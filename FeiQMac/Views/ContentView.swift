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
                    model.showingFileTransfers = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down.square")
                }
                .help("文件传输中心（⇧⌘J）")
                .accessibilityLabel("文件传输中心")
                .keyboardShortcut("j", modifiers: [.command, .shift])

                Button {
                    model.refreshDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("发送一次局域网发现广播")
                .accessibilityLabel("刷新用户")

                Menu {
                    Button("设置", systemImage: "gearshape") { model.showingSettings = true }
                    Button("网络日志", systemImage: "waveform.path.ecg") { model.showingLogs = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("设置与网络日志")
                .accessibilityLabel("应用选项")
            }
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView()
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
