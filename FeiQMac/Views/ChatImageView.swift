//
//  ChatImageView.swift
//  FeiQMac
//
//  聊天图片的缩略展示、复制、删除确认及放大预览交互。
//

import AppKit
import SwiftUI

struct ImageAttachmentView: View {
    let attachment: ChatAttachment
    let onDelete: () -> Void
    var onPreview: ((ChatAttachment) -> Void)? = nil
    var cardSize: CGSize? = nil
    @State private var image: NSImage?
    @State private var didAttemptLoad = false
    @State private var showingPreview = false
    @State private var showingDeleteConfirmation = false
    @State private var isDisintegrating = false
    @State private var deletionOpacity = 1.0

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: cardSize?.width ?? 340, maxHeight: cardSize?.height ?? 280)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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
        .opacity(deletionOpacity)
        .overlay {
            if isDisintegrating {
                DisintegrationEffectView(
                    image: image ?? NSImage(contentsOf: attachment.localURL),
                    duration: 0.78,
                    onFinished: completeDeletion
                )
            }
        }
        .onAppear {
            guard image == nil, attachment.isAvailable else { return }
            image = NSImage(contentsOf: attachment.localURL)
            didAttemptLoad = true
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture {
            openPreview()
        }
        .contextMenu {
            Button("放大查看") {
                openPreview()
            }
            Button("复制图片") {
                copyImageToPasteboard()
            }
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([attachment.localURL])
            }
            Divider()
            Button("删除图片…", role: .destructive) {
                showingDeleteConfirmation = true
            }
        }
        .alert("删除这张图片？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                beginDeletion()
            }
        } message: {
            Text("从此消息中删除图片，同时清理应用保存的本地副本；不会删除原始图片或撤回对方的消息。如果其他消息仍引用此副本，会在最后一次引用删除后清理。")
        }
        .help("\(attachment.fileName) · \(attachment.fileSizeDescription)")
        .sheet(isPresented: $showingPreview) {
            ImagePreviewView(attachment: attachment)
        }
    }

    private func openPreview() {
        guard !isDisintegrating else { return }
        if let onPreview {
            onPreview(attachment)
        } else {
            showingPreview = true
        }
    }

    private func copyImageToPasteboard() {
        guard let image = image ?? NSImage(contentsOf: attachment.localURL),
              let tiff = image.tiffRepresentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
    }

    private func beginDeletion() {
        guard !isDisintegrating else { return }
        showingPreview = false
        isDisintegrating = true
        withAnimation(.easeIn(duration: 0.72)) {
            deletionOpacity = 0
        }
    }

    private func completeDeletion() {
        guard isDisintegrating else { return }
        onDelete()

        // 删除失败时保留当前视图，避免图片永久停留在半透明状态。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard isDisintegrating else { return }
            isDisintegrating = false
            deletionOpacity = 1
        }
    }
}

struct ImageAlbumView: View {
    let attachments: [ChatAttachment]
    let onDelete: (String) -> Void
    var onPreview: ((ChatAttachment) -> Void)? = nil

    @State private var currentIndex = 0
    @State private var currentImage: NSImage?
    @State private var showingPreview = false
    @State private var showingDeleteConfirmation = false
    @State private var frontOffsetX: CGFloat = 0
    @State private var frontRotation: Double = 0
    @State private var frontOpacity = 1.0
    @State private var isTransitioning = false
    @State private var transitionDirection = 1
    @State private var isDisintegrating = false
    @State private var deletionOpacity = 1.0
    @State private var deletingAttachmentID: String?
    @State private var dragOffsetX: CGFloat = 0
    @State private var boundaryMessage: String?
    @State private var boundaryFeedbackGeneration = 0

    private let cardSize = CGSize(width: 300, height: 258)
    private let stackOffset = CGSize(width: 11, height: -7)
    private let stackDepth = 2

    private var canvasSize: CGSize {
        CGSize(
            width: cardSize.width + CGFloat(stackDepth) * stackOffset.width + 12,
            height: cardSize.height + abs(stackOffset.height) * CGFloat(stackDepth) + 12
        )
    }

