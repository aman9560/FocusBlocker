import Foundation

/// Where every Focus process finds the shared state. One definition, so focusctl, the native messaging host and the
/// agent can't disagree. `FOCUS_STATE_DIR` and `FOCUS_KEY_FILE` override the defaults for tests.
public enum FocusPaths {
    public static var stateDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["FOCUS_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FocusBlocker")
    }

    /// A file key rather than the login keychain: keychain items are bound to the binary that created them, so the
    /// separately built host and CLI would trigger access prompts. On an admin account both are equally readable.
    public static func keyFile(in stateDirectory: URL) -> URL {
        if let file = ProcessInfo.processInfo.environment["FOCUS_KEY_FILE"], !file.isEmpty {
            return URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        }
        return stateDirectory.appendingPathComponent("state.key")
    }

    /// Where `focusctl chrome install-host` copies the host binary, so it doesn't depend on the build folder.
    public static func installedHost(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("bin/focus-nmh")
    }

    public static func makeEngine(stateDirectory: URL, keyFile: URL? = nil) throws -> (FocusEngine, AuditLog) {
        let keys = FileKeyProvider(url: keyFile ?? Self.keyFile(in: stateDirectory))
        let audit = AuditLog(url: stateDirectory.appendingPathComponent("audit.log"), keyProvider: keys)
        let engine = try FocusEngine(store: StateStore(directory: stateDirectory, keyProvider: keys), audit: audit)
        return (engine, audit)
    }
}
