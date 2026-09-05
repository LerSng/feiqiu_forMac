//
//  UIStyle.swift
//  FeiQMac
//
//  定义应用界面统一使用的颜色、背景、边框、阴影和基础视觉设计令牌。
//

import SwiftUI

enum FeiQUI {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
    static let railBackground = Color(nsColor: .controlBackgroundColor).opacity(0.82)
    static let listBackground = Color(nsColor: .underPageBackgroundColor)
    static let chatBackground = Color(nsColor: .textBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let inputBackground = Color(nsColor: .textBackgroundColor)
    static let incomingBubble = Color(nsColor: .underPageBackgroundColor)
    static let outgoingBubble = Color(red: 0.58, green: 0.92, blue: 0.62)
    static let composerBackground = Color(nsColor: .textBackgroundColor)
    static let selectedBackground = Color.accentColor.opacity(0.14)
    static let selectedBorder = Color.accentColor.opacity(0.28)
    static let separator = Color.primary.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.045)
    static let unreadBadge = Color(red: 0.93, green: 0.25, blue: 0.31)
    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.12)
    static let rowRadius: CGFloat = 12
}
