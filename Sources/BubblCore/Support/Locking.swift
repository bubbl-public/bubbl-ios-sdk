import Foundation

extension NSLock {
    /// Runs `body` holding the lock. (Foundation's own `withLock` isn't on every platform the
    /// core builds for.)
    package func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
