import AppKit
import Foundation
import UserNotifications

@main
enum NotificationSoundChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feiq-sound-checks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sounds = NotificationSoundService(soundsDirectory: root.appendingPathComponent("Sounds"))
        let defaults = SoundTestDefaults(suiteName: "feiq-sound-tests")!
        let settings = UserDefaultsAppSettingsService(defaults: defaults)
        precondition(settings.load().messageNotificationSound == .system)
        defaults.set("unsupported-old-value", forKey: "feiq.messageNotificationSound")
        precondition(settings.load().messageNotificationSound == .system)
        let silent = try sounds.notificationSound(for: .none)
        let system = try sounds.notificationSound(for: .system)
        precondition(silent == nil && system != nil && !FileManager.default.fileExists(atPath: root.path))
        for choice in MessageNotificationSound.allCases {
            var selection = settings.load()
            selection.messageNotificationSound = choice
            settings.save(selection)
            let reloaded = UserDefaultsAppSettingsService(defaults: defaults).load()
            precondition(reloaded == selection)
            let sound = try sounds.notificationSound(for: choice)
            let content = FeiQNotificationService.makeContent(from: "联系人", text: "收到消息", conversationID: "stable-peer-id", sound: sound)
            precondition(content.title == "联系人 发来消息" && content.body == "收到消息")
            precondition(content.userInfo["feiq.conversationID"] as? String == "stable-peer-id")
            precondition((content.sound == nil) == (choice == .none), "Silent notifications must keep banners but contain no sound")
            if let source = sounds.sourceURL(for: choice), let destination = try sounds.prepare(choice) {
                let expected = try Data(contentsOf: source)
                let installed = try Data(contentsOf: destination)
                precondition(expected == installed && destination.lastPathComponent == choice.installedFileName)
                guard let audio = NSSound(contentsOf: destination, byReference: false) else { preconditionFailure("Unreadable installed audio") }
                precondition(audio.duration > 0 && audio.duration < 30)
                try Data([0]).write(to: destination)
                let repaired = try sounds.prepare(choice)!
                let repairedData = try Data(contentsOf: repaired)
                precondition(repairedData == expected)
            }
        }
        let unavailable = NotificationSoundService(soundsDirectory: root.appendingPathComponent("unused"), sourceDirectory: root.appendingPathComponent("missing"))
        do {
            _ = try unavailable.notificationSound(for: .glass)
            preconditionFailure("Unavailable custom sounds must report a preparation failure")
        } catch {}
        let fallback = try unavailable.notificationSound(for: .system)
        precondition(fallback != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: sounds.soundsDirectory.path)
        precondition(files.count == 4 && files.allSatisfy { $0.hasPrefix("FeiQMac-") && $0.hasSuffix(".aiff") })
        print("Notification sound checks passed; no audio played and no notifications posted")
    }
}

private final class SoundTestDefaults: UserDefaults {
    private var stored: [String: Any] = [:]
    override func string(forKey defaultName: String) -> String? { stored[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { stored[defaultName] = value }
}
