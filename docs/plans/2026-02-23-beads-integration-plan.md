# Beads Integration Enhancement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add tabbed settings (General/Beads), support for bd+br implementations, project-level beads init with CLAUDE.md setup, and GUI issue create/close.

**Architecture:** BeadsService becomes the central coordinator for all beads CLI operations (init, create, close, reopen) by shelling out to the user's preferred implementation (bd or br). SettingsView splits into TabView with General and Beads tabs. ProjectDetailView shows a setup CTA when no .beads folder exists. BeadsViewerView gains create/close issue actions.

**Tech Stack:** Swift, SwiftUI, AppStorage, Process (for CLI execution)

---

### Task 1: Extend BeadsService with CLI runner and binary detection

**Files:**
- Modify: `Workforce/Workforce/Services/BeadsService.swift`

**Step 1: Add BeadsImplementation enum and binary finders**

Add at the top of BeadsService.swift, before the `BeadsService` enum:

```swift
enum BeadsImplementation: String, CaseIterable, Identifiable {
    case bd = "bd"
    case br = "br"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bd: "Beads (bd)"
        case .br: "Beads Rust (br)"
        }
    }
}
```

**Step 2: Add methods to BeadsService**

Add these methods inside the `BeadsService` enum (after the existing `findBeadsViewer` method):

