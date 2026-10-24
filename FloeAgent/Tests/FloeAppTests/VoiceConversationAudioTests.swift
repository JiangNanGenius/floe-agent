// FloeAppTests — Continuous voice conversation: audio/text primitives.
//
// SPDX-License-Identifier: MPL-2.0
//
// Pure logic pinned here: endpoint windows, turn validity, barge persistence
// hysteresis, sentence splitting (never per-unit markdown stripping), chunk
// format validation (including the TTS worker's s16le mono 24 kHz bridge),
// frame conversion for the played-progress ledger, completed-sentence
// joining, and durable-segment aggregation. No AVFoundation or clock.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("Continuous voice audio and text primitives")
struct VoiceConversationAudioTests {

    // MARK: Endpoint windows

    @Test("Trailing connectives and dangling punctuation extend the window")
    func endpointWindows() {
        #expect(VoiceConversationEndpointPolicy.isProbablyIncomplete("我先看一下，然后"))
        #expect(VoiceConversationEndpointPolicy.isProbablyIncomplete("等一下，"))
        #expect(VoiceConversationEndpointPolicy.isProbablyIncomplete("tell me and"))
        #expect(VoiceConversationEndpointPolicy.isProbablyIncomplete("I think it is"))
        #expect(!VoiceConversationEndpointPolicy.isProbablyIncomplete("今天天气怎么样。"))
        #expect(!VoiceConversationEndpointPolicy.isProbablyIncomplete("好"))
        #expect(!VoiceConversationEndpointPolicy.isProbablyIncomplete(""))
    }

    // MARK: Turn validity

    @Test("Hesitation-only turns are invalid; short real answers are valid")
    func turnValidity() {
        #expect(!VoiceConversationTurnValidity.isValidTurn(""))
        #expect(!VoiceConversationTurnValidity.isValidTurn("   "))
        #expect(!VoiceConversationTurnValidity.isValidTurn("嗯。"))
        #expect(!VoiceConversationTurnValidity.isValidTurn("呃，啊"))
        #expect(!VoiceConversationTurnValidity.isValidTurn("um uh"))
        #expect(!VoiceConversationTurnValidity.isValidTurn("。，！？"))
        #expect(VoiceConversationTurnValidity.isValidTurn("好"))
        #expect(VoiceConversationTurnValidity.isValidTurn("不对"))
        #expect(VoiceConversationTurnValidity.isValidTurn("5"))
        #expect(VoiceConversationTurnValidity.isValidTurn("ok"))
        #expect(VoiceConversationTurnValidity.isValidTurn("嗯好"))
    }

    // MARK: Barge gate

    @Test("Barge gate emits suggestion after 180 ms and clears after 250 ms of silence")
    func bargeGate() {
        var gate = VoiceConversationBargeGate(suspectAfter: 0.18, clearAfter: 0.25)
        #expect(gate.process(.init(level: 0.5, isSpeech: true, duration: 0.1)) == .none)
        #expect(gate.process(.init(level: 0.5, isSpeech: true, duration: 0.1)) == .suspectStarted)
        #expect(gate.suspecting)
        // Sustained speech never re-emits the edge.
        #expect(gate.process(.init(level: 0.6, isSpeech: true, duration: 0.2)) == .none)
        #expect(gate.process(.init(level: 0, isSpeech: false, duration: 0.15)) == .none)
        #expect(gate.process(.init(level: 0, isSpeech: false, duration: 0.15)) == .cleared)
        #expect(!gate.suspecting)
        // A short noise blip never arms suspicion.
        #expect(gate.process(.init(level: 0.4, isSpeech: true, duration: 0.05)) == .none)
        #expect(gate.process(.init(level: 0, isSpeech: false, duration: 0.3)) == .none)
    }

    // MARK: Sentence splitting

    @Test("Complete sentence boundaries retain trailing punctuation until lookahead or EOF")
    func sentenceSplitting() {
        var splitter = VoiceConversationSentenceSplitter()
        let first = splitter.feed(cumulative: "第一句。第二句！Third? Yes.", finalize: false)
        #expect(first == ["第一句。", "第二句！", "Third?"])
        let more = splitter.feed(cumulative: "第一句。第二句！Third? Yes. 下一句。", finalize: false)
        #expect(more == ["Yes."])
        let tail = splitter.feed(cumulative: "第一句。第二句！Third? Yes. 下一句。尾巴", finalize: true)
        #expect(tail == ["下一句。", "尾巴"])
    }

