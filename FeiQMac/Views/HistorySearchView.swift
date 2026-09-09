import SwiftUI

struct HistorySearchView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var searchModel: HistorySearchViewModel
    @FocusState private var searchFieldFocused: Bool
    @State private var previewAttachment: ChatAttachment?
    @State private var exportModel: HistoryArchiveViewModel?

    private var filtersDates: Binding<Bool> {
        Binding(
            get: { searchModel.query.startDate != nil || searchModel.query.endDate != nil },
            set: { enabled in
                var query = searchModel.query
                query.startDate = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                query.endDate = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                searchModel.query = query
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filters
            Divider()
            results
        }
        .frame(minWidth: 860, idealWidth: 920, minHeight: 620, idealHeight: 700)
        .background(FeiQUI.chatBackground)
        .tint(FeiQUI.accent)
        .task {
            searchModel.searchNow()
            searchFieldFocused = true
        }
        .onDisappear {
            searchModel.cancel()
            model.cancelHistoryNavigation()
        }
        .sheet(item: $previewAttachment) { attachment in
            if attachment.isImage {
                ImagePreviewView(attachment: attachment)
            } else {
                FilePreviewView(attachment: attachment)
            }
        }
        .sheet(item: $exportModel) { archive in
            HistoryArchiveView(archiveModel: archive)
                .environmentObject(model)
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

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(FeiQUI.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("历史消息搜索")
                    .font(.title2.weight(.semibold))
                Text("搜索本机保存的完整聊天记录，包括离线联系人与群聊")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("导出结果") {
                exportModel = model.makeHistoryArchiveModel(query: searchModel.query)
            }
            .disabled(searchModel.results.isEmpty || searchModel.isSearching || model.isLocatingHistoryMessage)
            .help("导出当前筛选的全部记录，不仅是已加载的结果")
            if model.isLocatingHistoryMessage {
                ProgressView().controlSize(.small)
                Text("正在定位…").font(.caption)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(FeiQIconButtonStyle(size: 30))
            .keyboardShortcut(.cancelAction)
            .help("关闭历史消息搜索")
            .accessibilityLabel("关闭历史消息搜索")
        }
        .padding(22)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索消息文本、图片或文件名称", text: $searchModel.query.text)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onSubmit { searchModel.searchNow() }
                if !searchModel.query.text.isEmpty {
                    Button { searchModel.query.text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清除关键词")
                    .accessibilityLabel("清除关键词")
                }
            }
            .padding(12)
            .feiQSurface(fill: FeiQUI.cardBackground, cornerRadius: 10)

            HStack(spacing: 16) {
                Picker("联系人 / 群聊", selection: $searchModel.query.conversationID) {
                    Text("全部联系人与群聊").tag(String?.none)
                    ForEach(model.peers) { peer in
                        Text("\(peer.displayName) · \(peer.ipAddress)")
                            .tag(Optional(peer.id))
                    }
                    ForEach(model.groups) { group in
                        Text("群聊 · \(group.displayName)").tag(Optional(group.id))
                    }
                }
                .frame(maxWidth: 320)
                Spacer(minLength: 0)
                Button("重置筛选") { searchModel.query = ChatHistorySearchQuery() }
                    .buttonStyle(.borderless)
                Button {
                    searchModel.searchNow()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(searchModel.isSearching)
            }

            HStack(spacing: 16) {
                Picker("消息类型", selection: $searchModel.query.kind) {
                    ForEach(ChatHistoryMessageKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Toggle("日期范围", isOn: filtersDates)
                    .toggleStyle(.checkbox)
                if filtersDates.wrappedValue {
                    DatePicker("开始", selection: Binding(
                        get: { searchModel.query.startDate ?? Date() },
                        set: { searchModel.query.startDate = $0 }
                    ), displayedComponents: .date)
                    DatePicker("结束", selection: Binding(
                        get: { searchModel.query.endDate ?? Date() },
                        set: { searchModel.query.endDate = $0 }
                    ), displayedComponents: .date)
                } else {
                    Text("不限日期")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(searchModel.results.count) 条结果\(searchModel.hasMore ? "（可继续加载）" : "")")
                Spacer()
                Text("按时间从新到旧 · 日期包含起止两天")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = searchModel.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("重试") { searchModel.retry() }
                        .disabled(searchModel.isSearching)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(10)
                .background(FeiQUI.subtleFill, in: RoundedRectangle(cornerRadius: 8))
            }

            if searchModel.results.isEmpty {
                VStack(spacing: 12) {
                    if searchModel.isSearching {
                        ProgressView()
                        Text("正在搜索历史消息…")
                    } else {
                        Image(systemName: searchModel.errorMessage == nil ? "text.magnifyingglass" : "exclamationmark.triangle")
                            .font(.system(size: 34))
                        Text(searchModel.errorMessage == nil ? "没有匹配的历史消息" : "暂时无法显示搜索结果")
                        Text("试试其他联系人、日期或关键词，也可以只按消息类型查询。")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        ForEach(searchModel.results) { result in
                            HistorySearchResultRow(
                                result: result, query: searchModel.query,
                                isLocating: model.isLocatingHistoryMessage,
                                preview: { previewAttachment = $0 },
                                reveal: { model.revealHistoryMessage(result) }
                            )
                        }
                        if searchModel.isSearching {
                            ProgressView().controlSize(.small).padding(10)
                        } else if searchModel.hasMore {
                            Button("加载更多结果") { searchModel.loadMore() }
                                .padding(10)
                        }
                    }
                    .padding(2)
                }
                .hiddenScrollIndicators()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct HistorySearchResultRow: View {
    let result: ChatHistorySearchResult
    let query: ChatHistorySearchQuery
    let isLocating: Bool
    let preview: (ChatAttachment) -> Void
    let reveal: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private var attachments: [ChatAttachment] {
        guard let kind = query.kind.attachmentKind else { return result.message.attachments }
        return result.message.attachments.filter { $0.kind == kind }
    }

    private var sender: String {
        if result.message.direction == .outgoing { return "我" }
        return result.message.senderName.isEmpty ? result.conversationName : result.message.senderName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(result.conversationName, systemImage: result.isGroup ? "person.2" : "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(sender)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(Self.dateFormatter.string(from: result.message.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("定位到聊天", action: reveal)
                    .buttonStyle(.borderless)
                    .disabled(isLocating)
            }

            if !result.message.text.isEmpty {
                Text(highlighted(result.message.text))
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(attachments) { attachment in
                Button { preview(attachment) } label: {
                    HStack(spacing: 10) {
                        if attachment.isImage {
                            HistoryImageThumbnailView(attachment: attachment)
                        } else {
                            Image(systemName: attachment.systemImageName)
                                .font(.system(size: 22))
                                .foregroundStyle(FeiQUI.accent)
                                .frame(width: 30)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(highlighted(attachment.fileName))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(attachment.fileSizeDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "eye")
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(FeiQUI.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("预览 \(attachment.fileName)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feiQSurface(fill: FeiQUI.cardBackground, cornerRadius: 12)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.keyword.isEmpty else { return attributed }
        var start = text.startIndex
        while start < text.endIndex,
              let match = text.range(of: query.keyword, options: .caseInsensitive, range: start..<text.endIndex) {
            if let lower = AttributedString.Index(match.lowerBound, within: attributed),
               let upper = AttributedString.Index(match.upperBound, within: attributed) {
                attributed[lower..<upper].backgroundColor = FeiQUI.accent.opacity(0.18)
            }
            start = match.upperBound
        }
        return attributed
    }
}

struct HistoryImageThumbnailView: View {
    let attachment: ChatAttachment
    var width: CGFloat = 160
    var height: CGFloat = 112
    @State private var image: CGImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            FeiQUI.cardBackground
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                    Text("图片不可用").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("图片缩略图：\(attachment.fileName)")
        .task(id: attachment) {
            image = nil
            isLoading = true
            let thumbnail = await ChatImageThumbnailService.shared.thumbnail(for: attachment)
            guard !Task.isCancelled else { return }
            image = thumbnail
            isLoading = false
        }
    }
}
