// FloeCore — Model wire protocol identifier.
// See docs/DEVELOPMENT_PLAN.md §2.2.

/// Wire protocol spoken by a model provider endpoint.
public enum ModelProtocol: String, Sendable, Codable, CaseIterable, Hashable {
    case openAIResponses = "openai-responses"
    case openAIChatCompletions = "openai-chat-completions"
    case anthropicMessages = "anthropic-messages"
}
