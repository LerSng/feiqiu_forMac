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
                .navigationTitle(detailTitle)
                .animation(.easeInOut(duration: 0.2), value: detailTitle)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(FeiQUI.accent)
        .background(FeiQUI.windowBackground)
        .background(WindowShakeView(eventID: model.windowShakeID))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.refreshDiscovery()
                } label: {
                    Label("刷新用户", systemImage: "arrow.clockwise")
                }
                .help("发送一次局域网发现广播")

                Menu {
                    Button("设置", systemImage: "gearshape") { model.showingSettings = true }
                    Button("网络日志", systemImage: "waveform.path.ecg") { model.showingLogs = true }
                } label: {
                    Label("应用选项", systemImage: "ellipsis.circle")
                }
                .help("设置与网络日志")
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
        .sheet(isPresented: $model.showingGroupEditor) {
            GroupEditorView()
                .environmentObject(model)
        }
        .sheet(item: $model.remoteAssistanceRequest) { request in
            RemoteAssistanceRequestView(request: request)
                .environmentObject(model)
        }
    }

    private var detailTitle: String {
        if let group = model.selectedGroup {
            return group.displayName
        }
        if let peer = model.selectedPeer {
            return peer.displayName
        }
        return ""
    }
}
