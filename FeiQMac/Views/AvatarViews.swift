//
//  AvatarViews.swift
//  FeiQMac
//
//  提供本机、联系人和群聊头像等可复用的 SwiftUI 组件。
//

import SwiftUI

struct GroupAvatar: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            FeiQUI.accent.opacity(0.92),
                            Color.purple.opacity(0.68)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.28), lineWidth: max(1, size * 0.035))
                }

            Image(systemName: "person.3.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
        }
            .frame(width: size, height: size)
            .shadow(color: FeiQUI.accent.opacity(0.20), radius: 5, y: 2)
    }
}

struct LocalAvatar: View {
    let name: String
    let isOnline: Bool
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [FeiQUI.accent.opacity(0.9), Color.blue.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: max(1, size * 0.035))
                }

            if isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: max(8, size * 0.25), height: max(8, size * 0.25))
                    .overlay {
                        Circle()
                            .stroke(FeiQUI.cardBackground, lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(name.isEmpty ? "飞秋 Mac" : name)
        .shadow(color: FeiQUI.accent.opacity(0.16), radius: 5, y: 2)
    }
}

struct ContactAvatar: View {
    let name: String
    let isOnline: Bool
    let size: CGFloat

    private var initial: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "友" : String(value.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: isOnline
                            ? [FeiQUI.accent.opacity(0.86), Color.blue.opacity(0.66)]
                            : [Color.gray.opacity(0.48), Color.gray.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Text(initial)
                        .font(.system(size: size * 0.40, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.24), lineWidth: max(1, size * 0.035))
                }

            Circle()
                .fill(isOnline ? Color.green : Color.gray.opacity(0.72))
                .frame(width: max(8, size * 0.25), height: max(8, size * 0.25))
                .overlay {
                    Circle()
                        .stroke(FeiQUI.listBackground, lineWidth: 2)
                }
                .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(name)
        .shadow(color: Color.black.opacity(isOnline ? 0.10 : 0.05), radius: 4, y: 2)
    }
}
