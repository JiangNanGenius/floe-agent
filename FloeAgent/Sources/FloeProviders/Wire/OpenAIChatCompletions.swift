// FloeProviders — OpenAI Chat Completions wire DTOs.
// Streaming chunks carry incremental `tool_calls` deltas keyed by `index`;
// `ToolCallAggregator` concatenates argument fragments per index.

import Foundation

// MARK: - Request

/// Request body for `POST {baseURL}/chat/completions` with `stream: true`.
public struct ChatRequest: Sendable, Codable, Hashable {
    public var model: String
    public var messages: [Message]
    /// Omitted entirely when the selected model has tool calling disabled.
    public var tools: [ToolDefinition]?
    /// Explicitly advertises native tool selection to OpenAI-compatible
    /// providers. Omitted together with `tools` for text-only models.
    public var toolChoice: String?
    public var maxTokens: Int?
    public var thinking: Thinking?
    public var reasoningEffort: String?
    public var enableThinking: Bool?
    public var stream: Bool
    /// OpenAI-compatible providers only include usage in streamed responses
    /// when explicitly requested.
    public var streamOptions: StreamOptions?

    public init(
        model: String,
        messages: [Message],
        tools: [ToolDefinition]? = nil,
        toolChoice: String? = nil,
        maxTokens: Int? = nil,
        thinking: Thinking? = nil,
        reasoningEffort: String? = nil,
        enableThinking: Bool? = nil,
        stream: Bool = true,
        streamOptions: StreamOptions? = StreamOptions(includeUsage: true)
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
        self.enableThinking = enableThinking
        self.stream = stream
        self.streamOptions = streamOptions
    }

    public struct StreamOptions: Sendable, Codable, Hashable {
        public var includeUsage: Bool
        public init(includeUsage: Bool) { self.includeUsage = includeUsage }
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    public struct Thinking: Sendable, Codable, Hashable {
        public var type: String
        public init(type: String) { self.type = type }
    }

    public struct Message: Sendable, Codable, Hashable {
        public var role: String
        public var content: Content?
        /// Present on assistant messages that requested tools.
        public var toolCalls: [ToolCall]?
        /// DeepSeek thinking-mode continuity for assistant tool-call turns.
        public var reasoningContent: String?
        /// Present on tool-result messages.
        public var toolCallID: String?

        public init(
            role: String,
            content: String? = nil,
            toolCalls: [ToolCall]? = nil,
            reasoningContent: String? = nil,
            toolCallID: String? = nil
        ) {
            self.role = role
            self.content = content.map(Content.text)
            self.toolCalls = toolCalls
            self.reasoningContent = reasoningContent
            self.toolCallID = toolCallID
        }

        public init(
            role: String,
            contentParts: [ContentPart],
            toolCalls: [ToolCall]? = nil,
            reasoningContent: String? = nil,
            toolCallID: String? = nil
        ) {
            self.role = role
            self.content = .parts(contentParts)
            self.toolCalls = toolCalls
            self.reasoningContent = reasoningContent
            self.toolCallID = toolCallID
        }