    private var visibleAttachments: [ChatAttachment] {
        Array(attachments.prefix(ChatAttachmentGroup.maximumImageCount))
    }

    private var currentAttachment: ChatAttachment? {
        guard !visibleAttachments.isEmpty else { return nil }
        return visibleAttachments[min(max(currentIndex, 0), visibleAttachments.count - 1)]
    }

    private var backAttachments: [ChatAttachment] {
        if transitionDirection > 0 {
            let nextAttachments = Array(visibleAttachments.dropFirst(currentIndex + 1).prefix(2))
            if !nextAttachments.isEmpty {
                return nextAttachments
            }

            // 到最后一张时没有后续图片，改用前面的图片维持折叠卡片外观。
            return Array(visibleAttachments.prefix(currentIndex).suffix(2).reversed())
        }

        let previousAttachments = Array(visibleAttachments.prefix(currentIndex).suffix(2).reversed())
        if !previousAttachments.isEmpty {
            return previousAttachments
        }

        // 返回第一张时没有前置图片，改用后面的图片作为折叠层。
        return Array(visibleAttachments.dropFirst(currentIndex + 1).prefix(2))
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                stackedBackCards
                albumCanvas
            }
            .frame(width: canvasSize.width, height: canvasSize.height)

            photoCountLabel
                .frame(width: canvasSize.width)
        }
        .frame(width: canvasSize.width)
        .contentShape(Rectangle())
        .onAppear {
            normalizeIndex()
            loadCurrentImage()
        }
        .onChange(of: attachments.map(\.id)) { _, attachmentIDs in
            normalizeIndex()
            loadCurrentImage()

            if let deletingAttachmentID,
               !attachmentIDs.contains(deletingAttachmentID) {
                resetDeletionAnimation()
            }
        }
        .onChange(of: currentIndex) { _, _ in
            loadCurrentImage()
        }
        .contextMenu {
            Button("放大查看") {
                openPreview()
            }
            .disabled(currentAttachment == nil)

            Button("复制当前图片") {
                copyCurrentImageToPasteboard()
            }
            .disabled(currentImage == nil)

            Button("在 Finder 中显示") {
                guard let currentAttachment else { return }
                NSWorkspace.shared.activateFileViewerSelecting([currentAttachment.localURL])
            }
            .disabled(currentAttachment?.isAvailable != true)

            Divider()

            Button("删除当前图片…", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(currentAttachment == nil)
        }
        .alert("删除当前图片？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                beginCurrentDeletion()
            }
        } message: {
            Text("只从这条消息中删除当前图片，并清理应用保存的本地副本。其余 \(max(0, visibleAttachments.count - 1)) 张图片会保留。")
        }
        .sheet(isPresented: $showingPreview) {
            if let currentAttachment {
                ImagePreviewView(attachment: currentAttachment)
            }
        }
    }

    private var photoCountLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 11, weight: .medium))
            Text(
                boundaryMessage
                    ?? "第 \(currentIndex + 1) 张 · 共 \(visibleAttachments.count) 张照片"
            )
                .monospacedDigit()
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(boundaryMessage == nil ? Color.secondary : FeiQUI.accent)
        .animation(.easeInOut(duration: 0.18), value: boundaryMessage)
        .accessibilityLabel("照片进度")
        .accessibilityValue(
            "第 \(currentIndex + 1) 张，共 \(visibleAttachments.count) 张照片"
        )
    }

    private var stackedBackCards: some View {
        ZStack {
            ForEach(Array(backAttachments.enumerated()), id: \.element.id) { offset, attachment in
                AlbumImageLayer(attachment: attachment, size: cardSize)
                    .offset(
                        x: CGFloat(offset + 1) * stackOffset.width,
                        y: CGFloat(offset + 1) * stackOffset.height
                    )
                    .rotationEffect(.degrees(Double(offset + 1) * 1.4))
                    .scaleEffect(1 - CGFloat(offset) * 0.018)
                    .opacity(0.96 - Double(offset) * 0.12)
                    .zIndex(Double(backAttachments.count - offset))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private var albumCanvas: some View {
        ZStack {
            AlbumImageLayer(
                attachment: currentAttachment,
                image: currentImage,
                size: cardSize
            )
            .offset(x: frontOffsetX + dragOffsetX)
            .rotationEffect(.degrees(frontRotation))
            .opacity(frontOpacity * deletionOpacity)
            .zIndex(2)

            if isDisintegrating {
                DisintegrationEffectView(
                    image: currentImage,
                    duration: 0.78,
                    onFinished: completeCurrentDeletion
                )
                .frame(width: cardSize.width, height: cardSize.height)
                .zIndex(3)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .contentShape(Rectangle())
        .onTapGesture {
            openPreview()
        }
        .gesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard !isTransitioning, !isDisintegrating else { return }
                    guard isAtBoundary(for: value.translation.width) else {
                        dragOffsetX = 0
                        return
                    }
                    dragOffsetX = rubberBandOffset(for: value.translation.width)
                }
                .onEnded { value in
                    guard !isTransitioning, !isDisintegrating else { return }
                    let threshold: CGFloat = 40
                    if value.translation.width < -threshold {
                        if currentIndex < visibleAttachments.count - 1 {
                            movePage(by: 1)
                        } else {
                            showBoundaryFeedback(direction: 1)
                        }
                    } else if value.translation.width > threshold {
                        if currentIndex > 0 {
                            movePage(by: -1)
                        } else {
                            showBoundaryFeedback(direction: -1)
                        }
                    } else {
                        withAnimation(.interpolatingSpring(stiffness: 260, damping: 22)) {
                            dragOffsetX = 0
                        }
                    }
                }
        )
    }

    private func isAtBoundary(for translation: CGFloat) -> Bool {
        (translation < 0 && currentIndex >= visibleAttachments.count - 1)
            || (translation > 0 && currentIndex == 0)
    }

    private func rubberBandOffset(for translation: CGFloat) -> CGFloat {
        let resistance: CGFloat = 54
        return translation / (1 + abs(translation) / resistance)
    }

    private func showBoundaryFeedback(direction: Int) {
        let message = direction > 0 ? "已经是最后一张" : "已经是第一张"
        boundaryFeedbackGeneration += 1
        let generation = boundaryFeedbackGeneration

        withAnimation(.interpolatingSpring(stiffness: 260, damping: 18)) {
            dragOffsetX = 0
            boundaryMessage = message
        }

        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard boundaryFeedbackGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                boundaryMessage = nil
            }
        }
    }

    private func normalizeIndex() {
        currentIndex = min(max(currentIndex, 0), max(0, visibleAttachments.count - 1))
    }

    private func movePage(by offset: Int) {
        guard !isTransitioning else { return }
        let newIndex = min(
            max(currentIndex + offset, 0),
            max(0, visibleAttachments.count - 1)
        )
        guard newIndex != currentIndex else { return }

        let direction = offset > 0 ? 1 : -1
        transitionDirection = direction
        isTransitioning = true
        dragOffsetX = 0
        boundaryMessage = nil
        withAnimation(.easeInOut(duration: 0.22)) {
            frontOffsetX = direction > 0 ? -cardSize.width * 0.72 : cardSize.width * 0.72
            frontRotation = direction > 0 ? -4 : 4
            frontOpacity = 0.08
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(nil) {
                currentIndex = newIndex
                loadCurrentImage()
                frontOffsetX = direction > 0 ? cardSize.width * 0.24 : -cardSize.width * 0.24
                frontRotation = direction > 0 ? 2 : -2
                frontOpacity = 0.1
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                frontOffsetX = 0
                frontRotation = 0
                frontOpacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                isTransitioning = false
            }
        }
    }

    private func loadCurrentImage() {
        guard let currentAttachment else {
            currentImage = nil
            return
        }
        currentImage = currentAttachment.isAvailable
            ? NSImage(contentsOf: currentAttachment.localURL)
            : nil
    }

    private func openPreview() {
        guard !isDisintegrating, let currentAttachment else { return }
        if let onPreview {
            onPreview(currentAttachment)
        } else {
            showingPreview = true
        }
    }

    private func copyCurrentImageToPasteboard() {
        guard let currentImage,
              let tiff = currentImage.tiffRepresentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
    }

    private func beginCurrentDeletion() {
        guard let currentAttachment, !isDisintegrating else { return }
        deletingAttachmentID = currentAttachment.id
        showingPreview = false
        isDisintegrating = true
        withAnimation(.easeIn(duration: 0.72)) {
            deletionOpacity = 0
        }
    }

    private func completeCurrentDeletion() {
        guard isDisintegrating,
              let deletingAttachmentID else { return }
        onDelete(deletingAttachmentID)

        // 成功删除后由 attachments 变化触发重置；失败时使用兜底恢复交互。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard isDisintegrating else { return }
            resetDeletionAnimation()
        }
    }

    private func resetDeletionAnimation() {
        isDisintegrating = false
        deletionOpacity = 1
        deletingAttachmentID = nil
    }
}

