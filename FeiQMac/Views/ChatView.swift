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
                    Divider()
                    MessageComposer()
                }
            } else if let peer = model.selectedPeer {
                VStack(spacing: 0) {
                    ChatHeader(peer: peer)
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
            GroupAvatar(size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                    .font(.title2.weight(.semibold))
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

            ChatHeaderActions {
                model.showingLogs = true
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(FeiQUI.chatBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FeiQUI.separator)
                .frame(height: 1)
        }
    }
}

private struct ChatHeader: View {
    @EnvironmentObject private var model: ChatViewModel
    let peer: FeiQPeer

    var body: some View {
        HStack(spacing: 12) {
            ContactAvatar(name: peer.displayName, isOnline: peer.isOnline, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    FeiQStatusDot(
                        color: model.isPeerTyping(peer.id)
                            ? FeiQUI.accent
                            : (peer.isOnline ? Color.green : Color.secondary)
                    )
                    Text(model.isPeerTyping(peer.id)
                        ? "对方正在输入…"
                        : (peer.isOnline ? "在线" : "最近离线"))
                        .fontWeight(.medium)
                    if !model.isPeerTyping(peer.id) {
                        Text("·")
                        Text(peer.detailText)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            ChatHeaderActions {
                model.showingLogs = true
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(FeiQUI.chatBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FeiQUI.separator)
                .frame(height: 1)
        }
    }
}

private struct ChatHeaderActions: View {
    let showLogs: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: showLogs) {
                Image(systemName: "ellipsis.bubble")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .help("查看网络日志")

            Menu {
                Button("网络日志", action: showLogs)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 30, height: 34)
            }
            .menuStyle(.borderlessButton)
            .help("更多操作")
        }
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
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

                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowTimeSeparator(at: index) {
                                MessageTimeSeparator(date: message.date)
                                    .transition(.opacity)
                            }

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
                    ImageAttachmentView(attachment: attachment)
                        .frame(maxWidth: 360, alignment: isOutgoing ? .trailing : .leading)
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

private struct ImageAttachmentView: View {
    let attachment: ChatAttachment
    @State private var image: NSImage?
    @State private var didAttemptLoad = false
    @State private var showingPreview = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 340, maxHeight: 280)
            } else if attachment.isAvailable && !didAttemptLoad {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 180, height: 120)
            } else {
                Label("图片文件不可用", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 180, height: 90)
            }
        }
        .background(
            FeiQUI.cardBackground.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(FeiQUI.separator, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 6, y: 3)
        .onAppear {
            guard image == nil, attachment.isAvailable else { return }
            image = NSImage(contentsOf: attachment.localURL)
            didAttemptLoad = true
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture {
            guard attachment.isAvailable else { return }
            showingPreview = true
        }
        .contextMenu {
            Button("放大查看") {
                showingPreview = true
            }
            Button("复制图片") {
                copyImageToPasteboard()
            }
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([attachment.localURL])
            }
        }
        .help("\(attachment.fileName) · \(attachment.fileSizeDescription)")
        .sheet(isPresented: $showingPreview) {
            ImagePreviewView(attachment: attachment)
        }
    }

    private func copyImageToPasteboard() {
        guard let image = image ?? NSImage(contentsOf: attachment.localURL),
              let tiff = image.tiffRepresentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
    }
}

private struct ImagePreviewView: View {
    let attachment: ChatAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var scale: CGFloat = 1
    @State private var scaleAtGestureStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAtGestureStart: CGSize = .zero
    @State private var rotation: Angle = .zero

    var body: some View {
        ZStack {
            Color.black

            if let image {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(
                            width: max(1, proxy.size.width - 84),
                            height: max(1, proxy.size.height - 112)
                        )
                        .scaleEffect(scale)
                        .rotationEffect(rotation)
                        .offset(offset)
                        .contentShape(Rectangle())
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(5, max(0.35, scaleAtGestureStart * value))
                                }
                                .onEnded { _ in
                                    scaleAtGestureStart = scale
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: offsetAtGestureStart.width + value.translation.width,
                                        height: offsetAtGestureStart.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    offsetAtGestureStart = offset
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if scale > 1.1 {
                                    resetImageTransform()
                                } else {
                                    scale = 2
                                    scaleAtGestureStart = 2
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(attachment.fileName)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        resetImageTransform()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .help("重置缩放和位置")

                    Button {
                        scale = min(5, scale + 0.25)
                        scaleAtGestureStart = scale
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("放大")

                    Button {
                        scale = max(0.35, scale - 0.25)
                        scaleAtGestureStart = scale
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("缩小")

                    Button {
                        rotation += .degrees(90)
                    } label: {
                        Image(systemName: "rotate.right")
                    }
                    .help("旋转 90 度")

                    Button {
                        copyImageToPasteboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("复制图片")

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([attachment.localURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("在 Finder 中显示")

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("关闭")
                }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial)

                Spacer()

                HStack {
                    Text("双击放大 · 拖动查看 · 触控板捏合缩放")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Text(attachment.fileSizeDescription)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .background(Color.black)
        .onAppear {
            image = NSImage(contentsOf: attachment.localURL)
        }
    }

    private func resetImageTransform() {
        scale = 1
        scaleAtGestureStart = 1
        offset = .zero
        offsetAtGestureStart = .zero
        rotation = .zero
    }

    private func copyImageToPasteboard() {
        guard let image = image ?? NSImage(contentsOf: attachment.localURL),
              let tiff = image.tiffRepresentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
    }
}

private struct MessageComposer: View {
    @EnvironmentObject private var model: ChatViewModel
    @State private var showingEmojiPicker = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.draftAttachments.isEmpty {
                DraftAttachmentStrip(attachments: model.draftAttachments) { attachmentID in
                    model.removeDraftAttachment(attachmentID)
                }
            }

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    PasteAwareTextEditor(
                        text: $model.draft,
                        onPasteImage: { data, fileName in
                            model.pasteImage(data, suggestedFileName: fileName)
                        }
                    )
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 150)

                    if model.draft.isEmpty && model.draftAttachments.isEmpty {
                        Text("输入消息")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 92, maxHeight: 150)
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

                    Image(systemName: "paperclip")
                        .help("文件功能暂未开放")
                        .foregroundStyle(.tertiary)

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
    }

    private var canSend: Bool {
        !model.isPreparingPastedImage
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.draftAttachments.isEmpty)
    }
}

private struct DraftAttachmentStrip: View {
    let attachments: [ChatAttachment]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        ImageAttachmentView(attachment: attachment)
                            .frame(width: 88, height: 68)
                            .clipped()

                        Button {
                            onRemove(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(.black.opacity(0.65), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                        .help("移除这张图片")
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 76)
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
