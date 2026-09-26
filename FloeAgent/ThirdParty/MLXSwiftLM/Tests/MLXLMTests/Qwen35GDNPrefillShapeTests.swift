// Copyright © 2026 Apple Inc.
//
// Pins the Qwen3.5/Qwen3.8 GDN prefill shapes exercised by the production
// Floe path (constrained-tier chunked prefill: batch 8, bf16 activations,
// 5,314-token prompts) after the Build229 crash repair. The physical-device
// report symbolicated to `Qwen35GatedDeltaNet.generalConv`'s conv-state tail
// slice (`convInput[0..., (-(convKernelSize - 1))..., 0...]`); these tests
// prove that path is shape-correct for every production window size and that
// chunk boundaries hand state over exactly — i.e. the fault is not in the
// indexing math (the device failure was environmental; see
// LLMModelPrepareFailFastTests for the fail-fast repair).

import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import XCTest

final class Qwen35GDNPrefillShapeTests: XCTestCase {

    /// Qwen3.8-4B-heretic linear-attention dims (hidden 2560): the exact
    /// `convDim = 2 * keyDim + valueDim = 3072` state shapes the production
    /// constrained-tier prefill produces at batch 8.
    private func qwen38Configuration() throws -> Qwen35TextConfiguration {
        let json = """
            {
                "model_type": "qwen3_5",
                "hidden_size": 2560,
                "num_hidden_layers": 48,
                "intermediate_size": 9728,
                "num_attention_heads": 32,
                "num_key_value_heads": 8,
                "head_dim": 128,
                "linear_num_value_heads": 16,
                "linear_num_key_heads": 4,
                "linear_key_head_dim": 128,
                "linear_value_head_dim": 128,
                "linear_conv_kernel_dim": 4,
                "vocab_size": 151936,
                "full_attention_interval": 4
            }
            """
        return try JSONDecoder().decode(
            Qwen35TextConfiguration.self, from: Data(json.utf8))
    }

    private let convDim = 3072  // 2 * (4 * 128) + 16 * 128
    private let recShape: [Int] = [1, 16, 128, 128]  // [B, Hv, Dv, Dk]

    private func makeGDN() throws -> Qwen35GatedDeltaNet {
        MLXRandom.seed(35)
        let gdn = Qwen35GatedDeltaNet(try qwen38Configuration())
        gdn.update(
            parameters: gdn.parameters().mapValues { $0.asType(.bfloat16) })
        return gdn
    }

    // MARK: - Actual state shapes at production window sizes

    /// The conv-state tail slice is shape-correct for every prefill window
    /// size the production constrained tier can schedule (8/48/96) at bf16.
    func testGeneralConvStateShapesAtProductionWindowSizes() throws {
        let gdn = try makeGDN()
        for S in [8, 48, 96] {
            let convState = MLXRandom.normal(
                [1, gdn.convKernelSize - 1, convDim]
            ).asType(.bfloat16)
            let qkv = MLXRandom.normal([1, S, convDim]).asType(.bfloat16)
            eval(convState, qkv)

            let (conv, state) = gdn.generalConv(convState: convState, qkv: qkv)
            eval(conv, state)

            XCTAssertEqual(conv.shape, [1, S, convDim], "S=\(S) conv output")
            XCTAssertEqual(conv.dtype, .bfloat16, "S=\(S) conv dtype")
            XCTAssertEqual(
                state.shape, [1, gdn.convKernelSize - 1, convDim],
                "S=\(S) conv state must keep the sliding-window shape")
            XCTAssertEqual(state.dtype, .bfloat16, "S=\(S) conv state dtype")

            // The new state must be exactly the tail `convKernelSize - 1`
            // rows of `concatenated([convState, qkv])` — the negative slice
            // the device report pointed at.
            let expected = concatenated([convState, qkv], axis: 1)[
                0..., (-(gdn.convKernelSize - 1))..., 0...]
            eval(expected)
            XCTAssertEqual(
                abs(expected.asType(.float32) - state.asType(.float32)).max()
                    .item(Float.self), 0, accuracy: 1e-6,
                "S=\(S) conv state is not the negative tail slice")
        }
    }

