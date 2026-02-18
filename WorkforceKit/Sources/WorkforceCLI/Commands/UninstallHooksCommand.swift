import ArgumentParser
import Foundation

struct UninstallHooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall-hooks",
        abstract: "Remove Workforce hooks from Claude Code and OpenCode"
    )

    func run() throws {
        let settingsPath = Self.claudeSettingsPath

        var removedOpenCode = 0
        if FileManager.default.fileExists(atPath: Self.openCodePluginPath.path) {
            try FileManager.default.removeItem(at: Self.openCodePluginPath)
            removedOpenCode = 1
        }

        var removedClaude = 0
        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            print("No Claude settings file found at \(settingsPath.path)")
            print("Removed OpenCode plugin files: \(removedOpenCode)")
            return
        }

        let data = try Data(contentsOf: settingsPath)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else {
            print("No Claude hooks found in settings.")
            print("Removed OpenCode plugin files: \(removedOpenCode)")
            return
        }

        for (event, entries) in hooks {
            guard var eventEntries = entries as? [[String: Any]] else { continue }
            let before = eventEntries.count
            eventEntries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return Self.isWorkforceCommand(command)
                }
            }
            removedClaude += before - eventEntries.count
            hooks[event] = eventEntries.isEmpty ? nil : eventEntries
        }

        settings["hooks"] = hooks
        let output = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: settingsPath)
        print("Removed Claude hooks: \(removedClaude)")
        print("Removed OpenCode plugin files: \(removedOpenCode)")
    }

    private static let claudeSettingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    private static let openCodePluginPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/plugins/workforce.js")

    private static func isWorkforceCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).first else {
            return false
        }
        let executable = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return URL(fileURLWithPath: executable).lastPathComponent == "workforce"
    }
}
