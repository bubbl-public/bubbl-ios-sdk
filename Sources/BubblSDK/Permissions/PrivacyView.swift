#if os(iOS)
import SwiftUI
import UIKit
#if !COCOAPODS
import BubblCore
#endif

/// The privacy view: why Bubbl is about to ask for a permission, shown before the system's prompt
/// (when the dashboard's notice mode says so), in the dashboard's words when it has set some, with
/// its privacy policy link. Continue is its only action, and always goes on to the prompt (App Store
/// guideline 5.1.1(iv): nothing here may offer to delay or skip it). It's a window of its own, with
/// nothing to swipe away, so Continue is the only way past it.
@available(iOS 17, *)
@MainActor
enum PrivacyView {
    private static var window: UIWindow?

    /// Returns once Continue is tapped. With no screen to show it on, it returns at once.
    static func show(kind: String, text: String?, policy: String?) async {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard window == nil, let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let previousKey = scene.windows.first { $0.isKeyWindow }
            let view = PrivacyExplanation(kind: kind, text: text, policy: policy) {
                window?.isHidden = true
                window = nil
                previousKey?.makeKey()
                continuation.resume()
            }
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            let created = UIWindow(windowScene: scene)
            created.windowLevel = .alert + 1
            created.rootViewController = host
            created.makeKeyAndVisible()
            window = created
        }
    }
}

@available(iOS 17, *)
struct PrivacyExplanation: View {
    let kind: String
    let text: String?
    let policy: String?
    let done: @MainActor () -> Void

    private var title: String {
        switch kind {
        case "notifications": Words.text("bubbl_permission_notifications_title", "Stay in the loop")
        case "background_location": Words.text("bubbl_permission_background_title", "Offers even when the app is closed")
        default: Words.text("bubbl_permission_location_title", "Offers near you")
        }
    }

    private var message: String {
        switch kind {
        case "notifications": Words.text("bubbl_permission_notifications_body", "Allow notifications to hear about offers and updates as they happen.")
        case "background_location": Words.text("bubbl_permission_background_body", "To hear about places nearby while the app isn't open, choose \"Change to Always Allow\" when asked. You can change this at any time in Settings.")
        default: Words.text("bubbl_permission_location_body", "Allow your location to get offers and messages when you're near the places they're for.")
        }
    }

    var body: some View {
        ZStack {
            Look.scrim.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Look.onSurface)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Look.onSurfaceMuted)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                    if let text, !text.isEmpty {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(Look.onSurfaceMuted)
                            .padding(.top, 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let policy, LinkPolicy.canOpen(policy), let url = URL(string: policy) {
                        Link(Words.text("bubbl_privacy_policy", "Privacy policy"), destination: url)
                            .font(.subheadline)
                            .tint(Look.accent)
                            .padding(.top, 12)
                    }
                    PrimaryButton(title: Words.text("bubbl_continue", "Continue")) { done() }
                        .padding(.top, 20)
                        .accessibilityIdentifier("bubbl.continue")
                }
                .padding(Look.cardPadding)
                .background(Look.surface)
                .clipShape(RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
                .frame(maxWidth: Look.cardMaxWidth)
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityAddTraits(.isModal)
    }
}
#endif
