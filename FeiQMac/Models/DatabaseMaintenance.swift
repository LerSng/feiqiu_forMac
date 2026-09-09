import Foundation

struct DatabaseStorageReport: Sendable {
    let databaseBytes: Int64
    let imageBytes: Int64
    let fileBytes: Int64
    let safetyBackupBytes: Int64
    let imageCount: Int
    let fileCount: Int
    let messageCount: Int
    let missingAttachmentCount: Int
    let unreferencedFileCount: Int
    let unreferencedBytes: Int64
    let skippedEntryCount: Int
    let scannedAt: Date

    var totalBytes: Int64 { databaseBytes + imageBytes + fileBytes + safetyBackupBytes }
}

struct AttachmentCleanupPolicy: Equatable, Sendable {
    var before: Date
    var includesUnreferencedFiles = false
}

struct MaintenanceFileRecord: Hashable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let modifiedAt: Date
    let identity: String
}

struct AttachmentCleanupPreview: Sendable {
    let policy: AttachmentCleanupPolicy
    let files: [MaintenanceFileRecord]
    let protectedFileCount: Int
    let affectedMessageCount: Int

    var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

struct AttachmentCleanupSummary: Sendable {
    let removedFileCount: Int
    let removedBytes: Int64
    let failures: [String]
}

struct DatabaseBackupManifest: Codable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let relativePath: String
        let byteCount: Int64
        let sha256: String
    }

    var version = 1
    let id: UUID
    let createdAt: Date
    let database: File
    let files: [File]
    let messageCount: Int
    let conversationCount: Int
    let missingAttachmentCount: Int
}

struct DatabaseBackupPreview: Sendable {
    let directory: URL
    let manifest: DatabaseBackupManifest
    let manifestHash: String

    var byteCount: Int64 { manifest.database.byteCount + manifest.files.reduce(0) { $0 + $1.byteCount } }
}

struct DatabaseRestoreSummary: Sendable {
    let messageCount: Int
    let attachmentCount: Int
    let safetyBackupURL: URL
}

enum DatabaseMaintenanceError: LocalizedError {
    case restartRequired
    case busy
    case pendingImages
    case unsentDraft
    case invalidDate
    case stalePreview
    case unsafePath(String)
    case changedFile(String)
    case invalidBackup(String)
    case database(String)

    var errorDescription: String? {
        switch self {
        case .restartRequired: return "数据库已恢复，请退出并重新打开应用后继续使用"
        case .busy: return "请先暂停通信并结束附件操作，再进行数据库维护"
        case .pendingImages: return "还有内嵌图片尚未接收完成，请等待接收完成或超时后再维护"
        case .unsentDraft: return "请先发送或移除未发送的草稿与附件，再覆盖恢复数据库"
        case .invalidDate: return "清理日期必须早于或等于今天，且只清理该日期之前的附件"
        case .stalePreview: return "文件或引用关系已变化，请重新预览后确认清理"
        case .unsafePath(let path): return "出于安全考虑，不能访问此目录、链接或特殊文件：\(path)"
        case .changedFile(let path): return "文件已变化或校验失败，操作未完成：\(path)"
        case .invalidBackup(let detail): return "备份无效：\(detail)"
        case .database(let detail): return "数据库维护失败：\(detail)"
        }
    }
}
