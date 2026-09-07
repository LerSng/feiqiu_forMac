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
    var cardSize: CGSize? = nil
    @State private var image: NSImage?
    @State private var didAttemptLoad = false
    @State private var showingPreview = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: cardSize?.width ?? 340, maxHeight: cardSize?.height ?? 280)
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
        .frame(width: cardSize?.width, height: cardSize?.height)
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
            Divider()
            Button("删除图片…", role: .destructive) {
                showingDeleteConfirmation = true
            }
        }
        .alert("删除这张图片？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                showingPreview = false
                onDelete()
            }
        } message: {
            Text("从此消息中删除图片，同时清理应用保存的本地副本；不会删除原始图片或撤回对方的消息。如果其他消息仍引用此副本，会在最后一次引用删除后清理。")
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
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                previewToolbar
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
            image = NSImage(contentsOf: attachment.localURL)
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .foregroundStyle(FeiQUI.accent)

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
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var previewCanvas: some View {
        ZStack {
            Color.clear

            if let image {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(
                            width: max(1, proxy.size.width - 84),
                            height: max(1, proxy.size.height - 72)
                        )
                        .scaleEffect(scale)
                        .rotationEffect(rotation)
                        .offset(offset)
                        .shadow(color: .black.opacity(0.34), radius: 18, y: 8)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewFooter: some View {
        HStack {
            Text("双击放大 · 拖动查看 · 触控板捏合缩放")
                .font(.caption)
            Spacer()
            Text(attachment.fileSizeDescription)
                .font(.caption)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .foregroundStyle(.white.opacity(0.62))
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
