// web_push_payload.cpp のスタンドアロン単体テスト (#474 フェーズ2)。
//
// 復号済み平文 JSON → 表示フィールド抽出を、macOS NSE `PayloadParser` / Dart
// `PushMessageDispatcher.parsePayload` と同じ結果になるか検証する。Mastodon /
// Misskey notification / Misskey newChatMessage の各分岐・文面合成・notification
// _id の string/number 均し・\uXXXX デコード・不正系を見る。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 web_push_payload_test.cpp web_push_payload.cpp ^
//      web_push_text_util.cpp
//   .\web_push_payload_test.exe
//
// 期待値中の日本語も本体同様 \xHH（UTF-8）で表記し、実行文字セットに依存しない。

#include <cstdio>
#include <string>

#include "web_push_payload.h"

namespace {

int g_failures = 0;

void Check(bool cond, const char* name) {
  if (cond) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s\n", name);
    ++g_failures;
  }
}

void CheckEq(const std::string& got, const std::string& want, const char* name) {
  if (got == want) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s (got=\"%s\" want=\"%s\")\n", name, got.c_str(),
                want.c_str());
    ++g_failures;
  }
}

// 期待 UTF-8（可読形はコメント）。
const char kLabelImage[] = "\x5b\xe7\x94\xbb\xe5\x83\x8f\x5d";  // [画像]
const char kGa[] = "\x20\xe3\x81\x8c\x20";                      // " が "
const char kDeReaction[] =
    "\x20\xe3\x81\xa7\xe3\x83\xaa\xe3\x82\xa2\xe3\x82\xaf\xe3\x82\xb7"
    "\xe3\x83\xa7\xe3\x83\xb3";  // " でリアクション"
const char kFollowed[] =
    "\x20\xe3\x81\xab\xe3\x83\x95\xe3\x82\xa9\xe3\x83\xad\xe3\x83\xbc"
    "\xe3\x81\x95\xe3\x82\x8c\xe3\x81\xbe\xe3\x81\x97\xe3\x81\x9f";  // " にフォローされました"
const char kAiu[] = "\xe3\x81\x82\xe3\x81\x84";  // "あい"

}  // namespace

