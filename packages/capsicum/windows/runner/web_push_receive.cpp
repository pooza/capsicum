#include "web_push_receive.h"

#include <cstdint>
#include <map>
#include <vector>

#include "web_push_decrypt.h"
#include "web_push_key_reader.h"
#include "web_push_payload.h"

namespace capsicum {

namespace {

// base64url / 標準 base64 の両対応デコーダ（パディング無視）。relay は
// base64url で送るが、標準 base64 で来ても落とさないよう `+/` も受ける。
bool Base64Decode(const std::string& in, std::vector<uint8_t>* out) {
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
    } else if (c == '-' || c == '+') {
      value = 62;
    } else if (c == '_' || c == '/') {
      value = 63;
    } else if (c == '=') {
      continue;
    } else {
      return false;
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

// 値がすべて文字列の JSON オブジェクト `{"k":"v",...}` をパースする
// （エンベロープは flat な String→String）。エスケープ（\" \\ \/ \b\f\n\r\t
// \uXXXX）を解く最小実装。
bool ParseFlatObject(const std::string& s,
                     std::map<std::string, std::string>* out) {
  out->clear();
  size_t i = 0;
  auto skip_ws = [&]() {
    while (i < s.size() &&
           (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) {
      ++i;
    }
  };
  auto parse_hex4 = [&](size_t pos, uint32_t* cp) -> bool {
    if (pos + 4 > s.size()) return false;
    uint32_t v = 0;
    for (size_t k = 0; k < 4; ++k) {
      char c = s[pos + k];
      v <<= 4;
      if (c >= '0' && c <= '9') {
        v |= static_cast<uint32_t>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        v |= static_cast<uint32_t>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        v |= static_cast<uint32_t>(c - 'A' + 10);
      } else {
        return false;
      }
    }
    *cp = v;
    return true;
  };
  auto append_utf8 = [](uint32_t cp, std::string* o) {
    if (cp <= 0x7f) {
      o->push_back(static_cast<char>(cp));
    } else if (cp <= 0x7ff) {
      o->push_back(static_cast<char>(0xc0 | (cp >> 6)));
      o->push_back(static_cast<char>(0x80 | (cp & 0x3f)));
    } else if (cp <= 0xffff) {
      o->push_back(static_cast<char>(0xe0 | (cp >> 12)));
      o->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
      o->push_back(static_cast<char>(0x80 | (cp & 0x3f)));
    } else {
      o->push_back(static_cast<char>(0xf0 | (cp >> 18)));
      o->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3f)));
      o->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
      o->push_back(static_cast<char>(0x80 | (cp & 0x3f)));
    }
  };
  auto parse_string = [&](std::string* result) -> bool {
    if (i >= s.size() || s[i] != '"') return false;
    ++i;
    result->clear();
    while (i < s.size()) {
      char c = s[i];
      if (c == '"') {
        ++i;
        return true;
      }
      if (c == '\\') {
        ++i;
        if (i >= s.size()) return false;
        char e = s[i];
        switch (e) {
          case '"': result->push_back('"'); break;
          case '\\': result->push_back('\\'); break;
          case '/': result->push_back('/'); break;
          case 'b': result->push_back('\b'); break;
          case 'f': result->push_back('\f'); break;
          case 'n': result->push_back('\n'); break;
          case 'r': result->push_back('\r'); break;
          case 't': result->push_back('\t'); break;
          case 'u': {
            uint32_t cp = 0;
            if (!parse_hex4(i + 1, &cp)) return false;
            i += 4;
            if (cp >= 0xd800 && cp <= 0xdbff && i + 2 < s.size() &&
                s[i + 1] == '\\' && s[i + 2] == 'u') {
              uint32_t low = 0;
              if (!parse_hex4(i + 3, &low)) return false;
              if (low >= 0xdc00 && low <= 0xdfff) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                i += 6;
              }
            }
            append_utf8(cp, result);
            break;
          }
          default:
            return false;
        }
        ++i;
      } else {
        result->push_back(c);
        ++i;
      }
    }
    return false;
  };

