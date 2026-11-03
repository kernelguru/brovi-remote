import CommonCrypto
import CryptoKit
import Foundation

enum Crypto {
    static func randomHex(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.hexString
    }

    static func sha256Hex(_ string: String) -> String {
        Array(SHA256.hash(data: Data(string.utf8))).hexString
    }

    /// Client-Proof für den SCRAM-Login der HiLink-API
    /// (gleiche Berechnung wie im Web-Interface des Routers).
    static func scramClientProof(password: String, saltHex: String, iterations: Int,
                                 firstNonce: String, serverNonce: String) -> String {
        let salted = pbkdf2SHA256(password: password, salt: [UInt8](hex: saltHex), iterations: iterations)
        let clientKey = Array(HMAC<SHA256>.authenticationCode(
            for: salted, using: SymmetricKey(data: Data("Client Key".utf8))))
        let storedKey = Array(SHA256.hash(data: clientKey))
        let authMessage = "\(firstNonce),\(serverNonce),\(serverNonce)"
        let signature = Array(HMAC<SHA256>.authenticationCode(
            for: storedKey, using: SymmetricKey(data: Data(authMessage.utf8))))
        return zip(clientKey, signature).map { $0 ^ $1 }.hexString
    }

    private static func pbkdf2SHA256(password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8).map { CChar(bitPattern: $0) }
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes, passwordBytes.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &derived, derived.count
        )
        return derived
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension Array where Element == UInt8 {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        self = bytes
    }
}