private struct AlbumImageLayer: View {
    let attachment: ChatAttachment?
    var image: NSImage? = nil
    let size: CGSize
    @State private var loadedImage: NSImage?

    private var resolvedImage: NSImage? {
        image ?? loadedImage
    }

    var body: some View {
        ZStack {
            if let resolvedImage {
                Image(nsImage: resolvedImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else if attachment?.isAvailable == true {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("图片不可用", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(
            resolvedImage == nil ? FeiQUI.cardBackground.opacity(0.88) : Color.clear,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(resolvedImage == nil ? 0.22 : 0.34), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.16), radius: 9, y: 5)
        .onAppear {
            guard image == nil, let attachment, attachment.isAvailable else { return }
            loadedImage = NSImage(contentsOf: attachment.localURL)
        }
        .onChange(of: attachment?.id) { _, _ in
            guard image == nil, let attachment, attachment.isAvailable else {
                loadedImage = nil
                return
            }
            loadedImage = NSImage(contentsOf: attachment.localURL)
        }
    }
}

private struct DisintegrationParticle {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let color: Color
    let driftX: CGFloat
    let driftY: CGFloat
    let rotation: CGFloat
    let delay: CGFloat
    let isEmber: Bool
}

/// 将图片采样成彩色碎片，并在删除期间向上飘散成焚化效果。
private struct DisintegrationEffectView: View {
    let image: NSImage?
    let duration: TimeInterval
    let onFinished: () -> Void

    @State private var startedAt = Date()
    @State private var particles: [DisintegrationParticle] = []
    @State private var didFinish = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                drawParticles(
                    in: &context,
                    size: size,
                    progress: progress(at: timeline.date)
                )
            }
        }
        .onAppear {
            particles = Self.makeParticles(from: image)
            startedAt = Date()
            didFinish = false

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                guard !didFinish else { return }
                didFinish = true
                onFinished()
            }
        }
        .allowsHitTesting(false)
    }

