// Copyright © 2026 Apple Inc.
//
// Floe local regression for the Build229 device-crash repair (patch 0002):
// the default `LLMModel.prepare` windowed prefill must fail fast — throw the
// first MLX error raised between prefill windows — instead of continuing to
// build graphs on the degenerate 0-dim arrays the MLX C API returns after an
// error.
//
// Physical-device evidence (Build229, iPad16,10): EXC_BREAKPOINT in
// `getItemND` reached through `Qwen35GatedDeltaNet.generalConv`'s conv-state
// tail slice, ~54s into a 5,314-token batch-8 chunked prefill under ~280MB
// memory headroom. The trap fires at MLXArray+Indexing.swift `starts[axis]`
// because slicing a degenerate 0-dim array with three slice operations
// indexes an empty starts array. Host reproduction (scratch):
//   1. inject an MLX error (captured, not thrown),
//   2. continue building graphs,
//   3. slice a degenerate array -> Index out of range trap in getItemND.
// With the fix, the same scenario throws `MLXError.caught` carrying the
// original message instead of trapping.

import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXNN
import XCTest

final class LLMModelPrepareFailFastTests: XCTestCase {

    /// Minimal `LLMModel` whose forward poisons the stream on one window —
    /// mirroring what real model code does when an MLX op fails: the error is
    /// reported through the error handler and a degenerate 0-dim array
    /// propagates into the graph. The *next* window consumes the degenerate
    /// array through a three-slice subscript, the exact Build229 trap site.
    private final class PoisonedWindowModel: Module, LLMModel, KVCacheDimensionProvider {
        let vocabularySize = 16
        let kvHeads: [Int] = [1]

        /// Index (0-based) of the prefill window that raises the MLX error.
        var poisonAtWindow = 1
        /// When true, the poisoned window only enqueues poisoned lazy work
        /// into the KV cache; the error fires at the final `eval(cache)`.
        var deferPoisonToCacheFlush = false
        var windowsServed = 0

        func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
            defer { windowsServed += 1 }
            if windowsServed == poisonAtWindow {
                // A synchronizing MLX failure: invalid broadcast. The error
                // goes to the scoped handler; `bad` becomes a degenerate
                // 0-dim array, like every array produced after a C API error.
                let bad = MLXArray(0 ..< 6, [2, 3]) + MLXArray(0 ..< 20, [4, 5])
                if deferPoisonToCacheFlush, let kv = cache?.first as? KVCacheSimple {
                    // Keep everything lazy: the error only fires when
                    // prepare's final eval(cache) forces the cache contents.
                    kv.update(keys: bad, values: bad)
                    return inputs
                }
                eval(bad)
                return bad
            }
            if windowsServed > poisonAtWindow {
                // Consume the degenerate array the way the GDN conv-state
                // update does: concatenate it against a real activation and
                // take the negative tail slice (three slice operations on a
                // degenerate rank-0 source -> getItemND trap without the fix).
                let degenerate = MLXArray(0 ..< 6, [2, 3]) + MLXArray(0 ..< 20, [4, 5])
                eval(degenerate)
                let qkv = MLXRandom.normal([inputs.dim(0), inputs.dim(1), 4])
                    .asType(inputs.dtype)
                let convInput = concatenated(
                    [degenerate.reshaped(1, 1, 4), qkv], axis: 1)
                return convInput[0..., (-3)..., 0...].asType(inputs.dtype)
            }
            return inputs
        }

        func newCache(parameters: GenerateParameters?) -> [KVCache] {
            (0 ..< kvHeads.count).map { _ in KVCacheSimple() }
        }

        var loraLayers: [Module] { [] }
    }

    private func makeInput(tokenCount: Int) -> LMInput {
        LMInput(text: .init(tokens: MLXArray(0 ..< tokenCount, [tokenCount])))
    }

    /// No error: every window is processed and prepare returns the remainder,
    /// exactly as before the patch (output preservation on the happy path).
    /// 24 tokens at step 8: two windows (24 > 8, 16 > 8), remainder 8.
    func testPrepareCompletesWithoutError() throws {
        let model = PoisonedWindowModel()
        model.poisonAtWindow = .max  // never poison
        let result = try model.prepare(
            makeInput(tokenCount: 24),
            cache: model.newCache(parameters: nil),
            state: nil,
            windowSize: 8
        )
        guard case .tokens(let remainder) = result else {
            XCTFail("prepare should return .tokens for the un-poisoned model")
            return
        }
        XCTAssertEqual(remainder.tokens.size, 8)
        XCTAssertEqual(model.windowsServed, 2)
    }

    /// A mid-prefill MLX error must surface as a throw carrying the original
    /// MLX message, not as a silent continuation (which traps in getItemND
    /// one window later — the Build229 device crash).
    func testPrepareThrowsOnPoisonedWindow() throws {
        let model = PoisonedWindowModel()
        model.poisonAtWindow = 1
        XCTAssertThrowsError(
            try model.prepare(
                makeInput(tokenCount: 24),
                cache: model.newCache(parameters: nil),
                state: nil,
                windowSize: 8
            )
        ) { error in
            guard case MLXError.caught(let message) = error else {
                XCTFail("expected MLXError.caught, got \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("broadcast_shapes"),
                "the throw must preserve the original MLX error message, got: \(message)")
        }
        // The throw must happen at the poisoned window, before any later
        // window builds graphs on degenerate arrays.
        XCTAssertEqual(
            model.windowsServed, 2,
            "prepare must stop right after the poisoned window")
    }

    /// The final `eval(cache)` flush must also be error-checked: an error
    /// that only fires when the cache is forced (poisoned work enqueued
    /// without synchronizing inside the window) is thrown, not returned
    /// inside a corrupt cache.
    func testPrepareThrowsOnFinalFlushError() throws {
        let model = PoisonedWindowModel()
        // 24 tokens at step 8: two windows; poison the FIRST window with
        // lazily-poisoned cache contents so the error only surfaces when
        // prepare's final `eval(cache)` forces the cache.
        model.poisonAtWindow = 0
        model.deferPoisonToCacheFlush = true
        XCTAssertThrowsError(
            try model.prepare(
                makeInput(tokenCount: 24),
                cache: model.newCache(parameters: nil),
                state: nil,
                windowSize: 8
            )
        ) { error in
            guard case MLXError.caught = error else {
                XCTFail("expected MLXError.caught, got \(error)")
                return
            }
        }
    }
}
