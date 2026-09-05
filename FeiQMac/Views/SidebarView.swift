import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: ChatViewModel

    private var onlinePeers: [FeiQPeer] {
        model.filteredPeers.filter(\.isOnline)
    }

    private var offlinePeers: [FeiQPeer] {
        model.filteredPeers.filter { !$0.isOnline }
    }

    private var visibleGroups: [ChatGroup] {
        model.filteredGroups
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail()

            VStack(spacing: 0) {
                SidebarProfileHeader()

                Divider()

                SidebarSearchField()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        PeerSectionHeader(
                            title: "在线联系人",
                            count: onlinePeers.count,
                            symbol: "circle.fill",
                            color: .green
                        )

                        if onlinePeers.isEmpty {
                            EmptyPeerListView(
                                title: model.searchText.isEmpty ? "暂未发现用户" : "没有匹配的联系人",
                                message: model.searchText.isEmpty
                                    ? "点击右上角刷新，发现同一局域网中的飞秋用户"
                                    : "试试搜索昵称、主机名或 IP 地址"
                            )
                        } else {
                            ForEach(onlinePeers) { peer in
                                peerRow(for: peer)
                            }
                        }

                        GroupSectionHeader(
                            title: "群聊",
                            count: visibleGroups.count,
                            action: {
                                model.openGroupEditor()
                            }
                        )
                        .padding(.top, 10)

                        if visibleGroups.isEmpty {
                            EmptyPeerListView(
                                title: model.searchText.isEmpty ? "还没有群聊" : "没有匹配的群聊",
                                message: model.searchText.isEmpty
                                    ? "点击右侧加号，选择联系人创建群聊"
                                    : "试试搜索群名称或成员昵称"
                            )
                        } else {
                            ForEach(visibleGroups) { group in
                                groupRow(for: group)
                            }
                        }

                        if !offlinePeers.isEmpty {
                            PeerSectionHeader(
                                title: "最近离线",
                                count: offlinePeers.count,
                                symbol: "clock.arrow.circlepath",
                                color: .secondary
                            )
                            .padding(.top, 10)

                            ForEach(offlinePeers) { peer in
                                peerRow(for: peer)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .background(FeiQUI.listBackground)

                Divider()
                SidebarStatusFooter()
            }
        }
        .background(FeiQUI.sidebarBackground)
        .frame(minWidth: 310, idealWidth: 340)
    }

    @ViewBuilder
    private func peerRow(for peer: FeiQPeer) -> some View {
        PeerRow(
            peer: peer,
            unreadCount: model.unreadCount(for: peer.id),
            isSelected: model.selectedPeerID == peer.id
        ) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                model.selectPeer(peer.id)
            }
        }
    }

    @ViewBuilder
    private func groupRow(for group: ChatGroup) -> some View {
        GroupRow(
            group: group,
            unreadCount: model.unreadCount(for: group.id),
            isSelected: model.selectedGroupID == group.id
        ) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                model.selectGroup(group.id)
            }
        } onEdit: {
            model.openGroupEditor(for: group.id)
        } onDelete: {
            model.deleteGroup(group.id)
        }
    }
}

private struct SidebarRail: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        VStack(spacing: 8) {
            LocalAvatar(name: model.nickname, isOnline: model.isRunning, size: 36)
                .padding(.top, 14)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 12)

            RailButton(
                systemImage: "bubble.left.and.bubble.right.fill",
                title: "消息",
                isSelected: true
            ) { }

            RailButton(
                systemImage: "person.2.fill",
                title: "联系人",
                isSelected: false
            ) {
                model.searchText = ""
                model.selectPeer(nil)
            }

            RailButton(
                systemImage: "person.3.fill",
                title: "新建群聊",
                isSelected: false
            ) {
                model.openGroupEditor()
            }

            Spacer()

            RailButton(
                systemImage: "arrow.clockwise",
                title: "刷新用户",
                isSelected: false
            ) {
                model.refreshDiscovery()
            }

            RailButton(
                systemImage: "list.bullet.rectangle",
                title: "网络日志",
                isSelected: false
            ) {
                model.showingLogs = true
            }

            RailButton(
                systemImage: "gearshape.fill",
                title: "设置",
                isSelected: false
            ) {
                model.showingSettings = true
            }
            .padding(.bottom, 12)
        }
        .frame(width: 62)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .overlay(alignment: .trailing) {
            Divider()
        }
    }
}

