//
//  CommonViews.swift
//  FeiQMac
//
//  集中定义跨页面复用的徽标、状态组件、卡片样式和列表选中态修饰器。
//

import SwiftUI

struct FeiQUnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 20, minHeight: 20)
                .padding(.horizontal, count > 9 ? 3 : 0)
                .background(FeiQUI.unreadBadge, in: Capsule())
                .shadow(color: FeiQUI.unreadBadge.opacity(0.24), radius: 3, y: 1)
                .transition(
                    .scale(scale: 0.45, anchor: .trailing)
                        .combined(with: .opacity)
                )
        }
    }
}

struct FeiQStatusDot: View {
    let color: Color
    let size: CGFloat

    init(color: Color, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

struct FeiQIconBadge: View {
    let systemImage: String
    let tint: Color
    let size: CGFloat

    init(systemImage: String, tint: Color = FeiQUI.accent, size: CGFloat = 38) {
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.50, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: Circle())
            .overlay {
                Circle()
                    .stroke(tint.opacity(0.14), lineWidth: 1)
            }
    }
}

struct FeiQStatusPill: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
    }
}

struct FeiQSurfaceModifier: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat
    let shadow: Bool

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(FeiQUI.separator, lineWidth: 1)
            }
            .shadow(
                color: shadow ? Color.black.opacity(0.05) : .clear,
                radius: shadow ? 6 : 0,
                y: shadow ? 2 : 0
            )
    }
}

struct FeiQSelectionRowModifier: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: FeiQUI.rowRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? FeiQUI.selectedBackground
                            : (isHovering ? Color.primary.opacity(0.055) : .clear)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: FeiQUI.rowRadius, style: .continuous)
                    .stroke(isSelected ? FeiQUI.selectedBorder : .clear, lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(FeiQUI.accent)
                        .frame(width: 3, height: 24)
                        .padding(.leading, 2)
                }
            }
    }
}

extension View {
    func feiQSurface(
        fill: Color,
        cornerRadius: CGFloat = 12,
        shadow: Bool = false
    ) -> some View {
        modifier(
            FeiQSurfaceModifier(
                fill: fill,
                cornerRadius: cornerRadius,
                shadow: shadow
            )
        )
    }

    func feiQSelectionRow(isSelected: Bool, isHovering: Bool) -> some View {
        modifier(
            FeiQSelectionRowModifier(
                isSelected: isSelected,
                isHovering: isHovering
            )
        )
    }
}
