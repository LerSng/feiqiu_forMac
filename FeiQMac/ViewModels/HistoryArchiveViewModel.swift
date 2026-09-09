import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class HistoryArchiveViewModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var mode: ChatHistoryArchiveMode
    @Published var query: ChatHistorySearchQuery
    @Published var format: ChatHistoryExportFormat = .txt
    @Published private(set) var isBusy = false
    @Published private(set) var operationDescription = ""
    @Published private(set) var preview: ChatHistoryImportPreview?
    @Published private(set) var report: String?
    @Published private(set) var warning: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var exportedURL: URL?

    private let repository: ChatRepository
    private let didImport: () -> Void

    init(mode: ChatHistoryArchiveMode, query: ChatHistorySearchQuery, repository: ChatRepository, didImport: @escaping () -> Void) {
        self.mode = mode
        self.query = query
        self.repository = repository
        self.didImport = didImport
    }

    func chooseExportDestination() {
        guard !isBusy else { return }
        do { _ = try query.dateBounds() }
        catch { errorMessage = error.localizedDescription; return }
        let panel = NSSavePanel()
        panel.title = "导出聊天记录"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "飞秋聊天记录-\(formatter.string(from: Date())).\(format.fileExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        export(to: destination)
    }

    func export(to destination: URL) {
        guard !isBusy else { return }
        beginOperation("正在读取记录并导出附件…")
        exportedURL = nil
        repository.exportHistory(matching: query, format: format, to: destination) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let summary):
                    self.exportedURL = summary.fileURL
                    self.report = "已导出 \(summary.messageCount) 条消息和 \(summary.attachmentCount) 个附件文件。"
                    if summary.missingAttachmentCount > 0 {
                        self.warning = "\(summary.missingAttachmentCount) 个附件未找到，已保留其名称和元数据。"
                    }
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func chooseImportFile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择飞秋 Mac 导出的记录"
        panel.allowedContentTypes = [.plainText, .html, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        inspectImport(from: source)
    }

    func inspectImport(from source: URL) {
        guard !isBusy else { return }
        beginOperation("正在检查记录文件与附件…")
        preview = nil
        repository.inspectHistoryImport(from: source) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let preview): self.preview = preview
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func performImport() {
        guard !isBusy, let preview else { return }
        beginOperation("正在恢复附件并导入聊天记录…")
        repository.importHistory(preview) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let summary):
                    self.report = "已导入 \(summary.importedMessageCount) 条消息，跳过 \(summary.skippedMessageCount) 条重复消息；新增 \(summary.addedPeerCount) 个联系人、\(summary.addedGroupCount) 个群聊。"
                    var warnings: [String] = []
                    if summary.missingAttachmentCount > 0 {
                        warnings.append("\(summary.missingAttachmentCount) 个附件缺失，已保留历史元数据。")
                    }
                    if let cleanup = summary.cleanupWarning { warnings.append(cleanup) }
                    self.warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
                    self.preview = nil
                    self.didImport()
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func beginOperation(_ description: String) {
        isBusy = true
        operationDescription = description
        report = nil
        warning = nil
        errorMessage = nil
    }
}
