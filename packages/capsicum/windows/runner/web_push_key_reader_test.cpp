// web_push_key_reader.cpp のスタンドアロン単体テスト (#474 フェーズ2)。
//
// flutter_secure_storage_windows の Dart 実装と同じ形式
//   CryptProtectData( utf8( jsonEncode(Map<String,String>) ) )
// で一時 .dat を生成し、ReadPushKeys が DPAPI 復号 → JSON パース → base64url
// デコードまで正しく往復できることを検証する。鍵素材は RFC 8291 Appendix A の
// 既知ベクタ（web_push_decrypt のテストと同じ）を使い、復号器と地続きにする。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 web_push_key_reader_test.cpp web_push_key_reader.cpp ^
//      web_push_text_util.cpp ^
//      /link crypt32.lib shell32.lib ole32.lib version.lib
//   .\web_push_key_reader_test.exe
//
// 終了コード 0 = 全テスト成功、非 0 = 失敗。

#include <windows.h>
#include <dpapi.h>

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "web_push_key_reader.h"

namespace {

int g_failures = 0;

void Expect(bool cond, const char* name) {
  if (cond) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s\n", name);
    ++g_failures;
  }
}

// 参照用 base64url デコーダ（リーダー内部とは独立に実装し突き合わせる）。
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

// Dart jsonEncode 互換の最小 JSON 文字列エスケープ。
std::string JsonStr(const std::string& s) {
  std::string out = "\"";
  for (char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default: out.push_back(c); break;
    }
  }
  out += "\"";
  return out;
}

std::string KeysetJson(const std::string& p256dh, const std::string& auth,
                       const std::string& priv) {
  return "{" + JsonStr("p256dh") + ":" + JsonStr(p256dh) + "," +
         JsonStr("auth") + ":" + JsonStr(auth) + "," + JsonStr("priv") + ":" +
         JsonStr(priv) + "}";
}

// (key, value) の並びを String→String の JSON オブジェクトに直列化する。
std::string OuterJson(const std::vector<std::pair<std::string, std::string>>& m) {
  std::string out = "{";
  for (size_t i = 0; i < m.size(); ++i) {
    if (i != 0) out += ",";
    out += JsonStr(m[i].first) + ":" + JsonStr(m[i].second);
  }
  out += "}";
  return out;
}

void WriteBytes(const std::wstring& path, const uint8_t* data, size_t len) {
  std::ofstream fs(path, std::ios::binary | std::ios::trunc);
  if (fs && len > 0) {
    fs.write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(len));
  }
}

// 平文 JSON を DPAPI で保護してファイルに書く（プラグインの save と同形式）。
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

void WriteRaw(const std::wstring& path, const std::vector<uint8_t>& bytes) {
  WriteBytes(path, bytes.data(), bytes.size());
}

// RFC 8291 Appendix A の UA 鍵（web_push_decrypt のテストと同じ値）。
const char* kP256dh =
    "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyP"
    "js7Vd8pZGH6SRpkNtoIAiw4";
const char* kAuth = "BTBZMqHH6r4Tts7J_aSIgg";
const char* kPriv = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94";

std::wstring TempPath(const wchar_t* name) {
  wchar_t dir[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, dir);
  std::wstring base = (n > 0 && n < MAX_PATH) ? std::wstring(dir) : L".\\";
  return base + name;
}

bool Eq(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
  return a == b;
}

}  // namespace

