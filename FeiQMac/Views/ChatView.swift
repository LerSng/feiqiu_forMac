import SwiftUI

struct ChatDetailView: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        Group {
            if let group = model.selectedGroup {
                VStack(spacing: 0) {
                    GroupChatHeader(group: group)
                    Divider()
                    MessageList(
                        conversationID: group.id,
                        conversationTitle: group.displayName,
                        peer: nil
                    )
                    .id(group.id)
                    Divider()
                    MessageComposer()
                }
            } else if let peer = model.selectedPeer {
                VStack(spacing: 0) {
                    ChatHeader(peer: peer)
                    Divider()
                    MessageList(
                        conversationID: peer.id,
                        conversationTitle: peer.displayName,
                        peer: peer
                    )
                        .id(peer.id)
                    Divider()
                    MessageComposer()
                }
            } else {
                EmptyChatView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FeiQUI.chatBackground)
    }
}

private struct GroupChatHeader: View {
    @EnvironmentObject private var model: ChatViewModel
    let group: ChatGroup

    private var onlineMemberCount: Int {
        model.members(for: group.id).filter(\.isOnline).count
    }

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatar(size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "person.3.fill")
                    Text("\(group.memberCount) 位成员")
                    Text("·")
                    Text("\(onlineMemberCount) 人在线")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("飞秋兼容群聊")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("按成员分别发送")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .background(.regularMaterial)
    }
}

private struct ChatHeader: View {
    let peer: FeiQPeer

    var body: some View {
        HStack(spacing: 12) {
            ContactAvatar(name: peer.displayName, isOnline: peer.isOnline, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(peer.isOnline ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(peer.isOnline ? "在线" : "最近离线")
                    Text("·")
                    Text(peer.detailText)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("飞秋局域网")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(peer.ipAddress)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .background(.regularMaterial)
    }
}

private struct MessageList: View {
    @EnvironmentObject private var model: ChatViewModel
    let conversationID: String
    let conversationTitle: String
    let peer: FeiQPeer?
    @State private var showingMessages = false
    @State private var activeLoadAnimationMode: ChatLoadAnimationMode = .converge
    @State private var didFinishInitialLoad = false
    @State private var lastRenderedMessageID: UUID?

    private var messages: [ChatMessage] {
        model.messages(for: conversationID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 13) {
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
                                    Text("开始和 \(conversationTitle) 聊天")
                                        .foregroundStyle(.secondary)
                                    Text("消息通过局域网 UDP 2425 直接发送")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 96)
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
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.035), in: Capsule())
                            .onAppear {
                                model.loadEarlierMessages(
                                    for: conversationID,
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
                            MessageBubble(
                                message: message,
                                conversationName: conversationTitle,
                                peer: peer
                            )
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
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .animation(
                    .spring(response: 0.38, dampingFraction: 0.84),
                    value: messages.count
                )
            }
            .background(FeiQUI.chatBackground)
            .scrollIndicators(.hidden)
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
    let conversationName: String
    let peer: FeiQPeer?
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
        let rawValue: String
        if isOutgoing {
            rawValue = message.senderName
        } else if let peer {
            rawValue = peer.displayName
        } else {
            rawValue = message.senderName
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (isOutgoing ? "我" : "未知发送人") : value
    }

    private var recipientName: String {
        let value = conversationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未知收件人" : value
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
                    Text(senderName)
                        .fontWeight(.semibold)
                    Text("→")
                        .foregroundStyle(.tertiary)
                    Text(recipientName)
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
                .frame(maxWidth: 520, alignment: isOutgoing ? .trailing : .leading)

                Text(message.text)
                    .font(.body)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .foregroundStyle(isOutgoing ? Color.white : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isOutgoing
                            ? FeiQUI.accent
                            : FeiQUI.cardBackground,
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
                    .frame(maxWidth: 520, alignment: isOutgoing ? .trailing : .leading)
            }

            if isOutgoing {
                avatar
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }

    private var avatar: some View {
        ContactAvatar(
            name: isOutgoing ? "我" : (peer?.displayName ?? message.senderName),
            isOnline: true,
            size: 34
        )
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("新消息")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌘↩ 发送")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showingEmojiPicker.toggle()
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("选择表情")
                .popover(isPresented: $showingEmojiPicker, arrowEdge: .bottom) {
                    EmojiPickerView { emoji in
                        model.insertEmoji(emoji)
                        showingEmojiPicker = false
                    }
                }

                TextEditor(text: $model.draft)
                    .font(.body)
                    .frame(minHeight: 52, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(FeiQUI.cardBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }

                Button {
                    model.sendDraft()
                } label: {
                    Label("发送", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("飞秋兼容表情使用 Windows 表情码，中文自动转换为 GB18030")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
