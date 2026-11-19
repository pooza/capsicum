// web_push_decrypt.cpp のスタンドアロン単体テスト (#474 フェーズ2)。
//
// flutter / CMake のフルビルドに依存せず、CNG 復号ロジックを単体で検証する。
// macOS NSE / Dart の単体テストと同じ RFC 8291 Appendix A 既知ベクタを使い、
// 3 実装がビット一致することを担保する。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 web_push_decrypt_test.cpp web_push_decrypt.cpp ^
//      /link bcrypt.lib
//   .\web_push_decrypt_test.exe
//
// 終了コード 0 = 全テスト成功、非 0 = 失敗（失敗内容を stderr に出力）。

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "web_push_decrypt.h"

namespace {

int g_failures = 0;

// RFC 4648 §5 base64url（パディング省略可）デコーダ。
std::vector<uint8_t> B64Url(const std::string& in) {
  auto val = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
  };
  std::vector<uint8_t> out;
  int buf = 0, bits = 0;
  for (char c : in) {
    int v = val(c);
    if (v < 0) continue;
    buf = (buf << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<uint8_t>((buf >> bits) & 0xff));
    }
  }
  return out;
}

void Expect(bool cond, const char* name) {
  if (cond) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s\n", name);
    ++g_failures;
  }
}

// RFC 8291 Appendix A の固定ベクタ。
const char* kUaPrivate = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94";
const char* kUaPublic =
    "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyP"
    "js7Vd8pZGH6SRpkNtoIAiw4";
const char* kAuthSecret = "BTBZMqHH6r4Tts7J_aSIgg";
const char* kBody =
    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
    "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
    "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";
const char* kExpected = "When I grow up, I want to be a watermelon";

// capsicum#1390: aesgcm（Akkoma・古い Mastodon）。参照実装 http_ece（Python・
// 1.2.1）で作ったベクタで、Dart の web_push_decryptor_test.dart と同じもの。
// 鍵はこのテストのためだけに生成した使い捨て。
const char* kAesgcmPrivate = "dHFZR6GbgdtEXz1ihmtb3XKIpesGkP8hPNzgBMqBXsM";
const char* kAesgcmPublic =
    "BOaP7Rqa5UYJXUzicD8BY_GjojTEtk4sdIT9wQiherhu4U0LqyEfd_IixIALdqFVo2li"
    "i3Pmww7yx94irmy9efQ";
const char* kAesgcmAuth = "AAECAwQFBgcICQoLDA0ODw";
const char* kAesgcmDh =
    "BFClYpzh35kPLsutfMjcGlJFa0gCt7IxYsROs3W0A1ExNHkdNpFeXgKlDX2xisTpxBhU"
    "mR8LACHvrTXxXbH58mQ";
const char* kAesgcmSalt = "ZGVmZ2hpamtsbW5vcHFycw";
const char* kAesgcmBody =
    "fz9tMXkMRs-N59ij9_mlUoFVeQZpAgvP0uuGE8ejB1pzRGl7aC7JFcK9x55QAVkmBjF8"
    "8g2t6EQOUD4oOWFacKPVMfluJAuf-3HaauxS4B8uQutVxcUr2yHMnnxSFfgEni1HLEBu"
    "70m8OIm6tK39NTtU6qtbl7rbc5Lh5f4ZQfpb7GayFi-C8baShMsj4r8Dye9w6RcpcKHg"
    "M9yuPDLdmJdskVIjZJyI2nyNlR5VrY8i0DTpnNevxOuXyl6_uvS27UqaqiBuMZY";
// 平文の先頭（日本語を含むので全体は比べず、前後の ASCII で見る）。
const char* kAesgcmExpectedPrefix = "{\"title\": \"capsicumtest2 ";
const char* kAesgcmExpectedSuffix = "\"preferred_locale\": \"ja\"}";

bool StartsWith(const std::string& s, const char* p) {
  return s.compare(0, std::string(p).size(), p) == 0;
}
bool EndsWith(const std::string& s, const char* p) {
  const std::string suffix(p);
  return s.size() >= suffix.size() &&
         s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

}  // namespace

