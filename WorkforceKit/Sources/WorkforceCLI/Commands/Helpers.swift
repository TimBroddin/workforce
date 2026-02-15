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
    return claudeSessionId
}
