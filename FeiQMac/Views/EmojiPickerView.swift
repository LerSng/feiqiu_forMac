//
//  EmojiPickerView.swift
//  FeiQMac
//
//  提供飞秋兼容表情和 Unicode 表情的选择面板。
//

import SwiftUI

struct EmojiPickerView: View {
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("选择表情", systemImage: "face.smiling")
                .font(.headline.weight(.bold))
                .foregroundStyle(FeiQUI.accent)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(EmojiCategory.catalog) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 4)
                                ],
                                spacing: 4
                            ) {
                                ForEach(category.emojis, id: \.self) { emoji in
                                    Button {
                                        onSelect(emoji)
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 25))
                                            .frame(width: 34, height: 34)
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Rectangle())
                                }
                            }
                        }
                        .padding(9)
                        .feiQSurface(fill: FeiQUI.subtleFill, cornerRadius: 12)
                    }
                }
            }
        }
        .padding(15)
        .background(FeiQUI.chatBackground)
        .frame(width: 310, height: 360)
    }
}

private struct EmojiCategory: Identifiable {
    let id: String
    let title: String
    let emojis: [String]

    static let catalog = [
        EmojiCategory(
            id: "feiQCompatible",
            title: "飞秋兼容（Windows）",
            // These are the three FeiQ 2013 emoticons currently mapped by
            // the ViewModel's chat pipeline. Keeping the picker data local
            // to the view avoids coupling the UI to the wire formatter.
            emojis: ["😶", "🥺", "😮"]
        ),
        EmojiCategory(
            id: "faces",
            title: "其他表情（Unicode）",
            emojis: [
                "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣",
                "😊", "😇", "🙂", "🙃", "😉", "😌", "😍", "🥰",
                "😘", "😗", "😙", "😚", "😋", "😛", "😝", "😜",
                "🤪", "🤨", "🧐", "🤓", "😎", "🤩", "🥳", "😏",
                "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣",
                "😖", "😫", "😩", "😢", "😭", "😤", "😠",
                "😡", "🤬", "🤗", "🤔", "🤭", "🤫", "🤥",
                "😐", "😑", "😬", "🙄", "😯", "😦", "😧",
                "😲", "🥱", "😴", "🤤", "😪", "😵", "🤐", "🥴",
                "🤢", "🤮", "🤧", "😷", "🤒", "🤕", "🤑", "🤠"
            ]
        ),
        EmojiCategory(
            id: "gestures",
            title: "手势与人物",
            emojis: [
                "👋", "🤚", "🖐️", "✋", "🖖", "👌", "🤏", "✌️",
                "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "👇",
                "☝️", "👍", "👎", "✊", "👊", "🤝", "🙏", "👏",
                "🙌", "👐", "💪", "👀", "👂", "👃", "👶", "🧒",
                "👦", "👧", "🧑", "👨", "👩", "🧓", "👴", "👵"
            ]
        ),
        EmojiCategory(
            id: "objects",
            title: "物品与符号",
            emojis: [
                "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
                "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖",
                "💘", "💝", "💟", "🔥", "✨", "⭐", "🌟", "💫",
                "🎉", "🎊", "✅", "❌", "⚠️", "❗", "❓", "💯",
                "☀️", "🌈", "☁️", "☕", "🍎", "🍉", "🍔", "🍕",
                "⚽", "🏀", "🎵", "🎶", "🎁", "📌", "💡", "🚀"
            ]
        )
    ]
}