    @Test("Decimals stay whole and a newline never flushes an unfinished sentence")
    func decimalAndNewlineSplitting() {
        var splitter = VoiceConversationSentenceSplitter()
        // Complete sentences only: the trailing line is still growing.
        let complete = splitter.feed(cumulative: "价格是 3.5 元。\n下一行", finalize: false)
        #expect(complete == ["价格是 3.5 元。"])
        let rest = splitter.feed(cumulative: "价格是 3.5 元。\n下一行。", finalize: false)
        // Keep the terminal until a closer/lookahead arrives or EOF confirms it.
        #expect(rest.isEmpty)
        #expect(splitter.feed(cumulative: "价格是 3.5 元。\n下一行。", finalize: true) == ["下一行。"])

        // A newline alone cannot turn an unfinished line into a model request.
        var lines = VoiceConversationSentenceSplitter()
        #expect(lines.feed(cumulative: "第一行\n第二行", finalize: false).isEmpty)
        #expect(lines.feed(cumulative: "第一行\n第二行", finalize: true) == ["第一行\n第二行"])
    }

    @Test("A long unfinished sentence never fragments at the former 512-character threshold")
    func softFlush() {
        var splitter = VoiceConversationSentenceSplitter()
        let long = String(repeating: "字", count: 700)
        let units = splitter.feed(cumulative: long, finalize: false)
        #expect(units.isEmpty)
        #expect(splitter.consumedCount == 0)
        // Re-feeding the same cumulative emits nothing new (no replay).
        #expect(splitter.feed(cumulative: long, finalize: false).isEmpty)
        // EOF emits the entire unfinished utterance (with the new character)
        // exactly once; no fragment was sent before the sentence ended.
        let tail = splitter.feed(cumulative: long + "尾", finalize: true)
        #expect(tail == [long + "尾"])
        #expect(splitter.feed(cumulative: long + "尾", finalize: true).isEmpty)
        #expect(units.reduce(0) { $0 + $1.count } + (tail.first?.count ?? 0) == long.count + 1)
    }

    // MARK: End-of-utterance flush gate

    @Test("A short voiced utterance followed by ~0.5 s of tail flushes; pure silence never does")
    func utteranceGateFlushesShortSpeech() {
        var gate = VoiceConversationUtteranceGate()
        // ~1 s of quiet-but-real speech (RMS 0.004 ≥ voiced floor 0.002):
        // 16 × 1_000 samples = 16_000 in the gate's 16 kHz domain.
        for _ in 0..<16 { gate.process(rms: 0.004, samples: 1_000) }
        #expect(!gate.shouldFlush)              // still mid-utterance
        // ~0.5 s of tail silence: 8 × 1_000 = 8_000 samples at 16 kHz, the
        // documented `silenceTailSamplesRequired` end-of-utterance tail. The
        // utterance ended → flush NOW, even though the 3 s chunk boundary was
        // never reached.
        for _ in 0..<8 { gate.process(rms: 0.0001, samples: 1_000) }
        #expect(gate.shouldFlush)
        gate.noteDecoded()
        #expect(!gate.shouldFlush)              // counted once, never replayed
    }

    @Test("The gate is driven by real energy: room-tone silence never asks for a decode")
    func utteranceGateIgnoresSilence() {
        var gate = VoiceConversationUtteranceGate()
        for _ in 0..<400 { gate.process(rms: 0.0002, samples: 1_000) }  // 25 s of silence
        #expect(!gate.shouldFlush)
        // Noise blips under the voiced RMS floor accumulate as SILENCE.
        for _ in 0..<40 { gate.process(rms: 0.001, samples: 1_000) }
        #expect(!gate.shouldFlush)
    }

    @Test("Silence mid-utterance resets only the tail, the voiced run keeps counting until decode")
    func utteranceGateTracksRunsExactly() {
        var gate = VoiceConversationUtteranceGate()
        for _ in 0..<5 { gate.process(rms: 0.01, samples: 2_000) }   // 10_000 voiced
        gate.process(rms: 0.01, samples: 2_000)                       // tail reset to 0
        #expect(gate.silenceTailSamples == 0)
        #expect(gate.voicedSamplesSinceDecode == 12_000)
        gate.process(rms: 0, samples: 4_000)
        #expect(!gate.shouldFlush)                                    // tail 4 k < 8 k
        gate.process(rms: 0, samples: 4_000)
        #expect(gate.shouldFlush)                                     // tail 8 k, voiced 12 k
    }

    // MARK: Frame math and joining

