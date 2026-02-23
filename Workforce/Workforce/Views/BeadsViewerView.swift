import SwiftUI

// MARK: - Beads Viewer View

struct BeadsViewerView: View {
    let cwd: String
    @State private var issues: [BeadIssue] = []
    @State private var filter: IssueFilter = .all
    @State private var viewMode: ViewMode = .native
    @State private var bvInstalled = false
    @State private var expandedIssueId: String?
    @State private var isInstalling = false

    enum IssueFilter: String, CaseIterable {
        case all = "All"
        case open = "Open"
        case closed = "Closed"
    }

    enum ViewMode {
        case native
        case terminal
        case installing
    }

    private var filteredIssues: [BeadIssue] {
        let filtered: [BeadIssue]
        switch filter {
        case .all: filtered = issues
        case .open: filtered = issues.filter { $0.isOpen }
        case .closed: filtered = issues.filter { !$0.isOpen }
        }
        return filtered.sorted { lhs, rhs in
            // Open before closed
            if lhs.isOpen != rhs.isOpen { return lhs.isOpen }
            // Higher priority (lower number) first
            let lp = lhs.priority ?? 99
            let rp = rhs.priority ?? 99
            if lp != rp { return lp < rp }
            return lhs.title < rhs.title
        }
    }

    private var openCount: Int { issues.filter { $0.isOpen }.count }
    private var closedCount: Int { issues.filter { !$0.isOpen }.count }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            switch viewMode {
            case .native:
                nativeListView
            case .terminal:
                terminalView
            case .installing:
                installView
            }
        }
        .task { reload() }
        .task {
            // Periodically refresh issues
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                reload()
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Filter pills
            ForEach(IssueFilter.allCases, id: \.self) { f in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { filter = f }
                } label: {
                    HStack(spacing: 3) {
                        Text(f.rawValue)
                            .font(.caption.weight(.medium))
                        if f == .open {
                            Text("\(openCount)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.orange))
                        } else if f == .closed {
                            Text("\(closedCount)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.green))
                        }
                    }
                    .foregroundStyle(filter == f ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        filter == f
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if viewMode == .terminal {
                Button {
                    withAnimation { viewMode = .native }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                            .font(.caption2)
                        Text("List View")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    if bvInstalled {
                        withAnimation { viewMode = .terminal }
                    } else {
                        withAnimation { viewMode = .installing }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.caption2)
                        Text("Beads Viewer")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(bvInstalled ? "Open graph-aware TUI viewer" : "Install Beads Viewer (bv)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Native List View

    private var nativeListView: some View {
        Group {
            if filteredIssues.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text(filter == .all ? "No Issues" : "No \(filter.rawValue) Issues")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Issues tracked in .beads/ will appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredIssues) { issue in
                            issueRow(issue)
                            if issue.id != filteredIssues.last?.id {
                                Divider()
                                    .padding(.leading, 32)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func issueRow(_ issue: BeadIssue) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(alignment: .top, spacing: 8) {
                // Status indicator
                Image(systemName: issue.isOpen ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(issue.isOpen ? .orange : .green)
                    .frame(width: 20)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(issue.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)

                        Spacer()

                        // Priority badge
                        if let priority = issue.priority, priority <= 3 {
                            Text(issue.priorityLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(priorityForeground(priority))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(priorityBackground(priority))
                                )
                        }
                    }

                    HStack(spacing: 6) {
                        // Issue ID
                        Text(issue.id)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        // Type badge
                        if let type = issue.issueType {
                            Text(type)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                        }

                        // Dependency count
                        if issue.blockerCount > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "link")
                                    .font(.system(size: 8))
                                Text("\(issue.blockerCount)")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        // Time
                        if let date = issue.updatedAt ?? issue.createdAt {
                            Text(relativeTime(date))
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedIssueId = expandedIssueId == issue.id ? nil : issue.id
                }
            }

            // Expanded detail
            if expandedIssueId == issue.id {
                issueDetail(issue)
            }
        }
        .background(
            expandedIssueId == issue.id
                ? Color.accentColor.opacity(0.04)
                : Color.clear
        )
    }

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
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Terminal View (bv)

    private var terminalView: some View {
        Group {
            if let bvPath = BeadsService.findBeadsViewer() {
                CommandTerminalRepresentable(
                    command: bvPath,
                    arguments: [],
                    workingDirectory: cwd
                )
                .id("bv-\(cwd)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                installView
            }
        }
    }

    // MARK: - Install View

    private var installView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "arrow.down.app")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Beads Viewer Not Installed")
                    .font(.headline)
                Text("bv is a graph-aware TUI for visualizing beads issues with dependency analysis, PageRank metrics, and interactive navigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if isInstalling {
                ProgressView()
                    .controlSize(.small)
                Text("Installing via Homebrew...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    Button {
                        installViaHomebrew()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "mug")
                                .font(.caption)
                            Text("Install via Homebrew")
                        }
                        .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("brew install dicklesworthstone/tap/bv")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)

                    Divider()
                        .frame(maxWidth: 200)

                    Button {
                        installViaScript()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.caption)
                            Text("Install via Script")
                        }
                        .frame(minWidth: 180)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        withAnimation { viewMode = .native }
                    } label: {
                        Text("Back to List")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Helpers

    private func reload() {
        issues = BeadsService.loadIssues(from: cwd)
        bvInstalled = BeadsService.isBeadsViewerInstalled()
    }

    private func installViaHomebrew() {
        isInstalling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let brew = brewPath else {
                DispatchQueue.main.async {
                    isInstalling = false
                }
                return
            }
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", "dicklesworthstone/tap/bv"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

            DispatchQueue.main.async {
                isInstalling = false
                bvInstalled = BeadsService.isBeadsViewerInstalled()
                if bvInstalled {
                    viewMode = .terminal
                }
            }
        }
    }

    private func installViaScript() {
        isInstalling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                "-c",
                "curl -fsSL 'https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh' | bash",
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

            DispatchQueue.main.async {
                isInstalling = false
                bvInstalled = BeadsService.isBeadsViewerInstalled()
                if bvInstalled {
                    viewMode = .terminal
                }
            }
        }
    }

    private func priorityForeground(_ priority: Int) -> Color {
        switch priority {
        case 1: .red
        case 2: .orange
        case 3: .blue
        default: .secondary
        }
    }

    private func priorityBackground(_ priority: Int) -> Color {
        switch priority {
        case 1: .red.opacity(0.12)
        case 2: .orange.opacity(0.12)
        case 3: .blue.opacity(0.12)
        default: .gray.opacity(0.12)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30 { return "\(days)d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
