#ifndef RUNNER_WEB_PUSH_DECRYPT_H_
#define RUNNER_WEB_PUSH_DECRYPT_H_

#include <cstdint>
#include <string>
#include <vector>

// RFC 8291 (Web Push Encryption, aes128gcm) を復号する (#474 フェーズ2)。
//
// 参照実装は macOS NSE の `WebPushDecryptor.swift`（CryptoKit）/ Dart 側の
// `web_push_decryptor.dart`（pointycastle）。3 実装はビットごとに同じ結果を
// 返すよう、同一の RFC 8291 Appendix A 既知ベクタで突き合わせている。
//
// Windows では暗号プリミティブを CNG (bcrypt) で構成する:
//   - ECDH P-256        : BCryptSecretAgreement + BCRYPT_KDF_RAW_SECRET
//   - HKDF-SHA256        : HMAC-SHA256 上に extract/expand を自前構成
//   - AES-128-GCM        : BCRYPT_AES_ALGORITHM + GCM チェイニング
//
// Flutter / WinRT には依存しない。WNS バックグラウンドタスク（別プロセス・
// 別 DLL）からも同じ TU を再利用できるよう、純粋な std::vector I/F にする。
//
// runner ターゲットは `_HAS_EXCEPTIONS=0`（例外無効）でビルドされるため、
// 失敗は例外ではなく戻り値 (bool) + 任意の error 文字列で表現する。
namespace capsicum {

// aes128gcm の Web Push ペイロードを復号する。
//
// 成功時は true を返し `*out` に平文を書き込む。
// 失敗（ペイロード不正・鍵不一致・GCM タグ不一致・CNG エラー）時は false を
// 返し、`error` が非 null なら失敗理由を `*error` に設定する。
//
// `body` は RFC 8188 形式のバイト列
//   (salt(16) || rs(4) || idlen(1) || keyid(idlen) || ciphertext)。
// `ua_private_key_d` は受信者の P-256 秘密鍵 D 値 (32 バイト)。
// `ua_public_key` は受信者の P-256 公開鍵 (非圧縮 65 バイト, 先頭 0x04)。
// `auth_secret` は Web Push 登録時に交換した 16 バイト認証秘密。
bool DecryptWebPushAes128Gcm(const std::vector<uint8_t>& body,
                             const std::vector<uint8_t>& ua_private_key_d,
                             const std::vector<uint8_t>& ua_public_key,
                             const std::vector<uint8_t>& auth_secret,
                             std::vector<uint8_t>* out,
                             std::string* error = nullptr);

}  // namespace capsicum

#endif  // RUNNER_WEB_PUSH_DECRYPT_H_