    private func progress(at date: Date) -> CGFloat {
        guard duration > 0 else { return 1 }
        return min(
            1,
            max(0, CGFloat(date.timeIntervalSince(startedAt) / duration))
        )
    }

    private func drawParticles(
        in context: inout GraphicsContext,
        size: CGSize,
        progress: CGFloat
    ) {
        guard progress > 0 else { return }

        for particle in particles {
            let particleProgress = min(
                1,
                max(0, (progress - particle.delay) / (1 - particle.delay))
            )
            guard particleProgress > 0 else { continue }

            let easedProgress = 1 - pow(1 - Double(particleProgress), 1.12)
            let fadeIn = min(1, particleProgress / 0.14)
            let fadeOut = particleProgress > 0.64
                ? max(0, (1 - particleProgress) / 0.36)
                : 1
            let opacity = fadeIn * fadeOut

            var particleContext = context
            particleContext.opacity = opacity
            particleContext.translateBy(
                x: particle.x * size.width + particle.driftX * easedProgress,
                y: particle.y * size.height + particle.driftY * easedProgress
            )
            particleContext.rotate(
                by: .radians(Double(particle.rotation) * easedProgress)
            )

            let fragmentRect = CGRect(
                x: -particle.width / 2,
                y: -particle.height / 2,
                width: particle.width,
                height: particle.height
            )

            if particle.isEmber {
                particleContext.fill(
                    Path(ellipseIn: fragmentRect),
                    with: .color(particle.color)
                )
                particleContext.fill(
                    Path(ellipseIn: fragmentRect.insetBy(dx: -1.4, dy: -1.4)),
                    with: .color(Color.orange.opacity(0.22 * opacity))
                )
            } else {
                particleContext.fill(
                    Path(
                        roundedRect: fragmentRect,
                        cornerRadius: min(particle.width, particle.height) * 0.24
                    ),
                    with: .color(particle.color)
                )
            }
        }
    }

