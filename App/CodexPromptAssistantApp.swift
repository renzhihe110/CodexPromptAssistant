import AppKit
import SwiftUI
import Carbon
import Combine

// MARK: - 菜单栏应用入口

@main
@MainActor
struct CodexPromptAssistantApp: App {
    @NSApplicationDelegateAdaptor(AssistantAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("提示词助手", systemImage: "text.bubble.fill") {
            Button("打开提示词助手") {
                delegate.windowController?.show()
            }
            .keyboardShortcut("p", modifiers: [.control, .option, .command])
            Text("提示词助手窗口内按 ⌘D 收起或展开")
            Divider()
            Button("退出提示词助手") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AssistantAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowController: AssistantWindowController?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        let controller = AssistantWindowController(state: state)
        windowController = controller
        controller.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.show()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else {
            return .terminateLater
        }
        terminating = true
        Task {
            await windowController?.state.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - 关闭时隐藏，唤起时继续同一轮问答

// 由面板自身处理快捷键，文本框有焦点时也能切换标题栏。
private final class AssistantPanel: NSPanel {
    var toggleCollapsed: (() -> Void)?
    var onNewPointerGesture: (() -> Void)?

    // 新的鼠标操作结束上一轮移动保护，允许用户随后正常拖边缩放。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onNewPointerGesture?()
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control, .function])
        guard isKeyWindow, attachedSheet == nil, modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "d", let toggleCollapsed else {
            return super.performKeyEquivalent(with: event)
        }
        if !event.isARepeat {
            toggleCollapsed()
        }
        return true
    }
}

@MainActor
final class AssistantWindowController: NSObject, NSWindowDelegate {
    let state: AppState
    private let panel: AssistantPanel
    private var shortcut: GlobalShortcut?
    // 只保存被收起操作临时替换的高度约束；宽度和位置始终沿用当前窗口。
    private var collapseObservation: AnyCancellable?
    private var compactContentHeight: CGFloat?
    private let minimumExpandedHeight: CGFloat
    private var lastExpandedHeight: CGFloat?
    private var expandedMove: (screen: NSScreen, size: NSSize)?
    private var expandedLayout: (height: CGFloat, minSize: NSSize, maxSize: NSSize)?

