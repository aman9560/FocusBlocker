import Foundation

// A minimal runner: the installed Command Line Tools can't link SwiftPM manifests, so XCTest and
// swift-testing aren't usable yet. Replace with `swift test` once Xcode or working tools are installed.
var failed = 0
let all = ruleTests + engineTests + nativeHostTests + guardTests + batchOneTests + allWebsitesTests
for (name, test) in all {
    do {
        try test()
        print("✓ \(name)")
    } catch {
        failed += 1
        print("✗ \(name)\n    \(error)")
    }
}
print("\n\(all.count - failed)/\(all.count) passed")
exit(failed == 0 ? 0 : 1)