  skip_ws();
  if (i >= s.size() || s[i] != '{') return false;
  ++i;
  skip_ws();
  if (i < s.size() && s[i] == '}') return true;
  while (i < s.size()) {
    skip_ws();
    std::string key;
    if (!parse_string(&key)) return false;
    skip_ws();
    if (i >= s.size() || s[i] != ':') return false;
    ++i;
    skip_ws();
    std::string value;
    if (!parse_string(&value)) return false;  // 値が文字列でないエンベロープは非対応。
    (*out)[key] = value;
    skip_ws();
    if (i >= s.size()) return false;
    if (s[i] == ',') {
      ++i;
      continue;
    }
    if (s[i] == '}') return true;
    return false;
  }
  return false;
}

std::string MapGet(const std::map<std::string, std::string>& m,
                   const char* key) {
  auto it = m.find(key);
  return it == m.end() ? std::string() : it->second;
}

}  // namespace

namespace {

// 鍵の取得元（.dat ファイル or 平文鍵セット JSON）だけを差し替えて共通化する。
// dat_file_path != nullptr なら flutter_secure_storage.dat を DPAPI 復号して引く
// （in-process / FullTrust）。keyset_map_json != nullptr なら平文の鍵セット JSON
// から引く（AppContainer のバックグラウンドタスク、#474 フェーズ C / Option A）。
bool HandleWnsRawPayloadImpl(const std::string& raw_payload,
                             const std::wstring* dat_file_path,
                             const std::string* keyset_map_json,
                             PushDisplay* out, std::string* error) {
  auto fail = [&](const char* message) {
    if (error != nullptr) *error = message;
    return false;
  };

  std::map<std::string, std::string> envelope;
  if (!ParseFlatObject(raw_payload, &envelope)) {
    return fail("invalid envelope");
  }
  const std::string account = MapGet(envelope, "account");
  if (account.empty()) {
    return fail("missing account");
  }
  const std::string encoding = MapGet(envelope, "encoding");
  const std::string body_b64 = MapGet(envelope, "body");
  // announcement push 等は body / encoding を持たない。暗号化通知だけここで扱い、
  // それ以外は呼び出し側に委ねる。
  if (body_b64.empty() || encoding != "aes128gcm") {
    return fail("not an encrypted notification");
  }

  std::vector<uint8_t> body;
  if (!Base64Decode(body_b64, &body)) {
    return fail("invalid body base64url");
  }

  PushKeys keys;
  std::string key_error;
  const bool keys_ok =
      dat_file_path != nullptr
          ? ReadPushKeys(*dat_file_path, account, &keys, &key_error)
          : ReadPushKeysFromKeysetJson(*keyset_map_json, account, &keys,
                                       &key_error);
  if (!keys_ok) {
    return fail("no push keys");
  }

  std::vector<uint8_t> plaintext;
  if (!DecryptWebPushAes128Gcm(body, keys.private_d, keys.p256dh, keys.auth,
                               &plaintext, nullptr)) {
    return fail("decryption failed");
  }

  ParsedPayload parsed;
  if (!ParsePushPayload(std::string(plaintext.begin(), plaintext.end()),
                        &parsed)) {
    return fail("payload parse failed");
  }

  out->account = account;
  out->title = parsed.title;
  out->body = parsed.body;
  out->type = parsed.type;
  out->notification_id = parsed.notification_id;
  out->user_id = parsed.user_id;
  return true;
}

}  // namespace

bool HandleWnsRawPayload(const std::string& raw_payload,
                         const std::wstring& dat_file_path, PushDisplay* out,
                         std::string* error) {
  return HandleWnsRawPayloadImpl(raw_payload, &dat_file_path, nullptr, out,
                                 error);
}

bool HandleWnsRawPayloadFromKeysetJson(const std::string& raw_payload,
                                       const std::string& keyset_map_json,
                                       PushDisplay* out, std::string* error) {
  return HandleWnsRawPayloadImpl(raw_payload, nullptr, &keyset_map_json, out,
                                 error);
}

}  // namespace capsicum
