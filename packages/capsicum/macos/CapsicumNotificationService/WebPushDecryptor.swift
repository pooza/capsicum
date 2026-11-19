import CryptoKit
import Foundation

/// Web Push のペイロードを復号する。
///
/// 対応形式:
/// - aes128gcm (RFC 8291 + RFC 8188): Mastodon / Misskey。body 単体で復号できる
/// - aesgcm (draft-ietf-webpush-encryption-04): Akkoma（Pleroma 系）と古い
///   Mastodon（#1390・Akkoma 3.20.1 で実測）。`Crypto-Key`（`dh=`）と
///   `Encryption`（`salt=`）が要る。relay は APNs の custom payload に
///   `crypto_key` / `encryption` として載せている（縮退で落とすときは body と
///   一緒に落とす）
///
/// ⚠ iOS と macOS の NSE に**同じファイル**を置いている。直すときは両方。
///
/// 実装は Dart 側 [WebPushDecryptor] と同一ロジック。aesgcm のベクタは
/// Dart のテスト（`web_push_decryptor_test.dart`）と同じものを使う。
enum WebPushDecryptor {
    /// 復号できる `Content-Encoding` か。
    static func supports(_ encoding: String?) -> Bool {
        return encoding == "aes128gcm" || encoding == "aesgcm"
    }

    /// `encoding` で振り分けて復号する。NSE はこれだけを呼ぶ。
    static func decrypt(
        encoding: String,
        body: Data,
        uaPrivateKeyD: Data,
        uaPublicKey: Data,
        authSecret: Data,
        cryptoKey: String?,
        encryption: String?
    ) throws -> Data {
        switch encoding {
        case "aes128gcm":
            return try decryptAes128gcm(
                body: body, uaPrivateKeyD: uaPrivateKeyD,
                uaPublicKey: uaPublicKey, authSecret: authSecret
            )
        case "aesgcm":
            guard let cryptoKey = cryptoKey, let encryption = encryption else {
                throw WebPushError.missingAesgcmHeaders
            }
            return try decryptAesgcm(
                body: body, cryptoKey: cryptoKey, encryption: encryption,
                uaPrivateKeyD: uaPrivateKeyD, uaPublicKey: uaPublicKey,
                authSecret: authSecret
            )
        default:
            throw WebPushError.unsupportedEncoding
        }
    }

    /// aesgcm（旧方式）。単一レコードだけを扱う（本文は 4KB 以下で、既定の
    /// rs 4096 に収まる）。
    static func decryptAesgcm(
        body: Data,
        cryptoKey: String,
        encryption: String,
        uaPrivateKeyD: Data,
        uaPublicKey: Data,
        authSecret: Data
    ) throws -> Data {
        guard let dh = headerParam(cryptoKey, "dh"),
            let saltParam = headerParam(encryption, "salt"),
            let asPublic = decodeB64Url(dh),
            let salt = decodeB64Url(saltParam)
        else {
            throw WebPushError.missingAesgcmHeaders
        }
        guard asPublic.count == 65, asPublic.first == 0x04 else {
            throw WebPushError.invalidKeyId
        }
        guard salt.count == 16 else {
            throw WebPushError.invalidSalt
        }
        var rs = 4096
        if let rsParam = headerParam(encryption, "rs") {
            guard let parsed = Int(rsParam), parsed > 2 else {
                throw WebPushError.invalidRecordSize
            }
            rs = parsed
        }
        // ⚠ `rs + 16` と書かない。`rs` はヘッダの値そのままなので、Int.max 近くが
        // 来ると加算が trap して NSE ごと落ちる。引く側に寄せる（body.count は小さい）。
        guard body.count - 16 <= rs else {
            throw WebPushError.multiRecordUnsupported
        }

        let privateKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: uaPrivateKeyD
        )
        let asPublicKey = try P256.KeyAgreement.PublicKey(
            x963Representation: asPublic
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
            with: asPublicKey
        )

        // draft-ietf-webpush-encryption-04 §3.3: auth_secret を salt にした HKDF。
        var authInfo = Data("Content-Encoding: auth".utf8)
        authInfo.append(0x00)
        let ikm = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: authSecret,
            sharedInfo: authInfo,
            outputByteCount: 32
        )

        // context = "P-256" || 0x00 || len(ua) || ua || len(as) || as（長さは 2 バイト BE）
        var context = Data("P-256".utf8)
        context.append(0x00)
        context.append(contentsOf: [UInt8(uaPublicKey.count >> 8), UInt8(uaPublicKey.count & 0xff)])
        context.append(uaPublicKey)
        context.append(contentsOf: [UInt8(asPublic.count >> 8), UInt8(asPublic.count & 0xff)])
        context.append(asPublic)

        var cekInfo = Data("Content-Encoding: aesgcm".utf8)
        cekInfo.append(0x00)
        cekInfo.append(context)
        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: cekInfo, outputByteCount: 16
        )
        var nonceInfo = Data("Content-Encoding: nonce".utf8)
        nonceInfo.append(0x00)
        nonceInfo.append(context)
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: nonceInfo, outputByteCount: 12
        )
        let nonceData = nonceKey.withUnsafeBytes { Data($0) }

        guard body.count >= 16 else {
            throw WebPushError.ciphertextTooShort
        }
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: body.prefix(body.count - 16),
            tag: body.suffix(16)
        )
        let padded = try AES.GCM.open(sealed, using: cek)

        // 先頭 2 バイト（BE）がパディング長。その分の 0x00 のあとが平文。
        guard padded.count >= 2 else {
            throw WebPushError.invalidPadding
        }
        let bytes = [UInt8](padded)
        let padLength = Int(bytes[0]) << 8 | Int(bytes[1])
        let start = 2 + padLength
        guard start <= bytes.count, bytes[2..<start].allSatisfy({ $0 == 0 }) else {
            throw WebPushError.invalidPadding
        }
        return Data(bytes[start...])
    }

    /// `Crypto-Key: dh=…;p256ecdsa=…` / `Encryption: salt=…;rs=…` から 1 つ取る。
    /// 区切りは `;` と `,` の両方を見る。引用符は外す。
    static func headerParam(_ header: String, _ name: String) -> String? {
        for part in header.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[part.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard key.lowercased() == name else { continue }
            var value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    private static func decodeB64Url(_ value: String) -> Data? {
        var s = value.replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

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
    case missingAesgcmHeaders
    case invalidSalt
    case multiRecordUnsupported
    case invalidPadding
    case unsupportedEncoding
}
