import AppKit
import CryptoKit

struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// 发布方使用 v主.次.修订 标签；只接受仓库约定的正式版和 ZIP 文件名。
struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let digest: String?
        let size: Int
    }

    let tag_name: String
    let prerelease: Bool
    let draft: Bool
    let assets: [Asset]
    static let repository = "https://github.com/renzhihe110/CodexPromptAssistant"

    func newerVersion(than current: String) throws -> String? {
        guard !draft, !prerelease else { return nil }
        let next = String(tag_name.dropFirst())
        let pattern = #"^[0-9]+\.[0-9]+\.[0-9]+$"#
        guard tag_name.first == "v", next.range(of: pattern, options: .regularExpression) != nil,
              current.range(of: pattern, options: .regularExpression) != nil else {
            throw UpdateFailure("无法识别应用或 Release 的版本号。")
        }
        return next.compare(current, options: .numeric) == .orderedDescending ? next : nil
    }

    func package(version: String, architecture: String) throws -> Asset {
        for suffix in [architecture, "universal"] {
            let name = "CodexPromptAssistant-\(version)-macOS-\(suffix).zip"
            if let asset = assets.first(where: { $0.name == name }) {
                guard asset.size > 0, asset.size <= 150 * 1024 * 1024,
                      asset.digest?.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                    throw UpdateFailure("安装包大小或 GitHub 提供的 SHA-256 摘要无效。")
                }
                return asset
            }
        }
        throw UpdateFailure("此版本没有适配当前 Mac 的安装包。")
    }
}

enum ReleaseUpdate {
    // 即使应用通过 Rosetta 运行，也按实际硬件选择安装包。
    static var architecture: String {
        var arm64: Int32 = 0
        var size = MemoryLayout.size(ofValue: arm64)
        sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        return arm64 == 1 ? "arm64" : "x86_64"
    }

    static func latest() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/renzhihe110/CodexPromptAssistant/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(response)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == "https" else {
            throw UpdateFailure("GitHub 请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
    }

    // 临时目录与安装位置在同一卷；下载、解压或安全检查失败时，原包尚未动过。
    static func prepare(release: GitHubRelease, version: String, installed: URL) async throws -> URL {
        let asset = try release.package(version: version, architecture: architecture)
        let url = URL(string: "\(GitHubRelease.repository)/releases/download/\(release.tag_name)/\(asset.name)")!
        let (archive, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        try requireSuccess(response)
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count == asset.size,
              "sha256:" + SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.digest else {
            throw UpdateFailure("下载的 ZIP 与 GitHub 的 SHA-256 或大小不符，请重新下载。")
        }
        let fm = FileManager.default
        let stage = installed.deletingLastPathComponent().appendingPathComponent(".prompt-update-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            // bsdtar 默认拒绝 .. 和穿越符号链接的解压路径，不启用 -P。
            try command("/usr/bin/tar", ["-xf", archive.path, "-C", stage.path, "--no-same-owner"], failure: "解压安装包失败")
            let app = stage.appendingPathComponent("提示词助手.app")
            let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw UpdateFailure("ZIP 中缺少有效的「提示词助手.app」。")
            }
            // 让 Launch Services 保留网络来源标记，并在替换前显式执行 Gatekeeper 评估。
            let quarantine: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                                              kLSQuarantineDataURLKey as String: url]
            try (app as NSURL).setResourceValue(quarantine, forKey: .quarantinePropertiesKey)
            try validate(app, version: version)
            return app
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    static func validate(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              let executable = bundle.executableURL, executable.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/Contents/MacOS/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateFailure("安装包的应用标识、版本或可执行文件不匹配。")
        }
        let cpu = architecture == "arm64" ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64
        guard bundle.executableArchitectures?.contains(NSNumber(value: cpu)) == true else {
            throw UpdateFailure("安装包不支持当前 Mac 的处理器。")
        }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard current.compare(minimum, options: .numeric) != .orderedAscending else {
                throw UpdateFailure("此版本需要 macOS \(minimum) 或更高版本。")
            }
        }
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", app.path], failure: "应用签名校验失败")
        try command("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", app.path], failure: "macOS 安全校验未通过，无法安装此版本")
    }

    // 原子交换保留完整旧包；第二次交换可在启动失败时还原原安装路径。
    static func exchange(_ installed: URL, _ staged: URL) throws {
        guard renamex_np(installed.path, staged.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure("无法交换应用包：\(String(cString: strerror(errno)))")
        }
    }

    private static func command(_ path: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = output
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: message.prefix(1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateFailure(detail.isEmpty ? failure : "\(failure)（\(detail)）")
        }
    }
}
