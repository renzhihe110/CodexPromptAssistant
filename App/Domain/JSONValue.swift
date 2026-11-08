import Foundation

// MARK: - 无类型协议字段的安全承载

enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue? {
        objectValue?[key]
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    // 参数通过 Process.arguments 传递，TOML 字面量不经过 shell 展开。
    var tomlLiteral: String? {
        switch self {
        case .string(let value):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        case .number(let value):
            if value.isFinite, value.rounded(.towardZero) == value, abs(value) < 9_007_199_254_740_992 {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            let literals = values.compactMap(\.tomlLiteral)
            guard literals.count == values.count else {
                return nil
            }
            return "[" + literals.joined(separator: ", ") + "]"
        case .object(let values):
            let fields = values.keys.sorted().compactMap { key -> String? in
                guard let name = JSONValue.string(key).tomlLiteral, let literal = values[key]?.tomlLiteral else {
                    return nil
                }
                return name + " = " + literal
            }
            return "{ " + fields.joined(separator: ", ") + " }"
        case .null:
            return nil
        }
    }
}
