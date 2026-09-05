import SwiftUI

struct GroupEditorView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var memberSearchText = ""
    @State private var selectedMemberIDs: Set<String> = []
    @State private var didLoadInitialValues = false

    private var editingGroup: ChatGroup? {
        guard let editingGroupID = model.editingGroupID else { return nil }
        return model.group(withID: editingGroupID)
    }

    private var availablePeers: [FeiQPeer] {
        let query = memberSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.peers }
        return model.peers.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.hostName.localizedCaseInsensitiveContains(query)
                || $0.ipAddress.localizedCaseInsensitiveContains(query)
        }
    }

    private var canSave: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedMemberIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                GroupAvatar(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(editingGroup == nil ? "新建群聊" : "群聊设置")
                        .font(.title2.weight(.semibold))
                    Text("群聊在 Mac 端统一管理，消息按成员兼容发送")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") {
                    model.editingGroupID = nil
                    model.showingGroupEditor = false
                    dismiss()
                }
                .buttonStyle(.plain)
            }

            TextField("群聊名称", text: $groupName)
                .textFieldStyle(.roundedBorder)
                .padding(.top, 18)

            HStack(spacing: 8) {
                Text("选择成员")
                    .font(.headline)
                Text("已选 \(selectedMemberIDs.count) 人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 18)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索联系人", text: $memberSearchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(FeiQUI.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 3) {
                    if availablePeers.isEmpty {
                        Text("暂无可加入的局域网联系人")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 32)
                    } else {
                        ForEach(availablePeers) { peer in
                            GroupMemberSelectionRow(
                                peer: peer,
                                isSelected: selectedMemberIDs.contains(peer.id)
                            ) {
                                if selectedMemberIDs.contains(peer.id) {
                                    selectedMemberIDs.remove(peer.id)
                                } else {
                                    selectedMemberIDs.insert(peer.id)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 330)

            Divider()
                .padding(.top, 8)

            HStack {
                if let editingGroup {
                    Button("删除群聊", role: .destructive) {
                        model.deleteGroup(editingGroup.id)
                        model.editingGroupID = nil
                        model.showingGroupEditor = false
                        dismiss()
                    }
                }
                Spacer()
                Button(editingGroup == nil ? "创建群聊" : "保存群聊") {
                    model.saveGroup(
                        name: groupName,
                        memberIDs: Array(selectedMemberIDs),
                        editingGroupID: model.editingGroupID
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .background(FeiQUI.chatBackground)
        .frame(width: 480, height: 620)
        .onAppear {
            guard !didLoadInitialValues else { return }
            didLoadInitialValues = true
            if let editingGroup {
                groupName = editingGroup.displayName
                selectedMemberIDs = Set(editingGroup.memberIDs)
            }
        }
    }
}

private struct GroupMemberSelectionRow: View {
    let peer: FeiQPeer
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ContactAvatar(name: peer.displayName, isOnline: peer.isOnline, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    Text(peer.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? FeiQUI.accent : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? FeiQUI.selectedBackground :
                          (isHovering ? Color.primary.opacity(0.05) : .clear))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
