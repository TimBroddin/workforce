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
