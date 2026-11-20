// SPDX-License-Identifier: MPL-2.0
import FloeAgentRuntime
import FloeCore
import FloeMacSelfCore
import FloeProviders
import Foundation

enum MacTaskNaming {
    static func title(for prompt: String, using binding: FloeMacSelfProviderBinding) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var model = binding.model
                model.reasoningEffort = nil
                model.limits.maxOutputTokens = min(96, model.limits.configuredMaxOutputTokens ?? 96)
                let request = ProviderStreamRequest(provider: binding.provider, model: model,
                    contentMessages: [.init(role: "system", text: TaskTitlePrompt.instructions),
                                      .init(role: "user", text: TaskTitlePrompt.input(prompt))],
                    toolSchemas: [], reasoningPolicy: .disabled)
                var text = ""
                for try await event in binding.adapter.stream(request: request, credentials: binding.credentials) {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        text += String(delta.text.prefix(128))
                    case .error: throw FloeError.syncUnavailable("Task naming failed.")
                    default: break
                    }
                    if text.count >= 80 { break }
                }
                let clean = SecretRedactor.redact(text, secret: binding.credentials.apiKey)
                guard !clean.contains(SecretRedactor.replacement), !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FloeError.syncUnavailable("No usable task title.")
                }
                return TaskTitlePrompt.normalizedTitle(clean, fallbackGoal: prompt)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw FloeError.syncUnavailable("Task naming timed out.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
