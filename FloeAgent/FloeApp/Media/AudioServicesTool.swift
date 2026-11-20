// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeMusicNative
import FloeWorkspace

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

/// Produces a task-owned visual result from an existing workspace audio file.
struct AudioExportWaveformTool: AgentTool {
    struct Arguments: Decodable, Sendable { let path: String }
    static let name = "audio.exportWaveform"
    static let toolDescription = "Export the actual decoded waveform of a task workspace audio file as a PNG. Returns a downloadable file and visual evidence for a vision-capable model. Use audio.inspect for time-window measurements. For a music project use studio.run exportWaveform."
    static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"Existing workspace-relative audio file"}},"required":["path"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    func validate(_ args: Arguments) throws {
        guard !args.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FloeError.validationFailed("Choose a workspace audio file") }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard !context.temporaryReadOnly, let root = context.workspaceRootURL else { throw FloeError.unauthorized }
        try context.cancellation.throwIfCancelled()
        try context.authorizeWorkspacePath(args.path)
        let guardrail = WorkspacePathGuard(rootURL: root)
        let url = try guardrail.resolve(args.path)
        let source = try PersonalPreviewFile(root: guardrail.rootURL, url: url, maximumBytes: RunOutputCaps.standard.perFileBytes)
        try context.authorizeWorkspacePath(source.relativePath)
        let token = context.cancellation
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("floe-waveform-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let staged = folder.appendingPathComponent("input").appendingPathExtension(url.pathExtension)
        let sourceHash = try await personalPreviewOffMain { try source.copy(to: staged) { try token.throwIfCancelled() } }
        let png = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await MusicWaveformPNG.render(audioURL: staged) }
            group.addTask {
                while true {
                    try token.throwIfCancelled()
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw CancellationError() }
            return data
        }
        try token.throwIfCancelled()
        try source.validate()
        let file = folder.appendingPathComponent("waveform.png")
        try png.write(to: file, options: .atomic)
        let digest = FloeDigest.sha256Hex(png)
        let output = try RunOutputSnapshotStore.publish(.init(producerTool: Self.name, slot: "waveform",
            commit: .init(sourceURL: file, sha256: digest, byteCount: png.count, displayName: "waveform.png", mimeType: "image/png")), using: context)
        let artifact = try await StudioResultPublication.imageArtifact(png, context: context)
        try token.throwIfCancelled()
        try source.validate()
        let receipt = try JSONEncoder().encode(["fileName": "waveform.png", "sourceSHA256": sourceHash, "imageSHA256": digest])
        return ToolExecutionOutput(digesting: String(decoding: receipt, as: UTF8.self), exitStatus: 0,
                                   artifacts: [artifact], outputFiles: [output])
    }
}
#endif
