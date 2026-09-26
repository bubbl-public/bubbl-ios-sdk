import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if !COCOAPODS
import BubblCore
#endif

/// The engine's way to the network: an ephemeral URLSession of its own.
///  - No URL cache: a 304 for the engine's own If-None-Match reaches it as a 304, not as a
///    cached 200.
///  - No redirects followed: the request is signed for its own URL, and a redirect would carry
///    the signing headers to another host.
///  - Explicit timeouts, so work never hangs past what a background task allows.
@available(iOS 17, *)
final class URLSessionHttpClient: HttpClient, @unchecked Sendable {
    private let session: URLSession

    /// - Parameter protocolClasses: for tests, URLProtocols that answer instead of the network.
    init(requestTimeout: TimeInterval = 20, resourceTimeout: TimeInterval = 40, protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func execute(_ request: HttpRequest) async throws -> HttpResponse {
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        urlRequest.httpBody = request.body.map { Data($0.utf8) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            BubblLog.warning("An http:// baseUrl needs NSAllowsLocalNetworking under NSAppTransportSecurity in the app's Info.plist")
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        var headers: [String: [String]] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String { headers[name] = [String(describing: value)] }
        }
        return HttpResponse(status: http.statusCode, body: String(decoding: data, as: UTF8.self), headers: headers)
    }
}

/// Returns a redirect as the response itself (a 3xx the engine treats like any other status)
/// instead of following it.
@available(iOS 17, *)
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
