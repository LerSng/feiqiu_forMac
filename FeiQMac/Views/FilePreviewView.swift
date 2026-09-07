//
//  FilePreviewView.swift
//  FeiQMac
//
//  提供普通文件附件卡片和基于 macOS Quick Look 的聊天内文件预览。
//

import AppKit
import QuickLookUI
import SwiftUI

struct FileAttachmentView: View {
    let attachment: ChatAttachment

    @State private var showingPreview = false
    @State private var showingUnavailableAlert = false

    var body: some View {
        Button {
            openPreview()
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("预览文件") {
                openPreview()
            }
            .disabled(!attachment.isAvailable)

            Button("使用默认应用打开") {
                openWithDefaultApplication()
            }
            .disabled(!attachment.isAvailable)

            Button("在 Finder 中显示") {
                showInFinder()
            }
            .disabled(!attachment.isAvailable)

            Divider()

            Button("复制文件路径") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(attachment.localURL.path, forType: .string)
            }
        }
        .help(attachment.fileName)
        .sheet(isPresented: $showingPreview) {
            FilePreviewView(attachment: attachment)
        }
        .alert("文件不可用", isPresented: $showingUnavailableAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("本地文件已经不存在，无法预览：\n\(attachment.localURL.path)")
        }
    }

    private var cardContent: some View {
        HStack(spacing: 11) {
            fileIcon
            fileDetails
            Spacer(minLength: 6)
            statusIcon
        }
        .padding(12)
        .frame(minWidth: 270, maxWidth: 380, alignment: .leading)
        .background(
            FeiQUI.cardBackground,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FeiQUI.separator, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.055), radius: 5, y: 2)
    }

    private var fileIcon: some View {
        Image(systemName: attachment.systemImageName)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(FeiQUI.accent)
            .frame(width: 42, height: 42)
            .background(
                FeiQUI.accentSoft,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
    }

    private var fileDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attachment.fileName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)

            Text(metadataDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(attachment.isAvailable ? "点击预览文件" : "文件不可用")
                .font(.caption2)
                .foregroundStyle(attachment.isAvailable ? FeiQUI.accent : .orange)
        }
    }

    private var statusIcon: some View {
        Image(systemName: attachment.isAvailable ? "eye" : "exclamationmark.triangle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(
                attachment.isAvailable ? Color.secondary : Color.orange
            )
    }

    private var fileTypeDescription: String {
        if !attachment.mimeType.isEmpty,
           attachment.mimeType != "application/octet-stream" {
            return attachment.mimeType
        }
        let pathExtension = attachment.localURL.pathExtension
        return pathExtension.isEmpty ? "文件" : pathExtension.uppercased()
    }

    private var metadataDescription: String {
        "\(attachment.fileSizeDescription) · \(fileTypeDescription)"
    }

    private func openPreview() {
        guard attachment.isAvailable else {
            showingUnavailableAlert = true
            return
        }
        showingPreview = true
    }

    private func openWithDefaultApplication() {
        guard attachment.isAvailable else {
            showingUnavailableAlert = true
            return
        }
        NSWorkspace.shared.open(attachment.localURL)
    }

    private func showInFinder() {
        guard attachment.isAvailable else {
            showingUnavailableAlert = true
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([attachment.localURL])
    }
}

struct FilePreviewView: View {
    let attachment: ChatAttachment

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: attachment.systemImageName)
                        .foregroundStyle(FeiQUI.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(attachment.fileSizeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button("打开") {
                        NSWorkspace.shared.open(attachment.localURL)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!attachment.isAvailable)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭预览")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                Divider()

                if attachment.isAvailable {
                    QuickLookPreviewRepresentable(url: attachment.localURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(FeiQUI.chatBackground)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("文件已被移动或删除")
                            .font(.headline)
                        Text(attachment.localURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("预览由 macOS Quick Look 提供；不支持预览的格式可点击“打开”。")
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
            }
            .frame(minWidth: 700, minHeight: 500)
            .background(FeiQUI.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FeiQUI.separator, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.22), radius: 26, y: 12)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(.clear)
        .presentationBackground(.clear)
    }
}

private struct QuickLookPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal)!
        preview.autostarts = true
        preview.previewItem = context.coordinator.item
        return preview
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        guard context.coordinator.item.previewItemURL != url else { return }
        context.coordinator.item = LocalQuickLookItem(url: url)
        nsView.previewItem = context.coordinator.item
        nsView.refreshPreviewItem()
    }

    final class Coordinator {
        var item: LocalQuickLookItem

        init(url: URL) {
            item = LocalQuickLookItem(url: url)
        }
    }
}

private final class LocalQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL) {
        previewItemURL = url
        previewItemTitle = url.lastPathComponent
    }
}