        public enum Content: Sendable, Codable, Hashable {
            case text(String)
            case parts([ContentPart])

            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) { self = .text(text) }
                else { self = .parts(try container.decode([ContentPart].self)) }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let text): try container.encode(text)
                case .parts(let parts): try container.encode(parts)
                }
            }
        }

        public enum ContentPart: Sendable, Codable, Hashable {
            case text(String)
            case imageURL(String)

            private enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }
            private enum ImageKeys: String, CodingKey { case url }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if try container.decode(String.self, forKey: .type) == "image_url" {
                    let image = try container.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
                    self = .imageURL(try image.decode(String.self, forKey: .url))
                } else {
                    self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let text):
                    try container.encode("text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case .imageURL(let url):
                    try container.encode("image_url", forKey: .type)
                    var image = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
                    try image.encode(url, forKey: .url)
                }
            }
        }

        public struct ToolCall: Sendable, Codable, Hashable {
            public var id: String
            public var type: String = "function"
            public var function: Function

            public init(id: String, function: Function) {
                self.id = id
                self.function = function
            }

            public struct Function: Sendable, Codable, Hashable {
                public var name: String
                public var arguments: String

                public init(name: String, arguments: String) {
                    self.name = name
                    self.arguments = arguments
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case reasoningContent = "reasoning_content"
            case toolCallID = "tool_call_id"
        }
    }

    public struct ToolDefinition: Sendable, Codable, Hashable {
        public var type: String = "function"
        public var function: Function

        public init(name: String, description: String, parameters: String) {
            self.function = Function(name: name, description: description, parameters: parameters)
        }

        public struct Function: Sendable, Codable, Hashable {
            public var name: String
            public var description: String
            /// JSON Schema object as raw JSON string.
            public var parameters: String

            public init(name: String, description: String, parameters: String) {
                self.name = name
                self.description = description
                self.parameters = parameters
            }

            enum CodingKeys: String, CodingKey {
                case name, description, parameters
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                description = try container.decode(String.self, forKey: .description)
                parameters = try container.decode(RawJSONValue.self, forKey: .parameters).rawJSON
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encode(description, forKey: .description)
                try container.encode(RawJSONValue(rawJSON: parameters), forKey: .parameters)
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, thinking, stream
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
        case enableThinking = "enable_thinking"
        case streamOptions = "stream_options"
    }
}

// MARK: - Stream chunks

/// One server-sent chunk of a streaming chat completion.
public struct ChatChunk: Sendable, Codable, Hashable {
    public var id: String?
    public var choices: [Choice]
    public var usage: Usage?

    public init(id: String? = nil, choices: [Choice], usage: Usage? = nil) {
        self.id = id
        self.choices = choices
        self.usage = usage
    }

    public struct Choice: Sendable, Codable, Hashable {
        public var index: Int
        public var delta: Delta
        public var finishReason: String?

        public init(index: Int, delta: Delta, finishReason: String? = nil) {
            self.index = index
            self.delta = delta
            self.finishReason = finishReason
        }

        public struct Delta: Sendable, Codable, Hashable {
            public var role: String?
            public var content: String?
            /// Reasoning content (DeepSeek/compatible gateways).
            public var reasoningContent: String?
            public var toolCalls: [ToolCallDelta]?

            public init(
                role: String? = nil,
                content: String? = nil,
                reasoningContent: String? = nil,
                toolCalls: [ToolCallDelta]? = nil
            ) {
                self.role = role
                self.content = content
                self.reasoningContent = reasoningContent
                self.toolCalls = toolCalls
            }

            enum CodingKeys: String, CodingKey {
                case role, content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    public struct Usage: Sendable, Codable, Hashable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var promptTokenDetails: PromptTokenDetails?
        public var completionTokenDetails: CompletionTokenDetails?
        /// DeepSeek-compatible usage fields. They live at the usage root
        /// rather than inside `prompt_tokens_details`.
        public var promptCacheHitTokens: Int?
        public var promptCacheMissTokens: Int?

        public struct PromptTokenDetails: Sendable, Codable, Hashable {
            public var cachedTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
        }

        public struct CompletionTokenDetails: Sendable, Codable, Hashable {
            public var reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }

        public init(
            promptTokens: Int,
            completionTokens: Int,
            promptTokenDetails: PromptTokenDetails? = nil,
            completionTokenDetails: CompletionTokenDetails? = nil,
            promptCacheHitTokens: Int? = nil,
            promptCacheMissTokens: Int? = nil
        ) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.promptTokenDetails = promptTokenDetails
            self.completionTokenDetails = completionTokenDetails
            self.promptCacheHitTokens = promptCacheHitTokens
            self.promptCacheMissTokens = promptCacheMissTokens
        }

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptTokenDetails = "prompt_tokens_details"
            case completionTokenDetails = "completion_tokens_details"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case promptCacheMissTokens = "prompt_cache_miss_tokens"
        }
    }
}

/// Incremental fragment of one tool call within a chat chunk. Fragments
/// sharing an `index` belong to the same call and their `arguments`
/// strings concatenate in arrival order.
public struct ToolCallDelta: Sendable, Codable, Hashable {
    public var index: Int
    public var id: String?
    public var type: String?
    public var function: Function?

    public init(index: Int, id: String? = nil, type: String? = nil, function: Function? = nil) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }

    public struct Function: Sendable, Codable, Hashable {
        public var name: String?
        public var arguments: String?

        public init(name: String? = nil, arguments: String? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }
}

/// Accumulates `ToolCallDelta` fragments into complete tool calls.
/// Emission happens when `finishReason == "tool_calls"` arrives.
public struct ToolCallAggregator: Sendable {

    public struct AggregatedCall: Sendable, Hashable {
        public var id: String
        public var name: String
        public var argumentsJSON: String

        public init(id: String, name: String, argumentsJSON: String) {
            self.id = id
            self.name = name
            self.argumentsJSON = argumentsJSON
        }
    }

    private struct Partial: Sendable {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    private var partials: [Int: Partial] = [:]

    public init() {}

    /// Returns true when any fragments have been received.
    public var hasCalls: Bool { !partials.isEmpty }

    public mutating func consume(_ delta: ToolCallDelta) {
        var partial = partials[delta.index] ?? Partial()
        if let id = delta.id { partial.id = id }
        if let name = delta.function?.name { partial.name = name }
        if let arguments = delta.function?.arguments { partial.arguments += arguments }
        partials[delta.index] = partial
    }

    /// Finalizes all accumulated calls, ordered by index.
    public func aggregatedCalls() -> [AggregatedCall] {
        partials.keys.sorted().compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            return AggregatedCall(
                id: partial.id,
                name: partial.name,
                argumentsJSON: partial.arguments
            )
        }
    }

    public mutating func reset() {
        partials.removeAll(keepingCapacity: true)
    }
}
