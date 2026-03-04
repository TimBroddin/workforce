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

        // Title: Claude's message if available, otherwise agent display title
        let notificationTitle = agent.notificationMessage ?? agent.displayTitle
        let identifier = "agenthub-\(agent.sessionId)"
        let agentTitle = agent.displayTitle
        let sessionId = agent.sessionId

        // Wait for summary, then send a single notification
        let backend = SummarizationBackend(
            rawValue: UserDefaults.standard.string(forKey: "summarizationBackend") ?? SummarizationBackend.systemDefault.rawValue
        ) ?? .systemDefault
        if backend != .disabled, let transcriptPath = agent.transcriptPath {
            let messages = TranscriptReader.lastAssistantMessages(from: transcriptPath, count: 10)
            Task {
                let summary = await TranscriptSummarizer.shared.summarize(transcriptPath: transcriptPath, messages: messages, backend: backend)
                await MainActor.run {
                    self.sendNotification(
                        identifier: identifier,
                        title: notificationTitle,
                        body: summary ?? agentTitle,
                        sessionId: sessionId
                    )
                }
            }
        } else {
            sendNotification(identifier: identifier, title: notificationTitle, body: agentTitle, sessionId: sessionId)
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
