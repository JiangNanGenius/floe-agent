import Foundation
import FloeLocalModels
import FloeLocalModelCatalog
import MLX
import Darwin

/// macOS-host diagnostic for the real pinned Qwen3.8 snapshot. It intentionally
/// runs the production `MLXTextEngine` and `LocalModelStore` unchanged; only the
/// resource profiles and prompts are selected here. Success is NOT iPad
/// acceptance: this host has more memory than the crashing device and no
/// `os_proc_available_memory` pressure. See README.md.
@main struct Qualification {
    static func processFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        let values: [String: Any] = fields.merging([
            "event": event, "platform": "macOS-host-not-iPad",
            "mlxActiveBytes": Memory.activeMemory, "mlxPeakBytes": Memory.peakMemory,
            "mlxCacheBytes": Memory.cacheMemory,
            "processFootprintBytes": processFootprint().map { $0 as Any } ?? NSNull()
        ]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    static func errorFields(_ error: Error) -> [String: Any] {
        let nsError = error as NSError
        return [
            "errorDomain": nsError.domain,
            "errorCode": nsError.code,
            "errorMessage": nsError.localizedDescription
        ]
    }

    private nonisolated static func verifyMLXErrorGuard() async throws {
        // Exercise the same task-local C callback route that previously
        // terminated the iPad app in prefill; a Swift catch alone is insufficient.
        do {
            try await MLX.withError {
                let worker = Task {
                    let invalid = MLXArray(0..<10, [2, 5]) + MLXArray(0..<15, [3, 5])
                    _ = invalid
                }
                await worker.value
            }
            throw NSError(domain: "Qualification", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Expected MLX error was not captured"])
        } catch is MLXError {
            record("mlx-error-guard-passed")
        }
    }

    // MARK: - Profiles

    /// One production resource profile plus a stable label for logs. The tier
    /// selects the engine's KV precision (`constrained` -> 4-bit, otherwise
    /// 8-bit), and `batchSize` becomes `GenerateParameters.prefillStepSize`.
    struct ProfileCase {
        let label: String
        let profile: LocalInferenceResourceProfile

        var fields: [String: Any] {
            [
                "profile": label,
                "tier": profile.tier.rawValue,
                "batchSize": Int(profile.batchSize),
                "contextSize": Int(profile.contextSize),
                "gpuLayers": Int(profile.gpuLayers),
                "kvBits": profile.tier == .constrained ? 4 : 8
            ]
        }

        var kvBits: Int { profile.tier == .constrained ? 4 : 8 }
    }

    /// Values below mirror `LocalInferenceResourcePolicy.profile(mappedBytes:
    /// physicalMemoryBytes:)`. They are duplicated rather than recomputed
    /// because the policy depends on instantaneous host memory pressure, which
    /// is unrelated to the iPad profiles under test. Keep these literals in
    /// sync with the policy tiers. The 12,015-character app crash turn was
    /// `constrained context=8192 batch=48` and the recovered retry was
    /// `balanced context=12288 batch=96`.
    static func profileCases(includeBaseline: Bool) -> [ProfileCase] {
        var cases: [ProfileCase] = []
        if includeBaseline {
            // Original diagnostic baseline: batch 32, the only configuration
            // the first cloud run exercised. Optional so the default run covers
            // the two App-observed profiles.
            cases.append(ProfileCase(
                label: "baseline-constrained-batch32",
                profile: LocalInferenceResourceProfile(
                    tier: .constrained, contextSize: 8_192, batchSize: 32,
                    gpuLayers: 12, maximumOutputTokens: 128)
            ))
        }
        cases.append(ProfileCase(
            label: "constrained-batch48",
            profile: LocalInferenceResourceProfile(
                tier: .constrained, contextSize: 8_192, batchSize: 48,
                gpuLayers: 16, maximumOutputTokens: 1_024)
        ))
        cases.append(ProfileCase(
            label: "balanced-batch96",
            profile: LocalInferenceResourceProfile(
                tier: .balanced, contextSize: 12_288, batchSize: 96,
                gpuLayers: 24, maximumOutputTokens: 1_536)
        ))
        return cases
    }

    // MARK: - Synthetic fixtures (no user content)

    /// The App crash turn placed ~12,015 characters of harness text in the
    /// SYSTEM message with a 15-character user prompt. Mirror that shape with
    /// synthetic, varied prose so the prefill spans many chunks at both batch
    /// sizes. Nothing here is derived from a real conversation.
    static func harnessInstructions(minimumCharacters: Int) -> String {
        var sections: [String] = [
            "You are Floe's on-device assistant running inside an iPad app. The operator pressed send on a short question. "
                + "Follow the operating rules below, keep any blue item, and answer in one short sentence. "
                + "This document is synthetic diagnostic text and contains no user data."
        ]
        var index = 1
        while sections.joined(separator: "\n").count < minimumCharacters {
            let minute = (index * 7) % 60
            let color = index % 3 == 0 ? "amber" : "blue"
            sections.append(
                "Rule \(index): At minute \(minute) the operator reviewed synthetic item \(index) "
                    + "in workspace batch \(index * 13 % 997), marked it \(color), and confirmed that the "
                    + "checklist value \(index * 31 % 4099) must not change. Keep the blue item. "
                    + "Do not invent requirements beyond the recorded note \(index)."
            )
            index += 1
        }
        return sections.joined(separator: "\n")
    }

    static let harnessUserPrompt = "What color now?"

    static func shortBenchmarkInstructions() -> String { "Answer briefly in one sentence." }

    // MARK: - Engine lifecycle

    static func loadEngine(_ entry: LocalModelCatalogEntry, using profileCase: ProfileCase,
                           directory: URL, baselinePeak: Int) async throws -> MLXTextEngine {
        var fields = profileCase.fields
        fields["model"] = entry.id
        fields["mlxProcessPeakIncreaseBytes"] = max(0, Memory.peakMemory - baselinePeak)
        record("load-start", fields)
        let started = Date()
        do {
            let engine = try await MLXTextEngine(
                modelDirectory: directory,
                includesVisionProjector: false,
                resourceProfile: profileCase.profile
            )
            var done = profileCase.fields
            done["elapsedSeconds"] = Date().timeIntervalSince(started)
            done["loadSucceeded"] = true
            record("load-complete", done)
            return engine
        } catch {
            var failed = profileCase.fields
            failed["elapsedSeconds"] = Date().timeIntervalSince(started)
            failed["loadSucceeded"] = false
            failed.merge(errorFields(error)) { _, new in new }
            record("load-failed", failed)
            throw error
        }
    }

    // MARK: - Generation

    struct GenerationExpectation {
        /// When set, the prepared prompt must span at least this many prefill
        /// chunks (estimated from the pinned prepare loop, which leaves the last
        /// block for decode). This is the concrete
        /// reproduction requirement for the App's long-prefill crash.
        let minimumChunks: Int
    }

    @discardableResult
    static func generate(
        _ engine: MLXTextEngine,
        using profileCase: ProfileCase,
        turn: String,
        instructions: String,
        prompt: String,
        maxTokens: Int,
        expectation: GenerationExpectation? = nil,
        baselinePeak: Int
    ) async throws -> LocalGenerationResult {
        var startFields = profileCase.fields
        startFields["turn"] = turn
        startFields["instructionsCharacters"] = instructions.count
        startFields["promptCharacters"] = prompt.count
        startFields["requestedMaxTokens"] = maxTokens
        startFields["mlxProcessPeakIncreaseBytes"] = max(0, Memory.peakMemory - baselinePeak)
        record("generation-start", startFields)
        let started = Date()
        do {
            let result = try await engine.completeMeasured(
                instructions: instructions, prompt: prompt, maxTokens: maxTokens)
            let elapsed = Date().timeIntervalSince(started)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  result.outputTokens > 0 else {
                throw NSError(domain: "Qualification", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No generated text for turn \(turn)"])
            }
            let batch = Int(profileCase.profile.batchSize)
            let chunks = max(0, result.inputTokens - 1) / batch
            var fields = profileCase.fields
            fields.merge([
                "turn": turn,
                "instructionsCharacters": instructions.count,
                "promptCharacters": prompt.count,
                "text": result.text,
                "inputTokens": result.inputTokens,
                "outputTokens": result.outputTokens,
                "estimatedPrefillChunks": chunks,
                "elapsedSeconds": elapsed,
                "generationDurationMs": result.generationDurationMs,
                "timeToFirstTokenMs": result.timeToFirstTokenMs.map { $0 as Any } ?? NSNull(),
                "mlxProcessPeakIncreaseBytes": max(0, Memory.peakMemory - baselinePeak)
            ]) { _, new in new }
            record("generation-complete", fields)

            if let expectation {
                if chunks < expectation.minimumChunks {
                    // Record the offending numbers before throwing so the
                    // preserved log explains the assertion without editing the
                    // engine to make the run pass.
                    record("multi-chunk-failed", fields.merging([
                        "minimumChunks": expectation.minimumChunks,
                        "reason": "prepared prompt did not span enough prefill chunks"
                    ]) { _, new in new })
                    throw NSError(domain: "Qualification", code: 3, userInfo: [
                        NSLocalizedDescriptionKey:
                            "Turn \(turn) covered \(chunks) prefill chunk(s) at batch \(batch); "
                                + "expected at least \(expectation.minimumChunks)"
                    ])
                }
                record("multi-chunk-verified", fields.merging([
                    "minimumChunks": expectation.minimumChunks
                ]) { _, new in new })
            }
            return result
        } catch {
            var failed = profileCase.fields
            failed["turn"] = turn
            failed["elapsedSeconds"] = Date().timeIntervalSince(started)
            failed.merge(errorFields(error)) { _, new in new }
            record("generation-failed", failed)
            throw error
        }
    }

    // MARK: - Workloads

    /// Two real-weight profiles are exercised in sequence against a single
    /// downloaded snapshot directory. Only one engine is alive at a time: the
    /// first engine is shut down before the second profile loads.
    static func runActualProfile(_ entry: LocalModelCatalogEntry, using profileCase: ProfileCase,
                                 directory: URL) async throws {
        var startFields = profileCase.fields
        startFields["model"] = entry.id
        record("profile-start", startFields)
        let baselinePeak = Memory.peakMemory

        // Turn 1: short benchmark-style prompt.
        let first = try await loadEngine(entry, using: profileCase, directory: directory,
                                         baselinePeak: baselinePeak)
        try await generate(first, using: profileCase, turn: "short-benchmark",
                           instructions: shortBenchmarkInstructions(),
                           prompt: "用中文和 English 打个招呼。", maxTokens: 48,
                           baselinePeak: baselinePeak)

        // Turn 2: ~12k-character SYSTEM instructions with a short user prompt,
        // the shape of the App's batch 48/96 crash turn.
        try await generate(first, using: profileCase, turn: "system-context-chat",
                           instructions: harnessInstructions(minimumCharacters: 12_000),
                           prompt: harnessUserPrompt, maxTokens: 128,
                           expectation: GenerationExpectation(minimumChunks: 3),
                           baselinePeak: baselinePeak)
        await first.shutdown()
        record("shutdown-complete", profileCase.fields)

        // Turn 3: one reload, then a short follow-up question.
        let reloadedPeak = Memory.peakMemory
        let second = try await loadEngine(entry, using: profileCase, directory: directory,
                                          baselinePeak: reloadedPeak)
        try await generate(second, using: profileCase, turn: "reload-followup",
                           instructions: shortBenchmarkInstructions(),
                           prompt: "What is 2 plus 3?", maxTokens: 48,
                           baselinePeak: reloadedPeak)
        await second.shutdown()
        record("shutdown-complete", profileCase.fields)

        record("profile-complete", profileCase.fields)
    }

    /// Original optional baseline: the three prompts from the first cloud run.
    static func runBaseline(_ entry: LocalModelCatalogEntry, using profileCase: ProfileCase,
                            directory: URL) async throws {
        var startFields = profileCase.fields
        startFields["model"] = entry.id
        record("profile-start", startFields)
        let baselinePeak = Memory.peakMemory
        let engine = try await loadEngine(entry, using: profileCase, directory: directory,
                                          baselinePeak: baselinePeak)
        let longerPrompt = (1...450).map { "Document section \($0): keep the blue item." }.joined(separator: "\n")
            + "\nReply only with the color mentioned above."
        let prompts = ["用中文和 English 打个招呼。", "What is 2 plus 3?", longerPrompt]
        for (index, prompt) in prompts.enumerated() {
            let result = try await generate(engine, using: profileCase, turn: "baseline-\(index + 1)",
                instructions: "Answer briefly in one sentence.", prompt: prompt, maxTokens: 64,
                baselinePeak: baselinePeak)
            if index == 2, result.inputTokens < 4_000 {
                record("baseline-long-prefill-failed", profileCase.fields.merging([
                    "inputTokens": result.inputTokens,
                    "minimumInputTokens": 4_000
                ]) { _, new in new })
                throw NSError(domain: "Qualification", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Long-prefill fixture did not exercise enough input tokens"
                ])
            }
        }
        await engine.shutdown()
        record("shutdown-complete", profileCase.fields)
        record("profile-complete", profileCase.fields)
    }

    // MARK: - Entry point

    static func main() async throws {
        do {
            try await run()
            record("qualification-complete")
        } catch {
            record("qualification-failed", errorFields(error))
            throw error
        }
    }

    static func run() async throws {
        try await verifyMLXErrorGuard()
        var arguments = Array(CommandLine.arguments.dropFirst())
        let includeBaseline = arguments.contains("--include-baseline")
        arguments.removeAll { $0 == "--include-baseline" }
        guard arguments.count == 1 else {
            throw NSError(domain: "Qualification", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Provide one isolated model-cache directory (optional flag: --include-baseline)"
            ])
        }
        let entry = CuratedLocalModelCatalog.entries.first { $0.id == "qwen3.8-4b-heretic-mlx4" }!
        let root = URL(fileURLWithPath: arguments[0], isDirectory: true)
        // One LocalModelStore root and one download are reused by every
        // profile. The store either resumes or validates the existing snapshot,
        // so the multi-gigabyte weights are fetched once per job.
        let store = LocalModelStore(root: root)
        record("download-start", ["model": entry.id, "revision": entry.revision])
        let directory = try await store.download(entry)
        record("download-complete", ["model": entry.id, "revision": entry.revision])

        for profileCase in profileCases(includeBaseline: includeBaseline) {
            if includeBaseline, profileCase.label.hasPrefix("baseline") {
                try await runBaseline(entry, using: profileCase, directory: directory)
            } else {
                try await runActualProfile(entry, using: profileCase, directory: directory)
            }
        }
    }
}