    /// Full `forward` at production shapes: output, conv state and recurrent
    /// state all come back with the exact shapes downstream layers expect.
    func testForwardStateShapesAtProductionWindowSizes() throws {
        let gdn = try makeGDN()
        for S in [8, 48, 96] {
            let x = MLXRandom.normal([1, S, 2560]).asType(.bfloat16)
            let convState = MLXRandom.normal(
                [1, gdn.convKernelSize - 1, convDim]
            ).asType(.bfloat16)
            let recState = MLXRandom.normal(recShape).asType(.float32)
            eval(x, convState, recState)

            let (out, newConv, newRec) = gdn.forward(
                x, convState: convState, recState: recState, mask: nil)
            eval(out, newConv, newRec)

            XCTAssertEqual(out.shape, [1, S, 2560], "S=\(S) forward output")
            XCTAssertEqual(newConv.shape, [1, gdn.convKernelSize - 1, convDim])
            XCTAssertEqual(newRec.shape, recShape)
            XCTAssertEqual(newRec.dtype, .float32, "rec state stays fp32")
        }
    }

    /// `callAsFunction` with a `MambaCache` — the exact production entry —
    /// stores the same shapes back into the cache for every window size.
    func testCacheRoundTripAtProductionWindowSizes() throws {
        let gdn = try makeGDN()
        for S in [8, 48, 96] {
            let cache = MambaCache()
            let x = MLXRandom.normal([1, S, 2560]).asType(.bfloat16)
            let out = gdn(x, mask: nil, cache: cache)
            eval(out, cache[0]!, cache[1]!)

            XCTAssertEqual(out.shape, [1, S, 2560])
            XCTAssertEqual(cache[0]!.shape, [1, gdn.convKernelSize - 1, convDim])
            XCTAssertEqual(cache[1]!.shape, recShape)
        }
    }

    // MARK: - Chunk boundary

    /// Two chunks of 8 with an explicit state handoff must equal the single
    /// 16-token call, bitwise, through `generalConv` — the conv state carries
    /// across the boundary exactly (chunk-boundary regression at production
    /// shapes).
    func testGeneralConvChunkBoundaryIsBitwise() throws {
        let gdn = try makeGDN()
        let convState = MLXRandom.normal(
            [1, gdn.convKernelSize - 1, convDim]
        ).asType(.bfloat16)
        let qkv = MLXRandom.normal([1, 16, convDim]).asType(.bfloat16)
        eval(convState, qkv)

        let (convFull, stateFull) = gdn.generalConv(
            convState: convState, qkv: qkv)
        let (convA, stateA) = gdn.generalConv(
            convState: convState, qkv: qkv[0..., ..<8])
        let (convB, stateB) = gdn.generalConv(
            convState: stateA, qkv: qkv[0..., 8...])
        eval(convFull, stateFull, convA, stateA, convB, stateB)

        for (label, got, want) in [
            ("boundary conv", convB.asType(.float32), convFull.asType(.float32)[0..., 8...]),
            ("boundary state", stateB.asType(.float32), stateFull.asType(.float32)),
        ] {
            let mismatches = zip(
                got.asArray(Float.self), want.asArray(Float.self)
            ).lazy.filter { $0.bitPattern != $1.bitPattern }.count
            XCTAssertEqual(
                mismatches, 0,
                "generalConv chunk boundary mismatch in \(label)")
        }
    }

    /// `forward`-level chunk boundary with the recurrent state handoff:
    /// chunked prefill must track the whole-prompt call within fp32
    /// accumulation tolerance for the conv output and the recurrence state.
    func testForwardChunkBoundaryTracksWholePrompt() throws {
        let gdn = try makeGDN()
        let x = MLXRandom.normal([1, 16, 2560]).asType(.bfloat16)
        let convState = MLXRandom.normal(
            [1, gdn.convKernelSize - 1, convDim]
        ).asType(.bfloat16)
        let recState = MLXRandom.normal(recShape).asType(.float32)
        eval(x, convState, recState)

        let (_, convFull, recFull) = gdn.forward(
            x, convState: convState, recState: recState, mask: nil)
        let (_, convA, recA) = gdn.forward(
            x[0..., ..<8], convState: convState, recState: recState, mask: nil)
        let (_, convB, recB) = gdn.forward(
            x[0..., 8...], convState: convA, recState: recA, mask: nil)
        eval(convFull, recFull, convB, recB)

        XCTAssertTrue(
            arrayEqual(convFull, convB).item(Bool.self),
            "conv state must carry across the chunk boundary bitwise")
        XCTAssertTrue(
            allClose(recFull, recB, rtol: 1e-4, atol: 1e-4).item(Bool.self),
            "recurrent state diverged across the chunk boundary")
    }
}
