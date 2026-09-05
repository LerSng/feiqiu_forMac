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
                .navigationSplitViewColumnWidth(min: 310, ideal: 340, max: 420)
        } detail: {
            ChatDetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .tint(FeiQUI.accent)
        .background(FeiQUI.windowBackground)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.refreshDiscovery()
                } label: {
                    Label("刷新用户", systemImage: "arrow.clockwise")
                }
                .help("发送一次局域网发现广播")

                Button {
                    model.showingLogs = true
                } label: {
                    Label("网络日志", systemImage: "list.bullet.rectangle")
                }

                Button {
                    model.showingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
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
    }
}
