#if os(iOS)
import Foundation
import UniformTypeIdentifiers
import UserNotifications
#if !COCOAPODS
import BubblCore
#endif

/// Adds the picture to Bubbl's pushes (optional). Add a Notification Service Extension target to
/// the app, add this package's BubblNotificationService product to it, and make the extension's
/// principal class a subclass:
///
///     import BubblNotificationService
///     class NotificationService: BubblNotificationService {}
///
/// The push's image_url is downloaded (https only, at most 10 MB, within the time iOS gives) and
/// attached; anything that goes wrong shows the push as it came. Other pushes pass through
/// untouched (and all of them below iOS 17, where Bubbl does nothing): an app with its own
/// extension work can override `didReceive` and call `super` only for pushes where `isBubbl(_:)`
/// is true.
///
/// Nothing is recorded here: the extension is a separate process with no access to Bubbl's
/// state, and it doesn't need any.
open class BubblNotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private static let maxImageBytes = 10 * 1024 * 1024

    private let lock = NSLock()
    private var deliver: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var download: URLSessionDownloadTask?

    /// How long the picture may take to download. iOS gives the extension about 30 s in all.
    open var imageTimeout: TimeInterval { 20 }

    /// Whether a push is Bubbl's.
    public static func isBubbl(_ request: UNNotificationRequest) -> Bool {
        PushMessage.isBubbl(data(request.content.userInfo))
    }

    open override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Below iOS 17 Bubbl does nothing: pushes pass through as they came.
        guard #available(iOS 17, *) else {
            contentHandler(request.content)
            return
        }
        guard let imageUrl = PushMessage.imageUrl(Self.data(request.content.userInfo)),
              let url = URL(string: imageUrl),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else {
            contentHandler(request.content)
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = imageTimeout
        let session = URLSession(configuration: configuration)
        let task = session.downloadTask(with: url) { [weak self] location, response, _ in
            self?.attach(location, response)
            self?.finish()
        }
        lock.sync {
            deliver = contentHandler
            self.content = content
            download = task
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }

    /// iOS is about to end the extension: show the push with whatever is ready.
    open override func serviceExtensionTimeWillExpire() {
        lock.sync { download }?.cancel()
        finish()
    }

    @available(iOS 17, *)
    private func attach(_ location: URL?, _ response: URLResponse?) {
        guard let location, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= Self.maxImageBytes
        else { return }

        // iOS tells the picture's kind from the file's extension: from the MIME type, else the URL.
        let fromMime = http.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
        guard let fileExtension = fromMime ?? http.url.map(\.pathExtension).flatMap({ $0.isEmpty ? nil : $0 }) else { return }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try FileManager.default.moveItem(at: location, to: file)
            let attachment = try UNNotificationAttachment(identifier: "bubbl-image", url: file)
            lock.sync { content?.attachments = [attachment] }
        } catch {
            // Not a picture iOS can show: the push goes as it came.
        }
    }

    /// Hands iOS the content, once (the download and the time running out may both get here).
    private func finish() {
        let (deliver, content) = lock.sync {
            defer { self.deliver = nil }
            return (self.deliver, self.content)
        }
        if let deliver, let content { deliver(content) }
    }

    /// The push's top-level data as JSON: Bubbl's keys are strings (or 1/true for the flags).
    private static func data(_ userInfo: [AnyHashable: Any]) -> [String: JSONValue] {
        var data: [String: JSONValue] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String else { continue }
            switch value {
            case let text as String:
                data[key] = .string(text)
            case let number as NSNumber:
                data[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .int(number.int64Value)
            default:
                continue
            }
        }
        return data
    }
}
#endif
