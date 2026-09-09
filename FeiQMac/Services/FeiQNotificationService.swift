import Foundation
import UserNotifications

protocol NotificationService: AnyObject {
    var onNotificationSelected: ((String) -> Void)? { get set }

    func requestAuthorization()
    func notifyIncomingMessage(
        from sender: String,
        text: String,
        conversationID: String
    )
}

final class FeiQNotificationService: NSObject, NotificationService, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let settingsService: AppSettingsService
    private let soundService: NotificationSoundService

    var onNotificationSelected: ((String) -> Void)?

    init(settingsService: AppSettingsService = UserDefaultsAppSettingsService(), soundService: NotificationSoundService = NotificationSoundService()) {
        self.settingsService = settingsService
        self.soundService = soundService
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIncomingMessage(
        from sender: String,
        text: String,
        conversationID: String
    ) {
        let sound: UNNotificationSound?
        do { sound = try soundService.notificationSound(for: settingsService.load().messageNotificationSound) }
        catch { sound = .default }
        let content = Self.makeContent(from: sender, text: text, conversationID: conversationID, sound: sound)
        let request = UNNotificationRequest(
            identifier: "feiq.incoming.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    static func makeContent(from sender: String, text: String, conversationID: String, sound: UNNotificationSound?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let displaySender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = displaySender.isEmpty ? "收到新消息" : "\(displaySender) 发来消息"
        content.body = Self.previewText(text)
        content.sound = sound
        content.userInfo = [
            "feiq.conversationID": conversationID,
            // Keep the old key so notifications created by older builds can
            // still be opened after the app is upgraded.
            "feiq.peerID": conversationID
        ]

        return content
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let conversationID = (response.notification.request.content.userInfo["feiq.conversationID"]
                ?? response.notification.request.content.userInfo["feiq.peerID"]) as? String,
              !conversationID.isEmpty else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onNotificationSelected?(conversationID)
        }
    }

    private static func previewText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 120 else { return normalized }
        return String(normalized.prefix(120)) + "…"
    }
}
