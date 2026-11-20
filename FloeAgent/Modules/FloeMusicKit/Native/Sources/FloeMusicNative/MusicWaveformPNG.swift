// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Standalone waveform inspection PNG for one audio file.
///
/// Decodes the actual source PCM in bounded off-main chunks (never the whole
/// clip), reduces every channel to per-column min/max, and draws a fixed
/// [-1, 1] amplitude image with CoreGraphics labels via CoreText. Memory stays
/// O(columns * channels) regardless of clip length, cancellation is checked
/// between chunks, and the fixed geometry keeps renders deterministic.
public enum MusicWaveformPNG {
    /// Renders `audioURL` (WAV/AIFF or anything AVAudioFile decodes) to PNG bytes.
    public nonisolated static func render(audioURL: URL) async throws -> Data {
        try Task.checkCancellation()
        // Core Audio accepts a short RIFF payload by clamping its reported length.
        // Check the declared container length before drawing a misleading complete timeline.
        let handle = try FileHandle(forReadingFrom: audioURL)
        defer { try? handle.close() }
        if let header = try handle.read(upToCount: 12), header.count == 12,
           header.prefix(4).elementsEqual("RIFF".utf8), header.suffix(4).elementsEqual("WAVE".utf8) {
            let size = header[4..<8].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if size != UInt32.max, try handle.seekToEnd() < size + 8 {
                throw MusicNativeError.invalid("Incomplete WAV file")
            }
        }
        let model = try await reduce(audioURL: audioURL)
        try Task.checkCancellation()
        return try drawPNG(model: model)
    }
}

/// Internal single source of truth for layout; the deterministic tests read
/// these values through `@testable` so pixel expectations cannot drift.
enum MusicWaveformPNGGeometry {
    static let canvasWidth = 2048
    static let canvasHeight = 640
    static let marginLeft = 16
    static let marginRight = 16
    static let marginTop = 16
    static let marginBottom = 64
    static let lanePadding: CGFloat = 6
    static let tickHeight = 8
    static let labelBandInset = 4

    static var plotLeft: Int { marginLeft }
    static var plotRight: Int { canvasWidth - marginRight }
    static var plotWidth: Int { canvasWidth - marginLeft - marginRight }
    static var plotHeight: Int { canvasHeight - marginTop - marginBottom }
    static var binCount: Int { plotWidth }
    /// Top-down row of the 1 px horizontal time axis line.
    static var axisRow: Int { marginTop + plotHeight }
    /// Top-down row where 1 px tick marks start (just below the axis line).
    static var tickRow: Int { axisRow + 1 }
    /// Top-down row where the tick label band starts.
    static var labelRow: Int { tickRow + tickHeight + labelBandInset }

    /// Waveform colors by channel index (fallback wraps to the last gray).
    static let waveformColors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (31.0 / 255.0, 119.0 / 255.0, 180.0 / 255.0),
        (255.0 / 255.0, 127.0 / 255.0, 14.0 / 255.0),
        (44.0 / 255.0, 160.0 / 255.0, 44.0 / 255.0),
        (214.0 / 255.0, 39.0 / 255.0, 40.0 / 255.0),
        (148.0 / 255.0, 103.0 / 255.0, 189.0 / 255.0),
        (140.0 / 255.0, 86.0 / 255.0, 75.0 / 255.0),
        (227.0 / 255.0, 119.0 / 255.0, 194.0 / 255.0),
        (127.0 / 255.0, 127.0 / 255.0, 127.0 / 255.0),
    ]

    static func waveformColor(_ channel: Int) -> CGColor {
        let pick = waveformColors[min(channel, waveformColors.count - 1)]
        return CGColor(red: pick.r, green: pick.g, blue: pick.b, alpha: 1)
    }

    static let backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let separatorColor = CGColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1)
    static let zeroLineColor = CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
    static let axisColor = CGColor(red: 0.59, green: 0.59, blue: 0.59, alpha: 1)
    static let labelColor = CGColor(red: 0.28, green: 0.28, blue: 0.28, alpha: 1)
}

