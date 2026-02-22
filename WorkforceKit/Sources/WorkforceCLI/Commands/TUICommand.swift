import ArgumentParser
import Foundation
import WorkforceKit
@preconcurrency import Darwin.ncurses

// MARK: - ncurses helpers

// A_BOLD and similar attribute macros use NCURSES_BITS() which Swift cannot import.
// Redefine them manually using the same bit layout: NCURSES_BITS(mask, shift) = mask << (shift + 8)
private let ATTR_BOLD: Int32 = 1 << (13 + 8)

struct TUICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Interactive session picker"
    )

    func run() throws {
        var agents = fetchAgents()
        if agents.isEmpty {
            print("No active sessions.")
            return
        }

        setlocale(LC_ALL, "")
        initscr()
        defer { endwin() }
        cbreak()
        noecho()
        curs_set(0)
        keypad(stdscr, true)
        start_color()
        timeout(3000)

        init_pair(1, Int16(COLOR_GREEN), Int16(COLOR_BLACK))
        init_pair(2, Int16(COLOR_CYAN), Int16(COLOR_BLACK))
        init_pair(3, Int16(COLOR_WHITE), Int16(COLOR_BLACK))
        init_pair(4, Int16(COLOR_RED), Int16(COLOR_BLACK))
        init_pair(5, Int16(COLOR_BLACK), Int16(COLOR_WHITE))

        var selectedIndex = 0
        var shouldQuit = false

        while !shouldQuit {
            erase()

            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let maxY = Int(getmaxy(stdscr))
            let maxX = Int(getmaxx(stdscr))

            attron(ATTR_BOLD)
            mvaddstr(0, 1, " Workforce Sessions (\(agents.count))")
            attroff(ATTR_BOLD)
            mvhline(1, 0, chtype(Character("-").asciiValue!), Int32(maxX))

            let headerY: Int32 = 2
            attron(ATTR_BOLD)
            mvaddstr(headerY, 1, "  SESSION              AGENT      STATUS     CWD")
            attroff(ATTR_BOLD)

            let startY: Int32 = 3
            let maxRows = maxY - 5

            for (i, agent) in agents.enumerated() {
                guard i < maxRows else { break }
                let y = startY + Int32(i)
                let isSelected = i == selectedIndex

                if isSelected {
                    attron(COLOR_PAIR(5))
                }

                let (dot, colorPair) = statusIndicator(agent.status)
                if !isSelected {
                    attron(COLOR_PAIR(Int32(colorPair)))
                }
                mvaddstr(y, 1, dot)
                if !isSelected {
                    attroff(COLOR_PAIR(Int32(colorPair)))
                }

                let shortCwd = agent.cwd.hasPrefix(home)
                    ? "~" + agent.cwd.dropFirst(home.count)
                    : agent.cwd
                let truncCwd = String(shortCwd.prefix(max(0, maxX - 50)))

                let row = " " + agent.sessionId.padding(toLength: 20, withPad: " ", startingAt: 0)
                    + " " + agent.agentType.padding(toLength: 10, withPad: " ", startingAt: 0)
                    + " " + agent.status.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
                    + " " + truncCwd

                mvaddstr(y, 2, row)

                if isSelected {
                    // Pad rest of line for full highlight
                    let currentLen = 3 + row.count
                    if currentLen < maxX {
                        let padding = String(repeating: " ", count: maxX - currentLen)
                        addstr(padding)
                    }
                    attroff(COLOR_PAIR(5))
                }
            }

            let footerY = Int32(maxY - 1)
            mvhline(footerY - 1, 0, chtype(Character("-").asciiValue!), Int32(maxX))
            mvaddstr(footerY, 1, " ↑↓ navigate  ⏎ attach  q quit  r refresh")

            refresh()

            let ch = getch()
            switch ch {
            case Int32(Character("q").asciiValue!), Int32(Character("Q").asciiValue!):
                shouldQuit = true

            case Int32(Character("r").asciiValue!), Int32(Character("R").asciiValue!):
                agents = fetchAgents()
                if selectedIndex >= agents.count {
                    selectedIndex = max(0, agents.count - 1)
                }

            case KEY_UP:
                if selectedIndex > 0 { selectedIndex -= 1 }

            case KEY_DOWN:
                if selectedIndex < agents.count - 1 { selectedIndex += 1 }

            case 10, KEY_ENTER:
                guard !agents.isEmpty else { break }
                let agent = agents[selectedIndex]
                let tmuxSession = agent.tmuxSession ?? agent.sessionId
                endwin()
                try TmuxClient.attach(session: tmuxSession)
                return

            case ERR:
                agents = fetchAgents()
                if agents.isEmpty {
                    endwin()
                    print("No active sessions.")
                    return
                }
                if selectedIndex >= agents.count {
                    selectedIndex = max(0, agents.count - 1)
                }

            default:
                break
            }
        }
    }

    private func fetchAgents() -> [Agent] {
        APIClient.fetchAgents() ?? TmuxClient.discoverAgents()
    }

    private func statusIndicator(_ status: AgentStatus) -> (String, Int) {
        switch status {
        case .active:               return ("●", 1)
        case .waitingForInput:      return ("◉", 2)
        case .waitingForPermission: return ("◉", 2)
        case .idle:                 return ("○", 3)
        case .stopped:              return ("○", 4)
        }
    }
}
