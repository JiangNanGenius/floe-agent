// FloeApp — skill "dream" pass.
//
// Hermes-style self-evolution: after enough activity accumulates, the
// configured model reviews recent exchanges and distills a reusable skill
// (name + description + instructions), which is then created through the
// same reviewed pipeline as manual authoring but remains disabled until the
// user explicitly enables it. Best-effort and cadence-gated.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeAgentRuntime
import FloeSkills

@MainActor
final class SkillDreamService {
    private let environment: AppEnvironment
    private let defaults: UserDefaults

    /// Minimum wall-clock interval between skill-dream passes.
    static let minimumInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let lastKey = "org.floeagent.skillDream.lastAt"

    init(environment: AppEnvironment, defaults: UserDefaults = .standard) {
        self.environment = environment
        self.defaults = defaults
    }

    func dream(conversationID: UUID) async {
        guard shouldDream() else { return }
        // Curator runs on the same low-frequency cadence.
        await environment.skillsCenter.curate()
        guard let (provider, model) = environment.conversationCenter.generalAuxiliaryProviderAndModel() else {
            return
        }
        let messages = (try? await environment.conversationStore.messages(conversationID: conversationID)) ?? []
        let recent = Array(messages
            .filter { $0.role == "user" || $0.role == "assistant" }
            .suffix(16))
        guard recent.count >= 6 else { return }

        let prompt = Self.buildPrompt(recent)
        let raw: String
        do {
            raw = try await Self.extract(
                provider: provider,
                model: model,
                credentials: environment.conversationCenter.resolveCredentials(for: provider),
                adapter: environment.conversationCenter.providerAdapter(for: provider),
                prompt: prompt
            )
        } catch {
            return
        }
        guard let skill = Self.parse(raw) else {
            // `{}` is the model's valid "no reusable skill" response. A
            // malformed response remains due and may retry on a later run.
            if Self.isEmptyProposal(raw) { markDreamed() }
            return
        }
        // Provider output is untrusted persistent prompt text. Store the
        // proposal for review, but never inject it into future runs until the
        // user enables it in Skills.
        do {
            _ = try await environment.skillsCenter.createSkill(skill, enabled: false)
            markDreamed()
        } catch {
            return
        }
    }

    private func shouldDream(now: Date = Date()) -> Bool {
        let last = defaults.double(forKey: Self.lastKey)
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= Self.minimumInterval
    }

    private func markDreamed(at now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastKey)
    }

    private static func buildPrompt(_ messages: [PersistedMessage]) -> String {
        let transcript = messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        return """
        Review this conversation excerpt and decide whether it contains a reusable workflow worth
        capturing as a skill. Only propose a skill when the exchange shows a non-trivial,
        repeatable procedure (a debugging routine, a multi-step setup, a domain convention).

        Return strict JSON with exactly one object:
        {"name": string, "description": string, "instructions": string}
        The instructions field is the full skill body (steps, pitfalls, verification).

        Return {} when nothing is worth capturing.

        Conversation:
        \(transcript)
        """
    }

    private static func extract(
        provider: ProviderProfile,
        model: ModelProfile,
        credentials: ProviderCredentials,
        adapter: any ProviderAdapter,
        prompt: String
    ) async throws -> String {
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [
                (role: "system", content: "You distill reusable skills. Return strict JSON only."),
                (role: "user", content: prompt)
            ],
            toolSchemas: []
        )
        var output = ""
        for try await event in adapter.stream(request: request, credentials: credentials) {
            switch event {
            case .textDelta(let delta):
                guard output.utf8.count + delta.text.utf8.count <= 64 * 1024 else {
                    throw FloeError.validationFailed("Skill extraction response too large")
                }
                output += delta.text
            case .error(let error):
                throw FloeError.internalError("Skill extraction failed: \(error.providerMessage)")
            default:
                break
            }
        }
        return output
    }

    private static func parse(_ raw: String) -> SkillCreationRequest? {
        struct Payload: Decodable {
            var name: String
            var description: String
            var instructions: String
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.name.isEmpty, !payload.instructions.isEmpty else {
            return nil
        }
        return SkillCreationRequest(
            name: payload.name,
            description: payload.description,
            instructions: payload.instructions
        )
    }

    private static func isEmptyProposal(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object.isEmpty
    }
}
#endif
