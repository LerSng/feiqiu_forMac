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
        WindowGroup("飞秋 Mac") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
    }
}
