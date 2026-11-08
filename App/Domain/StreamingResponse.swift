import Foundation

// MARK: - 未校验的正文预览，没有选项、复制或编辑能力

struct GenerationPreview: Equatable, Sendable {
    struct Candidate: Equatable, Identifiable, Sendable {
        let id: Int
        var title = ""
        var prompt = ""
    }

    var question = ""
    var candidates: [Candidate] = []

    var isEmpty: Bool {
        question.isEmpty && candidates.allSatisfy { $0.prompt.isEmpty }
    }
}

// 只识别密集的短句复读；单纯篇幅较长、相似开头或重复术语都不足以触发。
enum RefinementRepetition {
    static let sentenceEnds: Set<Character> = ["。", "！", "？", ".", "!", "?"]

    static func detected(in text: Substring) -> Bool {
        var recent: [String] = []
        var counts: [String: Int] = [:]
        var start = text.startIndex
        for index in text.indices where sentenceEnds.contains(text[index]) {
            let fragment = text[start..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            start = text.index(after: index)
            if fragment.isEmpty { continue }
            guard (2...48).contains(fragment.count), !fragment.contains("\n") else {
                recent.removeAll(keepingCapacity: true)
                counts.removeAll(keepingCapacity: true)
                continue
            }
            let sentence = fragment.lowercased()
            recent.append(sentence)
            counts[sentence, default: 0] += 1
            if recent.count > 48 {
                let oldest = recent.removeFirst()
                counts[oldest, default: 1] -= 1
                if counts[oldest] == 0 { counts[oldest] = nil }
            }
            // 连续五次原句，或一段内多种短句交替复现，才中止这一轮。
            if recent.count >= 5, recent.suffix(5).allSatisfy({ $0 == sentence }) { return true }
            if recent.count == 48, recent.count - counts.count >= 9,
               counts.values.contains(where: { $0 >= 3 }), counts.values.filter({ $0 >= 2 }).count >= 3 { return true }
        }
        return false
    }
}

// 仅记录界面生命周期时序，不保存正文；首次预览和最终结果出现与模型首 token 分开计量。
struct GenerationTiming {
    let id: UUID
    let startedAt: Date
    var firstPreviewAt: Date?
    var validatedAt: Date?
    var resultVisibleAt: Date?
    var outcome = "running"
}

// 只从已确认的 JSON 路径提取字符串。词法状态跨 delta 保留，不用正则猜测或显示原始 JSON。
struct StreamingResponseParser {
    private enum Part: Equatable {
        case key(String)
        case index(Int)
    }

    private enum State: Equatable {
        case key
        case colon
        case value
        case separator
    }

    private struct Container {
        let object: Bool
        let path: [Part]
        var state: State
        var key = ""
        var index = 0
    }

    private var stack: [Container] = []
    private var started = false
    private var failed = false
    private var stringBytes: [UInt8]?
    private var stringIsKey = false
    private var stringPath: [Part] = []
    private var escaped = false
    private var primitive: [UInt8]?
    private(set) var preview = GenerationPreview()

    mutating func append(_ delta: String) {
        guard !failed else {
            return
        }
        for byte in delta.utf8 {
            consume(byte)
            if failed {
                preview = GenerationPreview()
                return
            }
        }
        // 不完整的转义或 UTF-16 代理项无法解码时，保留上一次安全前缀，等待真实后续分片。
        if let bytes = stringBytes, !stringIsKey, !escaped, let text = decode(bytes + [34]) {
            update(text, at: stringPath)
        }
    }

