/// One HTTP request as the engine sends it: the full URL, and the body's exact text.
package struct HttpRequest: Sendable, Equatable {
    package var method: String
    package var url: String
    package var headers: [String: String]
    package var body: String?

    package init(method: String, url: String, headers: [String: String] = [:], body: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// The response: status, body text and headers (names as the server sent them).
package struct HttpResponse: Sendable, Equatable {
    package var status: Int
    package var body: String
    package var headers: [String: [String]]

    package init(status: Int, body: String, headers: [String: [String]] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// A header's first value, matched without regard to case (HTTP header names aren't).
    package func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.first
    }
}

/// Sends one request. The engine's only way out to the network, so tests swap it for a fake
/// and no HTTP library is forced on the app. Throws when there's no response at all (offline,
/// timed out); any HTTP status is a response.
package protocol HttpClient: Sendable {
    func execute(_ request: HttpRequest) async throws -> HttpResponse
}
