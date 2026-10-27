import Foundation
@testable import FocusCore

/// A controllable clock: `advance` moves wall and monotonic time together, `setWall` changes only the wall clock.
final class TestClock: ClockSource {
    var wall: Date
    var mono: TimeInterval = 1000
    var boot = "boot-1"

    init(wall: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.wall = wall }

    func wallNow() -> Date { wall }
    func monotonicNow() -> TimeInterval { mono }
    func bootID() -> String { boot }

    func advance(_ seconds: TimeInterval) {
        wall += seconds
        mono += seconds
    }

    func reboot(offlineFor seconds: TimeInterval) {
        boot = UUID().uuidString
        mono = 5
        wall += seconds
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
            file: String = #fileID, line: Int = #line) throws {
    guard try condition() else { throw TestFailure(description: "\(file):\(line): expectation failed \(message())") }
}

func expectThrows(_ expected: FocusError, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as FocusError {
        guard error == expected else { throw TestFailure(description: "\(file):\(line): threw \(error), expected \(expected)") }
        return
    }
    throw TestFailure(description: "\(file):\(line): did not throw, expected \(expected)")
}

/// A temporary state folder plus an engine factory, so tests can simulate an app restart by building a second engine.
final class Fixture {
    let dir: URL
    let clock = TestClock()
    let keys: FileKeyProvider

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-tests-\(UUID().uuidString)")
        keys = FileKeyProvider(url: dir.appendingPathComponent("key"))
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var store: StateStore { StateStore(directory: dir, keyProvider: keys) }
    var audit: AuditLog { AuditLog(url: dir.appendingPathComponent("audit.log"), keyProvider: keys) }

    func engine() throws -> FocusEngine {
        try FocusEngine(store: store, audit: audit, clock: clock, passwordIterations: 1000)
    }
}
