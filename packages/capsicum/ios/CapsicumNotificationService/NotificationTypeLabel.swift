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
        case "mention", "reply":
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
        case "create_token", "createToken":
            return "アクセストークン作成"
        // Misskey 新 chat の Web Push 専用 type (#248)。Dart
        // notificationTypeDisplay / NotificationType.chat と同じく「メッセージ」に
        // 寄せる。case が無いと title が「通知」にフォールバックしていた (#765)。
        case "newChatMessage":
            return "メッセージ"
        // Misskey の実績解除通知 (#918)。Dart notificationTypeDisplay /
        // NotificationType.achievementEarned と同じく「実績を解除」に寄せる。
        case "achievementEarned":
            return "実績を解除"
        // #1177 で足した種別。⚠⚠ **Dart 側の notificationTypeFromString /
        // notificationTypeDisplay と綴りもラベルも揃えること。**片方だけ足すと
        // 「アプリ内では読めるが、プッシュだけ『通知』のまま」になる。
        case "status", "note":
            return "新しい\(postLabel)"
        // ⚠⚠ **quote を "メンション" から外した (#1177)。**#248 以来メンション
        // 扱いだったので、**プッシュの見出しが「引用」に変わる。**
        case "quote":
            return "引用"
        case "quoted_update":
            return "引用元を編集"
        case "annual_report":
            return "年間まとめ"
        case "admin.sign_up":
            return "新規登録"
        case "admin.report":
            return "通報"
        case "scheduledNotePosted":
            return "予約\(postLabel)を投稿"
        // ⚠⚠ この Issue でいちばん実害がある種別。
        case "scheduledNotePostFailed":
            return "予約\(postLabel)が失敗"
        case "followRequestAccepted":
            return "フォローが承認されました"
        case "roleAssigned":
            return "ロールが付与されました"
        // ⚠ newChatMessage（メッセージが来た）とは別物。
        case "chatRoomInvitationReceived":
            return "チャットに招待"
        case "exportCompleted":
            return "エクスポートが完了"
        default:
            return "通知"
        }
    }
}
