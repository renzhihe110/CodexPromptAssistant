import Foundation

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
