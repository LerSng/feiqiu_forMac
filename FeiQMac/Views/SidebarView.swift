//
//  SidebarView.swift
//  FeiQMac
//
//  会话导航：本机状态、搜索、全部/群聊/未读筛选及共用会话行。
//

import SwiftUI

private enum ConversationFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case groups = "群聊"
    case unread = "未读"
    var id: Self { self }
}

struct SidebarView: View {
    @EnvironmentObject private var model: ChatViewModel
    @State private var filter: ConversationFilter = .all
    @State private var showsOffline = false

    private var peers: [FeiQPeer] {
        guard filter != .groups else { return [] }
        return model.filteredPeers.filter { filter != .unread || model.unreadCount(for: $0.id) > 0 }
    }

    private var groups: [ChatGroup] {
        model.filteredGroups.filter { filter != .unread || model.unreadCount(for: $0.id) > 0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            appBrandHeader
                .padding(.horizontal, 20)
                .padding(.top, 12)

            profileHeader
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 18)

            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索联系人或群聊", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清除搜索")
                    }
                }
                .padding(10)
                .background(FeiQUI.cardBackground.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                Picker("会话筛选", selection: filterSelection) {
                    ForEach(ConversationFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("会话筛选")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            ScrollView(showsIndicators: false) {
                ZStack(alignment: .top) {
                    conversationPage
                        .id(filter)
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .offset(x: 12, y: 0))
                                .combined(with: .scale(scale: 0.985)),
                            removal: .opacity
                                .combined(with: .offset(x: -12, y: 0))
                        ))
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: filter)
            }
            .hiddenScrollIndicators()

            Button {
                model.showingFileTransfers = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down.square")
                        .foregroundStyle(FeiQUI.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("文件传输中心")
                            .font(.system(size: 12, weight: .medium))
                        Text(transferSummary)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.fileTransferSnapshot.unfinishedCount > 0 {
                        Text("\(model.fileTransferSnapshot.unfinishedCount)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(FeiQUI.accentSoft, in: Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(FeiQUI.cardBackground.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(spacing: 6) {
                FeiQStatusDot(color: model.isRunning ? .green : .gray, size: 5)
                Text(model.isRunning ? "局域网服务已启动" : "服务未启动")
                Spacer()
                Text("\(model.onlinePeerCount) 人在线")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(FeiQUI.sidebarBackground)
        .frame(minWidth: 260, idealWidth: 290)
        .onChange(of: model.selectedPeerID) { _, id in
            guard id != nil else { return }
            if filter == .groups { filter = .all }
            if let peer = model.selectedPeer, !peer.isOnline { showsOffline = true }
        }
    }

    private var filterSelection: Binding<ConversationFilter> {
        Binding(
            get: { filter },
            set: { newFilter in
                guard newFilter != filter else { return }
                withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                    filter = newFilter
                    showsOffline = false
                }
            }
        )
    }

    private var transferSummary: String {
        let snapshot = model.fileTransferSnapshot
        if snapshot.isPaused { return "队列已暂停 · \(snapshot.queuedCount) 个等待" }
        if snapshot.unfinishedCount > 0 {
            return "\(snapshot.activeCount) 个进行中 · \(snapshot.queuedCount) 个排队"
        }
        if snapshot.failedCount > 0 { return "\(snapshot.failedCount) 个失败，点击重试" }
        return "查看进度、重试与管理队列"
    }

    @ViewBuilder
    private var conversationPage: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if peers.isEmpty && groups.isEmpty {
                emptyState
            } else {
                let online = peers.filter(\.isOnline)
                if !online.isEmpty {
                    sectionTitle("在线", count: online.count)
                    ForEach(online) { peerRow($0) }
                }
                if !groups.isEmpty {
                    sectionTitle("群聊", count: groups.count)
                        .padding(.top, online.isEmpty ? 0 : 12)
                    ForEach(groups) { group in
                        ConversationRow(
                            title: group.displayName, subtitle: "\(group.memberCount) 位成员",
                            unreadCount: model.unreadCount(for: group.id),
                            isSelected: model.selectedGroupID == group.id
                        ) {
                            GroupAvatar(size: 42)
                        } action: {
                            model.selectGroup(group.id)
                        }
                        .contextMenu {
                            Button("群聊设置") { model.openGroupEditor(for: group.id) }
                            Button("删除群聊", role: .destructive) { model.deleteGroup(group.id) }
                        }
                    }
                }
                let offline = peers.filter { !$0.isOnline }
                if !offline.isEmpty {
                    if filter == .unread || !model.searchText.isEmpty {
                        sectionTitle("离线", count: offline.count).padding(.top, 12)
                        ForEach(offline) { peerRow($0) }
                    } else {
                        DisclosureGroup(isExpanded: $showsOffline) {
                            ForEach(offline) { peerRow($0) }
                        } label: {
                            Text("离线联系人 · \(offline.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 16)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 16)
    }

    private var profileHeader: some View {
        HStack(spacing: 11) {
            LocalAvatar(name: model.nickname, isOnline: model.isRunning, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.nickname.isEmpty ? "飞秋 Mac" : model.nickname)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Menu {
                    Button("在线") { model.setOnlineStatus(true) }
                    Button("离线") { model.setOnlineStatus(false) }
                } label: {
                    Text(model.isRunning ? "在线" : "离线").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("修改在线状态")
            }
            Spacer(minLength: 4)
            Button { model.openGroupEditor() } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(FeiQIconButtonStyle())
            .help("新建群聊")
            .accessibilityLabel("新建群聊")
        }
    }

    private var appBrandHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FeiQUI.accent)
                .frame(width: 28, height: 28)
                .background(FeiQUI.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text("飞秋 Mac")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("飞秋 Mac")
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func peerRow(_ peer: FeiQPeer) -> some View {
        ConversationRow(
            title: peer.displayName, subtitle: peer.isOnline ? peer.ipAddress : "离线 · \(peer.ipAddress)",
            unreadCount: model.unreadCount(for: peer.id),
            isSelected: model.selectedGroupID == nil && model.selectedPeerID == peer.id
        ) {
            ContactAvatar(name: peer.displayName, isOnline: peer.isOnline, size: 42)
        } action: {
            model.selectPeer(peer.id)
        }
        .contextMenu { Text(peer.detailText) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .unread ? "checkmark.bubble" : "bubble.left.and.bubble.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(!model.searchText.isEmpty ? "没有匹配的会话" : (filter == .unread ? "暂无未读消息" : "暂无会话"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.searchText.isEmpty && filter != .unread {
                Button(filter == .groups ? "创建群聊" : "发现联系人") {
                    if filter == .groups { model.openGroupEditor() }
                    else if model.isRunning { model.refreshDiscovery() }
                    else { model.startNetwork() }
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

/// 联系人与群聊共用行布局，统一头像、两级文字、选中态与未读动效。
private struct ConversationRow<Avatar: View>: View {
    let title: String
    let subtitle: String
    let unreadCount: Int
    let isSelected: Bool
    @ViewBuilder let avatar: () -> Avatar
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                avatar()
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected || unreadCount > 0 ? .semibold : .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                FeiQUnreadBadge(count: unreadCount)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .feiQSelectionRow(isSelected: isSelected, isHovering: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: unreadCount)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
