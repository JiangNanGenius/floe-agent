import Foundation
import FloeLocalModels
import FloeLocalModelCatalog
import MLX

@main struct Qualification {
    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        let values: [String: Any] = fields.merging([
            "event": event, "platform": "macOS-host-not-iPad",
            "mlxActiveBytes": Memory.activeMemory, "mlxPeakBytes": Memory.peakMemory,
            "mlxCacheBytes": Memory.cacheMemory
        ]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Qualification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Provide an isolated model-cache directory"])
        }
        let entry = CuratedLocalModelCatalog.entries.first { $0.id == "qwen3.8-4b-heretic-mlx4" }!
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = LocalModelStore(root: root)
        record("download-start", ["model": entry.id, "revision": entry.revision])
        let directory = try await store.download(entry)
        record("download-complete")
        let profile = LocalInferenceResourceProfile(tier: .constrained, contextSize: 8192,
            batchSize: 32, gpuLayers: 12, maximumOutputTokens: 128)
        let started = Date()
        record("load-start")
        let engine = try await MLXTextEngine(modelDirectory: directory, includesVisionProjector: false, resourceProfile: profile)
        record("load-complete", ["elapsedSeconds": Date().timeIntervalSince(started)])
        let longerPrompt = (1...450).map { "Document section \($0): keep the blue item." }.joined(separator: "\n")
            + "\nReply only with the color mentioned above."
        let prompts = ["用中文和 English 打个招呼。", "What is 2 plus 3?", longerPrompt]
        for (index, prompt) in prompts.enumerated() {
            let turn = index + 1
            record("generation-start", ["turn": turn])
            let generationStarted = Date()
            let result = try await engine.completeMeasured(instructions: "Answer briefly in one sentence.",
                prompt: prompt, maxTokens: 64)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  result.outputTokens > 0 else {
                throw NSError(domain: "Qualification", code: 2, userInfo: [NSLocalizedDescriptionKey: "No generated text"])
            }
            record("generation-complete", ["turn": turn, "text": result.text,
                "inputTokens": result.inputTokens, "outputTokens": result.outputTokens,
                "elapsedSeconds": Date().timeIntervalSince(generationStarted),
                "generationDurationMs": result.generationDurationMs])
            if turn == 3, result.inputTokens < 4_000 {
                throw NSError(domain: "Qualification", code: 3, userInfo: [NSLocalizedDescriptionKey: "Long-prefill fixture did not exercise enough input tokens"])
            }
        }
        await engine.shutdown()
        record("shutdown-complete")
    }
}
