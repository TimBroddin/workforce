import AppKit
import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIfNeeded(agent: Agent, previousStatus: AgentStatus?) {
        guard agent.status == .waitingForInput || agent.status == .waitingForPermission else { return }
        guard previousStatus != agent.status else { return }

        let defaultBody = agent.status == .waitingForPermission
            ? "Needs permission to continue"
            : "Waiting for your input"

        // Fire notification immediately with default text, then update if summary arrives
        let identifier = "workforce-\(agent.sessionId)"
        sendNotification(identifier: identifier, title: agent.displayTitle, body: defaultBody, sessionId: agent.sessionId)

        // Try to enrich with transcript summary
        if let transcriptPath = agent.transcriptPath {
            // Read transcript and resolve backend on the main actor before entering the summarizer actor
            let messages = TranscriptReader.lastAssistantMessages(from: transcriptPath, count: 10)
            let backend = SummarizationBackend(
                rawValue: UserDefaults.standard.string(forKey: "summarizationBackend") ?? SummarizationBackend.systemDefault.rawValue
            ) ?? .systemDefault
            let title = agent.displayTitle
            let sessionId = agent.sessionId
            Task {
                if let summary = await TranscriptSummarizer.shared.summarize(transcriptPath: transcriptPath, messages: messages, backend: backend) {
                    await MainActor.run {
                        self.sendNotification(identifier: identifier, title: title, body: summary, sessionId: sessionId)
                    }
                }
            }
        }
    }

    private func sendNotification(identifier: String, title: String, body: String, sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        if let sessionId {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .focusAgent,
                    object: nil,
                    userInfo: ["sessionId": sessionId]
                )
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension Notification.Name {
    static let focusAgent = Notification.Name("focusAgent")
}
