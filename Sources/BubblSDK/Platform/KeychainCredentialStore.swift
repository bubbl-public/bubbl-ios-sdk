#if canImport(Security)
import Foundation
import Security
#if !COCOAPODS
import BubblCore
#endif

/// The install's credential in the Keychain: this device only, readable after the first unlock
/// (so a region event after a reboot, before the phone is unlocked, finds it locked rather than
/// missing, and the engine waits instead of registering again).
@available(iOS 17, *)
final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String
    private let account = "credential"
    private let lock = NSLock()

    private struct Stored: Codable {
        let keyId: String
        let secret: String
    }

    init(service: String = "tech.bubbl.sdk") {
        self.service = service
    }

    func read() -> CredentialRead {
        lock.sync {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
                    // Unreadable content: as good as none (registering again replaces it).
                    return .missing
                }
                return .present(SigningCredential(keyId: stored.keyId, secret: stored.secret))
            case errSecItemNotFound:
                return .missing
            default:
                // errSecInteractionNotAllowed before the first unlock, and anything else the
                // Keychain can't do right now: try again later, never "not registered".
                report(status, "read")
                return .unavailable
            }
        }
    }

    private var reportedMissingEntitlement = false

    /// A Keychain failure, logged. Most pass (the device locked since a reboot): a debug line. An app
    /// that can't use the Keychain at all (errSecMissingEntitlement: not code-signed, or signed with
    /// no keychain access) never will, and all of Bubbl's work waits on it, so that's an error, once,
    /// which diagnostics' lastError shows.
    private func report(_ status: OSStatus, _ operation: String) {
        guard status == errSecMissingEntitlement else {
            BubblLog.debug("Keychain \(operation) unavailable (\(status))")
            return
        }
        guard !reportedMissingEntitlement else { return }
        reportedMissingEntitlement = true
        BubblLog.error("The app can't use the Keychain (errSecMissingEntitlement): is it code-signed? Bubbl can't keep its credential, so nothing is sent")
    }

    func save(keyId: String, secret: String) throws {
        let data = try JSONEncoder().encode(Stored(keyId: keyId, secret: secret))
        try lock.sync {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = baseQuery
                add.merge(update) { _, new in new }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                report(status, "save")
                throw KeychainError(status: status)
            }
        }
    }

    func clear() throws {
        try lock.sync {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                BubblLog.warning("The Keychain couldn't forget the credential (\(status))")
                throw KeychainError(status: status)
            }
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // The data-protection keychain on macOS too, so it behaves as on iOS.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

@available(iOS 17, *)
struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "Keychain error \(status)" }
}
#endif
