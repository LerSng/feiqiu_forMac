//
//  AvatarViews.swift
//  FeiQMac
//
//  本机、联系人和群聊共用的低饱和头像与在线标记。
//

import SwiftUI

struct GroupAvatar: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "person.3.fill")
            .font(.system(size: size * 0.37, weight: .medium))
            .foregroundStyle(FeiQUI.accent)
            .frame(width: size, height: size)
            .background(FeiQUI.accentSoft, in: RoundedRectangle(cornerRadius: size * 0.3))
    }
}

struct LocalAvatar: View {
    let name: String
    let isOnline: Bool
    let size: CGFloat
    var body: some View {
        ContactAvatar(name: name.isEmpty ? "飞秋" : name, isOnline: isOnline, size: size)
    }
}

struct ContactAvatar: View {
    let name: String
    let isOnline: Bool
    let size: CGFloat
    var showsStatus = true

    private var initial: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "友" : String(value.prefix(1)).uppercased()
    }

    private var tint: Color {
        let palette: [Color] = [FeiQUI.accent, .teal, .indigo, .purple, .brown]
        let index = name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
        return isOnline ? palette[index] : .secondary
    }

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.39, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3))
            .overlay(alignment: .bottomTrailing) {
                if showsStatus {
                    Circle()
                        .fill(isOnline ? Color.green : Color.gray)
                        .frame(width: max(7, size * 0.21), height: max(7, size * 0.21))
                        .overlay { Circle().stroke(FeiQUI.sidebarBackground, lineWidth: 2) }
                        .offset(x: 1, y: 1)
                }
            }
            .accessibilityLabel(name)
    }
}
