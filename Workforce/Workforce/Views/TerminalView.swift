import SwiftUI
import WebKit
import UniformTypeIdentifiers
import CoreText

// MARK: - Font Registration

enum NerdFontRegistration {
    static let registered: Bool = {
        let fontFiles = [
            "JetBrainsMonoNerdFontMono-Regular",
            "JetBrainsMonoNerdFontMono-Bold",
            "JetBrainsMonoNerdFontMono-Italic",
            "JetBrainsMonoNerdFontMono-BoldItalic",
        ]
        var success = true
        for name in fontFiles {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                NSLog("[Workforce] font not found in bundle: \(name).ttf")
                success = false
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
                NSLog("[Workforce] failed to register font \(name): \(desc)")
                success = false
            }
        }
        return success
    }()
}

// MARK: - Custom URL Scheme Handler

/// Serves bundled resources (HTML, fonts) via a custom `workforce://` scheme
/// so WKWebView can load @font-face fonts without file:// restrictions.
class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        guard let filename = url.host else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        guard let fileURL = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType: String
        if let utType = UTType(filenameExtension: ext) {
            mimeType = utType.preferredMIMEType ?? "application/octet-stream"
        } else {
            mimeType = "application/octet-stream"
        }

        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: ext == "html" ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Nothing to cancel
    }
}

// MARK: - Terminal View

/// Wraps a WKWebView running xterm.js for use in SwiftUI.
/// Attaches to a tmux session by spawning `tmux attach -t <sessionName>` via a PTY.
struct TerminalRepresentable: NSViewRepresentable {
    let sessionName: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        _ = NerdFontRegistration.registered

        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        userContentController.add(context.coordinator, name: "terminalInput")
        userContentController.add(context.coordinator, name: "terminalResize")
        userContentController.add(context.coordinator, name: "terminalReady")

        config.userContentController = userContentController

        let schemeHandler = BundleSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "workforce")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        webView.load(URLRequest(url: URL(string: "workforce://terminal.html")!))
        context.coordinator.startPTY(sessionName: sessionName)

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No dynamic updates — session is set at creation time.
        // Switching agents creates a new TerminalRepresentable with a different id.
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var ptyFD: Int32 = -1
        private var childPID: pid_t = 0
        private var readSource: DispatchSourceRead?
        private var isStopped = false

        func startPTY(sessionName: String) {
            let tmuxPath = findExecutable("tmux") ?? "/opt/homebrew/bin/tmux"

            // -u forces UTF-8 mode for proper powerline glyph rendering
            let args = [tmuxPath, "-u", "attach", "-t", sessionName]

            let cArgs = args.map { strdup($0) } + [nil]
            defer { cArgs.forEach { if let p = $0 { free(p) } } }

            var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

            var fd: Int32 = 0
            let pid = forkpty(&fd, nil, nil, &winSize)

            if pid < 0 {
                NSLog("[Workforce] forkpty failed: \(String(cString: strerror(errno)))")
                return
            }

            if pid == 0 {
                // Child process — exec tmux
                for (key, value) in ProcessInfo.processInfo.environment {
                    setenv(key, value, 1)
                }

                setenv("TERM", "xterm-256color", 1)
                setenv("LANG", "en_US.UTF-8", 1)
                setenv("LC_ALL", "en_US.UTF-8", 1)

                if ProcessInfo.processInfo.environment["PATH"] == nil {
                    setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1)
                }

                execv(tmuxPath, cArgs.map { UnsafeMutablePointer(mutating: $0) })
                _exit(1)
            }

            // Parent process
            self.ptyFD = fd
            self.childPID = pid

            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
            source.setEventHandler { [weak self] in
                self?.readFromPTY()
            }
            source.setCancelHandler { [weak self] in
                guard let self = self else { return }
                if self.ptyFD >= 0 {
                    close(self.ptyFD)
                    self.ptyFD = -1
                }
            }
            source.resume()
            self.readSource = source
        }

        private func readFromPTY() {
            guard !isStopped, ptyFD >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 16384)
            let bytesRead = read(ptyFD, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                let base64 = data.base64EncodedString()

                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.isStopped else { return }
                    self.webView?.evaluateJavaScript(
                        "window.terminalAPI && window.terminalAPI.writeBinary('\(base64)')"
                    )
                }
            } else if bytesRead == 0 {
                stop()
            }
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            readSource?.cancel()
            readSource = nil
            if childPID > 0 {
                kill(childPID, SIGTERM)
                childPID = 0
            }
        }

        // MARK: - WKScriptMessageHandler

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            DispatchQueue.main.async { [weak self] in
                self?.handleMessage(name: message.name, body: message.body)
            }
        }

        private func handleMessage(name: String, body: Any) {
            switch name {
            case "terminalInput":
                if let str = body as? String, let data = str.data(using: .utf8) {
                    data.withUnsafeBytes { ptr in
                        if let baseAddress = ptr.baseAddress {
                            let _ = write(ptyFD, baseAddress, ptr.count)
                        }
                    }
                }

            case "terminalResize":
                if let dict = body as? [String: Any],
                   let cols = dict["cols"] as? Int,
                   let rows = dict["rows"] as? Int {
                    var winSize = winsize(
                        ws_row: UInt16(rows),
                        ws_col: UInt16(cols),
                        ws_xpixel: 0,
                        ws_ypixel: 0
                    )
                    _ = ioctl(ptyFD, TIOCSWINSZ, &winSize)
                }

            case "terminalReady":
                if let dict = body as? [String: Any],
                   let cols = dict["cols"] as? Int,
                   let rows = dict["rows"] as? Int {
                    var winSize = winsize(
                        ws_row: UInt16(rows),
                        ws_col: UInt16(cols),
                        ws_xpixel: 0,
                        ws_ypixel: 0
                    )
                    _ = ioctl(ptyFD, TIOCSWINSZ, &winSize)
                }
                webView?.evaluateJavaScript("window.terminalAPI && window.terminalAPI.focus()")

            default:
                break
            }
        }

        private func findExecutable(_ name: String) -> String? {
            let paths = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "/usr/bin/\(name)",
            ]
            return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        deinit {
            stop()
        }
    }
}

