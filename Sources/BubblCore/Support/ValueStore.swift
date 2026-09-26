import Foundation

/// A small piece of the engine's state kept between launches (what's been shown, the config, the
/// device's segments…). `load` is nil when nothing has been saved yet.
package protocol ValueStore<Value>: Sendable {
    associatedtype Value: Codable & Sendable
    func load() throws -> Value?
    func save(_ value: Value) throws
    func delete() throws
}

/// The file couldn't be read or written, so it did neither. Before the first unlock after a reboot
/// iOS keeps protected files closed; an unreadable file is never taken for "nothing saved".
package struct ValueStoreUnavailable: Error {
    package let underlying: any Error
}

/// A value read once and then kept in memory, for state that's asked for often. Only a successful
/// read is kept: one that failed (the file locked) is tried again next time.
package final class Cached<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var stored: Value?

    package init() {}

    /// The kept value, or `load`'s result (kept) the first time.
    package func value(_ load: () throws -> Value?) rethrows -> Value? {
        try lock.sync {
            if loaded { return stored }
            let value = try load()
            stored = value
            loaded = true
            return value
        }
    }

    package func set(_ value: Value?) {
        lock.sync {
            stored = value
            loaded = true
        }
    }
}

/// A ValueStore in memory: for tests.
package final class InMemoryValueStore<Value: Codable & Sendable>: ValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    package init(_ value: Value? = nil) {
        self.value = value
    }

    package func load() -> Value? { lock.sync { value } }
    package func save(_ value: Value) { lock.sync { self.value = value } }
    package func delete() { lock.sync { value = nil } }
}

/// A ValueStore as one JSON file, written atomically (on iOS, with file protection). A missing
/// file is nothing saved, and so is one that reads but doesn't decode (from an older build, or
/// corrupt); one that can't be read at all throws ValueStoreUnavailable.
package final class FileValueStore<Value: Codable & Sendable>: ValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let writeOptions: Data.WritingOptions

    /// - Parameter writeOptions: added to `.atomic`; on iOS, the file protection class.
    package init(url: URL, writeOptions: Data.WritingOptions = []) {
        self.url = url
        self.writeOptions = writeOptions.union(.atomic)
    }

    package func load() throws -> Value? {
        try lock.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ValueStoreUnavailable(underlying: error)
            }
            return try? JSONDecoder().decode(Value.self, from: data)
        }
    }

    package func save(_ value: Value) throws {
        try lock.sync {
            let data = try JSONEncoder().encode(value)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: writeOptions)
            } catch {
                throw ValueStoreUnavailable(underlying: error)
            }
        }
    }

    package func delete() throws {
        try lock.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw ValueStoreUnavailable(underlying: error)
            }
        }
    }
}
