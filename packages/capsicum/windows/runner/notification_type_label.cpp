#include "notification_type_label.h"

namespace capsicum {

namespace {

// 表示ラベルの日本語リテラル。runner は `/utf-8` を付けないため、実行文字セット
// 依存を避けて UTF-8 バイトを \xHH で直接表記する（中身は ASCII バイト列なので
// ソース／実行文字セットに依存せず正しい UTF-8 を出力する）。各定数末尾の
// コメントが可読形。macOS NotificationTypeLabel.swift / Dart の
// notificationTypeDisplay と文言を一致させること。
const char kMention[] =
    "\xe3\x83\xa1\xe3\x83\xb3\xe3\x82\xb7\xe3\x83\xa7\xe3\x83\xb3";  // メンション
const char kFavourite[] =
    "\xe3\x81\x8a\xe6\xb0\x97\xe3\x81\xab\xe5\x85\xa5\xe3\x82\x8a";  // お気に入り
const char kFollow[] =
    "\xe3\x83\x95\xe3\x82\xa9\xe3\x83\xad\xe3\x83\xbc";  // フォロー
const char kFollowRequest[] =
    "\xe3\x83\x95\xe3\x82\xa9\xe3\x83\xad\xe3\x83\xbc\xe3\x83\xaa\xe3\x82\xaf"
    "\xe3\x82\xa8\xe3\x82\xb9\xe3\x83\x88";  // フォローリクエスト
const char kReaction[] =
    "\xe3\x83\xaa\xe3\x82\xa2\xe3\x82\xaf\xe3\x82\xb7\xe3\x83\xa7"
    "\xe3\x83\xb3";  // リアクション
const char kPollEnded[] =
    "\xe3\x82\xa2\xe3\x83\xb3\xe3\x82\xb1\xe3\x83\xbc\xe3\x83\x88\xe7\xb5\x82"
    "\xe4\xba\x86";  // アンケート終了
const char kUpdateSuffix[] =
    "\xe3\x82\x92\xe7\xb7\xa8\xe9\x9b\x86";  // 〜を編集
const char kLogin[] =
    "\xe3\x83\xad\xe3\x82\xb0\xe3\x82\xa4\xe3\x83\xb3";  // ログイン
const char kCreateToken[] =
    "\xe3\x82\xa2\xe3\x82\xaf\xe3\x82\xbb\xe3\x82\xb9\xe3\x83\x88\xe3\x83\xbc"
    "\xe3\x82\xaf\xe3\x83\xb3\xe4\xbd\x9c\xe6\x88\x90";  // アクセストークン作成
const char kGeneric[] = "\xe9\x80\x9a\xe7\x9f\xa5";  // 通知

}  // namespace

const char kDefaultReblogLabel[] =
    "\xe3\x83\x96\xe3\x83\xbc\xe3\x82\xb9\xe3\x83\x88";  // ブースト
const char kDefaultPostLabel[] = "\xe6\x8a\x95\xe7\xa8\xbf";  // 投稿

std::string NotificationTypeDisplayLabel(const std::string& type,
                                         const std::string& reblog_label,
                                         const std::string& post_label) {
  if (type == "mention" || type == "reply" || type == "quote") {
    return kMention;
  }
  if (type == "reblog" || type == "renote") {
    return reblog_label;
  }
  if (type == "favourite") {
    return kFavourite;
  }
  if (type == "follow") {
    return kFollow;
  }
  if (type == "follow_request" || type == "receiveFollowRequest") {
    return kFollowRequest;
  }
  if (type == "reaction") {
    return kReaction;
  }
  if (type == "poll" || type == "pollEnded") {
    return kPollEnded;
  }
  if (type == "update") {
    return post_label + kUpdateSuffix;
  }
  if (type == "login") {
    return kLogin;
  }
  if (type == "create_token") {
    return kCreateToken;
  }
  return kGeneric;
}

std::string ResolveDisplayTitle(const std::string& type,
                                const std::string& server_title) {
  if (!type.empty()) {
    return NotificationTypeDisplayLabel(type, kDefaultReblogLabel,
                                        kDefaultPostLabel);
  }
  if (!server_title.empty()) {
    return server_title;
  }
  return kGeneric;
}

}  // namespace capsicum