int main() {
  std::printf("WebPushDecryptor (CNG) tests\n");

  const std::vector<uint8_t> ua_private = B64Url(kUaPrivate);
  const std::vector<uint8_t> ua_public = B64Url(kUaPublic);
  const std::vector<uint8_t> auth = B64Url(kAuthSecret);

  // 1) RFC 8291 Appendix A の既知ベクタを復号できる。
  {
    std::vector<uint8_t> plaintext;
    std::string err;
    bool ok = capsicum::DecryptWebPushAes128Gcm(
        B64Url(kBody), ua_private, ua_public, auth, &plaintext, &err);
    std::string text(plaintext.begin(), plaintext.end());
    Expect(ok && text == kExpected, "RFC 8291 Appendix A: 既知ベクタを復号");
    if (!ok) std::fprintf(stderr, "    error: %s\n", err.c_str());
    if (ok && text != kExpected)
      std::fprintf(stderr, "    got: \"%s\"\n", text.c_str());
  }

  // 2) 改竄された ciphertext は失敗する（GCM タグ不一致）。
  {
    auto body = B64Url(kBody);
    body[body.size() - 1] ^= 0x01;
    std::vector<uint8_t> plaintext;
    bool ok = capsicum::DecryptWebPushAes128Gcm(body, ua_private, ua_public,
                                                auth, &plaintext, nullptr);
    Expect(!ok, "改竄 ciphertext は失敗する");
  }

  // 3) auth_secret が違うと復号に失敗する。
  {
    std::vector<uint8_t> wrong_auth(16, 0);
    std::vector<uint8_t> plaintext;
    bool ok = capsicum::DecryptWebPushAes128Gcm(
        B64Url(kBody), ua_private, ua_public, wrong_auth, &plaintext, nullptr);
    Expect(!ok, "誤 auth_secret は失敗する");
  }

  // 4) ヘッダが短すぎるペイロードは失敗する。
  {
    std::vector<uint8_t> plaintext;
    bool ok = capsicum::DecryptWebPushAes128Gcm(
        {0, 1, 2}, std::vector<uint8_t>(32), std::vector<uint8_t>(65, 0x04),
        std::vector<uint8_t>(16), &plaintext, nullptr);
    Expect(!ok, "短すぎるペイロードは失敗する");
  }

  // ---- aesgcm（capsicum#1390）----
  const std::vector<uint8_t> g_priv = B64Url(kAesgcmPrivate);
  const std::vector<uint8_t> g_pub = B64Url(kAesgcmPublic);
  const std::vector<uint8_t> g_auth = B64Url(kAesgcmAuth);
  // Akkoma と同じ並び（dh の後ろに p256ecdsa）。
  const std::string g_ck = std::string("dh=") + kAesgcmDh + ";p256ecdsa=BAnWLIQt";
  const std::string g_enc = std::string("salt=") + kAesgcmSalt;

  // 5) 参照実装のベクタを復号できる。
  {
    std::vector<uint8_t> plaintext;
    std::string err;
    bool ok = capsicum::DecryptWebPushAesGcm(B64Url(kAesgcmBody), g_ck, g_enc,
                                             g_priv, g_pub, g_auth, &plaintext,
                                             &err);
    std::string text(plaintext.begin(), plaintext.end());
    Expect(ok && StartsWith(text, kAesgcmExpectedPrefix) &&
               EndsWith(text, kAesgcmExpectedSuffix) && text.size() == 182,
           "aesgcm: 参照実装（http_ece）のベクタを復号");
    if (!ok) std::fprintf(stderr, "    error: %s\n", err.c_str());
  }

  // 6) ヘッダの書き方の揺れ（keyid が先・カンマ区切り・引用符・rs）を読める。
  {
    const std::string ck =
        std::string("keyid=p256dh;dh=\"") + kAesgcmDh + "\",p256ecdsa=BAnWLIQt";
    const std::string enc =
        std::string("keyid=p256dh;salt=\"") + kAesgcmSalt + "\";rs=4096";
    std::vector<uint8_t> plaintext;
    bool ok = capsicum::DecryptWebPushAesGcm(B64Url(kAesgcmBody), ck, enc,
                                             g_priv, g_pub, g_auth, &plaintext,
                                             nullptr);
    Expect(ok && plaintext.size() == 182, "aesgcm: ヘッダの書き方の揺れを読める");
  }

  // 7) 改竄・誤 auth・ヘッダ欠け・複数レコードは失敗する。
  {
    auto body = B64Url(kAesgcmBody);
    body[body.size() - 1] ^= 0x01;
    std::vector<uint8_t> plaintext;
    Expect(!capsicum::DecryptWebPushAesGcm(body, g_ck, g_enc, g_priv, g_pub,
                                           g_auth, &plaintext, nullptr),
           "aesgcm: 改竄 ciphertext は失敗する");
    Expect(!capsicum::DecryptWebPushAesGcm(B64Url(kAesgcmBody), g_ck, g_enc,
                                           g_priv, g_pub,
                                           std::vector<uint8_t>(16, 0),
                                           &plaintext, nullptr),
           "aesgcm: 誤 auth_secret は失敗する");
    Expect(!capsicum::DecryptWebPushAesGcm(B64Url(kAesgcmBody), "p256ecdsa=x",
                                           g_enc, g_priv, g_pub, g_auth,
                                           &plaintext, nullptr),
           "aesgcm: dh が無ければ失敗する");
    Expect(!capsicum::DecryptWebPushAesGcm(B64Url(kAesgcmBody), g_ck, "rs=4096",
                                           g_priv, g_pub, g_auth, &plaintext,
                                           nullptr),
           "aesgcm: salt が無ければ失敗する");
    Expect(!capsicum::DecryptWebPushAesGcm(B64Url(kAesgcmBody), g_ck,
                                           g_enc + ";rs=16", g_priv, g_pub,
                                           g_auth, &plaintext, nullptr),
           "aesgcm: rs を超える長さ（複数レコード）は失敗する");
  }

  if (g_failures == 0) {
    std::printf("ALL PASS\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
