import UIKit
import UserNotifications

/// iOS Notification Service Extension (NSE) エントリポイント。
/// capsicum-relay が APNs 経由で送る Web Push 暗号化ペイロードを
/// 受信し、RFC 8291 (aes128gcm) で復号した内容で通知を書き換える。
///
/// 動作条件:
/// - APNs payload に `mutable-content: 1` が含まれること（relay 側で常に設定）
/// - payload に `alert` が含まれること（fallback 文面として `"${account} に通知があります"`）
/// - `userInfo` 直下に `body` (base64) / `encoding` / `account` を持つこと
///
/// 復号失敗時 / 鍵不在時は、relay が付けた fallback 文面のまま通知を
/// 出す（無応答にはしない）。復号成功時は:
/// - title を `notificationTypeDisplay` と同じラベル統一に揃える
/// - body を復号後の JSON から抽出（Mastodon / Misskey 両形式対応）
class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent =
            (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttempt = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        let userInfo = request.content.userInfo
        guard
            let account = userInfo["account"] as? String, !account.isEmpty,
            let bodyB64 = userInfo["body"] as? String,
            let encoding = userInfo["encoding"] as? String, encoding == "aes128gcm"
        else {
            contentHandler(bestAttempt)
            return
        }

        guard let keys = PushKeyReader.read(account: account) else {
            NSLog("capsicum: nse: no push keys for \(account)")
            contentHandler(bestAttempt)
            return
        }

        guard
            let bodyData = Data(base64UrlEncoded: bodyB64),
            let privateKey = Data(base64UrlEncoded: keys.privateKeyBase64),
            let authSecret = Data(base64UrlEncoded: keys.authBase64),
            let p256dh = Data(base64UrlEncoded: keys.p256dhBase64)
        else {
            NSLog("capsicum: nse: base64url decode failed for \(account)")
            contentHandler(bestAttempt)
            return
        }

        let plaintext: Data
        do {
            plaintext = try WebPushDecryptor.decryptAes128gcm(
                body: bodyData,
                uaPrivateKeyD: privateKey,
                uaPublicKey: p256dh,
                authSecret: authSecret
            )
        } catch {
            NSLog("capsicum: nse: decrypt failed: \(error)")
            contentHandler(bestAttempt)
            return
        }

        guard let parsed = PayloadParser.parse(plaintext: plaintext) else {
            NSLog("capsicum: nse: parse failed")
            contentHandler(bestAttempt)
            return
        }

        // ラベル解決は App Group UserDefaults 経由の NotificationLabelCache
        // から行う（iOS 側は shared_preferences_foundation の suiteName 設定で
        // `UserDefaults(suiteName:)` に焼いている）。未保存アカウントは
        // 汎用 "ブースト" / "投稿" にフォールバック。
        let (reblogLabel, postLabel) = LabelCache.read(account: account)

        if let type = parsed.type {
            bestAttempt.title = NotificationTypeLabel.displayLabel(
                type: type,
                reblogLabel: reblogLabel,
                postLabel: postLabel
            )
        } else if let title = parsed.title, !title.isEmpty {
            bestAttempt.title = title
        }

        if let body = parsed.body, !body.isEmpty {
            bestAttempt.body = body
        }

        contentHandler(bestAttempt)
    }

    override func serviceExtensionTimeWillExpire() {
        // NSE は 30 秒以内に完了する必要がある。タイムアウト寸前にここが
        // 呼ばれるので、現時点での best attempt (relay の fallback 文面等)
        // を返して通知を止めない。
        if let contentHandler = contentHandler,
            let bestAttemptContent = bestAttemptContent
        {
            contentHandler(bestAttemptContent)
        }
    }
}

// MARK: - Label cache

/// Dart の [NotificationLabelCache] と同じキー空間を読む。suiteName は
/// App Group ID (`group.jp.co.b-shock.capsicum`)、キー形式は
/// `capsicum_notif_label_{slot}_{account}`。
enum LabelCache {
    private static let suiteName = "group.jp.co.b-shock.capsicum"
    private static let prefix = "capsicum_notif_label_"

    static func read(account: String) -> (reblog: String, post: String) {
        let defaults = UserDefaults(suiteName: suiteName)
        let reblog = defaults?.string(forKey: "\(prefix)reblog_\(account)") ?? "ブースト"
        let post = defaults?.string(forKey: "\(prefix)post_\(account)") ?? "投稿"
        return (reblog, post)
    }
}

// MARK: - Payload parsing

struct ParsedPayload {
    let title: String?
    let body: String?
    let type: String?
}

/// Dart の [PushMessageDispatcher.parsePayload] と同じ優先順位で
/// Mastodon / Misskey 両形式を扱う。
enum PayloadParser {
    static func parse(plaintext: Data) -> ParsedPayload? {
        guard
            let object = try? JSONSerialization.jsonObject(with: plaintext),
            let dict = object as? [String: Any]
        else {
            return nil
        }

        // Mastodon: {title, body, notification_type}
        let mastodonTitle = dict["title"] as? String
        let mastodonBody = dict["body"] as? String
        let mastodonType = dict["notification_type"] as? String
        if mastodonTitle != nil || mastodonBody != nil || mastodonType != nil {
            return ParsedPayload(
                title: mastodonTitle, body: mastodonBody, type: mastodonType)
        }

        // Misskey: {type: 'notification', body: {type, user, note, reaction, ...}}
        if (dict["type"] as? String) == "notification",
            let inner = dict["body"] as? [String: Any]
        {
            return ParsedPayload(
                title: nil,
                body: synthesizeMisskeyBody(inner),
                type: inner["type"] as? String
            )
        }
        return nil
    }

    private static func synthesizeMisskeyBody(_ body: [String: Any]) -> String? {
        let note = body["note"] as? [String: Any]
        let user = body["user"] as? [String: Any]
        let reaction = body["reaction"] as? String
        let type = body["type"] as? String

        if let noteText = note?["text"] as? String, !noteText.isEmpty {
            return noteText
        }

        let displayName =
            (user?["name"] as? String)?.trimmingCharacters(in: .whitespaces)
        let username = user?["username"] as? String
        let actor: String? = {
            if let displayName = displayName, !displayName.isEmpty {
                return displayName
            }
            if let username = username {
                return "@\(username)"
            }
            return nil
        }()

        if type == "reaction", let reaction = reaction {
            return actor.map { "\($0) が \(reaction) でリアクション" } ?? reaction
        }
        if type == "follow", let actor = actor {
            return "\(actor) にフォローされました"
        }
        return actor
    }
}

// MARK: - Base64URL helper

extension Data {
    /// URL-safe base64 を `Data` にデコードする。Web Push の `body` / 鍵
    /// マテリアルは padding を落とした base64url 形式で届く。
    init?(base64UrlEncoded input: String) {
        var normalized =
            input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - normalized.count % 4) % 4
        normalized.append(String(repeating: "=", count: pad))
        guard let data = Data(base64Encoded: normalized) else {
            return nil
        }
        self = data
    }
}
