import ArgumentParser

@main
struct Workforce: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workforce",
        abstract: "CLI companion for Workforce for Claude Code"
    )
}