    init(state: AppState) {
        self.state = state
        // 按外框设置启动尺寸，标题栏包含在 450 × 600 点之内。
        let screen = NSScreen.main?.visibleFrame
        let size = NSSize(width: min(450, screen?.width ?? 450), height: min(600, screen?.height ?? 600))
        minimumExpandedHeight = size.height
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let frame = NSRect(origin: .zero, size: size)
        panel = AssistantPanel(contentRect: NSWindow.contentRect(forFrameRect: frame, styleMask: mask), styleMask: mask, backing: .buffered, defer: false)
        super.init()
        panel.title = "提示词助手"
        // 让品牌和工具按钮进入系统标题栏，保留原生红绿灯、窗口拖动和边缘缩放。
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "PromptAssistantTitlebar")
        toolbar.displayMode = .iconOnly
        panel.toolbar = toolbar
        addTitlebarView(HStack(spacing: 9) {
            Image(nsImage: WelcomeArtwork.wand)
                .resizable()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text("提示词助手")
                .font(.system(size: 16, weight: .semibold))
        }.padding(.leading, 3), at: .left)
        addTitlebarView(WindowTitleActions(state: state) { [weak panel] pinned in
            panel?.level = pinned ? .floating : .normal
        }.padding(.trailing, 12), at: .right)
        panel.backgroundColor = NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.99, alpha: 1)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = self
        let hosting = NSHostingView(rootView: ChatView(state: state, onCompactHeightChange: { [weak self] height in
            // 避免在 SwiftUI 的布局回调内同步改变承载它的原生窗口。
            DispatchQueue.main.async { [weak self] in
                self?.applyPanelLayout(contentHeight: height)
            }
        }))
        // 由面板管理尺寸，避免 SwiftUI 内容的理想宽度反向撑大窗口。
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.minSize = size
        panel.setFrame(frame, display: false)
        if let screen {
            // 贴近当前屏幕右上角，并给菜单栏和 Dock 留出可见空间。
            let left = max(screen.minX, screen.maxX - size.width - 16)
            let top = max(screen.minY + size.height, screen.maxY - 16)
            panel.setFrameTopLeftPoint(NSPoint(x: left, y: top))
        } else {
            panel.center()
        }
        // 在状态切换时保存或恢复展开尺寸，不依赖 SwiftUI 是否再次报告输入栏高度。
        collapseObservation = state.$isWindowCollapsed.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.applyPanelLayout(contentHeight: nil)
        }
        shortcut = GlobalShortcut(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.togglePanelVisibility()
        }
        panel.onNewPointerGesture = { [weak self] in
            self?.expandedMove = nil
        }
        panel.toggleCollapsed = { [weak state] in
            state?.isWindowCollapsed.toggle()
        }
        if shortcut?.registered != true {
            state.information = "快捷键 ⌃⌥⌘P 注册失败，可能已被占用。可以通过菜单栏打开提示词助手。"
        }
    }

    // ⌃⌥⌘P 单独负责整窗显隐。
    private func togglePanelVisibility() {
        if panel.isVisible, panel.isKeyWindow, !panel.isMiniaturized {
            panel.orderOut(nil)
            return
        }
        show()
    }

    // 将视图附着在原生标题栏两端，避开工具栏按钮自带的胶囊底色。
    private func addTitlebarView<Content: View>(_ content: Content, at edge: NSLayoutConstraint.Attribute) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = edge
        let host = NSHostingView(rootView: content.fixedSize().preferredColorScheme(.light))
        host.setFrameSize(host.fittingSize)
        accessory.view = host
        panel.addTitlebarAccessoryViewController(accessory)
    }

    // 按当前状态应用排队的更新，过期的高度报告不能把展开窗口重新压小。
    private func applyPanelLayout(contentHeight: CGFloat?) {
        let collapsed = state.isWindowCollapsed
        if collapsed != (expandedLayout != nil) {
            setPanelCollapsed(collapsed)
        }
        if collapsed {
            resizeForComposer(contentHeight)
        }
    }

    // 标题栏和高度约束随同一次收起状态切换，测量回调只负责给紧凑窗口定高。
    private func setPanelCollapsed(_ collapsed: Bool) {
        expandedMove = nil
        if collapsed {
            rememberExpandedHeight()
            expandedLayout = (lastExpandedHeight ?? minimumExpandedHeight, panel.minSize, panel.maxSize)
        }
        guard let layout = expandedLayout else {
            return
        }
        let frame = panel.frame
        panel.titlebarAccessoryViewControllers.first(where: { $0.layoutAttribute == .left })?.isHidden = collapsed
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = collapsed
        }
        if !collapsed {
            compactContentHeight = nil
            expandedLayout = nil
            panel.maxSize = layout.maxSize
            panel.minSize = layout.minSize
            setPanelHeight(layout.height, anchoredTo: frame)
        }
    }

    private func resizeForComposer(_ contentHeight: CGFloat?) {
        if let contentHeight, contentHeight > 0 {
            compactContentHeight = contentHeight
        }
        guard let compactContentHeight, state.isWindowCollapsed, let layout = expandedLayout else {
            return
        }
        let frame = panel.frame
        // 用 AppKit 的内容到外框换算，避免跨屏时混用正在变化的外框和旧布局的高度。
        let content = NSRect(origin: .zero, size: NSSize(width: frame.width, height: compactContentHeight))
        let height = ceil(panel.frameRect(forContentRect: content).height)
        guard frame.height != height || panel.minSize.height != height || panel.maxSize.height != height else {
            return
        }
        panel.maxSize = layout.maxSize
        panel.minSize = NSSize(width: layout.minSize.width, height: height)
        panel.maxSize = NSSize(width: layout.maxSize.width, height: height)
        setPanelHeight(height, anchoredTo: frame)
    }

    // 跨屏时系统可能恢复目标屏上一次的窗口高度。只从移动前或手动缩放结束时记录展开高度。
    private func rememberExpandedHeight() {
        if expandedLayout == nil, panel.frame.height >= minimumExpandedHeight {
            lastExpandedHeight = panel.frame.height
        }
    }

    func windowWillMove(_ notification: Notification) {
        rememberExpandedHeight()
        if !state.isWindowCollapsed, let screen = panel.screen, panel.frame.height >= minimumExpandedHeight {
            expandedMove = (screen, panel.frame.size)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberExpandedHeight()
        scheduleSizeCheck()
    }

    func windowDidResize(_ notification: Notification) {
        if state.isWindowCollapsed || expandedMove != nil || panel.frame.height < minimumExpandedHeight {
            scheduleSizeCheck()
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        scheduleSizeCheck()
    }

    // 松开标题栏时系统还可能再次调整外框。按展开模式自身的下限判断，不采用系统重排中的临时 minSize。
    private func scheduleSizeCheck() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !panel.inLiveResize else {
                return
            }
            if state.isWindowCollapsed {
                resizeForComposer(nil)
            } else if let move = expandedMove, let screen = panel.screen, screen != move.screen {
                // 拖动松手后，系统可能套用目标屏上一次的尺寸，即使那也是合法的展开高度。
                let size = NSSize(width: min(move.size.width, screen.visibleFrame.width), height: min(move.size.height, screen.visibleFrame.height))
                if panel.frame.size != size {
                    var target = panel.frame
                    target.origin.y = max(screen.visibleFrame.minY, min(target.maxY - size.height, screen.visibleFrame.maxY - size.height))
                    target.size = size
                    panel.setFrame(target, display: true)
                }
            } else if expandedLayout == nil, panel.frame.height < minimumExpandedHeight {
                let height = lastExpandedHeight ?? minimumExpandedHeight
                let visibleHeight = panel.screen?.visibleFrame.height ?? height
                if panel.frame.height != min(height, visibleHeight) {
                    setPanelHeight(height, anchoredTo: panel.frame)
                }
            }
        }
    }

    // 保留当前宽度和上边缘，展开时必要地上移，使输入栏仍在屏幕内。
    private func setPanelHeight(_ height: CGFloat, anchoredTo frame: NSRect) {
        var target = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        if let visible = panel.screen?.visibleFrame {
            target.size.height = min(target.height, visible.height)
            target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        }
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }
    }

    func show() {
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if lastExpandedHeight == nil {
            rememberExpandedHeight()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// 设置沿用当前模型设置视图，头像展示本机用户，均不触发新的模型请求。
private struct WindowTitleActions: View {
    @ObservedObject var state: AppState
    let onPinChange: (Bool) -> Void
    @State private var isPinned = true
    @State private var showSettings = false
    @State private var showUser = false

    var body: some View {
        // 两种窗口状态共用同一组紧凑排列的工具按钮。
        HStack(spacing: 4) {
            // 全窗操作归入标题栏，收起和展开时使用同一份置顶状态。
            Button(action: state.reconnect) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(state.isBusy || state.isConnecting)
            .help("重新连接 Codex")
            .accessibilityLabel(state.isConnecting ? "连接中" : "重新连接")
            Button {
                isPinned.toggle()
                onPinChange(isPinned)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isPinned ? AssistantPalette.accent : .secondary)
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isPinned ? "取消窗口置顶" : "将窗口置顶")
            .help(isPinned ? "取消窗口置顶" : "将窗口置顶")
            Divider()
                .frame(height: 21)
            Button {
                state.isWindowCollapsed.toggle()
            } label: {
                // 箭头周围的留白也响应点击，两个状态共用同一块矩形热区。
                Image(systemName: state.isWindowCollapsed ? "chevron.down" : "chevron.up")
                    .frame(width: 44, height: 34)
                    .contentShape(Rectangle())
            }
            .help(state.isWindowCollapsed ? "展开对话窗口" : "收起为输入栏")
            .accessibilityLabel(state.isWindowCollapsed ? "展开对话窗口" : "收起为输入栏")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .frame(width: 27, height: 27)
            }
            .help("模型与推理设置")
            .accessibilityLabel("模型与推理设置")
            .popover(isPresented: $showSettings) {
                ModelSettingsView(state: state)
            }
            Button {
                showUser = true
            } label: {
                Image(nsImage: WelcomeArtwork.profile)
                    .resizable()
                    .frame(width: 27, height: 27)
            }
            .help("本机用户")
            .accessibilityLabel("本机用户")
            .popover(isPresented: $showUser) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("本机用户")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(NSFullUserName())
                }
                .padding(16)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .preferredColorScheme(.light)
    }
}

// Carbon 的全局快捷键不会监听或记录用户的其他按键。
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    let onPress: () -> Void
    private(set) var registered = false

    private let identifier: EventHotKeyID

    init(keyCode: Int, modifiers: Int, onPress: @escaping () -> Void) {
        identifier = EventHotKeyID(signature: 0x43504131, id: UInt32(keyCode))
        self.onPress = onPress
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else {
                return OSStatus(eventNotHandledErr)
            }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
            // 多个快捷键共享事件目标，只消费属于当前注册项的按键。
            var pressed = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr, pressed.signature == shortcut.identifier.signature, pressed.id == shortcut.identifier.id else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in
                shortcut.onPress()
            }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else {
            return
        }
        registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), identifier, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
    }
}
