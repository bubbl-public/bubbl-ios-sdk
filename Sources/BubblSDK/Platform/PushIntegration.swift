#if os(iOS)
import Foundation
import ObjectiveC
import UIKit
import UserNotifications
#if !COCOAPODS
import BubblCore
#endif

/// Bubbl's part in the app's push handling, with no app code (as Firebase does it):
///  - the device token: the app delegate's application(_:didRegisterForRemoteNotifications…) is
///    extended (given one, if the app has none) to hand Bubbl the token as well;
///  - the notification center's delegate: whichever the app sets (its own, Firebase's,
///    flutter_local_notifications'…) is extended so Bubbl answers for Bubbl's pushes and passes
///    everything else on unchanged; when there's none by the end of launch, Bubbl sets its own.
///
/// BubblAutoIntegrationEnabled = NO in Info.plist turns all of it off: the app then calls
/// Bubbl.setPushToken, Bubbl.willPresent and Bubbl.didReceive from its own code.
@available(iOS 17, *)
enum PushIntegration {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked = false
    @MainActor private static var installed = false

    /// Off with BubblAutoIntegrationEnabled = NO (a Boolean, or "NO" / "false").
    static var enabled: Bool {
        switch Bundle.main.object(forInfoDictionaryKey: "BubblAutoIntegrationEnabled") {
        case let flag as Bool: return flag
        case let text as String: return !["no", "false", "0"].contains(text.lowercased())
        default: return true
        }
    }

    /// Installs once launch has finished: apps and their plugins set their notification delegate
    /// during launch only when there's none yet, so Bubbl's own must not be there first. Taps that
    /// launched the app are delivered after launch, so they still reach it. At the end of launch
    /// (`launchFinished`: Bubbl starting itself) it installs now; started after launch (a
    /// wrapper's JavaScript or Dart), at the next turn of the main loop.
    static func installWhenLaunched(launchFinished: Bool = false) {
        guard enabled else {
            BubblLog.info("Bubbl's push integration is off (BubblAutoIntegrationEnabled): the app hands Bubbl the token and its pushes")
            return
        }
        let first: Bool = lock.sync {
            defer { asked = true }
            return !asked
        }
        guard first else { return }

        if launchFinished, Thread.isMainThread {
            MainActor.assumeIsolated { install() }
            return
        }
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { install() }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { install() }
        }
    }

    @MainActor
    private static func install() {
        guard !installed else { return }
        installed = true
        AppDelegateHooks.install()
        NotificationDelegateHooks.install()
        registerIfAllowed()
    }

    /// Asks iOS for the device token once the user allows notifications: a token for a device that
    /// can't show them would only make pushes that go nowhere look delivered. (Asking for the
    /// permission through Bubbl registers as well.)
    /// (Not main-actor code: iOS answers on a queue of its own, and a main-actor closure run there
    /// is a Swift runtime trap.)
    static func registerIfAllowed() {
        Task {
            let status = await PermissionFlow.notificationAuthorization()
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Bubbl answers for a remote notification (e.g. background geofence sync push); false when it isn't Bubbl's.
    static func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any], _ completion: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        let data = EngineHost.pushData(userInfo)
        guard PushMessage.isBubbl(data) else { return false }
        let done = Handed(completion)
        Task { @MainActor in
            let result = await EngineHost.shared.receivedRemoteNotification(data)
            done.value(result)
        }
        return true
    }
}

// MARK: - The app delegate's token callbacks

@available(iOS 17, *)
enum AppDelegateHooks {
    private typealias DidRegister = @convention(c) (AnyObject, Selector, UIApplication, NSData) -> Void
    private typealias DidFail = @convention(c) (AnyObject, Selector, UIApplication, NSError) -> Void
    private typealias DidReceiveRemote = @convention(c) (AnyObject, Selector, UIApplication, NSDictionary, @escaping @convention(block) (UIBackgroundFetchResult) -> Void) -> Void

    @MainActor
    static func install() {
        guard let delegate = UIApplication.shared.delegate, let cls = object_getClass(delegate) else {
            BubblLog.warning("The app has no delegate, so Bubbl can't get the device token: call Bubbl.setPushToken from the app")
            return
        }

        let didRegister = #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        Swizzle.extend(cls, didRegister, types: "v@:@@") { original in
            let block: @convention(block) (AnyObject, UIApplication, NSData) -> Void = { this, application, token in
                EngineHost.shared.pushTokenReceived(token as Data)
                if let original {
                    unsafeBitCast(original, to: DidRegister.self)(this, didRegister, application, token)
                } else if let target = Swizzle.forwardee(this, didRegister) {
                    // SwiftUI's app delegate hands the app's UIApplicationDelegateAdaptor its
                    // messages; now that Bubbl gave it the method, pass it on the same way.
                    _ = target.perform(didRegister, with: application, with: token)
                }
            }
            return block
        }

