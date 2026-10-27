import Foundation
import FocusCore

// Chrome launches this host when the extension calls connectNative, passing the caller's origin as the first
// argument. stdout carries only framed messages; diagnostics go to stderr, which Chrome writes to its log.

func log(_ text: String) {
    FileHandle.standardError.write(Data("focus-nmh: \(text)\n".utf8))
}

let origin = CommandLine.arguments.dropFirst().first ?? "unknown"
let queue = DispatchQueue(label: "focus-nmh")
let stdout = FileHandle.standardOutput

func send(_ message: [String: Any]) {
    do {
        stdout.write(try NativeMessageFraming.encode(message))
    } catch {
        log("could not send message: \(error)")
    }
}

let stateDir = FocusPaths.stateDirectory
let session: NativeHostSession
do {
    let (engine, _) = try FocusPaths.makeEngine(stateDirectory: stateDir)
    session = NativeHostSession(engine: engine, heartbeats: HeartbeatStore(directory: stateDir), origin: origin)
} catch {
    // The extension keeps its last rules when it gets an error, so a broken state never silently unblocks.
    send(["type": "error", "message": "Focus state unavailable: \(error)"])
    log("startup failed: \(error)")
    exit(1)
}

// Poll the engine so sessions that start or end are pushed to the extension within about two seconds.
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + 2, repeating: 2)
timer.setEventHandler {
    if let update = session.poll() { send(update) }
}
timer.resume()

// Read stdin on a background thread; Chrome closing the port shows up as end of file.
Thread.detachNewThread {
    var buffer = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty {
            queue.sync { exit(0) }
        }
        buffer.append(chunk)
        do {
            let messages = try NativeMessageFraming.decode(from: &buffer)
            queue.sync {
                for message in messages {
                    for reply in session.handle(message) { send(reply) }
                }
            }
        } catch {
            log("bad input: \(error)")
            queue.sync { exit(1) }
        }
    }
}

dispatchMain()
