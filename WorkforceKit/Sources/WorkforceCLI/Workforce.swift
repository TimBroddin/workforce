import ArgumentParser

@main
struct Workforce: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workforce",
        abstract: "CLI companion for Workforce for Claude Code",
        subcommands: [
            RunCommand.self,
            SessionStartCommand.self,
            PreToolUseCommand.self,
            PostToolUseCommand.self,
            PostToolUseFailureCommand.self,
            NotificationCommand.self,
            StopCommand.self,
            SessionEndCommand.self,
            SubagentStartCommand.self,
            SubagentStopCommand.self,
            InstallHooksCommand.self,
            UninstallHooksCommand.self,
        ]
    )
}
