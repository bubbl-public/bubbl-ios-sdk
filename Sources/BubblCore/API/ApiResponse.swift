import Foundation

/// A device API v1 response: its status, body and headers, and — for an error — what the engine
/// should do about it (`handling`, from the contract's error table).
package struct ApiResponse: Sendable {
    package let status: Int
    package let body: String
    private let raw: HttpResponse
    private let forcedHandling: ErrorHandling?

    package init(_ raw: HttpResponse, handledAs forcedHandling: ErrorHandling? = nil) {
        status = raw.status
        body = raw.body
        self.raw = raw
        self.forcedHandling = forcedHandling
    }

    package var isSuccessful: Bool { (200...299).contains(status) || status == 304 }

    /// The body as a JSON object, or nil when it isn't one (a 304, or a proxy's error page).
    package var json: [String: Any]? { JSON.object(body) }

    /// The body decoded as `T`, or nil when it isn't one. Codable reads the same on every
    /// platform, so parsing goes through here rather than `json`.
    package func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(body.utf8))
    }

    /// The error's stable `code`, when the body has one.
    package var code: String? {
        (json?["code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What to do about a failed response; nil for a success.
    package var handling: ErrorHandling? {
        isSuccessful ? nil : forcedHandling ?? ErrorActions.forResponse(status: status, code: code)
    }

    /// The same response, handled as `handling` says instead of by its code.
    package func handled(as handling: ErrorHandling) -> ApiResponse {
        ApiResponse(raw, handledAs: handling)
    }

    package func header(_ name: String) -> String? { raw.header(name) }
}

/// Why a call to the device API didn't get through, reduced to what whoever scheduled it (a
/// background task, an app resume) has to do next. Built from the contract's error table.
package enum ApiFailure: Sendable, Equatable {
    /// Try again later with exponential backoff (5xx, no network).
    case backoff
    /// The server asked for a wait (429, request_in_progress).
    case retryAfter(seconds: Int)
    /// Stop calling the API for a while (workspace paused, free tier); keep queuing.
    case pause(hours: Int, code: String?)
    /// The server doesn't know this device yet: PUT /device, then try again.
    case describeDevice
    /// The request can never succeed as sent: discard it (and refetch geofences, if said).
    case drop(refreshGeofences: Bool, status: Int, code: String?)
    /// Something only a developer can fix (misconfiguration): surface it in diagnostics.
    case stopped(status: Int, code: String?)

    private static let defaultRetrySeconds = 30
    private static let defaultPauseHours = 1

    /// What a failed `response` means for the caller. Never called with a success.
    package static func of(_ response: ApiResponse) -> ApiFailure {
        guard let handling = response.handling else { return .stopped(status: response.status, code: response.code) }

        switch handling.action {
        case .backoff:
            return .backoff
        case .waitAndRetry:
            let seconds = response.header("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .retryAfter(seconds: max(seconds ?? defaultRetrySeconds, 1))
        case .pause:
            return .pause(hours: handling.pauseHours ?? defaultPauseHours, code: response.code)
        case .describeDevice:
            return .describeDevice
        case .drop:
            return .drop(refreshGeofences: false, status: response.status, code: response.code)
        case .dropAndRefreshGeofences:
            return .drop(refreshGeofences: true, status: response.status, code: response.code)
        // The client has already registered again or corrected the clock once; what's left of
        // those, and everything else, needs a person.
        case .reRegister, .correctClockAndRetry, .stopAndReport, .showMessage:
            return .stopped(status: response.status, code: response.code)
        }
    }
}
