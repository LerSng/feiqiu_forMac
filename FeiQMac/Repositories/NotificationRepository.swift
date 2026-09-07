//
//  NotificationRepository.swift
//  FeiQMac
//
//  系统通知业务仓储：隔离 UserNotifications 细节，并向上层提供会话跳转事件。
//

import Foundation

protocol NotificationRepository: AnyObject {
    var onNotificationSelected: ((String) -> Void)? { get set }

    func notifyIncomingMessage(
        text: String,
        from sender: String,
        conversationID: String
    )
}

final class DefaultNotificationRepository: NotificationRepository {
    private let notificationService: NotificationService

    var onNotificationSelected: ((String) -> Void)? {
        get { notificationService.onNotificationSelected }
        set { notificationService.onNotificationSelected = newValue }
    }

    init(notificationService: NotificationService) {
        self.notificationService = notificationService
    }

    func notifyIncomingMessage(
        text: String,
        from sender: String,
        conversationID: String
    ) {
        notificationService.notifyIncomingMessage(
            from: sender,
            text: text,
            conversationID: conversationID
        )
    }
}
