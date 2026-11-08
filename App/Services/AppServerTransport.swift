import Foundation
import Darwin

// MARK: - 只读 JSON-RPC 传输

actor AppServerTransport {
    enum Purpose: Equatable {
        case history
        case generation
    }

    private let purpose: Purpose
    private var notifications: AsyncStream<JSONValue>.Continuation?
    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?
    private var buffer = Data()
    private var scannedByteCount = 0
    private var nextID = 0
    private var sessionID = UUID()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]

    init(purpose: Purpose = .history) {
        self.purpose = purpose
    }

    func start(arguments: [String] = []) throws {
        stop()
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let currentSession = UUID()
        child.executableURL = try CodexEnvironment.executable()
        child.arguments = ["app-server", "--listen", "stdio://"] + arguments
        child.environment = CodexEnvironment.childEnvironment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        sessionID = currentSession
        let output = stdout.fileHandleForReading
        // 每个数据块处理完成后才读取下一个，保持 stdio 字节顺序。
        readTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let data = output.availableData
                if data.isEmpty {
                    break
                }
                await self?.receive(data, session: currentSession)
            }
            try? output.close()
            await self?.closed(session: currentSession)
        }
    }

    func request(_ method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        // 历史连接始终只读；生成连接只允许创建临时会话、派生分支和发起生成。
        let allowed = purpose == .history ? ["initialize", "thread/list", "thread/read", "thread/turns/list", "model/list", "config/read"] : ["initialize", "thread/start", "thread/fork", "turn/start", "turn/interrupt"]
        guard allowed.contains(method), input != nil else {
            throw AssistantError.notConnected
        }
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(.object(["id": .number(Double(id)), "method": .string(method), "params": .object(params)]))
                timeouts[id] = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(20))
                    } catch {
                        return
                    }
                    await self?.fail(id, error: AssistantError.timeout(method))
                }
            } catch {
                fail(id, error: error)
            }
        }
    }

    func initialized() throws {
        try send(.object(["method": .string("initialized")]))
    }

    func notificationStream() -> AsyncStream<JSONValue> {
        notifications?.finish()
        return AsyncStream { continuation in
            notifications = continuation
        }
    }

    func stop() {
        sessionID = UUID()
        readTask?.cancel()
        readTask = nil
        try? input?.close()
        input = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        buffer.removeAll()
        scannedByteCount = 0
        notifications?.finish()
        notifications = nil
        failAll(error: AssistantError.transportClosed)
    }

    func shutdown() async {
        let child = process
        stop()
        if let child, child.isRunning {
            try? await Task.sleep(for: .milliseconds(350))
            if child.isRunning {
                _ = kill(child.processIdentifier, SIGKILL)
            }
        }
    }

    private func send(_ message: JSONValue) throws {
        guard let input else {
            throw AssistantError.notConnected
        }
        var data = try JSONEncoder().encode(message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data, session: UUID) {
        guard session == sessionID else {
            return
        }
        buffer.append(data)
        // 只扫描新增字节；收到完整换行帧后才解码 UTF-8，跨块字符与未完成帧保持原始字节。
        while scannedByteCount < buffer.count {
            let newlineOffset: Int? = buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
                guard let start = bytes.baseAddress, let newline = memchr(start.advanced(by: scannedByteCount), 10, bytes.count - scannedByteCount) else {
                    return nil
                }
                return start.distance(to: UnsafeRawPointer(newline))
            }
            guard let newlineOffset else {
                scannedByteCount = buffer.count
                return
            }
            let newline = buffer.index(buffer.startIndex, offsetBy: newlineOffset)
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            scannedByteCount = 0
            guard let response = try? JSONDecoder().decode(JSONValue.self, from: line) else {
                continue
            }
            // 通知按接收顺序交给生成器；不接受服务端发起的工具或授权请求。
            if response["method"]?.stringValue != nil {
                if let id = response["id"] {
                    try? send(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("This client does not execute server requests.")])]))
                } else {
                    notifications?.yield(response)
                }
                continue
            }
            guard let number = response["id"]?.numberValue else {
                continue
            }
            let id = Int(number)
            if let error = response["error"] {
                let code = Int(error["code"]?.numberValue ?? -1)
                let message = error["message"]?.stringValue ?? "未知错误"
                fail(id, error: AssistantError.rpc("读取", code, message))
            } else if let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                continuation.resume(returning: response["result"] ?? .null)
            }
        }
    }

    private func closed(session: UUID) {
        guard session == sessionID else {
            return
        }
        input = nil
        process = nil
        notifications?.finish()
        notifications = nil
        failAll(error: AssistantError.transportClosed)
    }

    private func fail(_ id: Int, error: Error) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(error: Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
