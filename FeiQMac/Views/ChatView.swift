//
//  ChatView.swift
//  FeiQMac
//
//  负责单聊与群聊详情页，包括聊天头部、消息列表、消息气泡、输入区和空状态。
//

import SwiftUI
import AppKit

struct ChatDetailView: View {
    @EnvironmentObject private var model: ChatViewModel
    @AppStorage("chat.detailsCollapsed") private var isPeerSidebarCollapsed = true

    var body: some View {
        Group {
            if let group = model.selectedGroup {
                VStack(spacing: 0) {
                    GroupChatHeader(group: group)
                    MessageList(
                        conversationID: group.id,
                        conversationTitle: group.displayName,
                        peer: nil
                    )
                    .id(group.id)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .layoutPriority(1)
                    Divider()
                    MessageComposer()
                }
            } else if let peer = model.selectedPeer {
                VStack(spacing: 0) {
                    ChatHeader(peer: peer, isShowingDetails: !isPeerSidebarCollapsed) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isPeerSidebarCollapsed.toggle()
                        }
                    }
                    HStack(spacing: 0) {
                        MessageList(
                            conversationID: peer.id,
                            conversationTitle: peer.displayName,
                            peer: peer
                        )
                        .id(peer.id)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .layoutPriority(1)

                        if !isPeerSidebarCollapsed {
                            Divider().opacity(0.5)
                                PeerContextSidebar(peer: peer) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isPeerSidebarCollapsed = true
                                    }
                                }
                                .frame(width: 238)
                                .clipped()
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    Divider()
                    MessageComposer()
                }
            } else {
                EmptyChatView()
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(FeiQUI.chatBackground)
        .alert("图片删除失败", isPresented: Binding(
            get: { model.imageDeletionError != nil },
            set: { if !$0 { model.imageDeletionError = nil } }
        )) {
            Button("好", role: .cancel) { model.imageDeletionError = nil }
        } message: {
            Text(model.imageDeletionError ?? "")
        }
    }
}


private struct PeerContextSidebar: View {
    let peer: FeiQPeer
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("联系人资料")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("收起右侧栏")
            }

            PeerProfileCard(peer: peer)

            Spacer(minLength: 4)

            ReceivedFilesPanel(conversationID: peer.id)
                .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 238)
        .frame(maxHeight: .infinity)
        .background(FeiQUI.listBackground)
    }
}

private struct CollapsedPeerSidebar: View {
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onExpand) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("展开右侧栏")

            Spacer()
        }
        .padding(.top, 12)
        .frame(width: 40)
        .frame(maxHeight: .infinity)
        .background(FeiQUI.listBackground)
    }
}

private struct PeerProfileCard: View {
    let peer: FeiQPeer

    private static let lastSeenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM月dd日 HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ContactAvatar(name: peer.displayName, isOnline: peer.isOnline, size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(peer.displayName)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        FeiQStatusDot(color: peer.isOnline ? .green : .secondary, size: 6)
                        Text(peer.isOnline ? "在线" : "最近离线")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            PeerProfileValue(title: "主机名", value: peer.hostName)
            PeerProfileValue(title: "IP 地址", value: peer.ipAddress)
            if !peer.group.isEmpty {
                PeerProfileValue(title: "分组", value: peer.group)
            }
            PeerProfileValue(
                title: "最后发现",
                value: Self.lastSeenFormatter.string(from: peer.lastSeen)
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feiQSurface(fill: FeiQUI.cardBackground, cornerRadius: 13, shadow: true)
    }
}

private struct PeerProfileValue: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)
            Text(value.isEmpty ? "未提供" : value)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.caption)
    }
}

private struct ReceivedFilesPanel: View {
    @EnvironmentObject private var model: ChatViewModel
    let conversationID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.document")
                    .foregroundStyle(FeiQUI.accent)
                Text("接收文件")
                    .font(.subheadline.weight(.semibold))
                Text("\(model.receivedFiles(for: conversationID).count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if model.receivedFiles(for: conversationID).isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("暂未收到文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(model.receivedFiles(for: conversationID)) { file in
                            ReceivedFileRow(file: file)
                        }
                    }
                }
                .hiddenScrollIndicators()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .feiQSurface(fill: FeiQUI.cardBackground, cornerRadius: 13, shadow: true)
    }
}

