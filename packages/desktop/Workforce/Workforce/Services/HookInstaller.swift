import Foundation

enum HookInstaller {
    enum CLIVersionStatus {
        case notInstalled
        case upToDate
        case needsUpdate(installedVersion: String?, appVersion: String)
    }

    private static let settingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    private static let openCodePluginPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/plugins/workforce.js")
    private static let installedBinaryPath = "/usr/local/bin/workforce"
    private static let versionMetadataPath = "/usr/local/bin/workforce.version"

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
        isClaudeHooksInstalled() || isOpenCodeHooksInstalled()
    }

    /// Check if workforce hooks are installed in Claude Code.
    static func isClaudeHooksInstalled() -> Bool {
        guard let settings = readSettings(),
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }
        // Check if at least one workforce hook exists
        for (event, _) in hookEvents {
            if let eventHooks = hooks[event] as? [[String: Any]] {
                let hasWorkforce = eventHooks.contains { entry in
                    guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                    return hookList.contains { hook in
                        guard let command = hook["command"] as? String else { return false }
                        return isWorkforceCommand(command)
                    }
                }
                if hasWorkforce { return true }
            }
        }
        return false
    }

    /// Check if workforce hooks are installed in OpenCode.
    static func isOpenCodeHooksInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: openCodePluginPath.path),
              let content = try? String(contentsOf: openCodePluginPath, encoding: .utf8) else {
            return false
        }
        return content.contains("workforce-opencode-plugin")
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

    /// Current app version from Info.plist.
    static func appVersion() -> String {
        if let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !short.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return short
        }
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return build
        }
        return "0"
    }

    /// Version recorded when the CLI binary was installed by the app.
    static func installedCLIVersion() -> String? {
        guard let raw = try? String(contentsOfFile: versionMetadataPath, encoding: .utf8) else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Returns whether the installed CLI matches this app version.
    static func cliVersionStatus() -> CLIVersionStatus {
        guard FileManager.default.isExecutableFile(atPath: installedBinaryPath) else {
            return .notInstalled
        }

        let app = appVersion()
        guard let installed = installedCLIVersion() else {
            return .needsUpdate(installedVersion: nil, appVersion: app)
        }

        if compareVersions(installed, app) == .orderedAscending {
            return .needsUpdate(installedVersion: installed, appVersion: app)
        }

        return .upToDate
    }

    /// Copy the workforce binary to /usr/local/bin/workforce.
    /// Returns the installed path.
    static func installBinary(from sourcePath: String) throws -> String {
        let destDir = "/usr/local/bin"
        let destPath = installedBinaryPath
        let version = appVersion()

        // If already at the destination, nothing to do
        if sourcePath == destPath {
            guard FileManager.default.isExecutableFile(atPath: destPath) else {
                throw NSError(domain: "HookInstaller", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Source binary not found or not executable: \(sourcePath)"])
            }
            do {
                try writeInstalledCLIVersionMetadata()
            } catch {
                try writeInstalledCLIVersionMetadataWithPrivileges(version: version)
            }
            return destPath
        }

        guard FileManager.default.isExecutableFile(atPath: sourcePath) else {
            throw NSError(domain: "HookInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Source binary not found or not executable: \(sourcePath)"])
        }

        do {
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
            try codesignBinary(atPath: destPath)
            try writeInstalledCLIVersionMetadata()
        } catch {
            try installBinaryWithPrivileges(from: sourcePath, version: version)
        }

        return destPath
    }

    /// Install workforce hooks into Claude Code and OpenCode.
    /// Returns the total number of hook entries/plugin files installed or updated.
    static func install(binaryPath: String) throws -> Int {
        // Copy binary to /usr/local/bin so hooks use a stable path
        let installedPath = try installBinary(from: binaryPath)

        let claudeInstalled = try installClaudeHooks(binaryPath: installedPath)
        let openCodeInstalled = try installOpenCodeHooks(binaryPath: installedPath)
        return claudeInstalled + openCodeInstalled
    }

    /// Remove workforce hooks from Claude Code and OpenCode.
    /// Returns the total number of hook entries/plugin files removed.
    static func uninstall() throws -> Int {
        let claudeRemoved = try uninstallClaudeHooks()
        let openCodeRemoved = try uninstallOpenCodeHooks()
        return claudeRemoved + openCodeRemoved
    }

    /// Install workforce hooks in Claude Code only.
    /// Returns the number of Claude hook entries added.
    static func installClaude(binaryPath: String) throws -> Int {
        let installedPath = try installBinary(from: binaryPath)
        return try installClaudeHooks(binaryPath: installedPath)
    }

    /// Install workforce hooks in OpenCode only.
    /// Returns 1 when the plugin file is created/updated, otherwise 0.
    static func installOpenCode(binaryPath: String) throws -> Int {
        let installedPath = try installBinary(from: binaryPath)
        return try installOpenCodeHooks(binaryPath: installedPath)
    }

    /// Remove workforce hooks from Claude Code only.
    /// Returns the number of Claude hook entries removed.
    static func uninstallClaude() throws -> Int {
        try uninstallClaudeHooks()
    }

    /// Remove workforce hooks from OpenCode only.
    /// Returns 1 when the plugin file is removed, otherwise 0.
    static func uninstallOpenCode() throws -> Int {
        try uninstallOpenCodeHooks()
    }

    // MARK: - Claude Hooks

    private static func installClaudeHooks(binaryPath: String) throws -> Int {
        var settings = readSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var installed = 0
        for (event, subcommand) in hookEvents {
            let command = "\(binaryPath) \(subcommand)"
            var eventHooks = hooks[event] as? [[String: Any]] ?? []

            let alreadyInstalled = eventHooks.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return isWorkforceCommand(command)
                }
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

    private static func uninstallClaudeHooks() throws -> Int {
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
                return hookList.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return isWorkforceCommand(command)
                }
            }
            removed += before - eventEntries.count
            hooks[event] = eventEntries.isEmpty ? nil : eventEntries
        }

        settings["hooks"] = hooks
        try writeSettings(settings)
        return removed
    }

    // MARK: - OpenCode Hooks

    private static func installOpenCodeHooks(binaryPath: String) throws -> Int {
        let pluginDir = openCodePluginPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true, attributes: nil)

        let content = renderOpenCodePlugin(binaryPath: binaryPath)
        if FileManager.default.fileExists(atPath: openCodePluginPath.path),
           let existing = try? String(contentsOf: openCodePluginPath, encoding: .utf8),
           existing == content {
            return 0
        }

        try content.write(to: openCodePluginPath, atomically: true, encoding: .utf8)
        return 1
    }

    private static func uninstallOpenCodeHooks() throws -> Int {
        guard FileManager.default.fileExists(atPath: openCodePluginPath.path) else {
            return 0
        }
        try FileManager.default.removeItem(at: openCodePluginPath)
        return 1
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

    private static func isWorkforceCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).first else {
            return false
        }
        let executable = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return URL(fileURLWithPath: executable).lastPathComponent == "workforce"
    }

    private static func renderOpenCodePlugin(binaryPath: String) -> String {
        """
        // workforce-opencode-plugin
        import { existsSync } from "node:fs";
        import { spawn } from "node:child_process";

        const WORKFORCE_BINARY = \(jsonString(binaryPath));

        export default async function WorkforcePlugin(ctx) {
          const defaultCwd = ctx.worktree || ctx.directory || process.cwd();
          const sessionDirectories = new Map();

          function getSessionID(event) {
            return (
              event?.properties?.sessionID ??
              event?.properties?.info?.id ??
              event?.properties?.request?.sessionID ??
              event?.properties?.session?.id ??
              "opencode"
            );
          }

          function resolveCwd(sessionID, fallback) {
            return sessionDirectories.get(sessionID) || fallback || defaultCwd;
          }

          function send(subcommand, payload) {
            const command = existsSync(WORKFORCE_BINARY) ? WORKFORCE_BINARY : "workforce";
            try {
              const child = spawn(command, [subcommand], {
                stdio: ["pipe", "ignore", "ignore"],
                env: process.env,
              });
              child.on("error", () => {});
              child.stdin.end(JSON.stringify(payload));
            } catch {
              // Ignore plugin transport failures.
            }
          }

          function basePayload(sessionID, cwd, hookEventName) {
            return {
              session_id: sessionID,
              cwd: cwd,
              hook_event_name: hookEventName,
            };
          }

          return {
            async event({ event }) {
              const type = event?.type;
              if (!type) return;

              if (type === "session.created" || type === "session.updated") {
                const sessionID = getSessionID(event);
                const cwd = event?.properties?.info?.directory || resolveCwd(sessionID);
                sessionDirectories.set(sessionID, cwd);
                send("session-start", basePayload(sessionID, cwd, "SessionStart"));
                return;
              }

              if (type === "session.deleted") {
                const sessionID = getSessionID(event);
                const cwd = resolveCwd(sessionID);
                send("session-end", basePayload(sessionID, cwd, "SessionEnd"));
                sessionDirectories.delete(sessionID);
                return;
              }

              if (type === "session.idle") {
                const sessionID = getSessionID(event);
                const cwd = resolveCwd(sessionID);
                send("stop", basePayload(sessionID, cwd, "Stop"));
                return;
              }

              if (type === "session.status") {
                const sessionID = getSessionID(event);
                const cwd = resolveCwd(sessionID);
                const status = event?.properties?.status?.type;
                if (status === "idle") {
                  send("stop", basePayload(sessionID, cwd, "Stop"));
                } else {
                  send("session-start", basePayload(sessionID, cwd, "SessionStart"));
                }
                return;
              }

              if (type === "permission.asked" || type === "permission.updated") {
                const sessionID = getSessionID(event);
                const cwd = resolveCwd(sessionID);
                send("notification", {
                  ...basePayload(sessionID, cwd, "Notification"),
                  type: "permission_prompt",
                });
                return;
              }

              if (type === "question.asked") {
                const sessionID = getSessionID(event);
                const cwd = resolveCwd(sessionID);
                send("notification", {
                  ...basePayload(sessionID, cwd, "Notification"),
                  type: "input_prompt",
                });
              }
            },

            async "tool.execute.before"(input) {
              const sessionID = input?.sessionID || "opencode";
              const cwd = resolveCwd(sessionID);
              send("pre-tool-use", {
                ...basePayload(sessionID, cwd, "PreToolUse"),
                tool_name: input?.tool || "tool",
              });
            },

            async "tool.execute.after"(input) {
              const sessionID = input?.sessionID || "opencode";
              const cwd = resolveCwd(sessionID);
              send("post-tool-use", {
                ...basePayload(sessionID, cwd, "PostToolUse"),
                tool_name: input?.tool || "tool",
              });
            },
          };
        }
        """
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else {
            return "\"/usr/local/bin/workforce\""
        }
        return String(json.dropFirst().dropLast())
    }

    private static func codesignBinary(atPath path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-fs", "-", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        // Non-zero exit is not fatal — the binary may still work unsigned
    }

    private static func writeInstalledCLIVersionMetadata() throws {
        let version = appVersion()
        try version.write(toFile: versionMetadataPath, atomically: true, encoding: .utf8)
    }

    private static func writeInstalledCLIVersionMetadataWithPrivileges(version: String) throws {
        let command = "printf %s\\\\n \(shellQuote(version)) > \(shellQuote(versionMetadataPath))"
        try runPrivilegedShell(command)
    }

    private static func installBinaryWithPrivileges(from sourcePath: String, version: String) throws {
        let command = """
        /usr/bin/install -d -m 755 /usr/local/bin
        /bin/cp \(shellQuote(sourcePath)) \(shellQuote(installedBinaryPath))
        /bin/chmod 755 \(shellQuote(installedBinaryPath))
        /usr/bin/codesign -fs - \(shellQuote(installedBinaryPath))
        printf %s\\\\n \(shellQuote(version)) > \(shellQuote(versionMetadataPath))
        """
        try runPrivilegedShell(command)
    }

    private static func runPrivilegedShell(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"\(appleScriptQuote(command))\" with administrator privileges"
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = raw.isEmpty
                ? "Administrator install was cancelled or failed."
                : "Administrator install failed: \(raw)"
            throw NSError(domain: "HookInstaller", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parseVersion(lhs)
        let right = parseVersion(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }

        return .orderedSame
    }

    private static func parseVersion(_ value: String) -> [Int] {
        value
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .map { token in
                let numericPrefix = token.prefix { $0.isNumber }
                return Int(numericPrefix) ?? 0
            }
    }
}