// MARK: - Command Terminal View

/// Wraps a WKWebView running xterm.js for use in SwiftUI.
/// Runs an arbitrary command via a PTY instead of attaching to a tmux session.
struct CommandTerminalRepresentable: NSViewRepresentable {
    let command: String
    let arguments: [String]
    let workingDirectory: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        _ = NerdFontRegistration.registered

        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        userContentController.add(context.coordinator, name: "terminalInput")
        userContentController.add(context.coordinator, name: "terminalResize")
        userContentController.add(context.coordinator, name: "terminalReady")

        config.userContentController = userContentController

        let schemeHandler = BundleSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "cmdterm")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        webView.load(URLRequest(url: URL(string: "cmdterm://terminal.html")!))
        context.coordinator.startCommand(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory
        )

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var ptyFD: Int32 = -1
        private var childPID: pid_t = 0
        private var readSource: DispatchSourceRead?
        private var isStopped = false

        func startCommand(command: String, arguments: [String], workingDirectory: String?) {
            let allArgs = [command] + arguments
            let cArgs = allArgs.map { strdup($0) } + [nil]
            defer { cArgs.forEach { if let p = $0 { free(p) } } }

            var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

            var fd: Int32 = 0
            let pid = forkpty(&fd, nil, nil, &winSize)

            if pid < 0 {
                NSLog("[Workforce] forkpty failed: \(String(cString: strerror(errno)))")
                return
            }

            if pid == 0 {
                // Child process
                for (key, value) in ProcessInfo.processInfo.environment {
                    setenv(key, value, 1)
                }

                setenv("TERM", "xterm-256color", 1)
                setenv("LANG", "en_US.UTF-8", 1)
                setenv("LC_ALL", "en_US.UTF-8", 1)

                if ProcessInfo.processInfo.environment["PATH"] == nil {
                    setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1)
                }

                if let wd = workingDirectory {
                    chdir(wd)
                }

                execv(command, cArgs.map { UnsafeMutablePointer(mutating: $0) })
                _exit(1)
            }

            // Parent process
            self.ptyFD = fd
            self.childPID = pid

            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
            source.setEventHandler { [weak self] in
                self?.readFromPTY()
            }
            source.setCancelHandler { [weak self] in
                guard let self = self else { return }
                if self.ptyFD >= 0 {
                    close(self.ptyFD)
                    self.ptyFD = -1
                }
            }
            source.resume()
            self.readSource = source
        }

        private func readFromPTY() {
            guard !isStopped, ptyFD >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 16384)
            let bytesRead = read(ptyFD, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                let base64 = data.base64EncodedString()

                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.isStopped else { return }
                    self.webView?.evaluateJavaScript(
                        "window.terminalAPI && window.terminalAPI.writeBinary('\(base64)')"
                    )
                }
            } else if bytesRead == 0 {
                stop()
            }
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            readSource?.cancel()
            readSource = nil
            if childPID > 0 {
                kill(childPID, SIGTERM)
                childPID = 0
            }
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            DispatchQueue.main.async { [weak self] in
                self?.handleMessage(name: message.name, body: message.body)
            }
        }

        private func handleMessage(name: String, body: Any) {
            switch name {
            case "terminalInput":
                if let str = body as? String, let data = str.data(using: .utf8) {
                    data.withUnsafeBytes { ptr in
                        if let baseAddress = ptr.baseAddress {
                            let _ = write(ptyFD, baseAddress, ptr.count)
                        }
                    }
                }

            case "terminalResize":
                if let dict = body as? [String: Any],
                   let cols = dict["cols"] as? Int,
                   let rows = dict["rows"] as? Int {
                    var winSize = winsize(
                        ws_row: UInt16(rows),
                        ws_col: UInt16(cols),
                        ws_xpixel: 0,
                        ws_ypixel: 0
                    )
                    _ = ioctl(ptyFD, TIOCSWINSZ, &winSize)
                }

            case "terminalReady":
                if let dict = body as? [String: Any],
                   let cols = dict["cols"] as? Int,
                   let rows = dict["rows"] as? Int {
                    var winSize = winsize(
                        ws_row: UInt16(rows),
                        ws_col: UInt16(cols),
                        ws_xpixel: 0,
                        ws_ypixel: 0
                    )
                    _ = ioctl(ptyFD, TIOCSWINSZ, &winSize)
                }
                webView?.evaluateJavaScript("window.terminalAPI && window.terminalAPI.focus()")

            default:
                break
            }
        }

        deinit {
            stop()
        }
    }
}
