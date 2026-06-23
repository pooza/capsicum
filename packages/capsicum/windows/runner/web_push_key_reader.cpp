#include "web_push_key_reader.h"

#include <windows.h>
// windows.h の後に置く（依存順）。
#include <dpapi.h>
#include <shlobj.h>

#include <cstdio>
#include <fstream>
#include <map>

namespace capsicum {

namespace {

// ---------------------------------------------------------------------------
// base64url デコード（RFC 4648 §5。パディング '=' は読み飛ばし、padded /
// unpadded どちらも受ける）。不正文字があれば false。
// ---------------------------------------------------------------------------
bool Base64UrlDecode(const std::string& in, std::vector<uint8_t>* out) {
  out->clear();
  int buffer = 0;
  int bits = 0;
  for (char c : in) {
    int value;
    if (c >= 'A' && c <= 'Z') {
      value = c - 'A';
    } else if (c >= 'a' && c <= 'z') {
      value = c - 'a' + 26;
    } else if (c >= '0' && c <= '9') {
      value = c - '0' + 52;
    } else if (c == '-') {
      value = 62;
    } else if (c == '_') {
      value = 63;
    } else if (c == '=') {
      continue;  // パディングは無視。
    } else {
      return false;  // 不正文字。
    }
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out->push_back(static_cast<uint8_t>((buffer >> bits) & 0xff));
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// コードポイントを UTF-8 にして末尾へ追加する（JSON \uXXXX 用）。
// ---------------------------------------------------------------------------
void AppendUtf8(uint32_t cp, std::string* out) {
  if (cp <= 0x7f) {
    out->push_back(static_cast<char>(cp));
  } else if (cp <= 0x7ff) {
    out->push_back(static_cast<char>(0xc0 | (cp >> 6)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3f)));
  } else if (cp <= 0xffff) {
    out->push_back(static_cast<char>(0xe0 | (cp >> 12)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3f)));
  } else {
    out->push_back(static_cast<char>(0xf0 | (cp >> 18)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3f)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3f)));
  }
}

bool ParseHex4(const std::string& s, size_t pos, uint32_t* out) {
  if (pos + 4 > s.size()) {
    return false;
  }
  uint32_t value = 0;
  for (size_t i = 0; i < 4; ++i) {
    char c = s[pos + i];
    value <<= 4;
    if (c >= '0' && c <= '9') {
      value |= static_cast<uint32_t>(c - '0');
    } else if (c >= 'a' && c <= 'f') {
      value |= static_cast<uint32_t>(c - 'a' + 10);
    } else if (c >= 'A' && c <= 'F') {
      value |= static_cast<uint32_t>(c - 'A' + 10);
    } else {
      return false;
    }
  }
  *out = value;
  return true;
}

void SkipWhitespace(const std::string& s, size_t* i) {
  while (*i < s.size()) {
    char c = s[*i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      ++(*i);
    } else {
      break;
    }
  }
}

// JSON 文字列を 1 つ読む。`*i` は開きクォートを指している前提。成功時 `*i` は
// 閉じクォートの次へ進む。エスケープ（\" \\ \/ \b \f \n \r \t \uXXXX、
// サロゲートペア対応）を解く。
bool ParseJsonString(const std::string& s, size_t* i, std::string* out) {
  if (*i >= s.size() || s[*i] != '"') {
    return false;
  }
  ++(*i);
  out->clear();
  while (*i < s.size()) {
    char c = s[*i];
    if (c == '"') {
      ++(*i);
      return true;
    }
    if (c == '\\') {
      ++(*i);
      if (*i >= s.size()) {
        return false;
      }
      char e = s[*i];
      switch (e) {
        case '"': out->push_back('"'); break;
        case '\\': out->push_back('\\'); break;
        case '/': out->push_back('/'); break;
        case 'b': out->push_back('\b'); break;
        case 'f': out->push_back('\f'); break;
        case 'n': out->push_back('\n'); break;
        case 'r': out->push_back('\r'); break;
        case 't': out->push_back('\t'); break;
        case 'u': {
          uint32_t cp = 0;
          if (!ParseHex4(s, *i + 1, &cp)) {
            return false;
          }
          *i += 4;
          // サロゲートペアの上位なら下位を続けて読む。
          if (cp >= 0xd800 && cp <= 0xdbff) {
            if (*i + 2 < s.size() && s[*i + 1] == '\\' && s[*i + 2] == 'u') {
              uint32_t low = 0;
              if (!ParseHex4(s, *i + 3, &low)) {
                return false;
              }
              if (low >= 0xdc00 && low <= 0xdfff) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                *i += 6;
              }
            }
          }
          AppendUtf8(cp, out);
          break;
        }
        default:
          return false;  // 不正なエスケープ。
      }
      ++(*i);
    } else {
      out->push_back(c);
      ++(*i);
    }
  }
  return false;  // 閉じクォートが無い。
}

