import AppKit

enum SupportedTerminal: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm = "iTerm"
    case ghostty = "Ghostty"
    case warp = "Warp"
    case kitty = "Kitty"
    case alacritty = "Alacritty"
    case wezterm = "WezTerm"

    var id: String { rawValue }

    var bundleId: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        case .wezterm: "com.github.wez.wezterm"
        }
    }
}

enum SupportedIDE: String, CaseIterable, Identifiable {
    case vscode = "VS Code"
    case cursor = "Cursor"
    case windsurf = "Windsurf"
    case zed = "Zed"
    case xcode = "Xcode"
    case intellij = "IntelliJ IDEA"
    case sublime = "Sublime Text"
    case nova = "Nova"

    var id: String { rawValue }

    var appName: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .zed: "Zed"
        case .xcode: "Xcode"
        case .intellij: "IntelliJ IDEA"
        case .sublime: "Sublime Text"
        case .nova: "Nova"
        }
    }
}

enum AppLauncher {
    /// Open an agent in the user's preferred external terminal via `agenthub attach`.
    static func openInTerminal(agentId: String, terminal: SupportedTerminal) {
        let agenthubPath = findExecutable("agenthub") ?? "agenthub"
        let command = "\(agenthubPath) attach \(agentId)"

        switch terminal {
        case .terminal:
            let script = """
            tell application "Terminal"
                activate
                do script "\(command)"
            end tell
            """
            runAppleScript(script)

        case .iterm:
            let script = """
            tell application "iTerm"
                activate
                create window with default profile command "\(command)"
            end tell
            """
            runAppleScript(script)

        default:
            // For Ghostty, Warp, Kitty, Alacritty, WezTerm
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", terminal.rawValue, "--args", "-e", command]
            try? process.run()
        }
    }

    /// Open a remote agent in an external terminal via SSH + agenthub attach.
    static func openRemoteInTerminal(agentId: String, host: String, terminal: SupportedTerminal) {
        let command = "ssh -t \(host) agenthub attach \(agentId)"

        switch terminal {
        case .terminal:
            let script = """
            tell application "Terminal"
                activate
                do script "\(command)"
            end tell
            """
            runAppleScript(script)

        case .iterm:
            let script = """
            tell application "iTerm"
                activate
                create window with default profile command "\(command)"
            end tell
            """
            runAppleScript(script)

        default:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", terminal.rawValue, "--args", "-e", command]
            try? process.run()
        }
    }

    static func openInIDE(path: String, ide: SupportedIDE) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", ide.appName, path]
        try? process.run()
    }

    static func openInFinder(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func attachCommand(agentId: String) -> String {
        let agenthubPath = findExecutable("agenthub") ?? "agenthub"
        return "\(agenthubPath) attach \(agentId)"
    }

    static func remoteAttachCommand(agentId: String, host: String) -> String {
        return "ssh -t \(host) agenthub attach \(agentId)"
    }

    private static func findExecutable(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: source)
            script?.executeAndReturnError(nil)
        }
    }
}
