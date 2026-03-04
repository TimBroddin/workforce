import Foundation

struct GitInfo {
    let branch: String
    let dirtyFileCount: Int
    let recentCommits: [GitCommit]
}

struct GitCommit: Identifiable {
    let id: String  // short hash
    let message: String
}

enum GitService {
    private static let gitPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func fetchInfo(for path: String) -> GitInfo? {
        guard let git = gitPath else { return nil }

        let headResult = runGit(git, args: ["rev-parse", "--abbrev-ref", "HEAD"], cwd: path)
        guard headResult.status == 0 else { return nil }
        let branch = headResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let statusResult = runGit(git, args: ["status", "--porcelain"], cwd: path)
        let dirtyCount = statusResult.status == 0
            ? statusResult.output.split(separator: "\n").count
            : 0

        let logResult = runGit(git, args: ["log", "--oneline", "-10", "--no-decorate"], cwd: path)
        let commits: [GitCommit] = logResult.status == 0
            ? logResult.output.split(separator: "\n").compactMap { line in
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2 else { return nil }
                return GitCommit(id: String(parts[0]), message: String(parts[1]))
            }
            : []

        return GitInfo(branch: branch, dirtyFileCount: dirtyCount, recentCommits: commits)
    }

    private static func runGit(_ gitPath: String, args: [String], cwd: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (1, "")
        }
    }
}