    private static func makeParticles(from image: NSImage?) -> [DisintegrationParticle] {
        let bitmap: NSBitmapImageRep? = {
            guard let image, let tiffData = image.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiffData)
        }()

        let columns = 22
        let rows = 16
        let pixelWidth = max(1, bitmap?.pixelsWide ?? 1)
        let pixelHeight = max(1, bitmap?.pixelsHigh ?? 1)

        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let normalizedX = (CGFloat(column) + 0.5) / CGFloat(columns)
                let normalizedY = (CGFloat(row) + 0.5) / CGFloat(rows)
                let pixelX = min(
                    pixelWidth - 1,
                    max(0, Int(normalizedX * CGFloat(pixelWidth)))
                )
                let pixelY = min(
                    pixelHeight - 1,
                    max(0, Int(normalizedY * CGFloat(pixelHeight)))
                )
                let sampledColor = Self.color(
                    from: bitmap?.colorAt(x: pixelX, y: pixelY)
                )

                return DisintegrationParticle(
                    x: normalizedX,
                    y: normalizedY,
                    width: CGFloat.random(in: 2.2...5.5),
                    height: CGFloat.random(in: 2.0...7.0),
                    color: sampledColor,
                    driftX: CGFloat.random(in: -24...24),
                    driftY: CGFloat.random(in: -92 ... -22),
                    rotation: CGFloat.random(in: -1.2...1.2),
                    delay: CGFloat.random(in: 0...0.18),
                    isEmber: Int.random(in: 0...9) == 0
                )
            }
        }
    }

    private static func color(from nsColor: NSColor?) -> Color {
        guard let rgbColor = nsColor?.usingColorSpace(.deviceRGB) else {
            return Color(red: 0.72, green: 0.75, blue: 0.82)
        }

        return Color(
            red: Double(rgbColor.redComponent),
            green: Double(rgbColor.greenComponent),
            blue: Double(rgbColor.blueComponent),
            opacity: Double(rgbColor.alphaComponent)
        )
    }
}

@MainActor
struct ImagePreviewView: View {
    @StateObject private var model: ConversationImagePreviewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var scaleAtGestureStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAtGestureStart: CGSize = .zero
    @State private var rotation: Angle = .zero

    init(model: ConversationImagePreviewModel) {
        _model = StateObject(wrappedValue: model)
    }

