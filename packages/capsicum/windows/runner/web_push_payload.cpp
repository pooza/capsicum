#include "web_push_payload.h"

#include <cstdint>
#include <utility>
#include <vector>

namespace capsicum {

namespace {

// ---------------------------------------------------------------------------
// 最小 JSON 値ツリー + 再帰下降パーサ。
//
// SNS の push payload（Mastodon / Misskey）はネストしたオブジェクトを持つため、
// 鍵リーダーの flat string-map パーサでは足りず、value ツリーが要る。例外無効
// ビルドのため失敗は bool で返し、悪意ある入力に備えて再帰深さを制限する。
// 数値は精度落ちを避けるため raw テキストのまま保持する（notification_id が
// 64bit snowflake のことがある）。
// ---------------------------------------------------------------------------
struct JsonValue {
  enum class Type { Null, Bool, Number, String, Array, Object };
  Type type = Type::Null;
  bool bool_val = false;
  std::string str;  // String の値 / Number の raw テキスト。
  std::vector<JsonValue> arr;
  std::vector<std::pair<std::string, JsonValue>> members;

  bool IsString() const { return type == Type::String; }
  bool IsObject() const { return type == Type::Object; }
  bool IsNumber() const { return type == Type::Number; }
  bool IsBool() const { return type == Type::Bool; }

  const JsonValue* Find(const std::string& key) const {
    if (type != Type::Object) {
      return nullptr;
    }
    for (const auto& kv : members) {
      if (kv.first == key) {
        return &kv.second;
      }
    }
    return nullptr;
  }
};

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

class JsonParser {
 public:
  explicit JsonParser(const std::string& s) : s_(s) {}

  bool Parse(JsonValue* out) {
    SkipWs();
    if (!ParseValue(out, 0)) {
      return false;
    }
    SkipWs();
    return i_ == s_.size();  // 末尾に余分なトークンが無いこと。
  }

 private:
  static constexpr int kMaxDepth = 64;

  void SkipWs() {
    while (i_ < s_.size()) {
      char c = s_[i_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        ++i_;
      } else {
        break;
      }
    }
  }

  bool ParseHex4(size_t pos, uint32_t* out) {
    if (pos + 4 > s_.size()) {
      return false;
    }
    uint32_t value = 0;
    for (size_t k = 0; k < 4; ++k) {
      char c = s_[pos + k];
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

  bool ParseString(std::string* out) {
    if (i_ >= s_.size() || s_[i_] != '"') {
      return false;
    }
    ++i_;
    out->clear();
    while (i_ < s_.size()) {
      char c = s_[i_];
      if (c == '"') {
        ++i_;
        return true;
      }
      if (c == '\\') {
        ++i_;
        if (i_ >= s_.size()) {
          return false;
        }
        char e = s_[i_];
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
            if (!ParseHex4(i_ + 1, &cp)) {
              return false;
            }
            i_ += 4;
            if (cp >= 0xd800 && cp <= 0xdbff) {
              if (i_ + 2 < s_.size() && s_[i_ + 1] == '\\' && s_[i_ + 2] == 'u') {
                uint32_t low = 0;
                if (!ParseHex4(i_ + 3, &low)) {
                  return false;
                }
                if (low >= 0xdc00 && low <= 0xdfff) {
                  cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                  i_ += 6;
                }
              }
            }
            AppendUtf8(cp, out);
            break;
          }
          default:
            return false;
        }
        ++i_;
      } else {
        out->push_back(c);
        ++i_;
      }
    }
    return false;  // 閉じクォート無し。
  }

