import SwiftUI

struct ConversationManagementActions: View {
    @EnvironmentObject private var model: ChatViewModel
    let conversationID: String

    var body: some View {
        let settings = model.conversationSettings(for: conversationID)
        Group {
            Button(settings.isPinned ? "取消置顶" : "置顶会话", systemImage: settings.isPinned ? "pin.slash" : "pin") {
                model.toggleConversationPin(conversationID)
            }
            Button(settings.isMuted ? "关闭免打扰" : "开启免打扰", systemImage: settings.isMuted ? "bell" : "bell.slash") {
                model.toggleConversationMute(conversationID)
            }
            Button("备注与标签…", systemImage: "tag") {
                model.editConversationSettings(conversationID)
            }
            Divider()
            Button(role: settings.isBlocked ? nil : .destructive) {
                model.requestConversationBlock(conversationID)
            } label: {
                Label(settings.isBlocked ? "解除屏蔽" : "屏蔽此会话…", systemImage: settings.isBlocked ? "checkmark.circle" : "nosign")
            }
        }
        .disabled(model.savingConversationIDs.contains(conversationID))
    }
}

struct ConversationStatusIcons: View {
    let settings: ConversationSettings

    var body: some View {
        HStack(spacing: 4) {
            if settings.isPinned { Image(systemName: "pin.fill").help("已置顶").accessibilityLabel("已置顶") }
            if settings.isMuted { Image(systemName: "bell.slash.fill").help("免打扰").accessibilityLabel("免打扰") }
            if settings.isBlocked { Image(systemName: "nosign").help("已屏蔽").accessibilityLabel("已屏蔽") }
        }
        .font(.system(size: 10))
        .foregroundStyle(settings.isBlocked ? .orange : .secondary)
    }
}

struct ConversationSettingsView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    let target: ConversationSettingsTarget
    @State private var remark: String
    @State private var tags: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(target: ConversationSettingsTarget, settings: ConversationSettings) {
        self.target = target
        _remark = State(initialValue: settings.remark)
        _tags = State(initialValue: settings.tags.joined(separator: "，"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                FeiQIconBadge(systemImage: "tag")
                VStack(alignment: .leading, spacing: 4) {
                    Text("备注与标签").font(.title2.weight(.semibold))
                    Text("\(target.isGroup ? "群聊" : "联系人")：\(target.originalName)")
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("备注名称").font(.headline)
                TextField("留空使用原名称", text: $remark)
                Text("最多 80 个字符；仅修改本机显示，不会改动对方昵称或群名。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("标签").font(.headline)
                TextField("例如：工作，项目 A，家人", text: $tags)
                Text("用逗号或顿号分隔；最多 10 个标签，每个最多 24 个字符。保存后可在会话列表筛选或搜索。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("仅保存在本机，不会发送给联系人。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("保存") {
                    isSaving = true
                    errorMessage = nil
                    model.saveConversationDetails(target.id, remark: remark, tags: tags) { result in
                        isSaving = false
                        switch result {
                        case .success: dismiss()
                        case .failure(let error): errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || model.savingConversationIDs.contains(target.id))
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isSaving)
    }
}
