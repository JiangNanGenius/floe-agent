import Foundation
import FloeLocalModels
import FloeLocalModelCatalog
import FloeCore
import FloeModels
import FloeProviders
import FloeExecution
import FloeAgentRuntime
import MLX
import Darwin
import Synchronization

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
        // Truthful compile-policy metadata, present on every event. It reports
        // whether the production `MLXCompilePolicy` ran in-process and whether
        // the diagnostic inherited the legacy environment switch. A host run
        // with `mlxCompilePolicy=disabled-by-process-policy` and
        // `mlxDisableCompileEnvSet=false` proves the guard is environmentless.
        let values: [String: Any] = fields.merging([
            "event": event, "platform": "macOS-host-not-iPad",
            "mlxActiveBytes": Memory.activeMemory, "mlxPeakBytes": Memory.peakMemory,
            "mlxCacheBytes": Memory.cacheMemory,
            "mlxCompilePolicy": MLXCompilePolicy.compiledTracesDisabled
                ? "disabled-by-process-policy" : "not-applied",
            "mlxDisableCompileEnvSet":
                ProcessInfo.processInfo.environment["MLX_DISABLE_COMPILE"] != nil,
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
        // Build 231 device diagnostics used batch 8, not the historical 48/96
        // profiles. Keep this distinct so host evidence names its actual shape.
        cases.append(ProfileCase(
            label: "device-constrained-batch8",
            profile: LocalInferenceResourceProfile(
                tier: .constrained, contextSize: 8_192, batchSize: 8,
                gpuLayers: 16, maximumOutputTokens: 1_024)
        ))
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

    // MARK: - Post-shutdown lifecycle observation (macOS-host regression gate)

    // Baseline run 35180378429 (baseline pins) ended every shutdown at
    // mlxActiveBytes 4,000-15,976 with footprint ~311MB, while candidate run
    // 35183627027 retained 1.56GB-3.11GB of live MLX memory after the same
    // engine.shutdown(). Generation-string checks stayed green in both, so
    // the host now gates on what the engine leaves behind. These thresholds
    // are a macOS-host regression gate for pin evaluation, NOT an iPad
    // jetsam limit: the host has more memory and no
    // `os_proc_available_memory` pressure.
    static let settledActiveLimitBytes = 64 * 1024 * 1024
    /// Diagnostic reference only. Baseline run 35180378429
    /// (`/usr/bin/time`) reported a 4.86GB peak footprint with normal
    /// architecture noise, so the footprint is captured per observation but
    /// never fails the run by itself.
    static let footprintReferenceBytes = 512 * 1024 * 1024
    /// Baseline run 35180378429 peak mlxActiveBytes. Report-only comparison
    /// (+10% note); never a failure by itself.
    static let baselinePeakActiveReferenceBytes = 2_804_000_582
    /// Post-barrier settle window per engine shutdown. This budget starts
    /// ONLY after the synchronous GPU barrier above returns; the barrier
    /// itself is unbounded and is bounded in practice only by the CI
    /// job-level timeout, so this must not be described as a "total budget
    /// including the barrier". Bounded: no unbounded polling and no
    /// synthetic allocations or extra MLX work between samples.
    static let shutdownSettleBudgetSeconds: TimeInterval = 5.0
    static let shutdownSettleSampleIntervalSeconds: TimeInterval = 0.25

    /// Collected across every profile so a violation in an early profile
    /// never hides evidence from later scenarios: the run records everything
    /// and only fails at the end with a useful summary. Mutex-isolated so
    /// the mutable static state is Swift 6 concurrency-safe without
    /// resorting to unsafe assumptions.
    static let lifecycleViolations = Mutex<[String]>([])

    /// Observe engine memory immediately after `MLXTextEngine.shutdown()`.
    ///
    /// Order: (1) preserve the immediate snapshot, (2) synchronize the
    /// generation GPU stream, (3) watch a bounded settle window, then gate
    /// on the settled active bytes.
    ///
    /// GPU barrier scope (verified against both pin sets via local git
    /// objects): mlx-swift always resolves `StreamOrDevice.default` to the
    /// process-wide static `Stream.gpu` (`Device.defaultStream()` returns
    /// that same static), and mlx-swift-lm at both bd4b7434 and d5d8b290
    /// never installs a task-local stream (`withNewDefaultStream` absent), so
    /// generation runs on that one stream. On the candidate MLX 0.32.2 core
    /// `gpu::synchronize` (mlx/backend/metal/eval.cpp) commits the stream's
    /// `CommandEncoder` and `waitUntilCompleted()` (device.cpp), which fires
    /// the completion handlers that release encoder temporaries. LIMIT: the
    /// 0.32 core also has per-thread default streams
    /// (`mlx/stream.cpp: default_stream_storage`); work submitted to a core
    /// thread-local default stream that mlx-swift never saw would NOT be
    /// covered by this barrier. No such path is reachable from the Swift
    /// layers at either pin, but the observation records the scope instead
    /// of claiming the whole GPU is idle.
    static func observePostShutdown(profileCase: ProfileCase, engineIndex: Int) {
        var fields = profileCase.fields
        fields["engineIndex"] = engineIndex
        record("shutdown-immediate", fields)
        let immediateActive = Memory.activeMemory
        let immediateFootprint = processFootprint()

        fields["gpuSyncScope"] = "swift-static-Stream.gpu (covers mlx-swift "
            + "default stream; core per-thread default streams not reachable "
            + "from Swift layers at either pin)"
        // Blocks until the stream's committed command buffer completes;
        // on MLX 0.32 this releases CommandEncoder temporaries held by
        // completion handlers. Not wrapped in a scheduler barrier, so
        // stream-thread queue tasks that were never submitted are not
        // awaited; the settle window below covers their reclamation.
        // `synchronize()` is not `throws`; a hard MLX error would terminate
        // the process rather than reach a catch block.
        Stream.gpu.synchronize()
        fields["gpuSynchronize"] = "completed"
        record("shutdown-gpu-synchronize", fields)

        let settleStarted = Date()
        let deadline = settleStarted.addingTimeInterval(shutdownSettleBudgetSeconds)
        var sample = 0
        var previousActive = immediateActive
        var previousFootprint = immediateFootprint ?? 0
        // Observe the entire post-barrier window, including after a low
        // sample, so a delayed increase remains visible in the final gate.
        while true {
            Thread.sleep(forTimeInterval: shutdownSettleSampleIntervalSeconds)
            if Date() >= deadline { break }
            sample += 1
            let active = Memory.activeMemory
            let footprint = processFootprint()
            var sampleFields = profileCase.fields
            sampleFields["engineIndex"] = engineIndex
            sampleFields["settleSample"] = sample
            sampleFields["deltaActiveBytes"] = active - immediateActive
            sampleFields["activeDeltaVersusPrevious"] = active - previousActive
            sampleFields["footprintDeltaVersusPrevious"] =
                footprint.map { Int64($0) - Int64(previousFootprint) } ?? 0
            record("shutdown-settle", sampleFields)
            previousActive = active
            previousFootprint = footprint ?? previousFootprint
        }
        let settleElapsed = Date().timeIntervalSince(settleStarted)

        // Gate the FINAL sample directly: the final active bytes decide,
        // not a sticky "was under limit at some point" flag that could
        // mask a later rise back above the limit.
        let settledActive = Memory.activeMemory
        let settledUnderLimit = settledActive <= settledActiveLimitBytes
        fields["settledActiveBytes"] = settledActive
        fields["settleSamples"] = sample
        fields["settleElapsedSeconds"] = settleElapsed
        fields["settledUnderLimit"] = settledUnderLimit
        fields["settledActiveLimitBytes"] = settledActiveLimitBytes
        fields["footprintReferenceBytes"] = footprintReferenceBytes
        fields["settledFootprintBytes"] = processFootprint().map { $0 as Any } ?? NSNull()
        record("shutdown-settled", fields)

        if !settledUnderLimit {
            // Still above the limit at the end of the bounded post-barrier
            // window: sustained retention, not promptly reclaimed pending
            // work. This is exactly the candidate-pin regression (final
            // shutdown left 3,111,710,152 bytes active) that
            // generation-string checks missed. The message reports the
            // ACTUAL elapsed window, not the nominal budget.
            lifecycleViolations.withLock {
                $0.append(
                    "profile \(profileCase.label) engine \(engineIndex): settled active "
                        + "\(settledActive) bytes still exceeds "
                        + "\(settledActiveLimitBytes) byte limit after "
                        + String(format: "%.2f", settleElapsed)
                        + "s post-barrier settle (immediate was \(immediateActive))")
            }
        }
    }

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
            // The one-time compile policy must have run inside the engine
            // initializer before any model/graph construction. A future edit
            // that drops it fails here instead of producing a green run with
            // the retained-compiled-trace memory behavior we rejected.
            guard MLXCompilePolicy.compiledTracesDisabled else {
                throw NSError(domain: "Qualification", code: 6, userInfo: [
                    NSLocalizedDescriptionKey:
                        "MLXTextEngine constructed without applying MLXCompilePolicy; "
                            + "compile-disabled retention is unverified"
                ])
            }
            var done = profileCase.fields
            done["elapsedSeconds"] = Date().timeIntervalSince(started)
            done["loadSucceeded"] = true
            done["mlxCompilePolicyAppliedBeforeLoad"] = true
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
                           instructions: harnessInstructions(minimumCharacters:
                               profileCase.profile.batchSize == 8 ? 16_000 : 12_000),
                           prompt: harnessUserPrompt, maxTokens: 128,
                           expectation: GenerationExpectation(minimumChunks: 3),
                           baselinePeak: baselinePeak)
        await first.shutdown()
        record("shutdown-complete", profileCase.fields)
        observePostShutdown(profileCase: profileCase, engineIndex: 1)

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
        observePostShutdown(profileCase: profileCase, engineIndex: 2)

        record("profile-complete", profileCase.fields)
    }

    /// Exercise actual weights through the production adapter and a controlled
    /// read-only workspace tool. A text-only completion is a failure here.
    static func runActualToolRoundtrip(_ entry: LocalModelCatalogEntry, store: LocalModelStore,
                                       fixtureRoot: URL) async throws {
        let marker = "FLOE_TOOL_PROBE_7B42"
        let fixture = fixtureRoot.appendingPathComponent("qualification-probe.txt")
        let secondMarker = "FLOE_SECOND_TOOL_PROBE_92F1"
        let secondFixture = fixtureRoot.appendingPathComponent("qualification-probe-2.txt")
        try Data(marker.utf8).write(to: fixture, options: .atomic)
        try Data(secondMarker.utf8).write(to: secondFixture, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: secondFixture)
        }

        let runtime = LocalModelRuntime(store: store)
        let adapter = LocalProviderAdapter(runtime: runtime, store: store)
        let model = ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: entry.id,
            displayName: "Qwen tool qualification",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 256),
            capabilities: [.text, .tools]
        )
        let schema = ToolSchemaDescriptor(
            name: "workspace.readFile",
            description: "Read the UTF-8 text of one file in the current workspace",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
        )
        let first = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model,
            messages: [
                (role: "system", content: "A workspace is available. Use workspace.readFile when asked to read a file. Never guess file contents."),
                (role: "user", content: "Call workspace.readFile with path qualification-probe.txt. After the tool result, report its exact contents.")
            ],
            toolSchemas: [schema],
            allToolNames: [schema.name]
        )
        record("tool-roundtrip-start", ["model": entry.id])
        var calls: [ToolCall] = []
        for try await event in adapter.stream(request: first, credentials: ProviderCredentials()) {
            switch event {
            case .toolRequest(let call): calls.append(call)
            case .error(let error): throw NSError(domain: "Qualification.Tool", code: 10,
                userInfo: [NSLocalizedDescriptionKey: error.providerMessage])
            default: break
            }
        }
        guard calls.count == 1, let call = calls.first,
              call.toolName == schema.name,
              let arguments = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
              arguments["path"] as? String == fixture.lastPathComponent else {
            throw NSError(domain: "Qualification.Tool", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Actual model did not request the offered fixture read tool exactly once"])
        }
        let output = try String(contentsOf: fixture, encoding: .utf8)
        let result = ToolResult(callID: call.id, status: .ok, outputSummary: output,
                                outputDigest: FloeDigest.sha256Hex(Data(output.utf8)))
        record("tool-executed", ["model": entry.id, "tool": call.toolName,
                                  "callID": call.id, "receiptDigest": result.outputDigest])

        let followup = ProviderStreamRequest(
            provider: first.provider,
            model: model,
            messages: first.messages,
            toolResults: [(callID: call.id, output: result.outputSummary)],
            pendingToolCalls: [call],
            replayedToolPairs: [ReplayedToolPair(call: call, result: result)],
            toolSchemas: [schema],
            allToolNames: [schema.name]
        )
        var answer = ""
        var completed = false
        for try await event in adapter.stream(request: followup, credentials: ProviderCredentials()) {
            switch event {
            case .textDelta(let delta): answer += delta.text
            case .completed(let info): completed = info.stopReason == .endTurn
            case .toolRequest: throw NSError(domain: "Qualification.Tool", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Model requested an extra tool after the read receipt"])
            case .error(let error): throw NSError(domain: "Qualification.Tool", code: 13,
                userInfo: [NSLocalizedDescriptionKey: error.providerMessage])
            default: break
            }
        }
        guard completed, answer.contains(marker) else {
            throw NSError(domain: "Qualification.Tool", code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Tool continuation did not report the executed read result"])
        }
        record("tool-first-turn-complete", ["model": entry.id, "callID": call.id,
                                            "answerContainsReceipt": true])

        // A fresh user turn after the first completed answer must still retain
        // the schema and the settled first call/result pair. This specifically
        // catches the reported second-turn failure and tool-schema eviction.
        let nextTurn = ProviderStreamRequest(
            provider: first.provider,
            model: model,
            messages: first.messages + [
                (role: "assistant", content: answer),
                (role: "user", content: "Now call workspace.readFile with path qualification-probe-2.txt. Report its exact contents only after the tool responds.")
            ],
            replayedToolPairs: [ReplayedToolPair(call: call, result: result)],
            toolSchemas: [schema],
            allToolNames: [schema.name]
        )
        var secondCalls: [ToolCall] = []
        var secondAnswer = ""
        var secondCompleted = false
        for try await event in adapter.stream(request: nextTurn, credentials: ProviderCredentials()) {
            switch event {
            case .toolRequest(let toolCall): secondCalls.append(toolCall)
            case .textDelta(let delta): secondAnswer += delta
            case .completed(let info): secondCompleted = info.stopReason == .endTurn
            case .error(let error): throw NSError(domain: "Qualification.Tool", code: 15,
                userInfo: [NSLocalizedDescriptionKey: error.providerMessage])
            default: break
            }
        }
        // Synthetic fixture only: retain the actual failure shape before the
        // assertion, rather than losing whether the model answered or called
        // the wrong file. Never log user conversations here.
        record("tool-second-turn-observed", [
            "completed": secondCompleted,
            "syntheticAnswerPrefix": String(secondAnswer.prefix(1024)),
            "calls": secondCalls.map { call in
                ["id": call.id, "name": call.toolName,
                 "syntheticArguments": String(decoding: call.argumentsJSON, as: UTF8.self)]
            }
        ])
        guard secondCalls.count == 1, let secondCall = secondCalls.first,
              secondCall.id != call.id, secondCall.toolName == schema.name,
              let arguments = try JSONSerialization.jsonObject(with: secondCall.argumentsJSON) as? [String: Any],
              arguments["path"] as? String == secondFixture.lastPathComponent else {
            throw NSError(domain: "Qualification.Tool", code: 16,
                userInfo: [NSLocalizedDescriptionKey: "Second user turn did not request the second fixture read with a new call ID"])
        }
        let secondOutput = try String(contentsOf: secondFixture, encoding: .utf8)
        let secondResult = ToolResult(callID: secondCall.id, status: .ok, outputSummary: secondOutput,
                                      outputDigest: FloeDigest.sha256Hex(Data(secondOutput.utf8)))
        record("tool-executed", ["model": entry.id, "tool": secondCall.toolName,
                                  "callID": secondCall.id, "receiptDigest": secondResult.outputDigest,
                                  "conversationTurn": 2])

        let secondFollowup = ProviderStreamRequest(
            provider: nextTurn.provider,
            model: model,
            messages: nextTurn.messages,
            toolResults: [(callID: secondCall.id, output: secondResult.outputSummary)],
            pendingToolCalls: [secondCall],
            replayedToolPairs: [
                ReplayedToolPair(call: call, result: result),
                ReplayedToolPair(call: secondCall, result: secondResult)
            ],
            toolSchemas: [schema],
            allToolNames: [schema.name]
        )
        var secondAnswer = ""
        var secondCompleted = false
        for try await event in adapter.stream(request: secondFollowup, credentials: ProviderCredentials()) {
            switch event {
            case .textDelta(let delta): secondAnswer += delta.text
            case .completed(let info): secondCompleted = info.stopReason == .endTurn
            case .toolRequest: throw NSError(domain: "Qualification.Tool", code: 17,
                userInfo: [NSLocalizedDescriptionKey: "Second tool continuation requested an unexpected extra tool"])
            case .error(let error): throw NSError(domain: "Qualification.Tool", code: 18,
                userInfo: [NSLocalizedDescriptionKey: error.providerMessage])
            default: break
            }
        }
        guard secondCompleted, secondAnswer.contains(secondMarker) else {
            throw NSError(domain: "Qualification.Tool", code: 19,
                userInfo: [NSLocalizedDescriptionKey: "Second tool continuation did not report the second read result"])
        }
        record("tool-roundtrip-complete", ["model": entry.id, "firstCallID": call.id,
                                           "secondCallID": secondCall.id,
                                           "conversationTurns": 2,
                                           "answerContainsReceipt": true])
        await runtime.unload(modelID: entry.id)
    }

    /// Real-weight greeting → web.search → tool result → follow-up web.search
    /// chain through the production `LocalProviderAdapter`, using the EXACT
    /// production `web.search` descriptor. The existing tool host covered only
    /// file reads; this case proves the previously untested news-search path:
    ///   * a greeting never invokes the offered search tool,
    ///   * an explicit news request yields one `web.search` call (directly or
    ///     after the bounded repair) with a non-empty `query`,
    ///   * a truthful receipt then reaches a follow-up turn, which requests a
    ///     second search (new call id, weather query).
    /// No live/paid web search is performed: the tool result is a clearly
    /// labeled synthetic fixture supplied by this host.
    static func runActualSearchRoundtrip(_ entry: LocalModelCatalogEntry, store: LocalModelStore) async throws {
        let runtime = LocalModelRuntime(store: store)
        let adapter = LocalProviderAdapter(runtime: runtime, store: store)
        let model = ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: entry.id,
            displayName: "Qwen search qualification",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 256),
            capabilities: [.text, .tools]
        )
        let schema = ToolSchemaDescriptor(
            name: WebSearchTool.name,
            description: WebSearchTool.toolDescription,
            parametersJSON: WebSearchTool.parametersJSON
        )
        let offeredSchemas = [schema,
            ToolSchemaDescriptor(name: WebFetchTool.name, description: WebFetchTool.toolDescription,
                                 parametersJSON: WebFetchTool.parametersJSON),
            ToolSchemaDescriptor(name: URLDownloadTool.name, description: URLDownloadTool.toolDescription,
                                 parametersJSON: URLDownloadTool.parametersJSON),
            ToolSchemaDescriptor(name: OCRTool.name, description: OCRTool.toolDescription,
                                 parametersJSON: OCRTool.parametersJSON),
            ToolSchemaDescriptor(name: LocalPythonTool.name, description: LocalPythonTool.toolDescription,
                                 parametersJSON: LocalPythonTool.parametersJSON)
        ]
        let systemEnvelope = AgentPromptComposer.compose(
            mode: .chat,
            runtimeContext: "# Run context\nWorkspace: synthetic qualification workspace. Tool permissions are enforced by the host. After a tool result, answer from that result; repeat its receipt marker verbatim and identify synthetic results as synthetic.",
            toolsAvailable: true, compactForLocal: true
        )

        func collect(_ request: ProviderStreamRequest) async throws -> (calls: [ToolCall], answer: String, completed: Bool) {
            var calls: [ToolCall] = []
            var answer = ""
            var completed = false
            for try await event in adapter.stream(request: request, credentials: ProviderCredentials()) {
                switch event {
                case .toolRequest(let call): calls.append(call)
                case .textDelta(let delta): answer += delta.text
                case .completed(let info): completed = info.stopReason == .endTurn
                case .error(let error): throw NSError(domain: "Qualification.Search", code: 30,
                    userInfo: [NSLocalizedDescriptionKey: error.providerMessage])
                default: break
                }
            }
            return (calls, answer, completed)
        }

        // Turn 1: greeting stays conversational.
        record("search-roundtrip-start", ["model": entry.id,
            "systemEnvelopeSource": "production-local-composer",
            "offeredSchemas": offeredSchemas.count])
        let greeting = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model,
            messages: [
                (role: "system", content: systemEnvelope),
                (role: "user", content: "你好，今天过得怎么样？")
            ],
            toolSchemas: offeredSchemas,
            allToolNames: offeredSchemas.map(\.name)
        )
        let greetingReply = try await collect(greeting)
        guard greetingReply.calls.isEmpty, greetingReply.completed,
              !greetingReply.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Qualification.Search", code: 31,
                userInfo: [NSLocalizedDescriptionKey: "Real model invoked web.search for a plain greeting"])
        }

        // Turn 2: explicit news search.
        let search = ProviderStreamRequest(
            provider: greeting.provider,
            model: model,
            messages: greeting.messages + [
                (role: "assistant", content: greetingReply.answer),
                (role: "user", content: "那你能尝试调用一下工具，随便搜索一下今天的新闻吗")
            ],
            toolSchemas: offeredSchemas,
            allToolNames: offeredSchemas.map(\.name)
        )
        let searchReply = try await collect(search)
        let calls = searchReply.calls
        guard calls.count == 1, let call = calls.first, call.toolName == schema.name,
              let arguments = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
              let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw NSError(domain: "Qualification.Search", code: 32,
                userInfo: [NSLocalizedDescriptionKey:
                    "Real model did not request exactly one web.search call with a non-empty query"])
        }

        // Truthful, clearly labeled synthetic receipt — no live search.
        let firstMarker = "FLOE_SEARCH_RECEIPT_7A31"
        let summary = "receipt marker: \(firstMarker). synthetic fixture (no live search performed): 3 normalized results for query \"\(query)\""
        let result = ToolResult(callID: call.id, status: .ok, outputSummary: summary,
                                outputDigest: FloeDigest.sha256Hex(Data(summary.utf8)))
        record("search-tool-executed", ["model": entry.id, "tool": call.toolName,
                                         "callID": call.id, "receiptSource": "synthetic-fixture",
                                         "query": query])

        let continuation = ProviderStreamRequest(
            provider: search.provider, model: model, messages: search.messages,
            toolResults: [(callID: call.id, output: result.outputSummary)],
            pendingToolCalls: [call],
            replayedToolPairs: [ReplayedToolPair(call: call, result: result)],
            toolSchemas: offeredSchemas, allToolNames: offeredSchemas.map(\.name)
        )
        let firstReply = try await collect(continuation)
        // Only synthetic qualification content: retain the actual observation
        // before an assertion so failures distinguish truncation, another call
        // and an answer that did not consume the tool receipt.
        record("search-reply-observed", ["conversationTurn": 2,
            "completed": firstReply.completed, "toolNames": firstReply.calls.map(\.toolName),
            "answerCharacters": firstReply.answer.count,
            "syntheticAnswerPrefix": String(firstReply.answer.prefix(1_024)),
            "answerContainsReceipt": firstReply.answer.contains(firstMarker)])
        guard firstReply.calls.isEmpty, firstReply.completed,
              firstReply.answer.contains(firstMarker) else {
            throw NSError(domain: "Qualification.Search", code: 34,
                userInfo: [NSLocalizedDescriptionKey: "First search receipt did not produce a completed answer containing its marker"])
        }
        record("search-answer-complete", ["model": entry.id, "conversationTurn": 2,
                                          "callID": call.id, "answerContainsReceipt": true])

        // Turn 3 follows the actual greeting and completed search answer.

        let followup = ProviderStreamRequest(
            provider: search.provider,
            model: model,
            messages: search.messages + [
                (role: "assistant", content: firstReply.answer),
                (role: "user", content: "很好，再帮我搜索一下明天的天气")
            ],
            replayedToolPairs: [ReplayedToolPair(call: call, result: result)],
            toolSchemas: offeredSchemas,
            allToolNames: offeredSchemas.map(\.name)
        )
        let followupReply = try await collect(followup)
        let followupCalls = followupReply.calls
        guard followupCalls.count == 1, let followupCall = followupCalls.first,
              followupCall.id != call.id, followupCall.toolName == schema.name,
              let followupArguments = try JSONSerialization.jsonObject(with: followupCall.argumentsJSON) as? [String: Any],
              let weatherQuery = followupArguments["query"] as? String,
              weatherQuery.range(of: "天气|weather", options: .regularExpression) != nil else {
            throw NSError(domain: "Qualification.Search", code: 33,
                userInfo: [NSLocalizedDescriptionKey:
                    "Follow-up turn did not request a new web.search call with a weather query"])
        }
        let secondMarker = "FLOE_SEARCH_RECEIPT_B802"
        let secondSummary = "receipt marker: \(secondMarker). synthetic fixture (no live search performed): weather search fixture, not a real forecast."
        let secondResult = ToolResult(callID: followupCall.id, status: .ok,
            outputSummary: secondSummary, outputDigest: FloeDigest.sha256Hex(Data(secondSummary.utf8)))
        record("search-tool-executed", ["model": entry.id, "tool": followupCall.toolName,
            "callID": followupCall.id, "receiptSource": "synthetic-fixture", "query": weatherQuery])
        let secondContinuation = ProviderStreamRequest(
            provider: followup.provider, model: model, messages: followup.messages,
            toolResults: [(callID: followupCall.id, output: secondResult.outputSummary)],
            pendingToolCalls: [followupCall],
            replayedToolPairs: [ReplayedToolPair(call: call, result: result),
                               ReplayedToolPair(call: followupCall, result: secondResult)],
            toolSchemas: offeredSchemas, allToolNames: offeredSchemas.map(\.name)
        )
        let secondReply = try await collect(secondContinuation)
        record("search-reply-observed", ["conversationTurn": 3,
            "completed": secondReply.completed, "toolNames": secondReply.calls.map(\.toolName),
            "answerCharacters": secondReply.answer.count,
            "syntheticAnswerPrefix": String(secondReply.answer.prefix(1_024)),
            "answerContainsReceipt": secondReply.answer.contains(secondMarker)])
        guard secondReply.calls.isEmpty, secondReply.completed,
              secondReply.answer.contains(secondMarker) else {
            throw NSError(domain: "Qualification.Search", code: 35,
                userInfo: [NSLocalizedDescriptionKey: "Second search receipt did not produce a completed answer containing its marker"])
        }
        record("search-answer-complete", ["model": entry.id, "conversationTurn": 3,
            "callID": followupCall.id, "answerContainsReceipt": true])
        record("search-roundtrip-complete", [
            "model": entry.id,
            "greetingInvokedTool": false,
            "completedToolAnswers": 2,
            "firstCallID": call.id,
            "followupCallID": followupCall.id,
            "conversationTurns": 3,
            "receiptSource": "synthetic-fixture"
        ])
        await runtime.unload(modelID: entry.id)
    }
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
        observePostShutdown(profileCase: profileCase, engineIndex: 1)
        record("profile-complete", profileCase.fields)
    }

    // MARK: - Entry point

    static func main() async throws {
        do {
            try await run()
            record("qualification-complete")
            let violations = lifecycleViolations.withLock { $0 }
            var summary: [String: Any] = [
                "violationCount": violations.count,
                "settledActiveLimitBytes": settledActiveLimitBytes,
                "footprintReferenceBytes": footprintReferenceBytes,
                "footprintGate": "diagnostic-only",
                "baselinePeakActiveReferenceBytes": baselinePeakActiveReferenceBytes,
                "peakGate": "report-only"
            ]
            // Peak reference is Memory.peakMemory (process-wide peak), NOT
            // the per-sample active bytes; label matches the source metric.
            let peak = Memory.peakMemory
            summary["finalPeakMemoryBytes"] = peak
            summary["peakVersusBaselinePct"] = Int(
                (Double(peak) / Double(baselinePeakActiveReferenceBytes) * 100).rounded())
            if !violations.isEmpty {
                summary["violations"] = violations
                record("lifecycle-gate-failed", summary)
                throw NSError(domain: "Qualification", code: 5, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Post-shutdown memory gate failed with \(violations.count) "
                        + "violation(s): " + violations.joined(separator: " | ")
                ])
            }
            record("lifecycle-gate-passed", summary)
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
        try await runActualToolRoundtrip(entry, store: store, fixtureRoot: root)
        try await runActualSearchRoundtrip(entry, store: store)
    }
}