  bool ParseNumber(JsonValue* out) {
    size_t start = i_;
    if (i_ < s_.size() && s_[i_] == '-') {
      ++i_;
    }
    bool any_digit = false;
    while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') {
      ++i_;
      any_digit = true;
    }
    if (i_ < s_.size() && s_[i_] == '.') {
      ++i_;
      while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') {
        ++i_;
        any_digit = true;
      }
    }
    if (i_ < s_.size() && (s_[i_] == 'e' || s_[i_] == 'E')) {
      ++i_;
      if (i_ < s_.size() && (s_[i_] == '+' || s_[i_] == '-')) {
        ++i_;
      }
      bool exp_digit = false;
      while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') {
        ++i_;
        exp_digit = true;
      }
      if (!exp_digit) {
        return false;
      }
    }
    if (!any_digit) {
      return false;
    }
    out->type = JsonValue::Type::Number;
    out->str = s_.substr(start, i_ - start);
    return true;
  }

  bool ParseLiteral(const char* literal, size_t len) {
    if (i_ + len > s_.size()) {
      return false;
    }
    for (size_t k = 0; k < len; ++k) {
      if (s_[i_ + k] != literal[k]) {
        return false;
      }
    }
    i_ += len;
    return true;
  }

  bool ParseArray(JsonValue* out, int depth) {
    ++i_;  // '['
    out->type = JsonValue::Type::Array;
    SkipWs();
    if (i_ < s_.size() && s_[i_] == ']') {
      ++i_;
      return true;
    }
    while (i_ < s_.size()) {
      SkipWs();
      JsonValue element;
      if (!ParseValue(&element, depth + 1)) {
        return false;
      }
      out->arr.push_back(std::move(element));
      SkipWs();
      if (i_ >= s_.size()) {
        return false;
      }
      if (s_[i_] == ',') {
        ++i_;
        continue;
      }
      if (s_[i_] == ']') {
        ++i_;
        return true;
      }
      return false;
    }
    return false;
  }

  bool ParseObject(JsonValue* out, int depth) {
    ++i_;  // '{'
    out->type = JsonValue::Type::Object;
    SkipWs();
    if (i_ < s_.size() && s_[i_] == '}') {
      ++i_;
      return true;
    }
    while (i_ < s_.size()) {
      SkipWs();
      std::string key;
      if (!ParseString(&key)) {
        return false;
      }
      SkipWs();
      if (i_ >= s_.size() || s_[i_] != ':') {
        return false;
      }
      ++i_;
      SkipWs();
      JsonValue value;
      if (!ParseValue(&value, depth + 1)) {
        return false;
      }
      out->members.emplace_back(std::move(key), std::move(value));
      SkipWs();
      if (i_ >= s_.size()) {
        return false;
      }
      if (s_[i_] == ',') {
        ++i_;
        continue;
      }
      if (s_[i_] == '}') {
        ++i_;
        return true;
      }
      return false;
    }
    return false;
  }

  bool ParseValue(JsonValue* out, int depth) {
    if (depth > kMaxDepth) {
      return false;
    }
    if (i_ >= s_.size()) {
      return false;
    }
    char c = s_[i_];
    switch (c) {
      case '{':
        return ParseObject(out, depth);
      case '[':
        return ParseArray(out, depth);
      case '"':
        out->type = JsonValue::Type::String;
        return ParseString(&out->str);
      case 't':
        if (ParseLiteral("true", 4)) {
          out->type = JsonValue::Type::Bool;
          out->bool_val = true;
          return true;
        }
        return false;
      case 'f':
        if (ParseLiteral("false", 5)) {
          out->type = JsonValue::Type::Bool;
          out->bool_val = false;
          return true;
        }
        return false;
      case 'n':
        if (ParseLiteral("null", 4)) {
          out->type = JsonValue::Type::Null;
          return true;
        }
        return false;
      default:
        return ParseNumber(out);
    }
  }

  const std::string& s_;
  size_t i_ = 0;
};

// ---------------------------------------------------------------------------
// 文面合成（Dart `_synthesizeMisskeyBody` / `_synthesizeMisskeyChatBody` /
// `_stringId` と同じ仕様）。
// ---------------------------------------------------------------------------

// 表示文面の日本語リテラル。runner は `/utf-8` を付けないため、実行文字セット
// 依存を避けて UTF-8 バイトを \xHH で直接表記する（中身は全て ASCII バイト列に
// なるのでソース／実行文字セットに依存せず正しい UTF-8 を出力する）。各定数の
// 末尾コメントが可読形。macOS / Dart の文面と一致させること。
const char kLabelImage[] = "\x5b\xe7\x94\xbb\xe5\x83\x8f\x5d";        // [画像]
const char kLabelVideo[] = "\x5b\xe5\x8b\x95\xe7\x94\xbb\x5d";        // [動画]
const char kLabelAudio[] = "\x5b\xe9\x9f\xb3\xe5\xa3\xb0\x5d";        // [音声]
const char kLabelFile[] =
    "\x5b\xe3\x83\x95\xe3\x82\xa1\xe3\x82\xa4\xe3\x83\xab\x5d";        // [ファイル]
const char kGa[] = "\x20\xe3\x81\x8c\x20";                            // " が "
const char kDeReaction[] =
    "\x20\xe3\x81\xa7\xe3\x83\xaa\xe3\x82\xa2\xe3\x82\xaf\xe3\x82\xb7"
    "\xe3\x83\xa7\xe3\x83\xb3";                                       // " でリアクション"
const char kFollowed[] =
    "\x20\xe3\x81\xab\xe3\x83\x95\xe3\x82\xa9\xe3\x83\xad\xe3\x83\xbc"
    "\xe3\x81\x95\xe3\x82\x8c\xe3\x81\xbe\xe3\x81\x97\xe3\x81\x9f";    // " にフォローされました"

std::string TrimAsciiWs(const std::string& s) {
  size_t start = 0;
  size_t end = s.size();
  auto is_ws = [](char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' ||
           c == '\v';
  };
  while (start < end && is_ws(s[start])) {
    ++start;
  }
  while (end > start && is_ws(s[end - 1])) {
    --end;
  }
  return s.substr(start, end - start);
}

