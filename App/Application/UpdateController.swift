import AppKit

// 菜单和启动检查共享一次请求；手动检查可接收正在进行的静默检查结果。
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: String {
        case checking = "正在检查更新…"
        case downloading = "正在下载并解压更新…"
    }

    @Published private(set) var phase: Phase?
    private var showResult = false

    func check(manual: Bool) {
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
                guard confirm("发现新版提示词助手 \(version)", "当前版本为 \(current)。将下载并解压到「下载」文件夹，完成后可在 Finder 中手动替换。", action: "更新") else { return }
                showResult = true
                phase = .downloading
                let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let result = try await ReleaseUpdate.download(release: release, version: version, to: downloads)
                NSWorkspace.shared.activateFileViewerSelecting([result.app])
                if let warning = result.securityWarning {
                    alert("已下载并解压，尚未安装", warning + "\n请保留旧版，等待可通过安全校验的安装包。")
                } else {
                    alert("已下载并解压，尚未安装", "Finder 已选中新版。请先保存需要的轮次内容，自行退出旧版，再将「提示词助手.app」拖到「应用程序」并选择「替换」。")
                }
            } catch {
                if showResult { alert("更新未完成", error.localizedDescription) }
            }
        }
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
