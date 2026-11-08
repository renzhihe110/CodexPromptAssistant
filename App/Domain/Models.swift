import Foundation

// MARK: - 来源会话与模型目录

struct SourceChat: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let preview: String
    let cwd: String
    let updatedAt: Date

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else {
            return nil
        }
        self.id = id
        self.preview = json["preview"]?.stringValue ?? ""
        self.cwd = json["cwd"]?.stringValue ?? ""
        let name = json["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = name.isEmpty ? String(preview.prefix(70)).nonEmpty(or: "未命名聊天") : name
        self.updatedAt = Date(timeIntervalSince1970: json["updatedAt"]?.numberValue ?? 0)
    }
}

struct ChatPage: Sendable {
    let chats: [SourceChat]
    let nextCursor: String?
}

struct ReasoningOption: Identifiable, Hashable, Sendable {
    let id: String
    let detail: String

    var title: String {
        switch id {
        case "none":
            return "无"
        case "minimal":
            return "最低"
        case "low":
            return "低"
        case "medium":
            return "中"
        case "high":
            return "高"
        case "xhigh":
            return "极高"
        case "max":
            return "最高"
        case "ultra":
            return "极致"
        default:
            return id
        }
    }
}

struct ModelOption: Identifiable, Sendable {
    let id: String
    let name: String
    let defaultEffort: String?
    let efforts: [ReasoningOption]
    let supportsImages: Bool
    let isDefault: Bool

    init?(json: JSONValue) {
        guard let id = json["model"]?.stringValue ?? json["id"]?.stringValue else {
            return nil
        }
        self.id = id
        self.name = json["displayName"]?.stringValue ?? id
        self.defaultEffort = json["defaultReasoningEffort"]?.stringValue
        self.isDefault = json["isDefault"]?.boolValue ?? false
        self.supportsImages = json["inputModalities"]?.arrayValue?.contains { $0.stringValue == "image" } ?? true
        self.efforts = (json["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { row in
            guard let id = row["reasoningEffort"]?.stringValue else {
                return nil
            }
            return ReasoningOption(id: id, detail: row["description"]?.stringValue ?? "")
        }
    }
}

struct EffectiveConfiguration: Sendable {
    let raw: JSONValue

    var model: String? {
        raw["model"]?.stringValue
    }

    var effort: String? {
        raw["model_reasoning_effort"]?.stringValue
    }

    static let empty = EffectiveConfiguration(raw: .object([:]))
}

struct ContextSnapshot: Sendable {
    let chat: SourceChat
    let text: String
    let isTrimmed: Bool
    let capturedAt: Date
}

// MARK: - 本轮问答及候选内容

// 与完善/推荐独立：两个入口共用同一上下文偏好，每轮开始时固定。
enum ContextMode: String, CaseIterable {
    case snapshot = "筛选快照"
    case sideChat = "侧边聊天"
}

enum AssistantMode: String, CaseIterable, Identifiable, Sendable {
    case refine
    case nextStep

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .refine:
            return "完善文本"
        case .nextStep:
            return "推荐下一步"
        }
    }

    var symbol: String {
        switch self {
        case .refine:
            return "text.bubble"
        case .nextStep:
            return "arrow.turn.down.right"
        }
    }
}

struct ImageAttachment: Identifiable, Sendable {
    let id: UUID
    let name: String
    let fileURL: URL
}

struct QuestionOption: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
}

struct ClarifyingQuestion: Codable, Identifiable, Sendable {
    let id: String
    let text: String
    let options: [QuestionOption]
    let recommendedID: String
}

struct PromptCandidate: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    var prompt: String
}

struct AnswerRecord: Codable, Sendable {
    let question: String
    let answer: String
}

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    var attachments: [ImageAttachment] = []
    var question: ClarifyingQuestion?
    var questionNumber: Int?
    var candidates: [PromptCandidate] = []
}

struct EngineResponse: Decodable, Sendable {
    let kind: String
    let question: ClarifyingQuestion?
    let candidates: [PromptCandidate]

    // Schema 之外再约束分支关系，避免将损坏结果写入问答状态。
    func validated(candidatesOnly: Bool) throws -> EngineResponse {
        if kind == "question" {
            guard !candidatesOnly, let question, !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...3).contains(question.options.count), candidates.isEmpty else {
                throw AssistantError.invalidResponse
            }
            let ids = question.options.map(\.id)
            guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }), ids.contains(question.recommendedID), question.options.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AssistantError.invalidResponse
            }
        } else if kind == "candidates" {
            guard question == nil, (2...3).contains(candidates.count), Set(candidates.map(\.id)).count == candidates.count, candidates.allSatisfy({ !$0.title.isEmpty && !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AssistantError.invalidResponse
            }
        } else {
            throw AssistantError.invalidResponse
        }
        return self
    }
}

enum AssistantError: LocalizedError {
    case codexNotFound
    case notConnected
    case transportClosed
    case timeout(String)
    case rpc(String, Int, String)
    case invalidResponse
    case missingSchema
    case imageUnsupported
    case imageUnreadable
    case imageTooLarge
    case sideChatFailed(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "没有找到 Codex CLI。请先安装 Codex，并在终端完成登录。"
        case .notConnected:
            return "Codex 连接尚未建立，请重新连接。"
        case .transportClosed:
            return "Codex 连接已结束，请重试连接。"
        case .timeout(let operation):
            return "\(operation)超时，已保留当前内容，可以重试。"
        case .rpc(let method, let code, let message):
            return "Codex 接口 \(method) 返回错误 \(code)：\(message)"
        case .invalidResponse:
            return "未能整理出有效的问题或候选，当前回答已保留，请重试。"
        case .missingSchema:
            return "应用缺少生成协议资源，请检查工程中的 Resources 目录。"
        case .imageUnsupported:
            return "当前模型不支持图片，请选择支持图片的模型后重试。"
        case .imageUnreadable:
            return "无法读取这张图片，请使用有效的 PNG、JPEG 或其他系统支持的图片。"
        case .imageTooLarge:
            return "图片文件超过 30 MB，请先缩小图片后重新添加。"
        case .sideChatFailed(let reason):
            return "侧边聊天未能建立：" + reason
        case .generationFailed(let message):
            return message
        }
    }
}

extension String {
    // 界面上的缺省标题在数据解析时统一处理。
    func nonEmpty(or fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
