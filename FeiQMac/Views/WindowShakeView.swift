//
//  WindowShakeView.swift
//  FeiQMac
//
//  将 ViewModel 的抖动事件转换为当前窗口动画；支持取消和减少动态效果。
//

import AppKit
import SwiftUI
import QuartzCore

struct WindowShakeView: NSViewRepresentable {
    let eventID: UUID

    func makeCoordinator() -> Coordinator { Coordinator(eventID: eventID) }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.eventID != eventID else { return }
        context.coordinator.eventID = eventID
        context.coordinator.shake(view.window)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        var eventID: UUID
        private var animation: Task<Void, Never>?
        private weak var window: NSWindow?
        private var originalOrigin: NSPoint?

        init(eventID: UUID) { self.eventID = eventID }

        func cancel() {
            animation?.cancel()
            animation = nil
            window?.contentView?.layer?.removeAnimation(forKey: "feiq.shake")
            if let originalOrigin { window?.setFrameOrigin(originalOrigin) }
            originalOrigin = nil
        }

        func shake(_ window: NSWindow?) {
            cancel()
            guard let window, window.isVisible, !window.isMiniaturized,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            self.window = window
            // Full-screen windows cannot move; animate the content instead.
            if window.styleMask.contains(.fullScreen) {
                guard let content = window.contentView else { return }
                content.wantsLayer = true
                let effect = CAKeyframeAnimation(keyPath: "transform.translation.x")
                effect.values = [0, -8, 8, -6, 6, -3, 3, 0]
                effect.duration = 0.4
                content.layer?.add(effect, forKey: "feiq.shake")
                return
            }
            let origin = window.frame.origin
            originalOrigin = origin
            animation = Task { [weak self, weak window] in
                for offset in [0.0, -8, 8, -6, 6, -4, 4, -2, 2, 0] {
                    guard !Task.isCancelled, let window else { return }
                    window.setFrameOrigin(NSPoint(x: origin.x + offset, y: origin.y))
                    do { try await Task.sleep(for: .milliseconds(40)) }
                    catch { return }
                }
                self?.originalOrigin = nil
                self?.animation = nil
            }
        }
    }
}
