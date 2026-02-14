import ArgumentParser
import Foundation

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run Claude Code inside a tmux session",
        discussion: """
        Wraps `claude` in a named tmux session so the Workforce app can attach to it.
        Everything after -- is passed to claude.

        Examples:
          workforce run
          workforce run -- --model opus
          workforce run -- "fix the login bug"
        """
    )

    @Argument(parsing: .allUnrecognized)
    var claudeArgs: [String] = []

    func run() throws {
        // Check tmux is available
        let whichTmux = Process()
        whichTmux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichTmux.arguments = ["which", "tmux"]
        whichTmux.standardOutput = FileHandle.nullDevice
        whichTmux.standardError = FileHandle.nullDevice
        try whichTmux.run()
        whichTmux.waitUntilExit()
        guard whichTmux.terminationStatus == 0 else {
            throw ValidationError(
                "tmux not found. Install with: brew install tmux"
            )
        }

        // Check claude is available
        let whichClaude = Process()
        whichClaude.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichClaude.arguments = ["which", "claude"]
        whichClaude.standardOutput = FileHandle.nullDevice
        whichClaude.standardError = FileHandle.nullDevice
        try whichClaude.run()
        whichClaude.waitUntilExit()
        guard whichClaude.terminationStatus == 0 else {
            throw ValidationError(
                "claude not found. Install Claude Code first: https://docs.anthropic.com/en/docs/claude-code"
            )
        }

        // Generate session name
        let hexBytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
        let hex = hexBytes.map { String(format: "%02x", $0) }.joined()
        let sessionName = "workforce-\(hex)"

        // Build tmux command: tmux new-session -s <name> -- claude [args...]
        let tmux = Process()
        tmux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var tmuxArgs = ["tmux", "new-session", "-s", sessionName, "--", "claude"]
        tmuxArgs.append(contentsOf: claudeArgs)
        tmux.arguments = tmuxArgs
        tmux.standardInput = FileHandle.standardInput
        tmux.standardOutput = FileHandle.standardOutput
        tmux.standardError = FileHandle.standardError

        // Forward signals
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        try tmux.run()
        tmux.waitUntilExit()

        // Exit with tmux's exit code
        throw ExitCode(tmux.terminationStatus)
    }
}
