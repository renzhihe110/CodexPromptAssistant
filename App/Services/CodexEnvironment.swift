import AppKit

// MARK: - 桌面进程启动环境

enum CodexEnvironment {
    static var home: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    static func executable() throws -> URL {
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let fixedPaths = [userHome + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        for path in fixedPaths + pathEntries {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // Finder 启动时 PATH 可能只含系统目录。用稳定的 bundle ID 定位桌面应用，兼容改名或移动的安装。
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            // 新版将 CLI 封装在独立的应用包内，旧版直接放在 Resources 下。
            for relativePath in ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"] {
                let candidate = app.appendingPathComponent(relativePath)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        throw AssistantError.codexNotFound
    }

    static var childEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let prefix = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = prefix + ":" + (environment["PATH"] ?? "")
        environment["CODEX_HOME"] = home.path
        // 辅助任务不继承调用本应用的聊天身份。
        environment.removeValue(forKey: "CODEX_THREAD_ID")
        environment.removeValue(forKey: "CODEX_INTERNAL_ORIGINATOR_OVERRIDE")
        return environment
    }

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.renzhihe.CodexPromptAssistant", isDirectory: true)
    }
}
