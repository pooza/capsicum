// web_push_receive.cpp のスタンドアロン単体テスト (#474 フェーズ2)。
//
// 「raw エンベロープ → 鍵読み → 復号 → 文面化」のオーケストレーション配線を、
// RFC 8291 Appendix A の既知ベクタ（鍵 + 暗号文 body）で検証する。鍵は DPAPI で
// 保護した flutter_secure_storage.dat に入れ、暗号文 body はエンベロープ JSON に
// 包んで HandleWnsRawPayload に渡す。
//
// 復号は成功するが Appendix A の平文（"When I grow up, ..."）は SNS の JSON では
// ないため、最終段の payload パースで停止する。これにより「エンベロープ解析 →
// 鍵 lookup → base64url → 復号（鍵と body が一致しないと GCM タグで失敗する）」
// までの配線が通っていることを段階別エラーで確認する。改竄 body は「復号段」で
// 失敗することと対比させ、復号配線が本当に動いていることを示す。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 web_push_receive_test.cpp web_push_receive.cpp ^
//      web_push_key_reader.cpp web_push_decrypt.cpp web_push_payload.cpp ^
//      notification_type_label.cpp ^
//      /link crypt32.lib bcrypt.lib shell32.lib ole32.lib version.lib

#include <windows.h>
#include <dpapi.h>

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "web_push_receive.h"

namespace {

int g_failures = 0;

void CheckErr(bool ok, const std::string& err, const char* want_err,
              const char* name) {
  bool pass = !ok && err == want_err;
  if (pass) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s (ok=%d err=\"%s\" want=\"%s\")\n", name, ok ? 1 : 0,
                err.c_str(), want_err);
    ++g_failures;
  }
}

std::string JsonStr(const std::string& s) {
  std::string out = "\"";
  for (char c : s) {
    if (c == '"' || c == '\\') out.push_back('\\');
    out.push_back(c);
  }
  out += "\"";
  return out;
}

void WriteBytes(const std::wstring& path, const uint8_t* data, size_t len) {
  std::ofstream fs(path, std::ios::binary | std::ios::trunc);
  if (fs && len > 0) {
    fs.write(reinterpret_cast<const char*>(data),
             static_cast<std::streamsize>(len));
  }
}

bool WriteDat(const std::wstring& path, const std::string& json) {
  DATA_BLOB in;
  in.cbData = static_cast<DWORD>(json.size());
  in.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(json.data()));
  DATA_BLOB out = {0, nullptr};
  if (!CryptProtectData(&in, L"capsicum-test", nullptr, nullptr, nullptr, 0,
                        &out)) {
    return false;
  }
  WriteBytes(path, out.pbData, out.cbData);
  LocalFree(out.pbData);
  return true;
}

std::wstring TempPath(const wchar_t* name) {
  wchar_t dir[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, dir);
  std::wstring base = (n > 0 && n < MAX_PATH) ? std::wstring(dir) : L".\\";
  return base + name;
}

// RFC 8291 Appendix A の UA 鍵 + 暗号文 body（web_push_decrypt のテストと同値）。
const char* kP256dh =
    "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyP"
    "js7Vd8pZGH6SRpkNtoIAiw4";
const char* kAuth = "BTBZMqHH6r4Tts7J_aSIgg";
const char* kPriv = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94";
const char* kBody =
    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
    "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
    "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";

const char* kAccount = "probe@example.test";

std::string KeysetJson() {
  return "{" + JsonStr("p256dh") + ":" + JsonStr(kP256dh) + "," +
         JsonStr("auth") + ":" + JsonStr(kAuth) + "," + JsonStr("priv") + ":" +
         JsonStr(kPriv) + "}";
}

std::string DatJson() {
  return "{" + JsonStr(std::string("capsicum_push_keyset_mastodon://") +
                       kAccount) +
         ":" + JsonStr(KeysetJson()) + "}";
}

std::string Envelope(const std::string& account, const std::string& encoding,
                     const std::string& body) {
  std::string out = "{";
  out += JsonStr("account") + ":" + JsonStr(account) + ",";
  out += JsonStr("server") + ":" + JsonStr("https://example.test") + ",";
  if (!encoding.empty()) out += JsonStr("encoding") + ":" + JsonStr(encoding) + ",";
  out += JsonStr("body") + ":" + JsonStr(body);
  out += "}";
  return out;
}

}  // namespace

int main() {
  std::printf("WebPushReceive (orchestration) tests\n");
  using capsicum::HandleWnsRawPayload;
  using capsicum::PushDisplay;

  std::wstring dat = TempPath(L"capsicum_recv_test.dat");
  if (!WriteDat(dat, DatJson())) {
    std::fprintf(stderr, "failed to write test .dat\n");
    return 2;
  }

  // 1) フル配線: エンベロープ → 鍵 → base64url → 復号 まで通る。Appendix A の
  //    平文は JSON でないため最終段 payload パースで停止する（= 復号は成功）。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(Envelope(kAccount, "aes128gcm", kBody), dat,
                                  &d, &err);
    CheckErr(ok, err, "payload parse failed",
             "復号配線が通る（平文非JSONで parse 段停止 = 復号成功）");
  }

  // 2) account 欠落。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(Envelope("", "aes128gcm", kBody), dat, &d, &err);
    CheckErr(ok, err, "missing account", "account 欠落");
  }

  // 3) 暗号化通知でない（encoding 無し）→ 呼び出し側に委ねる。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(Envelope(kAccount, "", kBody), dat, &d, &err);
    CheckErr(ok, err, "not an encrypted notification",
             "encoding 無しは encrypted でない扱い");
  }

  // 4) 改竄 body → 復号段で失敗（1 と対比し復号が実際に走っていることを示す）。
  {
    std::string tampered = kBody;
    tampered[tampered.size() - 1] =
        (tampered.back() == 'A') ? 'B' : 'A';  // 末尾 1 文字を変える。
    PushDisplay d;
    std::string err;
    bool ok =
        HandleWnsRawPayload(Envelope(kAccount, "aes128gcm", tampered), dat, &d, &err);
    CheckErr(ok, err, "decryption failed", "改竄 body は復号段で失敗");
  }

  // 5) .dat に鍵が無いアカウント。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(
        Envelope("other@nope.test", "aes128gcm", kBody), dat, &d, &err);
    CheckErr(ok, err, "no push keys", "鍵不在アカウント");
  }

  // 6) body の base64 が不正。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload(Envelope(kAccount, "aes128gcm", "!!!not base64!!!"),
                                  dat, &d, &err);
    CheckErr(ok, err, "invalid body base64url", "body base64 不正");
  }

  // 7) エンベロープ JSON が壊れている。
  {
    PushDisplay d;
    std::string err;
    bool ok = HandleWnsRawPayload("{not json", dat, &d, &err);
    CheckErr(ok, err, "invalid envelope", "壊れたエンベロープ");
  }

  _wremove(dat.c_str());

  if (g_failures == 0) {
    std::printf("ALL PASS\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
