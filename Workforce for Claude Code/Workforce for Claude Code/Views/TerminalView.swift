import SwiftUI
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView for use in SwiftUI.
/// Attaches to a tmux session by spawning `tmux attach -t <sessionName>`.
struct TerminalRepresentable: NSViewRepresentable {
    let sessionName: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)

        let tmuxPath = findExecutable("tmux") ?? "/opt/homebrew/bin/tmux"

        view.startProcess(
            executable: tmuxPath,
            args: ["attach", "-t", sessionName],
            environment: nil,
            execName: "tmux"
        )

        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // No dynamic updates — session is set at creation time.
        // Switching agents creates a new TerminalRepresentable with a different id.
    }

    private func findExecutable(_ name: String) -> String? {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