    @Test("Chunk frames convert to output-rate frames with rounding")
    func frameConversion() {
        #expect(VoiceConversationFrameMath.outputFrames(chunkFrames: 1_000, chunkSampleRate: 24_000, outputSampleRate: 48_000) == 2_000)
        #expect(VoiceConversationFrameMath.outputFrames(chunkFrames: 441, chunkSampleRate: 44_100, outputSampleRate: 48_000) == 480)
        #expect(VoiceConversationFrameMath.outputFrames(chunkFrames: 0, chunkSampleRate: 24_000, outputSampleRate: 48_000) == 0)
        #expect(VoiceConversationFrameMath.outputFrames(chunkFrames: 10, chunkSampleRate: 0, outputSampleRate: 48_000) == 0)
        #expect(VoiceConversationFrameMath.outputFrames(chunkFrames: 10, chunkSampleRate: 24_000, outputSampleRate: .infinity) == 0)
    }

    @Test("Completed sentences join without mangling CJK or Latin spacing")
    func sentenceJoining() {
        #expect(VoiceConversationFrameMath.joinCompletedSentences(["第一句。", "第二句。"]) == "第一句。第二句。")
        #expect(VoiceConversationFrameMath.joinCompletedSentences(["Hello.", "World."]) == "Hello. World.")
        #expect(VoiceConversationFrameMath.joinCompletedSentences(["", "  ", "好"]) == "好")
        #expect(VoiceConversationFrameMath.joinCompletedSentences([]) == "")
    }

    // MARK: Chunk contract (TTS bridge input)

    @Test("s16le mono 24 kHz chunks bridge to the Float32 sink contract")
    func int16ChunkBridge() {
        let chunk = VoiceConversationAudioChunk(
            int16Samples: [0, 16_384, -16_384, 32_767],
            channelCount: 1,
            sampleRate: 24_000
        )
        #expect(chunk.frameCount == 4)
        #expect(chunk.channelCount == 1)
        #expect(abs(chunk.samples[1] - 0.5) < 0.0001)
        #expect(chunk.isValid)
    }

    @Test("Chunk validation rejects bad formats and caps runaway chunks")
    func chunkValidation() {
        let nan = VoiceConversationAudioChunk(samples: [.nan], channelCount: 1, sampleRate: 24_000)
        #expect(!nan.isValid)
        let tooLow = VoiceConversationAudioChunk(samples: [0.1], channelCount: 1, sampleRate: 1_000)
        #expect(!tooLow.isValid)
        let tooManyChannels = VoiceConversationAudioChunk(samples: [0.1, 0.1, 0.1], channelCount: 3, sampleRate: 24_000)
        #expect(!tooManyChannels.isValid)
        let oddStereo = VoiceConversationAudioChunk(samples: [0.1, 0.1, 0.1], channelCount: 2, sampleRate: 24_000)
        #expect(!oddStereo.isValid)
        let interleavedStereo = VoiceConversationAudioChunk(samples: [0.1, 0.2, 0.3, 0.4], channelCount: 2, sampleRate: 24_000)
        #expect(interleavedStereo.isValid)
        #expect(interleavedStereo.frameCount == 2)
        let huge = VoiceConversationAudioChunk(
            samples: [Float](repeating: 0.1, count: 240_001),
            channelCount: 1,
            sampleRate: 8_000
        )
        #expect(!huge.isValid)
    }

    // MARK: Durable segment aggregation

    @Test("Segment aggregation keeps monotonic cumulative text across tool-boundary resets")
    func segmentAggregation() {
        var aggregator = VoiceConversationSegmentAggregator()
        aggregator.applySnapshot("让我搜索。")
        #expect(aggregator.cumulative == "让我搜索。")
        #expect(aggregator.sealedCount == 0)

        // Boundary: the live segment resets to the new answer.
        aggregator.applySnapshot("结果如下。")
        #expect(aggregator.sealedCount == 1)
        #expect(aggregator.cumulative == "让我搜索。\n结果如下。")

        aggregator.applySnapshot("结果如下。共三条。")
        #expect(aggregator.cumulative == "让我搜索。\n结果如下。共三条。")

        // Duplicate snapshot never duplicates text.
        aggregator.applySnapshot("结果如下。共三条。")
        #expect(aggregator.cumulative == "让我搜索。\n结果如下。共三条。")

        // Store-truth finalization replaces the whole aggregate.
        aggregator.finalize("最终答案。")
        #expect(aggregator.cumulative == "最终答案。")
        #expect(aggregator.sealedCount == 0)
    }

    @Test("Explicit boundary seals the live segment")
    func explicitBoundary() {
        var aggregator = VoiceConversationSegmentAggregator()
        aggregator.applySnapshot("中间说明。")
        aggregator.boundary()
        #expect(aggregator.cumulative == "中间说明。")
        aggregator.applySnapshot("最终回答。")
        #expect(aggregator.cumulative == "中间说明。\n最终回答。")
    }
}
#endif