private struct MusicWaveformModel: Sendable {
    var sampleRate: Double
    var channelCount: Int
    var frameCount: Int64
    /// [channel][bin] reduced extrema on the actual decoded source PCM.
    var minimums: [[Float]]
    var maximums: [[Float]]

    var duration: Double { Double(frameCount) / sampleRate }
}

private enum MusicWaveformLayout {
    /// Top-down row of amplitude `value` inside `lane` for the given lane height.
    /// Positive amplitudes sit above the zero baseline (smaller row index).
    static func amplitudeRow(laneTop: CGFloat, laneHeight: CGFloat, value: Float) -> CGFloat {
        let clamped = CGFloat(min(max(value, -1), 1))
        let inner = laneHeight - 2 * MusicWaveformPNGGeometry.lanePadding
        return laneTop + MusicWaveformPNGGeometry.lanePadding + ((1 - clamped) / 2) * inner
    }
}

public extension MusicWaveformPNG {
    /// Chunked decode + reduction. Runs on the generic executor because the
    /// entry point is `nonisolated`; yields periodically so long clips stay
    /// cooperative. Only `bins * channels` extrema are retained.
    fileprivate static func reduce(audioURL: URL, knownFrames: Int64? = nil) async throws -> MusicWaveformModel {
        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let total = knownFrames ?? file.length
        guard channels > 0, channels <= 16, sampleRate > 0, total > 0 else {
            throw MusicNativeError.invalid("Waveform render needs a non-empty PCM-decodable audio file with 1–16 channels")
        }
        // PCM containers (WAV/AIFF) report an exact frame count; compressed
        // decoders only estimate theirs, so short reads are tolerated there.
        let exactLength = file.fileFormat.commonFormat != .otherFormat
        let bins = MusicWaveformPNGGeometry.binCount
        var minimums = [[Float]](repeating: [Float](repeating: .infinity, count: bins), count: channels)
        var maximums = [[Float]](repeating: [Float](repeating: -.infinity, count: bins), count: channels)
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let pcm = buffer.floatChannelData else { throw MusicNativeError.invalid("Waveform decode buffer") }
        var consumed: Int64 = 0
        var iterations = 0
        let span = Double(bins) / Double(total)
        while true {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let endOfFile: Bool
            do {
                try file.read(into: buffer, frameCount: capacity)
                endOfFile = false
            } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == -39 {
                endOfFile = true
            }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            for channel in 0..<channels {
                let samples = pcm[channel]
                var mins = minimums[channel]
                var maxs = maximums[channel]
                for index in 0..<count {
                    let absolute = consumed + Int64(index)
                    let value = samples[index]
                    guard value.isFinite else {
                        throw MusicNativeError.invalid("Waveform source contains a non-finite sample at frame \(absolute)")
                    }
                    let bin = min(bins - 1, Int(Double(absolute) * span))
                    if value < mins[bin] { mins[bin] = value }
                    if value > maxs[bin] { maxs[bin] = value }
                }
                minimums[channel] = mins
                maximums[channel] = maxs
            }
            consumed += Int64(count)
            if endOfFile { break }
            iterations += 1
            if iterations % 8 == 0 { await Task.yield() }
        }
        if consumed != total {
            guard consumed > 0, !exactLength, knownFrames == nil else {
                throw MusicNativeError.invalid("Waveform length changed during decoding")
            }
            // Some compressed headers estimate duration. Decode again only when that estimate
            // was wrong so column positions and labels describe exactly the same samples.
            return try await reduce(audioURL: audioURL, knownFrames: consumed)
        }
        for channel in 0..<channels {
            for bin in 0..<bins where !minimums[channel][bin].isFinite {
                minimums[channel][bin] = bin > 0 ? minimums[channel][bin - 1] : 0
                maximums[channel][bin] = bin > 0 ? maximums[channel][bin - 1] : 0
            }
        }
        return MusicWaveformModel(sampleRate: sampleRate, channelCount: channels,
                                  frameCount: consumed, minimums: minimums, maximums: maximums)
    }

