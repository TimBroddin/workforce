import Foundation

func readStdin() -> Data {
    return FileHandle.standardInput.readDataToEndOfFile()
}

/// Returns the workforce session name if running inside a workforce-managed tmux session,
/// otherwise returns the given Claude session ID as-is.
func resolveSessionId(from claudeSessionId: String) -> String {
    if let workforceSession = ProcessInfo.processInfo.environment["WORKFORCE_SESSION"] {
        return workforceSession
    }
    if let tmuxSession = detectCurrentTmuxSession(), tmuxSession.hasPrefix("workforce-") {
        return tmuxSession
    }
    return claudeSessionId
}

/// Detects the active tmux session name for the current process, if any.
private func detectCurrentTmuxSession() -> String? {
    guard ProcessInfo.processInfo.environment["TMUX"] != nil else {
        return nil
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["tmux", "display-message", "-p", "#S"]
    process.standardError = FileHandle.nullDevice

    let outputPipe = Pipe()
    process.standardOutput = outputPipe

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let session = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !session.isEmpty else {
            return nil
        }
        return session
    } catch {
        return nil
    }
}