// JSON 値が文字列ならその値を、無ければ空文字列を返す。
std::string StringOr(const JsonValue* v) {
  return (v != nullptr && v->IsString()) ? v->str : std::string();
}

// 通知 ID を文字列に均す。string はそのまま、number は raw テキスト、
// bool / その他は空（Dart `_stringId` と同じ）。
std::string StringId(const JsonValue* v) {
  if (v == nullptr) {
    return std::string();
  }
  if (v->IsString()) {
    return v->str;  // 空文字列ならそのまま空（呼び出し側で「無し」扱い）。
  }
  if (v->IsNumber()) {
    return v->str;
  }
  return std::string();  // bool / null / 構造体は ID 不可。
}

// user / fromUser オブジェクトから actor 表示名を作る。
// 表示名（trim 後非空）があればそれ、無ければ "@username"、いずれも無ければ空。
std::string ResolveActor(const JsonValue* user) {
  if (user == nullptr || !user->IsObject()) {
    return std::string();
  }
  std::string display = TrimAsciiWs(StringOr(user->Find("name")));
  if (!display.empty()) {
    return display;
  }
  std::string username = StringOr(user->Find("username"));
  if (!username.empty()) {
    return "@" + username;
  }
  return std::string();
}

std::string SynthesizeMisskeyBody(const JsonValue& body) {
  const JsonValue* note = body.Find("note");
  std::string note_text;
  if (note != nullptr && note->IsObject()) {
    note_text = StringOr(note->Find("text"));
  }
  if (!note_text.empty()) {
    return note_text;
  }
  std::string actor = ResolveActor(body.Find("user"));
  std::string type = StringOr(body.Find("type"));
  std::string reaction = StringOr(body.Find("reaction"));
  if (type == "reaction" && !reaction.empty()) {
    return actor.empty() ? reaction : (actor + kGa + reaction + kDeReaction);
  }
  if (type == "follow" && !actor.empty()) {
    return actor + kFollowed;
  }
  return actor;
}

std::string SynthesizeMisskeyChatBody(const JsonValue& body) {
  std::string text = StringOr(body.Find("text"));
  std::string file_mime;
  const JsonValue* file = body.Find("file");
  if (file != nullptr && file->IsObject()) {
    file_mime = StringOr(file->Find("type"));
  }
  std::string actor = ResolveActor(body.Find("fromUser"));

  std::string content;
  if (!text.empty()) {
    content = text;
  } else if (!file_mime.empty()) {
    if (file_mime.rfind("image/", 0) == 0) {
      content = kLabelImage;
    } else if (file_mime.rfind("video/", 0) == 0) {
      content = kLabelVideo;
    } else if (file_mime.rfind("audio/", 0) == 0) {
      content = kLabelAudio;
    } else {
      content = kLabelFile;
    }
  }

  if (actor.empty()) {
    return content;
  }
  return content.empty() ? actor : (actor + ": " + content);
}

}  // namespace

bool ParsePushPayload(const std::string& plaintext_json, ParsedPayload* out) {
  JsonValue root;
  JsonParser parser(plaintext_json);
  if (!parser.Parse(&root) || !root.IsObject()) {
    return false;
  }

  // Mastodon: top-level に title / body / notification_type のいずれか文字列。
  const JsonValue* m_title = root.Find("title");
  const JsonValue* m_body = root.Find("body");
  const JsonValue* m_type = root.Find("notification_type");
  if ((m_title != nullptr && m_title->IsString()) ||
      (m_body != nullptr && m_body->IsString()) ||
      (m_type != nullptr && m_type->IsString())) {
    out->title = StringOr(m_title);
    out->body = StringOr(m_body);
    out->type = StringOr(m_type);
    out->notification_id = StringId(root.Find("notification_id"));
    return true;
  }

  const JsonValue* top_type = root.Find("type");
  const std::string top = StringOr(top_type);

  // Misskey: {type:'notification', body:{type,user,note,reaction,...}}
  if (top == "notification") {
    const JsonValue* inner = root.Find("body");
    if (inner != nullptr && inner->IsObject()) {
      out->body = SynthesizeMisskeyBody(*inner);
      out->type = StringOr(inner->Find("type"));
      out->notification_id = StringId(inner->Find("id"));
      return true;
    }
  }

  // Misskey 新 chat: {type:'newChatMessage', body:<ChatMessage>} (#248)
  if (top == "newChatMessage") {
    const JsonValue* inner = root.Find("body");
    if (inner != nullptr && inner->IsObject()) {
      out->body = SynthesizeMisskeyChatBody(*inner);
      out->type = "newChatMessage";
      const JsonValue* from_user = inner->Find("fromUser");
      if (from_user != nullptr && from_user->IsObject()) {
        out->user_id = StringOr(from_user->Find("id"));
      } else {
        out->user_id = StringOr(inner->Find("fromUserId"));
      }
      out->notification_id = StringId(inner->Find("id"));
      return true;
    }
  }

  return false;
}

}  // namespace capsicum
