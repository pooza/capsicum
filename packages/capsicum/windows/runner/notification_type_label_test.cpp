// notification_type_label.cpp のスタンドアロン単体テスト (#474 空タイトル修正)。
//
// type→ラベル変換と、表示 title 解決の優先順位（type 優先 → サーバー title →
// 汎用 "通知"）を検証する。Misskey の payload は title を持たず type だけのため、
// 「空タイトルになっていた」回帰の防止が主目的。文言は macOS
// NotificationTypeLabel.swift / Dart notificationTypeDisplay と一致させること。
//
// ビルド & 実行（VS Developer 環境）:
//   cl /EHsc /std:c++17 notification_type_label_test.cpp notification_type_label.cpp

#include <cstdio>
#include <string>

#include "notification_type_label.h"

namespace {

int g_failures = 0;

void CheckEq(const std::string& got, const std::string& want,
             const char* name) {
  if (got == want) {
    std::printf("  ok   - %s\n", name);
  } else {
    std::printf("  FAIL - %s (got=\"%s\" want=\"%s\")\n", name, got.c_str(),
                want.c_str());
    ++g_failures;
  }
}

}  // namespace

int main() {
  std::printf("NotificationTypeLabel tests\n");
  using capsicum::kDefaultPostLabel;
  using capsicum::kDefaultReblogLabel;
  using capsicum::NotificationTypeDisplayLabel;
  using capsicum::ResolveDisplayTitle;

  const std::string reblog = kDefaultReblogLabel;  // ブースト
  const std::string post = kDefaultPostLabel;      // 投稿

  // UTF-8 の期待値（\xHH 直書き、末尾コメントが可読形）。
  const std::string kMention =
      "\xe3\x83\xa1\xe3\x83\xb3\xe3\x82\xb7\xe3\x83\xa7\xe3\x83\xb3";  // メンション
  const std::string kReaction =
      "\xe3\x83\xaa\xe3\x82\xa2\xe3\x82\xaf\xe3\x82\xb7\xe3\x83\xa7"
      "\xe3\x83\xb3";  // リアクション
  const std::string kFollow =
      "\xe3\x83\x95\xe3\x82\xa9\xe3\x83\xad\xe3\x83\xbc";  // フォロー
  const std::string kGeneric = "\xe9\x80\x9a\xe7\x9f\xa5";  // 通知
  const std::string kChatMessage =
      "\xe3\x83\xa1\xe3\x83\x83\xe3\x82\xbb\xe3\x83\xbc\xe3\x82\xb8";  // メッセージ
  const std::string kEditSuffix =
      "\xe3\x82\x92\xe7\xb7\xa8\xe9\x9b\x86";  // 〜を編集

  // 1) Mastodon / Misskey 共通の type マッピング。
  CheckEq(NotificationTypeDisplayLabel("mention", reblog, post), kMention,
          "mention → メンション");
  CheckEq(NotificationTypeDisplayLabel("reply", reblog, post), kMention,
          "reply → メンション");
  CheckEq(NotificationTypeDisplayLabel("reaction", reblog, post), kReaction,
          "reaction → リアクション");
  CheckEq(NotificationTypeDisplayLabel("follow", reblog, post), kFollow,
          "follow → フォロー");

  // 2) reblog / renote は注入ラベル、update は post ラベル + 接尾辞。
  CheckEq(NotificationTypeDisplayLabel("reblog", reblog, post), reblog,
          "reblog → 注入 reblog ラベル");
  CheckEq(NotificationTypeDisplayLabel("renote", reblog, post), reblog,
          "renote → 注入 reblog ラベル");
  CheckEq(NotificationTypeDisplayLabel("update", reblog, post),
          post + kEditSuffix, "update → 投稿を編集");

  // 3) Misskey 新 chat の Web Push type はメッセージに寄せる (#765)。
  CheckEq(NotificationTypeDisplayLabel("newChatMessage", reblog, post),
          kChatMessage, "newChatMessage → メッセージ");

  // 4) 未知 type / 空 type は汎用 "通知"。
  CheckEq(NotificationTypeDisplayLabel("totally_unknown", reblog, post),
          kGeneric, "未対応 type → 通知");
  CheckEq(NotificationTypeDisplayLabel("", reblog, post), kGeneric,
          "空 type → 通知");

  // 4) title 解決の優先順位。server title は MSVC のソース文字セット依存を
  //    避けるため ASCII を使う（日本語リテラルは \xHH の期待値側だけで使う）。
  CheckEq(ResolveDisplayTitle("reaction", ""), kReaction,
          "type あり: type 優先（Misskey の空 title でもラベルが出る）");
  CheckEq(ResolveDisplayTitle("reblog", "server-title"), reblog,
          "type あり: サーバー title より type ラベルを優先");
  CheckEq(ResolveDisplayTitle("", "server-title"), "server-title",
          "type 無し: サーバー title を使う");
  CheckEq(ResolveDisplayTitle("", ""), kGeneric,
          "type も title も無し: 汎用 通知（空タイトルにしない）");

  if (g_failures == 0) {
    std::printf("ALL PASS\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
