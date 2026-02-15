# First-Launch Setup Wizard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a first-launch setup wizard that explains the app, checks prerequisites, installs the CLI + hooks, and teaches `workforce run`.

**Architecture:** A single `SetupWizardView` presented as a `.sheet` on `MainWindowView`, gated by `@AppStorage("hasCompletedSetup")`. The wizard reuses `HookInstaller` for CLI/hook installation and adds simple `$PATH` checks for tmux/claude. A Help menu item allows re-running the wizard.

**Tech Stack:** SwiftUI, AppStorage, existing HookInstaller

---

### Task 1: Create SetupWizardView

**Files:**
- Create: `Workforce/Workforce/Views/SetupWizardView.swift`

**Step 1: Create the view file**

```swift
import SwiftUI

struct SetupWizardView: View {
    @Binding var isPresented: Bool
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    // Prereq status
    @State private var hasTmux = false
    @State private var hasClaude = false

    // Install status
    @State private var cliInstalled = false
    @State private var hooksInstalled = false
    @State private var installError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection
                Divider()
                prerequisitesSection
                Divider()
                installSection
                Divider()
                usageSection
            }
            .padding(32)
        }
        .frame(width: 520, height: 580)
        .task { checkStatus() }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button("Get Started") {
                        hasCompletedSetup = true
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Welcome to Workforce")
                .font(.title)
                .fontWeight(.bold)

            Text("Workforce monitors your Claude Code sessions in real-time. It tracks agents, subagents, tool usage, and notifications — all in one window.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Prerequisites

    private var prerequisitesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prerequisites")
                .font(.headline)

            statusRow(
                name: "tmux",
                installed: hasTmux,
                hint: "brew install tmux"
            )
            statusRow(
                name: "Claude CLI",
                installed: hasClaude,
                hint: "See claude.ai/download"
            )
        }
    }

    private func statusRow(name: String, installed: Bool, hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(installed ? .green : .yellow)
                .frame(width: 20)

            Text(name)
                .fontWeight(.medium)

            Spacer()

            if !installed {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Install

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup")
                .font(.headline)

            HStack(spacing: 8) {
                Image(systemName: cliInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(cliInstalled ? .green : .secondary)
                    .frame(width: 20)

                Text("Workforce CLI")
                    .fontWeight(.medium)

                Spacer()

                if !cliInstalled {
                    Button("Install") { installCLI() }
                        .disabled(HookInstaller.findBinary() == nil)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: hooksInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(hooksInstalled ? .green : .secondary)
                    .frame(width: 20)

                Text("Claude Code Hooks")
                    .fontWeight(.medium)

                Spacer()

                if !hooksInstalled {
                    Button("Install") { installHooks() }
                        .disabled(!cliInstalled)
                }
            }

            if let installError {
                Text(installError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Getting Started")
                .font(.headline)

            Text("Launch a tracked Claude agent with:")
                .foregroundStyle(.secondary)

            Text("workforce run claude \"Build the login page\"")
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .textSelection(.enabled)

            Text("The agent will appear in the sidebar and you can monitor its progress in the embedded terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func checkStatus() {
        hasTmux = isCommandAvailable("tmux")
        hasClaude = isCommandAvailable("claude")
        cliInstalled = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/workforce")
        hooksInstalled = HookInstaller.isInstalled()
    }

    private func installCLI() {
        installError = nil
        guard let source = HookInstaller.findBinary() else {
            installError = "workforce binary not found in build output"
            return
        }
        do {
            _ = try HookInstaller.installBinary(from: source)
            cliInstalled = true
        } catch {
            installError = error.localizedDescription
        }
    }

    private func installHooks() {
        installError = nil
        do {
            _ = try HookInstaller.install(binaryPath: "/usr/local/bin/workforce")
            hooksInstalled = true
        } catch {
            installError = error.localizedDescription
        }
    }

    private func isCommandAvailable(_ command: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "\(home)/.local/bin/\(command)",
        ]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
```

**Step 2: Verify it compiles**

Build the Xcode project and confirm no compiler errors.

**Step 3: Commit**

```
git add "Workforce/Workforce/Views/SetupWizardView.swift"
git commit -m "feat: add SetupWizardView for first-launch wizard"
```

---

### Task 2: Wire up sheet presentation in MainWindowView

**Files:**
- Modify: `Workforce/Workforce/Views/MainWindowView.swift`

**Step 1: Add @AppStorage and sheet state**

Add these properties to `MainWindowView`:

```swift
@AppStorage("hasCompletedSetup") private var hasCompletedSetup = false
@State private var showSetupWizard = false
```

**Step 2: Add .sheet modifier and .onAppear trigger**

Add to the `VStack` in `body` (after the existing `.task` modifiers):

```swift
.sheet(isPresented: $showSetupWizard) {
    SetupWizardView(isPresented: $showSetupWizard)
}
.onAppear {
    if !hasCompletedSetup {
        showSetupWizard = true
    }
}
```

**Step 3: Verify it works**

Run the app. On first launch (or after clearing `hasCompletedSetup` from UserDefaults), the sheet should appear.

**Step 4: Commit**

```
git add "Workforce/Workforce/Views/MainWindowView.swift"
git commit -m "feat: present setup wizard sheet on first launch"
```

---

### Task 3: Add "Run Setup Wizard" menu item

**Files:**
- Modify: `Workforce/Workforce/WorkforceApp.swift`
- Modify: `Workforce/Workforce/Views/MainWindowView.swift`

**Step 1: Add a notification for re-running the wizard**

In `MainWindowView`, add a listener for a custom notification that re-triggers the wizard:

```swift
.onReceive(NotificationCenter.default.publisher(for: .showSetupWizard)) { _ in
    showSetupWizard = true
}
```

And add the notification name extension (can go in SetupWizardView.swift or a shared location):

```swift
extension Notification.Name {
    static let showSetupWizard = Notification.Name("showSetupWizard")
}
```

**Step 2: Add the menu command in WorkforceApp**

In the `.commands` block of the main Window scene, add a Help menu item:

```swift
CommandGroup(replacing: .help) {
    Button("Setup Wizard...") {
        NotificationCenter.default.post(name: .showSetupWizard, object: nil)
    }
}
```

**Step 3: Verify**

Run the app. Open Help menu → "Setup Wizard..." should re-present the sheet even after completing setup.

**Step 4: Commit**

```
git add "Workforce/Workforce/WorkforceApp.swift" "Workforce/Workforce/Views/MainWindowView.swift"
git commit -m "feat: add Help menu item to re-run setup wizard"
```

---

### Task 4: Add SetupWizardView to Xcode project

**Files:**
- Modify: `Workforce/Workforce.xcodeproj/project.pbxproj`

This is handled automatically by Xcode when the file is in the right directory and the project uses file system references. If using explicit file references, add `SetupWizardView.swift` to the Views group in the Xcode project.

**Step 1: Verify the file is included in the build**

Build the project in Xcode. If `SetupWizardView` is not found, add it to the project's file references.

**Step 2: Full end-to-end test**

1. Delete `hasCompletedSetup` from UserDefaults: `defaults delete com.workforce.app hasCompletedSetup` (adjust bundle ID)
2. Launch app → wizard sheet appears
3. Verify prereq checks show correct status
4. Click Install CLI → installs binary
5. Click Install Hooks → installs hooks
6. Click Get Started → sheet dismisses, main view visible
7. Relaunch app → wizard does NOT appear
8. Help → Setup Wizard... → wizard appears again

**Step 3: Commit**

```
git add -A
git commit -m "feat: complete first-launch setup wizard"
```
