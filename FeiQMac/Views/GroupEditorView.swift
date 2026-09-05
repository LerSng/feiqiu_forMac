//
//  GroupEditorView.swift
//  FeiQMac
//
//  负责新建、编辑和删除群聊，以及选择群聊成员。
//

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
                GroupAvatar(size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(editingGroup == nil ? "新建群聊" : "群聊设置")
                        .font(.title2.weight(.bold))
                    Text("Mac 作为群聊中继，成员消息会转发给其他成员")
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
                .controlSize(.large)
                .padding(.top, 18)

            HStack(spacing: 8) {
                Text("选择成员")
                    .font(.headline)
                Text("已选 \(selectedMemberIDs.count) 人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(FeiQUI.accentSoft, in: Capsule())
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
            .feiQSurface(fill: FeiQUI.inputBackground, cornerRadius: 10)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
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
        .frame(width: 500, height: 640)
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
            .feiQSelectionRow(isSelected: isSelected, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
