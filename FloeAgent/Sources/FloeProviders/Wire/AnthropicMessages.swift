// FloeProviders — Anthropic Messages API wire DTOs.
// `AnthropicStreamEvent` is a tagged union over the stream event `type`
// field; unknown types decode as `.unknown(name)` for forward compatibility.

import Foundation

// MARK: - Request

/// Request body for `POST {baseURL}/v1/messages` with `stream: true`.
public struct AnthropicRequest: Sendable, Codable, Hashable {
    public var model: String
    public var maxTokens: Int
    public var messages: [Message]
    public var system: String?
    public var tools: [ToolDefinition]
    public var stream: Bool

    public init(
        model: String,
        maxTokens: Int,
        messages: [Message],
        system: String? = nil,
        tools: [ToolDefinition] = [],
        stream: Bool = true
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.messages = messages
        self.system = system
        self.tools = tools
        self.stream = stream
    }

    public struct Message: Sendable, Codable, Hashable {
        public var role: String
        public var content: [AnthropicContent]

        public init(role: String, content: [AnthropicContent]) {
            self.role = role
            self.content = content
        }
    }

    public struct ToolDefinition: Sendable, Codable, Hashable {
        public var name: String
        public var description: String
        /// JSON Schema object as raw JSON string.
        public var inputSchema: String

        public init(name: String, description: String, inputSchema: String) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decode(String.self, forKey: .description)
            inputSchema = try container.decode(RawJSONValue.self, forKey: .inputSchema).rawJSON
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encode(RawJSONValue(rawJSON: inputSchema), forKey: .inputSchema)
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, system, tools, stream
        case maxTokens = "max_tokens"
    }
}

// MARK: - Content blocks

/// Content block in an Anthropic message (request or response).
public enum AnthropicContent: Sendable, Codable, Hashable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input
        case toolUseID = "tool_use_id"
        case content, isError = "is_error"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(try container.decode(String.self, forKey: .thinking))
        case "tool_use":
            // `input` is an arbitrary JSON object; re-encode to a string so
            // downstream size validation works on bytes.
            let inputData = try container.decode(RawJSONValue.self, forKey: .input)
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                inputJSON: inputData.rawJSON
            )
        case "tool_result":
            self = .toolResult(
                toolUseID: try container.decode(String.self, forKey: .toolUseID),
                content: try container.decodeIfPresent(String.self, forKey: .content) ?? "",
                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        default:
            self = .text("")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let thinking):
            try container.encode("thinking", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
        case .toolUse(let id, let name, let inputJSON):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(RawJSONValue(rawJSON: inputJSON), forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        }
    }
}

/// Lossless JSON passthrough used where the wire carries arbitrary objects
/// (tool inputs). Stores the minified serialization.
struct RawJSONValue: Codable, Hashable, @unchecked Sendable {
    var rawJSON: String

    init(rawJSON: String) {
        self.rawJSON = rawJSON
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Decode to a JSONSerialization-compatible tree, then re-serialize
        // deterministically.
        let value = try container.decode(JSONTree.self)
        let data = try JSONSerialization.data(withJSONObject: value.foundationObject, options: [.sortedKeys])
        self.rawJSON = String(decoding: data, as: UTF8.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let object = try JSONSerialization.jsonObject(with: Data(rawJSON.utf8))
        try container.encode(JSONTree(foundationObject: object))
    }
}

/// Recursive JSON tree bridging `Codable` and `JSONSerialization`.
enum JSONTree: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONTree])
    case object([String: JSONTree])

    init(foundationObject: Any) {
        switch foundationObject {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(JSONTree.init(foundationObject:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONTree.init(foundationObject:)))
        default:
            self = .null
        }
    }

    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let values): return values.mapValues(\.foundationObject)
        }
    }

    init(from decoder: any Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [JSONTree] = []
            while !unkeyed.isAtEnd {
                items.append(try unkeyed.decode(JSONTree.self))
            }
            self = .array(items)
            return
        }
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var pairs: [String: JSONTree] = [:]
            for key in keyed.allKeys {
                pairs[key.stringValue] = try keyed.decode(JSONTree.self, forKey: key)
            }
            self = .object(pairs)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try single.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .array(let items):
            var container = encoder.unkeyedContainer()
            for item in items { try container.encode(item) }
        case .object(let pairs):
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in pairs {
                try container.encode(value, forKey: DynamicKey(stringValue: key))
            }
        default:
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            default: break
            }
        }
    }

    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

// MARK: - Stream events

