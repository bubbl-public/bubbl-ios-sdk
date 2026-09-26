import Foundation
#if !COCOAPODS
import BubblCore
#endif

/// A device credential issued outside the app (installs provisioned ahead of time, an app's own
/// pairing flow), for `Bubbl.start(credential:options:)` instead of an API key. The same as
/// Android's BubblCredential. Its secret is kept in the Keychain and never shown: not in
/// `description`, not by `dump` or the debugger.
public struct BubblCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let keyId: String
    public let secret: String
    /// The install the credential was issued for (a pairing flow passes the install_id it paired
    /// with).
    public let installId: String

    public init(keyId: String, secret: String, installId: String) {
        self.keyId = keyId
        self.secret = secret
        self.installId = installId
    }

    public var description: String { "BubblCredential(keyId: \(keyId), installId: \(installId), secret: hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["keyId": keyId, "installId": installId, "secret": "hidden"], displayStyle: .struct)
    }

    var issued: IssuedCredential { IssuedCredential(keyId: keyId, secret: secret, installId: installId) }
}
