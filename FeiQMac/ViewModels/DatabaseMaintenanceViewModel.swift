import AppKit
import Combine
import Foundation

@MainActor
final class DatabaseMaintenanceViewModel: ObservableObject, Identifiable {
    typealias Authorize = (Bool, @escaping (Result<Set<String>, Error>) -> Void) -> Void

    let id = UUID()
    @Published var policy = AttachmentCleanupPolicy(before: Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -90, to: Date())!)) {
        didSet { if policy != oldValue { cleanupPreview = nil } }
    }
    @Published private(set) var statistics: DatabaseStorageReport?
    @Published private(set) var cleanupPreview: AttachmentCleanupPreview?
    @Published private(set) var backupPreview: DatabaseBackupPreview?
    @Published private(set) var isBusy = false
    @Published private(set) var requiresRestart = false
    @Published private(set) var operationDescription = ""
    @Published private(set) var report: String?
    @Published private(set) var warning: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastBackupURL: URL?

    let service: DatabaseMaintenanceService
    private let authorize: Authorize
    private let finish: (_ attachmentsChanged: Bool, _ requiresRestart: Bool) -> Void

    init(service: DatabaseMaintenanceService, authorize: @escaping Authorize,
         finish: @escaping (Bool, Bool) -> Void) {
        self.service = service
        self.authorize = authorize
        self.finish = finish
    }

    func loadStatistics() {
        read("正在统计数据库和附件大小…", operation: service.scan) { [weak self] in self?.statistics = $0 }
    }

    func previewCleanup() {
        let requestedPolicy = policy
        exclusive("正在检查旧附件和共享引用…", operation: { [service] protected, completion in
            service.previewCleanup(policy: requestedPolicy, protectedPaths: protected, completion: completion)
        }) { [weak self] preview in
            guard let self, self.policy == requestedPolicy else { return }
            self.cleanupPreview = preview
        }
    }

    func performCleanup() {
        guard let preview = cleanupPreview, preview.policy == policy else { return }
        exclusive("正在清理已确认的旧附件…", attachmentsChanged: true, operation: { [service] protected, completion in
            service.cleanup(preview, protectedPaths: protected, completion: completion)
        }) { [weak self] summary in
            guard let self else { return }
            self.cleanupPreview = nil
            self.report = "已清理 \(summary.removedFileCount) 个附件，移除文件大小 \(Self.byteCount(summary.removedBytes))。聊天文字和附件元信息保留。"
            if !summary.failures.isEmpty {
                self.warning = "\(summary.failures.count) 个文件未清理：\n" + summary.failures.prefix(8).joined(separator: "\n")
            }
            self.loadStatistics()
        }
    }

    func chooseBackupDestination() {
        guard !isBusy, !requiresRestart else { return }
        let panel = NSOpenPanel()
        panel.title = "选择备份保存文件夹"
        panel.message = "将创建独立的 .feiqbackup 文件夹，包含聊天数据库、会话设置和已关联附件。请选择应用数据目录以外的位置。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        createBackup(in: directory)
    }

    func createBackup(in directory: URL) {
        exclusive("正在创建一致的数据库快照并备份附件…", operation: { [service] _, completion in
            service.createBackup(in: directory, completion: completion)
        }) { [weak self] result in
            self?.lastBackupURL = result.directory
            self?.report = "已备份 \(result.manifest.messageCount) 条消息、\(result.manifest.conversationCount) 个会话和 \(result.manifest.files.count) 个附件。"
            if result.manifest.missingAttachmentCount > 0 {
                self?.warning = "\(result.manifest.missingAttachmentCount) 个附件缺失或不在应用管理目录，备份仅保留其元信息。"
            }
        }
    }

    func chooseRestoreSource() {
        guard !isBusy, !requiresRestart else { return }
        let panel = NSOpenPanel()
        panel.title = "选择飞秋数据库备份"
        panel.message = "选择完整的 .feiqbackup 文件夹，不要只选其中的 SQLite 文件。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        inspectBackup(at: directory)
    }

    func inspectBackup(at directory: URL) {
        guard !isBusy else { return }
        backupPreview = nil
        read("正在校验备份数据库与全部附件…", operation: { [service] completion in
            service.inspectBackup(at: directory, completion: completion)
        }) { [weak self] in self?.backupPreview = $0 }
    }

    func performRestore() {
        guard let preview = backupPreview else { return }
        exclusive("正在校验、创建安全备份并恢复数据库…", restoring: true, operation: { [service] _, completion in
            service.restoreBackup(preview, completion: completion)
        }) { [weak self] result in
            self?.backupPreview = nil
            self?.lastBackupURL = result.safetyBackupURL
            self?.report = "已恢复 \(result.messageCount) 条消息和 \(result.attachmentCount) 个附件。请退出并重新打开应用。"
            self?.warning = "恢复前的数据已自动备份。旧附件未被删除；重新打开后可按需清理无引用文件。"
        }
    }

    private func read<Value>(_ description: String,
                             operation: (@escaping (Result<Value, Error>) -> Void) -> Void,
                             success: @escaping (Value) -> Void) {
        guard !isBusy, !requiresRestart else { return }
        isBusy = true
        operationDescription = description
        errorMessage = nil
        operation { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let value): success(value)
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func exclusive<Value>(_ description: String, restoring: Bool = false, attachmentsChanged: Bool = false,
                                  operation: @escaping (Set<String>, @escaping (Result<Value, Error>) -> Void) -> Void,
                                  success: @escaping (Value) -> Void) {
        guard !isBusy, !requiresRestart else { return }
        isBusy = true
        operationDescription = description
        report = nil
        warning = nil
        errorMessage = nil
        authorize(restoring) { [self] authorization in
            switch authorization {
            case .failure(let error):
                isBusy = false
                errorMessage = error.localizedDescription
            case .success(let protected):
                operation(protected) { [self] result in
                    DispatchQueue.main.async { [self] in
                        isBusy = false
                        switch result {
                        case .success(let value):
                            requiresRestart = restoring
                            finish(attachmentsChanged, restoring)
                            success(value)
                        case .failure(let error):
                            finish(false, false)
                            errorMessage = error.localizedDescription
                            if case DatabaseMaintenanceError.stalePreview = error { cleanupPreview = nil }
                        }
                    }
                }
            }
        }
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
