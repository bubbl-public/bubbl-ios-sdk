import Foundation

/// What a build's provisioning profile (embedded.mobileprovision) says about push: which APNs
/// environment its device tokens belong to. A development-signed build's tokens are sandbox
/// tokens; ad hoc, TestFlight and App Store builds' are production ones. Sent with the token
/// (PUT /device apns_environment), since a token sent to the wrong environment is refused
/// (BadDeviceToken).
package enum ProvisioningProfile {
    /// "sandbox" or "production" from the profile's aps-environment entitlement; nil when the data
    /// isn't a profile or the app has no push entitlement.
    ///
    /// A profile is a CMS-signed file with its property list in plain text inside, so the plist is
    /// cut out between "<?xml" and "</plist>" rather than verifying the signature (iOS did that
    /// when it installed the app).
    package static func apnsEnvironment(_ profile: Data) -> String? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return nil }
        return environment == "development" ? "sandbox" : "production"
    }
}
