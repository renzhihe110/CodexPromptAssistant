import AppKit
import SwiftUI

// MARK: - 保留中文输入法行为的原生编辑器

struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let onSubmit: (() -> Void)?
    let onPasteImage: (NSImage) -> Void
    let onDropFile: (URL) -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 54))
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 16)
        editor.textColor = .labelColor
        editor.insertionPointColor = NSColor(AssistantPalette.accent)
        editor.textContainerInset = NSSize(width: 0, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 54)
        // 显式使用 CGFloat，避免尺寸初始化时的浮点类型推断歧义。
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.delegate = context.coordinator
        editor.string = text
        editor.onSubmit = onSubmit
        editor.onPasteImage = onPasteImage
        editor.onDropFile = onDropFile
        editor.onHeightChange = onHeightChange
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? PromptTextView else {
            return
        }
        context.coordinator.parent = self
        editor.isEditable = enabled
        editor.onSubmit = onSubmit
        editor.onPasteImage = onPasteImage
        editor.onDropFile = onDropFile
        editor.onHeightChange = onHeightChange
        // 输入法仍在组字时，不用 SwiftUI 的旧值覆盖 marked text。
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            if enabled, !text.isEmpty {
                editor.window?.makeFirstResponder(editor)
            }
            editor.reportHeight()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor

        init(_ parent: ComposerEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? PromptTextView else {
                return
            }
            parent.text = editor.string
            editor.reportHeight()
        }
    }
}

final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteImage: ((NSImage) -> Void)?
    var onDropFile: ((URL) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    private var lastHeight: CGFloat = 0

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if let onSubmit, isReturn, !hasMarkedText(), !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else {
            return
        }
        let pasteboard = NSPasteboard.general
        if pasteboard.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pasteboard) {
            onPasteImage?(image)
            return
        }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isEditable, sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else {
            return false
        }
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls {
                onDropFile?(url)
            }
            return true
        }
        if let image = NSImage(pasteboard: pasteboard) {
            onPasteImage?(image)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func layout() {
        super.layout()
        reportHeight()
    }

    func reportHeight() {
        guard let layoutManager, let textContainer, bounds.width > 10 else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let height = min(160, max(54, layoutManager.usedRect(for: textContainer).height + 18))
        guard abs(height - lastHeight) > 1 else {
            return
        }
        lastHeight = height
        DispatchQueue.main.async { [weak self] in
            self?.onHeightChange?(height)
        }
    }
}
