#ifndef RUNNER_NOTIFICATION_TYPE_LABEL_H_
#define RUNNER_NOTIFICATION_TYPE_LABEL_H_

#include <string>

// 通知種別 (notification_type / Misskey body.type) から capsicum 規定の
// 表示ラベルを組む (#474 空タイトル修正)。macOS NSE の
// NotificationTypeLabel.swift / Dart の notificationTypeDisplay と同じ対応表で、
// Mastodon サーバー生成 title の表記揺れを吸収して用語を統一する。
//
// WNS raw 受信は in-process（起動中）でも out-of-process バックグラウンドタスク
// （完全終了中・AppContainer）でも、トースト表示前にこの関数で title を解決する。
// Flutter / WinRT 非依存（純粋な文字列 I/F）。runner は `_HAS_EXCEPTIONS=0`。
namespace capsicum {

// reblog / post ラベルの既定値。サーバー / アカウントごとの実値（リノート /
// リキュア！ 等）は Dart の shared_preferences にあり Windows ネイティブからは
// 読めないため、macOS NSE がキャッシュ未保存時にそうするのと同様、ここでは
// 汎用ラベルにフォールバックする。
extern const char kDefaultReblogLabel[];  // "ブースト"
extern const char kDefaultPostLabel[];    // "投稿"

// [type] に対応する表示ラベルを返す。未知 / 空の type は "通知"。
// [reblog_label] は reblog / renote、[post_label] は update（"〜を編集"）で使う。
std::string NotificationTypeDisplayLabel(const std::string& type,
                                         const std::string& reblog_label,
                                         const std::string& post_label);

// 表示する最終 title を決める。macOS NSE の didReceive と同じ優先順位:
//   type があれば type→ラベル変換を優先（サーバー title の表記揺れを統一）、
//   無ければサーバー生成 title、いずれも空なら汎用 "通知"。
// [reblog_label] / [post_label] はサーバー / アカウント別のカスタムラベル
// （リノート / リキュア！等）を渡す (#770)。省略時は既定値（ブースト / 投稿）。
// Windows では LocalState の push_labels.json から引いた値を渡し、無ければ既定に
// フォールバックする。
std::string ResolveDisplayTitle(const std::string& type,
                                const std::string& server_title,
                                const std::string& reblog_label =
                                    kDefaultReblogLabel,
                                const std::string& post_label =
                                    kDefaultPostLabel);

}  // namespace capsicum

#endif  // RUNNER_NOTIFICATION_TYPE_LABEL_H_
