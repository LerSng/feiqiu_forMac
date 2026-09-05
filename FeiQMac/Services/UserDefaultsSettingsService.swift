import Foundation

protocol AppSettingsService: AnyObject {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

final class UserDefaultsAppSettingsService: AppSettingsService {
    private enum Key {
        static let nickname = "feiq.nickname"
        static let hostName = "feiq.hostname"
        static let groupName = "feiq.group"
        static let chatLoadAnimationMode = "feiq.chatLoadAnimationMode"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        AppSettings(
            identity: FeiQIdentity(
                nickname: defaults.string(forKey: Key.nickname) ?? "飞秋 Mac",
                hostName: defaults.string(forKey: Key.hostName) ?? Self.defaultHostName,
                groupName: defaults.string(forKey: Key.groupName) ?? ""
            ),
            chatLoadAnimationMode: ChatLoadAnimationMode(
                rawValue: defaults.string(forKey: Key.chatLoadAnimationMode) ?? ""
            ) ?? .converge
        )
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.identity.nickname, forKey: Key.nickname)
        defaults.set(settings.identity.hostName, forKey: Key.hostName)
        defaults.set(settings.identity.groupName, forKey: Key.groupName)
        defaults.set(
            settings.chatLoadAnimationMode.rawValue,
            forKey: Key.chatLoadAnimationMode
        )
    }

    private static var defaultHostName: String {
        if let localizedName = Host.current().localizedName,
           !localizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localizedName
        }
        return ProcessInfo.processInfo.hostName
    }
}
