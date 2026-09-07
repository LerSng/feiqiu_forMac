//
//  EmojiPickerView.swift
//  FeiQMac
//
//  从 ViewModel 获取飞秋兼容码表，选择可与 Windows 飞秋互通的表情。
//

import SwiftUI

struct EmojiPickerView: View {
    @EnvironmentObject private var model: ChatViewModel
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("飞秋表情", systemImage: "face.smiling")
                .font(.headline)
            Text("Mac 显示对应 emoji，Windows 显示飞秋原生表情")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 4)], spacing: 8) {
                    ForEach(model.compatibleEmoticons, id: \.code) { item in
                        Button {
                            onSelect(item.emoji)
                        } label: {
                            Text(item.emoji)
                                .font(.system(size: 25))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .help(item.title)
                        .accessibilityLabel(item.title)
                    }
                }
                .padding(4)
            }
            .hiddenScrollIndicators()
        }
        .padding(15)
        .background(FeiQUI.chatBackground)
        .frame(width: 330, height: 360)
    }
}
