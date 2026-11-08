import AppKit

// 菜单和启动检查共享一次请求；手动检查可接收正在进行的静默检查结果。
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: String {
        case checking = "正在检查更新…"
        case downloading = "正在下载并校验更新…"
        case relaunching = "正在重新打开提示词助手…"
    }

    @Published private(set) var phase: Phase?
    private let installedIdentity = try? Bundle.main.bundleURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    private var showResult = false
    private(set) var switching = false

    func check(state: AppState, manual: Bool) {
        if manual { showResult = true }
        guard phase == nil else { return }
        phase = .checking
        Task {
            defer { phase = nil; showResult = false }
            do {
                let release = try await ReleaseUpdate.latest()
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                guard let version = try release.newerVersion(than: current) else {
                    if showResult { alert("已是最新版本", "当前版本为 \(current)。") }
                    return
                }
                _ = try release.package(version: version, architecture: ReleaseUpdate.architecture)
                guard confirm("发现新版提示词助手 \(version)", "当前版本为 \(current)。下载完成后会校验安装包并重新打开应用。", action: "更新") else { return }
                showResult = true
                phase = .downloading
                let installed = Bundle.main.bundleURL
                let staged = try await ReleaseUpdate.prepare(release: release, version: version, installed: installed)
                if try finish(staged: staged, installed: installed, state: state) {
                    // 只有完成安装和备份清理后才正常退出，释放快捷键和本轮附件。
                    NSApp.terminate(nil)
                }
            } catch {
                if showResult { alert("更新未完成", error.localizedDescription) }
            }
        }
    }

    private func finish(staged: URL, installed: URL, state: AppState) throws -> Bool {
        let directory = staged.deletingLastPathComponent()
        var keepBackup = false
        defer { if !keepBackup { try? FileManager.default.removeItem(at: directory) } }
        // 下载期间仍可编辑，因此在最后一次可取消的位置重新检查所有内存轮次。
        if state.hasUnsavedRounds && !confirm("有尚未保存的轮次", "重启会清空输入、附件和本轮结果。可先取消更新并复制需要的内容。", action: "继续更新") { return false }
        phase = .relaunching
        switching = true
        defer { switching = false }
        // 其他进程可能在下载期间换过安装包，避免覆盖用户刚安装的版本。
        let currentIdentity = try installed.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        guard let installedIdentity, installedIdentity.isEqual(currentIdentity),
              NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").filter({ $0.bundleURL == installed && !$0.isTerminated }).count <= 1 else {
            throw UpdateFailure("安装位置已变化，或另一个提示词助手实例正在运行。请重新打开安装位置的应用后再试。")
        }
        try ReleaseUpdate.exchange(installed, staged)
        do {
            try launchReplacement(installed)
        } catch {
            do {
                try ReleaseUpdate.exchange(installed, staged)
            } catch {
                keepBackup = true
                throw UpdateFailure("无法自动还原旧版。旧版保留在 \(staged.path)。\n\(error.localizedDescription)")
            }
            throw UpdateFailure("新版启动失败，已恢复旧版。\n\(error.localizedDescription)")
        }
        return true
    }

    // 模态窗口锁住交接期间的输入。通过 Launch Services 启动，失败时旧进程仍可使用。
    private func launchReplacement(_ installed: URL) throws {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 290, height: 52), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "正在重新打开提示词助手…"
        panel.level = .modalPanel
        panel.center()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--replacing-process", String(ProcessInfo.processInfo.processIdentifier)]
        var failure: Error?
        NSWorkspace.shared.openApplication(at: installed, configuration: configuration) { app, error in
            RunLoop.main.perform(inModes: [.modalPanel]) {
                guard error == nil, let app, app.bundleURL?.standardizedFileURL.path == installed.standardizedFileURL.path,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    failure = error ?? UpdateFailure("系统未启动安装位置的新版应用。")
                    NSApp.stopModal()
                    return
                }
                // Launch Services 可能在初始化结束前返回；确认新实例可用才释放旧包。
                let deadline = Date().addingTimeInterval(20)
                let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
                    if app.isTerminated || Date() >= deadline {
                        if !app.isTerminated { _ = app.terminate() }
                        failure = UpdateFailure("新版已退出或未能及时完成启动。")
                    } else if !app.isFinishedLaunching {
                        return
                    }
                    timer.invalidate()
                    NSApp.stopModal()
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        if let failure { throw failure }
    }

    private func alert(_ title: String, _ detail: String) {
        let panel = makeAlert(title, detail)
        panel.addButton(withTitle: "好")
        panel.runModal()
    }

    private func confirm(_ title: String, _ detail: String, action: String) -> Bool {
        let panel = makeAlert(title, detail)
        panel.addButton(withTitle: action)
        let cancel = panel.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"
        return panel.runModal() == .alertFirstButtonReturn
    }

    private func makeAlert(_ title: String, _ detail: String) -> NSAlert {
        let panel = NSAlert()
        panel.messageText = title
        panel.informativeText = detail
        panel.window.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        return panel
    }
}
