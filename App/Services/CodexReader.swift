import Foundation

// MARK: - 来源聊天和配置读取

actor CodexReader {
    private let transport = AppServerTransport()
    private var connection: Task<Void, Error>?

    private func connect() async throws {
        if let connection {
            try await connection.value
            return
        }
        let transport = self.transport
        let task = Task {
            try await transport.start()
            _ = try await transport.request("initialize", params: ["clientInfo": .object(["name": .string("codex_prompt_assistant"), "title": .string("提示词助手"), "version": .string("0.1.1")]), "capabilities": .object([:])])
            try await transport.initialized()
        }
        connection = task
        do {
            try await task.value
        } catch {
            connection = nil
            await transport.stop()
            throw error
        }
    }

    func reconnect() async throws {
        connection?.cancel()
        connection = nil
        await transport.stop()
        try await connect()
    }

    func shutdown() async {
        connection?.cancel()
        connection = nil
        await transport.shutdown()
    }

    func listChats(cursor: String? = nil, search: String = "") async throws -> ChatPage {
        try await connect()
        var params: [String: JSONValue] = ["limit": .number(50), "sortKey": .string("updated_at"), "sourceKinds": .array([.string("appServer"), .string("cli"), .string("vscode")]), "modelProviders": .array([]), "useStateDbOnly": .bool(true)]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        if !search.isEmpty {
            params["searchTerm"] = .string(search)
        }
        let result = try await transport.request("thread/list", params: params)
        return ChatPage(chats: (result["data"]?.arrayValue ?? []).compactMap(SourceChat.init), nextCursor: result["nextCursor"]?.stringValue)
    }

    func configuration(cwd: String? = nil) async throws -> EffectiveConfiguration {
        try await connect()
        var params: [String: JSONValue] = ["includeLayers": .bool(false)]
        if let cwd, !cwd.isEmpty {
            params["cwd"] = .string(cwd)
        }
        let result = try await transport.request("config/read", params: params)
        return EffectiveConfiguration(raw: result["config"] ?? .object([:]))
    }

    func models() async throws -> [ModelOption] {
        try await connect()
        var models: [ModelOption] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var params: [String: JSONValue] = ["limit": .number(100), "includeHidden": .bool(false)]
            if let cursor {
                params["cursor"] = .string(cursor)
            }
            let result = try await transport.request("model/list", params: params)
            models.append(contentsOf: (result["data"]?.arrayValue ?? []).compactMap(ModelOption.init))
            cursor = result["nextCursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted {
                throw AssistantError.invalidResponse
            }
        } while cursor != nil
        return models
    }

    func chat(id: String) async throws -> SourceChat? {
        try await connect()
        let result = try await transport.request("thread/read", params: ["threadId": .string(id), "includeTurns": .bool(false)])
        return result["thread"].flatMap(SourceChat.init)
    }

    // 发送回执先只查最新轮次 ID，出现新轮次后才读取该轮正文。
    func latestDeliveryTurn(threadID: String, full: Bool = false) async throws -> JSONValue? {
        try await connect()
        let result = try await transport.request("thread/turns/list", params: ["threadId": .string(threadID), "sortDirection": .string("desc"), "limit": .number(1), "itemsView": .string(full ? "full" : "notLoaded")])
        guard let turns = result["data"]?.arrayValue else {
            throw AssistantError.invalidResponse
        }
        if let latest = turns.first, latest["id"]?.stringValue == nil {
            throw AssistantError.invalidResponse
        }
        return turns.first
    }

    // 只取轮次元数据；固定分叉点，取消或断线后重试也不会吸收后来的主聊天内容。
    func forkBoundary(for chat: SourceChat) async throws -> String {
        try await connect()
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var params: [String: JSONValue] = ["threadId": .string(chat.id), "sortDirection": .string("desc"), "limit": .number(20), "itemsView": .string("notLoaded")]
            if let cursor {
                params["cursor"] = .string(cursor)
            }
            let result = try await transport.request("thread/turns/list", params: params)
            guard let turns = result["data"]?.arrayValue else {
                throw AssistantError.invalidResponse
            }
            if let turnID = turns.first(where: { ["completed", "failed", "interrupted"].contains($0["status"]?.stringValue ?? "") })?["id"]?.stringValue {
                return turnID
            }
            cursor = result["nextCursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted {
                throw AssistantError.invalidResponse
            }
        } while cursor != nil
        throw AssistantError.generationFailed("所选聊天还没有已结束的轮次。")
    }

    func snapshot(for chat: SourceChat) async throws -> ContextSnapshot {
        try await connect()
        let common: [String: JSONValue] = ["threadId": .string(chat.id), "itemsView": .string("full")]
        var latestParams = common
        latestParams["limit"] = .number(24)
        latestParams["sortDirection"] = .string("desc")
        var firstParams = common
        firstParams["limit"] = .number(1)
        firstParams["sortDirection"] = .string("asc")
        let latest = try await transport.request("thread/turns/list", params: latestParams)
        let first = try await transport.request("thread/turns/list", params: firstParams)
        let completed = (latest["data"]?.arrayValue ?? []).filter { turn in
            let status = turn["status"]?.stringValue
            return status == nil || status == "completed"
        }
        let recent = Array(completed.prefix(20).reversed())
        let firstTurn = first["data"]?.arrayValue?.first
        let firstID = firstTurn?["id"]?.stringValue
        let recentContainsFirst = recent.contains { $0["id"]?.stringValue == firstID }
        let initial = try firstTurn.map { try Self.text(from: $0, userOnly: true) } ?? ""
        let recentText = try recent.map { try Self.text(from: $0) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        // 轮次范围控制历史规模，范围内正文不再按字符裁剪，避免截断用户补充和最终答复。
        let initialBlock = recentContainsFirst || initial.isEmpty ? "" : "最初的用户请求：\n" + initial + "\n\n最近的对话：\n"
        let text = initialBlock + recentText
        let trimmed = latest["nextCursor"]?.stringValue != nil && !recentContainsFirst
        return ContextSnapshot(chat: chat, text: text, isTrimmed: trimmed, capturedAt: Date())
    }

    // 依据协议类型筛选；partial_answer、缺失或未知 phase 的助手正文均保留，只有 commentary 被明确排除。
    private static func text(from turn: JSONValue, userOnly: Bool = false) throws -> String {
        let items = turn["items"]?.arrayValue ?? []
        return try items.compactMap { item -> String? in
            let type = item["type"]?.stringValue
            if userOnly, type != "userMessage" {
                return nil
            }
            switch type {
            case "userMessage":
                let text = (item["content"]?.arrayValue ?? []).compactMap { content in
                    content["text"]?.stringValue
                }.joined(separator: "\n")
                return text.isEmpty ? nil : "用户：\n" + text
            case "agentMessage":
                guard item["phase"]?.stringValue != "commentary" else {
                    return nil
                }
                guard let text = item["text"]?.stringValue else {
                    throw AssistantError.invalidResponse
                }
                return text.isEmpty ? nil : "助手：\n" + text
            case "hookPrompt", "functionCallOutput", "plan", "reasoning", "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "subAgentActivity", "webSearch", "imageView", "sleep", "imageGeneration", "enteredReviewMode", "exitedReviewMode", "contextCompaction":
                return nil
            default:
                // 不展开未知条目的原始数据，也不静默忽略可能包含正文的新类型。
                throw AssistantError.generationFailed("聊天包含无法识别的消息类型（\(type ?? "缺失")），已停止生成以避免遗漏正文。请核对 Codex 版本后重试。")
            }
        }.joined(separator: "\n\n")
    }
}