// 値がすべて文字列の JSON オブジェクト `{"k":"v",...}` をパースする。
// 値に文字列以外（数値・配列・オブジェクト・true/false/null）が来たら false。
// flutter_secure_storage の外側マップ（String→String）と、内側の鍵セット JSON
// （p256dh/auth/priv はいずれも文字列）の両方に使える。
bool ParseJsonStringMap(const std::string& s,
                        std::map<std::string, std::string>* out) {
  out->clear();
  size_t i = 0;
  SkipWhitespace(s, &i);
  if (i >= s.size() || s[i] != '{') {
    return false;
  }
  ++i;
  SkipWhitespace(s, &i);
  if (i < s.size() && s[i] == '}') {
    return true;  // 空オブジェクト。
  }
  while (i < s.size()) {
    SkipWhitespace(s, &i);
    std::string key;
    if (!ParseJsonString(s, &i, &key)) {
      return false;
    }
    SkipWhitespace(s, &i);
    if (i >= s.size() || s[i] != ':') {
      return false;
    }
    ++i;
    SkipWhitespace(s, &i);
    std::string value;
    if (!ParseJsonString(s, &i, &value)) {
      return false;  // 文字列以外の値は非対応。
    }
    (*out)[key] = value;
    SkipWhitespace(s, &i);
    if (i >= s.size()) {
      return false;
    }
    if (s[i] == ',') {
      ++i;
      continue;
    }
    if (s[i] == '}') {
      return true;
    }
    return false;
  }
  return false;
}

// ---------------------------------------------------------------------------
// ファイル全体をバイト列で読む。
// ---------------------------------------------------------------------------
bool ReadAllBytes(const std::wstring& path, std::vector<uint8_t>* out) {
  std::ifstream fs(path, std::ios::binary | std::ios::ate);
  if (!fs) {
    return false;
  }
  std::streamoff size = fs.tellg();
  if (size < 0) {
    return false;
  }
  fs.seekg(0, std::ios::beg);
  out->resize(static_cast<size_t>(size));
  if (size > 0) {
    fs.read(reinterpret_cast<char*>(out->data()), size);
    if (!fs) {
      return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// DPAPI 復号（CryptUnprotectData）。flutter_secure_storage はオプショナル
// エントロピー無し・ユーザースコープで保護しているため、同じユーザーの
// プロセスから復号できる。
// ---------------------------------------------------------------------------
bool DpapiUnprotect(const std::vector<uint8_t>& in, std::string* out) {
  DATA_BLOB input;
  input.cbData = static_cast<DWORD>(in.size());
  input.pbData = const_cast<BYTE*>(in.data());
  DATA_BLOB output = {0, nullptr};
  if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, 0,
                          &output)) {
    return false;
  }
  out->assign(reinterpret_cast<const char*>(output.pbData), output.cbData);
  if (output.pbData != nullptr) {
    LocalFree(output.pbData);
  }
  return true;
}

bool DecodeKey(const std::map<std::string, std::string>& fields,
               const char* name, size_t expected_len,
               std::vector<uint8_t>* out) {
  auto it = fields.find(name);
  if (it == fields.end()) {
    return false;
  }
  if (!Base64UrlDecode(it->second, out)) {
    return false;
  }
  return out->size() == expected_len;
}

}  // namespace

