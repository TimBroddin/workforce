import ArgumentParser
import Foundation
import WorkforceKit

struct InstallHooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-hooks",
        abstract: "Install Workforce hooks into Claude Code and OpenCode"
    )

    func run() throws {
        let settingsPath = Self.claudeSettingsPath
        let currentBinary = ProcessInfo.processInfo.arguments[0]
        let binaryPath = try Self.installBinary(from: currentBinary)
        let openCodeInstalled = try Self.installOpenCodePlugin(binaryPath: binaryPath)

        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsPath.path) {
            let data = try Data(contentsOf: settingsPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = json
            }
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, String)] = [
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

        var installed = 0
        for (event, subcommand) in hookEvents {
            let command = "\(binaryPath) \(subcommand)"
            var eventHooks = hooks[event] as? [[String: Any]] ?? []

            let alreadyInstalled = eventHooks.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return Self.isWorkforceCommand(command)
                }
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

        print("Installed Claude hooks: \(installed). (\(hookEvents.count - installed) already present)")
        print("Installed OpenCode plugin files: \(openCodeInstalled)")
        print("Claude settings written to: \(settingsPath.path)")
        print("OpenCode plugin path: \(Self.openCodePluginPath.path)")
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
        Self.codesignBinary(atPath: destPath)

        print("Installed workforce binary to \(destPath)")
        return destPath
    }

    private static func installOpenCodePlugin(binaryPath: String) throws -> Int {
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

    /// Re-sign the binary with an ad-hoc signature so macOS allows execution
    /// outside the original app bundle.
    private static func codesignBinary(atPath path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-fs", "-", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else {
            return "\"/usr/local/bin/workforce\""
        }
        return String(json.dropFirst().dropLast())
    }
}
