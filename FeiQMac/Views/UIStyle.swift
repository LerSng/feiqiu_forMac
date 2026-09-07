//
//  UIStyle.swift
//  FeiQMac
//
//  定义应用界面统一使用的颜色、背景、边框、阴影和基础视觉设计令牌。
//

import AppKit
import SwiftUI

enum FeiQUI {
    static let windowBackground = adaptive(light: 0xFAFBFD, dark: 0x1C1E23)
    static let sidebarBackground = adaptive(light: 0xF1F3F7, dark: 0x22252C)
    static let listBackground = sidebarBackground
    static let chatBackground = windowBackground
    static let cardBackground = adaptive(light: 0xFFFFFF, dark: 0x2B2E36)
    static let inputBackground = cardBackground
    static let incomingBubble = adaptive(light: 0xEDEFF3, dark: 0x30343D)
    static let outgoingBubble = adaptive(light: 0xDFE9FF, dark: 0x2B4167)
    static let composerBackground = cardBackground
    static let selectedBackground = adaptive(light: 0xDFE7F5, dark: 0x32415A)
    static let separator = Color.primary.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.045)
    static let unreadBadge = Color(red: 0.93, green: 0.25, blue: 0.31)
    static let accent = adaptive(light: 0x3867D6, dark: 0x8AAFFF)
    static let accentSoft = accent.opacity(0.10)
    static let actionFill = Color(red: 0.22, green: 0.40, blue: 0.84)
    static let rowRadius: CGFloat = 12

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}

extension View {
    /// 永久隐藏滚动条，保留触控板、鼠标滚轮及程序化滚动。
    func hiddenScrollIndicators() -> some View {
        scrollIndicators(.never)
    }
}
