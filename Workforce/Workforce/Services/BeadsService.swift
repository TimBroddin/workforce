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

    var isOpen: Bool { status == "open" || status == "in_progress" }
    var isInProgress: Bool { status == "in_progress" }

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

        // Read pipe data asynchronously to avoid deadlock when output exceeds
        // the pipe buffer. The child would block on write while waitUntilExit
        // waits for the child — classic deadlock.
        var stdoutData = Data()
        var stderrData = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutData.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrData.append(handle.availableData)
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return CLIResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        // Drain remaining data and clean up handlers
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
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

    static func startProgress(id: String, cwd: String) -> CLIResult {
        runCLI(arguments: ["update", id, "-s", "in_progress"], cwd: cwd)
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

    private static let beadsMarkerPrefix = "<!-- workforce:beads"
    private static let beadsMarkerVersion = 2
    private static var beadsMarker: String { "<!-- workforce:beads:v\(beadsMarkerVersion) -->" }

    /// Returns the version of the beads instructions in a file, or nil if not present.
    private static func beadsInstructionVersion(in content: String) -> Int? {
        // Match versioned marker: <!-- workforce:beads:v2 -->
        if let range = content.range(of: #"<!-- workforce:beads:v(\d+) -->"#, options: .regularExpression) {
            let match = content[range]
            if let numRange = match.range(of: #"\d+"#, options: .regularExpression) {
                return Int(match[numRange])
            }
        }
        // Match legacy unversioned marker: <!-- workforce:beads -->
        if content.contains("<!-- workforce:beads -->") {
            return 1
        }
        return nil
    }

    /// Replaces the beads instructions block (between markers) with the current version.
    private static func replaceBeadsBlock(in content: String, with block: String) -> String {
        // Match from any versioned or unversioned opening marker to closing marker
        let pattern = #"<!-- workforce:beads(?::v\d+)? -->[\s\S]*?<!-- workforce:beads(?::v\d+)? -->"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: block.trimmingCharacters(in: .newlines))
    }

    static func hasBeadsInstructions(at cwd: String) -> Bool {
        for filename in ["CLAUDE.md", "AGENTS.md"] {
            let path = (cwd as NSString).appendingPathComponent(filename)
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               beadsInstructionVersion(in: content) != nil {
                return true
            }
        }
        return false
    }

    /// Returns true if any file has outdated beads instructions.
    static func hasOutdatedBeadsInstructions(at cwd: String) -> Bool {
        for filename in ["CLAUDE.md", "AGENTS.md"] {
            let path = (cwd as NSString).appendingPathComponent(filename)
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let version = beadsInstructionVersion(in: content),
               version < beadsMarkerVersion {
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

        **IMPORTANT: Before starting ANY work, create beads issues with `\(cmd) create` to track the task. Always check
        `\(cmd) list` and `\(cmd) ready` first to see if there are existing issues to work on.**

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
                if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    if let version = beadsInstructionVersion(in: content) {
                        if version >= beadsMarkerVersion { continue }
                        // Replace outdated block
                        let updated = replaceBeadsBlock(in: content, with: block.trimmingCharacters(in: .newlines))
                        try? updated.write(toFile: path, atomically: true, encoding: .utf8)
                        continue
                    }
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
