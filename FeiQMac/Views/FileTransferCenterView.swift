import AppKit
import SwiftUI

private enum TransferFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case active = "进行中"
    case queued = "排队中"
    case failed = "失败"
    case finished = "已结束"

    var id: Self { self }

    func includes(_ transfer: FileTransferRecord) -> Bool {
        switch self {
        case .all: return true
        case .active: return transfer.state.isActive
        case .queued: return transfer.state == .queued
        case .failed: return transfer.state == .failed
        case .finished: return transfer.state == .completed || transfer.state == .cancelled
        }
    }
}

struct FileTransferCenterView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var filter: TransferFilter = .all
    @State private var direction: FileTransferDirection?
    @State private var searchText = ""
    @State private var showingCancelConfirmation = false

    private var snapshot: FileTransferSnapshot { model.fileTransferSnapshot }

    private var visibleTransfers: [FileTransferRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.transfers.enumerated().filter { _, transfer in
            filter.includes(transfer)
                && (direction == nil || transfer.direction == direction)
                && (query.isEmpty || transfer.attachment.fileName.localizedCaseInsensitiveContains(query)
                    || transfer.peerName.localizedCaseInsensitiveContains(query)
                    || transfer.ipAddress.localizedCaseInsensitiveContains(query))
        }.sorted { first, second in
            let firstPriority = priority(first.element)
            let secondPriority = priority(second.element)
            if firstPriority != secondPriority { return firstPriority < secondPriority }
            if firstPriority < 2 { return first.offset < second.offset }
            return first.element.createdAt > second.element.createdAt
        }.map(\.element)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Divider()
            if visibleTransfers.isEmpty {
                ContentUnavailableView(
                    snapshot.transfers.isEmpty ? "暂无文件传输" : "没有匹配的任务",
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text(snapshot.transfers.isEmpty
                        ? "发送或接收文件后，进度和队列会显示在这里。"
                        : "试试其他筛选条件或搜索关键词。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleTransfers) { transfer in
                            FileTransferRow(transfer: transfer)
                        }
                    }
                    .padding(20)
                }
                .hiddenScrollIndicators()
            }
            Divider()
            HStack(spacing: 12) {
                Text("记录保留至退出应用；重试从头传输，不删除原文件。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 570, idealHeight: 660)
        .background(FeiQUI.windowBackground)
        .tint(FeiQUI.accent)
        .confirmationDialog("取消全部未完成传输？", isPresented: $showingCancelConfirmation) {
            Button("取消全部传输", role: .destructive) { model.cancelAllFileTransfers() }
            Button("返回", role: .cancel) {}
        } message: {
            Text("正在传输的连接会中断，排队任务会取消。已完成文件和发送原文件不受影响，取消后可重新加入队列。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.up.arrow.down.square.fill")
                .font(.system(size: 34))
                .foregroundStyle(FeiQUI.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text("文件传输中心").font(.system(size: 21, weight: .semibold))
                Text("\(snapshot.activeCount) 个进行中 · \(snapshot.queuedCount) 个排队 · \(snapshot.failedCount) 个失败")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if snapshot.isPaused {
                Label("队列已暂停", systemImage: "pause.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    model.setFileTransferQueuePaused(!snapshot.isPaused)
                } label: {
                    Label(snapshot.isPaused ? "继续队列" : "暂停队列",
                          systemImage: snapshot.isPaused ? "play.fill" : "pause.fill")
                }
                .help("只暂停排队任务的启动，不中断正在传输的文件")
                Button("重试全部失败", systemImage: "arrow.clockwise") {
                    model.retryFailedFileTransfers()
                }
                .disabled(snapshot.failedCount == 0)
                Menu {
                    Button("取消全部未完成…", role: .destructive) {
                        showingCancelConfirmation = true
                    }
                    .disabled(snapshot.unfinishedCount == 0)
                    Button("清除已完成和已取消记录") { model.clearFinishedFileTransfers() }
                        .disabled(!snapshot.transfers.contains { $0.state == .completed || $0.state == .cancelled })
                } label: {
                    Label("批量管理", systemImage: "ellipsis.circle")
                }
                .fixedSize()
                Spacer()
                Picker("每方向并发", selection: Binding(
                    get: { snapshot.maximumConcurrentTransfers },
                    set: { model.setFileTransferConcurrency($0) }
                )) {
                    ForEach(1...6, id: \.self) { count in Text("\(count)").tag(count) }
                }
                .frame(width: 142)
                .help("发送和接收分别限制并发，避免互相等待；降低上限不会中断已开始的任务")
            }
            .controlSize(.small)

            HStack(spacing: 12) {
                Picker("任务状态", selection: $filter) {
                    ForEach(TransferFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Picker("传输方向", selection: $direction) {
                    Text("全部方向").tag(Optional<FileTransferDirection>.none)
                    Text("接收").tag(Optional(FileTransferDirection.incoming))
                    Text("发送").tag(Optional(FileTransferDirection.outgoing))
                }
                .labelsHidden()
                .frame(width: 96)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("文件、联系人或 IP", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .font(.system(size: 12))
                .padding(7)
                .background(FeiQUI.subtleFill, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func priority(_ transfer: FileTransferRecord) -> Int {
        if transfer.state.isActive { return 0 }
        if transfer.state == .queued { return 1 }
        if transfer.state == .failed { return 2 }
        return 3
    }
}

private struct FileTransferRow: View {
    @EnvironmentObject private var model: ChatViewModel
    let transfer: FileTransferRecord
    @State private var showingDetails = false

    private var queued: [FileTransferRecord] {
        model.fileTransferSnapshot.transfers.filter {
            $0.state == .queued && $0.direction == transfer.direction
        }
    }

    private var queueIndex: Int? { queued.firstIndex { $0.id == transfer.id } }

    private var statusColor: Color {
        switch transfer.state {
        case .completed: return .green
        case .failed: return .red
        case .waitingForPeer, .cancelling: return .orange
        case .queued, .cancelled: return .secondary
        case .connecting, .transferring: return FeiQUI.accent
        }
    }

    private var statusText: String {
        if let queueIndex { return "排队中 · 第 \(queueIndex + 1) 位" }
        if transfer.state == .transferring { return transfer.direction == .incoming ? "接收中" : "发送中" }
        return transfer.state.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: transfer.attachment.systemImageName)
                    .font(.system(size: 22))
                    .foregroundStyle(FeiQUI.accent)
                    .frame(width: 42, height: 46)
                    .background(FeiQUI.accentSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(transfer.attachment.fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(transfer.attachment.fileName)
                    Label("\(transfer.direction.rawValue) · \(transfer.peerName)",
                          systemImage: transfer.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.08), in: Capsule())
                actions
            }

            ProgressView(value: transfer.progress)
                .progressViewStyle(.linear)
                .tint(statusColor)
                .accessibilityLabel("\(transfer.attachment.fileName)传输进度")
                .accessibilityValue("\(Int(transfer.progress * 100))%")

            HStack(spacing: 10) {
                Text("\(byteCount(transfer.bytesTransferred)) / \(byteCount(transfer.attachment.fileSize))")
                Text("\(Int(transfer.progress * 100))%")
                    .foregroundStyle(statusColor)
                if transfer.state == .transferring, transfer.bytesPerSecond > 0 {
                    Text("\(byteCount(Int64(min(transfer.bytesPerSecond, Double(Int64.max / 2)))))/秒")
                    if let remaining = transfer.remainingSeconds {
                        Text("剩余约 \(remainingDescription(remaining))")
                    }
                }
                Spacer()
                Button(showingDetails ? "收起详情" : "详情") { showingDetails.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(FeiQUI.accent)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)

            if let error = transfer.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showingDetails { details }
        }
        .padding(14)
        .background(FeiQUI.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(FeiQUI.separator))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if transfer.state.canCancel {
                Button("取消") { model.cancelFileTransfer(transfer.id) }
            }
            if transfer.state.canRetry {
                Button(transfer.state == .cancelled ? "重新排队" : "重试") {
                    model.retryFileTransfer(transfer.id)
                }
                .help("从头重试；接收时需对方仍保留该文件的发送任务")
            }
            if transfer.state == .completed {
                Button("显示文件", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([transfer.attachment.localURL])
                }
                .disabled(!transfer.attachment.isAvailable)
            }
            Menu {
                if let queueIndex {
                    Button("移到队首", systemImage: "arrow.up.to.line") { model.prioritizeFileTransfer(transfer.id) }
                        .disabled(queueIndex == 0)
                    Button("上移", systemImage: "arrow.up") { model.moveFileTransfer(transfer.id, by: -1) }
                        .disabled(queueIndex == 0)
                    Button("下移", systemImage: "arrow.down") { model.moveFileTransfer(transfer.id, by: 1) }
                        .disabled(queueIndex == queued.count - 1)
                    Divider()
                }
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([transfer.attachment.localURL])
                }
                .disabled(!transfer.attachment.isAvailable || (transfer.direction == .incoming && transfer.state != .completed))
                Button("移除记录", systemImage: "trash") { model.removeFileTransfer(transfer.id) }
                    .disabled(!transfer.state.isFinished)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .help("队列排序与记录管理；移除记录不删除文件")
            .accessibilityLabel("\(transfer.attachment.fileName)更多操作")
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            LabeledContent("对方地址", value: transfer.ipAddress)
            LabeledContent("加入时间", value: transfer.createdAt.formatted(date: .numeric, time: .standard))
            LabeledContent("尝试次数", value: "\(transfer.attemptCount)")
            if let finishedAt = transfer.finishedAt {
                LabeledContent("结束时间", value: finishedAt.formatted(date: .numeric, time: .standard))
            }
            LabeledContent("本地路径", value: transfer.attachment.localPath)
                .textSelection(.enabled)
            if transfer.direction == .outgoing {
                Text("发送完成表示文件数据已写入连接，不代表对方已保存或阅读。")
            } else if transfer.state.canRetry {
                Text("重试会重新请求原消息中的文件；若对方已移除发送任务，需要请对方重新发送。")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func remainingDescription(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400 { return "超过一天" }
        let value = max(1, Int(ceil(seconds)))
        if value >= 3600 { return "\(value / 3600) 小时 \(value % 3600 / 60) 分钟" }
        if value >= 60 { return "\(value / 60) 分 \(value % 60) 秒" }
        return "\(value) 秒"
    }
}