    init(attachment: ChatAttachment) {
        _model = StateObject(wrappedValue: ConversationImagePreviewModel(attachment: attachment))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                previewToolbar
                if model.historyError != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("历史图片加载失败，当前仅显示已加载的图片")
                        Spacer()
                        Button("重试") { model.reloadHistory() }
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .help(model.historyError ?? "")
                }
                previewCanvas
                previewFooter
            }
            .frame(minWidth: 720, minHeight: 540)
            .background(Color.black.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.20), radius: 28, y: 12)
        }
        .frame(minWidth: 720, minHeight: 540)
        .background(.clear)
        .presentationBackground(.clear)
        .onAppear {
            model.start()
        }
        .onChange(of: model.currentImage?.id) { _, _ in resetImageTransform() }
    }

    private var previewToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .foregroundStyle(FeiQUI.accent)

            Text(model.currentImage?.attachment.fileName ?? "图片预览")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if model.conversationID != nil {
                Text("\(model.currentIndex.map { $0 + 1 } ?? 0) / \(model.images.count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityLabel("第 \(model.currentIndex.map { $0 + 1 } ?? 0) 张，共 \(model.images.count) 张")
                if model.isLoadingHistory {
                    ProgressView().controlSize(.small).tint(.white)
                        .help("正在读取此会话的历史图片")
                }
            }

            Spacer()

            Button {
                resetImageTransform()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("适应窗口，重置缩放和位置")
            .accessibilityLabel("图片适应窗口")

            Button {
                scale = min(5, scale + 0.25)
                scaleAtGestureStart = scale
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("放大")
            .disabled(model.image == nil)

            Button {
                scale = max(0.35, scale - 0.25)
                scaleAtGestureStart = scale
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("缩小")
            .disabled(model.image == nil)

            Button {
                rotation += .degrees(90)
            } label: {
                Image(systemName: "rotate.right")
            }
            .help("旋转 90 度")
            .disabled(model.image == nil)

            Button {
                copyImageToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("复制图片")
            .disabled(model.image == nil)

            Button {
                guard let attachment = model.currentImage?.attachment else { return }
                NSWorkspace.shared.activateFileViewerSelecting([attachment.localURL])
            } label: {
                Image(systemName: "folder")
            }
            .help("在 Finder 中显示")
            .disabled(model.currentImage?.attachment.isAvailable != true)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .help("关闭")
            .accessibilityLabel("关闭图片预览")
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var previewCanvas: some View {
        ZStack {
            GeometryReader { proxy in
                let hasNeighbors = model.images.count > 1
                let cardSize = CGSize(width: max(1, proxy.size.width - (hasNeighbors ? 128 : 24)),
                                      height: max(1, proxy.size.height - 28))
                ZStack {
                    ForEach(model.visibleCards) { card in
                        previewCard(card)
                            .frame(width: cardSize.width, height: cardSize.height)
                            .scaleEffect(card.isSelected ? 1 : 0.88)
                            .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(card.offset) * -8),
                                              axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                            .offset(x: CGFloat(card.offset) * cardSize.width * 0.56,
                                    y: card.isSelected ? 0 : 8)
                            .opacity(card.isSelected ? 1 : 0.55)
                            .zIndex(card.isSelected ? 1 : 0)
                            .transition(.opacity)
                    }
                    if model.visibleCards.isEmpty {
                        ImagePreviewCardSurface(attachment: nil, image: nil, isSelected: true,
                                                isLoadingImage: false, canNavigate: false)
                            .frame(width: cardSize.width, height: cardSize.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86),
                           value: model.selectedImageID)
                .clipped()
            }

            if model.conversationID != nil {
                HStack {
                    Button {
                        moveImage(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 36, height: 44)
                            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(!model.canGoPrevious)
                    .opacity(model.canGoPrevious ? 1 : 0.25)
                    .help("上一张图片（←）")
                    .accessibilityLabel("上一张图片")
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer()
                    Button {
                        moveImage(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 36, height: 44)
                            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(!model.canGoNext)
                    .opacity(model.canGoNext ? 1 : 0.25)
                    .help("下一张图片（→）")
                    .accessibilityLabel("下一张图片")
                    .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .buttonStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewCard(_ card: ImagePreviewCard) -> some View {
        ImagePreviewCardSurface(
            attachment: card.image.attachment,
            image: card.isSelected ? model.image : nil,
            isSelected: card.isSelected,
            isLoadingImage: card.isSelected && model.isLoadingImage,
            canNavigate: model.canGoPrevious || model.canGoNext,
            scale: card.isSelected ? scale : 1,
            offset: card.isSelected ? offset : .zero,
            rotation: card.isSelected ? rotation : .zero
        )
        .contentShape(Rectangle())
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    scale = min(5, max(0.35, scaleAtGestureStart * value))
                }
                .onEnded { _ in scaleAtGestureStart = scale },
            including: card.isSelected && model.image != nil ? .all : .none
        )
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    guard scale > 1.01 || model.conversationID == nil else { return }
                    offset = CGSize(width: offsetAtGestureStart.width + value.translation.width,
                                    height: offsetAtGestureStart.height + value.translation.height)
                }
                .onEnded { value in
                    if scale <= 1.01, model.conversationID != nil,
                       abs(value.translation.width) >= 60,
                       abs(value.translation.width) > abs(value.translation.height) * 1.2 {
                        moveImage(by: value.translation.width < 0 ? 1 : -1)
                    } else {
                        offsetAtGestureStart = offset
                    }
                },
            including: card.isSelected ? .all : .none
        )
        .onTapGesture(count: 2) {
            guard card.isSelected, model.image != nil else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                if scale > 1.1 {
                    resetImageTransform()
                } else {
                    scale = 2
                    scaleAtGestureStart = 2
                }
            }
        }
        .onTapGesture {
            if !card.isSelected { moveImage(by: card.offset) }
        }
        .accessibilityHidden(!card.isSelected)
    }

    private var previewFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.conversationID != nil, let current = model.currentImage {
                HStack {
                    Text(model.conversationTitle)
                        .lineLimit(1)
                    Text(current.direction == .outgoing ? "我" : current.senderName)
                        .lineLimit(1)
                    Spacer()
                    Text(current.date.formatted(date: .numeric, time: .shortened))
                }
            }
            HStack {
                Text(model.conversationID == nil
                     ? "双击放大 · 拖动查看 · 触控板捏合缩放"
                     : "← → / 滑动 / 点击侧卡切图 · 双击放大 · 放大后拖动 · 捏合缩放")
                Spacer()
                Text(model.currentImage?.attachment.fileSizeDescription ?? "")
            }
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .foregroundStyle(.white.opacity(0.62))
    }

    private func moveImage(by step: Int) {
        guard (step == -1 && model.canGoPrevious) || (step == 1 && model.canGoNext) else { return }
        resetImageTransform()
        model.move(by: step)
    }

    private func resetImageTransform() {
        scale = 1
        scaleAtGestureStart = 1
        offset = .zero
        offsetAtGestureStart = .zero
        rotation = .zero
    }

    private func copyImageToPasteboard() {
        guard let image = model.image,
              let tiff = image.tiffRepresentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
    }
}

private struct ImagePreviewCardSurface: View {
    let attachment: ChatAttachment?
    let image: NSImage?
    let isSelected: Bool
    let isLoadingImage: Bool
    let canNavigate: Bool
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var rotation: Angle = .zero
    @State private var thumbnail: NSImage?
    @State private var didAttemptThumbnail = false

    private var displayedImage: NSImage? {
        if isSelected { return image ?? (isLoadingImage ? thumbnail : nil) }
        return thumbnail
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let displayedImage {
                    let fittedSize = ImagePreviewLayout.fittedImageSize(
                        displayedImage.size, in: proxy.size, rotationDegrees: rotation.degrees
                    )
                    Image(nsImage: displayedImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .scaleEffect(scale)
                        .rotationEffect(rotation)
                        .offset(offset)
                        .accessibilityLabel(attachment?.fileName ?? "图片")
                } else if isSelected ? isLoadingImage : !didAttemptThumbnail {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 36))
                        Text(attachment == nil ? "没有可预览的图片" : "图片文件不可用或无法解码")
                        if isSelected && canNavigate {
                            Text("可使用左右按钮继续查看其他图片").font(.caption)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: attachment) {
            thumbnail = nil
            didAttemptThumbnail = false
            guard let attachment else { didAttemptThumbnail = true; return }
            let bitmap = await ChatImageThumbnailService.shared.thumbnail(for: attachment, pixelSize: 640)
            guard !Task.isCancelled else { return }
            thumbnail = bitmap.map { NSImage(cgImage: $0, size: .zero) }
            didAttemptThumbnail = true
        }
    }
}
