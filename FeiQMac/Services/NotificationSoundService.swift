import Foundation
import UserNotifications

final class NotificationSoundService {
    let soundsDirectory: URL
    private let sourceDirectory: URL
    private let lock = NSLock()

    init(soundsDirectory: URL? = nil, sourceDirectory: URL = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)) {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        self.soundsDirectory = soundsDirectory ?? library.appendingPathComponent("Sounds", isDirectory: true)
        self.sourceDirectory = sourceDirectory
    }

    func sourceURL(for sound: MessageNotificationSound) -> URL? {
        sound.sourceFileName.map { sourceDirectory.appendingPathComponent($0) }
    }

    @discardableResult
    func prepare(_ sound: MessageNotificationSound) throws -> URL? {
        guard let source = sourceURL(for: sound), let name = sound.installedFileName else { return nil }
        return try lock.withLock {
            let data = try Data(contentsOf: source)
            guard !data.isEmpty, data.count <= 5 * 1024 * 1024 else { throw NotificationSoundError.unavailable }
            try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
            let destination = soundsDirectory.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            if attributes?[.type] as? FileAttributeType == .typeRegular,
               (attributes?[.size] as? NSNumber)?.intValue == data.count,
               (try? Data(contentsOf: destination)) == data { return destination }
            try data.write(to: destination, options: .atomic)
            return destination
        }
    }

    func notificationSound(for sound: MessageNotificationSound) throws -> UNNotificationSound? {
        switch sound {
        case .system: return .default
        case .none: return nil
        default:
            guard let url = try prepare(sound) else { throw NotificationSoundError.unavailable }
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: url.lastPathComponent))
        }
    }
}

enum NotificationSoundError: LocalizedError {
    case unavailable
    case previewFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "所选提示音不可用，请选择其他提示音或系统默认"
        case .previewFailed: return "无法试听所选提示音，请检查系统音量或选择其他提示音"
        }
    }
}
