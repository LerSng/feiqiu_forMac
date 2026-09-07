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
        HStack(spacing: 10) {
            identityView
            Spacer(minLength: 16)
            actionView
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 340, idealWidth: 540, maxWidth: 780)
        .frame(height: 40)
        .animation(.easeInOut(duration: 0.2), value: model.selectedConversationID)
        .onChange(of: model.selectedConversationID) { _, _ in
            showingProfile = false
            showingReceivedFiles = false
        }
    }

    @ViewBuilder
    private var identityView: some View {
        if let peer = model.selectedPeer {
            HStack(spacing: 9) {
                ContactAvatar(name: peer.displayName, isOnline: peer.isOnline, size: 32, showsStatus: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        FeiQStatusDot(
                            color: model.isPeerTyping(peer.id)
                                ? FeiQUI.accent
                                : (peer.isOnline ? .green : .gray),
                            size: 5
                        )
                        Text(model.isPeerTyping(peer.id) ? "对方正在输入…" : (peer.isOnline ? "在线" : "离线"))
                        if !peer.ipAddress.isEmpty {
                            Text("·")
                            Text(peer.ipAddress)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        } else if let group = model.selectedGroup {
            HStack(spacing: 9) {
                GroupAvatar(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("\(group.memberCount) 位成员 · \(model.members(for: group.id).filter(\.isOnline).count) 人在线")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var actionView: some View {
        if let peer = model.selectedPeer {
            HStack(spacing: 2) {
                Button {
                    showingReceivedFiles = false
                    showingProfile.toggle()
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .buttonStyle(FeiQIconButtonStyle())
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
                .buttonStyle(FeiQIconButtonStyle())
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
            .buttonStyle(FeiQIconButtonStyle())
            .help("群聊资料与成员")
            .accessibilityLabel("群聊资料与成员")
        }
    }
}
