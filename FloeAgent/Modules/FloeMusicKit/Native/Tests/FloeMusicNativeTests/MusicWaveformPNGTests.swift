// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
@testable import FloeMusicNative

/// Deterministic pixel checks for the standalone waveform PNG renderer:
/// synthetic WAV/AIFF fixtures whose decoded image regions, fixed [-1, 1]
/// amplitude mapping, channel lanes, time/channel labels and cooperative
/// cancellation are all verified on real decoded pixels.
final class MusicWaveformPNGTests: XCTestCase {
    private let g = MusicWaveformPNGGeometry.self

    // MARK: - Fixtures

    private func fixtureFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform-png-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }

    private func appendLE32(_ value: UInt32, to data: inout Data) {
        for shift in [0, 8, 16, 24] { data.append(UInt8((value >> shift) & 0xff)) }
    }

    /// Minimal IEEE-float32 WAV writer; `declaredFrames` may exceed the payload
    /// to synthesize a truncated exact-length file.
    private func writeWAV(url: URL, sampleRate: UInt32, channels: UInt16, frames: Int,
                          declaredFrames: Int? = nil, fill: (Int, Int) -> Float) throws {
        let dataBytes = UInt32(frames * Int(channels) * 4)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLE32(36 + dataBytes, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE32(16, to: &data)
        appendLE16(3, to: &data) // IEEE float
        appendLE16(channels, to: &data)
        appendLE32(sampleRate, to: &data)
        appendLE32(sampleRate * UInt32(channels) * 4, to: &data)
        appendLE16(channels * 4, to: &data)
        appendLE16(32, to: &data)
        data.append(contentsOf: "data".utf8)
        appendLE32(dataBytes, to: &data)
        var payload = Data(count: frames * Int(channels) * 4)
        payload.withUnsafeMutableBytes { raw in
            var offset = 0
            for frame in 0..<frames {
                for channel in 0..<Int(channels) {
                    raw.storeBytes(of: fill(frame, channel).bitPattern, toByteOffset: offset, as: UInt32.self)
                    offset += 4
                }
            }
        }
        data.append(payload)
        if let declaredFrames {
            // Patch the RIFF and data sizes to claim a longer payload than written.
            let declaredBytes = UInt32(declaredFrames * Int(channels) * 4)
            data.replaceSubrange(4..<8, with: { var d = Data(); appendLE32(36 + declaredBytes, to: &d); return d }())
            let dataRange = data.range(of: Data("data".utf8))!
            data.replaceSubrange((dataRange.lowerBound + 4)..<(dataRange.lowerBound + 8),
                                 with: { var d = Data(); appendLE32(declaredBytes, to: &d); return d }())
        }
        try data.write(to: url, options: .atomic)
    }

    private func writeAIFF(url: URL, sampleRate: Double, seconds: Double, amplitude: Float) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: true,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = Int(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<frames {
            channel[index] = amplitude * Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate))
        }
        try file.write(from: buffer)
    }

    // MARK: - Decoding helpers

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8] // RGBA, row-major from the top-left

        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let o = (y * width + x) * 4
            return (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
        }

        func isBackground(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return p.r > 235 && p.g > 235 && p.b > 235
        }

        func isBlue(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return p.b > 130 && p.b > p.r + 40 && p.g < p.b
        }

        func isOrange(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return p.r > 200 && p.g > 80 && p.g < 180 && p.b < 80
        }

        func isDarkText(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return p.r + p.g + p.b < 390
        }

        func isNeutralLine(_ x: Int, _ y: Int, range: ClosedRange<Int>) -> Bool {
            let p = pixel(x, y)
            let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
            return range.contains(p.r) && range.contains(p.g) && range.contains(p.b) && hi - lo <= 12
        }

        func any(_ xRange: ClosedRange<Int>, _ yRange: ClosedRange<Int>, where predicate: (Int, Int) -> Bool) -> Bool {
            for y in yRange {
                for x in xRange where predicate(x, y) { return true }
            }
            return false
        }
    }

    private func decode(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> Bitmap {
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4e, 0x47], "PNG signature", file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        let width = image.width, height = image.height
        XCTAssertEqual(width, g.canvasWidth, "canvas width", file: file, line: line)
        XCTAssertEqual(height, g.canvasHeight, "canvas height", file: file, line: line)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB), file: file, line: line)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo),
                                    file: file, line: line)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Bitmap(width: width, height: height, bytes: bytes)
    }

    private func render(_ url: URL) async throws -> Bitmap {
        let data = try await MusicWaveformPNG.render(audioURL: url)
        return try decode(data)
    }

    // MARK: - Tests

    func testStereoDCRegionsChannelLanesTimeAndChannelLabels() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stereo-dc.wav")
        try writeWAV(url: url, sampleRate: 44_100, channels: 2, frames: 88_200) { frame, channel in
            if frame >= 44_100 { return 0 }
            return channel == 0 ? 1.0 : -1.0
        }
        let bmp = try await render(url)
        // Lane geometry: L rows 16..296 (center 156), R rows 296..576 (center 436).
        let colA = g.plotLeft + 504, colB = g.plotLeft + 1512 // t = 0.5 s and 1.5 s of a 2 s clip
        XCTAssertTrue(bmp.isBlue(colA, 22) || bmp.isBlue(colA, 23), "L lane +1 DC reaches its top rail")
        XCTAssertTrue(bmp.isBackground(colA, 289) && bmp.isBackground(colA, 290), "L lane bottom rail stays empty for +1")
        XCTAssertTrue(bmp.isBlue(colB, 156), "L lane silence collapses to the zero baseline")
        XCTAssertTrue(bmp.isBackground(colB, 60), "L lane upper area stays empty for silence")
        XCTAssertTrue(bmp.isOrange(colA, 570), "R lane -1 DC reaches its bottom rail")
        XCTAssertTrue(bmp.isBackground(colA, 301) && bmp.isBackground(colA, 302), "R lane top rail stays empty for -1")
        XCTAssertTrue(bmp.isOrange(colB, 436), "R lane silence collapses to the zero baseline")
        XCTAssertTrue(bmp.isBackground(colB, 500), "R lane lower area stays empty for silence")
        // Distinct channel lanes: no foreign color bleeds across lanes.
        XCTAssertFalse(bmp.isOrange(colA, 150) || bmp.isOrange(colA, 156), "no R color inside the L lane")
        XCTAssertFalse(bmp.isBlue(colA, 430) || bmp.isBlue(colA, 436), "no L color inside the R lane")
        // Channel labels "L" / "R" are readable at the left of each lane.
        XCTAssertTrue(bmp.any(22...42, 148...166, where: bmp.isDarkText), "L lane label visible")
        XCTAssertTrue(bmp.any(22...42, 428...446, where: bmp.isDarkText), "R lane label visible")
        // Time labels: "0s" at the left edge, "2s" at the right edge, tick at t = 1.0 s.
        XCTAssertTrue(bmp.any(g.plotLeft...72, g.labelRow...606, where: bmp.isDarkText), "left time label visible")
        XCTAssertTrue(bmp.any(1960...(g.canvasWidth - 1), g.labelRow...606, where: bmp.isDarkText), "right time label visible")
        XCTAssertTrue(bmp.isNeutralLine(1024, 580, range: 130...180), "tick mark at t = 1.0 s")
        XCTAssertTrue(bmp.isNeutralLine(1024, g.axisRow, range: 130...180), "axis line under the t = 1.0 s tick")
    }

    func testPositiveOnlySignalDrawsAboveZeroBaseline() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("positive-only.wav")
        try writeWAV(url: url, sampleRate: 8_000, channels: 1, frames: 8_000) { _, _ in 0.5 }
        let bmp = try await render(url)
        let col = g.plotLeft + 504
        XCTAssertTrue(bmp.isBlue(col, 159) || bmp.isBlue(col, 158), "+0.5 maps to its fixed-scale row above zero")
        XCTAssertTrue(bmp.isBackground(col, 22) && bmp.isBackground(col, 23), "top rail stays empty for +0.5")
        XCTAssertTrue(bmp.isBackground(col, 400), "nothing is drawn below the zero baseline for a positive-only signal")
        XCTAssertTrue(bmp.isNeutralLine(col, 296, range: 175...215), "zero baseline remains visible beside the bars")
    }

    func testShortNonGridDurationLabelsEndpointWithoutRepeatingLastTick() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("non-grid.wav")
        try writeWAV(url: url, sampleRate: 8_000, channels: 1, frames: 13_600) { _, _ in 0.25 } // 1.7 s
        let bmp = try await render(url)
        // Step 0.2 s: the last regular tick "1.6s" centers near x = 1913 and the
        // off-grid duration "1.7s" right-aligns at the plot right edge.
        XCTAssertTrue(bmp.any(1883...1943, g.labelRow...610, where: bmp.isDarkText), "last regular tick label stays at its own tick")
        XCTAssertTrue(bmp.any(1962...(g.canvasWidth - 1), g.labelRow...610, where: bmp.isDarkText), "off-grid duration label at the right edge")
        XCTAssertTrue(bmp.isNeutralLine(1913, g.tickRow + 3, range: 130...180), "tick mark under the 1.6 s label")
        XCTAssertTrue(bmp.any(g.plotLeft...72, g.labelRow...610, where: bmp.isDarkText), "0s label at the left edge")
    }

    func testMinMaxEnvelopeAcrossChunkBoundaryOnLongClip() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("long-click.wav")
        // 12 s mono with a +1 burst crossing the 81920-frame decode chunk boundary.
        try writeWAV(url: url, sampleRate: 8_000, channels: 1, frames: 96_000) { frame, _ in
            (81_800...82_039).contains(frame) ? 1.0 : 0
        }
        let bmp = try await render(url)
        let col = g.plotLeft + 1_717 // first partial bin contains both zero and the burst
        XCTAssertTrue(bmp.isBlue(col, 100), "burst bin spans from the zero baseline upward")
        XCTAssertTrue(bmp.isBackground(col, 400), "burst bin leaves the lower half empty")
        let control = g.plotLeft + 100
        XCTAssertTrue(bmp.isBackground(control, 100), "silent bin leaves the upper half empty")
        XCTAssertTrue(bmp.isBlue(control, 296), "silent bin collapses to the zero baseline")
        let far = g.plotRight - 20
        XCTAssertTrue(bmp.isBackground(far, 100) && bmp.isBlue(far, 296), "region after the burst stays silent")
    }

    func testSilenceKeepsFixedScaleBaseline() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("silence.wav")
        try writeWAV(url: url, sampleRate: 8_000, channels: 1, frames: 8_000) { _, _ in 0 }
        let bmp = try await render(url)
        let col = g.plotLeft + 504
        XCTAssertTrue(bmp.isBlue(col, 296), "silence draws its 1 px bar on the zero baseline")
        XCTAssertTrue(bmp.isBackground(col, 60) && bmp.isBackground(col, 500), "silence does not rescale the fixed [-1, 1] axis")
        XCTAssertTrue(bmp.any(g.plotLeft...72, g.labelRow...606, where: bmp.isDarkText), "time labels still drawn for silence")
    }

    func testClippingAndNegativeValuesClampToFixedScale() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clipped.wav")
        try writeWAV(url: url, sampleRate: 8_000, channels: 1, frames: 8_000) { frame, _ in
            frame < 4_000 ? 2.0 : -0.5
        }
        let bmp = try await render(url)
        let loud = g.plotLeft + 504
        let soft = g.plotLeft + 1_512
        XCTAssertTrue(bmp.isBlue(loud, 22) || bmp.isBlue(loud, 23), "+2.0 clamps to the top rail, no rescale")
        XCTAssertTrue(bmp.isBackground(loud, 550), "bottom rail stays empty for the +2.0 region")
        XCTAssertTrue(bmp.isBlue(soft, 432) || bmp.isBlue(soft, 433) || bmp.isBlue(soft, 434), "-0.5 maps to its row below zero")
        XCTAssertTrue(bmp.isBackground(soft, 550), "-0.5 never reaches the bottom rail")
    }

    func testRepeatedRendersAreByteIdentical() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("repeatable.wav")
        try writeWAV(url: url, sampleRate: 8_000, channels: 2, frames: 4_000) { frame, channel in
            0.5 * Float(sin(2 * Double.pi * Double(frame) / 128 + Double(channel) * .pi))
        }
        let first = try await MusicWaveformPNG.render(audioURL: url)
        let second = try await MusicWaveformPNG.render(audioURL: url)
        XCTAssertEqual(first, second, "fixed geometry renders must be byte-identical")
    }

    func testCooperativeCancellationStopsLongRender() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("long-cancel.wav")
        try writeWAV(url: url, sampleRate: 44_100, channels: 1, frames: 44_100 * 90) { frame, _ in
            frame % 2 == 0 ? 0.5 : -0.5
        }
        let task = Task { try await MusicWaveformPNG.render(audioURL: url) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled render must not return PNG data")
        } catch is CancellationError {
            // expected: cancellation is honored between decode chunks
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testAIFFDecodesToReadablePNG() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tone.aiff")
        try writeAIFF(url: url, sampleRate: 44_100, seconds: 0.5, amplitude: 0.5)
        let bmp = try await render(url)
        let drawn = bmp.any(g.plotLeft...(g.plotRight - 1), g.marginTop...(g.axisRow - 1)) { x, y in
            bmp.isBlue(x, y)
        }
        XCTAssertTrue(drawn, "AIFF source decodes to a drawn waveform")
        XCTAssertTrue(bmp.any(g.plotLeft...72, g.labelRow...606, where: bmp.isDarkText), "time labels drawn for AIFF")
    }

    func testTruncatedExactLengthFileIsRejected() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("truncated.wav")
        try writeWAV(url: url, sampleRate: 8_000, channels: 1, frames: 4_000, declaredFrames: 8_000) { _, _ in 0.25 }
        do {
            _ = try await MusicWaveformPNG.render(audioURL: url)
            XCTFail("a truncated PCM file must be rejected, not rendered as silence")
        } catch MusicNativeError.invalid(_) {
            // explicit early-EOF rejection from the renderer
        } catch {
            // an underlying decoder open/read error is also a rejection
        }
    }

    func testNonFiniteSampleThrows() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("nan.wav")
        try writeWAV(url: url, sampleRate: 8_000, channels: 1, frames: 8_000) { frame, _ in
            frame == 100 ? .nan : 0.25
        }
        do {
            _ = try await MusicWaveformPNG.render(audioURL: url)
            XCTFail("non-finite source samples must be rejected")
        } catch MusicNativeError.invalid(_) {
            // expected
        } catch {
            XCTFail("expected MusicNativeError.invalid, got \(error)")
        }
    }

    func testEmptyFileThrows() async throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("empty.wav")
        try writeWAV(url: url, sampleRate: 8_000, channels: 1, frames: 0) { _, _ in 0 }
        do {
            _ = try await MusicWaveformPNG.render(audioURL: url)
            XCTFail("an empty audio file must be rejected")
        } catch MusicNativeError.invalid(_) {
            // expected
        } catch {
            XCTFail("expected MusicNativeError.invalid, got \(error)")
        }
    }
}
