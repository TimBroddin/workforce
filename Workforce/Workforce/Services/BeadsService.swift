import Foundation

// MARK: - Models

struct BeadIssue: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let status: String
    let priority: Int?
    let issueType: String?
    let createdAt: Date?
    let createdBy: String?
    let updatedAt: Date?
    let closedAt: Date?
    let closeReason: String?
    let dependencies: [BeadDependency]?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority
        case issueType = "issue_type"
        case createdAt = "created_at"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case closeReason = "close_reason"
        case dependencies
    }

    var isOpen: Bool { status == "open" }

    var priorityLabel: String {
        switch priority {
        case 1: "High"
        case 2: "Medium"
        case 3: "Low"
        default: "—"
        }
    }

    var blockerCount: Int {
        dependencies?.filter { $0.type == "blocks" }.count ?? 0
    }
}

struct BeadDependency: Codable {
    let issueId: String
    let dependsOnId: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case issueId = "issue_id"
        case dependsOnId = "depends_on_id"
        case type
    }
}

// MARK: - Implementation Selection

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

// MARK: - Service

enum BeadsService {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) {
                return date
            }

            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(string)"
            )
        }
        return decoder
    }()

    /// Check if a .beads folder exists at the given path.
    static func hasBeadsFolder(at cwd: String) -> Bool {
        let beadsPath = (cwd as NSString).appendingPathComponent(".beads")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: beadsPath, isDirectory: &isDir) && isDir.boolValue
    }

    /// Load all issues from .beads/issues.jsonl at the given path.
    static func loadIssues(from cwd: String) -> [BeadIssue] {
        let issuesPath = (cwd as NSString).appendingPathComponent(".beads/issues.jsonl")
        guard let data = FileManager.default.contents(atPath: issuesPath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        return content
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(BeadIssue.self, from: lineData)
            }
    }

    /// Check if the `bv` command is available.
    static func isBeadsViewerInstalled() -> Bool {
        findBeadsViewer() != nil
    }

    /// Find the bv binary path.
    static func findBeadsViewer() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/bv",
            "/usr/local/bin/bv",
            "\(home)/.local/bin/bv",
            "\(home)/.cargo/bin/bv",
            "\(home)/.bun/bin/bv",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

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

    private static let beadsMarker = "<!-- workforce:beads -->"

    static func hasBeadsInstructions(at cwd: String) -> Bool {
        for filename in ["CLAUDE.md", "AGENTS.md"] {
            let path = (cwd as NSString).appendingPathComponent(filename)
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               content.contains(beadsMarker) {
                return true
            }
        }
        return false
    }

    static func appendBeadsInstructions(to cwd: String, claudeMd: Bool = true, agentsMd: Bool = true) {
        let impl = preferredImplementation()
        let cmd = impl.rawValue

        let block = """

        \(beadsMarker)
        ## Beads Issue Tracking

        Use `\(cmd)` for issue tracking in this project.
        - `\(cmd) list` — list open issues
        - `\(cmd) ready` — show unblocked issues ready for work
        - `\(cmd) create "title" -p <priority>` — create an issue
        - `\(cmd) close <id>` — close a completed issue
        - `\(cmd) show <id>` — view issue details
        \(beadsMarker)
        """

        var filenames: [String] = []
        if claudeMd { filenames.append("CLAUDE.md") }
        if agentsMd { filenames.append("AGENTS.md") }

        for filename in filenames {
            let path = (cwd as NSString).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: path) {
                if let content = try? String(contentsOfFile: path, encoding: .utf8),
                   content.contains(beadsMarker) {
                    continue
                }
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    if let data = ("\n" + block + "\n").data(using: .utf8) {
                        handle.write(data)
                    }
                    handle.closeFile()
                }
            } else {
                let content = block.trimmingCharacters(in: .newlines) + "\n"
                FileManager.default.createFile(atPath: path, contents: content.data(using: .utf8))
            }
        }
    }
}