int main() {
  std::printf("WebPushKeyReader (DPAPI .dat) tests\n");

  const std::string account = "probe@example.test";

  // 1) mastodon のキーが入った .dat から読める。
  {
    std::wstring path = TempPath(L"capsicum_kr_test1.dat");
    std::string outer = OuterJson({
        {"secret_mastodon://" + account, "{\"access_token\":\"x\"}"},
        {"capsicum_push_keyset_mastodon://" + account,
         KeysetJson(kP256dh, kAuth, kPriv)},
    });
    bool wrote = WriteDat(path, outer);
    capsicum::PushKeys keys;
    std::string err;
    bool ok = wrote && capsicum::ReadPushKeys(path, account, &keys, &err);
    Expect(ok, "mastodon の鍵セットを読める");
    Expect(ok && Eq(keys.p256dh, B64Url(kP256dh)) && keys.p256dh.size() == 65,
           "p256dh が一致 (65 bytes)");
    Expect(ok && Eq(keys.auth, B64Url(kAuth)) && keys.auth.size() == 16,
           "auth が一致 (16 bytes)");
    Expect(ok && Eq(keys.private_d, B64Url(kPriv)) && keys.private_d.size() == 32,
           "priv が一致 (32 bytes)");
    if (!ok) std::fprintf(stderr, "    error: %s\n", err.c_str());
    _wremove(path.c_str());
  }

  // 2) mastodon が無く misskey にあるとき fallback で読める。
  //    auth はパディング付き base64url で格納し、デコードの padding 処理も見る。
  {
    std::wstring path = TempPath(L"capsicum_kr_test2.dat");
    std::string padded_auth = std::string(kAuth) + "==";  // 16 bytes -> 末尾 ==
    std::string outer = OuterJson({
        {"capsicum_push_keyset_misskey://" + account,
         KeysetJson(kP256dh, padded_auth, kPriv)},
    });
    bool wrote = WriteDat(path, outer);
    capsicum::PushKeys keys;
    bool ok = wrote && capsicum::ReadPushKeys(path, account, &keys, nullptr);
    Expect(ok, "misskey fallback で読める");
    Expect(ok && Eq(keys.auth, B64Url(kAuth)) && keys.auth.size() == 16,
           "padding 付き auth も正しくデコード");
    _wremove(path.c_str());
  }

  // 3) 対象アカウントの鍵が無ければ false。
  {
    std::wstring path = TempPath(L"capsicum_kr_test3.dat");
    std::string outer = OuterJson({
        {"capsicum_push_keyset_mastodon://other@host",
         KeysetJson(kP256dh, kAuth, kPriv)},
    });
    bool wrote = WriteDat(path, outer);
    capsicum::PushKeys keys;
    bool ok = wrote && capsicum::ReadPushKeys(path, account, &keys, nullptr);
    Expect(!ok, "別アカウントしか無ければ false");
    _wremove(path.c_str());
  }

  // 4) DPAPI で保護されていない（壊れた）ファイルは false。
  {
    std::wstring path = TempPath(L"capsicum_kr_test4.dat");
    WriteRaw(path, {0x00, 0x01, 0x02, 0x03, 0x04, 0x05});
    capsicum::PushKeys keys;
    bool ok = capsicum::ReadPushKeys(path, account, &keys, nullptr);
    Expect(!ok, "非 DPAPI ファイルは復号失敗で false");
    _wremove(path.c_str());
  }

  // 5) 鍵セットに priv 欠落 → false。
  {
    std::wstring path = TempPath(L"capsicum_kr_test5.dat");
    std::string keyset = "{" + JsonStr("p256dh") + ":" + JsonStr(kP256dh) +
                         "," + JsonStr("auth") + ":" + JsonStr(kAuth) + "}";
    std::string outer = OuterJson({
        {"capsicum_push_keyset_mastodon://" + account, keyset},
    });
    bool wrote = WriteDat(path, outer);
    capsicum::PushKeys keys;
    bool ok = wrote && capsicum::ReadPushKeys(path, account, &keys, nullptr);
    Expect(!ok, "priv 欠落の鍵セットは false");
    _wremove(path.c_str());
  }

  // 6) ファイルが無ければ false。
  {
    capsicum::PushKeys keys;
    bool ok = capsicum::ReadPushKeys(TempPath(L"capsicum_kr_nope.dat"), account,
                                     &keys, nullptr);
    Expect(!ok, "ファイル不在は false");
  }

  // 7) push_labels.json からアカウント別 reblog/post ラベルを引く (#770)。
  //    形式は鍵セットと同じ「値が JSON 文字列の入れ子」なので OuterJson で組める。
  {
    const std::string inner = "{" + JsonStr("reblog") + ":" + JsonStr("RB") +
                              "," + JsonStr("post") + ":" + JsonStr("PO") + "}";
    const std::string labels = OuterJson({{account, inner}});

    std::string rb = "def_rb", po = "def_po";
    capsicum::ReadPushLabelsFromJson(labels, account, &rb, &po);
    Expect(rb == "RB" && po == "PO", "push_labels: 該当アカウントのラベルを反映");

    std::string rb2 = "def_rb", po2 = "def_po";
    capsicum::ReadPushLabelsFromJson(labels, "other@example.test", &rb2, &po2);
    Expect(rb2 == "def_rb" && po2 == "def_po",
           "push_labels: 該当なしは既定のまま");

    std::string rb3 = "def_rb", po3 = "def_po";
    capsicum::ReadPushLabelsFromJson("", account, &rb3, &po3);
    Expect(rb3 == "def_rb" && po3 == "def_po", "push_labels: 空JSONは既定のまま");

    std::string rb4 = "def_rb", po4 = "def_po";
    capsicum::ReadPushLabelsFromJson("{broken", account, &rb4, &po4);
    Expect(rb4 == "def_rb" && po4 == "def_po", "push_labels: 不正JSONは既定のまま");

    // 片方だけ入っている / 空文字列は、その項目だけ既定のまま据え置く。
    const std::string innerReblogOnly =
        "{" + JsonStr("reblog") + ":" + JsonStr("ONLY") + "," +
        JsonStr("post") + ":" + JsonStr("") + "}";
    const std::string labels2 = OuterJson({{account, innerReblogOnly}});
    std::string rb5 = "def_rb", po5 = "def_po";
    capsicum::ReadPushLabelsFromJson(labels2, account, &rb5, &po5);
    Expect(rb5 == "ONLY" && po5 == "def_po",
           "push_labels: 欠け/空項目は既定のまま");
  }

  if (g_failures == 0) {
    std::printf("ALL PASS\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
