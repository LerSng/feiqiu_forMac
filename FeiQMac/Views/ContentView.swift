import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ChatDetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.refreshDiscovery()
                } label: {
                    Label("刷新用户", systemImage: "arrow.clockwise")
                }
                .help("发送一次局域网发现广播")

                Button {
                    model.showingLogs = true
                } label: {
                    Label("网络日志", systemImage: "list.bullet.rectangle")
                }

                Button {
                    model.showingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingLogs) {
            LogsView()
                .environmentObject(model)
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: ChatViewModel

    private var onlinePeers: [FeiQPeer] {
        model.filteredPeers.filter(\.isOnline)
    }

    private var offlinePeers: [FeiQPeer] {
        model.filteredPeers.filter { !$0.isOnline }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("飞秋 Mac")
                            .font(.headline)
                        Text(model.isRunning ? "局域网服务已启动" : "局域网服务未启动")
                            .font(.caption)
                            .foregroundStyle(model.isRunning ? .green : .secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(model.isRunning ? .green : .gray)
                        .frame(width: 9, height: 9)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索用户", text: $model.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)

            Divider()

            List(selection: Binding<String?>(
                get: { model.selectedPeerID },
                set: { peerID in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        model.selectPeer(peerID)
                    }
                }
            )) {
                Section("在线 · \(onlinePeers.count)") {
                    if onlinePeers.isEmpty {
                        Text("暂未发现用户")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(onlinePeers) { peer in
                            PeerRow(
                                peer: peer,
                                unreadCount: model.unreadCount(for: peer.id)
                            )
                                .tag(peer.id)
                        }
                    }
                }

                if !offlinePeers.isEmpty {
                    Section("最近离线") {
                        ForEach(offlinePeers) { peer in
                            PeerRow(
                                peer: peer,
                                unreadCount: model.unreadCount(for: peer.id)
                            )
                                .tag(peer.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Label("UDP/TCP 2425", systemImage: "network")
                Spacer()
                Text("\(model.onlinePeerCount) 人在线")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 250, idealWidth: 280)
    }
}

private struct PeerRow: View {
    let peer: FeiQPeer
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(peer.isOnline ? Color.blue.opacity(0.14) : Color.gray.opacity(0.12))
                Image(systemName: "person.fill")
                    .foregroundStyle(peer.isOnline ? .blue : .secondary)
                    .font(.caption)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName)
                    .lineLimit(1)
                Text(peer.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if unreadCount > 0 {
                Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, unreadCount > 9 ? 3 : 0)
                    .background(Color.red, in: Capsule())
                    .transition(
                        .scale(scale: 0.45, anchor: .trailing)
                            .combined(with: .opacity)
                    )
            }
        }
        .padding(.vertical, 3)
        .opacity(peer.isOnline ? 1 : 0.65)
        .animation(
            .spring(response: 0.32, dampingFraction: 0.78),
            value: unreadCount
        )
        .contextMenu {
            Text(peer.ipAddress)
        }
    }
}

private struct ChatDetailView: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        Group {
            if let peer = model.selectedPeer {
                VStack(spacing: 0) {
                    ChatHeader(peer: peer)
                    Divider()
                    MessageList(peer: peer)
                        .id(peer.id)
                    Divider()
                    MessageComposer()
                }
            } else {
                EmptyChatView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ChatHeader: View {
    let peer: FeiQPeer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(peer.isOnline ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName)
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(peer.isOnline ? .green : .secondary)
                        .frame(width: 7, height: 7)
                    Text(peer.isOnline ? "在线" : "最近离线")
                    Text("·")
                    Text(peer.detailText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

private struct MessageList: View {
    @EnvironmentObject private var model: ChatViewModel
    let peer: FeiQPeer
    @State private var showingMessages = false
    @State private var activeLoadAnimationMode: ChatLoadAnimationMode = .converge
    @State private var didFinishInitialLoad = false
    @State private var lastRenderedMessageID: UUID?

    private var messages: [ChatMessage] {
        model.messages(for: peer.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if messages.isEmpty {
                        Group {
                            if model.isLoadingMessages {
                                VStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在加载聊天记录…")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.system(size: 34))
                                        .foregroundStyle(.tertiary)
                                    Text("开始和 \(peer.displayName) 聊天")
                                        .foregroundStyle(.secondary)
                                    Text("消息通过局域网 UDP 2425 直接发送")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        if model.hasMoreMessages, let firstMessage = messages.first {
                            HStack(spacing: 8) {
                                if model.isLoadingMessages {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在加载更早的聊天记录…")
                                } else {
                                    Text("向上滚动加载更早的聊天记录")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .onAppear {
                                model.loadEarlierMessages(
                                    for: peer.id,
                                    before: firstMessage
                                ) {
                                    DispatchQueue.main.async {
                                        var transaction = Transaction(animation: nil)
                                        transaction.disablesAnimations = true
                                        withTransaction(transaction) {
                                            proxy.scrollTo(
                                                firstMessage.id,
                                                anchor: .top
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        ForEach(messages) { message in
                            MessageBubble(message: message, peer: peer)
                                .id(message.id)
                                .transition(messageTransition(for: message))
                                .opacity(
                                    showingMessages
                                        ? 1
                                        : initialOpacity
                                )
                                .offset(
                                    x: initialOffset(for: message).width,
                                    y: initialOffset(for: message).height
                                )
                                .scaleEffect(
                                    showingMessages
                                        ? 1
                                        : initialScale(for: message),
                                    anchor: message.direction == .outgoing ? .trailing : .leading
                                )
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .animation(
                    .spring(response: 0.38, dampingFraction: 0.84),
                    value: messages.count
                )
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onAppear {
                if !model.isLoadingMessages {
                    didFinishInitialLoad = true
                    lastRenderedMessageID = messages.last?.id
                }
                presentMessages(using: proxy)
            }
            .onChange(of: model.isLoadingMessages) { _, isLoading in
                guard !isLoading else { return }
                if !didFinishInitialLoad {
                    didFinishInitialLoad = true
                    scrollToLatest(using: proxy, animated: false)
                }
                lastRenderedMessageID = messages.last?.id
            }
            .onChange(of: messages.count) { _, _ in
                guard showingMessages,
                      didFinishInitialLoad,
                      !model.isLoadingMessages else {
                    return
                }
                let latestMessageID = messages.last?.id
                guard latestMessageID != lastRenderedMessageID else { return }
                lastRenderedMessageID = latestMessageID
                if let lastMessage = messages.last {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func presentMessages(using proxy: ScrollViewProxy) {
        let mode = model.chatLoadAnimationMode.modeForPresentation()
        activeLoadAnimationMode = mode
        showingMessages = false
        if !model.isLoadingMessages {
            didFinishInitialLoad = true
            lastRenderedMessageID = messages.last?.id
        }
        scrollToLatest(using: proxy, animated: false)

        DispatchQueue.main.async {
            if mode == .instant {
                showingMessages = true
            } else {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                    showingMessages = true
                }
            }
        }
    }

    private func messageTransition(for message: ChatMessage) -> AnyTransition {
        let anchor: UnitPoint = message.direction == .outgoing ? .trailing : .leading

        switch activeLoadAnimationMode {
        case .converge:
            return .asymmetric(
                insertion: .opacity
                    .combined(
                        with: .move(
                            edge: message.direction == .outgoing ? .trailing : .leading
                        )
                    )
                    .combined(with: .scale(scale: 0.94, anchor: anchor)),
                removal: .opacity
            )
        case .fade:
            return .opacity.combined(with: .scale(scale: 0.97, anchor: .center))
        case .slideUp:
            return .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            )
        case .zoom:
            return .asymmetric(
                insertion: .scale(scale: 0.84, anchor: anchor).combined(with: .opacity),
                removal: .opacity
            )
        case .instant, .random:
            return .identity
        }
    }

    private var initialOpacity: Double {
        guard !showingMessages else { return 1 }
        return activeLoadAnimationMode == .instant ? 1 : 0
    }

    private func initialOffset(for message: ChatMessage) -> CGSize {
        guard !showingMessages else { return .zero }

        switch activeLoadAnimationMode {
        case .converge:
            return CGSize(
                width: message.direction == .outgoing ? 42 : -42,
                height: 0
            )
        case .slideUp:
            return CGSize(width: 0, height: 30)
        case .fade, .zoom, .instant, .random:
            return .zero
        }
    }

    private func initialScale(for message: ChatMessage) -> CGFloat {
        guard !showingMessages else { return 1 }

        switch activeLoadAnimationMode {
        case .converge:
            return 0.94
        case .fade:
            return 0.97
        case .zoom:
            return 0.84
        case .slideUp, .instant, .random:
            return 1
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool) {
        guard let lastMessage = messages.last else { return }

        if animated {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let peer: FeiQPeer
    @State private var showingFullDate = false

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
        return formatter
    }()

    private var isOutgoing: Bool {
        message.direction == .outgoing
    }

    private var senderName: String {
        let value = (isOutgoing ? message.senderName : peer.displayName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (isOutgoing ? "我" : "未知发送人") : value
    }

    private var recipientName: String {
        let value = (isOutgoing ? peer.displayName : message.recipientName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未知收件人" : value
    }

    private var metadataText: String {
        "发送人：\(senderName)  →  收件人：\(recipientName)"
    }

    private var fullDateText: String {
        Self.fullDateFormatter.string(from: message.date)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if !isOutgoing {
                avatar
            }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(metadataText)
                    Text("·")
                    Button {
                        showingFullDate.toggle()
                    } label: {
                        Text(showingFullDate ? fullDateText : timeText)
                    }
                    .buttonStyle(.plain)
                    .help(showingFullDate ? "点击显示简略时间" : "点击显示完整日期和时间")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

                Text(message.text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .foregroundStyle(isOutgoing ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isOutgoing
                            ? Color.accentColor
                            : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        if !isOutgoing {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                    }
                    .shadow(
                        color: Color.black.opacity(isOutgoing ? 0.08 : 0.05),
                        radius: 5,
                        y: 2
                    )
                    // Keep the bubble's visible background at its natural
                    // width for short messages, while still wrapping long
                    // messages at a readable maximum width.
                    .frame(maxWidth: 520, alignment: isOutgoing ? .trailing : .leading)
            }

            if isOutgoing {
                avatar
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(isOutgoing ? Color.accentColor.opacity(0.14) : Color.gray.opacity(0.14))
            Image(systemName: "person.fill")
                .font(.caption)
                .foregroundStyle(isOutgoing ? .blue : .secondary)
        }
        .frame(width: 34, height: 34)
    }

    private var timeText: String {
        Self.timeFormatter.string(from: message.date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct MessageComposer: View {
    @EnvironmentObject private var model: ChatViewModel
    @State private var showingEmojiPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showingEmojiPicker.toggle()
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("选择表情")
                .popover(isPresented: $showingEmojiPicker, arrowEdge: .bottom) {
                    EmojiPickerView { emoji in
                        model.insertEmoji(emoji)
                        showingEmojiPicker = false
                    }
                }

                TextEditor(text: $model.draft)
                    .font(.body)
                    .frame(minHeight: 54, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                Button {
                    model.sendDraft()
                } label: {
                    Label("发送", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("⌘↩ 发送 · 飞秋兼容表情使用 Windows 表情码，中文使用 GB18030")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct EmojiPickerView: View {
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择表情")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(EmojiCategory.catalog) { category in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(category.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 4)
                                ],
                                spacing: 4
                            ) {
                                ForEach(category.emojis, id: \.self) { emoji in
                                    Button {
                                        onSelect(emoji)
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 25))
                                            .frame(width: 34, height: 34)
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Rectangle())
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 310, height: 360)
    }
}

private struct EmojiCategory: Identifiable {
    let id: String
    let title: String
    let emojis: [String]

    static let catalog = [
        EmojiCategory(
            id: "feiQCompatible",
            title: "飞秋兼容（Windows）",
            emojis: FeiQMessageFormatter.feiQCompatibleEmojis
        ),
        EmojiCategory(
            id: "faces",
            title: "其他表情（Unicode）",
            emojis: [
                "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣",
                "😊", "😇", "🙂", "🙃", "😉", "😌", "😍", "🥰",
                "😘", "😗", "😙", "😚", "😋", "😛", "😝", "😜",
                "🤪", "🤨", "🧐", "🤓", "😎", "🤩", "🥳", "😏",
                "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣",
                "😖", "😫", "😩", "😢", "😭", "😤", "😠",
                "😡", "🤬", "🤗", "🤔", "🤭", "🤫", "🤥",
                "😐", "😑", "😬", "🙄", "😯", "😦", "😧",
                "😲", "🥱", "😴", "🤤", "😪", "😵", "🤐", "🥴",
                "🤢", "🤮", "🤧", "😷", "🤒", "🤕", "🤑", "🤠"
            ]
        ),
        EmojiCategory(
            id: "gestures",
            title: "手势与人物",
            emojis: [
                "👋", "🤚", "🖐️", "✋", "🖖", "👌", "🤏", "✌️",
                "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "👇",
                "☝️", "👍", "👎", "✊", "👊", "🤝", "🙏", "👏",
                "🙌", "👐", "💪", "👀", "👂", "👃", "👶", "🧒",
                "👦", "👧", "🧑", "👨", "👩", "🧓", "👴", "👵"
            ]
        ),
        EmojiCategory(
            id: "objects",
            title: "物品与符号",
            emojis: [
                "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
                "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖",
                "💘", "💝", "💟", "🔥", "✨", "⭐", "🌟", "💫",
                "🎉", "🎊", "✅", "❌", "⚠️", "❗", "❓", "💯",
                "☀️", "🌈", "☁️", "☕", "🍎", "🍉", "🍔", "🍕",
                "⚽", "🏀", "🎵", "🎶", "🎁", "📌", "💡", "🚀"
            ]
        )
    ]
}

private struct EmptyChatView: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 52))
                .foregroundStyle(.blue.opacity(0.75))
            Text("选择一个局域网用户")
                .font(.title3.weight(.medium))
            Text(model.isRunning ? "正在监听 UDP/TCP 2425，等待飞秋用户上线" : "局域网服务未启动")
                .foregroundStyle(.secondary)
            Button("刷新用户") {
                model.refreshDiscovery()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本机资料")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 4)
            Text("这些字段会放入飞秋的上线广播中。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            Form {
                TextField("昵称", text: $model.nickname)
                TextField("主机名", text: $model.hostName)
                TextField("分组（可选）", text: $model.groupName)
                LabeledContent("通信端口") {
                    Text("UDP / TCP 2425")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("聊天记录") {
                    Text("文稿 / 飞秋 Mac / ChatHistory.sqlite")
                        .foregroundStyle(.secondary)
                }

                Section("聊天界面") {
                    Picker("聊天记录进入方式", selection: $model.chatLoadAnimationMode) {
                        ForEach(ChatLoadAnimationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(model.chatLoadAnimationMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
                .padding(.top, 8)
            HStack {
                if model.isRunning {
                    Button("停止服务") {
                        model.stopNetwork()
                    }
                } else {
                    Button("启动服务") {
                        model.startNetwork()
                    }
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存并广播") {
                    model.saveSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 430)
    }
}

private struct LogsView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("网络日志")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("清空") {
                    model.clearLogs()
                }
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if model.logs.isEmpty {
                        Text("暂无日志")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 30)
                    } else {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
    }
}
