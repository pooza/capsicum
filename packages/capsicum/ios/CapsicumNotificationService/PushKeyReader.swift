import Foundation

/// Notification Service Extension 用に、Web Push ペイロードの復号に必要な
/// 鍵素材をメインアプリと共有する Keychain から読み出す。
///
/// 格納元は Dart 側の [PushKeyStore] で、iOS では flutter_secure_storage が
/// kSecClassGenericPassword + kSecAttrAccount にキーを詰めている。アプリ
/// 拡張から読めるよう、エントリーは共有 Keychain Access Group
/// (`group.jp.co.b-shock.capsicum`) に保存される想定（メインアプリ側で
/// IOSOptions(groupId:) を付けて書き込む）。
enum PushKeyReader {
    static let accessGroup = "group.jp.co.b-shock.capsicum"

    /// Dart 側 `_key(slot, accountStorageKey)` と同じ文字列を組み立てる。
    /// account は `{prefix}://{username}@{host}` 形式の storage key。
    ///
    /// 例: `capsicum_push_private_mastodon://pooza@mstdn.b-shock.org`
    private static func storageKey(slot: String, accountStorageKey: String) -> String {
        return "capsicum_push_\(slot)_\(accountStorageKey)"
    }

    /// `account` (`username@host`) に対応する鍵セットを返す。
    ///
    /// 復号に必要なのは privateKey / auth / p256dh の 3 点のみ。
    /// adapter 種別が payload からは特定できないため、mastodon / misskey の
    /// 両 prefix を順に試す（Dart 側の [_findKeys] と同じ戦略）。
    static func read(account: String) -> PushKeys? {
        for prefix in ["mastodon", "misskey"] {
            let storage = "\(prefix)://\(account)"
            if let keys = tryRead(storageKey: storage) {
                return keys
            }
        }
        return nil
    }

    private static func tryRead(storageKey: String) -> PushKeys? {
        guard
            let priv = keychainRead(
                account: PushKeyReader.storageKey(
                    slot: "private", accountStorageKey: storageKey)),
            let auth = keychainRead(
                account: PushKeyReader.storageKey(
                    slot: "auth", accountStorageKey: storageKey)),
            let p256dh = keychainRead(
                account: PushKeyReader.storageKey(
                    slot: "p256dh", accountStorageKey: storageKey))
        else {
            return nil
        }
        return PushKeys(privateKeyBase64: priv, authBase64: auth, p256dhBase64: p256dh)
    }

    private static func keychainRead(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

struct PushKeys {
    /// Base64URL エンコードされた P-256 秘密鍵 D 値 (32 バイト)。
    let privateKeyBase64: String
    /// Base64URL エンコードされた 16 バイト auth secret。
    let authBase64: String
    /// Base64URL エンコードされた非圧縮 P-256 公開鍵 (65 バイト)。
    let p256dhBase64: String
}
