/// What the engine does about a failed request. The device API contract's errors fixture
/// (contracts/v1/fixtures/v1/errors.json) is the source of truth for which code gets which
/// action, and ErrorActionsContractTests checks this against it. Raw values are the fixture's.
package enum ErrorAction: String, Sendable, CaseIterable {
    /// POST /installs again, once and one at a time, then retry.
    case reRegister = "re_register"
    /// Take the clock offset from server_time (or the Date header) and retry once.
    case correctClockAndRetry = "correct_clock_and_retry"
    /// Stop calling the API for a while (ErrorHandling.pauseHours); keep queuing.
    case pause
    /// PUT /device, then retry.
    case describeDevice = "describe_device"
    /// Drop the item and fetch geofences again: the location is gone.
    case dropAndRefreshGeofences = "drop_and_refresh_geofences"
    /// Discard the request or item (it can never succeed as sent) and log it.
    case drop
    /// Wait for Retry-After, then retry.
    case waitAndRetry = "wait_and_retry"
    /// Stop and surface it in diagnostics: something is misconfigured.
    case stopAndReport = "stop_and_report"
    /// The pairing UI shows the server's message.
    case showMessage = "show_message"
    /// 5xx or network failure: exponential backoff with jitter.
    case backoff
}

/// An ErrorAction, with how long to pause for `.pause`.
package struct ErrorHandling: Sendable, Equatable {
    package let action: ErrorAction
    package let pauseHours: Int?

    package init(_ action: ErrorAction, pauseHours: Int? = nil) {
        self.action = action
        self.pauseHours = pauseHours
    }
}

package enum ErrorActions {
    /// The handling for a response's status and error `code` (nil when the body had none). An
    /// unknown code falls back on its status, so a newer server can't wedge an older SDK.
    package static func forResponse(status: Int, code: String?) -> ErrorHandling {
        switch code {
        case "missing_signature": ErrorHandling(.stopAndReport)
        case "timestamp_out_of_range": ErrorHandling(.correctClockAndRetry)
        case "invalid_key", "invalid_signature", "credential_revoked": ErrorHandling(.reRegister)
        case "workspace_paused": ErrorHandling(.pause, pauseHours: 6)
        case "own_app_not_in_plan": ErrorHandling(.pause, pauseHours: 24)
        // Sandbox: no room for another device awaiting approval; back off as for a paused workspace.
        case "sandbox_pending_full": ErrorHandling(.pause, pauseHours: 6)
        // A Sandbox key at the Production address or the other way round: only the app can fix it.
        case "wrong_environment": ErrorHandling(.stopAndReport)
        case "showcase_only", "unknown_notification": ErrorHandling(.drop)
        case "device_not_registered": ErrorHandling(.describeDevice)
        case "request_in_progress", "too_many_failed_attempts": ErrorHandling(.waitAndRetry)
        case "unknown_location": ErrorHandling(.dropAndRefreshGeofences)
        // The message goes back to whoever asked (pairing; Bubbl.registerTestDevice).
        case "invalid_pairing_code", "invalid_test_device_code", "test_devices_full": ErrorHandling(.showMessage)
        case "rate_limited": ErrorHandling(.waitAndRetry)
        default:
            switch status {
            case 422: ErrorHandling(.drop)
            case 429: ErrorHandling(.waitAndRetry)
            case 500...: ErrorHandling(.backoff)
            default: ErrorHandling(.stopAndReport)
            }
        }
    }
}
