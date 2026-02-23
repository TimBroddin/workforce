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
}
