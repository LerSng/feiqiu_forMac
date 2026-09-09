import AppKit
import SwiftUI

struct DatabaseMaintenanceView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var maintenance: DatabaseMaintenanceViewModel
    @State private var confirmsCleanup = false
    @State private var confirmsRestore = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if maintenance.requiresRestart {
                        Label("恢复完成。为防止旧缓存写回，通信与数据库写入已暂停，请退出并重新打开应用。", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    } else {
                        statistics
                        availability
                        cleanup
                        backup
                    }
                    messages
                }
                .padding(24)
            }
            .hiddenScrollIndicators()
            Divider()
            HStack {
                if maintenance.isBusy {
                    ProgressView().controlSize(.small)
                    Text(maintenance.operationDescription).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("备份未加密，请保存在可信的位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if maintenance.requiresRestart {
                    Button("退出应用") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("关闭") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(maintenance.isBusy)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 670, idealHeight: 760)
        .background(FeiQUI.chatBackground)
        .tint(FeiQUI.accent)
        .interactiveDismissDisabled(maintenance.isBusy || maintenance.requiresRestart)
        .task { maintenance.loadStatistics() }
        .confirmationDialog("永久清理这些附件？", isPresented: $confirmsCleanup, titleVisibility: .visible) {
            Button("清理 \(maintenance.cleanupPreview?.files.count ?? 0) 个附件", role: .destructive) { maintenance.performCleanup() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除预览中的本机附件，聊天文字与附件名称保留。清理后的图片和文件无法打开，操作不可撤销；建议先创建备份。")
        }
        .confirmationDialog("覆盖当前数据库并恢复备份？", isPresented: $confirmsRestore, titleVisibility: .visible) {
            Button("创建安全备份并恢复", role: .destructive) { maintenance.performRestore() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这不是合并导入。当前消息、联系人、群聊及会话设置将被所选备份替换；先自动备份当前数据，任何校验或复制失败均不覆盖数据库。恢复后需要重新打开应用，不会自动恢复通信。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            FeiQIconBadge(systemImage: "externaldrive.badge.timemachine")
            VStack(alignment: .leading, spacing: 5) {
                Text("数据库维护").font(.title2.weight(.semibold))
                Text("统计占用 · 清理旧附件 · 完整备份与恢复")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新统计", systemImage: "arrow.clockwise") { maintenance.loadStatistics() }
                .disabled(maintenance.isBusy || maintenance.requiresRestart)
        }
        .padding(24)
    }

    private var statistics: some View {
        GroupBox("存储占用") {
            if let report = maintenance.statistics {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(DatabaseMaintenanceViewModel.byteCount(report.totalBytes))
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                        Spacer()
                        Text("\(report.messageCount) 条消息 · \(report.imageCount + report.fileCount) 个本地附件")
                            .foregroundStyle(.secondary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                        GridRow {
                            storageLabel("数据库及日志", bytes: report.databaseBytes)
                            storageLabel("图片", bytes: report.imageBytes)
                            storageLabel("文件", bytes: report.fileBytes)
                            storageLabel("恢复前安全备份", bytes: report.safetyBackupBytes)
                        }
                    }
                    Text("无引用文件 \(report.unreferencedFileCount) 个（\(DatabaseMaintenanceViewModel.byteCount(report.unreferencedBytes))） · 缺失附件引用 \(report.missingAttachmentCount) 条")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("按文件逻辑大小统计，共享附件只计一次；APFS 克隆或硬链接的实际可用空间变化可能不同。已跳过 \(report.skippedEntryCount) 个链接、子目录或特殊条目。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
            } else {
                Text("尚未读取统计数据").foregroundStyle(.secondary).padding(16)
            }
        }
    }

    private func storageLabel(_ name: String, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(DatabaseMaintenanceViewModel.byteCount(bytes)).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var availability: some View {
        HStack(spacing: 12) {
            Label(model.isRunning ? "维护操作前请暂停通信" : "通信已暂停，可进行维护", systemImage: model.isRunning ? "network" : "pause.circle")
            Spacer()
            if model.isRunning {
                Button("暂停通信") { model.stopNetwork() }
                    .disabled(maintenance.isBusy || model.fileTransferSnapshot.unfinishedCount > 0)
            }
        }
        .font(.callout)
        .padding(12)
        .background(FeiQUI.accentSoft, in: RoundedRectangle(cornerRadius: 9))
        .help("若有未完成传输，请先在下载中心完成或取消任务。维护后不会自动切换在线。")
    }

    private var cleanup: some View {
        GroupBox("清理旧附件") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DatePicker("清理此日期之前的附件", selection: $maintenance.policy.before,
                               in: ...Calendar.current.startOfDay(for: Date()), displayedComponents: .date)
                    Spacer()
                    Button("预览清理") { maintenance.previewCleanup() }
                }
                Toggle("包含无引用的旧文件（按文件修改 / 创建时间判断）", isOn: $maintenance.policy.includesUnreferencedFiles)
                    .toggleStyle(.checkbox)
                Text("按最后一次消息引用判断新旧；被较新消息、草稿或本次传输任务引用的文件不会清理。不会触碰原始文件或安全备份。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let preview = maintenance.cleanupPreview {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("待清理 \(preview.files.count) 个文件 · \(DatabaseMaintenanceViewModel.byteCount(preview.byteCount))")
                                .fontWeight(.medium)
                            Text("影响 \(preview.affectedMessageCount) 条消息的附件可用性，跳过 \(preview.protectedFileCount) 个正在使用的文件")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("清理…", role: .destructive) { confirmsCleanup = true }
                            .disabled(preview.files.isEmpty)
                    }
                    ForEach(preview.files.prefix(8), id: \.relativePath) { file in
                        HStack {
                            Text(file.relativePath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(DatabaseMaintenanceViewModel.byteCount(file.byteCount))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if preview.files.count > 8 { Text("以及另外 \(preview.files.count - 8) 个文件").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(10)
        }
        .disabled(maintenance.isBusy)
    }

    private var backup: some View {
        GroupBox("备份与恢复") {
            VStack(alignment: .leading, spacing: 12) {
                Text("备份包含聊天数据库、联系人 / 群聊、备注 / 标签 / 屏蔽等会话设置及已关联附件；不含未发送草稿、本机昵称、提示音与界面偏好。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("创建完整备份…", systemImage: "externaldrive.badge.plus") { maintenance.chooseBackupDestination() }
                    Button("选择备份恢复…", systemImage: "arrow.counterclockwise") { maintenance.chooseRestoreSource() }
                    Spacer()
                    Button("打开数据目录", systemImage: "folder") {
                        NSWorkspace.shared.open(maintenance.service.attachmentDirectory)
                    }
                }
                if let preview = maintenance.backupPreview {
                    Divider()
                    Text("备份时间：\(preview.manifest.createdAt.formatted(date: .numeric, time: .standard))")
                    Text("\(preview.manifest.messageCount) 条消息 · \(preview.manifest.conversationCount) 个会话 · \(preview.manifest.files.count) 个附件 · \(DatabaseMaintenanceViewModel.byteCount(preview.byteCount))")
                        .font(.caption).foregroundStyle(.secondary)
                    if preview.manifest.missingAttachmentCount > 0 {
                        Text("此备份有 \(preview.manifest.missingAttachmentCount) 个缺失附件，不能恢复其内容。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("覆盖恢复…", role: .destructive) { confirmsRestore = true }
                }
            }
            .padding(10)
        }
        .disabled(maintenance.isBusy)
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = maintenance.report {
                Label(report, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            if let warning = maintenance.warning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let error = maintenance.errorMessage {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let url = maintenance.lastBackupURL {
                Text(url.path).font(.caption).foregroundStyle(.secondary)
                Button("在 Finder 中显示备份", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}
