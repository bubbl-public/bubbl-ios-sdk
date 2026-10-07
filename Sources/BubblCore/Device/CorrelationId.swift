import Foundation

/// The app's own id for the person using this device (a member or CRM id), as the app last set it
/// (Bubbl.setCorrelationId / clearCorrelationId), as Android's CorrelationId. It goes to the server
/// as the device attribute `correlation_id`: a value replaces it, null clears it, and the device
/// sync sends only what the server doesn't have yet, so it's sent once per change.
///
/// Cleared is not the same as never set: a cleared id is kept as null, so the next sync tells the
/// server to drop one it still holds (an install that was signed in before). Never set sends
/// nothing at all.
package final class CorrelationId: Sendable {
    package static let key = "correlation_id"
    /// The contract's maxLength, in characters.
    package static let maxLength = 255

    /// What's kept: the id, or nil for one the app cleared. No file at all is never touched.
    package struct Saved: Codable, Sendable, Equatable {
        package var id: String?
    }

    private let store: any ValueStore<Saved>
    private let lock = NSLock()
    private let cache = Cached<Saved>()

    package init(store: any ValueStore<Saved>) {
        self.store = store
    }

    /// Whether `id` is one the server accepts: 1 to 255 characters, and not blank.
    package static func isValid(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.unicodeScalars.count <= maxLength
    }

    /// The id the app set; nil if it never has, or cleared it.
    package var current: String? { lock.sync { (try? load()) ?? nil }?.id }

    private func load() throws -> Saved? {
        try cache.value { try store.load() }
    }

    private func save(_ saved: Saved) throws {
        try store.save(saved)
        cache.set(saved)
    }

    /// Keeps `id` (exactly as given); false if it already is the id.
    @discardableResult
    package func set(_ id: String) throws -> Bool {
        try lock.sync {
            if (try load())?.id == id { return false }
            try save(Saved(id: id))
            return true
        }
    }

    /// Clears it; false if the app already had (a cleared id isn't sent twice).
    @discardableResult
    package func clear() throws -> Bool {
        try lock.sync {
            if let saved = try load(), saved.id == nil { return false }
            try save(Saved(id: nil))
            return true
        }
    }

    /// Adds `correlation_id` to a device's `attributes` once the app has set or cleared it.
    package func apply(to attributes: inout [String: JSONValue]) {
        guard let saved = lock.sync({ (try? load()) ?? nil }) else { return }
        attributes[Self.key] = saved.id.map(JSONValue.string) ?? .null
    }

    /// Forget it (deleteMyData): the device starts again with none.
    package func forget() throws {
        try lock.sync {
            try store.delete()
            cache.set(nil)
        }
    }
}
