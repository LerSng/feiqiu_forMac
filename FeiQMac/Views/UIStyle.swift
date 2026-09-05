//
//  UIStyle.swift
//  FeiQMac
//
//  定义应用界面统一使用的颜色、背景、边框、阴影和基础视觉设计令牌。
//

import AppKit
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

/// Configures the nearest AppKit scroll view to use an overlay scroller that
/// appears while scrolling and fades out when the content becomes idle.
struct FeiQScrollViewConfigurationBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureScrollView(near: nsView, coordinator: context.coordinator)

        // SwiftUI can attach the representable after the first update. A
        // second pass covers that lifecycle timing on different macOS builds.
        DispatchQueue.main.async {
            configureScrollView(near: nsView, coordinator: context.coordinator)
        }
    }

    private func configureScrollView(
        near view: NSView,
        coordinator: Coordinator
    ) {
        guard let scrollView = view.enclosingScrollView else { return }
        coordinator.attach(to: scrollView)
    }

    final class Coordinator {
        private weak var observedScrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var visibilityGeneration = 0

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func attach(to scrollView: NSScrollView) {
            guard observedScrollView !== scrollView else { return }

            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }

            observedScrollView = scrollView
            scrollView.scrollerStyle = .overlay
            // The visibility is controlled explicitly so the app behaves the
            // same even when macOS is configured to always show scroll bars.
            scrollView.autohidesScrollers = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.verticalScrollElasticity = .none
            scrollView.contentView.postsBoundsChangedNotifications = true
            hideScrollers(on: scrollView, animated: false)

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                self.showScrollersWhileScrolling(on: scrollView)
            }
        }

        private func showScrollersWhileScrolling(on scrollView: NSScrollView) {
            visibilityGeneration += 1
            let generation = visibilityGeneration
            setScrollers(on: scrollView, visible: true, animated: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak scrollView] in
                guard let self,
                      let scrollView,
                      self.visibilityGeneration == generation else { return }
                self.hideScrollers(on: scrollView, animated: true)
            }
        }

        private func hideScrollers(on scrollView: NSScrollView, animated: Bool) {
            setScrollers(on: scrollView, visible: false, animated: animated)
        }

        private func setScrollers(
            on scrollView: NSScrollView,
            visible: Bool,
            animated: Bool
        ) {
            let scrollers = [scrollView.verticalScroller, scrollView.horizontalScroller]
                .compactMap { $0 }

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = visible ? 0.12 : 0.18
                    for scroller in scrollers {
                        scroller.isHidden = false
                        scroller.animator().alphaValue = visible ? 1 : 0
                    }
                } completionHandler: {
                    if !visible {
                        for scroller in scrollers {
                            scroller.isHidden = true
                        }
                    }
                }
            } else {
                for scroller in scrollers {
                    scroller.alphaValue = visible ? 1 : 0
                    scroller.isHidden = !visible
                }
            }
        }
    }
}

private struct AutoHidingScrollIndicatorsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollIndicators(.automatic)
            .background(FeiQScrollViewConfigurationBridge())
    }
}

extension View {
    /// 使用 macOS overlay 滚动条：滚动时显示，停止后自动隐藏。
    func autoHidingScrollIndicators() -> some View {
        modifier(AutoHidingScrollIndicatorsModifier())
    }
}