int main() {
  std::printf("WebPushPayload (parser) tests\n");
  using capsicum::ParsedPayload;
  using capsicum::ParsePushPayload;

  // 1) Mastodon: title/body/type + 数値 notification_id。
  {
    ParsedPayload p;
    bool ok = ParsePushPayload(
        "{\"title\":\"T\",\"body\":\"B\",\"notification_type\":\"reblog\","
        "\"notification_id\":12345}",
        &p);
    Check(ok, "mastodon: 認識");
    CheckEq(p.type, "reblog", "mastodon: type");
    CheckEq(p.title, "T", "mastodon: title");
    CheckEq(p.body, "B", "mastodon: body");
    CheckEq(p.notification_id, "12345", "mastodon: 数値 id を文字列化");
  }

  // 2) Mastodon: 文字列 notification_id。
  {
    ParsedPayload p;
    ParsePushPayload("{\"title\":\"T\",\"notification_id\":\"abc\"}", &p);
    CheckEq(p.notification_id, "abc", "mastodon: 文字列 id");
  }

  // 3) Mastodon: body だけでも認識する。
  {
    ParsedPayload p;
    bool ok = ParsePushPayload("{\"body\":\"hello\"}", &p);
    Check(ok && p.body == "hello" && p.type.empty() && p.title.empty(),
          "mastodon: body のみ");
  }

  // 4) Misskey notification: note.text を本文にする。
  {
    ParsedPayload p;
    bool ok = ParsePushPayload(
        "{\"type\":\"notification\",\"body\":{\"type\":\"mention\","
        "\"id\":\"n1\",\"note\":{\"text\":\"hi there\"}}}",
        &p);
    Check(ok, "misskey notification: 認識");
    CheckEq(p.body, "hi there", "misskey: note.text");
    CheckEq(p.type, "mention", "misskey: inner type");
    CheckEq(p.notification_id, "n1", "misskey: inner id");
  }

  // 5) Misskey reaction（表示名あり）。
  {
    ParsedPayload p;
    ParsePushPayload(
        "{\"type\":\"notification\",\"body\":{\"type\":\"reaction\","
        "\"id\":\"n2\",\"reaction\":\":smile:\","
        "\"user\":{\"name\":\"Alice\",\"username\":\"alice\"}}}",
        &p);
    CheckEq(p.body, std::string("Alice") + kGa + ":smile:" + kDeReaction,
            "misskey: reaction 文面（表示名）");
  }

  // 6) Misskey reaction（表示名なし → @username）。
  {
    ParsedPayload p;
    ParsePushPayload(
        "{\"type\":\"notification\",\"body\":{\"type\":\"reaction\","
        "\"id\":\"n2b\",\"reaction\":\":x:\","
        "\"user\":{\"username\":\"bob\"}}}",
        &p);
    CheckEq(p.body, std::string("@bob") + kGa + ":x:" + kDeReaction,
            "misskey: reaction 文面（@username）");
  }

  // 7) Misskey follow。
  {
    ParsedPayload p;
    ParsePushPayload(
        "{\"type\":\"notification\",\"body\":{\"type\":\"follow\","
        "\"id\":\"n3\",\"user\":{\"name\":\"Carol\"}}}",
        &p);
    CheckEq(p.body, std::string("Carol") + kFollowed, "misskey: follow 文面");
  }

  // 8) Misskey: 既知でない type は actor のみ。
  {
    ParsedPayload p;
    ParsePushPayload(
        "{\"type\":\"notification\",\"body\":{\"type\":\"pollEnded\","
        "\"id\":\"n4\",\"user\":{\"name\":\"Dave\"}}}",
        &p);
    CheckEq(p.body, "Dave", "misskey: actor のみ");
    CheckEq(p.type, "pollEnded", "misskey: 未知 type も保持");
  }

  // 9) Misskey chat: text あり、fromUser.id を user_id に。
  {
    ParsedPayload p;
    bool ok = ParsePushPayload(
        "{\"type\":\"newChatMessage\",\"body\":{\"id\":\"c1\",\"text\":\"yo\","
        "\"fromUser\":{\"id\":\"u1\",\"username\":\"eve\"}}}",
        &p);
    Check(ok, "misskey chat: 認識");
    CheckEq(p.body, "@eve: yo", "chat: actor: text");
    CheckEq(p.type, "newChatMessage", "chat: type");
    CheckEq(p.user_id, "u1", "chat: fromUser.id");
    CheckEq(p.notification_id, "c1", "chat: id");
  }

  // 10) Misskey chat: text 無し・画像添付。
  {
    ParsedPayload p;
    ParsePushPayload(
        "{\"type\":\"newChatMessage\",\"body\":{\"id\":\"c2\","
        "\"file\":{\"type\":\"image/png\"},\"fromUser\":{\"name\":\"Fae\"}}}",
        &p);
    CheckEq(p.body, std::string("Fae: ") + kLabelImage, "chat: 画像ラベル");
  }

  // 11) Misskey chat: fromUser 無し → fromUserId を user_id に、actor 無しで本文のみ。
  {
    ParsedPayload p;
    ParsePushPayload(
        "{\"type\":\"newChatMessage\",\"body\":{\"id\":\"c3\",\"text\":\"hey\","
        "\"fromUserId\":\"u3\"}}",
        &p);
    CheckEq(p.user_id, "u3", "chat: fromUserId フォールバック");
    CheckEq(p.body, "hey", "chat: actor 無しは本文のみ");
  }

  // 12) どの形式でもない → false。
  {
    ParsedPayload p;
    Check(!ParsePushPayload("{\"foo\":\"bar\"}", &p), "未対応形式は false");
  }

  // 13) オブジェクトでない → false。
  {
    ParsedPayload p;
    Check(!ParsePushPayload("[1,2,3]", &p), "配列は false");
    Check(!ParsePushPayload("\"just a string\"", &p), "文字列単体は false");
  }

  // 14) 壊れた JSON → false。
  {
    ParsedPayload p;
    Check(!ParsePushPayload("{\"title\":", &p), "途中で切れた JSON は false");
    Check(!ParsePushPayload("{bad}", &p), "不正トークンは false");
    Check(!ParsePushPayload("{\"a\":\"b\"} trailing", &p),
          "末尾に余分があれば false");
  }

  // 15) title/body/type がいずれも文字列でない → mastodon 不成立で false。
  {
    ParsedPayload p;
    Check(!ParsePushPayload("{\"notification_type\":123,\"x\":\"y\"}", &p),
          "type が数値のみは mastodon 不成立");
  }

  // 16) \uXXXX エスケープを UTF-8 にデコードする。
  {
    ParsedPayload p;
    ParsePushPayload("{\"body\":\"\\u3042\\u3044\"}", &p);
    CheckEq(p.body, kAiu, "\\uXXXX を UTF-8 にデコード");
  }

  // 17) type=notification だが body が object でも文字列でもない（数値）→ false。
  //     （body が文字列だと Dart/macOS と同じく Mastodon 優先で認識される。
  //      ここは Misskey 経路で body が object でないケースの fall-through を見る）
  {
    ParsedPayload p;
    Check(!ParsePushPayload("{\"type\":\"notification\",\"body\":123}", &p),
          "notification で body 非 object は false");
  }

  // 18) 64bit snowflake の notification_id を精度落ちなく保持する。
  {
    ParsedPayload p;
    ParsePushPayload(
        "{\"title\":\"T\",\"notification_id\":113936715822339072}", &p);
    CheckEq(p.notification_id, "113936715822339072",
            "snowflake id を厳密に保持");
  }

  if (g_failures == 0) {
    std::printf("ALL PASS\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