```swift
// MARK: - Binary Discovery

static func findBinary(_ name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "\(home)/.local/bin/\(name)",
        "\(home)/.cargo/bin/\(name)",
        "\(home)/.bun/bin/\(name)",
        "/usr/bin/\(name)",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

static func isBdInstalled() -> Bool { findBinary("bd") != nil }
static func isBrInstalled() -> Bool { findBinary("br") != nil }

static func preferredCLIPath() -> String? {
    let pref = UserDefaults.standard.string(forKey: "beadsImplementation") ?? "br"
    return findBinary(pref) ?? findBinary("br") ?? findBinary("bd")
}

static func preferredImplementation() -> BeadsImplementation {
    let pref = UserDefaults.standard.string(forKey: "beadsImplementation") ?? "br"
    return BeadsImplementation(rawValue: pref) ?? .br
}

// MARK: - CLI Runner

struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var success: Bool { exitCode == 0 }
}

@discardableResult
static func runCLI(arguments: [String], cwd: String) -> CLIResult {
    guard let binary = preferredCLIPath() else {
        return CLIResult(exitCode: 1, stdout: "", stderr: "No beads CLI found")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

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

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return CLIResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

// MARK: - Issue Operations

static func initBeads(cwd: String) -> CLIResult {
    runCLI(arguments: ["init"], cwd: cwd)
}

static func createIssue(title: String, priority: Int?, type: String?, description: String?, cwd: String) -> CLIResult {
    var args = ["create", title]
    if let p = priority { args += ["-p", "\(p)"] }
    if let t = type, !t.isEmpty { args += ["-t", t] }
    if let d = description, !d.isEmpty { args += ["-d", d] }
    return runCLI(arguments: args, cwd: cwd)
}

static func closeIssue(id: String, cwd: String) -> CLIResult {
    runCLI(arguments: ["close", id], cwd: cwd)
}

static func reopenIssue(id: String, cwd: String) -> CLIResult {
    runCLI(arguments: ["reopen", id], cwd: cwd)
}

// MARK: - Install Scripts

static func installBd(completion: @escaping (Bool) -> Void) {
    runInstallScript(
        command: "curl -fsSL 'https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh' | bash",
        completion: completion
    )
}

static func installBr(completion: @escaping (Bool) -> Void) {
    runInstallScript(
        command: "curl -fsSL 'https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh' | bash",
        completion: completion
    )
}

static func installBv(viaHomebrew: Bool, completion: @escaping (Bool) -> Void) {
    if viaHomebrew {
        let brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let brew = brewPath else {
            completion(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", "dicklesworthstone/tap/bv"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            DispatchQueue.main.async { completion(ok) }
        }
    } else {
        runInstallScript(
            command: "curl -fsSL 'https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh' | bash",
            completion: completion
        )
    }
}

private static func runInstallScript(command: String, completion: @escaping (Bool) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let ok = process.terminationStatus == 0
        DispatchQueue.main.async { completion(ok) }
    }
}

// MARK: - CLAUDE.md / AGENTS.md Instructions

static func appendBeadsInstructions(to cwd: String) {
    let impl = preferredImplementation()
    let cmd = impl.rawValue

    let block = """

    ## Beads Issue Tracking

    Use `\(cmd)` for issue tracking in this project.
    - `\(cmd) list` — list open issues
    - `\(cmd) ready` — show unblocked issues ready for work
    - `\(cmd) create "title" -p <priority>` — create an issue
    - `\(cmd) close <id>` — close a completed issue
    - `\(cmd) show <id>` — view issue details
    """

    for filename in ["CLAUDE.md", "AGENTS.md"] {
        let path = (cwd as NSString).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                if let data = ("\n" + block + "\n").data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        }
    }
}
```

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/BeadsService.swift
git commit -m "feat: extend BeadsService with CLI runner, install helpers, and issue operations"
```

---

### Task 2: Split SettingsView into tabbed General / Beads

**Files:**
- Modify: `Workforce/Workforce/Views/SettingsView.swift`

**Step 1: Wrap existing content in TabView, add Beads tab**

Replace the entire `SettingsView.swift` with:

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            BeadsSettingsView()
                .tabItem {
                    Label("Beads", systemImage: "target")
                }
        }
        .frame(width: 420, height: 480)
    }
}

// MARK: - General Settings

private struct GeneralSettingsView: View {
    @AppStorage("defaultTerminal") private var defaultTerminal: String = SupportedTerminal.terminal.rawValue
    @AppStorage("defaultIDE") private var defaultIDE: String = SupportedIDE.vscode.rawValue
    @AppStorage("summarizationBackend") private var summarizationBackend: String = SummarizationBackend.systemDefault.rawValue
    @AppStorage("openRouterAPIKey") private var openRouterAPIKey: String = ""
    @AppStorage("openRouterModel") private var openRouterModel: String = "google/gemini-2.5-flash-lite"
    @AppStorage("listenOnAllInterfaces") private var listenOnAllInterfaces: Bool = false

    @State private var cliInstalled = false
    @State private var cliNeedsUpdate = false
    @State private var claudeHooksInstalled = false
    @State private var openCodeHooksInstalled = false
    @State private var message: String?

    var body: some View {
        Form {
            Picker("Default Terminal", selection: $defaultTerminal) {
                ForEach(SupportedTerminal.allCases) { terminal in
                    Text(terminal.rawValue).tag(terminal.rawValue)
                }
            }

            Picker("Default IDE", selection: $defaultIDE) {
                ForEach(SupportedIDE.allCases) { ide in
                    Text(ide.rawValue).tag(ide.rawValue)
                }
            }

            Section("Notification Summaries") {
                Picker("Backend", selection: $summarizationBackend) {
                    ForEach(SummarizationBackend.availableCases) { backend in
                        Text(backend.rawValue).tag(backend.rawValue)
                    }
                }

                if summarizationBackend == SummarizationBackend.appleIntelligence.rawValue {
                    if !SummarizationBackend.isAppleIntelligenceReady {
                        Label("Apple Intelligence is not enabled. Enable it in System Settings → Apple Intelligence & Siri.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                if summarizationBackend == SummarizationBackend.openRouter.rawValue {
                    SecureField("OpenRouter API Key", text: $openRouterAPIKey)
                    TextField("Model", text: $openRouterModel)
                        .font(.caption)
                }
            }

            Section("Network") {
                Toggle("Listen on all interfaces", isOn: $listenOnAllInterfaces)
                Text("When enabled, the API is accessible from other devices on your network. Requires app restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Workforce CLI & Hooks") {
                HStack {
                    Text("CLI Binary")
                    Spacer()
                    if cliInstalled {
                        Image(systemName: cliNeedsUpdate ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(cliNeedsUpdate ? .yellow : .green)
                        Button(cliNeedsUpdate ? "Update" : "Reinstall") { installCLI() }
                            .disabled(HookInstaller.findBinary() == nil)
                    } else {
                        Button("Install") { installCLI() }
                            .disabled(HookInstaller.findBinary() == nil)
                    }
                }

                HStack {
                    Text("Claude Code Hooks")
                    Spacer()
                    Image(systemName: claudeHooksInstalled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(claudeHooksInstalled ? .green : .secondary)
                    Button(claudeHooksInstalled ? "Reinstall" : "Install") { installClaudeHooks() }
                        .disabled(!cliInstalled)
                    if claudeHooksInstalled {
                        Button("Uninstall") { uninstallClaudeHooks() }
                    }
                }

                HStack {
                    Text("OpenCode Hooks")
                    Spacer()
                    Image(systemName: openCodeHooksInstalled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(openCodeHooksInstalled ? .green : .secondary)
                    Button(openCodeHooksInstalled ? "Reinstall" : "Install") { installOpenCodeHooks() }
                        .disabled(!cliInstalled)
                    if openCodeHooksInstalled {
                        Button("Uninstall") { uninstallOpenCodeHooks() }
                    }
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { checkStatus() }
    }

    private func checkStatus() {
        cliInstalled = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/workforce")
        switch HookInstaller.cliVersionStatus() {
        case .needsUpdate(let installedVersion, let appVersion):
            cliNeedsUpdate = true
            if let installedVersion {
                message = "CLI update available: installed \(installedVersion), app \(appVersion)"
            } else {
                message = "CLI update available: installed version unknown, app \(appVersion)"
            }
        case .upToDate:
            cliNeedsUpdate = false
        case .notInstalled:
            cliNeedsUpdate = false
        }
        claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
        openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
    }

    private func installCLI() {
        guard let source = HookInstaller.findBinary() else {
            message = "workforce binary not found"
            return
        }
        do {
            _ = try HookInstaller.installBinary(from: source)
            cliInstalled = true
            cliNeedsUpdate = false
            message = "CLI installed to /usr/local/bin/workforce"
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func installClaudeHooks() {
        do {
            let count = try HookInstaller.installClaude(binaryPath: "/usr/local/bin/workforce")
            claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
            message = count > 0 ? "Installed Claude hooks." : "Claude hooks already installed."
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func installOpenCodeHooks() {
        do {
            let count = try HookInstaller.installOpenCode(binaryPath: "/usr/local/bin/workforce")
            openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
            message = count > 0 ? "Installed OpenCode hooks." : "OpenCode hooks already installed."
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func uninstallClaudeHooks() {
        do {
            _ = try HookInstaller.uninstallClaude()
            claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
            message = "Removed Claude hooks."
        } catch {
            message = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    private func uninstallOpenCodeHooks() {
        do {
            _ = try HookInstaller.uninstallOpenCode()
            openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
            message = "Removed OpenCode hooks."
        } catch {
            message = "Uninstall failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Beads Settings

private struct BeadsSettingsView: View {
    @AppStorage("beadsImplementation") private var beadsImplementation: String = "br"

    @State private var bdInstalled = false
    @State private var brInstalled = false
    @State private var bvInstalled = false
    @State private var isInstalling: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section("Default Implementation") {
                Picker("CLI Tool", selection: $beadsImplementation) {
                    ForEach(BeadsImplementation.allCases) { impl in
                        Text(impl.displayName).tag(impl.rawValue)
                    }
                }
                Text("Select which beads CLI to use for issue tracking operations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Beads CLI (bd)") {
                installRow(
                    name: "bd",
                    installed: bdInstalled,
                    description: "Python/Go — steveyegge/beads",
                    isInstalling: isInstalling == "bd"
                ) {
                    isInstalling = "bd"
                    message = nil
                    BeadsService.installBd { ok in
                        isInstalling = nil
                        bdInstalled = BeadsService.isBdInstalled()
                        message = ok ? "bd installed successfully." : "bd installation failed."
                    }
                }
            }

            Section("Beads Rust CLI (br)") {
                installRow(
                    name: "br",
                    installed: brInstalled,
                    description: "Rust — Dicklesworthstone/beads_rust",
                    isInstalling: isInstalling == "br"
                ) {
                    isInstalling = "br"
                    message = nil
                    BeadsService.installBr { ok in
                        isInstalling = nil
                        brInstalled = BeadsService.isBrInstalled()
                        message = ok ? "br installed successfully." : "br installation failed."
                    }
                }
            }

            Section("Beads Viewer (bv)") {
                installRow(
                    name: "bv",
                    installed: bvInstalled,
                    description: "Graph-aware TUI viewer",
                    isInstalling: isInstalling == "bv"
                ) {
                    isInstalling = "bv"
                    message = nil
                    BeadsService.installBv(viaHomebrew: true) { ok in
                        isInstalling = nil
                        bvInstalled = BeadsService.isBeadsViewerInstalled()
                        message = ok ? "bv installed successfully." : "bv installation failed. Try installing manually."
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { checkStatus() }
    }

    private func checkStatus() {
        bdInstalled = BeadsService.isBdInstalled()
        brInstalled = BeadsService.isBrInstalled()
        bvInstalled = BeadsService.isBeadsViewerInstalled()
    }

    private func installRow(name: String, installed: Bool, description: String, isInstalling: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(installed ? .green : .secondary)
                Button(installed ? "Reinstall" : "Install") { action() }
            }
        }
    }
}
```

