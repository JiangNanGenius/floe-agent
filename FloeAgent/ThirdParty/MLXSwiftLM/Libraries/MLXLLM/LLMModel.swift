// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXLMCommon

/// Marker protocol for LLMModels
public protocol LLMModel: LanguageModel, LoRAModel {

    /// Models can implement this is they need a custom `MessageGenerator`.
    ///
    /// The default implementation returns `DefaultMessageGenerator`.
    func messageGenerator(tokenizer: Tokenizer) -> MessageGenerator
}

extension LLMModel {

    /// Default prepare step for ``LLMModel``.
    ///
    /// This will evaluate the prompt in chunks until there is a small number of
    /// tokens left to feed into the `TokenIterator`.
    public func prepare(
        _ input: LMInput, cache: [KVCache], state: LMOutput.State?, windowSize: Int?
    ) throws
        -> PrepareResult
    {
        let prefillStepSize = windowSize ?? 512
        var y = input.text

        // Floe local fix (Build229 crash repair): run the windowed prefill
        // under a scoped MLX error handler and check the box between windows
        // (and once after the final flush). MLX reports C++ errors (e.g.
        // "[METAL] Command buffer execution failed" from a transient
        // allocation failure or a backgrounded GPU) through the error
        // handler and then returns degenerate 0-dim arrays; callers that
        // keep building graphs on them crash in Swift graph code (the
        // device report symbolicated to getItemND via the GDN conv-state
        // slice). Failing fast between windows turns that process abort
        // into a throw carrying the original MLX message. Successful
        // prefills are unchanged: a clean box is a no-op check.
        try MLX.withError { errorBox in
            try withPreparedCache(cache, lengths: y.sequenceLengths) {
                // Prepare the prompt in chunks if larger than the prefill size.
                // asyncEval lets the CPU build chunk N+1's graph while the GPU evaluates
                // chunk N.
                var state: LMOutput.State? = state
                while y.tokens.size > prefillStepSize {
                    // Cooperative cancellation between prefill windows. On iOS, GPU work
                    // submitted after the app moves to the background is rejected by the
                    // system ("Insufficient Permission"), and the resulting command-buffer
                    // error is thrown from a Metal completion handler where it cannot be
                    // caught, aborting the process. Without this check a long prompt's
                    // prefill cannot be interrupted, so apps cannot stop GPU submissions
                    // in time when entering the background. See ml-explore/mlx-swift-examples#230.
                    try Task.checkCancellation()
                    // Pool per chunk: long prompts run hundreds of chunk forwards
                    // before returning to any autorelease boundary.
                    autoreleasepool {
                        let input = y[.newAxis, ..<prefillStepSize]
                        let output = self(input, cache: cache.isEmpty ? nil : cache, state: state)
                        state = output.state
                        asyncEval(cache)
                        y = y[prefillStepSize...]
                    }
                    // Fail fast on an MLX error raised while building or
                    // scheduling this window, before the next window builds
                    // graphs on degenerate arrays.
                    try errorBox.check()
                }

                // Single sync after the loop to flush any remaining async work.
                eval(cache)
                try errorBox.check()
            }
        }

        return .tokens(y)
    }

    public func messageGenerator(tokenizer: Tokenizer) -> MessageGenerator {
        DefaultMessageGenerator()
    }
}
