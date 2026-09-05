import SwiftUI

struct GroupAvatar: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(FeiQUI.accent.opacity(0.14))
            .overlay {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(FeiQUI.accent)
            }
            .frame(width: size, height: size)
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

            if isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: max(8, size * 0.25), height: max(8, size * 0.25))
                    .overlay {
                        Circle()
                            .stroke(FeiQUI.cardBackground, lineWidth: 2)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(name.isEmpty ? "飞秋 Mac" : name)
    }
}

struct ContactAvatar: View {
    let name: String
    let isOnline: Bool
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.blue.opacity(isOnline ? 0.15 : 0.10))
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(isOnline ? FeiQUI.accent : Color.secondary)
                }

            Circle()
                .fill(isOnline ? Color.green : Color.gray.opacity(0.72))
                .frame(width: max(8, size * 0.25), height: max(8, size * 0.25))
                .overlay {
                    Circle()
                        .stroke(FeiQUI.listBackground, lineWidth: 2)
                }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(name)
    }
}
