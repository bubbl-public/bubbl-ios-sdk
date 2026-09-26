import Foundation

/// What `Bubbl.registerTestDevice` came to: approved as a Sandbox test device, or not, and why.
public struct BubblTestDeviceResult: Sendable, Equatable {
    public let approved: Bool
    /// Why not, when not approved, to show whoever typed the code: the server's words (a wrong,
    /// used or expired code, the Sandbox's test devices all taken) or the SDK's (before `start`,
    /// no network, below iOS 17). Nil when approved.
    public let message: String?
}