**Step 2: Commit**

```bash
git add Workforce/Workforce/Views/SettingsView.swift
git commit -m "feat: split settings into General and Beads tabs"
```

---

### Task 3: Add "Setup Beads" CTA in ProjectDetailView

**Files:**
- Modify: `Workforce/Workforce/Views/ProjectDetailView.swift`

**Step 1: Always show Issues tab, add setup view**

In `ProjectDetailView.swift`, change the tab bar to always show the Issues tab (remove the `if hasBeads` guard on line 121-123):

```swift
// Replace lines 121-123:
//     if hasBeads {
//         tabButton(title: "Issues", icon: "target", tag: 3)
//     }
// With:
tabButton(title: "Issues", icon: "target", tag: 3)
```

Then change the tab content (line 162) to handle the no-beads case:

```swift
// Replace line 162:
//     case 3: BeadsViewerView(cwd: cwd)
// With:
case 3:
    if hasBeads {
        BeadsViewerView(cwd: cwd)
    } else {
        BeadsSetupView(cwd: cwd) {
            hasBeads = BeadsService.hasBeadsFolder(at: cwd)
        }
    }
```

**Step 2: Create BeadsSetupView**

Add at the bottom of `ProjectDetailView.swift` (or in a new section of `BeadsViewerView.swift` — but keeping it in ProjectDetailView is cleaner since it's small):

Add a new file `Workforce/Workforce/Views/BeadsSetupView.swift`:

```swift
import SwiftUI

struct BeadsSetupView: View {
    let cwd: String
    let onSetupComplete: () -> Void

    @AppStorage("beadsImplementation") private var beadsImplementation: String = "br"
    @State private var isInitializing = false
    @State private var showInstructionsPrompt = false
    @State private var errorMessage: String?

    private var hasCLI: Bool {
        BeadsService.preferredCLIPath() != nil
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "target")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Set Up Issue Tracking")
                    .font(.headline)
                Text("Initialize beads in this project to track issues, dependencies, and priorities.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if isInitializing {
                ProgressView()
                    .controlSize(.small)
                Text("Initializing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !hasCLI {
                VStack(spacing: 6) {
                    Text("No beads CLI installed.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Install bd or br in Settings → Beads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    initBeads()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                        Text("Setup Beads")
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)

                Text("Runs \(beadsImplementation) init in this project")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .alert("Add Beads Instructions?", isPresented: $showInstructionsPrompt) {
            Button("Yes") {
                BeadsService.appendBeadsInstructions(to: cwd)
                onSetupComplete()
            }
            Button("No", role: .cancel) {
                onSetupComplete()
            }
        } message: {
            Text("Add beads usage instructions to CLAUDE.md and AGENTS.md in this project?")
        }
    }

    private func initBeads() {
        isInitializing = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = BeadsService.initBeads(cwd: cwd)
            DispatchQueue.main.async {
                isInitializing = false
                if result.success {
                    showInstructionsPrompt = true
                } else {
                    errorMessage = "Init failed: \(result.stderr)"
                }
            }
        }
    }
}
```

**Step 3: Commit**

```bash
git add Workforce/Workforce/Views/ProjectDetailView.swift Workforce/Workforce/Views/BeadsSetupView.swift
git commit -m "feat: add beads setup CTA when no .beads folder exists"
```

---

### Task 4: Add close/reopen buttons to issue detail in BeadsViewerView

**Files:**
- Modify: `Workforce/Workforce/Views/BeadsViewerView.swift`

**Step 1: Add state for operations**

Add to the `@State` properties at the top of `BeadsViewerView` (after line 12):

```swift
@State private var operatingOnIssue: String?
```

**Step 2: Add close/reopen button to issueDetail**

Replace the `issueDetail` method (lines 285-333) with a version that includes action buttons:

```swift
private func issueDetail(_ issue: BeadIssue) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        if let desc = issue.description, !desc.isEmpty {
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }

        HStack(spacing: 12) {
            if let by = issue.createdBy {
                Label(by, systemImage: "person")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let reason = issue.closeReason {
                Label(reason, systemImage: "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        if let deps = issue.dependencies, !deps.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dependencies")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.3)

                ForEach(deps, id: \.dependsOnId) { dep in
                    HStack(spacing: 4) {
                        Image(systemName: dep.type == "blocks" ? "arrow.right" : "arrow.turn.down.right")
                            .font(.system(size: 8))
                        Text(dep.dependsOnId)
                            .font(.system(.caption2, design: .monospaced))
                        Text("(\(dep.type))")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }

        Divider()

        HStack(spacing: 8) {
            if operatingOnIssue == issue.id {
                ProgressView()
                    .controlSize(.small)
            } else if issue.isOpen {
                Button {
                    closeIssue(issue)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption2)
                        Text("Close")
                            .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    reopenIssue(issue)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.left.circle")
                            .font(.caption2)
                        Text("Reopen")
                            .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
    }
    .padding(.horizontal, 40)
    .padding(.bottom, 10)
    .transition(.opacity.combined(with: .move(edge: .top)))
}

private func closeIssue(_ issue: BeadIssue) {
    operatingOnIssue = issue.id
    DispatchQueue.global(qos: .userInitiated).async {
        BeadsService.closeIssue(id: issue.id, cwd: cwd)
        DispatchQueue.main.async {
            operatingOnIssue = nil
            reload()
        }
    }
}

private func reopenIssue(_ issue: BeadIssue) {
    operatingOnIssue = issue.id
    DispatchQueue.global(qos: .userInitiated).async {
        BeadsService.reopenIssue(id: issue.id, cwd: cwd)
        DispatchQueue.main.async {
            operatingOnIssue = nil
            reload()
        }
    }
}
```

**Step 3: Commit**

```bash
git add Workforce/Workforce/Views/BeadsViewerView.swift
git commit -m "feat: add close/reopen buttons to issue detail view"
```

---

### Task 5: Add "create issue" popover to BeadsViewerView toolbar

**Files:**
- Modify: `Workforce/Workforce/Views/BeadsViewerView.swift`

**Step 1: Add state for the create popover**

Add to the `@State` properties (after `operatingOnIssue`):

```swift
@State private var showCreatePopover = false
@State private var newIssueTitle = ""
@State private var newIssuePriority: Int? = nil
@State private var newIssueType = ""
@State private var newIssueDescription = ""
@State private var isCreating = false
```

**Step 2: Add "+" button to toolbar**

In the `toolbar` computed property, add a "+" button before the `Spacer()` (after the filter pills ForEach, around line 112):

```swift
// After the ForEach closing brace (line 110) and before Spacer():
Button {
    showCreatePopover = true
} label: {
    Image(systemName: "plus")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
}
.buttonStyle(.plain)
.help("Create new issue")
.popover(isPresented: $showCreatePopover, arrowEdge: .bottom) {
    createIssuePopover
}
```

**Step 3: Add the create issue popover view**

Add this computed property to `BeadsViewerView`:

```swift
private var createIssuePopover: some View {
    VStack(alignment: .leading, spacing: 12) {
        Text("New Issue")
            .font(.headline)

        TextField("Title", text: $newIssueTitle)
            .textFieldStyle(.roundedBorder)

        HStack(spacing: 12) {
            Picker("Priority", selection: $newIssuePriority) {
                Text("None").tag(nil as Int?)
                Text("P1 High").tag(1 as Int?)
                Text("P2 Medium").tag(2 as Int?)
                Text("P3 Low").tag(3 as Int?)
            }
            .frame(maxWidth: 140)

            Picker("Type", selection: $newIssueType) {
                Text("None").tag("")
                Text("Task").tag("task")
                Text("Bug").tag("bug")
                Text("Feature").tag("feature")
            }
            .frame(maxWidth: 140)
        }

        TextEditor(text: $newIssueDescription)
            .font(.caption)
            .frame(height: 60)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                if newIssueDescription.isEmpty {
                    Text("Description (optional)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

        HStack {
            Spacer()
            Button("Cancel") {
                resetCreateForm()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                createIssue()
            } label: {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Create")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(newIssueTitle.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            .keyboardShortcut(.defaultAction)
        }
    }
    .padding(16)
    .frame(width: 320)
}

private func createIssue() {
    let title = newIssueTitle.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return }

    isCreating = true
    let priority = newIssuePriority
    let type = newIssueType
    let description = newIssueDescription.trimmingCharacters(in: .whitespacesAndNewlines)

    DispatchQueue.global(qos: .userInitiated).async {
        BeadsService.createIssue(
            title: title,
            priority: priority,
            type: type.isEmpty ? nil : type,
            description: description.isEmpty ? nil : description,
            cwd: cwd
        )
        DispatchQueue.main.async {
            isCreating = false
            resetCreateForm()
            reload()
        }
    }
}

private func resetCreateForm() {
    showCreatePopover = false
    newIssueTitle = ""
    newIssuePriority = nil
    newIssueType = ""
    newIssueDescription = ""
}
```

**Step 4: Commit**

```bash
git add Workforce/Workforce/Views/BeadsViewerView.swift
git commit -m "feat: add create issue popover to beads viewer toolbar"
```

---

### Task 6: Clean up BeadsViewerView — remove inline bv install logic

**Files:**
- Modify: `Workforce/Workforce/Views/BeadsViewerView.swift`

**Step 1: Replace installViaHomebrew and installViaScript methods**

Replace the `installViaHomebrew()` method (lines 438-465) and `installViaScript()` method (lines 467-489) with simplified versions that delegate to BeadsService:

```swift
private func installViaHomebrew() {
    isInstalling = true
    BeadsService.installBv(viaHomebrew: true) { ok in
        isInstalling = false
        bvInstalled = BeadsService.isBeadsViewerInstalled()
        if bvInstalled { viewMode = .terminal }
    }
}

private func installViaScript() {
    isInstalling = true
    BeadsService.installBv(viaHomebrew: false) { ok in
        isInstalling = false
        bvInstalled = BeadsService.isBeadsViewerInstalled()
        if bvInstalled { viewMode = .terminal }
    }
}
```

**Step 2: Commit**

```bash
git add Workforce/Workforce/Views/BeadsViewerView.swift
git commit -m "refactor: delegate bv install logic to BeadsService"
```

---

### Task 7: Final review and integration test

**Step 1: Build the project**

```bash
cd Workforce && xcodebuild build -scheme Workforce -destination 'platform=macOS' 2>&1 | tail -20
```

Fix any compilation errors.

**Step 2: Manual verification checklist**

- [ ] Settings → General tab shows all existing settings
- [ ] Settings → Beads tab shows implementation picker, install status for bd/br/bv
- [ ] Project with .beads folder shows Issues tab with existing beads viewer
- [ ] Project without .beads folder shows Issues tab with "Setup Beads" CTA
- [ ] Setup Beads runs init, then prompts about CLAUDE.md/AGENTS.md
- [ ] Expanding an open issue shows "Close" button
- [ ] Expanding a closed issue shows "Reopen" button
- [ ] "+" button in toolbar opens create issue popover
- [ ] Creating an issue refreshes the list

**Step 3: Commit any fixes**

```bash
git add -A && git commit -m "fix: address build issues from beads integration"
```
