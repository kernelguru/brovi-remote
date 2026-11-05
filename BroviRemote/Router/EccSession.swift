import CryptoKit
import Foundation

/// Verschlüsselte Anfragen der Router-Weboberfläche (js/main.js, „isSupportEcc“):
/// Curve25519-Schlüsseltausch mit dem Server-Schlüssel aus /api/webserver/publickey,
/// danach AES-256-GCM mit 16 Null-Bytes als Zusatzdaten.
///
/// Die Weboberfläche nutzt die JS-Bibliothek „elliptic“, die Schlüssel als Big-Endian-Hex
/// darstellt; CryptoKit arbeitet mit Little-Endian, daher werden die Bytes umgedreht.
///
/// Format verschlüsselter Daten (Hex): 4 Byte Länge (LE) | 12 Byte IV | 16 Byte Tag | Chiffretext
struct EccSession {
    /// Öffentlicher Client-Schlüssel (Hex), wird als `ecc-client-pubkey` in der URL übergeben.
    let clientKeyHex: String
    private let key: SymmetricKey
    private static let aad = Data(repeating: 0, count: 16)

    init(serverKeyHex: String) throws {
        let serverBE = [UInt8](hex: serverKeyHex)
        guard serverBE.count == 32 else {
            throw RouterError(code: nil, message: "Unbekanntes Schlüsselformat des Routers")
        }
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(serverBE.reversed()))
        // Die Weboberfläche wandelt das Geheimnis ohne führende Nullen in Hex um –
        // daher nur Schlüssel verwenden, deren höchstes Byte keine führende Null erzeugt.
        for _ in 0..<64 {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: serverKey)
            let sharedBE = Array(secret.withUnsafeBytes { Array($0) }.reversed())
            guard let first = sharedBE.first, first >= 0x10 else { continue }
            clientKeyHex = Array(privateKey.publicKey.rawRepresentation.reversed()).hexString
            key = SymmetricKey(data: sharedBE)
            return
        }
        throw RouterError(code: nil, message: "Schlüsseltausch fehlgeschlagen")
    }

    func encrypt(_ plain: String) throws -> String {
        let data = Data(plain.utf8)
        let box = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce(), authenticating: Self.aad)
        let length = UInt32(data.count)
        let lengthBytes = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF),
                           UInt8((length >> 16) & 0xFF), UInt8((length >> 24) & 0xFF)]
        return lengthBytes.hexString + Array(box.nonce).hexString + Array(box.tag).hexString
            + Array(box.ciphertext).hexString
    }

    func decrypt(_ hex: String) throws -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 64 else { throw RouterError(code: nil, message: "Verschlüsselte Antwort unvollständig") }
        let chars = Array(trimmed)
        let iv = [UInt8](hex: String(chars[8..<32]))
        let tag = [UInt8](hex: String(chars[32..<64]))
        let body = [UInt8](hex: String(chars[64...]))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: body, tag: tag)
        let plain = try AES.GCM.open(box, using: key, authenticating: Self.aad)
        return String(decoding: plain, as: UTF8.self)
    }
}
