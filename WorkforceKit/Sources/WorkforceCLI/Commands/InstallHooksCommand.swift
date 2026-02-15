import ArgumentParser
import Foundation
import WorkforceKit

struct InstallHooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-hooks",
        abstract: "Install Workforce hooks into ~/.claude/settings.json"
    )

    func run() throws {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsPath.path) {
            let data = try Data(contentsOf: settingsPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = json
            }
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let currentBinary = ProcessInfo.processInfo.arguments[0]
        let binaryPath = try Self.installBinary(from: currentBinary)

        let hookEvents: [(String, String)] = [
            ("PreToolUse", "pre-tool-use"),
            ("PostToolUse", "post-tool-use"),
            ("PostToolUseFailure", "post-tool-use-failure"),
            ("Notification", "notification"),
            ("SubagentStart", "subagent-start"),
            ("SubagentStop", "subagent-stop"),
            ("Stop", "stop"),
            ("SessionEnd", "session-end"),
        ]

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
                    "hooks": [["type": "command", "command": command]]
                ]
                eventHooks.append(entry)
                hooks[event] = eventHooks
                installed += 1
            }
        }

        settings["hooks"] = hooks
        let output = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: settingsPath)

        print("Installed \(installed) hooks. (\(hookEvents.count - installed) already present)")
        print("Settings written to: \(settingsPath.path)")
    }

    /// Copy the workforce binary to /usr/local/bin/workforce.
    /// Returns the destination path.
    private static func installBinary(from sourcePath: String) throws -> String {
        let destDir = "/usr/local/bin"
        let destPath = "\(destDir)/workforce"

        // Resolve the source to an absolute path
        let source = sourcePath.hasPrefix("/")
            ? sourcePath
            : FileManager.default.currentDirectoryPath + "/" + sourcePath

        // If already running from /usr/local/bin, nothing to do
        guard source != destPath else { return destPath }

        guard FileManager.default.isExecutableFile(atPath: source) else {
            throw ValidationError("Source binary not found or not executable: \(source)")
        }

        // Create /usr/local/bin if it doesn't exist
        if !FileManager.default.fileExists(atPath: destDir) {
            try FileManager.default.createDirectory(
                atPath: destDir,
                withIntermediateDirectories: true
            )
        }

        // Remove existing binary if present, then copy
        if FileManager.default.fileExists(atPath: destPath) {
            try FileManager.default.removeItem(atPath: destPath)
        }
        try FileManager.default.copyItem(atPath: source, toPath: destPath)

        print("Installed workforce binary to \(destPath)")
        return destPath
    }
}