    private mutating func consume(_ byte: UInt8) {
        if stringBytes != nil {
            stringBytes?.append(byte)
            if escaped {
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                guard let bytes = stringBytes, let text = decode(bytes) else {
                    failed = true
                    return
                }
                stringBytes = nil
                if stringIsKey {
                    stack[stack.count - 1].key = text
                    stack[stack.count - 1].state = .colon
                } else {
                    update(text, at: stringPath)
                }
            }
            return
        }
        if let bytes = primitive {
            if byte == 44 || byte == 93 || byte == 125 || Self.whitespace(byte) {
                guard (try? JSONDecoder().decode(JSONValue.self, from: Data(bytes))) != nil else {
                    failed = true
                    return
                }
                primitive = nil
            } else {
                primitive?.append(byte)
                return
            }
        }
        if Self.whitespace(byte) {
            return
        }
        if byte == 34 {
            stringIsKey = stack.last?.object == true && stack.last?.state == .key
            if !stringIsKey {
                guard let path = takeValue() else {
                    failed = true
                    return
                }
                stringPath = path
            }
            stringBytes = [34]
            escaped = false
        } else if byte == 123 || byte == 91 {
            guard let path = takeValue() else {
                failed = true
                return
            }
            stack.append(Container(object: byte == 123, path: path, state: byte == 123 ? .key : .value))
        } else if byte == 125 || byte == 93 {
            guard let last = stack.last, last.object == (byte == 125), last.state == .separator || (last.object && last.state == .key) || (!last.object && last.state == .value) else {
                failed = true
                return
            }
            stack.removeLast()
        } else if byte == 58, stack.last?.state == .colon {
            stack[stack.count - 1].state = .value
        } else if byte == 44, stack.last?.state == .separator {
            stack[stack.count - 1].state = stack[stack.count - 1].object ? .key : .value
        } else if byte == 110 || byte == 116 || byte == 102 || byte == 45 || (48...57).contains(byte) {
            guard takeValue() != nil else {
                failed = true
                return
            }
            primitive = [byte]
        } else {
            failed = true
        }
    }

    private mutating func takeValue() -> [Part]? {
        guard !stack.isEmpty else {
            guard !started else {
                return nil
            }
            started = true
            return []
        }
        let index = stack.count - 1
        guard stack[index].state == .value else {
            return nil
        }
        let path = stack[index].path + [stack[index].object ? .key(stack[index].key) : .index(stack[index].index)]
        stack[index].state = .separator
        stack[index].index += 1
        return path
    }

    private func decode(_ bytes: [UInt8]) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(bytes))
    }

    private static func whitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private mutating func update(_ text: String, at path: [Part]) {
        if path == [.key("question"), .key("text")] {
            preview.question = text
        } else if path.count == 3, path[0] == .key("candidates"), case .index(let index) = path[1], (0..<3).contains(index), path[2] == .key("title") || path[2] == .key("prompt") {
            while preview.candidates.count <= index {
                preview.candidates.append(.init(id: preview.candidates.count))
            }
            if path[2] == .key("title") {
                preview.candidates[index].title = text
            } else {
                preview.candidates[index].prompt = text
            }
        }
    }
}

// 最终本地校验覆盖随应用提供的三份 Schema 使用的关键字；预览永不参与最终结果解码。
enum ResponseSchema {
    static func matches(_ value: JSONValue, schema: JSONValue) -> Bool {
        if let choices = schema["anyOf"]?.arrayValue {
            return choices.contains { matches(value, schema: $0) }
        }
        if let choices = schema["enum"]?.arrayValue {
            guard let text = value.stringValue, choices.contains(where: { $0.stringValue == text }) else {
                return false
            }
        }
        switch schema["type"]?.stringValue {
        case "object":
            guard let object = value.objectValue, let properties = schema["properties"]?.objectValue else {
                return false
            }
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard required.allSatisfy({ object[$0] != nil }), schema["additionalProperties"]?.boolValue != false || object.keys.allSatisfy({ properties[$0] != nil }) else {
                return false
            }
            return object.allSatisfy { key, child in
                properties[key].map { matches(child, schema: $0) } ?? true
            }
        case "array":
            guard let items = value.arrayValue, let itemSchema = schema["items"], Double(items.count) >= (schema["minItems"]?.numberValue ?? 0), Double(items.count) <= (schema["maxItems"]?.numberValue ?? .infinity) else {
                return false
            }
            return items.allSatisfy { matches($0, schema: itemSchema) }
        case "string":
            return value.stringValue != nil
        case "null":
            if case .null = value {
                return true
            }
            return false
        default:
            return false
        }
    }
}
