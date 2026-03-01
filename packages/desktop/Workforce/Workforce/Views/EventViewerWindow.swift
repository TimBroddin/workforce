import SwiftUI

struct EventViewerWindow: View {
    let eventLog: EventLog
    let store: AgentStore
    @State private var selectedEntryId: UUID?
    @State private var typeFilter: SocketMessageType?
    @State private var popoverEntryId: UUID?

    private var filteredEntries: [EventLogEntry] {
        guard let filter = typeFilter else { return eventLog.entries }
        return eventLog.entries.filter { $0.message?.type == filter }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            eventList
            Divider()
            footer
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Picker("Filter", selection: $typeFilter) {
                Text("All Types").tag(nil as SocketMessageType?)
                Divider()
                ForEach(SocketMessageType.allCases, id: \.self) { type in
                    Label(type.rawValue, systemImage: "circle.fill")
                        .foregroundStyle(type.badgeColor)
                        .tag(type as SocketMessageType?)
                }
            }
            .frame(width: 180)

            Spacer()

            Button("Clear") {
                eventLog.clear()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Event List

    private var eventList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries, selection: $selectedEntryId) { entry in
                eventRow(entry)
                    .id(entry.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            .listStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .onChange(of: eventLog.entries.count) {
                if let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func eventRow(_ entry: EventLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))

                if let message = entry.message {
                    Text(message.type.rawValue)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(message.type.badgeColor.opacity(0.2))
                        .foregroundStyle(message.type.badgeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    HStack(spacing: 3) {
                        if store.agents[message.sessionId] != nil {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                        }
                        Text(String(message.sessionId.prefix(12)))
                    }
                        .foregroundStyle(.secondary)
                        .font(.system(.caption, design: .monospaced))
                        .onTapGesture {
                            popoverEntryId = popoverEntryId == entry.id ? nil : entry.id
                        }
                        .popover(isPresented: Binding(
                            get: { popoverEntryId == entry.id },
                            set: { if !$0 { popoverEntryId = nil } }
                        )) {
                            agentPopover(for: message)
                        }

                    Text(entrySummary(message))
                        .foregroundStyle(.primary)
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text("ERROR")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.2))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    if let error = entry.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }

            if selectedEntryId == entry.id {
                ScrollView {
                    Text(prettyJSON(entry.rawJSON))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Color(nsColor: .textColor))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .frame(maxHeight: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func agentPopover(for message: SocketMessage) -> some View {
        let agent = store.agents[message.sessionId]
        let name = agent?.name ?? message.name ?? message.sessionId
        return VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.headline)
            Text(message.cwd)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func entrySummary(_ message: SocketMessage) -> String {
        switch message.type {
        case .register:
            return message.name ?? ""
        case .updateTool:
            return message.toolName ?? ""
        case .updateStatus:
            return message.status?.rawValue ?? ""
        case .notification:
            return message.notificationType ?? message.status?.rawValue ?? ""
        case .subagentStart, .subagentStop:
            return message.agentType ?? ""
        case .deregister:
            return ""
        case .updateTokens:
            return ""
        }
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return str
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(filteredEntries.count) event\(filteredEntries.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
