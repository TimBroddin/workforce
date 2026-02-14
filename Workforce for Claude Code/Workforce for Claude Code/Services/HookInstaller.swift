import Foundation

enum HookInstaller {
    private static let settingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    private static let hookEvents: [(String, String)] = [
        ("SessionStart", "session-start"),
        ("PreToolUse", "pre-tool-use"),
        ("PostToolUse", "post-tool-use"),
        ("PostToolUseFailure", "post-tool-use-failure"),
        ("Notification", "notification"),
        ("SubagentStart", "subagent-start"),
        ("SubagentStop", "subagent-stop"),
        ("Stop", "stop"),
        ("SessionEnd", "session-end"),
    ]

    /// Check if workforce hooks are already installed.
    static func isInstalled() -> Bool {
        guard let settings = readSettings(),
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }
        // Check if at least one workforce hook exists
        for (event, _) in hookEvents {
            if let eventHooks = hooks[event] as? [[String: Any]] {
                let hasWorkforce = eventHooks.contains { entry in
                    guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                    return hookList.contains { ($0["command"] as? String)?.contains("workforce") == true }
                }
                if hasWorkforce { return true }
            }
        }
        return false
    }

    /// Find the workforce CLI binary.
    static func findBinary() -> String? {
        let candidates = [
            "/usr/local/bin/workforce",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/workforce").path,
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Check if it's in the build directory (development)
        let devPath = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WorkforceKit/.build/release/workforce")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath.path
        }
        return nil
    }

    /// Install workforce hooks into ~/.claude/settings.json.
    /// Returns the number of hooks installed, or throws on error.
    static func install(binaryPath: String) throws -> Int {
        var settings = readSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var installed = 0
        for (event, subcommand) in hookEvents {
            let command = "\(binaryPath) \(subcommand)"
            var eventHooks = hooks[event] as? [[String: Any]] ?? []

            let alreadyInstalled = eventHooks.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { ($0["command"] as? String)?.contains("workforce") == true }
            }

            if !alreadyInstalled {
                let entry: [String: Any] = [
                    "matcher": "",
                    "hooks": [["type": "command", "command": command] as [String: Any]]
                ]
                eventHooks.append(entry)
                hooks[event] = eventHooks
                installed += 1
            }
        }

        settings["hooks"] = hooks
        try writeSettings(settings)
        return installed
    }

    /// Remove workforce hooks from ~/.claude/settings.json.
    /// Returns the number of hooks removed, or throws on error.
    static func uninstall() throws -> Int {
        guard var settings = readSettings(),
              var hooks = settings["hooks"] as? [String: Any] else {
            return 0
        }

        var removed = 0
        for (event, _) in hooks {
            guard var eventEntries = hooks[event] as? [[String: Any]] else { continue }
            let before = eventEntries.count
            eventEntries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { ($0["command"] as? String)?.contains("workforce") == true }
            }
            removed += before - eventEntries.count
            hooks[event] = eventEntries.isEmpty ? nil : eventEntries
        }

        settings["hooks"] = hooks
        try writeSettings(settings)
        return removed
    }

    // MARK: - Private

    private static func readSettings() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsPath.path),
              let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let output = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: settingsPath)
    }
}
