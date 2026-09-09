import AppKit
import SwiftUI

struct AttachmentHistoryView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var historyModel: AttachmentHistoryViewModel
    @State private var previewAttachment: ChatAttachment?

    private var filtersDates: Binding<Bool> {
        Binding(
            get: { historyModel.query.startDate != nil || historyModel.query.endDate != nil },
            set: { enabled in
                var query = historyModel.query
                query.startDate = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                query.endDate = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                historyModel.query = query
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            results
        }
        .task { historyModel.start() }
        .onDisappear { historyModel.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { historyModel.searchNow() }
        }
        .sheet(item: $previewAttachment) { attachment in
            if attachment.isImage {
                ImagePreviewView(attachment: attachment)
            } else {
                FilePreviewView(attachment: attachment)
            }
        }
        .alert("无法定位原消息", isPresented: Binding(
            get: { model.historyNavigationError != nil },
            set: { if !$0 { model.historyNavigationError = nil } }
        )) {
            Button("好", role: .cancel) { model.historyNavigationError = nil }
        } message: {
            Text(model.historyNavigationError ?? "")
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("文件名、联系人、备注或发送者", text: $historyModel.query.text)
                    .textFieldStyle(.plain)
                    .onSubmit { historyModel.searchNow() }
                if !historyModel.query.text.isEmpty {
                    Button { historyModel.query.text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("清除关键词")
                    .accessibilityLabel("清除关键词")
                }
                Button("刷新", systemImage: "arrow.clockwise") { historyModel.searchNow() }
                    .disabled(historyModel.isSearching)
                    .help("重新读取历史附件和本地文件状态")
            }
            .padding(10)
            .feiQSurface(fill: FeiQUI.cardBackground, cornerRadius: 9)

            HStack(spacing: 14) {
                Picker("会话", selection: $historyModel.query.conversationID) {
                    Text("全部联系人与群聊").tag(String?.none)
                    ForEach(model.peers) { peer in
                        Text("\(model.displayName(for: peer)) · \(peer.ipAddress)").tag(Optional(peer.id))
                    }
                    ForEach(model.groups) { group in
                        Text("群聊 · \(model.displayName(for: group))").tag(Optional(group.id))
                    }
                }
                .frame(minWidth: 230, maxWidth: .infinity)
                Picker("方向", selection: $historyModel.query.direction) {
                    Text("仅接收").tag(Optional(ChatMessageDirection.incoming))
                    Text("仅发送").tag(Optional(ChatMessageDirection.outgoing))
                    Text("全部方向").tag(ChatMessageDirection?.none)
                }
                .frame(width: 144)
                Picker("类型", selection: $historyModel.query.kind) {
                    Text("全部附件").tag(ChatAttachmentKind?.none)
                    Text("图片").tag(Optional(ChatAttachmentKind.image))
                    Text("文件").tag(Optional(ChatAttachmentKind.file))
                }
                .frame(width: 144)
                Toggle("按日期筛选", isOn: filtersDates)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .controlSize(.small)

            if filtersDates.wrappedValue {
                HStack(spacing: 16) {
                    DatePicker("开始日期", selection: Binding(
                        get: { historyModel.query.startDate ?? Date() },
                        set: { historyModel.query.startDate = $0 }
                    ), displayedComponents: .date)
                    DatePicker("结束日期", selection: Binding(
                        get: { historyModel.query.endDate ?? Date() },
                        set: { historyModel.query.endDate = $0 }
                    ), displayedComponents: .date)
                    Text("包含起止当天").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("已加载 \(historyModel.results.count) 个附件\(historyModel.hasMore ? " · 还有更多" : "")")
                Spacer()
                if historyModel.isSearching || model.isLocatingHistoryMessage {
                    ProgressView().controlSize(.small)
                    Text(model.isLocatingHistoryMessage ? "正在定位原消息…" : "正在查询…")
                } else {
                    Text("按时间倒序")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if let error = historyModel.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button("重试") { historyModel.retry() }
                }
                .font(.caption)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if historyModel.results.isEmpty {
                if historyModel.isSearching {
                    ProgressView("正在读取历史附件…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        historyModel.errorMessage == nil ? "暂无匹配的历史附件" : "暂时无法读取附件",
                        systemImage: "tray",
                        description: Text(historyModel.errorMessage == nil
                            ? "接收完成的文件、图片及导入的历史附件会显示在这里，也可切换为查看已发送附件。"
                            : "请重试，或调整筛选条件后再次查询。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(historyModel.results) { result in
                            AttachmentHistoryRow(
                                result: result, isLocating: model.isLocatingHistoryMessage,
                                preview: { previewAttachment = result.attachment },
                                revealMessage: { model.revealHistoryAttachment(result) }
                            )
                        }
                        if historyModel.hasMore {
                            Button("加载更多附件") { historyModel.loadMore() }
                                .disabled(historyModel.isSearching)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .hiddenScrollIndicators()
            }
        }
    }
}

private struct AttachmentHistoryRow: View {
    let result: ChatAttachmentHistoryResult
    let isLocating: Bool
    let preview: () -> Void
    let revealMessage: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: preview) {
                if result.attachment.isImage {
                    HistoryImageThumbnailView(attachment: result.attachment, width: 104, height: 78)
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(FeiQUI.accent)
                        .frame(width: 104, height: 78)
                        .background(FeiQUI.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .buttonStyle(.plain)
            .disabled(!result.attachment.isAvailable)
            .help(result.attachment.isAvailable ? "预览附件" : "本地文件已缺失，附件信息仍保留")

            VStack(alignment: .leading, spacing: 6) {
                Text(result.attachment.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(result.attachment.fileName)
                Label("\(result.conversationName) · \(result.direction == .incoming ? "接收" : "发送")",
                      systemImage: result.isGroup ? "person.2" : "person")
                    .lineLimit(1)
                Text("\(result.senderName) · \(result.date.formatted(date: .numeric, time: .shortened)) · \(result.attachment.fileSizeDescription)")
                    .lineLimit(1)
                if !result.attachment.isAvailable {
                    Label("本地文件已缺失", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)

            VStack(alignment: .trailing, spacing: 10) {
                HStack {
                    Button("预览", action: preview)
                        .disabled(!result.attachment.isAvailable)
                    Menu {
                        Button("打开文件", systemImage: "arrow.up.forward.app") {
                            NSWorkspace.shared.open(result.attachment.localURL)
                        }
                        .disabled(!result.attachment.isAvailable)
                        Button("在 Finder 中显示", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([result.attachment.localURL])
                        }
                        .disabled(!result.attachment.isAvailable)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 22)
                    .accessibilityLabel("\(result.attachment.fileName)更多操作")
                }
                Button("定位原消息", action: revealMessage)
                    .disabled(isLocating)
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(14)
        .feiQSurface(fill: FeiQUI.cardBackground, cornerRadius: 12)
    }
}
