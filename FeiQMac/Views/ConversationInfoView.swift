//
//  ConversationInfoView.swift
//  FeiQMac
//
//  联系人资料与接收文件面板，供顶部会话工具栏以原生 Popover 展示。
//

import SwiftUI
import AppKit

struct PeerProfileCard: View {
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

struct ReceivedFilesPanel: View {
    @EnvironmentObject private var model: ChatViewModel
    let conversationID: String

    private var files: [ChatReceivedFile] {
        model.receivedFiles(for: conversationID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.document")
                    .foregroundStyle(FeiQUI.accent)
                Text("接收文件")
                    .font(.subheadline.weight(.semibold))
                Text("\(files.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if files.isEmpty {
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
                        ForEach(files) { file in
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
        .animation(.easeInOut(duration: 0.2), value: files.count)
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
