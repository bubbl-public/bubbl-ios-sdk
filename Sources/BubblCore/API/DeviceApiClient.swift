import Foundation

/// Why a request wasn't made, other than having no network. Both mean "later": nothing was
/// refused, and the install keeps its identity.
package enum DeviceApiError: Error {
    /// The credential can't be read yet (the device hasn't been unlocked since it started).
    /// Registering now would replace a working credential, so the request waits instead.
    case credentialsLocked
    /// POST /installs succeeded but its credential couldn't be kept, so it doesn't count.
    case credentialNotSaved(any Error)
}

/// The engine's client for the device API v1 (contracts/v1/device-api-v1.yaml): registers the
/// install, signs every other request with its credential, and deals with the errors that have
/// one right answer, so callers only see the rest:
///
///  - no credential yet: POST /installs first;
///  - timestamp_out_of_range: take the server's clock, retry once;
///  - invalid_key / invalid_signature / credential_revoked: register again, once, then retry
///    once (a second failure is returned as it is, so this can never loop).
///
/// Every response's Date header keeps the clock in step. Registering is serialised: requests
/// that find the credential missing or refused wait for one registration rather than each
/// doing one (found on a device: sync, config and geofences all start at once on first launch).
package final class DeviceApiClient: Sendable {
    private let baseUrl: String
    /// Nil for a device started with a credential issued outside the app: it never registers.
    private let apiKey: String?
    private let onCredentialRejected: @Sendable () -> Void
    private let userAgent: String
    private let http: any HttpClient
    private let credentials: any CredentialStore
    private let clock: ServerClock
    private let installBody: @Sendable () throws -> [String: Any]
    private let onRegistered: @Sendable ([String: Any]) -> Void
    private let registration = AsyncMutex()
    private let serverErrors = ServerErrorStreak()

    /// - Parameters:
    ///   - installBody: what POST /installs sends (api_key is added here): the install id the SDK
    ///     keeps for this installation, and what the device says about itself. It throws when the
    ///     install id can't be read yet (before the first unlock): nothing is sent then.
    ///   - onRegistered: told the install response's `data` (device and config) after each
    ///     successful registration.
    package init(
        baseUrl: String,
        apiKey: String?,
        sdkVersion: String,
        http: any HttpClient,
        credentials: any CredentialStore,
        clock: ServerClock,
        installBody: @escaping @Sendable () throws -> [String: Any],
        onRegistered: @escaping @Sendable ([String: Any]) -> Void = { _ in },
        onCredentialRejected: @escaping @Sendable () -> Void = {}
    ) {
        var trimmed = baseUrl
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseUrl = trimmed
        self.apiKey = apiKey
        userAgent = "Bubbl-iOS-SDK/\(sdkVersion)"
        self.http = http
        self.credentials = credentials
        self.clock = clock
        self.installBody = installBody
        self.onRegistered = onRegistered
        self.onCredentialRejected = onCredentialRejected
    }

    /// POST /installs: registers (or registers again) and keeps the credential it returns.
    /// Unsigned; the public API key identifies the company. The response tells the caller why
    /// when it failed (e.g. own_app_not_in_plan, or a wrong API key).
    package func register() async throws -> ApiResponse {
        try await registration.withLock { try await self.registerLocked() }
    }

    /// A signed request to `path` (from the API root, no leading slash: "api/v1/geofences").
    /// `query` values are sent as given; `body` is sent and signed byte for byte; `headers` are
    /// added as they are (e.g. Idempotency-Key, If-None-Match).
    ///
    /// Throws when the request couldn't be made at all: no response (offline), or a
    /// `DeviceApiError` (the credential can't be read yet, or couldn't be kept). Either way it's
    /// worth trying again later; nothing was refused.
    package func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> ApiResponse {
        if try credentialKeyId() == nil {
            // The first to get here registers; the rest wait, find the credential, and use it.
            let registered = try await registration.withLock { () async throws -> ApiResponse? in
                try self.credentialKeyId() != nil ? nil : try await self.registerLocked()
            }
            if let registered, !registered.isSuccessful { return registered }
        }

        var sent = try await send(method, path, query: query, body: body, headers: headers)

        if sent.response.handling?.action == .correctClockAndRetry {
            if let serverTime = JSON.int64(sent.response.json?["server_time"]), serverTime > 0 {
                clock.sync(serverSeconds: serverTime)
            }
            sent = try await send(method, path, query: query, body: body, headers: headers)
        }

        if sent.response.handling?.action == .reRegister {
            let refusedKeyId = sent.keyId
            let registered = try await registration.withLock { () async throws -> ApiResponse? in
                // Another request may have registered again since this one was signed (it was
                // refused for the same reason): use that credential rather than replace it.
                try self.credentialKeyId() != refusedKeyId ? nil : try await self.registerLocked()
            }
            if let registered, !registered.isSuccessful { return registered }
            sent = try await send(method, path, query: query, body: body, headers: headers)
        }

        return sent.response
    }

    /// The credential's key id, nil when there's none; throws when it can't be read yet (never
    /// "none" for a locked Keychain, or a working credential would be replaced).
    private func credentialKeyId() throws -> String? {
        switch credentials.read() {
        case .present(let credential): credential.keyId
        case .missing: nil
        case .unavailable: throw DeviceApiError.credentialsLocked
        }
    }

    /// A response, and the key id the request was signed with (nil if it couldn't be signed).
    private struct Sent: Sendable {
        let response: ApiResponse
        let keyId: String?
    }

    /// What a device started with a credential gets where an install would register.
    static let credentialRejected = #"{"message":"The device's credential was refused: start Bubbl with a new one.","code":"credential_rejected"}"#

    private func registerLocked() async throws -> ApiResponse {
        // Started with a credential issued outside the app: nothing here can renew it (there's no
        // API key), so where an install would register, the app is told and has to start Bubbl
        // with a new one.
        guard let apiKey else {
            onCredentialRejected()
            return ApiResponse(HttpResponse(status: 401, body: Self.credentialRejected)).handled(as: ErrorHandling(.stopAndReport))
        }
        var install: [String: Any]
        do {
            install = try installBody()
        } catch {
            throw DeviceApiError.credentialsLocked
        }
        install["api_key"] = apiKey
        let body = JSON.string(install)
        let response = try await execute(HttpRequest(method: "POST", url: url("api/v1/installs"), headers: jsonHeaders(body: body), body: body))

        if response.isSuccessful,
           let data = response.json?["data"] as? [String: Any],
           let credential = data["credential"] as? [String: Any],
           let keyId = credential["key_id"] as? String, !keyId.isEmpty,
           let secret = credential["secret"] as? String, !secret.isEmpty {
            // Not kept, not registered: the next request registers again rather than carry on
            // with a credential this install no longer has.
            do {
                try credentials.save(keyId: keyId, secret: secret)
            } catch {
                throw DeviceApiError.credentialNotSaved(error)
            }
            onRegistered(data)
        }

        // invalid_key here means the public API key itself is wrong: registering again can't fix
        // that, so it's reported rather than retried.
        if response.handling?.action == .reRegister {
            return response.handled(as: ErrorHandling(.stopAndReport))
        }
        return response
    }

    private func send(_ method: String, _ path: String, query: [String: String], body: String?, headers: [String: String]) async throws -> Sent {
        let credential: SigningCredential
        switch credentials.read() {
        case .present(let current):
            credential = current
        case .missing:
            // The credential vanished (cleared mid-request): the server's answer would be
            // missing_signature, so say that without a round trip.
            return Sent(response: ApiResponse(HttpResponse(status: 401, body: #"{"message":"Not registered.","code":"missing_signature"}"#)), keyId: nil)
        case .unavailable:
            throw DeviceApiError.credentialsLocked
        }

        let fullUrl = url(path, query: query)
        let timestamp = clock.nowSeconds()
        // The server signs the request path it sees, which includes any prefix in the base URL.
        let signedPath = String((URLComponents(string: fullUrl)?.percentEncodedPath ?? "").drop { $0 == "/" })
        let signature = RequestSigner.sign(secret: credential.secret, method: method, path: signedPath, timestamp: Int(timestamp), body: body ?? "", query: query)

        var allHeaders = jsonHeaders(body: body)
        allHeaders.merge(headers) { _, new in new }
        allHeaders["X-Bubbl-Key-Id"] = credential.keyId
        allHeaders["X-Bubbl-Timestamp"] = String(timestamp)
        allHeaders["X-Bubbl-Signature"] = signature

        let response = try await execute(HttpRequest(method: method, url: fullUrl, headers: allHeaders, body: body))
        return Sent(response: response, keyId: credential.keyId)
    }

    private func execute(_ request: HttpRequest) async throws -> ApiResponse {
        let response = try await http.execute(request)
        clock.sync(dateHeader: response.header("Date"))
        let result = ApiResponse(response)
        if let said = Self.wrongEnvironment(result) { BubblLog.error(said) }
        let path = String((URLComponents(string: request.url)?.percentEncodedPath ?? "").drop { $0 == "/" })
        if let said = serverErrors.record(status: response.status, method: request.method, path: path) { BubblLog.error(said) }
        return result
    }

    /// What the log says for wrong_environment (a pk_test_ key at the Production address, or the
    /// other way round): the server's message, and the address the key belongs to (`base_url`).
    package static func wrongEnvironment(_ response: ApiResponse) -> String? {
        guard response.code == "wrong_environment" else { return nil }
        let json = response.json
        let message = (json?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "The API key and the address are for different workspaces."
        let address = (json?["base_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return "Bubbl: the API key and baseUrl don't match (wrong_environment). \(message)" + (address.map { " Use baseUrl \($0) with this key." } ?? "")
    }

    /// The URL for `path`, with `query` in canonical order (the same encoding that's signed).
    private func url(_ path: String, query: [String: String] = [:]) -> String {
        let canonical = RequestSigner.canonicalQuery(query)
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "\(baseUrl)/\(relative)" + (canonical.isEmpty ? "" : "?\(canonical)")
    }

    private func jsonHeaders(body: String?) -> [String: String] {
        var headers = ["Accept": "application/json", "User-Agent": userAgent]
        if body != nil { headers["Content-Type"] = "application/json" }
        return headers
    }
}
