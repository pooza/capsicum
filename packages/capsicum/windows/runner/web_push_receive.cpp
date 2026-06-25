#include "web_push_receive.h"

#include <cstdint>
#include <map>
#include <vector>

#include "notification_type_label.h"
#include "web_push_decrypt.h"
#include "web_push_key_reader.h"
#include "web_push_payload.h"
#include "web_push_text_util.h"

namespace capsicum {

namespace {

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
            if (!ParseHex4(s, i + 1, &cp)) return false;
            i += 4;
            if (cp >= 0xd800 && cp <= 0xdbff && i + 2 < s.size() &&
                s[i + 1] == '\\' && s[i + 2] == 'u') {
              uint32_t low = 0;
              if (!ParseHex4(s, i + 3, &low)) return false;
              if (low >= 0xdc00 && low <= 0xdfff) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                i += 6;
              }
            }
            AppendUtf8(cp, result);
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
  if (body_b64.empty() || encoding.empty()) {
    return fail("not an encrypted notification");
  }
  // 本体も encoding もあるが aes128gcm 以外（レガシー aesgcm 等）は、
  // iOS / Android / macOS が扱える暗号化 push を Windows だけ静かに捨てている
  // 可能性がある。announcement（body / encoding 無し）と区別できる別エラーに
  // して観測へ載せる (#765)。プリセット 5 サーバーは aes128gcm のため通常は
  // 起きない。
  if (encoding != "aes128gcm") {
    return fail("unsupported encoding");
  }

  std::vector<uint8_t> body;
  // relay は base64url で送るが、標準 base64 で来ても落とさないよう '+' / '/'
  // も受ける。
  if (!Base64Decode(body_b64, &body, /*accept_standard=*/true)) {
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
  // 表示 title を統一ラベルで解決する (#474 空タイトル修正)。Misskey は
  // payload に title を持たず（type だけ）、Mastodon もサーバー生成 title は
  // 表記揺れがあるため、type→ラベル変換を優先する。macOS NSE と同じ優先順位。
  out->title = ResolveDisplayTitle(parsed.type, parsed.title);
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
