#include "web_push_decrypt.h"

#include <windows.h>

#include <bcrypt.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <initializer_list>

#ifndef NT_SUCCESS
#define NT_SUCCESS(Status) (((NTSTATUS)(Status)) >= 0)
#endif

namespace capsicum {

namespace {

// CNG マジック値（bcrypt.h で提供されるが、ヘッダ差異に備え定数で持つ）。
constexpr ULONG kEcdhPublicP256Magic = 0x314B4345;   // BCRYPT_ECDH_PUBLIC_P256_MAGIC
constexpr ULONG kEcdhPrivateP256Magic = 0x324B4345;  // BCRYPT_ECDH_PRIVATE_P256_MAGIC

// 例外を投げられない（_HAS_EXCEPTIONS=0）ため、CNG ハンドルは RAII 構造体で
// 通常リターン時に確実に解放する。
struct AlgProvider {
  BCRYPT_ALG_HANDLE h = nullptr;
  ~AlgProvider() {
    if (h) BCryptCloseAlgorithmProvider(h, 0);
  }
};
struct HashHandle {
  BCRYPT_HASH_HANDLE h = nullptr;
  ~HashHandle() {
    if (h) BCryptDestroyHash(h);
  }
};
struct KeyHandle {
  BCRYPT_KEY_HANDLE h = nullptr;
  ~KeyHandle() {
    if (h) BCryptDestroyKey(h);
  }
};
struct SecretHandle {
  BCRYPT_SECRET_HANDLE h = nullptr;
  ~SecretHandle() {
    if (h) BCryptDestroySecret(h);
  }
};

bool Fail(std::string* error, const char* msg, NTSTATUS st) {
  if (error) {
    char buf[160];
    std::snprintf(buf, sizeof(buf), "%s (NTSTATUS=0x%08lx)", msg,
                  static_cast<unsigned long>(st));
    *error = buf;
  }
  return false;
}

bool Fail(std::string* error, const char* msg) {
  if (error) *error = msg;
  return false;
}

// HMAC-SHA256(key, data) を 32 バイトで `*out` に書く。
bool HmacSha256(const std::vector<uint8_t>& key,
                const std::vector<uint8_t>& data, std::vector<uint8_t>* out,
                std::string* error) {
  AlgProvider alg;
  NTSTATUS st = BCryptOpenAlgorithmProvider(&alg.h, BCRYPT_SHA256_ALGORITHM,
                                            nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG);
  if (!NT_SUCCESS(st))
    return Fail(error, "BCryptOpenAlgorithmProvider(HMAC-SHA256)", st);

  HashHandle hash;
  const UCHAR zero = 0;
  const UCHAR* key_ptr = key.empty() ? &zero : key.data();
  ULONG key_len = key.empty() ? 0 : static_cast<ULONG>(key.size());
  st = BCryptCreateHash(alg.h, &hash.h, nullptr, 0,
                        const_cast<UCHAR*>(key_ptr), key_len, 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptCreateHash", st);

  if (!data.empty()) {
    st = BCryptHashData(hash.h, const_cast<UCHAR*>(data.data()),
                        static_cast<ULONG>(data.size()), 0);
    if (!NT_SUCCESS(st)) return Fail(error, "BCryptHashData", st);
  }

  out->assign(32, 0);
  st = BCryptFinishHash(hash.h, out->data(), 32, 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptFinishHash", st);
  return true;
}

// RFC 5869 HKDF-SHA256（extract + expand）。
bool Hkdf(const std::vector<uint8_t>& ikm, const std::vector<uint8_t>& salt,
          const std::vector<uint8_t>& info, size_t length,
          std::vector<uint8_t>* out, std::string* error) {
  // extract: PRK = HMAC(salt, IKM)
  std::vector<uint8_t> prk;
  if (!HmacSha256(salt, ikm, &prk, error)) return false;

  // expand: T(i) = HMAC(PRK, T(i-1) || info || i)
  std::vector<uint8_t> okm;
  std::vector<uint8_t> t;
  uint8_t counter = 1;
  while (okm.size() < length) {
    std::vector<uint8_t> input;
    input.reserve(t.size() + info.size() + 1);
    input.insert(input.end(), t.begin(), t.end());
    input.insert(input.end(), info.begin(), info.end());
    input.push_back(counter);
    if (!HmacSha256(prk, input, &t, error)) return false;
    okm.insert(okm.end(), t.begin(), t.end());
    ++counter;
  }
  okm.resize(length);
  *out = std::move(okm);
  return true;
}

// 受信者の秘密鍵 D 値と送信者の公開鍵から ECDH 共有秘密（32 バイト・共有点
// X 座標のビッグエンディアン）を `*out` に書く。
bool EcdhP256(const std::vector<uint8_t>& ua_private_key_d,
              const std::vector<uint8_t>& ua_public_key,
              const std::vector<uint8_t>& as_public_key,
              std::vector<uint8_t>* out, std::string* error) {
  if (ua_private_key_d.size() != 32 || ua_public_key.size() != 65 ||
      ua_public_key[0] != 0x04 || as_public_key.size() != 65 ||
      as_public_key[0] != 0x04) {
    return Fail(error, "invalid key length for ECDH P-256");
  }

  AlgProvider alg;
  NTSTATUS st = BCryptOpenAlgorithmProvider(&alg.h, BCRYPT_ECDH_P256_ALGORITHM,
                                            nullptr, 0);
  if (!NT_SUCCESS(st))
    return Fail(error, "BCryptOpenAlgorithmProvider(ECDH_P256)", st);

  // 受信者の秘密鍵 BLOB: header(magic,cbKey=32) || X(32) || Y(32) || d(32)
  // X / Y は受信者公開鍵 (0x04 || X || Y) から取り出す。
  std::vector<uint8_t> priv_blob(sizeof(BCRYPT_ECCKEY_BLOB) + 96);
  auto* priv_hdr = reinterpret_cast<BCRYPT_ECCKEY_BLOB*>(priv_blob.data());
  priv_hdr->dwMagic = kEcdhPrivateP256Magic;
  priv_hdr->cbKey = 32;
  uint8_t* p = priv_blob.data() + sizeof(BCRYPT_ECCKEY_BLOB);
  std::memcpy(p, ua_public_key.data() + 1, 64);      // X || Y
  std::memcpy(p + 64, ua_private_key_d.data(), 32);  // d

  KeyHandle priv;
  st = BCryptImportKeyPair(alg.h, nullptr, BCRYPT_ECCPRIVATE_BLOB, &priv.h,
                           priv_blob.data(),
                           static_cast<ULONG>(priv_blob.size()), 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptImportKeyPair(private)", st);

  // 送信者の公開鍵 BLOB: header(magic,cbKey=32) || X(32) || Y(32)
  std::vector<uint8_t> pub_blob(sizeof(BCRYPT_ECCKEY_BLOB) + 64);
  auto* pub_hdr = reinterpret_cast<BCRYPT_ECCKEY_BLOB*>(pub_blob.data());
  pub_hdr->dwMagic = kEcdhPublicP256Magic;
  pub_hdr->cbKey = 32;
  std::memcpy(pub_blob.data() + sizeof(BCRYPT_ECCKEY_BLOB),
              as_public_key.data() + 1, 64);

  KeyHandle pub;
  st = BCryptImportKeyPair(alg.h, nullptr, BCRYPT_ECCPUBLIC_BLOB, &pub.h,
                           pub_blob.data(),
                           static_cast<ULONG>(pub_blob.size()), 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptImportKeyPair(public)", st);

  SecretHandle secret;
  st = BCryptSecretAgreement(priv.h, pub.h, &secret.h, 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptSecretAgreement", st);

  // BCRYPT_KDF_RAW_SECRET は共有点 X 座標を **リトルエンディアン** で返す。
  // RFC は標準（ビッグエンディアン）32 バイトを要求するため反転する。
  ULONG out_len = 0;
  st = BCryptDeriveKey(secret.h, BCRYPT_KDF_RAW_SECRET, nullptr, nullptr, 0,
                       &out_len, 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptDeriveKey(size)", st);

  std::vector<uint8_t> shared(out_len);
  st = BCryptDeriveKey(secret.h, BCRYPT_KDF_RAW_SECRET, nullptr, shared.data(),
                       out_len, &out_len, 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptDeriveKey", st);

  std::reverse(shared.begin(), shared.end());
  // P-256 の共有秘密は 32 バイト。短ければ先頭ゼロ詰め、長ければ切り詰め。
  if (shared.size() < 32) {
    shared.insert(shared.begin(), 32 - shared.size(), 0);
  } else if (shared.size() > 32) {
    shared.resize(32);
  }
  *out = std::move(shared);
  return true;
}

// AES-128-GCM 復号。`cipher_with_tag` は ciphertext || tag(16)。タグ不一致は失敗。
bool AesGcmDecrypt(const std::vector<uint8_t>& cipher_with_tag,
                   const std::vector<uint8_t>& cek,
                   const std::vector<uint8_t>& nonce,
                   std::vector<uint8_t>* out, std::string* error) {
  if (cek.size() != 16 || nonce.size() != 12)
    return Fail(error, "invalid CEK/nonce length");
  if (cipher_with_tag.size() < 16)
    return Fail(error, "ciphertext too short for GCM tag");

  const size_t cipher_len = cipher_with_tag.size() - 16;
  std::vector<uint8_t> cipher(cipher_with_tag.begin(),
                              cipher_with_tag.begin() + cipher_len);
  std::vector<uint8_t> tag(cipher_with_tag.begin() + cipher_len,
                           cipher_with_tag.end());

  AlgProvider alg;
  NTSTATUS st =
      BCryptOpenAlgorithmProvider(&alg.h, BCRYPT_AES_ALGORITHM, nullptr, 0);
  if (!NT_SUCCESS(st))
    return Fail(error, "BCryptOpenAlgorithmProvider(AES)", st);

  st = BCryptSetProperty(
      alg.h, BCRYPT_CHAINING_MODE,
      reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_GCM)),
      sizeof(BCRYPT_CHAIN_MODE_GCM), 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptSetProperty(GCM)", st);

  KeyHandle key;
  st = BCryptGenerateSymmetricKey(alg.h, &key.h, nullptr, 0,
                                  const_cast<PUCHAR>(cek.data()),
                                  static_cast<ULONG>(cek.size()), 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptGenerateSymmetricKey", st);

  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO auth_info;
  BCRYPT_INIT_AUTH_MODE_INFO(auth_info);
  auth_info.pbNonce = const_cast<PUCHAR>(nonce.data());
  auth_info.cbNonce = static_cast<ULONG>(nonce.size());
  auth_info.pbTag = tag.data();
  auth_info.cbTag = static_cast<ULONG>(tag.size());

  std::vector<uint8_t> plaintext(cipher_len);
  ULONG written = 0;
  st = BCryptDecrypt(key.h, cipher.empty() ? nullptr : cipher.data(),
                     static_cast<ULONG>(cipher.size()), &auth_info, nullptr, 0,
                     plaintext.empty() ? nullptr : plaintext.data(),
                     static_cast<ULONG>(plaintext.size()), &written, 0);
  if (!NT_SUCCESS(st)) return Fail(error, "BCryptDecrypt", st);

  plaintext.resize(written);
  *out = std::move(plaintext);
  return true;
}

// RFC 8188 §2: 単一レコード末尾は 0x02 デリミタ + 0x00 パディング。
bool StripPadding(const std::vector<uint8_t>& bytes, std::vector<uint8_t>* out,
                  std::string* error) {
  size_t i = bytes.size();
  while (i > 0 && bytes[i - 1] == 0x00) {
    --i;
  }
  if (i == 0 || bytes[i - 1] != 0x02)
    return Fail(error, "missing aes128gcm last-record delimiter (0x02)");
  out->assign(bytes.begin(), bytes.begin() + (i - 1));
  return true;
}

std::vector<uint8_t> Concat(
    std::initializer_list<std::vector<uint8_t>> parts) {
  std::vector<uint8_t> out;
  size_t total = 0;
  for (const auto& part : parts) total += part.size();
  out.reserve(total);
  for (const auto& part : parts) out.insert(out.end(), part.begin(), part.end());
  return out;
}

std::vector<uint8_t> Bytes(const char* s) {
  return std::vector<uint8_t>(s, s + std::strlen(s));
}

uint32_t ReadU32Be(const std::vector<uint8_t>& b, size_t off) {
  return (static_cast<uint32_t>(b[off]) << 24) |
         (static_cast<uint32_t>(b[off + 1]) << 16) |
         (static_cast<uint32_t>(b[off + 2]) << 8) |
         static_cast<uint32_t>(b[off + 3]);
}

}  // namespace

bool DecryptWebPushAes128Gcm(const std::vector<uint8_t>& body,
                             const std::vector<uint8_t>& ua_private_key_d,
                             const std::vector<uint8_t>& ua_public_key,
                             const std::vector<uint8_t>& auth_secret,
                             std::vector<uint8_t>* out, std::string* error) {
  if (out == nullptr) return Fail(error, "out must not be null");
  if (body.size() < 21) return Fail(error, "payload too short");

  const std::vector<uint8_t> salt(body.begin(), body.begin() + 16);
  const uint32_t rs = ReadU32Be(body, 16);
  if (rs == 0) return Fail(error, "record size must be non-zero");

  const size_t idlen = body[20];
  if (body.size() < 21 + idlen)
    return Fail(error, "payload truncated before keyid");

  const std::vector<uint8_t> keyid(body.begin() + 21,
                                   body.begin() + 21 + idlen);
  const std::vector<uint8_t> ciphertext(body.begin() + 21 + idlen, body.end());

  if (idlen != 65 || keyid[0] != 0x04)
    return Fail(error, "invalid keyid: expected uncompressed P-256 public key");
  const std::vector<uint8_t>& as_public = keyid;

  std::vector<uint8_t> ecdh_secret;
  if (!EcdhP256(ua_private_key_d, ua_public_key, as_public, &ecdh_secret, error))
    return false;

  // RFC 8291 §3.4: IKM = HKDF(auth_secret, ecdh_secret, key_info, 32)
  std::vector<uint8_t> ikm;
  if (!Hkdf(ecdh_secret, auth_secret,
            Concat({Bytes("WebPush: info"), {0x00}, ua_public_key, as_public}),
            32, &ikm, error))
    return false;

  // RFC 8188 §2.2: CEK / NONCE = HKDF(IKM, salt, label, len)
  std::vector<uint8_t> cek;
  if (!Hkdf(ikm, salt,
            Concat({Bytes("Content-Encoding: aes128gcm"), {0x00}}), 16, &cek,
            error))
    return false;
  std::vector<uint8_t> nonce;
  if (!Hkdf(ikm, salt, Concat({Bytes("Content-Encoding: nonce"), {0x00}}), 12,
            &nonce, error))
    return false;

  std::vector<uint8_t> plaintext_with_padding;
  if (!AesGcmDecrypt(ciphertext, cek, nonce, &plaintext_with_padding, error))
    return false;
  return StripPadding(plaintext_with_padding, out, error);
}

}  // namespace capsicum
