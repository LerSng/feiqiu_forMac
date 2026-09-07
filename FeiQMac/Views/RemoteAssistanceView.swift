//
//  RemoteAssistanceView.swift
//  FeiQMac
//
//  展示飞秋 2013 的远程协助请求，并在协议能力不明确时阻止
//  未经确认的屏幕、键盘和鼠标控制。
//

import SwiftUI

struct RemoteAssistanceRequestView: View {
    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    let request: FeiQRemoteAssistanceRequest

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(FeiQUI.accent)
                    .frame(width: 48, height: 48)
                    .background(FeiQUI.accentSoft, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text("远程协助请求")
                        .font(.title3.weight(.semibold))
                    Text("\(request.peer.displayName) 请求与此 Mac 建立远程协助")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                RemoteAssistanceValue(title: "联系人", value: request.peer.displayName)
                RemoteAssistanceValue(title: "主机名", value: request.peer.hostName)
                RemoteAssistanceValue(title: "IP 地址", value: request.peer.ipAddress)
                RemoteAssistanceValue(title: "协议", value: "飞秋私有命令 0xB0")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FeiQUI.subtleFill, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 22)

            VStack(alignment: .leading, spacing: 7) {
                Label("安全提示", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("已识别飞秋 2013 的远程协助请求。当前公开资料没有定义后续控制和画面传输协议，因此此版本不会自动共享屏幕、键盘或鼠标，也不会发送未知应答。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)

            Spacer(minLength: 20)

            HStack {
                Button("忽略请求", role: .cancel) {
                    model.dismissRemoteAssistanceRequest()
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("查看网络日志") {
                    model.showRemoteAssistanceLogs()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(FeiQUI.chatBackground)
        .frame(width: 480, height: 400)
    }
}

private struct RemoteAssistanceValue: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Text(value.isEmpty ? "未提供" : value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
