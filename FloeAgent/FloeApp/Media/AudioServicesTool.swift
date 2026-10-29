// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools

struct AudioServicesTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let kind: String?
    }

    static let name = "audio.services"
    static let toolDescription = "List the concrete audio services that are ready right now for assistant file tools. Transcription entries include the installed on-device recognition model, Apple system recognition and a configured OpenAI-compatible cloud transcription profile. Synthesis entries include ready local voices, configured cloud voice profiles and the system voice. Only actually ready services are returned; a missing model or credential is never presented as available. Use an id with audio.transcribe or audio.synthesize. This tool does not download models, change settings, read secrets or send audio."
    static let parametersJSON = #"{"type":"object","properties":{"kind":{"type":"string","enum":["transcription","synthesis"],"description":"Optionally list only one capability"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let assistant: AssistantAudioService?

    init(assistant: AssistantAudioService? = nil) {
        self.assistant = assistant
    }

    func validate(_ args: Arguments) throws {
        if let kind = args.kind, !["transcription", "synthesis"].contains(kind.lowercased()) {
            throw FloeError.validationFailed("kind must be transcription or synthesis")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let assistant else {
            throw FloeError.validationFailed(
                "Assistant audio service is not configured. Register this tool with the app audio service.")
        }
        await assistant.refreshAvailability()
        try context.cancellation.throwIfCancelled()
        let capability = args.kind.flatMap { AssistantAudioCapability(rawValue: $0.lowercased()) }
        let payload = await MainActor.run { () -> ServicePayload in
            let services = assistant.services.filter { service in
                guard service.ready else { return false }
                guard let capability else { return true }
                return service.capability == capability
            }
            return ServicePayload(
                transcription: services.filter { $0.capability == .transcription },
                synthesis: services.filter { $0.capability == .synthesis },
                automaticTranscription: assistant.service(id: nil, for: .transcription)?.id,
                automaticSynthesis: assistant.service(id: nil, for: .synthesis)?.id,
                selectedTranscription: assistant.priorityIDs(for: .transcription).first,
                selectedSynthesis: assistant.priorityIDs(for: .synthesis).first)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return ToolExecutionOutput(
            summary: json,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            exitStatus: 0,
            maximumSummaryCharacters: 32_768,
            capturedOutput: json)
    }

    private struct ServicePayload: Codable, Sendable {
        let transcription: [AssistantAudioServiceDescriptor]
        let synthesis: [AssistantAudioServiceDescriptor]
        let automaticTranscription: String?
        let automaticSynthesis: String?
        let selectedTranscription: String?
        let selectedSynthesis: String?
    }
}
#endif
