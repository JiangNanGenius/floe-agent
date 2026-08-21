// FloeProviders — OpenAI Responses API wire DTOs.
// Only the fields Floe consumes are modeled; unknown fields are ignored by
// the decoder and unknown event types surface as `.unknown(name)` for
// forward compatibility.

import Foundation

// MARK: - Request

/// Request body for `POST {baseURL}/responses` with `stream: true`.
public struct ResponsesRequest: Sendable, Codable, Hashable {
    public var model: String
    public var input: [InputItem]
    public var tools: [ToolDefinition]
    public var maxOutputTokens: Int?
    public var reasoning: Reasoning?
    public var stream: Bool

    public init(
        model: String,
        input: [InputItem],
        tools: [ToolDefinition] = [],
        maxOutputTokens: Int? = nil,
        reasoning: Reasoning? = nil,
        stream: Bool = true
    ) {
        self.model = model
        self.input = input
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.stream = stream
    }

    public struct Reasoning: Sendable, Codable, Hashable {
        public var effort: String

        public init(effort: String) {
            self.effort = effort
        }
    }

    public enum InputItem: Sendable, Hashable {
        case message(role: String, content: String)
        case multimodalMessage(role: String, content: [ContentPart])
        case functionCall(callID: String, name: String, arguments: String)
        case functionCallOutput(callID: String, output: String)

        public enum ContentPart: Sendable, Codable, Hashable {
            case text(String)
            case imageURL(String)

            private enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                switch try container.decode(String.self, forKey: .type) {
                case "input_image": self = .imageURL(try container.decode(String.self, forKey: .imageURL))
                default: self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let text):
                    try container.encode("input_text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case .imageURL(let url):
                    try container.encode("input_image", forKey: .type)
                    try container.encode(url, forKey: .imageURL)
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, role, content, callID = "call_id", name, arguments, output
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "message"
            switch type {
            case "function_call":
                self = .functionCall(
                    callID: try container.decode(String.self, forKey: .callID),
                    name: try container.decode(String.self, forKey: .name),
                    arguments: try container.decode(String.self, forKey: .arguments)
                )
            case "function_call_output":
                self = .functionCallOutput(
                    callID: try container.decode(String.self, forKey: .callID),
                    output: try container.decode(String.self, forKey: .output)
                )
            default:
                let role = try container.decode(String.self, forKey: .role)
                if let text = try? container.decode(String.self, forKey: .content) {
                    self = .message(role: role, content: text)
                } else {
                    self = .multimodalMessage(
                        role: role,
                        content: try container.decode([ContentPart].self, forKey: .content)
                    )
                }
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .message(let role, let content):
                try container.encode("message", forKey: .type)
                try container.encode(role, forKey: .role)
                try container.encode(content, forKey: .content)
            case .multimodalMessage(let role, let content):
                try container.encode("message", forKey: .type)
                try container.encode(role, forKey: .role)
                try container.encode(content, forKey: .content)
            case .functionCall(let callID, let name, let arguments):
                try container.encode("function_call", forKey: .type)
                try container.encode(callID, forKey: .callID)
                try container.encode(name, forKey: .name)
                try container.encode(arguments, forKey: .arguments)
            case .functionCallOutput(let callID, let output):
                try container.encode("function_call_output", forKey: .type)
                try container.encode(callID, forKey: .callID)
                try container.encode(output, forKey: .output)
            }
        }
    }

    public struct ToolDefinition: Sendable, Codable, Hashable {
        public var type: String = "function"
        public var name: String
        public var description: String
        /// JSON Schema object as raw JSON.
        public var parameters: String

        public init(name: String, description: String, parameters: String) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }

        enum CodingKeys: String, CodingKey {
            case type, name, description, parameters
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "function"
            name = try container.decode(String.self, forKey: .name)
            description = try container.decode(String.self, forKey: .description)
            parameters = try container.decode(RawJSONValue.self, forKey: .parameters).rawJSON
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encode(RawJSONValue(rawJSON: parameters), forKey: .parameters)
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, input, tools, reasoning, stream
        case maxOutputTokens = "max_output_tokens"
    }
}

extension ResponsesRequest.InputItem: Codable {}

// MARK: - Response items

/// A `function_call` output item inside Responses stream events.
public struct FunctionCallItem: Sendable, Codable, Hashable {
    public var id: String?
    public var callID: String
    public var name: String
    public var arguments: String
    public var status: String?

