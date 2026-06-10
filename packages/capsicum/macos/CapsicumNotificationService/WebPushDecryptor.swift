import CryptoKit
import Foundation

/// RFC 8291 (Web Push Encryption, aes128gcm) を復号する。
///
/// 対応形式は aes128gcm (RFC 8291 + RFC 8188) のみ。これは APNs に転送
/// される Mastodon / Misskey Web Push の実質唯一の形式。レガシー aesgcm は
/// Content-Encoding / Crypto-Key ヘッダが必要だが、relay は custom_payload
/// に詰めないため NSE からは再構築できない。必要になった時点で拡張する。
///
/// 実装は Dart 側 [WebPushDecryptor] と同一ロジックで、ビットごとに
/// 同じ結果を返すよう単体テストで突き合わせている。
enum WebPushDecryptor {
    /// `body` は RFC 8188 形式のバイト列
    /// (salt(16) || rs(4) || idlen(1) || keyid(idlen) || ciphertext)。
    /// `uaPrivateKeyD` は受信者の P-256 秘密鍵 D 値 (32 バイト)。
    /// `uaPublicKey` は受信者の P-256 公開鍵 (非圧縮 65 バイト)。
    /// `authSecret` は Web Push 登録時に交換した 16 バイト認証秘密。
    static func decryptAes128gcm(
        body: Data,
        uaPrivateKeyD: Data,
        uaPublicKey: Data,
        authSecret: Data
    ) throws -> Data {
        guard body.count >= 21 else {
            throw WebPushError.payloadTooShort
        }
        let salt = body.prefix(16)
        let rs = body.subdata(in: 16..<20).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        if rs == 0 {
            throw WebPushError.invalidRecordSize
        }
        let idlen = Int(body[20])
        guard body.count >= 21 + idlen else {
            throw WebPushError.payloadTruncated
        }
        let keyid = body.subdata(in: 21..<(21 + idlen))
        let ciphertext = body.subdata(in: (21 + idlen)..<body.count)

        guard idlen == 65, keyid.first == 0x04 else {
            throw WebPushError.invalidKeyId
        }
        let asPublic = keyid

        let privateKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: uaPrivateKeyD
        )
        let asPublicKey = try P256.KeyAgreement.PublicKey(
            x963Representation: asPublic
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
            with: asPublicKey
        )

        // RFC 8291 §3.4: IKM = HKDF-SHA256(auth_secret, ecdh, key_info, 32)
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0x00)
        keyInfo.append(uaPublicKey)
        keyInfo.append(asPublic)

        let ikm = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: authSecret,
            sharedInfo: keyInfo,
            outputByteCount: 32
        )

        // RFC 8188 §2.2: CEK / NONCE = HKDF(IKM, salt, label, len)
        var cekInfo = Data("Content-Encoding: aes128gcm".utf8)
        cekInfo.append(0x00)
        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: cekInfo,
            outputByteCount: 16
        )

        var nonceInfo = Data("Content-Encoding: nonce".utf8)
        nonceInfo.append(0x00)
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: nonceInfo,
            outputByteCount: 12
        )
        let nonceData = nonceKey.withUnsafeBytes { Data($0) }

        guard ciphertext.count >= 16 else {
            throw WebPushError.ciphertextTooShort
        }
        let tag = ciphertext.suffix(16)
        let cipher = ciphertext.prefix(ciphertext.count - 16)

        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: cipher,
            tag: tag
        )
        var plaintext = try AES.GCM.open(sealed, using: cek)

        // RFC 8188 §2: 単一レコードの末尾は 0x02 デリミタ + 0x00 パディング。
        while let last = plaintext.last, last == 0x00 {
            plaintext.removeLast()
        }
        guard let delimiter = plaintext.last, delimiter == 0x02 else {
            throw WebPushError.missingDelimiter
        }
        plaintext.removeLast()
        return plaintext
    }
}

enum WebPushError: Error {
    case payloadTooShort
    case invalidRecordSize
    case payloadTruncated
    case invalidKeyId
    case ciphertextTooShort
    case missingDelimiter
}
