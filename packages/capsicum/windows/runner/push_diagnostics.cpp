#include "push_diagnostics.h"

#include <cstdlib>

namespace capsicum {

namespace {

// JSON 文字列リテラルにエスケープして書き出す（" と \ のみ。code / host は
// 制御文字を含まない想定）。
std::string JsonQuote(const std::string& s) {
  std::string out = "\"";
  for (char c : s) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
    }
    out.push_back(c);
  }
  out.push_back('"');
  return out;
}

// 観測上の「正常系」コード。これらは未消費の異常系コードを上書きしない
// （単一スロットゆえ、異常系が後続の正常系イベントに飲まれて Sentry の warning が
// 消えるのを防ぐ）。Dart 側 _flushWnsPushDiagnostics の benign 判定と揃えること。
bool IsBenignCode(const std::string& code) {
  return code == "bgtask.shown" || code == "bgtask.not_encrypted" ||
         code == "bgtask.not_raw";
}

// 自前で生成した flat オブジェクト（値は文字列 or 数値）を解く最小パーサ。
// ネスト無し・我々の出力のみを対象とする。
class FlatParser {
 public:
  explicit FlatParser(const std::string& s) : s_(s) {}

  bool Parse(PushDiagnostic* out) {
    SkipWs();
    if (!Expect('{')) return false;
    SkipWs();
    if (Peek() == '}') return false;  // 空オブジェクトはレコード無し扱い。
    bool has_code = false;
    while (true) {
      SkipWs();
      std::string key;
      if (!ParseString(&key)) return false;
      SkipWs();
      if (!Expect(':')) return false;
      SkipWs();
      if (key == "code") {
        if (!ParseString(&out->code)) return false;
        has_code = true;
      } else if (key == "host") {
        if (!ParseString(&out->host)) return false;
      } else if (key == "at_ms") {
        if (!ParseNumber(&out->at_ms)) return false;
      } else if (key == "count") {
        int64_t v = 0;
        if (!ParseNumber(&v)) return false;
        out->count = static_cast<int>(v);
      } else {
        // 未知キーは値を読み飛ばす（前方互換）。
        if (!SkipValue()) return false;
      }
      SkipWs();
      char c = Peek();
      if (c == ',') {
        ++i_;
        continue;
      }
      if (c == '}') {
        ++i_;
        break;
      }
      return false;
    }
    return has_code && !out->code.empty();
  }

 private:
  char Peek() const { return i_ < s_.size() ? s_[i_] : '\0'; }
  bool Expect(char c) {
    if (Peek() == c) {
      ++i_;
      return true;
    }
    return false;
  }
  void SkipWs() {
    while (i_ < s_.size() &&
           (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' ||
            s_[i_] == '\r')) {
      ++i_;
    }
  }
  bool ParseString(std::string* out) {
    if (Peek() != '"') return false;
    ++i_;
    out->clear();
    while (i_ < s_.size()) {
      char c = s_[i_++];
      if (c == '"') return true;
      if (c == '\\') {
        if (i_ >= s_.size()) return false;
        out->push_back(s_[i_++]);  // 我々の出力は " / \ のみエスケープ。
      } else {
        out->push_back(c);
      }
    }
    return false;
  }
  bool ParseNumber(int64_t* out) {
    size_t start = i_;
    if (Peek() == '-') ++i_;
    bool any = false;
    while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') {
      ++i_;
      any = true;
    }
    if (!any) return false;
    *out = std::strtoll(s_.substr(start, i_ - start).c_str(), nullptr, 10);
    return true;
  }
  bool SkipValue() {
    char c = Peek();
    if (c == '"') {
      std::string tmp;
      return ParseString(&tmp);
    }
    int64_t tmp = 0;
    return ParseNumber(&tmp);
  }

  const std::string& s_;
  size_t i_ = 0;
};

}  // namespace

std::string BuildPushDiagnosticJson(const std::string& prev_json,
                                    const std::string& code,
                                    const std::string& host, int64_t at_ms) {
  int count = 1;
  PushDiagnostic prev;
  const bool has_prev = ParsePushDiagnosticJson(prev_json, &prev);
  if (has_prev) {
    count = prev.count + 1;
  }
  // 未消費の異常系コードは後続の正常系イベントで上書きしない（warning が info に
  // 飲まれて消えるのを防ぐ）。それ以外は最新イベントを代表にする。
  std::string rep_code = code;
  std::string rep_host = host;
  int64_t rep_at_ms = at_ms;
  if (has_prev && IsBenignCode(code) && !IsBenignCode(prev.code)) {
    rep_code = prev.code;
    rep_host = prev.host;
    rep_at_ms = prev.at_ms;
  }
  std::string o = "{";
  o += "\"code\":" + JsonQuote(rep_code);
  o += ",\"at_ms\":" + std::to_string(rep_at_ms);
  o += ",\"count\":" + std::to_string(count);
  if (!rep_host.empty()) {
    o += ",\"host\":" + JsonQuote(rep_host);
  }
  o += "}";
  return o;
}

bool ParsePushDiagnosticJson(const std::string& json, PushDiagnostic* out) {
  if (json.empty()) return false;
  *out = PushDiagnostic();
  FlatParser parser(json);
  return parser.Parse(out);
}

}  // namespace capsicum
