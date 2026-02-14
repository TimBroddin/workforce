import Foundation
import UserNotifications
import AppKit

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

        if let bundleId = agent.hostBundleId,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = agent.name
        content.body = agent.status == .waitingForPermission ? "Needs permission to continue" : "Waiting for your input"
        content.sound = .default
        content.userInfo = ["sessionId": agent.sessionId]

        let request = UNNotificationRequest(
            identifier: "workforce-\(agent.sessionId)",
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
