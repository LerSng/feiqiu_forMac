import SwiftUI
import AppKit

struct HistoryArchiveView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var archiveModel: HistoryArchiveViewModel

    private var filtersDates: Binding<Bool> {
        Binding(
            get: { archiveModel.query.startDate != nil || archiveModel.query.endDate != nil },
            set: { enabled in
                var query = archiveModel.query
                query.startDate = enabled ? Date() : nil
                query.endDate = enabled ? Date() : nil
                archiveModel.query = query
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Label("聊天记录导出 / 导入", systemImage: "archivebox")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(FeiQIconButtonStyle(size: 30))
                    .disabled(archiveModel.isBusy)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭聊天记录导出 / 导入")
            }
            Picker("操作", selection: $archiveModel.mode) {
                ForEach(ChatHistoryArchiveMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .disabled(archiveModel.isBusy)

            if archiveModel.mode == .export { exportOptions } else { importOptions }

            if archiveModel.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(archiveModel.operationDescription)
                }
                .font(.callout)
            }
            if let report = archiveModel.report {
                Label(report, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                if let url = archiveModel.exportedURL {
                    Button("在 Finder 中显示导出文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            if let warning = archiveModel.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = archiveModel.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Text("导出文件与恢复数据均为明文，请妥善保管；迁移时请同时复制配套附件目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 760, height: 620)
        .background(FeiQUI.chatBackground)
        .tint(FeiQUI.accent)
        .interactiveDismissDisabled(archiveModel.isBusy)
    }

    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("导出范围") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("联系人 / 群聊", selection: $archiveModel.query.conversationID) {
                        Text("全部联系人与群聊").tag(String?.none)
                        ForEach(model.peers) { peer in
                            Text("\(peer.displayName) · \(peer.ipAddress)").tag(Optional(peer.id))
                        }
                        ForEach(model.groups) { group in
                            Text("群聊 · \(group.displayName)").tag(Optional(group.id))
                        }
                    }
                    TextField("关键词（可留空）", text: $archiveModel.query.text)
                        .textFieldStyle(.roundedBorder)
                    Picker("消息类型", selection: $archiveModel.query.kind) {
                        ForEach(ChatHistoryMessageKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 12) {
                        Toggle("日期范围", isOn: filtersDates).toggleStyle(.checkbox)
                        if filtersDates.wrappedValue {
                            DatePicker("开始", selection: Binding(
                                get: { archiveModel.query.startDate ?? Date() },
                                set: { archiveModel.query.startDate = $0 }
                            ), displayedComponents: .date)
                            DatePicker("结束", selection: Binding(
                                get: { archiveModel.query.endDate ?? Date() },
                                set: { archiveModel.query.endDate = $0 }
                            ), displayedComponents: .date)
                        } else {
                            Text("不限日期").foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                }
                .padding(10)
            }
            Picker("导出格式", selection: $archiveModel.format) {
                ForEach(ChatHistoryExportFormat.allCases) { format in Text(format.title).tag(format) }
            }
            .pickerStyle(.segmented)
            Text("导出筛选范围内的全部记录，不限于当前已加载的消息。三种格式都包含导入恢复数据，HTML 还可直接浏览图片。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("选择位置并导出…") { archiveModel.chooseExportDestination() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .disabled(archiveModel.isBusy)
    }

    private var importOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择飞秋 Mac 导出的 TXT、Markdown 或 HTML 文件。需要保留文件末尾的恢复数据，普通第三方文本不支持直接导入。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("选择记录文件…") { archiveModel.chooseImportFile() }
            if let preview = archiveModel.preview {
                GroupBox("导入预览") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(preview.sourceURL.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(preview.archive.messages.count) 条消息 · \(preview.archive.peers.count) 个联系人 · \(preview.archive.groups.count) 个群聊")
                        if preview.missingAttachmentCount > 0 {
                            Text("\(preview.missingAttachmentCount) 个附件文件缺失，仍可导入消息与附件元数据。")
                                .foregroundStyle(.orange)
                        }
                        Text("现有消息、联系人和群聊不会被覆盖，同一消息 ID 自动去重。新导入群聊仅恢复名称与历史，成员需手动添加，避免自动开启消息中继。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                Button("确认导入") { archiveModel.performImport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.archive.messages.isEmpty)
            }
        }
        .disabled(archiveModel.isBusy)
    }
}
