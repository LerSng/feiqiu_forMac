//
//  PasteAwareTextEditor.swift
//  FeiQMac
//
//  提供支持文本和图片剪贴板的消息输入框。图片由 ViewModel 接收后保存为
//  待发送附件，View 本身不访问 Repository 或网络服务。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PasteAwareTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onPasteImage: (Data, String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = PasteAwareNSTextView()
        view.delegate = context.coordinator
        view.onPasteImage = onPasteImage
        view.string = text
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textContainerInset = NSSize(width: 8, height: 5)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = view
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? PasteAwareNSTextView else { return }
        textView.onPasteImage = onPasteImage
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
            textView.scrollCaretIntoView()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteAwareTextEditor

        init(_ parent: PasteAwareTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            (textView as? PasteAwareNSTextView)?.scrollCaretIntoView()
        }
    }
}

final class PasteAwareNSTextView: NSTextView {
    var onPasteImage: ((Data, String?) -> Void)?

    func scrollCaretIntoView() {
        let selectedRange = selectedRange()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollRangeToVisible(selectedRange)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCommandV(event), pasteImageIfAvailable() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Some macOS text-input paths bypass performKeyEquivalent and send
        // the shortcut directly to keyDown. Handle both paths so image paste
        // does not depend on the source application.
        if Self.isCommandV(event), pasteImageIfAvailable() {
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if pasteImageIfAvailable() {
            return
        }
        super.paste(sender)
    }

    @discardableResult
    private func pasteImageIfAvailable() -> Bool {
        guard let payload = Self.imagePayload(from: NSPasteboard.general) else {
            return false
        }
        onPasteImage?(payload.data, payload.fileName)
        return true
    }

    private static func isCommandV(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.type == .keyDown
            && modifiers.contains(.command)
            && !modifiers.contains(.shift)
            && !modifiers.contains(.option)
            && !modifiers.contains(.control)
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    private static func imagePayload(
        from pasteboard: NSPasteboard
    ) -> (data: Data, fileName: String?)? {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType("org.webmproject.webp")
        ]

        if let types = pasteboard.types {
            for imageType in imageTypes where types.contains(imageType) {
                if let data = pasteboard.data(forType: imageType), !data.isEmpty {
                    return (data, nil)
                }
            }
        }

        // Finder copies an image as a file URL. Read it here so the regular
        // text editor never inserts a file path into the draft.
        if let fileURLData = pasteboard.data(forType: .fileURL),
           let fileURL = URL(dataRepresentation: fileURLData, relativeTo: nil),
           let data = try? Data(contentsOf: fileURL),
           !data.isEmpty {
            return (data, fileURL.lastPathComponent)
        }

        if let image = NSImage(pasteboard: pasteboard),
           let data = image.tiffRepresentation,
           !data.isEmpty {
            return (data, nil)
        }
        return nil
    }
}
