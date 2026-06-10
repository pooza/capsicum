import Foundation

/// Dart 側の [notificationTypeDisplay] / [notificationTypeFromString] と
/// 同じラベル統一を NSE 側で行う。Mastodon 生成の title は表記揺れが
/// あるため、notification_type を基に capsicum 規定のラベルを組む。
///
/// `reblogLabel` / `postLabel` は呼び出し側から注入する（サーバー / アカウント
/// ごとに「ブースト」「リノート」「リキュア！」等に切り替わるため）。
enum NotificationTypeLabel {
    static func displayLabel(
        type: String?,
        reblogLabel: String,
        postLabel: String
    ) -> String {
        switch type {
        case "mention", "reply", "quote":
            return "メンション"
        case "reblog", "renote":
            return reblogLabel
        case "favourite":
            return "お気に入り"
        case "follow":
            return "フォロー"
        case "follow_request", "receiveFollowRequest":
            return "フォローリクエスト"
        case "reaction":
            return "リアクション"
        case "poll", "pollEnded":
            return "アンケート終了"
        case "update":
            return "\(postLabel)を編集"
        case "login":
            return "ログイン"
        case "create_token":
            return "アクセストークン作成"
        default:
            return "通知"
        }
    }
}