bool ReadPushKeys(const std::wstring& dat_file_path, const std::string& account,
                  PushKeys* out, std::string* error) {
  auto fail = [&](const char* message) {
    if (error != nullptr) {
      *error = message;
    }
    return false;
  };

  std::vector<uint8_t> encrypted;
  if (!ReadAllBytes(dat_file_path, &encrypted)) {
    return fail("secure storage file not found or unreadable");
  }
  std::string plain;
  if (!DpapiUnprotect(encrypted, &plain)) {
    return fail("CryptUnprotectData failed");
  }
  std::map<std::string, std::string> entries;
  if (!ParseJsonStringMap(plain, &entries)) {
    return fail("failed to parse secure storage JSON map");
  }

  // adapter 種別が判らないので mastodon → misskey の順に storage key を試す。
  const char* kPrefixes[] = {"mastodon", "misskey"};
  for (const char* prefix : kPrefixes) {
    std::string storage_key =
        "capsicum_push_keyset_" + std::string(prefix) + "://" + account;
    auto it = entries.find(storage_key);
    if (it == entries.end()) {
      continue;
    }
    std::map<std::string, std::string> fields;
    if (!ParseJsonStringMap(it->second, &fields)) {
      return fail("failed to parse keyset JSON");
    }
    if (!DecodeKey(fields, "p256dh", 65, &out->p256dh)) {
      return fail("invalid p256dh");
    }
    if (!DecodeKey(fields, "auth", 16, &out->auth)) {
      return fail("invalid auth");
    }
    if (!DecodeKey(fields, "priv", 32, &out->private_d)) {
      return fail("invalid priv");
    }
    return true;
  }
  return fail("no push keys for account");
}

std::wstring DefaultSecureStorageDatPath() {
  // %APPDATA% (Roaming) を取得。
  PWSTR roaming = nullptr;
  if (SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &roaming) !=
      S_OK) {
    if (roaming != nullptr) {
      CoTaskMemFree(roaming);
    }
    return std::wstring();
  }
  std::wstring base(roaming);
  CoTaskMemFree(roaming);

  // 実行中 exe のバージョン情報から CompanyName / ProductName を取る
  // （path_provider_windows と同じ規則）。
  wchar_t module_path[MAX_PATH];
  DWORD len = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return std::wstring();
  }
  DWORD dummy = 0;
  DWORD info_size = GetFileVersionInfoSizeW(module_path, &dummy);
  if (info_size == 0) {
    return std::wstring();
  }
  std::vector<uint8_t> info(info_size);
  if (!GetFileVersionInfoW(module_path, 0, info_size, info.data())) {
    return std::wstring();
  }

  auto query = [&](const wchar_t* name) -> std::wstring {
    // 040904e4 (US English, Windows Multilingual) / 040904b0 (Unicode) の順。
    const wchar_t* code_pages[] = {L"040904e4", L"040904b0"};
    for (const wchar_t* cp : code_pages) {
      std::wstring sub =
          std::wstring(L"\\StringFileInfo\\") + cp + L"\\" + name;
      void* value = nullptr;
      UINT value_len = 0;
      if (VerQueryValueW(info.data(), sub.c_str(), &value, &value_len) &&
          value != nullptr && value_len > 0) {
        return std::wstring(static_cast<const wchar_t*>(value));
      }
    }
    return std::wstring();
  };

  std::wstring company = query(L"CompanyName");
  std::wstring product = query(L"ProductName");
  if (company.empty() || product.empty()) {
    return std::wstring();
  }
  return base + L"\\" + company + L"\\" + product +
         L"\\flutter_secure_storage.dat";
}

}  // namespace capsicum
