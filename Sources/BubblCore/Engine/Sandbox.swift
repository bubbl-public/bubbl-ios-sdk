import Foundation

/// The workspace an API key belongs to, from POST /installs and GET /config (`workspace`):
/// Sandbox (a pk_test_ key: free, and only approved test devices get anything) or Production
/// (pk_live_). In Sandbox, `testDevice` says where this device stands: pending until someone
/// approves it (with the short `code` the dashboard lists it under), then approved.
package struct Workspace: Sendable, Equatable {
    package struct TestDevice: Sendable, Equatable {
        /// pending or approved (as the server says; a newer server may add others). An approved phone
        /// unused for 30 days goes back to pending; a revoked one registers again as pending.
        package let status: String
        /// While pending: the short code the dashboard lists this device under (e.g. K7Q-2MX).
        package let code: String?

        package init(status: String, code: String?) {
            self.status = status
            self.code = code
        }
    }

    /// "sandbox" or "production".
    package let environment: String
    package let testDevice: TestDevice?

    package init(environment: String, testDevice: TestDevice?) {
        self.environment = environment
        self.testDevice = testDevice
    }

    package var isSandbox: Bool { environment == "sandbox" }

    /// What the log says about it, at start and when it changes: in Sandbox, how to get this device
    /// approved; nothing in Production (or from a server that predates Sandbox).
    package var announcement: (warning: Bool, message: String)? {
        guard isSandbox, let testDevice else { return nil }
        switch testDevice.status {
        case "pending":
            guard let code = testDevice.code else { return (true, "Bubbl sandbox: this device is waiting to be approved as a test device (Test devices in the dashboard)") }
            return (true, "Bubbl sandbox: approve this device with code \(code)")
        case "approved":
            return (false, "Bubbl sandbox: this device is an approved test device")
        default:
            return nil
        }
    }
}

extension SdkConfig {
    /// Nil from a server that predates Sandbox (every workspace was Production then).
    package var workspace: Workspace? {
        guard let block = json["workspace"], let environment = block["environment"]?.nonEmptyString else { return nil }
        let device = block["test_device"]
        let testDevice = device?["status"]?.nonEmptyString.map { Workspace.TestDevice(status: $0, code: device?["code"]?.nonEmptyString) }
        return Workspace(environment: environment, testDevice: testDevice)
    }
}

extension EngineStart {
    /// The console's warning for a key that doesn't suit the build: a Sandbox key in a release
    /// build (only approved test devices would get anything), or a Production key in a debug build
    /// (development should go to Sandbox). Nil when they suit, or for a key without a prefix.
    package static func keyWarning(apiKey: String, debugBuild: Bool) -> String? {
        if apiKey.hasPrefix("pk_test_") && !debugBuild {
            return "Bubbl: a Sandbox key (pk_test_) in a release build. Only approved test devices get anything from Sandbox: to go live, use the Production key (pk_live_) and https://api.bubbl.tech"
        }
        if apiKey.hasPrefix("pk_live_") && debugBuild {
            return "Bubbl: a Production key (pk_live_) in a debug build. Develop against Sandbox: its key (pk_test_) and https://api.sandbox.bubbl.tech"
        }
        return nil
    }
}

extension EngineCore {
    /// The workspace this key belongs to, as last heard; nil before the first registration.
    package var workspace: Workspace? { configSync.current?.workspace }

    /// Says in the log where this device stands in Sandbox (its approval code while pending), once
    /// per status and code in a process: at start, and when a registration or the config brings a
    /// change.
    package func announceSandbox() {
        guard let workspace, let said = workspace.announcement else { return }
        guard sandboxAnnounced.changed(to: said.message) else { return }
        if said.warning { BubblLog.warning(said.message) } else { BubblLog.info(said.message) }
    }

    /// POST /test-device: approves this device in Sandbox with a registration code from the
    /// dashboard (single-use, 24 hours). Approved, with the workspace block the server returns kept
    /// at once; or not, with why: the server's message (a wrong, used or expired code, the Sandbox
    /// full), or the SDK's (not running, an empty code, no network). Said in the log too; the code
    /// itself never is.
    package func registerTestDevice(_ code: String) async -> TestDeviceResult {
        func refused(_ why: String) -> TestDeviceResult {
            BubblLog.warning("Bubbl.registerTestDevice: \(why)")
            return TestDeviceResult(approved: false, message: why)
        }
        guard isActive else { return refused("Bubbl isn't running (consent, a pause, or the SDK's minimum version)") }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return refused("the code is empty") }

        let response: ApiResponse
        do {
            response = try await api.request("POST", "api/v1/test-device", body: JSON.string(["code": trimmed]))
        } catch {
            return refused("the device API couldn't be reached; try again")
        }
        guard response.isSuccessful else {
            let message = (response.json?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return refused(message ?? "not approved (\(response.code ?? "HTTP \(response.status)"))")
        }
        struct Body: Decodable {
            struct Content: Decodable { let workspace: JSONValue }
            let data: Content
        }
        if let workspace = response.decode(Body.self)?.data.workspace {
            try? await configSync.setWorkspace(workspace)
        } else {
            _ = await configSync.refresh(force: true)
        }
        announceSandbox()
        return TestDeviceResult(approved: true, message: nil)
    }
}

/// What `registerTestDevice` came to.
package struct TestDeviceResult: Sendable, Equatable {
    package let approved: Bool
    /// Why not, when not approved.
    package let message: String?

    package init(approved: Bool, message: String?) {
        self.approved = approved
        self.message = message
    }
}

/// The last thing said, so a message is logged once until it changes.
final class LastSaid: @unchecked Sendable {
    private let lock = NSLock()
    private var last: String?

    /// True, and remembered, when `message` differs from the last one.
    func changed(to message: String) -> Bool {
        lock.sync {
            guard message != last else { return false }
            last = message
            return true
        }
    }
}
