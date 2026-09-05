//
//  ChatView.swift
//  FeiQMac
//
//  负责单聊与群聊详情页，包括聊天头部、消息列表、消息气泡、输入区和空状态。
//

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
        .overlay {
            Rectangle()
                .stroke(FeiQUI.separator, lineWidth: 1)
        }
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
            GroupAvatar(size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(FeiQUI.accent)
                    Text("\(group.memberCount) 位成员")
                    Text("·")
                    Text("\(onlineMemberCount) 人在线")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            FeiQStatusPill(
                title: "兼容群聊",
                subtitle: "按成员分别发送",
                systemImage: "checkmark.seal.fill",
                tint: FeiQUI.accent
            )
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FeiQUI.separator)
                .frame(height: 1)
        }
    }
}

private struct ChatHeader: View {
    let peer: FeiQPeer

    var body: some View {
        HStack(spacing: 12) {
            ContactAvatar(name: peer.displayName, isOnline: peer.isOnline, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    FeiQStatusDot(
                        color: peer.isOnline ? Color.green : Color.secondary
                    )
                    Text(peer.isOnline ? "在线" : "最近离线")
                        .fontWeight(.medium)
                    Text("·")
                    Text(peer.detailText)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            FeiQStatusPill(
                title: "局域网",
                subtitle: peer.ipAddress,
                systemImage: "network",
                tint: peer.isOnline ? Color.green : Color.secondary
            )
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FeiQUI.separator)
                .frame(height: 1)
        }
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
                LazyVStack(spacing: 15) {
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
                            .background(FeiQUI.subtleFill, in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(FeiQUI.separator, lineWidth: 1)
                            }
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
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
                .animation(
                    .spring(response: 0.38, dampingFraction: 0.84),
                    value: messages.count
                )
            }
            .background {
                ZStack {
                    FeiQUI.chatBackground
                    LinearGradient(
                        colors: [FeiQUI.accent.opacity(0.045), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 190)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                }
            }
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
                        .foregroundStyle(isOutgoing ? FeiQUI.accent : .primary)
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
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(FeiQUI.cardBackground)
                            if isOutgoing {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                FeiQUI.accent,
                                                FeiQUI.accent.opacity(0.78)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(
                                isOutgoing ? Color.white.opacity(0.16) : FeiQUI.separator,
                                lineWidth: 1
                            )
                    }
                    .shadow(
                        color: Color.black.opacity(isOutgoing ? 0.13 : 0.06),
                        radius: 7,
                        y: 3
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("新消息", systemImage: "pencil.line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FeiQUI.accent)
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
                        .background(FeiQUI.subtleFill, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(FeiQUI.separator, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("选择表情")
                .popover(isPresented: $showingEmojiPicker, arrowEdge: .bottom) {
                    EmojiPickerView { emoji in
                        model.insertEmoji(emoji)
                        showingEmojiPicker = false
                    }
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)

                    if model.draft.isEmpty {
                        Text("输入消息…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                    .frame(minHeight: 52, maxHeight: 110)
                    .background(FeiQUI.inputBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(FeiQUI.separator, lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.035), radius: 4, y: 1)

                Button {
                    model.sendDraft()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(FeiQUI.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityLabel("发送")
            }
            Label("飞秋兼容表情使用 Windows 表情码，中文自动转换为 GB18030", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 26)
        .padding(.top, 13)
        .padding(.bottom, 16)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(FeiQUI.separator)
                .frame(height: 1)
        }
        .shadow(color: Color.black.opacity(0.07), radius: 10, y: -4)
    }
}

private struct EmptyChatView: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [FeiQUI.accent.opacity(0.18), Color.purple.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 98, height: 98)
                    .overlay {
                        Circle()
                            .stroke(FeiQUI.accent.opacity(0.18), lineWidth: 1)
                    }

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(FeiQUI.accent)
            }
            .shadow(color: FeiQUI.accent.opacity(0.16), radius: 14, y: 6)

            VStack(spacing: 8) {
                Text("开始一段局域网聊天")
                    .font(.title2.weight(.bold))
                Text(
                    model.isRunning
                        ? "选择左侧联系人，和同一局域网中的飞秋用户即时沟通"
                        : "局域网服务未启动，请先启动服务"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.refreshDiscovery()
            } label: {
                Label("刷新联系人", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(FeiQUI.separator, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 24, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(38)
    }
}
