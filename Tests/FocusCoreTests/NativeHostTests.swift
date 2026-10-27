import Foundation
@testable import FocusCore

let nativeHostTests: [(String, () throws -> Void)] = [
    ("native messages round-trip and wait for complete frames", {
        let a = try NativeMessageFraming.encode(["type": "hello", "n": 1])
        let b = try NativeMessageFraming.encode(["type": "heartbeat"])
        try expect(a.prefix(4) == Data([UInt8(a.count - 4), 0, 0, 0]), "little-endian length")

        var buffer = a + b.prefix(3)
        var messages = try NativeMessageFraming.decode(from: &buffer)
        try expect(messages.count == 1 && messages[0]["type"] as? String == "hello")
        try expect(buffer.count == 3, "partial frame kept")

        buffer += b.dropFirst(3)
        messages = try NativeMessageFraming.decode(from: &buffer)
        try expect(messages.count == 1 && messages[0]["type"] as? String == "heartbeat" && buffer.isEmpty)

        var huge = Data([0xFF, 0xFF, 0xFF, 0x7F])
        do {
            _ = try NativeMessageFraming.decode(from: &huge)
            throw TestFailure(description: "oversized frame accepted")
        } catch FocusError.storage {}
    }),

    ("two engines on one folder see each other's changes", {
        let fx = Fixture()
        let a = try fx.engine()
        let b = try fx.engine()
        try a.createBlocklist(name: "A", domains: ["a.com"])
        try b.createBlocklist(name: "B", domains: ["b.com"])  // Would overwrite A's list without reload-under-lock.
        try a.tick()
        try expect(a.state.blocklists.map(\.name).sorted() == ["A", "B"])
        try a.startSession(blocklistNames: ["A"], duration: 600, lock: .none, strict: true)
        try b.tick()
        try expect(b.policy().blockedDomains == ["a.com"])

        // Time is credited once, not once per process.
        fx.clock.advance(100)
        try a.tick()
        try b.tick()
        try expect(b.state.activeSessions.first?.remaining == 500)
    }),

    ("the host sends policy on hello, records heartbeats and pushes changes", {
        let fx = Fixture()
        let cli = try fx.engine()
        try cli.createBlocklist(name: "Social", domains: ["reddit.com", "youtube.com/shorts"], exceptions: ["reddit.com/r/swift"])
        let heartbeats = HeartbeatStore(directory: fx.dir)
        let host = NativeHostSession(engine: try fx.engine(), heartbeats: heartbeats, origin: "chrome-extension://abc/",
                                     clock: fx.clock, pid: 42)

        let hello = host.handle(["type": "hello", "version": "0.1.0", "incognitoAllowed": true, "rulesRevision": "", "ruleCount": 0])
        try expect(hello.count == 1 && hello[0]["type"] as? String == "policy" && hello[0]["active"] as? Bool == false)
        let beat = heartbeats.read()
        try expect(beat?.extensionVersion == "0.1.0" && beat?.incognitoAllowed == true && beat?.hostPID == 42)
        try expect(beat?.age(clock: fx.clock) == 0)
        try expect(host.poll() == nil, "nothing changed")

        try cli.startSession(blocklistNames: ["Social"], duration: 900, lock: .timer, strict: true)
        let update = host.poll()
        try expect(update?["active"] as? Bool == true && update?["strict"] as? Bool == true)
        try expect((update?["rules"] as? [[String: Any]])?.count == 5)
        try expect(update?["domains"] as? [String] == ["reddit.com", "youtube.com/shorts"])
        try expect(update?["exceptions"] as? [String] == ["reddit.com/r/swift"])
        try expect((update?["estimatedEnd"] as? Double) == (fx.clock.wall.timeIntervalSince1970 + 900) * 1000)
        try expect(host.poll() == nil)

        // A heartbeat reporting stale rules gets the policy again.
        let resend = host.handle(["type": "heartbeat", "rulesRevision": "old", "ruleCount": 0])
        try expect(resend.first?["type"] as? String == "policy")
        let fine = host.handle(["type": "heartbeat", "rulesRevision": update?["revision"] as? String ?? "", "ruleCount": 5])
        try expect(fine.isEmpty)

        fx.clock.advance(900)
        let ended = host.poll()
        try expect(ended?["active"] as? Bool == false && (ended?["rules"] as? [Any])?.isEmpty == true)

        try expect(host.handle(["type": "stopSession"]).first?["type"] as? String == "error", "the extension can't stop sessions")
        fx.clock.advance(5)
        try expect(heartbeats.read()?.age(clock: fx.clock) == 905)
    }),

    ("policy matching agrees with the shared URL fixture used by the extension tests", {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/fixtures/url-cases.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let policy = EnforcementPolicy(active: true, strict: true, sessionIDs: [], estimatedEnd: nil,
                                       blockedDomains: fixture["domains"] as! [String], exceptions: fixture["exceptions"] as! [String],
                                       blockedApps: [], revision: "fixture")
        for case let item as [String: Any] in fixture["cases"] as! [Any] {
            let raw = item["url"] as! String
            try expect(policy.blocks(URL(string: raw)!) == (item["blocked"] as! Bool), raw)
        }
    }),

    ("host manifest and extension IDs", {
        let data = try NativeHostManifest.contents(hostPath: "/x/focus-nmh", extensionIDs: ["abcdefghijklmnopabcdefghijklmnop"])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try expect(json?["name"] as? String == "com.focusblocker.nmh" && json?["type"] as? String == "stdio")
        try expect(json?["allowed_origins"] as? [String] == ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])
        try expect(NativeHostManifest.isValidExtensionID("abcdefghijklmnopabcdefghijklmnop"))
        try expect(!NativeHostManifest.isValidExtensionID("abcdefghijklmnopabcdefghijklmnoq"))
        // Vector computed independently with Python hashlib for the key bytes "hello".
        try expect(NativeHostManifest.extensionID(publicKeyBase64: "aGVsbG8=") == "cmpcenlkfplakdaocgoidlckmfljocjo")
    }),
]
