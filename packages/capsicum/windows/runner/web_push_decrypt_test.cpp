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

  if (g_failures == 0) {
    std::printf("ALL PASS\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
