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
    /// Checks: app bundle → installed locations → dev build path.
    static func findBinary() -> String? {
        // 1. Bundled inside the app
        if let bundled = Bundle.main.path(forResource: "workforce", ofType: nil) {
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }

        // 2. Already installed
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

        // 3. Development build directory
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

    /// Copy the workforce binary to /usr/local/bin/workforce.
    /// Returns the installed path.
    static func installBinary(from sourcePath: String) throws -> String {
        let destDir = "/usr/local/bin"
        let destPath = "\(destDir)/workforce"

        // If already at the destination, nothing to do
        guard sourcePath != destPath else { return destPath }

        guard FileManager.default.isExecutableFile(atPath: sourcePath) else {
            throw NSError(domain: "HookInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Source binary not found or not executable: \(sourcePath)"])
        }

        if !FileManager.default.fileExists(atPath: destDir) {
            try FileManager.default.createDirectory(
                atPath: destDir,
                withIntermediateDirectories: true
            )
        }

        if FileManager.default.fileExists(atPath: destPath) {
            try FileManager.default.removeItem(atPath: destPath)
        }
        try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath)

        return destPath
    }

    /// Install workforce hooks into ~/.claude/settings.json.
    /// Returns the number of hooks installed, or throws on error.
    static func install(binaryPath: String) throws -> Int {
        // Copy binary to /usr/local/bin so hooks use a stable path
        let installedPath = try installBinary(from: binaryPath)

        var settings = readSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var installed = 0
        for (event, subcommand) in hookEvents {
            let command = "\(installedPath) \(subcommand)"
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

    /// Check if a command is available in common install locations.
    static func isCommandAvailable(_ command: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "\(home)/.local/bin/\(command)",
            "\(home)/.cargo/bin/\(command)",
            "\(home)/.bun/bin/\(command)",
        ]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
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
