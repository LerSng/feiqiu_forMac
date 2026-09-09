//
//  SettingsView.swift
//  FeiQMac
//
//  提供本机资料、通信服务、聊天动画设置和网络日志界面。
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                FeiQIconBadge(systemImage: "person.crop.circle.badge.checkmark")
                Text("设置")
                    .font(.title2.weight(.bold))
            }
            Text("本机资料用于上线广播，提示音和界面偏好仅保存在本机。")
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
                Section("消息提醒") {
                    Picker("消息接收提示音", selection: $model.messageNotificationSound) {
                        ForEach(MessageNotificationSound.allCases) { sound in
                            Text(sound.title).tag(sound)
                        }
                    }
                    HStack {
                        Text("保存后生效，静音仅关闭声音，不影响消息与横幅。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("试听", systemImage: "speaker.wave.2") { model.previewNotificationSound() }
                            .disabled(model.messageNotificationSound == .none)
                    }
                    Text("遵循会话免打扰 / 屏蔽和 macOS 通知、专注模式设置；当前正在查看的会话不额外响铃。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .hiddenScrollIndicators()
            .scrollContentBackground(.hidden)

            Divider()
                .padding(.top, 8)
            HStack {
                if model.isRunning {
                    Button {
                        model.stopNetwork()
                    } label: {
                        Label("停止服务", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        model.startNetwork()
                    } label: {
                        Label("启动服务", systemImage: "play.circle")
                    }
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button {
                    if model.saveSettings() { dismiss() }
                } label: {
                    Label("保存并广播", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .background(FeiQUI.chatBackground)
        .frame(width: 490, height: 680)
        .onChange(of: model.messageNotificationSound) { _, _ in model.stopNotificationSoundPreview() }
        .onDisappear {
            model.stopNotificationSoundPreview()
            model.reloadNotificationSoundSetting()
        }
        .alert("消息提示音", isPresented: Binding(
            get: { model.settingsError != nil },
            set: { if !$0 { model.settingsError = nil } }
        )) {
            Button("好", role: .cancel) { model.settingsError = nil }
        } message: {
            Text(model.settingsError ?? "")
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 9) {
                    FeiQIconBadge(systemImage: "waveform.path.ecg", size: 36)
                    Text("网络日志")
                        .font(.title2.weight(.bold))
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

            ScrollView(showsIndicators: false) {
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
            .hiddenScrollIndicators()
            .feiQSurface(fill: FeiQUI.cardBackground, cornerRadius: 12, shadow: true)
        }
        .padding(20)
        .background(FeiQUI.chatBackground)
        .frame(minWidth: 680, minHeight: 420)
    }
}
