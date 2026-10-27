// swift-tools-version:5.10
// Not used yet: the installed Command Line Tools ship a broken libPackageDescription, so build.sh calls swiftc directly.
// Once Xcode is installed, `swift build` and the app/extension targets will build from here.
import PackageDescription

let package = Package(
    name: "Focus",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FocusCore", targets: ["FocusCore"]),
        .executable(name: "focusctl", targets: ["focusctl"]),
    ],
    targets: [
        .target(name: "FocusCore"),
        .executableTarget(name: "focusctl", dependencies: ["FocusCore"]),
        .executableTarget(name: "focus-tests", dependencies: ["FocusCore"], path: "Tests/FocusCoreTests"),
    ]
)
