import ArgumentParser
import Foundation

struct UninstallHooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall-hooks",
        abstract: "Remove Workforce hooks from ~/.claude/settings.json"
    )

    func run() throws {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            print("No settings file found at \(settingsPath.path)")
            return
        }

        let data = try Data(contentsOf: settingsPath)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else {
            print("No hooks found in settings.")
            return
        }

        var removed = 0
        for (event, entries) in hooks {
            guard var eventEntries = entries as? [[String: Any]] else { continue }
            let before = eventEntries.count
            eventEntries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { ($0["command"] as? String)?.contains("workforce") == true }
            }
            removed += before - eventEntries.count
            hooks[event] = eventEntries.isEmpty ? nil : eventEntries
        }

        settings["hooks"] = hooks
        let output = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: settingsPath)
        print("Removed \(removed) workforce hooks.")
    }
}
