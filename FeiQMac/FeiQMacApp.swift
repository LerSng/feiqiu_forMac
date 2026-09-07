import SwiftUI

@main
struct FeiQMacApp: App {
    @StateObject private var model: ChatViewModel

    init() {
        let notificationService = FeiQNotificationService()
        notificationService.requestAuthorization()

        let repository = DefaultChatRepository(
            networkService: FeiQNetworkService(),
            historyService: SQLiteChatHistoryService.makeDefault(),
            attachmentStorageService: LocalChatAttachmentStorageService.makeDefault(),
            notificationService: notificationService
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
