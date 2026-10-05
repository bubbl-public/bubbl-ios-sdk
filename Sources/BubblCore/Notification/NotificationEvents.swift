import Foundation

/// The events a notification's life produces, in the contract's shapes (events.json), handed to
/// `enqueue` (the event queue). Each carries the campaign_notification_id, as the contract asks.
package struct NotificationEvents: Sendable {
    private let observe: @Sendable (_ type: String, _ notification: BubblNotification) -> Void
    private let enqueue: @Sendable (_ type: String, _ data: [String: JSONValue]) async throws -> Void

    /// - Parameter observe: told of each event as it's recorded (the app's event listeners).
    package init(
        observe: @escaping @Sendable (String, BubblNotification) -> Void = { _, _ in },
        enqueue: @escaping @Sendable (String, [String: JSONValue]) async throws -> Void
    ) {
        self.observe = observe
        self.enqueue = enqueue
    }

    package func displayed(_ n: BubblNotification) async throws {
        var data = base(n)
        if let location = n.locationId { data["location_id"] = .string(location) }
        try await record("notification.displayed", n, data)
    }

    package func opened(_ n: BubblNotification) async throws { try await record("notification.opened", n, base(n)) }
    package func dismissed(_ n: BubblNotification) async throws { try await record("notification.dismissed", n, base(n)) }
    package func ctaClicked(_ n: BubblNotification) async throws { try await record("notification.cta_clicked", n, base(n)) }
    package func surveyStarted(_ n: BubblNotification) async throws { try await record("notification.survey_started", n, base(n)) }

    /// Throws SurveyProblem when the form isn't complete: nothing is recorded.
    package func surveySubmitted(_ n: BubblNotification, _ form: SurveyForm) async throws {
        guard let data = form.eventData(n.campaignNotificationId) else {
            throw SurveyProblem("\"\(form.missing.first?.text ?? "")\" needs an answer")
        }
        try await record("survey.submitted", n, data)
    }

    package func mediaViewed(_ n: BubblNotification, positionSeconds: Double) async throws {
        var data = base(n)
        data["position_seconds"] = .double(positionSeconds)
        try await record("media.viewed", n, data)
    }

    package func mediaCompleted(_ n: BubblNotification, positionSeconds: Double) async throws {
        var data = base(n)
        data["position_seconds"] = .double(positionSeconds)
        try await record("media.completed", n, data)
    }

    private func record(_ type: String, _ n: BubblNotification, _ data: [String: JSONValue]) async throws {
        try await enqueue(type, data)
        observe(type, n)
    }

    private func base(_ n: BubblNotification) -> [String: JSONValue] {
        ["campaign_notification_id": .string(n.campaignNotificationId)]
    }
}

/// The notifications shown lately, so one that arrives twice (a push and then a pull, a push
/// retried) is only shown once. Keeps the most recent `capacity`.
package final class RecentNotifications: Sendable {
    private let store: any ValueStore<[String]>
    private let capacity: Int
    private let lock = NSLock()

    package init(store: any ValueStore<[String]>, capacity: Int = 200) {
        self.store = store
        self.capacity = capacity
    }

    /// True the first time `campaignNotificationId` is seen; false after that. When the list can't
    /// be read (before the first unlock) it's taken as the first time: showing a notification
    /// twice beats losing it.
    package func firstTime(_ campaignNotificationId: String) -> Bool {
        lock.sync {
            guard let ids = try? store.load() ?? [] else { return true }
            if ids.contains(campaignNotificationId) { return false }
            try? store.save(Array((ids + [campaignNotificationId]).suffix(capacity)))
            return true
        }
    }
}

/// Which links from a campaign (a CTA, a media link) the SDK opens: web links and app links,
/// never schemes that reach into the device or run code.
package enum LinkPolicy {
    /// Schemes that reach into the device or run code.
    private static let blocked: Set<String> = ["javascript", "file", "content", "intent", "data", "android-app", "about"]

    /// Apple's own `itms-` schemes are not a campaign's to open (one of them installs an app from a
    /// link), bar the App Store's. Matched as a family, so none is named: new ones are covered too,
    /// and nothing in the SDK spells out the app-install scheme (an App Review scan flagged the name).
    private static let appleFamily = "itms-"
    private static let appStoreLinks: Set<String> = ["itms-apps", "itms-appss"]

    package static func canOpen(_ url: String) -> Bool {
        guard let scheme = scheme(of: url.trimmingCharacters(in: .whitespaces)) else { return false }
        if scheme.hasPrefix(appleFamily) { return appStoreLinks.contains(scheme) }
        return !blocked.contains(scheme)
    }

    /// The URL's scheme (RFC 3986: a letter, then letters, digits, + - .), lower-cased; nil when
    /// it has none. Read here rather than by URL(string:), whose leniency differs by platform.
    private static func scheme(of url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let scheme = url[..<colon]
        guard let first = scheme.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first),
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) }),
              !url[url.index(after: colon)...].contains(" ")
        else { return nil }
        return scheme.lowercased()
    }
}

/// Embedding a YouTube video in the notification screen.
package enum YouTube {
    private static let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"]

    /// The video id in a YouTube link (watch?v=, youtu.be/, /embed/, /shorts/, /live/), or nil when
    /// it isn't one. Only a well-formed id comes back, since it goes into the embed page.
    package static func videoId(_ url: String) -> String? {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased()
        else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)

        let candidate: String?
        if host == "youtu.be" {
            candidate = segments.first
        } else if hosts.contains(host), segments.first == "watch" {
            candidate = components.queryItems?.first { $0.name == "v" }?.value
        } else if hosts.contains(host), let first = segments.first, ["embed", "shorts", "live", "v"].contains(first), segments.count > 1 {
            candidate = segments[1]
        } else {
            candidate = nil
        }
        return candidate.flatMap { isVideoId($0) ? $0 : nil }
    }

    /// The page the embedded player lives in: YouTube's privacy-enhanced player (no cookies until
    /// the video plays) filling the frame, starting at once since the person has just tapped Play.
    /// `origin` identifies the app to YouTube, which refuses embeds that don't say where they are
    /// (load the page with that origin as its base URL). Nil when `videoId` isn't one.
    package static func embedHtml(videoId: String, origin: String) -> String? {
        guard isVideoId(videoId) else { return nil }
        // RFC 3986 unreserved characters stay as they are; everything else is escaped.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedOrigin = origin.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        let src = "https://www.youtube-nocookie.com/embed/\(videoId)?autoplay=1&playsinline=1&rel=0&origin=\(encodedOrigin)"
        return """
            <!doctype html><html><head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
            </head><body>
            <iframe src="\(src)" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
            </body></html>
            """
    }

    /// Eleven of A–Z a–z 0–9 _ -.
    private static func isVideoId(_ value: String) -> Bool {
        value.unicodeScalars.count == 11 && value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }
    }
}
