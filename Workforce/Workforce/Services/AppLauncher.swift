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
    static func openInTerminal(tmuxSession: String, terminal: SupportedTerminal) {
        let tmuxPath = findTmux() ?? "/opt/homebrew/bin/tmux"
        let command = "\(tmuxPath) attach -t \(tmuxSession)"

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
            // For Ghostty, Warp, Kitty, Alacritty, WezTerm — open the app then
            // use a shell wrapper since these don't have reliable AppleScript support
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

    static func tmuxAttachCommand(session: String) -> String {
        let tmuxPath = findTmux() ?? "tmux"
        return "\(tmuxPath) attach -t \(session)"
    }

    static func runTmuxCommand(session: String, args: [String]) {
        let tmuxPath = findTmux() ?? "/opt/homebrew/bin/tmux"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = args + ["-t", session]
        process.standardOutput = nil
        process.standardError = nil
        try? process.run()
    }

    private static func findTmux() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
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
