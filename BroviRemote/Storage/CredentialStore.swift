import Foundation
import LocalAuthentication
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Status \(status)"
        return "Schlüsselbund: \(detail)"
    }
}

/// Speichert das Router-Passwort im Schlüsselbund, geschützt durch Face ID / Touch ID
/// (mit Gerätecode als Rückfall). Das Passwort verlässt das Gerät nicht.
enum CredentialStore {
    private static let service = "de.marck.broviremote.router"

    /// Name der verfügbaren biometrischen Methode für die Oberfläche.
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Gerätecode"
        }
    }

    static var biometryIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "touchid"
        case .faceID: return "faceid"
        default: return "lock"
        }
    }

    static func save(password: String, account: String) throws {
        delete(account: account)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw KeychainError(status: errSecParam)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data(password.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Liest das Passwort; iOS zeigt dabei die Face-ID-Abfrage an.
    /// Gibt `nil` zurück, wenn nichts gespeichert ist, und wirft `CancellationError` bei Abbruch.
    static func load(account: String, reason: String) async throws -> String? {
        let service = Self.service
        return try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedReason = reason
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data else { return nil }
                return String(decoding: data, as: UTF8.self)
            case errSecItemNotFound:
                return nil
            case errSecUserCanceled, errSecAuthFailed:
                throw CancellationError()
            default:
                throw KeychainError(status: status)
            }
        }.value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
