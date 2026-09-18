// Build191 media-review — GIF disposal/timing/bounds/atomic-cancellation
// fixture.
//
// Compiled directly with the edited FloeMedia source (no stale modules). The
// embedded GIF is a raw 354-byte GIF89a: frame 0 is a full red canvas
// (disposal=1), frame 1 is a partial 16x16 blue rectangle, so a decoder that
// ignores disposal/compositing would lose the red background on frame 1.

import Foundation
import ImageIO
import CoreGraphics
import AVFoundation

@main
@MainActor
struct ReviewGIFTests {
    static var failures: [String] = []
    static var checks = 0

    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures.append(label) }
    }

    static func main() async {
        do {
            try await run()
        } catch {
            failures.append("unexpected error: \(error)")
        }
        if failures.isEmpty {
            print("REVIEW-GIF: PASS (\(checks) checks)")
        } else {
            print("REVIEW-GIF: FAIL (\(failures.count)/\(checks))")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
    }

    static let disposalGIFBase64 = "R0lGODlhQABAAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQECgAAACwAAAAAQABAAAAIaQABCBxIsKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPHjyBDihxJsqTJkyhTqlzJsqXLlzBjypxJs6bNmzhz6tzJs6fPn0CDCh1KtKjRo0iTKl3KtKnTp1CjSp1KtarVq1izagUQEAAh+QQFCgAAACwAAAAAQABAAIEAAAAAAP8AAAAAAAAIlgADCBxIsGAAAAgTKlzIsKHDhwkNShwIsaLFiwgnTsTIsWNEjQY9irwIMuTIkw5LFkTJcqFKgi1jAnhJUSZLmgJt3sSpEyXOgz1H/gwqlCdRj0OPdkyqFCPTplCjSp1KtarVq1izat3KtavXr2DDih1LtqzZs2jTql3Ltq3bt3Djyp1Lt67du3jz6t3Lt6/fv4ADC84bEAA7"

    static func makeSolidImage(_ color: (r: CGFloat, g: CGFloat, b: CGFloat), side: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// Builds a timed GIF through ImageIO.
    static func writeTimedGIF(url: URL, delays: [Double]) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "com.compuserve.gif" as CFString, delays.count, nil
        ) else { throw NSError(domain: "fixture", code: 1) }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
        for (index, delay) in delays.enumerated() {
            guard let image = makeSolidImage(colors[index % colors.count], side: 64) else {
                throw NSError(domain: "fixture", code: 2)
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "fixture", code: 3)
        }
    }

    /// Raw pixel at (x, y) with y measured from the top row of the bitmap.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int, Int) {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let offset = (y * width + x) * 4
        return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]), Int(buffer[offset + 3]))
    }

    static func frame(of url: URL, at seconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-review-gif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        guard let disposalData = Data(base64Encoded: disposalGIFBase64) else {
            check(false, "embedded GIF decodes")
            return
        }
        let disposalURL = directory.appendingPathComponent("disposal.gif")
        try disposalData.write(to: disposalURL)

        // MARK: probe
        let info = try GIFSupport.probe(fileURL: disposalURL)
        check(info.frameCount == 2, "disposal GIF has 2 frames, got \(info.frameCount)")
        check(info.isAnimated, "disposal GIF is animated")
        check(info.width == 64 && info.height == 64, "disposal GIF dimensions")
        check(info.loopCount == 0, "disposal GIF loop count 0 (infinite)")
        check(abs(info.totalDurationSeconds - 0.2) < 0.05,
              "disposal GIF total duration ~0.2s, got \(info.totalDurationSeconds)")
        check(info.frameDelaysSeconds.count == 2
                && info.frameDelaysSeconds.allSatisfy { abs($0 - 0.1) < 0.02 },
              "per-frame delays preserved as 0.1s")

        // MARK: disposal compositing survives into the video
        let mp4URL = directory.appendingPathComponent("disposal.mp4")
        let converted = try await GIFSupport.convertToVideo(
            fileURL: disposalURL, outputURL: mp4URL, frameRate: 10
        )
        check(converted.preservedOriginalTiming == false, "requested frame rate is a resample")
        check(FileManager.default.fileExists(atPath: mp4URL.path), "converted video written")
        // Frame 1 (100–200ms) must be the composited frame: red background with
        // the blue square, not a lost/black background.
        let composite = try await frame(of: mp4URL, at: 0.15)
        let background = pixel(composite, x: 48, y: 48)
        let square = pixel(composite, x: 8, y: 8)
        check(background.0 > 180 && background.1 < 80 && background.2 < 80,
              "frame 1 keeps the red background (got \(background))")
        check(square.2 > 180 && square.0 < 80,
              "frame 1 draws the blue square (got \(square))")

        // MARK: timing preservation with a nil frame rate
        let timedURL = directory.appendingPathComponent("timed.gif")
        try writeTimedGIF(url: timedURL, delays: [0.3, 0.1, 0.2])
        let timedInfo = try GIFSupport.probe(fileURL: timedURL)
        check(timedInfo.frameCount == 3, "3-frame GIF written by ImageIO")
        let timedOut = directory.appendingPathComponent("timed.mp4")
        let timedResult = try await GIFSupport.convertToVideo(
            fileURL: timedURL, outputURL: timedOut, frameRate: nil
        )
        check(timedResult.preservedOriginalTiming, "nil frame rate preserves original timing")
        check(abs(timedResult.durationSeconds - 0.6) < 0.05,
              "preserved duration ~0.6s, got \(timedResult.durationSeconds)")
        let trackDuration = try await AVURLAsset(url: timedOut).load(.duration).seconds
        check(abs(trackDuration - 0.6) < 0.1, "written track duration ~0.6s, got \(trackDuration)")

        // MARK: atomic cancellation
        let cancelURL = directory.appendingPathComponent("cancelled.mp4")
        var cancelled = false
        do {
            _ = try await GIFSupport.convertToVideo(
                fileURL: timedURL, outputURL: cancelURL,
                cancellation: { true }
            )
        } catch GIFSupportError.cancelled {
            cancelled = true
        }
        check(cancelled, "cancellation throws GIFSupportError.cancelled")
        check(!FileManager.default.fileExists(atPath: cancelURL.path), "cancelled output is not published")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".floe-gif-") }
        check(leftovers.isEmpty, "cancelled conversion leaves no staging file")

        // MARK: bounds
        checkThrows("frame limit enforced") {
            _ = try GIFSupport.probe(fileURL: disposalURL, maximumFrames: 1)
        }
        await checkThrowsAsync("duration limit enforced") {
            _ = try await GIFSupport.convertToVideo(
                fileURL: timedURL, outputURL: directory.appendingPathComponent("nope.mp4"),
                maximumDurationSeconds: 0.1
            )
        }
        await checkThrowsAsync("invalid frame rate rejected") {
            _ = try await GIFSupport.convertToVideo(
                fileURL: timedURL, outputURL: directory.appendingPathComponent("nope2.mp4"),
                frameRate: 0
            )
        }
        let scaled = try GIFSupport.targetDimensions(
            sourceWidth: 1920, sourceHeight: 1080, requestedWidth: 5000, maximumDimension: 1280
        )
        check(scaled.width <= 1280 && scaled.height <= 1280 && scaled.width % 2 == 0 && scaled.height % 2 == 0,
              "dimension scaling stays bounded and even (got \(scaled))")

        // MARK: single-frame GIF is not converted
        let singleURL = directory.appendingPathComponent("single.gif")
        guard let single = makeSolidImage((0.2, 0.2, 0.2), side: 32),
              let singleDestination = CGImageDestinationCreateWithURL(
                  singleURL as CFURL, "com.compuserve.gif" as CFString, 1, nil
              ) else {
            check(false, "single-frame fixture created")
            return
        }
        CGImageDestinationAddImage(singleDestination, single, nil)
        _ = CGImageDestinationFinalize(singleDestination)
        await checkThrowsAsync("single-frame GIF rejected") {
            _ = try await GIFSupport.convertToVideo(
                fileURL: singleURL, outputURL: directory.appendingPathComponent("single.mp4")
            )
        }
    }

    static func checkThrows<T>(_ label: String, _ body: () throws -> T) {
        do {
            _ = try body()
            failures.append("\(label): expected an error")
            checks += 1
        } catch {
            check(true, label)
        }
    }

    static func checkThrowsAsync<T>(_ label: String, _ body: () async throws -> T) async {
        do {
            _ = try await body()
            failures.append("\(label): expected an error")
            checks += 1
        } catch {
            check(true, label)
        }
    }
}