    public init(
        id: String? = nil,
        callID: String,
        name: String,
        arguments: String,
        status: String? = nil
    ) {
        self.id = id
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, name, arguments, status
        case callID = "call_id"
    }
}

// MARK: - Stream events

/// Tagged union over Responses API stream event `type` values.
public enum ResponsesStreamEvent: Sendable, Hashable {
    case outputTextDelta(delta: String)
    case reasoningSummaryTextDelta(delta: String)
    case outputItemDoneFunctionCall(FunctionCallItem)
    case completed(usage: Usage?)
    case incomplete
    case failed(message: String?)
    case error(message: String?, code: String?)
    /// Forward compatibility: event type not yet modeled.
    case unknown(type: String)

    public struct Usage: Sendable, Codable, Hashable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var inputTokenDetails: InputTokenDetails?
        public var outputTokenDetails: OutputTokenDetails?

        public struct InputTokenDetails: Sendable, Codable, Hashable {
            public var cachedTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
        }

        public struct OutputTokenDetails: Sendable, Codable, Hashable {
            public var reasoningTokens: Int?
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }

        public init(
            inputTokens: Int,
            outputTokens: Int,
            inputTokenDetails: InputTokenDetails? = nil,
            outputTokenDetails: OutputTokenDetails? = nil
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.inputTokenDetails = inputTokenDetails
            self.outputTokenDetails = outputTokenDetails
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case inputTokenDetails = "input_tokens_details"
            case outputTokenDetails = "output_tokens_details"
        }
    }
}

extension ResponsesStreamEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, delta, item, response, error
    }

    private enum ResponseKeys: String, CodingKey {
        case status, usage, error
    }

    private enum ErrorKeys: String, CodingKey {
        case message, code
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "response.output_text.delta":
            self = .outputTextDelta(delta: try container.decode(String.self, forKey: .delta))
        case "response.reasoning_summary_text.delta":
            self = .reasoningSummaryTextDelta(delta: try container.decode(String.self, forKey: .delta))
        case "response.output_item.done":
            let item = try container.decode(FunctionCallItem.self, forKey: .item)
            self = .outputItemDoneFunctionCall(item)
        case "response.completed":
            let response = try container.decodeIfPresent(ResponsePayload.self, forKey: .response)
            self = .completed(usage: response?.usage)
        case "response.incomplete":
            self = .incomplete
        case "response.failed":
            let response = try container.decodeIfPresent(ResponsePayload.self, forKey: .response)
            self = .failed(message: response?.errorMessage)
        case "error":
            let payload = try container.decodeIfPresent(ErrorPayload.self, forKey: .error)
            self = .error(message: payload?.message, code: payload?.code)
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .outputTextDelta(let delta):
            try container.encode("response.output_text.delta", forKey: .type)
            try container.encode(delta, forKey: .delta)
        case .reasoningSummaryTextDelta(let delta):
            try container.encode("response.reasoning_summary_text.delta", forKey: .type)
            try container.encode(delta, forKey: .delta)
        case .outputItemDoneFunctionCall(let item):
            try container.encode("response.output_item.done", forKey: .type)
            try container.encode(item, forKey: .item)
        case .completed(let usage):
            try container.encode("response.completed", forKey: .type)
            try container.encode(ResponsePayload(status: "completed", usage: usage, errorMessage: nil), forKey: .response)
        case .incomplete:
            try container.encode("response.incomplete", forKey: .type)
        case .failed(let message):
            try container.encode("response.failed", forKey: .type)
            try container.encode(ResponsePayload(status: "failed", usage: nil, errorMessage: message), forKey: .response)
        case .error(let message, let code):
            try container.encode("error", forKey: .type)
            try container.encode(ErrorPayload(message: message, code: code), forKey: .error)
        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }

    /// Decodes the nested `response` object of completed/failed events.
    private struct ResponsePayload: Codable {
        var status: String?
        var usage: Usage?
        var errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case status, usage, error
        }

        init(status: String?, usage: Usage?, errorMessage: String?) {
            self.status = status
            self.usage = usage
            self.errorMessage = errorMessage
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
            if let errorObject = try container.decodeIfPresent(ErrorPayload.self, forKey: .error) {
                errorMessage = errorObject.message
            } else {
                errorMessage = nil
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encodeIfPresent(usage, forKey: .usage)
            if let errorMessage {
                try container.encode(ErrorPayload(message: errorMessage, code: nil), forKey: .error)
            }
        }
    }

    private struct ErrorPayload: Codable {
        var message: String?
        var code: String?
    }
}

/// Alias kept for design-doc naming (`OpenAIResponsesStreamEvent`).
public typealias OpenAIResponsesStreamEvent = ResponsesStreamEvent
