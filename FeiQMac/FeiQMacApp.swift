import SwiftUI

@main
struct FeiQMacApp: App {
    @StateObject private var model: ChatViewModel

    init() {
        let notificationService = FeiQNotificationService()
        notificationService.requestAuthorization()

        let networkService = FeiQNetworkService()
        let historyService = SQLiteChatHistoryService.makeDefault()
        let attachmentStorageService = LocalChatAttachmentStorageService.makeDefault()
        let repository = DefaultChatRepository(
            eventSource: networkService,
            discoveryService: DefaultDiscoveryService(networkService: networkService),
            messageTransportService: DefaultMessageTransportService(networkService: networkService),
            fileTransferService: DefaultFileTransferService(networkService: networkService),
            inlineImageService: DefaultInlineImageService(networkService: networkService),
            groupProtocolService: DefaultGroupProtocolService(),
            messageRepository: DefaultMessageRepository(historyService: historyService),
            attachmentRepository: DefaultAttachmentRepository(storageService: attachmentStorageService),
            groupRepository: DefaultGroupRepository(historyService: historyService),
            sessionRepository: DefaultSessionRepository(historyService: historyService),
            notificationRepository: DefaultNotificationRepository(notificationService: notificationService),
            conversationSettingsRepository: DefaultConversationSettingsRepository(historyService: historyService)
        )
        let settingsRepository = DefaultAppSettingsRepository(
            service: UserDefaultsAppSettingsService()
        )

        _model = StateObject(
            wrappedValue: ChatViewModel(
                repository: repository,
                settingsRepository: settingsRepository
            )
        )
    }

    var body: some Scene {
        WindowGroup("") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 660)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentSize)
    }
}