    /// CoreGraphics/CoreText drawing; no UIKit/AppKit dependency.
    fileprivate static func drawPNG(model: MusicWaveformModel) throws -> Data {
        let g = MusicWaveformPNGGeometry.self
        let width = g.canvasWidth
        let height = g.canvasHeight
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw MusicNativeError.invalid("Waveform color space")
        }
        let storage = NSMutableData(length: width * height * 4)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: storage.mutableBytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: bitmapInfo) else {
            throw MusicNativeError.invalid("Waveform bitmap context")
        }
        context.setShouldAntialias(false)
        context.setFillColor(g.backgroundColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let canvasHeight = CGFloat(height)
        /// Fill that covers top-down rows [top, top + height).
        func fillRow(_ top: CGFloat, x: CGFloat, w: CGFloat, height h: CGFloat, color: CGColor) {
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: canvasHeight - top - h, width: w, height: h))
        }

        let laneCount = model.channelCount
        let laneHeight = CGFloat(g.plotHeight) / CGFloat(laneCount)
        let plotLeft = CGFloat(g.plotLeft)
        let plotRight = CGFloat(g.plotRight)
        let plotWidth = CGFloat(g.plotWidth)

        // Lane separators and fixed-scale zero baselines.
        for lane in 0..<laneCount {
            let laneTop = CGFloat(g.marginTop) + laneHeight * CGFloat(lane)
            fillRow(laneTop, x: plotLeft, w: plotWidth, height: 1, color: g.separatorColor)
            let zero = MusicWaveformLayout.amplitudeRow(laneTop: laneTop, laneHeight: laneHeight, value: 0)
            fillRow(zero, x: plotLeft, w: plotWidth, height: 1, color: g.zeroLineColor)
        }

        // Per-column min/max bars, clamped to the fixed [-1, 1] scale.
        let bins = g.binCount
        for channel in 0..<laneCount {
            let laneTop = CGFloat(g.marginTop) + laneHeight * CGFloat(channel)
            let color = g.waveformColor(channel)
            for bin in 0..<bins {
                let low = MusicWaveformLayout.amplitudeRow(laneTop: laneTop, laneHeight: laneHeight,
                                                           value: model.minimums[channel][bin])
                let high = MusicWaveformLayout.amplitudeRow(laneTop: laneTop, laneHeight: laneHeight,
                                                            value: model.maximums[channel][bin])
                let top = min(low, high)
                let barHeight = max(1, abs(low - high))
                fillRow(top, x: plotLeft + CGFloat(bin), w: 1, height: barHeight, color: color)
            }
        }

        // Horizontal time axis with tick marks and accurately positioned labels.
        let axisRow = CGFloat(g.axisRow)
        fillRow(axisRow, x: plotLeft, w: plotWidth, height: 1, color: g.axisColor)
        let step = timeStep(duration: model.duration)
        var ticks: [Double] = []
        var t = 0.0
        while t <= model.duration + 1e-9 {
            ticks.append(t)
            t += step
        }
        let onGrid = abs((ticks.last ?? 0) - model.duration) <= max(1e-9, step * 1e-3)
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        for (index, tick) in ticks.enumerated() {
            let x = plotLeft + CGFloat(tick / model.duration) * plotWidth
            fillRow(CGFloat(g.tickRow), x: x, w: 1, height: CGFloat(g.tickHeight), color: g.axisColor)
            let isFirst = index == 0
            let isLastOnEdge = index == ticks.count - 1 && onGrid
            let text = formatSeconds(tick)
            if isFirst {
                drawLabel(context, text: text, font: font, x: plotLeft,
                          topDownRow: CGFloat(g.labelRow), alignment: .left)
            } else if isLastOnEdge {
                drawLabel(context, text: text, font: font, x: plotRight,
                          topDownRow: CGFloat(g.labelRow), alignment: .right)
            } else {
                drawLabel(context, text: text, font: font, x: x,
                          topDownRow: CGFloat(g.labelRow), alignment: .center)
            }
        }
        if !onGrid {
            drawLabel(context, text: formatSeconds(model.duration), font: font, x: plotRight,
                      topDownRow: CGFloat(g.labelRow), alignment: .right)
        }

        // Channel lane labels (L/R, M for mono, 1-based numbers beyond stereo).
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 13, nil)
        for channel in 0..<laneCount {
            let laneTop = CGFloat(g.marginTop) + laneHeight * CGFloat(channel)
            let center = laneTop + laneHeight / 2
            drawBaselineLabel(context, text: channelLabel(channel, count: laneCount), font: bold,
                              x: plotLeft + 6, baselineTopDown: center, alignment: .left)
        }

        guard let image = context.makeImage() else {
            throw MusicNativeError.invalid("Waveform image")
        }
        guard let pngData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else {
            throw MusicNativeError.invalid("Waveform PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MusicNativeError.encoder(-1)
        }
        return pngData as Data
    }

    private static func channelLabel(_ channel: Int, count: Int) -> String {
        if count == 1 { return "M" }
        if count == 2 { return channel == 0 ? "L" : "R" }
        return "\(channel + 1)"
    }

    /// Smallest "nice" step keeping about 9 or fewer ticks for the duration.
    private static func timeStep(duration: Double) -> Double {
        let candidates: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let raw = duration / 9
        return candidates.first(where: { $0 >= raw }) ?? max(3600, (raw / 600).rounded(.up) * 600)
    }

    private static func formatSeconds(_ value: Double) -> String {
        if value > 0, value < 0.01 { return String(format: "%.2f ms", value * 1000) }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(), rounded < 1000 { return "\(Int(rounded))s" }
        if rounded < 10 {
            var text = String(format: "%.2f", rounded)
            if text.hasSuffix("0") { text = String(text.dropLast()) }
            return "\(text)s"
        }
        return String(format: "%.1fs", rounded)
    }

    private enum LabelAlignment { case left, center, right }

    /// CoreText label whose text box starts at `topDownRow` (text grows downward).
    private static func drawLabel(_ context: CGContext, text: String, font: CTFont,
                                  x: CGFloat, topDownRow: CGFloat, alignment: LabelAlignment) {
        drawLabel(context, text: text, font: font, color: MusicWaveformPNGGeometry.labelColor,
                  x: x, topDownRow: topDownRow, alignment: alignment)
    }

    private static func drawLabel(_ context: CGContext, text: String, font: CTFont, color: CGColor,
                                  x: CGFloat, topDownRow: CGFloat, alignment: LabelAlignment) {
        let (line, ascent, textWidth) = makeLine(text, font: font, color: color)
        let anchor: CGFloat
        switch alignment {
        case .left: anchor = x
        case .center: anchor = x - textWidth / 2
        case .right: anchor = x - textWidth
        }
        drawLine(context, line: line, x: anchor, baselineTopDown: topDownRow + ascent)
    }

    /// CoreText label anchored by its baseline (used for vertically centered lane labels).
    private static func drawBaselineLabel(_ context: CGContext, text: String, font: CTFont,
                                          x: CGFloat, baselineTopDown: CGFloat, alignment: LabelAlignment) {
        let (line, _, textWidth) = makeLine(text, font: font, color: MusicWaveformPNGGeometry.labelColor)
        let anchor: CGFloat
        switch alignment {
        case .left: anchor = x
        case .center: anchor = x - textWidth / 2
        case .right: anchor = x - textWidth
        }
        drawLine(context, line: line, x: anchor, baselineTopDown: baselineTopDown)
    }

    private static func makeLine(_ text: String, font: CTFont, color: CGColor) -> (CTLine, CGFloat, CGFloat) {
        // CoreText attribute names keep this file free of AppKit/UIKit.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (line, ascent, textWidth)
    }

    private static func drawLine(_ context: CGContext, line: CTLine, x: CGFloat, baselineTopDown: CGFloat) {
        let height = CGFloat(MusicWaveformPNGGeometry.canvasHeight)
        context.saveGState()
        context.setShouldAntialias(true)
        // Unflipped y-up bitmap context: identity textMatrix draws CoreText
        // upright; the baseline sits at the requested top-down row.
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: height - baselineTopDown)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
