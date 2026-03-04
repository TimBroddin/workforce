import Foundation

struct EventLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: SocketMessage?
    let rawJSON: String
    let error: String?
}

@Observable
final class EventLog {
    private(set) var entries: [EventLogEntry] = []
    private let maxEntries = 1000

    func append(message: SocketMessage?, rawJSON: String, error: String? = nil) {
        let entry = EventLogEntry(
            timestamp: Date(),
            message: message,
            rawJSON: rawJSON,
            error: error
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
