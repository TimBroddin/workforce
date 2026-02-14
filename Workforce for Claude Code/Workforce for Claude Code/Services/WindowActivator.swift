import AppKit

enum WindowActivator {
    static func activate(_ agent: Agent) {
        guard let bundleId = agent.hostBundleId else { return }
        let source = """
        tell application id "\(bundleId)"
            activate
        end tell
        """
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }
}
