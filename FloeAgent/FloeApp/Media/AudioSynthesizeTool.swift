// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace

struct AudioSynthesizeTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let text: String
        let output: String
        let service: String?
    }

    static let name = "audio.synthesize"
    static let toolDescription = "Generate a real audio file in the task workspace from text using the selected configured voice service. Writes a new .wav/.m4a/.caf/.aiff file and attaches a small inline player preview when the audio fits the app artifact limit. Use a service id from audio.services to choose a ready local or configured cloud voice; omit it to use the assistant audio settings (ready local first, configured cloud fallback). The selected service is fixed for the whole call: a failure or cancellation is reported, never retried on another paid route. Temporary chat cannot generate files. Text is final prose, not tool output or reasoning."
    static let parametersJSON = #"{"type":"object","properties":{"text":{"type":"string","description":"Final prose to speak"},"output":{"type":"string","description":"New workspace-relative .wav/.m4a/.caf/.aiff file"},"service":{"type":"string","description":"Optional ready synthesis service id from audio.services"}},"required":["text","output"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .networkAccess, .sendsDataToProvider]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let assistant: AssistantAudioService?

    init(assistant: AssistantAudioService? = nil) {
        self.assistant = assistant
    }

    func validate(_ args: Arguments) throws {
        let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw FloeError.validationFailed(AssistantAudioError.textEmpty.errorDescription!)
        }
        guard args.text.count <= AssistantAudioService.maximumTextCharacters else {
            throw FloeError.validationFailed(
                AssistantAudioError.textTooLong(AssistantAudioService.maximumTextCharacters)
                    .errorDescription!)
        }
        let output = args.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw FloeError.validationFailed("output path is required")
        }
        let ext = (output as NSString).pathExtension.lowercased()
        guard AssistantAudioFileWriter.supportedFormats.contains(ext) else {
            throw FloeError.validationFailed(
                AssistantAudioError.unsupportedOutputFormat(ext).errorDescription!)
        }
        if let service = args.service,
           service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("service id must not be empty")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        try context.authorizeWorkspacePath(args.output)
        if context.temporaryReadOnly {
            throw FloeError.validationFailed(
                AssistantAudioError.temporaryWriteRefused.errorDescription!)
        }
        guard let root = context.workspaceRootURL else {
            throw FloeError.validationFailed("The current task has no workspace.")
        }
        guard let assistant else {
            throw FloeError.validationFailed(
                "Assistant audio service is not configured. Register this tool with the app audio service.")
        }
        let guardrail = WorkspacePathGuard(rootURL: root, maxWriteBytes: 64 * 1024 * 1024)
        let output = try guardrail.resolve(args.output)
        let relative = String(output.path.dropFirst(guardrail.rootURL.path.count + 1))
        try context.authorizeWorkspacePath(relative)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw FloeError.validationFailed(AssistantAudioError.outputExists.errorDescription!)
        }

        let result = try await synthesize(
            assistant: assistant, args: args, output: output, context: context)
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        guard try guardrail.resolve(args.output) == output,
              FileManager.default.fileExists(atPath: output.path),
              let size = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber,
              size.intValue == result.byteCount,
              (try? FloeDigest.sha256Hex(ofFileAt: output)) == result.sha256 else {
            throw FloeError.validationFailed("The generated audio file changed before it could be reported.")
        }

        var outputFiles: [RunOutputFile] = []
        switch RunOutputPublication.state(context) {
        case .legacyDirect:
            break
        case .temporaryExempt:
            throw FloeError.validationFailed(
                AssistantAudioError.temporaryWriteRefused.errorDescription!)
        case .partiallyBound:
            throw RunOutputPublication.partialBindingFailure
        case .required:
            do {
                let published = try RunOutputSnapshotStore.publish(
                    RunOutputSnapshotRequest(
                        producerTool: Self.name,
                        slot: "audio",
                        commit: RunOutputCommit(
                            sourceURL: output,
                            sha256: result.sha256,
                            byteCount: result.byteCount,
                            displayName: output.lastPathComponent,
                            mimeType: result.mimeType,
                            uti: result.uti)),
                    using: context)
                outputFiles = [published]
            } catch let error as RunOutputSnapshotError {
                throw RunOutputPublication.publicationFailure(error)
            }
        }

        let inline = result.inlineArtifact.map { [$0] } ?? []
        let player = result.inlineArtifact == nil
            ? "No inline player (audio exceeds the preview size limit)."
            : "Inline player preview artifact attached."
        return ToolExecutionOutput(
            summary: "Generated \(String(format: "%.2f", result.duration)) s of audio at \(args.output) with \(result.service.title) (\(result.byteCount) bytes, \(result.sampleRate) Hz, sha256 \(result.sha256)). \(player)",
            fullOutputSHA256: FloeDigest.sha256Hex(Data(result.sha256.utf8)),
            exitStatus: 0,
            artifacts: inline,
            outputFiles: outputFiles)
    }

    private func synthesize(
        assistant: AssistantAudioService,
        args: Arguments,
        output: URL,
        context: ToolContext
    ) async throws -> AssistantAudioSynthesisResult {
        try await withThrowingTaskGroup(of: AssistantAudioSynthesisResult.self) { group in
            group.addTask {
                do {
                    return try await assistant.synthesize(
                        text: args.text, outputURL: output,
                        serviceID: args.service, runID: context.runID)
                } catch let error as AssistantAudioError {
                    throw FloeError.validationFailed(error.errorDescription ?? "Audio generation failed.")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw FloeError.validationFailed("Audio generation failed.")
                }
            }
            group.addTask {
                while true {
                    try context.cancellation.throwIfCancelled()
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
#endif
