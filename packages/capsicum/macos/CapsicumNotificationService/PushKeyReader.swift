// === macOS コピー (#673) ===
// ios/CapsicumNotificationService/PushKeyReader.swift の macOS NSE 向けコピー。
// macOS 固有差分: keychainRead の query に kSecUseDataProtectionKeychain: true を
// 足す（下記参照）。それ以外は iOS と一致させること。
import Foundation

/// Notification Service Extension 用に、Web Push ペイロードの復号に必要な
/// 鍵素材をメインアプリと共有する Keychain から読み出す。
///
/// 格納元は Dart 側の [PushKeyStore] で、iOS では flutter_secure_storage が
/// kSecClassGenericPassword + kSecAttrAccount にキーを詰めている。アプリ
/// 拡張から読めるよう、エントリーは共有 Keychain Access Group
/// (`group.jp.co.b-shock.capsicum`) に保存される想定（メインアプリ側で
/// IOSOptions(groupId:) を付けて書き込む）。
///
/// 鍵セット（p256dh / auth / privateKey）は **1 JSON blob** として
/// `capsicum_push_keyset_{storageKey}` に格納されている。旧来の 3 スロット
/// 個別書き込みだと、メインアプリが鍵を書き換え中の NSE 側読み出しで
/// 新旧混成ロードが起きる race があったため（R-C 対応）、統合済み。
enum PushKeyReader {
    /// `kSecAttrAccessGroup` には **TeamID + ドット + グループ名** の完全表記が
    /// 必須 (Apple Keychain Services Programming Guide)。bare 表記
    /// （`group.jp.co.b-shock.capsicum`）でも development 署名では通ることが
    /// あるが、distribution（TestFlight / App Store）署名ではエントリが
    /// entitlements に解決できず、書き込み・読み出しが silent に失敗する。
    /// `Y27AK8VF85` は Xcode project の `DEVELOPMENT_TEAM` と一致 (#373 候補 B)。
    /// Dart 側 `PushKeyStore._iOSAccessGroup` と同じ文字列を使うこと。
    static let accessGroup = "Y27AK8VF85.group.jp.co.b-shock.capsicum"

    /// Dart 側 `_key(slot, accountStorageKey)` と同じ文字列を組み立てる。
    /// account は `{prefix}://{username}@{host}` 形式の storage key。
    ///
    /// 例: `capsicum_push_keyset_mastodon://pooza@mstdn.b-shock.org`
    private static func storageKey(slot: String, accountStorageKey: String) -> String {
        return "capsicum_push_\(slot)_\(accountStorageKey)"
    }

    /// `account` (`username@host`) に対応する鍵セットを返す。
    ///
    /// adapter 種別が payload からは特定できないため、mastodon / misskey の
    /// 両 prefix を順に試す（Dart 側の [_findKeys] と同じ戦略）。
    ///
    /// 戻り値の [PushKeyLookupResult.keys] が nil の場合、[lastStatus] / [triedPrefixes]
    /// に Keychain の OSStatus と試行したプレフィックスを格納する (#436)。
    /// nse.no_keys の根本原因切り分け（entitlement 不一致 / accessibility / migration 漏れ）
    /// に必要な情報を Sentry に送るため。
    static func read(account: String) -> PushKeyLookupResult {
        var lastStatus: OSStatus = errSecItemNotFound
        var tried: [String] = []
        for prefix in ["mastodon", "misskey"] {
            let storage = "\(prefix)://\(account)"
            tried.append(prefix)
            let (keys, status) = tryRead(storageKey: storage)
            lastStatus = status
            if let keys = keys {
                return PushKeyLookupResult(
                    keys: keys, lastStatus: status, triedPrefixes: tried)
            }
        }
        return PushKeyLookupResult(
            keys: nil, lastStatus: lastStatus, triedPrefixes: tried)
    }

    private static func tryRead(storageKey: String) -> (PushKeys?, OSStatus) {
        let keychainKey = PushKeyReader.storageKey(
            slot: "keyset", accountStorageKey: storageKey)
        let (raw, status) = keychainRead(account: keychainKey)
        guard let raw = raw else {
            return (nil, status)
        }
        guard
            let data = raw.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let p256dh = json["p256dh"] as? String,
            let auth = json["auth"] as? String,
            let priv = json["priv"] as? String
        else {
            return (nil, status)
        }
        return (
            PushKeys(
                privateKeyBase64: priv,
                authBase64: auth,
                p256dhBase64: p256dh
            ),
            status
        )
    }

    private static func keychainRead(account: String) -> (String?, OSStatus) {
        // macOS 固有 (#673): flutter_secure_storage の MacOsOptions は既定で
        // data-protection keychain (kSecUseDataProtectionKeychain=true) に書く。
        // Dart 側 PushKeyStore も MacOsOptions で書き込むため、NSE 読み出しも
        // 同じ data-protection keychain を指定しないと、既定の file-based
        // keychain を引いて item が見つからず復号失敗 (#436 / #580 型) になる。
        // iOS では既定が data-protection なので不要だったが macOS では必須。
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
    }
}

/// PushKeyReader.read() の結果。鍵が読めた場合は keys が non-nil。
/// 失敗時は lastStatus / triedPrefixes が原因切り分けに使える (#436)。
struct PushKeyLookupResult {
    let keys: PushKeys?
    let lastStatus: OSStatus
    let triedPrefixes: [String]
}

struct PushKeys {
    /// Base64URL エンコードされた P-256 秘密鍵 D 値 (32 バイト)。
    let privateKeyBase64: String
    /// Base64URL エンコードされた 16 バイト auth secret。
    let authBase64: String
    /// Base64URL エンコードされた非圧縮 P-256 公開鍵 (65 バイト)。
    let p256dhBase64: String
}
