import ArgumentParser
import Foundation
import WorkforceKit

@main
struct Workforce: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workforce",
        abstract: "CLI companion for Workforce",
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
        ],
        defaultSubcommand: RunCommand.self
    )
}
