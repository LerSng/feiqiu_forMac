//
//  ContentView.swift
//  FeiQMac
//
//  应用主界面根容器，负责组合导航分栏、工具栏以及设置、日志和群聊弹窗。
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ChatViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 360)
        } detail: {
            ChatDetailView()
                .navigationTitle("")
        }
        .navigationSplitViewStyle(.balanced)
        .tint(FeiQUI.accent)
        .background(FeiQUI.windowBackground)
        .background(WindowShakeView(eventID: model.windowShakeID))
        .toolbar {
            ToolbarItem(placement: .principal) {
                if model.selectedConversationID != nil {
                    ConversationToolbarView()
                        .id(model.selectedConversationID)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }

            ToolbarItemGroup {
                Button {
                    model.openHistorySearch()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("历史消息搜索（⇧⌘F）")
                .accessibilityLabel("历史消息搜索")
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button {
                    model.showingFileTransfers = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down.square")
                }
                .help("下载中心（⇧⌘J）")
                .accessibilityLabel("下载中心")
                .keyboardShortcut("j", modifiers: [.command, .shift])

                Button {
                    model.refreshDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("发送一次局域网发现广播")
                .accessibilityLabel("刷新用户")

                Menu {
                    Button("导出聊天记录", systemImage: "square.and.arrow.up") { model.openHistoryArchive(mode: .export) }
                    Button("导入聊天记录", systemImage: "square.and.arrow.down") { model.openHistoryArchive(mode: .import) }
                    Button("数据库维护", systemImage: "externaldrive.badge.timemachine") { model.openDatabaseMaintenance() }
                    Divider()
                    Button("设置", systemImage: "gearshape") { model.showingSettings = true }
                    Button("网络日志", systemImage: "waveform.path.ecg") { model.showingLogs = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("聊天记录、数据库维护、设置与网络日志")
                .accessibilityLabel("应用选项")
            }
        }
        .disabled(model.isDatabaseUnavailable)
        .sheet(item: $model.databaseMaintenance) { maintenance in
            DatabaseMaintenanceView(maintenance: maintenance)
                .environmentObject(model)
                .environment(\.isEnabled, true)
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .sheet(item: $model.editingConversationSettings) { target in
            ConversationSettingsView(target: target, settings: model.conversationSettings(for: target.id))
                .environmentObject(model)
        }
        .confirmationDialog("屏蔽此会话？", isPresented: Binding(
            get: { model.blockingConversation != nil },
            set: { if !$0 { model.blockingConversation = nil } }
        ), titleVisibility: .visible, presenting: model.blockingConversation) { target in
            Button("屏蔽「\(target.originalName)」", role: .destructive) {
                model.setConversationBlocked(true, for: target.id)
                model.blockingConversation = nil
            }
            Button("取消", role: .cancel) { model.blockingConversation = nil }
        } message: { target in
            Text(target.isGroup
                ? "不再显示或中继此群的新消息，停止向此群发送，取消未完成的群文件发送。成员私聊不受影响，历史记录保留；可随时解除。"
                : "不再接收此联系人的新消息、图片、文件及提醒，同时停止向对方发送并取消未完成传输。历史记录保留，屏蔽期间的消息不会补收；可随时解除。")
        }
        .alert("会话管理", isPresented: Binding(
            get: { model.conversationManagementError != nil },
            set: { if !$0 { model.conversationManagementError = nil } }
        )) {
            Button("好", role: .cancel) { model.conversationManagementError = nil }
        } message: {
            Text(model.conversationManagementError ?? "")
        }
        .sheet(item: $model.historySearch) { search in
            HistorySearchView(searchModel: search)
                .environmentObject(model)
        }
        .sheet(item: $model.historyArchive) { archive in
            HistoryArchiveView(archiveModel: archive)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingLogs) {
            LogsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingFileTransfers) {
            FileTransferCenterView()
                .environmentObject(model)
        }
        .sheet(item: $model.imagePreview) { preview in
            ImagePreviewView(model: preview)
        }
        .sheet(isPresented: $model.showingGroupEditor) {
            GroupEditorView()
                .environmentObject(model)
        }
        .sheet(item: $model.remoteAssistanceRequest) { request in
            RemoteAssistanceRequestView(request: request)
                .environmentObject(model)
        }
    }

}
