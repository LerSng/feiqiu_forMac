//
//  ChatHeaderView.swift
//  FeiQMac
//
//  单聊/群聊的轻量标题栏，仅保留会话相关操作和资料栏开关。
//

import SwiftUI

struct GroupChatHeader: View {
    @EnvironmentObject private var model: ChatViewModel
    let group: ChatGroup

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatar(size: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(group.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text("\(group.memberCount) 位成员 · \(model.members(for: group.id).filter(\.isOnline).count) 人在线")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button { model.openGroupEditor(for: group.id) } label: {
                Image(systemName: "person.2.badge.gearshape")
            }
            .buttonStyle(FeiQIconButtonStyle())
            .help("群聊资料与成员")
            .accessibilityLabel("群聊资料与成员")
        }
        .padding(.horizontal, 24)
        .frame(height: 76)
        .background(FeiQUI.chatBackground)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

struct ChatHeader: View {
    @EnvironmentObject private var model: ChatViewModel
    let peer: FeiQPeer
    let isShowingDetails: Bool
    let toggleDetails: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ContactAvatar(name: peer.displayName, isOnline: peer.isOnline, size: 38, showsStatus: false)
            VStack(alignment: .leading, spacing: 5) {
                Text(peer.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    FeiQStatusDot(color: model.isPeerTyping(peer.id) ? FeiQUI.accent : (peer.isOnline ? .green : .gray), size: 5)
                    Text(model.isPeerTyping(peer.id) ? "对方正在输入…" : (peer.isOnline ? "在线" : "离线"))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button { model.sendShake() } label: {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                }
                .disabled(!model.canSendShake)
                .help(model.shakeCoolingDown ? "请稍等再发送抖一抖" : "抖一抖")
                .accessibilityLabel("抖一抖")

                Button(action: toggleDetails) {
                    Image(systemName: isShowingDetails ? "sidebar.right" : "info.circle")
                }
                .help(isShowingDetails ? "收起联系人资料" : "联系人资料与接收文件")
                .accessibilityLabel(isShowingDetails ? "收起联系人资料" : "展开联系人资料")
            }
            .buttonStyle(FeiQIconButtonStyle())
        }
        .padding(.horizontal, 24)
        .frame(height: 76)
        .background(FeiQUI.chatBackground)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}