private struct ReceivedFileRow: View {
    let file: ChatReceivedFile
    @State private var showingPreview = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        Button {
            if file.attachment.isAvailable {
                showingPreview = true
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([file.attachment.localURL])
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: file.attachment.systemImageName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FeiQUI.accent)
                    .frame(width: 28, height: 28)
                    .background(FeiQUI.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.attachment.fileName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(file.attachment.fileSizeDescription) · \(Self.dateFormatter.string(from: file.receivedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .help(file.attachment.isAvailable ? "预览 \(file.attachment.fileName)" : "在 Finder 中显示文件")
        .sheet(isPresented: $showingPreview) {
            if file.attachment.kind == .file {
                FilePreviewView(attachment: file.attachment)
            } else {
                ImagePreviewView(attachment: file.attachment)
            }
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

    private var latestMessageID: UUID? {
        messages.last?.id
    }

    private var latestMessageAnchorID: String {
        "latest-message-(conversationID)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
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

                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowTimeSeparator(at: index) {
                                MessageTimeSeparator(date: message.date)
                                    .transition(.opacity)
                            }

                            MessageBubble(
                                conversationID: conversationID,
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

                    // 固定底部锚点比直接定位最后一条消息更稳定，避免
                    // LazyVStack 首次布局或进入动画期间定位失效。
                    Color.clear
                        .frame(height: 1)
                        .id(latestMessageAnchorID)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
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
            .hiddenScrollIndicators()
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
                    scrollToLatestWhenLaidOut(using: proxy, animated: false)
                }
                lastRenderedMessageID = messages.last?.id
            }
            .onChange(of: latestMessageID) { _, _ in
                guard showingMessages,
                      didFinishInitialLoad,
                      !model.isLoadingMessages else {
                    return
                }
                let latestMessageID = messages.last?.id
                guard latestMessageID != lastRenderedMessageID else { return }
                lastRenderedMessageID = latestMessageID
                scrollToLatestWhenLaidOut(using: proxy, animated: true)
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
        scrollToLatestWhenLaidOut(using: proxy, animated: false)

        DispatchQueue.main.async {
            if mode == .instant {
                showingMessages = true
            } else {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                    showingMessages = true
                }
            }

            // 进入动画改变了消息的可见状态，再补一次无动画定位，避免
            // SwiftUI 在动画结束后把 ScrollView 恢复到默认顶部位置。
            DispatchQueue.main.async {
                scrollToLatest(using: proxy, animated: false)
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
        guard !messages.isEmpty else { return }

        if animated {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                proxy.scrollTo(latestMessageAnchorID, anchor: .bottom)
            }
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(latestMessageAnchorID, anchor: .bottom)
        }
    }

    private func scrollToLatestWhenLaidOut(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        scrollToLatest(using: proxy, animated: animated)
        DispatchQueue.main.async {
            scrollToLatest(using: proxy, animated: animated)
        }
    }

    private func shouldShowTimeSeparator(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = messages[index - 1].date
        let current = messages[index].date
        let calendar = Calendar.current
        if !calendar.isDate(previous, inSameDayAs: current) {
            return true
        }
        return current.timeIntervalSince(previous) >= 5 * 60
    }
}

private struct MessageTimeSeparator: View {
    let date: Date
    @State private var showingFullDate = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
        return formatter
    }()

    var body: some View {
        Button {
            showingFullDate.toggle()
        } label: {
            Text(showingFullDate
                ? Self.fullDateFormatter.string(from: date)
                : Self.timeFormatter.string(from: date))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(showingFullDate ? "点击显示简略时间" : "点击查看完整日期和时间")
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var model: ChatViewModel
    let conversationID: String
    let message: ChatMessage
    let conversationName: String
    let peer: FeiQPeer?

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
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520, alignment: isOutgoing ? .trailing : .leading)

                if !model.displayText(for: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(model.displayText(for: message))
                        .font(.body)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, isOutgoing ? 15 : 22)
                        .padding(.trailing, isOutgoing ? 22 : 15)
                        .padding(.vertical, 10)
                        .background(
                            FeiQMessageBubbleShape(isOutgoing: isOutgoing)
                                .fill(isOutgoing ? FeiQUI.outgoingBubble : FeiQUI.incomingBubble)
                        )
                        .overlay {
                            FeiQMessageBubbleShape(isOutgoing: isOutgoing)
                                .stroke(
                                    isOutgoing
                                        ? FeiQUI.outgoingBubble.opacity(0.55)
                                        : FeiQUI.separator,
                                    lineWidth: 1
                                )
                        }
                        .shadow(
                            color: Color.black.opacity(0.045),
                            radius: 4,
                            y: 2
                        )
                        .frame(maxWidth: 520, alignment: isOutgoing ? .trailing : .leading)
                        .contextMenu {
                            Button("复制文本") {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(model.displayText(for: message), forType: .string)
                            }
                        }
                }

                ForEach(message.attachments) { attachment in
                    if attachment.kind == .image {
                        ImageAttachmentView(attachment: attachment) {
                            model.deleteImage(attachment.id, from: message, conversationID: conversationID)
                        }
                            .frame(maxWidth: 360, alignment: isOutgoing ? .trailing : .leading)
                    } else {
                        FileAttachmentView(attachment: attachment)
                            .frame(maxWidth: 380, alignment: isOutgoing ? .trailing : .leading)
                    }
                }
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

}

private struct FeiQMessageBubbleShape: Shape {
    let isOutgoing: Bool

    func path(in rect: CGRect) -> Path {
        let tailWidth: CGFloat = 8
        let bubbleRect = isOutgoing
            ? CGRect(x: 0, y: 0, width: max(0, rect.width - tailWidth), height: rect.height)
            : CGRect(x: tailWidth, y: 0, width: max(0, rect.width - tailWidth), height: rect.height)
        var path = Path()
        path.addRoundedRect(in: bubbleRect, cornerSize: CGSize(width: 13, height: 13))

        let tailY = min(max(18, rect.height * 0.48), max(18, rect.height - 9))
        if isOutgoing {
            path.move(to: CGPoint(x: bubbleRect.maxX - 1, y: tailY - 7))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: tailY),
                control: CGPoint(x: rect.maxX - 1, y: tailY - 1)
            )
            path.addQuadCurve(
                to: CGPoint(x: bubbleRect.maxX - 1, y: tailY + 7),
                control: CGPoint(x: rect.maxX - 1, y: tailY + 1)
            )
        } else {
            path.move(to: CGPoint(x: bubbleRect.minX + 1, y: tailY - 7))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: tailY),
                control: CGPoint(x: rect.minX + 1, y: tailY - 1)
            )
            path.addQuadCurve(
                to: CGPoint(x: bubbleRect.minX + 1, y: tailY + 7),
                control: CGPoint(x: rect.minX + 1, y: tailY + 1)
            )
        }
        return path
    }
}