        let didFail = #selector(UIApplicationDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:))
        Swizzle.extend(cls, didFail, types: "v@:@@") { original in
            let block: @convention(block) (AnyObject, UIApplication, NSError) -> Void = { this, application, error in
                BubblLog.warning("iOS couldn't give the app a device token (\(error.domain) \(error.code)): pushes can't reach this device")
                if let original {
                    unsafeBitCast(original, to: DidFail.self)(this, didFail, application, error)
                } else if let target = Swizzle.forwardee(this, didFail) {
                    _ = target.perform(didFail, with: application, with: error)
                }
            }
            return block
        }

        let didReceiveRemote = #selector(UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:))
        Swizzle.extend(cls, didReceiveRemote, types: "v@:@@@?") { original in
            let block: @convention(block) (AnyObject, UIApplication, NSDictionary, @escaping @convention(block) (UIBackgroundFetchResult) -> Void) -> Void = { this, application, userInfo, completion in
                let dict = userInfo as? [AnyHashable: Any] ?? [:]
                if PushIntegration.didReceiveRemoteNotification(dict, completion) { return }
                if let original {
                    unsafeBitCast(original, to: DidReceiveRemote.self)(this, didReceiveRemote, application, userInfo, completion)
                } else if let target = Swizzle.forwardee(this, didReceiveRemote) {
                    if let delegate = target as? UIApplicationDelegate {
                        delegate.application?(application, didReceiveRemoteNotification: dict, fetchCompletionHandler: completion)
                    } else if let method = class_getInstanceMethod(object_getClass(target), didReceiveRemote) {
                        let imp = method_getImplementation(method)
                        unsafeBitCast(imp, to: DidReceiveRemote.self)(target, didReceiveRemote, application, userInfo, completion)
                    } else {
                        completion(.noData)
                    }
                } else {
                    completion(.noData)
                }
            }
            return block
        }
    }
}

// MARK: - The notification center's delegate

@available(iOS 17, *)
enum NotificationDelegateHooks {
    private typealias SetDelegate = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    private typealias WillPresent = @convention(c) (AnyObject, Selector, UNUserNotificationCenter, UNNotification, @escaping @convention(block) (UNNotificationPresentationOptions) -> Void) -> Void
    private typealias DidReceive = @convention(c) (AnyObject, Selector, UNUserNotificationCenter, UNNotificationResponse, @escaping @convention(block) () -> Void) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hooked: Set<ObjectIdentifier> = []
    /// Bubbl's own delegate when the app has none, kept alive here (the center holds it weakly).
    nonisolated(unsafe) private static var own: BubblNotificationCenterDelegate?

    @MainActor
    static func install() {
        hookSetDelegate()
        let center = UNUserNotificationCenter.current()
        if let delegate = center.delegate {
            hook(object_getClass(delegate))
        } else {
            let delegate = BubblNotificationCenterDelegate()
            lock.sync { own = delegate }
            center.delegate = delegate
        }
    }

    /// Bubbl answers for a push arriving in front when it's Bubbl's; false when it isn't (then the
    /// app's own handling decides).
    static func willPresent(_ notification: UNNotification, _ completion: @escaping (UNNotificationPresentationOptions) -> Void) -> Bool {
        let data = EngineHost.pushData(notification.request.content.userInfo)
        guard PushMessage.isBubbl(data) else { return false }
        arrived(data, completion)
        return true
    }

    /// Bubbl answers for a tap on its push's notification; false when it isn't Bubbl's.
    static func didReceive(_ response: UNNotificationResponse, _ completion: @escaping () -> Void) -> Bool {
        let data = EngineHost.pushData(response.notification.request.content.userInfo)
        guard PushMessage.isBubbl(data) else { return false }
        opened(data, tapped: response.actionIdentifier == UNNotificationDefaultActionIdentifier, completion)
        return true
    }

    // iOS's completion handlers are called on the main thread, whatever thread the delegate was
    // called on and wherever the work in between ran: UIKit's for a notification response updates
    // the app's snapshot and state restoration, and asserts it's on the main thread (a tap on a
    // campaign push crashed TestFlight build 6 at launch when it wasn't).

