#ifndef RUNNER_WEB_PUSH_PAYLOAD_H_
#define RUNNER_WEB_PUSH_PAYLOAD_H_

#include <string>

// 復号済み Web Push 平文（SNS サーバーの通知 JSON）から、通知表示に使う
// フィールドを取り出す (#474 フェーズ2)。macOS NSE の `PayloadParser`
// （NotificationService.swift）/ Dart の `PushMessageDispatcher.parsePayload`
// と同じ優先順位・同じ文面合成を C++ で再現する。Mastodon / Misskey
// notification / Misskey newChatMessage の 3 形式を扱う。
//
// runner は `_HAS_EXCEPTIONS=0`（例外無効）なので失敗は戻り値 (bool) で表す。
// Flutter / WinRT 非依存（WNS バックグラウンドタスクから再利用）。
namespace capsicum {

// 通知表示に使う抽出結果。文字列は「空 = 無し」を意味する。
struct ParsedPayload {
  // 通知種別。Mastodon: notification_type / Misskey: body.type /
  // chat: "newChatMessage"。空なら未取得（呼び出し側はサーバー title を使う）。
  std::string type;
  // Mastodon がサーバー側で組み立てた title（用語統一のため type があれば
  // そちらの表示ラベルを優先し、type 不在時のみ使う）。空なら無し。
  std::string title;
  // 表示本文（Misskey は構造体から合成する）。空なら fallback 文面のまま。
  std::string body;
  // SNS 側の通知 ID（起動中の二重通知 dedup 用）。Mastodon: notification_id /
  // Misskey: body.id。取れない形式では空。
  std::string notification_id;
  // Misskey newChatMessage の fromUser.id（タップで /chat/user/:id へ遷移する
  // 宛先解決用）。chat 以外は空。
  std::string user_id;
};

// 復号済み平文 JSON (UTF-8) をパースして `*out` に表示フィールドを格納する。
// Mastodon / Misskey notification / Misskey newChatMessage のいずれかとして
// 解釈できたら true。JSON 不正・未対応形式（オブジェクトでない / どの形式にも
// 当てはまらない）なら false。
bool ParsePushPayload(const std::string& plaintext_json, ParsedPayload* out);

}  // namespace capsicum

#endif  // RUNNER_WEB_PUSH_PAYLOAD_H_