private struct RailButton: View {
    let systemImage: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? FeiQUI.accent : Color.secondary)
                .frame(width: 38, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isSelected ? FeiQUI.selectedBackground :
                              (isHovering ? Color.primary.opacity(0.07) : .clear))
                }
        }
        .buttonStyle(.plain)
        .help(title)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
    }
}

private struct SidebarProfileHeader: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        HStack(spacing: 10) {
            LocalAvatar(name: model.nickname, isOnline: model.isRunning, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.nickname.isEmpty ? "飞秋 Mac" : model.nickname)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isRunning ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(model.isRunning ? "局域网在线" : "服务未启动")
                }
                .font(.caption)
                .foregroundStyle(model.isRunning ? Color.secondary : Color.orange)
            }

            Spacer(minLength: 4)

            Button {
                model.refreshDiscovery()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("刷新局域网用户")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
    }
}

private struct SidebarSearchField: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("搜索联系人", text: $model.searchText)
                .textFieldStyle(.plain)

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(FeiQUI.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct PeerSectionHeader: View {
    let title: String
    let count: Int
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
            Text(title)
            Text("\(count)")
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct GroupSectionHeader: View {
    let title: String
    let count: Int
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(FeiQUI.accent)
            Text(title)
            Text("\(count)")
                .foregroundStyle(.tertiary)
            Spacer()

            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FeiQUI.accent)
                    .frame(width: 24, height: 24)
                    .background(FeiQUI.selectedBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .help("新建群聊")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct GroupRow: View {
    let group: ChatGroup
    let unreadCount: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                GroupAvatar(size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(group.memberCount) 位成员")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if unreadCount > 0 {
                    Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .padding(.horizontal, unreadCount > 9 ? 3 : 0)
                        .background(Color.red, in: Capsule())
                        .transition(
                            .scale(scale: 0.45, anchor: .trailing)
                                .combined(with: .opacity)
                        )
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? FeiQUI.selectedBackground :
                          (isHovering ? Color.primary.opacity(0.055) : .clear))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(
            .spring(response: 0.32, dampingFraction: 0.78),
            value: unreadCount
        )
        .contextMenu {
            Button("群聊设置", action: onEdit)
            Button("删除群聊", role: .destructive, action: onDelete)
        }
    }
}


private struct EmptyPeerListView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

private struct SidebarStatusFooter: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "network")
                .font(.system(size: 12, weight: .semibold))
            Text("UDP/TCP 2425")
            Spacer(minLength: 4)
            Text("\(model.onlinePeerCount) 人在线")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }
}

private struct PeerRow: View {
    let peer: FeiQPeer
    let unreadCount: Int
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ContactAvatar(name: peer.displayName, isOnline: peer.isOnline, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(peer.displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(peer.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if unreadCount > 0 {
                    Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .padding(.horizontal, unreadCount > 9 ? 3 : 0)
                        .background(Color.red, in: Capsule())
                        .transition(
                            .scale(scale: 0.45, anchor: .trailing)
                                .combined(with: .opacity)
                        )
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? FeiQUI.selectedBackground :
                          (isHovering ? Color.primary.opacity(0.055) : .clear))
            }
        }
        .buttonStyle(.plain)
        .opacity(peer.isOnline ? 1 : 0.65)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(
            .spring(response: 0.32, dampingFraction: 0.78),
            value: unreadCount
        )
        .contextMenu {
            Text(peer.ipAddress)
        }
    }
}
