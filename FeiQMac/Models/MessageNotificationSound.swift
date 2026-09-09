import Foundation

enum MessageNotificationSound: String, CaseIterable, Identifiable, Sendable {
    case system
    case glass
    case ping
    case pop
    case tink
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统默认"
        case .glass: return "玻璃（Glass）"
        case .ping: return "清脆（Ping）"
        case .pop: return "轻响（Pop）"
        case .tink: return "轻铃（Tink）"
        case .none: return "无提示音"
        }
    }

    var sourceFileName: String? {
        switch self {
        case .system, .none: return nil
        case .glass: return "Glass.aiff"
        case .ping: return "Ping.aiff"
        case .pop: return "Pop.aiff"
        case .tink: return "Tink.aiff"
        }
    }

    var installedFileName: String? { sourceFileName.map { "FeiQMac-" + $0 } }
}
