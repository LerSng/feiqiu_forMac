//
//  ChatHeaderView.swift
//  FeiQMac
//
//  顶部会话工具栏，集中显示联系人/群聊身份和常用操作。
//

import SwiftUI

struct ConversationToolbarView: View {
    @EnvironmentObject private var model: ChatViewModel
    @State private var showingProfile = false
    @State private var showingReceivedFiles = false

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 390

            HStack(spacing: isCompact ? 5 : 10) {
                identityView(isCompact: isCompact)
                    .layoutPriority(1)
                Spacer(minLength: isCompact ? 4 : 10)
                actionView(isCompact: isCompact)
            }
            .padding(.horizontal, isCompact ? 7 : 10)
            .padding(.vertical, isCompact ? 1 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: 1)
        }
        .frame(minWidth: 178, idealWidth: 430, maxWidth: 700)
        .frame(height: 36)
        .animation(.easeInOut(duration: 0.2), value: model.selectedConversationID)
        .onChange(of: model.selectedConversationID) { _, _ in
            showingProfile = false
            showingReceivedFiles = false
        }
    }

    @ViewBuilder
    private func identityView(isCompact: Bool) -> some View {
        if let peer = model.selectedPeer {
            HStack(spacing: isCompact ? 6 : 9) {
                ContactAvatar(
                    name: peer.displayName,
                    isOnline: peer.isOnline,
                    size: isCompact ? 23 : 28,
                    showsStatus: false
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(peer.displayName)
                        .font(.system(size: isCompact ? 12 : 14, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        FeiQStatusDot(
                            color: model.isPeerTyping(peer.id)
                                ? FeiQUI.accent
                                : (peer.isOnline ? .green : .gray),
                            size: 5
                        )
                        Text(model.isPeerTyping(peer.id) ? "对方正在输入…" : (peer.isOnline ? "在线" : "离线"))
                        if !isCompact && !peer.ipAddress.isEmpty {
                            Text("·")
                            Text(peer.ipAddress)
                        }
                    }
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: isCompact ? 12 : 13, alignment: .top)
                    .offset(y: -1)
                }
            }
        } else if let group = model.selectedGroup {
            HStack(spacing: isCompact ? 6 : 9) {
                GroupAvatar(size: isCompact ? 23 : 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.displayName)
                        .font(.system(size: isCompact ? 12 : 14, weight: .semibold))
                        .lineLimit(1)
                    Text(
                        isCompact
                            ? "\(group.memberCount) 位成员"
                            : "\(group.memberCount) 位成员 · \(model.members(for: group.id).filter(\.isOnline).count) 人在线"
                    )
                        .font(.system(size: isCompact ? 10 : 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: isCompact ? 12 : 13, alignment: .top)
                        .offset(y: -1)
                }
            }
        }
    }

    @ViewBuilder
    private func actionView(isCompact: Bool) -> some View {
        if let peer = model.selectedPeer {
            HStack(spacing: 2) {
                Button {
                    showingReceivedFiles = false
                    showingProfile.toggle()
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .buttonStyle(FeiQIconButtonStyle(size: isCompact ? 27 : 32))
                .help("联系人资料")
                .accessibilityLabel("联系人资料")
                .popover(isPresented: $showingProfile, arrowEdge: .top) {
                    PeerProfileCard(peer: peer)
                        .padding(12)
                        .frame(width: 320)
                }

                Button {
                    showingProfile = false
                    showingReceivedFiles.toggle()
                } label: {
                    Image(systemName: "arrow.down.document")
                }
                .buttonStyle(FeiQIconButtonStyle(size: isCompact ? 27 : 32))
                .help("接收文件")
                .accessibilityLabel("接收文件")
                .popover(isPresented: $showingReceivedFiles, arrowEdge: .top) {
                    ReceivedFilesPanel(conversationID: peer.id)
                        .padding(12)
                        .frame(width: 360, height: 360)
                }
            }
        } else if let group = model.selectedGroup {
            Button {
                model.openGroupEditor(for: group.id)
            } label: {
                Image(systemName: "person.2.badge.gearshape")
            }
            .buttonStyle(FeiQIconButtonStyle(size: isCompact ? 27 : 32))
            .help("群聊资料与成员")
            .accessibilityLabel("群聊资料与成员")
        }
    }
}
