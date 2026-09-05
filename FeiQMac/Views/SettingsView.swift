import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(FeiQUI.accent)
                Text("本机资料")
                    .font(.title2.weight(.semibold))
            }
            Text("这些字段会放入飞秋的上线广播中。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
                .padding(.bottom, 16)

            Form {
                TextField("昵称", text: $model.nickname)
                TextField("主机名", text: $model.hostName)
                TextField("分组（可选）", text: $model.groupName)
                LabeledContent("通信端口") {
                    Text("UDP / TCP 2425")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("聊天记录") {
                    Text("文稿 / 飞秋 Mac / ChatHistory.sqlite")
                        .foregroundStyle(.secondary)
                }

                Section("聊天界面") {
                    Picker("聊天记录进入方式", selection: $model.chatLoadAnimationMode) {
                        ForEach(ChatLoadAnimationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(model.chatLoadAnimationMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
                .padding(.top, 8)
            HStack {
                if model.isRunning {
                    Button("停止服务") {
                        model.stopNetwork()
                    }
                } else {
                    Button("启动服务") {
                        model.startNetwork()
                    }
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存并广播") {
                    model.saveSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .background(FeiQUI.chatBackground)
        .frame(width: 430)
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(FeiQUI.accent)
                    Text("网络日志")
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                Button("清空") {
                    model.clearLogs()
                }
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if model.logs.isEmpty {
                        Text("暂无日志")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 30)
                    } else {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
            .background(FeiQUI.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .padding(20)
        .background(FeiQUI.chatBackground)
        .frame(minWidth: 680, minHeight: 420)
    }
}
