import Foundation

enum HookInstaller {
    enum CLIVersionStatus {
        case notInstalled
        case upToDate
        case needsUpdate(installedVersion: String?, expectedVersion: String)
    }

    struct CLIResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static let settingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    private static let openCodePluginPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/plugins/agenthub.js")

    // MARK: - CLI Runner

    /// Run the agenthub CLI with the given arguments.
    /// Finds the binary automatically and returns exit code, stdout, and stderr.
    static func runCLI(_ arguments: [String]) -> CLIResult {
        guard let binary = findBinary() else {
            return CLIResult(exitCode: 127, stdout: "", stderr: "agenthub binary not found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        // GUI apps don't inherit shell PATH — inject bun/homebrew paths so #!/usr/bin/env bun works
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CLIResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return CLIResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    // MARK: - Hook Installation (delegates to CLI)

    /// Install agenthub hooks into Claude Code via CLI.
    @discardableResult
    static func installClaude(binaryPath: String) -> CLIResult {
        runCLI(["install-hooks", "--agent=claude"])
    }

    /// Install agenthub hooks into OpenCode via CLI.
    @discardableResult
    static func installOpenCode(binaryPath: String) -> CLIResult {
        runCLI(["install-hooks", "--agent=opencode"])
    }

    /// Remove agenthub hooks from Claude Code via CLI.
    @discardableResult
    static func uninstallClaude() -> CLIResult {
        runCLI(["uninstall-hooks", "--agent=claude"])
    }

    /// Remove agenthub hooks from OpenCode via CLI.
    @discardableResult
    static func uninstallOpenCode() -> CLIResult {
        runCLI(["uninstall-hooks", "--agent=opencode"])
    }

    // MARK: - Daemon Management

    /// Start the daemon via CLI.
    @discardableResult
    static func startDaemon() -> CLIResult {
        runCLI(["daemon", "start"])
    }

    /// Check if the daemon is running by verifying daemon.pid exists and the process is alive.
    static func isDaemonRunning() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pidPath = "\(home)/.agenthub/daemon.pid"

        guard let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(pidString) else {
            return false
        }

        // kill(pid, 0) returns 0 if the process exists
        return kill(pid, 0) == 0
    }

    // MARK: - Version

    /// Get the CLI version by running `agenthub --version`.
    static func cliReportedVersion() -> String? {
        let result = runCLI(["--version"])
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
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

    /// The CLI version to install, synced from the repo-root VERSION file at build time.
    static var cliVersion: String { GeneratedVersion.string }

    /// Returns whether the installed CLI matches the expected CLI version.
    static func cliVersionStatus() -> CLIVersionStatus {
        guard findBinary() != nil else {
            return .notInstalled
        }

        let expected = cliVersion
        guard let installed = cliReportedVersion() else {
            return .needsUpdate(installedVersion: nil, expectedVersion: expected)
        }

        if compareVersions(installed, expected) == .orderedAscending {
            return .needsUpdate(installedVersion: installed, expectedVersion: expected)
        }

        return .upToDate
    }

    // MARK: - Binary Discovery & Installation

    /// Find the agenthub CLI binary.
    /// Checks: app bundle → installed locations → bun global → dev build path.
    static func findBinary() -> String? {
        // 1. Bundled inside the app
        if let bundled = Bundle.main.path(forResource: "agenthub", ofType: nil) {
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }

        // 2. Already installed
        let candidates = [
            "/usr/local/bin/agenthub",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/agenthub").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".bun/bin/agenthub").path,
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    /// Locate the bun binary.
    static func findBunPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Install the agenthub CLI via `bun i -g @timbroddin/agenthub@{version}`.
    static func installBinary(from sourcePath: String) throws -> String {
        let bunPath = findBunPath() ?? "/usr/local/bin/bun"
        let version = cliVersion
        let pkg = "@timbroddin/agenthub@\(version)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bunPath)
        process.arguments = ["i", "-g", pkg]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = stderrData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw NSError(domain: "HookInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bun i -g \(pkg) failed: \(stderrStr)"])
        }

        if let found = findBinary() {
            return found
        }
        return "/usr/local/bin/agenthub"
    }

    // MARK: - Status Checks

    /// Check if agenthub hooks are installed in either Claude Code or OpenCode.
    static func isInstalled() -> Bool {
        isClaudeHooksInstalled() || isOpenCodeHooksInstalled()
    }

    /// Check if agenthub hooks are installed in Claude Code.
    static func isClaudeHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        // Check if at least one agenthub hook exists
        for (_, value) in hooks {
            if let eventHooks = value as? [[String: Any]] {
                let hasAgenthub = eventHooks.contains { entry in
                    guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                    return hookList.contains { hook in
                        guard let command = hook["command"] as? String else { return false }
                        return isAgenthubCommand(command)
                    }
                }
                if hasAgenthub { return true }
            }
        }
        return false
    }

    /// Check if agenthub hooks are installed in OpenCode.
    static func isOpenCodeHooksInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: openCodePluginPath.path),
              let content = try? String(contentsOf: openCodePluginPath, encoding: .utf8) else {
            return false
        }
        return content.contains("agenthub-opencode-plugin")
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

    private static func isAgenthubCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).first else {
            return false
        }
        let executable = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return name == "agenthub"
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