/// Tagged union over Anthropic Messages stream event `type` values.
public enum AnthropicStreamEvent: Sendable, Hashable {
    case messageStart(model: String?)
    case contentBlockStart(index: Int, blockType: String, toolID: String?, toolName: String?)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, thinking: String)
    case inputJSONDelta(index: Int, partialJSON: String)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?, usage: Usage?)
    case messageStop
    case ping
    case error(type: String?, message: String)
    case unknown(type: String)

    public struct Usage: Sendable, Codable, Hashable {
        public var inputTokens: Int
        public var outputTokens: Int

        public init(inputTokens: Int, outputTokens: Int) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

extension AnthropicStreamEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, index, delta, message, error
        case contentBlock = "content_block"
    }

    private enum DeltaKeys: String, CodingKey {
        case type, text, thinking
        case partialJSON = "partial_json"
        case stopReason = "stop_reason"
        case usage
    }

    private enum MessageKeys: String, CodingKey {
        case model
    }

    private enum BlockKeys: String, CodingKey {
        case type, id, name
    }

    private enum ErrorKeys: String, CodingKey {
        case type, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "message_start":
            let message = try container.decodeIfPresent(MessagePayload.self, forKey: .message)
            self = .messageStart(model: message?.model)
        case "content_block_start":
            let index = try container.decode(Int.self, forKey: .index)
            let block = try container.decode(BlockPayload.self, forKey: .contentBlock)
            self = .contentBlockStart(index: index, blockType: block.type, toolID: block.id, toolName: block.name)
        case "content_block_delta":
            let index = try container.decode(Int.self, forKey: .index)
            let delta = try container.decode(DeltaPayload.self, forKey: .delta)
            switch delta.type {
            case "text_delta":
                self = .textDelta(index: index, text: delta.text ?? "")
            case "thinking_delta":
                self = .thinkingDelta(index: index, thinking: delta.thinking ?? "")
            case "input_json_delta":
                self = .inputJSONDelta(index: index, partialJSON: delta.partialJSON ?? "")
            default:
                self = .unknown(type: "content_block_delta.\(delta.type)")
            }
        case "content_block_stop":
            self = .contentBlockStop(index: try container.decode(Int.self, forKey: .index))
        case "message_delta":
            let delta = try container.decodeIfPresent(DeltaPayload.self, forKey: .delta)
            self = .messageDelta(stopReason: delta?.stopReason, usage: delta?.usage)
        case "message_stop":
            self = .messageStop
        case "ping":
            self = .ping
        case "error":
            let payload = try container.decode(ErrorPayload.self, forKey: .error)
            self = .error(type: payload.type, message: payload.message)
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .messageStart(let model):
            try container.encode("message_start", forKey: .type)
            try container.encode(MessagePayload(model: model), forKey: .message)
        case .contentBlockStart(let index, let blockType, let toolID, let toolName):
            try container.encode("content_block_start", forKey: .type)
            try container.encode(index, forKey: .index)
            try container.encode(BlockPayload(type: blockType, id: toolID, name: toolName), forKey: .contentBlock)
        case .textDelta(let index, let text):
            try container.encode("content_block_delta", forKey: .type)
            try container.encode(index, forKey: .index)
            try container.encode(DeltaPayload(type: "text_delta", text: text, thinking: nil, partialJSON: nil, stopReason: nil, usage: nil), forKey: .delta)
        case .thinkingDelta(let index, let thinking):
            try container.encode("content_block_delta", forKey: .type)
            try container.encode(index, forKey: .index)
            try container.encode(DeltaPayload(type: "thinking_delta", text: nil, thinking: thinking, partialJSON: nil, stopReason: nil, usage: nil), forKey: .delta)
        case .inputJSONDelta(let index, let partialJSON):
            try container.encode("content_block_delta", forKey: .type)
            try container.encode(index, forKey: .index)
            try container.encode(DeltaPayload(type: "input_json_delta", text: nil, thinking: nil, partialJSON: partialJSON, stopReason: nil, usage: nil), forKey: .delta)
        case .contentBlockStop(let index):
            try container.encode("content_block_stop", forKey: .type)
            try container.encode(index, forKey: .index)
        case .messageDelta(let stopReason, let usage):
            try container.encode("message_delta", forKey: .type)
            try container.encode(DeltaPayload(type: "", text: nil, thinking: nil, partialJSON: nil, stopReason: stopReason, usage: usage), forKey: .delta)
        case .messageStop:
            try container.encode("message_stop", forKey: .type)
        case .ping:
            try container.encode("ping", forKey: .type)
        case .error(let type, let message):
            try container.encode("error", forKey: .type)
            try container.encode(ErrorPayload(type: type, message: message), forKey: .error)
        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }

    private struct MessagePayload: Codable {
        var model: String?
    }

    private struct BlockPayload: Codable {
        var type: String
        var id: String?
        var name: String?
    }

    private struct DeltaPayload: Codable {
        var type: String
        var text: String?
        var thinking: String?
        var partialJSON: String?
        var stopReason: String?
        var usage: Usage?

        enum CodingKeys: String, CodingKey {
            case type, text, thinking, usage
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    private struct ErrorPayload: Codable {
        var type: String?
        var message: String
    }
}