private struct MessageComposer: View {
    @EnvironmentObject private var model: ChatViewModel
    @State private var showingEmojiPicker = false
    @AppStorage("chat.composer.editorHeight") private var savedEditorHeight = 112.0
    @State private var editorHeight: CGFloat = 112
    @State private var resizeStartHeight: CGFloat?

    private let minimumEditorHeight: CGFloat = 78
    private let maximumEditorHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            if !model.draftAttachments.isEmpty {
                DraftAttachmentStrip(attachments: model.draftAttachments) { attachmentID in
                    model.removeDraftAttachment(attachmentID)
                }
            }

            VStack(spacing: 0) {
                ComposerResizeHandle(
                    onChanged: {
                        resizeStartHeight = editorHeight
                    },
                    onChangedTranslation: { translation in
                        let startHeight = resizeStartHeight ?? editorHeight
                        let proposedHeight = startHeight - translation
                        editorHeight = min(
                            max(proposedHeight, minimumEditorHeight),
                            maximumEditorHeight
                        )
                    },
                    onEnded: {
                        savedEditorHeight = Double(editorHeight)
                        resizeStartHeight = nil
                    }
                )

                ZStack(alignment: .topLeading) {
                    PasteAwareTextEditor(
                        text: $model.draft,
                        onPasteImage: { data, fileName in
                            model.pasteImage(data, suggestedFileName: fileName)
                        }
                    )
                        .font(.body)
                        .frame(maxWidth: .infinity)
                        .frame(height: editorHeight)

                    if model.draft.isEmpty && model.draftAttachments.isEmpty {
                        Text("输入消息")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: editorHeight)
                .onChange(of: model.draft) { _, _ in
                    model.draftDidChange()
                }

                Divider()
                    .opacity(0.7)

                HStack(spacing: 14) {
                    Button {
                        showingEmojiPicker.toggle()
                    } label: {
                        Image(systemName: "face.smiling")
                    }
                    .popover(isPresented: $showingEmojiPicker, arrowEdge: .bottom) {
                        EmojiPickerView { emoji in
                            model.insertEmoji(emoji)
                            showingEmojiPicker = false
                        }
                    }
                    .help("选择表情")

                    Button {
                        model.chooseAndSendImage()
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .help("发送图片")
                    .disabled(model.selectedConversationID == nil)

                    Button {
                        model.captureScreenshot()
                    } label: {
                        if model.isCapturingScreenshot {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "camera.viewfinder")
                        }
                    }
                    .help("截取屏幕并添加到输入框")
                    .disabled(
                        model.selectedConversationID == nil
                            || model.isCapturingScreenshot
                            || model.isPreparingPastedImage
                            || model.isPreparingAttachment
                    )

                    Button {
                        model.chooseAndAddFiles()
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .help("添加文件")
                    .disabled(model.selectedConversationID == nil || model.isPreparingAttachment)

                    if model.isPreparingAttachment {
                        ProgressView()
                            .controlSize(.small)
                            .help("正在准备文件")
                    }

                    Spacer()

                    Text("⌘↩ 发送")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Button {
                        model.sendDraft()
                    } label: {
                        Text("发送")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(canSend ? .white : .secondary)
                            .padding(.horizontal, 18)
                            .frame(height: 32)
                            .background(
                                canSend ? FeiQUI.accent : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSend)
                    .accessibilityLabel("发送")
                }
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(FeiQUI.composerBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(FeiQUI.separator, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(FeiQUI.chatBackground)
        .onAppear {
            editorHeight = min(
                max(CGFloat(savedEditorHeight), minimumEditorHeight),
                maximumEditorHeight
            )
        }
    }

    private var canSend: Bool {
        !model.isPreparingPastedImage
            && !model.isPreparingAttachment
            && !model.isCapturingScreenshot
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.draftAttachments.isEmpty)
    }
}

/// 输入框顶部的连续调整手柄。向上拖动扩大编辑区，向下拖动缩小编辑区。
private struct ComposerResizeHandle: View {
    let onChanged: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnded: () -> Void
    @State private var isHovering = false
    @State private var hasStartedDragging = false

    init(
        onChanged: @escaping () -> Void,
        onChangedTranslation: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void
    ) {
        self.onChanged = onChanged
        self.onDrag = onChangedTranslation
        self.onEnded = onEnded
    }

    var body: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(isHovering ? FeiQUI.accent.opacity(0.65) : Color.secondary.opacity(0.28))
                .frame(width: 34, height: 4)
            Spacer()
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !hasStartedDragging {
                        hasStartedDragging = true
                        onChanged()
                    }
                    onDrag(value.translation.height)
                }
                .onEnded { _ in
                    hasStartedDragging = false
                    onEnded()
                }
        )
        .accessibilityElement()
        .accessibilityLabel("调整输入框高度")
        .accessibilityHint("向上或向下拖动以调整输入框高度")
    }
}

private struct DraftAttachmentStrip: View {
    let attachments: [ChatAttachment]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    DraftAttachmentTile(attachment: attachment) {
                        onRemove(attachment.id)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .hiddenScrollIndicators()
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(height: 122)
        .background(FeiQUI.cardBackground.opacity(0.42))
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.65)
        }
    }
}

private struct DraftAttachmentTile: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    private var tileWidth: CGFloat {
        attachment.kind == .image ? 168 : 300
    }

    private var tileHeight: CGFloat {
        attachment.kind == .image ? 104 : 82
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image {
                    ImageAttachmentView(attachment: attachment, onDelete: onRemove)
                } else {
                    FileAttachmentView(attachment: attachment)
                }
            }
            .frame(width: tileWidth, height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 21, height: 21)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
            .padding(5)
            .help("移除附件")
        }
        .frame(width: tileWidth, height: tileHeight)
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
