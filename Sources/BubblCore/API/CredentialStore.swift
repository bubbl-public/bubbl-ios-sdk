import Foundation

/// The install's credential, read together so a registration in between can't mix old and new.
package struct SigningCredential: Sendable, Equatable {
    package let keyId: String
    package let secret: String

    package init(keyId: String, secret: String) {
        self.keyId = keyId
        self.secret = secret
    }
}

/// What reading the credential found. `unavailable` is not `missing`: before the first unlock
/// after a reboot iOS can relaunch the app (for a region event) while the Keychain can't be read
/// yet. Taking that for "not registered" would register again and replace a working credential.
package enum CredentialRead: Sendable, Equatable {
    case present(SigningCredential)
    case missing
    case unavailable
}

/// Where the install's signing credential lives: the Keychain on a device
/// (AfterFirstUnlockThisDeviceOnly), memory in tests.
package protocol CredentialStore: Sendable {
    /// The key id and secret, read together.
    func read() -> CredentialRead

    /// Keep a new credential, replacing any old one. Throws when it couldn't be kept (the Keychain
    /// refused it): the registration it came from then doesn't count.
    func save(keyId: String, secret: String) throws

    /// Forget the credential (deleteMyData, or an earlier installation's). Throws when it couldn't
    /// be forgotten (the Keychain refused), so nothing claims the device's data is gone when it isn't.
    func clear() throws
}

/// A credential kept only while this install's id is. On iOS the Keychain outlives the app and its
/// files don't: after a reinstall the old install's credential would sign for a new install id.
/// A credential with no install id beside it (none saved, not merely unreadable) belongs to an
/// earlier installation, so it's forgotten and this install registers as itself, as on Android,
/// where uninstalling wipes the Keystore. Checked once per process: from then on a credential is
/// only saved by a registration, which makes the install id first.
package final class InstallBoundCredentialStore: CredentialStore, @unchecked Sendable {
    private let base: any CredentialStore
    private let installId: any ValueStore<String>
    private let lock = NSLock()
    private var checked = false

    package init(_ base: any CredentialStore, installId: any ValueStore<String>) {
        self.base = base
        self.installId = installId
    }

    package func read() -> CredentialRead {
        lock.sync {
            let read = base.read()
            guard !checked, case .present = read else {
                if read == .missing { checked = true }
                return read
            }
            let id: String?
            do {
                id = try installId.load()
            } catch {
                return .unavailable
            }
            if let id, !id.isEmpty {
                checked = true
                return read
            }
            do {
                try base.clear()
            } catch {
                // Still there: not this install's, and not gone either. Asked again next time.
                return .unavailable
            }
            checked = true
            BubblLog.info("A credential left by an earlier installation of the app was forgotten")
            return .missing
        }
    }

    package func save(keyId: String, secret: String) throws {
        try base.save(keyId: keyId, secret: secret)
    }

    package func clear() throws {
        try base.clear()
    }
}

/// A CredentialStore in memory: for tests, and for nothing else.
package final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: SigningCredential?

    package init() {}

    /// The current key id, for tests.
    package func keyId() -> String? {
        lock.sync { credential?.keyId }
    }

    package func read() -> CredentialRead {
        lock.sync { credential.map(CredentialRead.present) ?? .missing }
    }

    package func save(keyId: String, secret: String) throws {
        lock.sync { credential = SigningCredential(keyId: keyId, secret: secret) }
    }

    package func clear() throws {
        lock.sync { credential = nil }
    }
}
