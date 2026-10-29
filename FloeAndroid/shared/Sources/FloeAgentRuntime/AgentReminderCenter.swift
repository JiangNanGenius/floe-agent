import Foundation

/// Kimi-Code-style harness reminders: feature-owned providers registered by
/// variant, evaluated before every provider dispatch, wrapped as
/// `<system-reminder>` blocks so the model treats them as authoritative
/// harness directives rather than user statements or history. Each provider
/// receives its own injection track record and decides whether to fire, so a
/// reminder never repeats identical content and can enforce its own cooldown.
public struct AgentReminderContext: Sendable {
    /// Settled tool calls in this run — a stable clock for cooldowns.
    public var toolCallCount: Int
    /// The content this variant injected most recently, if any.
    public var lastInjectedContent: String?
    /// Tool-call clock value when this variant last injected.
    public var lastInjectedAtToolCall: Int?

    public init(toolCallCount: Int, lastInjectedContent: String?, lastInjectedAtToolCall: Int?) {
        self.toolCallCount = toolCallCount
        self.lastInjectedContent = lastInjectedContent
        self.lastInjectedAtToolCall = lastInjectedAtToolCall
    }
}

public struct AgentReminderCenter: Sendable {
    public typealias Provider = @Sendable (AgentReminderContext) async -> String?

    private var providers: [(variant: String, provider: Provider)] = []
    private var injections: [String: (content: String, toolCall: Int)] = [:]

    public init() {}

    public mutating func register(variant: String, provider: @escaping Provider) {
        providers.append((variant, provider))
    }

    /// Evaluates every registered provider in registration order. A variant
    /// whose content is unchanged since its last injection stays silent;
    /// providers returning nil stay silent. Returns ready-to-inject blocks.
    public mutating func evaluate(toolCallCount: Int) async -> [String] {
        var blocks: [String] = []
        for entry in providers {
            let last = injections[entry.variant]
            let context = AgentReminderContext(
                toolCallCount: toolCallCount,
                lastInjectedContent: last?.content,
                lastInjectedAtToolCall: last?.toolCall
            )
            guard let content = await entry.provider(context),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  content != last?.content else { continue }
            injections[entry.variant] = (content, toolCallCount)
            blocks.append("<system-reminder>\n\(content)\n</system-reminder>")
        }
        return blocks
    }
}
