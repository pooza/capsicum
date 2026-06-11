// === macOS コピー (#673) ===
// 本ファイルは ios/CapsicumNotificationService/NotificationService.swift の
// macOS NSE 向けコピー。出荷中の iOS NSE を触らないため共有せずコピーしている。
// 復号・パース・ラベル・FailureRecorder のロジックは iOS と一致させること
// （変更時は両側を揃える）。macOS 固有差分:
// - 冒頭の import (UIKit → Foundation)
// - ParsedPayload.notificationId の抽出と userInfo への stamp (#674)。
//   起動中二重通知の dedup は WebSocket dispatcher (#569) を持つ desktop だけの
//   要件のため iOS には入れない（iOS で stamp しても無害だが、出荷中 NSE を
//   触らない方針を優先）
// - 成功・guard 素通り・タイムアウトの NSLog (#673)。「失敗ログ無しなのに
//   generic 文面」の切り分けで、無言経路を unified log から判別するため。
//   iOS は出荷実績があるため足さない。
//
// iOS は拡張テンプレート由来で `import UIKit` だが UIKit API は未使用。
// macOS に UIKit は無いため Foundation に置き換える。
import Foundation
import UserNotifications

/// Notification Service Extension (NSE) エントリポイント。
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
        let startedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        func elapsedMs() -> Int {
            return Int(Date().timeIntervalSince1970 * 1000) - startedAtMs
        }

        self.contentHandler = contentHandler
        bestAttemptContent =
            (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttempt = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        let userInfo = request.content.userInfo
        let rawAccount = userInfo["account"] as? String
        let rawEncoding = userInfo["encoding"] as? String
        let host = rawAccount.flatMap { hostFromAccount($0) }

        guard
            let account = rawAccount, !account.isEmpty,
            let bodyB64 = userInfo["body"] as? String,
            let encoding = rawEncoding, encoding == "aes128gcm"
        else {
            // announcement push (#477) は body / encoding を持たない仕様のため
            // ここを通るのが正常。FailureRecorder には残さず NSLog のみ。
            NSLog(
                "capsicum: nse: passthrough (account=\(rawAccount != nil), "
                    + "body=\(userInfo["body"] is String), "
                    + "encoding=\(rawEncoding ?? "nil"))"
            )
            contentHandler(bestAttempt)
            return
        }

        let lookup = PushKeyReader.read(account: account)
        guard let keys = lookup.keys else {
            NSLog(
                "capsicum: nse: no push keys for \(account) "
                    + "(status=\(lookup.lastStatus), tried=\(lookup.triedPrefixes))"
            )
            FailureRecorder.record(
                code: "nse.no_keys",
                host: host, encoding: encoding, elapsedMs: elapsedMs(),
                keychainStatus: Int(lookup.lastStatus),
                triedPrefixes: lookup.triedPrefixes.joined(separator: ",")
            )
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
            FailureRecorder.record(
                code: "nse.base64_decode_failed",
                host: host, encoding: encoding, elapsedMs: elapsedMs()
            )
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
            // #436: Misskey 限定で発生している decrypt_failed の切り分け。
            // ヘッダ系 (WebPushError.invalidKeyId / payloadTruncated 等) と
            // 鍵不一致系 (CryptoKitError.authenticationFailure) で意味が違うので
            // タグに残す。`String(describing:)` は enum case を含むので
            // "WebPushError.invalidKeyId" の形で出る。
            let reason = "\(type(of: error)).\(String(describing: error))"
            NSLog("capsicum: nse: decrypt failed: \(reason)")
            FailureRecorder.record(
                code: "nse.decrypt_failed",
                host: host, encoding: encoding, elapsedMs: elapsedMs(),
                decryptError: reason
            )
            contentHandler(bestAttempt)
            return
        }

        guard let parsed = PayloadParser.parse(plaintext: plaintext) else {
            NSLog("capsicum: nse: parse failed")
            FailureRecorder.record(
                code: "nse.parse_failed",
                host: host, encoding: encoding, elapsedMs: elapsedMs()
            )
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

        // 復号で得た通知 ID を userInfo に stamp する (#674)。アプリ起動中は
        // #569 (WebSocket → ローカル通知) と本 APNs の両方が同じ通知イベントを
        // 配信しうるため、main app 側の UNUserNotificationCenter delegate proxy
        // (NotificationDedupPlugin) が `account|id` キーで突き合わせて後着を
        // 黙殺する。stamp が無い通知 (復号失敗 = generic 文面) は dedup 不能の
        // ため proxy 側で degrade する。
        if let notificationId = parsed.notificationId, !notificationId.isEmpty {
            var userInfo = bestAttempt.userInfo
            userInfo["capsicum_notification_id"] = notificationId
            bestAttempt.userInfo = userInfo
        }

        NSLog(
            "capsicum: nse: rewrote (type=\(parsed.type ?? "nil"), "
                + "stamped=\(parsed.notificationId != nil), "
                + "elapsed=\(elapsedMs())ms)"
        )
        contentHandler(bestAttempt)
    }

    override func serviceExtensionTimeWillExpire() {
        // NSE は 30 秒以内に完了する必要がある。タイムアウト寸前にここが
        // 呼ばれるので、現時点での best attempt (relay の fallback 文面等)
        // を返して通知を止めない。
        NSLog("capsicum: nse: expired before completion")
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

// MARK: - Failure recorder

/// Dart 側の `PushFailureKey` と完全同名で対応する App Group UserDefaults
/// キー集合。新しい項目を増やすときは両側を揃えること。
enum PushFailureKey: String {
    case code = "capsicum_push_failure_last_code"
    case at = "capsicum_push_failure_last_at_ms"
    case count = "capsicum_push_failure_count"
    case host = "capsicum_push_failure_last_host"
    case encoding = "capsicum_push_failure_last_encoding"
    case elapsedMs = "capsicum_push_failure_last_elapsed_ms"
    /// #436: nse.no_keys の根本原因切り分け用。Keychain OSStatus と
    /// 試行したストレージキープレフィックス（"mastodon,misskey" 等）。
    case keychainStatus = "capsicum_push_failure_last_keychain_status"
    case triedPrefixes = "capsicum_push_failure_last_tried_prefixes"
    /// #436: nse.decrypt_failed の切り分け用。WebPushDecryptor / CryptoKit が
    /// 投げた error の type + case 名（"WebPushError.invalidKeyId" 等）。
    case decryptError = "capsicum_push_failure_last_decrypt_error"
}

/// NSE で起きた fallback 起因（鍵不在・base64 失敗・復号失敗・parse 失敗）を
/// App Group UserDefaults に書き、次回 main app 起動時に Dart 側の
/// [PushFailureRecorder] が読み出して Sentry へ送る (#366)。
/// 単一スロット（最後のコード + 件数 + 最終時刻 + コンテキスト）のみ保持する。
///
/// host / encoding / elapsedMs は #376 で追加した切り分け用コンテキストで、
/// `nse.decrypt_failed` の発生源（自前/他鯖、aes128gcm 以外、タイムアウト由来か
/// 即時失敗か）を Sentry tag/extra で見るために使う。
enum FailureRecorder {
    private static let suiteName = "group.jp.co.b-shock.capsicum"

    static func record(
        code: String,
        host: String?,
        encoding: String?,
        elapsedMs: Int?,
        keychainStatus: Int? = nil,
        triedPrefixes: String? = nil,
        decryptError: String? = nil
    ) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(code, forKey: PushFailureKey.code.rawValue)
        defaults.set(
            Int(Date().timeIntervalSince1970 * 1000),
            forKey: PushFailureKey.at.rawValue
        )
        let next = defaults.integer(forKey: PushFailureKey.count.rawValue) + 1
        defaults.set(next, forKey: PushFailureKey.count.rawValue)
        writeOptional(defaults, .host, host)
        writeOptional(defaults, .encoding, encoding)
        writeOptional(defaults, .elapsedMs, elapsedMs)
        writeOptional(defaults, .keychainStatus, keychainStatus)
        writeOptional(defaults, .triedPrefixes, triedPrefixes)
        writeOptional(defaults, .decryptError, decryptError)
    }

    private static func writeOptional(
        _ defaults: UserDefaults,
        _ key: PushFailureKey,
        _ value: Any?
    ) {
        if let value = value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}

/// `username@host` 形式のアカウント識別子から host 部分を取り出す。
/// 取得できない場合（`@` がない / 末尾が `@`）は `nil`。
func hostFromAccount(_ account: String) -> String? {
    guard let atIndex = account.lastIndex(of: "@") else { return nil }
    let host = account[account.index(after: atIndex)...]
    return host.isEmpty ? nil : String(host)
}

// MARK: - Payload parsing

struct ParsedPayload {
    let title: String?
    let body: String?
    let type: String?
    /// SNS サーバー側の通知 ID。WebSocket 経由 (#569) の `notification.id` と
    /// 同じ ID 空間で、起動中の二重通知 dedup (#674) の突き合わせキーになる。
    /// Mastodon: `notification_id` / Misskey: `body.id`。取れない形式では nil。
    let notificationId: String?
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

        // Mastodon: {title, body, notification_type, notification_id}
        let mastodonTitle = dict["title"] as? String
        let mastodonBody = dict["body"] as? String
        let mastodonType = dict["notification_type"] as? String
        if mastodonTitle != nil || mastodonBody != nil || mastodonType != nil {
            return ParsedPayload(
                title: mastodonTitle, body: mastodonBody, type: mastodonType,
                notificationId: stringId(dict["notification_id"]))
        }

        // Misskey: {type: 'notification', body: {id, type, user, note, reaction, ...}}
        if (dict["type"] as? String) == "notification",
            let inner = dict["body"] as? [String: Any]
        {
            return ParsedPayload(
                title: nil,
                body: synthesizeMisskeyBody(inner),
                type: inner["type"] as? String,
                notificationId: stringId(inner["id"])
            )
        }

        // Misskey 新 chat: {type: 'newChatMessage', body: <ChatMessage>, ...} (#248)。
        // /api/i/notifications には来ない push 専用 type。body は ChatMessage 自体で
        // fromUser / text / file を直接持つ。Dart 側 push_message_dispatcher と同じ
        // ハンドリングを NSE 側にも入れる必要がある (NSE は別プロセスで Dart の
        // parsePayload を共有しないため)。
        // body.id は ChatMessage の ID。WebSocket 通知ストリームの ID 空間とは
        // 別物だが、dedup キーとしては「同一イベントなら同一値」が満たせれば
        // よいので、そのまま stamp する。
        if (dict["type"] as? String) == "newChatMessage",
            let inner = dict["body"] as? [String: Any]
        {
            return ParsedPayload(
                title: nil,
                body: synthesizeMisskeyChatBody(inner),
                type: "newChatMessage",
                notificationId: stringId(inner["id"])
            )
        }
        return nil
    }

    /// 通知 ID を文字列に均す。Mastodon の `notification_id` は JSON 数値で
    /// 届くことがあり (Misskey は文字列)、dedup キーの突き合わせは文字列表現で
    /// 行うため両方を受ける。
    private static func stringId(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        // Bool は NSNumber に bridge されるため除外する (id に Bool は来ない想定
        // だが、誤って "0"/"1" を ID 扱いしない)。
        if let n = value as? NSNumber, !(value is Bool) {
            return n.stringValue
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

    /// Misskey 新 chat の `newChatMessage` push payload 内 body
    /// (= ChatMessage そのもの) から通知本文を合成する。
    /// 形式: `<actor>: <text or 添付ラベル>`。Dart 側 _synthesizeMisskeyChatBody と
    /// 同じ仕様。
    private static func synthesizeMisskeyChatBody(_ body: [String: Any]) -> String? {
        let fromUser = body["fromUser"] as? [String: Any]
        let text = body["text"] as? String
        let fileMime = (body["file"] as? [String: Any])?["type"] as? String

        let displayName =
            (fromUser?["name"] as? String)?.trimmingCharacters(in: .whitespaces)
        let username = fromUser?["username"] as? String
        let actor: String? = {
            if let displayName = displayName, !displayName.isEmpty {
                return displayName
            }
            if let username = username {
                return "@\(username)"
            }
            return nil
        }()

        let content: String
        if let text = text, !text.isEmpty {
            content = text
        } else if let mime = fileMime {
            if mime.hasPrefix("image/") {
                content = "[画像]"
            } else if mime.hasPrefix("video/") {
                content = "[動画]"
            } else if mime.hasPrefix("audio/") {
                content = "[音声]"
            } else {
                content = "[ファイル]"
            }
        } else {
            content = ""
        }

        guard let actor = actor else {
            return content.isEmpty ? nil : content
        }
        return content.isEmpty ? actor : "\(actor): \(content)"
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