    /// A Bubbl push arriving in front: how to present it, handed to `completion` on the main thread.
    static func arrived(_ data: [String: JSONValue], _ completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        let done = Handed(completion)
        Task { @MainActor in
            let options = await EngineHost.shared.presentation(forArriving: data)
            done.value(options)
        }
    }

    /// A Bubbl push's notification answered (`tapped`: opened), then `completion` on the main thread.
    static func opened(_ data: [String: JSONValue], tapped: Bool, _ completion: @escaping () -> Void) {
        let done = Handed(completion)
        Task { @MainActor in
            if tapped { await EngineHost.shared.pushOpened(data) }
            done.value()
        }
    }

    /// A delegate the app sets later (after Bubbl's, or replacing another) is extended too.
    private static func hookSetDelegate() {
        let selector = #selector(setter: UNUserNotificationCenter.delegate)
        guard let method = class_getInstanceMethod(UNUserNotificationCenter.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: SetDelegate.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { center, delegate in
            original(center, selector, delegate)
            if let delegate, !(delegate is BubblNotificationCenterDelegate) { hook(object_getClass(delegate)) }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func hook(_ cls: AnyClass?) {
        guard let cls, lock.sync({ hooked.insert(ObjectIdentifier(cls)).inserted }) else { return }

        let willPresentSelector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))
        Swizzle.extend(cls, willPresentSelector, types: "v@:@@@?") { original in
            let block: @convention(block) (AnyObject, UNUserNotificationCenter, UNNotification, @escaping @convention(block) (UNNotificationPresentationOptions) -> Void) -> Void = { this, center, notification, completion in
                if willPresent(notification, completion) { return }
                if let original {
                    unsafeBitCast(original, to: WillPresent.self)(this, willPresentSelector, center, notification, completion)
                } else {
                    // The app's delegate doesn't handle pushes in front: iOS's default, not shown.
                    completion([])
                }
            }
            return block
        }

        let didReceiveSelector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
        Swizzle.extend(cls, didReceiveSelector, types: "v@:@@@?") { original in
            let block: @convention(block) (AnyObject, UNUserNotificationCenter, UNNotificationResponse, @escaping @convention(block) () -> Void) -> Void = { this, center, response, completion in
                if didReceive(response, completion) { return }
                if let original {
                    unsafeBitCast(original, to: DidReceive.self)(this, didReceiveSelector, center, response, completion)
                } else {
                    completion()
                }
            }
            return block
        }
    }
}

/// The notification center's delegate when the app has none: Bubbl's pushes are Bubbl's to
/// handle; others are left as iOS would (not shown in front, a tap just opens the app).
/// (The async forms: they match the protocol however its completion handlers are annotated.)
/// On the main actor, so iOS's completion handlers (which Swift calls when these return) run on
/// the main thread: nonisolated, they returned on a background thread (see `opened`).
@available(iOS 17, *)
@MainActor
final class BubblNotificationCenterDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let data = EngineHost.pushData(notification.request.content.userInfo)
        guard PushMessage.isBubbl(data) else { return [] }
        return await EngineHost.shared.presentation(forArriving: data)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let data = EngineHost.pushData(response.notification.request.content.userInfo)
        guard PushMessage.isBubbl(data), response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await EngineHost.shared.pushOpened(data)
    }
}

// MARK: - Extending a class's method

@available(iOS 17, *)
enum Swizzle {
    /// Gives `cls` its own `selector`, implemented by the block `make` returns for the original
    /// implementation: the class's own or a superclass's, nil when it had none. A superclass's
    /// implementation is left as it was, so other subclasses aren't touched.
    static func extend(_ cls: AnyClass, _ selector: Selector, types: String, _ make: (IMP?) -> Any) {
        let inherited = class_getInstanceMethod(cls, selector)
        let replacement = imp_implementationWithBlock(make(inherited.map(method_getImplementation)))
        let added = if let inherited, let encoding = method_getTypeEncoding(inherited) {
            class_addMethod(cls, selector, replacement, encoding)
        } else {
            class_addMethod(cls, selector, replacement, types)
        }
        // The class defines it itself: replace it there (the original is that one).
        if !added, let own = class_getInstanceMethod(cls, selector) { method_setImplementation(own, replacement) }
    }

    /// Where an object sends a message it doesn't implement itself (SwiftUI's app delegate sends
    /// the app's UIApplicationDelegateAdaptor its messages this way), if anywhere else.
    static func forwardee(_ object: AnyObject, _ selector: Selector) -> NSObject? {
        guard let target = (object as? NSObject)?.forwardingTarget(for: selector) as? NSObject,
              target !== object, target.responds(to: selector)
        else { return nil }
        return target
    }
}
#endif
