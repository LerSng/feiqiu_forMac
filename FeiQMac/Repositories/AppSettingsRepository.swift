import Foundation

protocol AppSettingsRepository: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

final class DefaultAppSettingsRepository: AppSettingsRepository {
    private let service: AppSettingsService

    init(service: AppSettingsService) {
        self.service = service
    }

    func load() -> AppSettings {
        service.load()
    }

    func save(_ settings: AppSettings) {
        service.save(settings)
    }
}
