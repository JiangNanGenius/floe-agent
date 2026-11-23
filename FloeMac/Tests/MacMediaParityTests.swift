// SPDX-License-Identifier: MPL-2.0

// Focused parity tests for the Mac creative timeline/subtitle/grading lane.
//
// These tests deliberately exercise the SHARED shipping subtitle codec
// (`FloeAgent/FloeApp/Workbench/MediaV2/MediaV2SubtitleCodec.swift`, added
// to the Mac target by the coordinator) through the `MacSubtitleCodec`
// typealias — the parser is never re-implemented here. Everything runs with
// synthetic fixtures (generated pixels, tiny in-memory movies, temp
// directories); no user files, devices or network are touched.
//
// Target membership (coordinator wiring): add this file to a macOS unit-test
// target whose sources also include `Sources/FloeMacUnified/MediaParity/*`,
// `Sources/FloeMacUnified/MacMediaEditing.swift`,
// `Sources/FloeMacUnified/MacCanvasEditor.swift` and the shared
// `../FloeAgent/FloeApp/Workbench/MediaV2/MediaV2SubtitleCodec.swift`.

import AVFoundation
import CoreImage
import XCTest

// Compiled into the same target as the sources (the existing FloeMac
// unit-test convention), so no module import is required: the internal
// parity types are directly visible.

final class MacMediaParityTests: XCTestCase {

    // MARK: - Timeline model

    func testDraftTrackLifecycleAndOrdering() throws {
        var draft = try MacTimelineDraft(name: "Test")
        let visual = try draft.addTrack(.visual)
        let audio = try draft.addTrack(.audio)
        let captions = try draft.addTrack(.caption)
        XCTAssertEqual(draft.tracks.map(\.id), [visual.id, audio.id, captions.id])

        try draft.moveTrack(captions.id, to: 0)
        XCTAssertEqual(draft.tracks.first?.id, captions.id)
        XCTAssertEqual(draft.tracks.last?.id, audio.id)

        try draft.renameTrack(audio.id, name: "Music")
        XCTAssertEqual(draft.track(audio.id)?.name, "Music")

        try draft.removeTrack(visual.id)
        XCTAssertNil(draft.track(visual.id))
        XCTAssertEqual(draft.tracks.count, 2)
    }

    func testClipOverlapRefusedAndMoveAndTrim() throws {
        var draft = try MacTimelineDraft(name: "Clips")
        let track = try draft.addTrack(.visual)
        let url = URL(fileURLWithPath: "/tmp/synthetic.mov")
        let first = try MacTimelineClip.media(sourceURL: url, title: "a",
                                              timelineStart: 0, duration: 4)
        try draft.addClip(first, toTrack: track.id)

        // Overlapping second clip is rejected.
        let overlapping = try MacTimelineClip.media(sourceURL: url, title: "b",
                                                    timelineStart: 2, duration: 4)
        XCTAssertThrowsError(try draft.addClip(overlapping, toTrack: track.id)) {
            XCTAssertEqual($0 as? MacTimelineError, .overlap)
        }
        // Adjacent is allowed.
        let adjacent = try MacTimelineClip.media(sourceURL: url, title: "b",
                                                 timelineStart: 4, duration: 2)
        try draft.addClip(adjacent, toTrack: track.id)
        XCTAssertEqual(draft.totalDurationSeconds, 6, accuracy: 0.001)

        // Moving onto an occupied span is refused, free span accepted.
        XCTAssertThrowsError(try draft.moveClip(trackID: track.id, clipID: adjacent.id, newStart: 1))
        try draft.moveClip(trackID: track.id, clipID: adjacent.id, newStart: 10)
        XCTAssertEqual(draft.track(track.id)?.clip(adjacent.id)?.timelineRange.startSeconds, 10)

        // Trim adjusts source and timeline together.
        try draft.trimClip(trackID: track.id, clipID: first.id,
                           newDuration: 2, newSourceStart: 1)
        let trimmed = try XCTUnwrap(draft.track(track.id)?.clip(first.id))
        XCTAssertEqual(trimmed.timelineRange.durationSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(trimmed.sourceRange.startSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(trimmed.sourceRange.durationSeconds, 2, accuracy: 0.001)
    }

    func testCaptionAndGradeRules() throws {
        var draft = try MacTimelineDraft(name: "Rules")
        let captions = try draft.addTrack(.caption)
        let cue = try MacTimelineClip.caption(timelineStart: 1, duration: 2, text: "你好 world")
        try draft.addClip(cue, toTrack: captions.id)

        // Empty and HTML-ish captions are rejected by the model.
        var broken = cue
        broken.captionText = ""
        XCTAssertThrowsError(try draft.replaceClip(trackID: captions.id, clip: broken))
        var tagged = cue
        tagged.captionText = "<b>nope</b>"
        XCTAssertThrowsError(try draft.replaceClip(trackID: captions.id, clip: tagged))

        // Captions cannot join a visual track (kind rule, not overlap).
        XCTAssertThrowsError(try draft.addClip(cue, toTrack: try draft.addTrack(.visual).id)) {
            XCTAssertEqual($0 as? MacTimelineError, .kindMismatch)
        }

        // Grades only apply to visual clips and must validate.
        let visual = try draft.addTrack(.visual)
        let movie = try MacTimelineClip.media(
            sourceURL: URL(fileURLWithPath: "/tmp/a.mov"), title: "a",
            timelineStart: 0, duration: 3)
        try draft.addClip(movie, toTrack: visual.id)
        let badGrade = MacVideoGrade(toneCurve: [.init(x: 0.5, y: 0.5)])
        XCTAssertThrowsError(try draft.setClipGrade(trackID: visual.id, clipID: movie.id, grade: badGrade))
        let goodGrade = MacVideoGrade(filterID: "CISepiaTone")
        try draft.setClipGrade(trackID: visual.id, clipID: movie.id, grade: goodGrade)
        XCTAssertEqual(draft.track(visual.id)?.clip(movie.id)?.grade?.filterID, "CISepiaTone")
        XCTAssertThrowsError(try draft.setClipGrade(trackID: captions.id, clipID: cue.id, grade: goodGrade)) {
            XCTAssertEqual($0 as? MacTimelineError, .kindMismatch)
        }
    }

    func testDraftCodableRoundtripAndStrictDecoding() throws {
        var draft = try MacTimelineDraft(name: "Roundtrip", canvasWidth: 1280, canvasHeight: 720)
        let visual = try draft.addTrack(.visual)
        try draft.addClip(try MacTimelineClip.media(
            sourceURL: URL(fileURLWithPath: "/tmp/a.mov"), title: "a",
            timelineStart: 0, duration: 2), toTrack: visual.id)
        let captions = try draft.addTrack(.caption)
        try draft.addClip(try MacTimelineClip.caption(timelineStart: 0.5, duration: 1, text: "hello"),
                          toTrack: captions.id)

        // The store writes exact numeric dates (deferredToDate) so a fresh
        // Date() with sub-second components survives the equality check.
        let bytes = try JSONEncoder().encode(draft)
        let restored = try JSONDecoder().decode(MacTimelineDraft.self, from: bytes)
        XCTAssertEqual(restored, draft)
        XCTAssertEqual(restored.totalDurationSeconds, draft.totalDurationSeconds, accuracy: 0.001)
        XCTAssertEqual(restored.createdAt, draft.createdAt)
        XCTAssertEqual(restored.updatedAt, draft.updatedAt)

        // Legacy ISO8601 drafts (older builds) still decode, truncated to
        // whole seconds — the store migration path accepts both formats.
        let isoEncoder = JSONEncoder()
        isoEncoder.dateEncodingStrategy = .iso8601
        let isoBytes = try isoEncoder.encode(draft)
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        let isoRestored = try isoDecoder.decode(MacTimelineDraft.self, from: isoBytes)
        // ISO8601 keeps whole seconds only, so a sub-second fraction is
        // truncated by up to a second in either direction.
        XCTAssertEqual(isoRestored.createdAt.timeIntervalSinceReferenceDate,
                       draft.createdAt.timeIntervalSinceReferenceDate, accuracy: 1.0)

        // Unknown fields are rejected, never silently dropped.
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        object["futureField"] = "mystery"
        let polluted = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MacTimelineDraft.self, from: polluted))
    }

    // MARK: - Shared subtitle codec (MediaV2SubtitleCodec.swift)

    func testSharedSubtitleCodecRoundtrips() throws {
        let srt = """
        1
        00:00:01,500 --> 00:00:03,000
        First line

        2
        00:00:03,250 --> 00:00:04,000
        Second line
        with a second row
        """
        let cues = try MacSubtitleCodec.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].duration, 1.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "Second line\nwith a second row")

        let encoded = try MacSubtitleCodec.encode(cues, format: .srt)
        let reparsed = try MacSubtitleCodec.parse(encoded)
        XCTAssertEqual(reparsed, cues)

        let vtt = try MacSubtitleCodec.encode(cues, format: .vtt)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertEqual(try MacSubtitleCodec.parse(vtt), cues)
    }

    func testSharedSubtitleCodecRejectsUnsupportedContent() {
        // Styling blocks are rejected, not stripped.
        let styled = "STYLE\n::cue { color: red }\n\n1\n00:00:00,000 --> 00:00:01,000\nHi"
        XCTAssertThrowsError(try MacSubtitleCodec.parse(styled)) {
            XCTAssertEqual($0 as? MacSubtitleCodec.Failure, .unsupportedStyle)
        }
        // Cue settings are rejected.
        let positioned = "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000 align:center\nHi"
        XCTAssertThrowsError(try MacSubtitleCodec.parse(positioned)) {
            XCTAssertEqual($0 as? MacSubtitleCodec.Failure, .unsupportedStyle)
        }
        // Malformed timing is rejected.
        let broken = "1\n00:99:00,000 --> 00:00:01,000\nHi"
        XCTAssertThrowsError(try MacSubtitleCodec.parse(broken)) {
            XCTAssertEqual($0 as? MacSubtitleCodec.Failure, .malformed)
        }
    }

    func testDraftImportsSharedCuesAndExportsThem() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\n你好\n\n00:00:03.000 --> 00:00:04.000\nWorld"
        let cues = try MacSubtitleCodec.parse(vtt)
        var draft = try MacTimelineDraft(name: "Subs")
        try draft.importCues(cues, offset: 10)
        let captionTrack = try XCTUnwrap(draft.tracks.first { $0.kind == .caption })
        XCTAssertEqual(captionTrack.clips.count, 2)
        XCTAssertEqual(captionTrack.clips[0].timelineRange.startSeconds, 11, accuracy: 0.001)
        XCTAssertEqual(captionTrack.clips[0].captionText, "你好")

        // Re-import into the same draft appends to the same caption track.
        try draft.importCues(cues)
        XCTAssertEqual(draft.tracks.filter { $0.kind == .caption }.count, 1)

        let exported = draft.captionCues
        XCTAssertEqual(exported.count, 4)
        let encoded = try MacSubtitleCodec.encode(exported, format: .vtt)
        XCTAssertEqual(try MacSubtitleCodec.parse(encoded).count, 4)
    }

    // MARK: - Grading

    func testGradeValidation() {
        // Tone curve needs five ordered points in the unit square.
        XCTAssertThrowsError(try MacVideoGrade(toneCurve: [.init(x: 0.2, y: 0.2)]).validate())
        XCTAssertThrowsError(try MacVideoGrade(toneCurve: [
            .init(x: 0, y: 0), .init(x: 0.5, y: 0.5), .init(x: 0.25, y: 0.25),
            .init(x: 0.75, y: 0.75), .init(x: 1, y: 1)]).validate())
        // Filter/LUT conflict and unsupported filters are rejected.
        XCTAssertThrowsError(try MacVideoGrade(filterID: "CIUnregistered").validate())
        XCTAssertThrowsError(try MacVideoGrade(colorLUT: try Self.identityLUT(),
                                               filterID: "CISepiaTone").validate())
        // Out-of-range balance is rejected.
        var balance = MacColorBalance()
        balance.shadows.red = 2
        XCTAssertThrowsError(try MacVideoGrade(colorBalance: balance).validate())
    }

    func testGradeApplyDeterministicAndEffective() throws {
        let context = CIContext()
        let solid = try Self.solidImage(width: 64, height: 64, r: 0.4, g: 0.6, b: 0.2)

        // Identical grades render identical pixels.
        let grade = MacVideoGrade(filterID: "CISepiaTone")
        let first = try Self.renderedBytes(try grade.apply(to: solid), context: context)
        let second = try Self.renderedBytes(try grade.apply(to: solid), context: context)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)

        // A midtone lift brightens the frame versus the untouched source.
        let lifted = MacVideoGrade(toneCurve: [
            .init(x: 0, y: 0), .init(x: 0.25, y: 0.3), .init(x: 0.5, y: 0.6),
            .init(x: 0.75, y: 0.8), .init(x: 1, y: 1)])
        let sourceBytes = try Self.renderedBytes(solid, context: context)
        let liftedBytes = try Self.renderedBytes(try lifted.apply(to: solid), context: context)
        XCTAssertNotEqual(sourceBytes, liftedBytes)
        // Sum in Int: a UInt8 accumulator traps on overflow.
        XCTAssertGreaterThan(liftedBytes.reduce(0) { $0 + Int($1) },
                             sourceBytes.reduce(0) { $0 + Int($1) })
    }

    func testHSLAndLUTBaking() throws {
        let secondary = MacHSLSecondary(hueCenter: 120, hueWidth: 40, hueShift: -60)
        let cube = try secondary.cubeData()
        XCTAssertEqual(cube.count, 32 * 32 * 32 * 16)

        let lut = try Self.identityLUT()
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(lut.rgba.count, 2 * 2 * 2 * 16)
        // Identity LUT leaves pixels unchanged after the domain matrix.
        let context = CIContext()
        let solid = try Self.solidImage(width: 32, height: 32, r: 0.3, g: 0.5, b: 0.7)
        let graded = try MacVideoGrade(colorLUT: lut).apply(to: solid)
        XCTAssertEqual(try Self.renderedBytes(graded, context: context),
                       try Self.renderedBytes(solid, context: context))
    }

    func testParseCubeRejectsMalformedFiles() {
        XCTAssertThrowsError(try MacColorLUT.parseCube("LUT_3D_SIZE 99"))
        XCTAssertThrowsError(try MacColorLUT.parseCube("LUT_3D_SIZE 2\n1 1"))
        XCTAssertThrowsError(try MacColorLUT.parseCube("not a lut"))
    }

    // MARK: - Composition math (no media required)

    func testFitTransformAspectFillsCanvas() throws {
        // 4:3 source into 16:9 canvas scales to cover and centers.
        let t = MacTimelineCompositionBuilder.fitTransform(
            source: CGSize(width: 400, height: 300),
            preferredTransform: .identity,
            canvas: CGSize(width: 1600, height: 900))
        let mapped = CGRect(x: 0, y: 0, width: 400, height: 300).applying(t)
        XCTAssertEqual(mapped.width, 1600, accuracy: 0.5)
        XCTAssertEqual(mapped.height, 1200, accuracy: 0.5)
        XCTAssertEqual(mapped.midX, 800, accuracy: 0.5)
        XCTAssertEqual(mapped.midY, 450, accuracy: 0.5)

        // 90° preferredTransform swaps the axes and still covers.
        let rotated = MacTimelineCompositionBuilder.fitTransform(
            source: CGSize(width: 400, height: 300),
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 2),
            canvas: CGSize(width: 900, height: 1600))
        let mappedRotated = CGRect(x: 0, y: 0, width: 400, height: 300).applying(rotated)
        XCTAssertGreaterThanOrEqual(mappedRotated.width, 900 - 1)
        XCTAssertGreaterThanOrEqual(mappedRotated.height, 1600 - 1)
        XCTAssertEqual(mappedRotated.midX, 450, accuracy: 1)
        XCTAssertEqual(mappedRotated.midY, 800, accuracy: 1)
    }

    func testCompositionBuildsAndExportsSyntheticMovie() async throws {
        let movie = try await Self.makeSyntheticMovie(seconds: 1.0)
        let info = try await MacTimelineAssetProber.probe(movie)
        XCTAssertTrue(info.isVisualMovie)
        XCTAssertEqual(info.duration, 1.0, accuracy: 0.2)

        var draft = try MacTimelineDraft(name: "Render", canvasWidth: 320, canvasHeight: 240)
        let visual = try draft.addTrack(.visual)
        try draft.addClip(try MacTimelineClip.media(
            sourceURL: movie, title: "clip", timelineStart: 0, duration: info.duration),
            toTrack: visual.id)
        let captions = try draft.addTrack(.caption)
        try draft.addClip(try MacTimelineClip.caption(
            timelineStart: 0.1, duration: 0.5, text: "Hi"), toTrack: captions.id)

        // Plan builds with scene tiling at every boundary.
        let build = try await MacTimelineCompositionBuilder.build(draft: draft, assets: [movie: info])
        XCTAssertEqual(build.duration, draft.totalDurationSeconds, accuracy: 0.001)
        XCTAssertEqual(build.videoComposition.instructions.count, 3)
        // The synthetic fixture is video-only, so no audio mix is built;
        // the signed-app smoke covers the audio path.
        XCTAssertNil(build.audioMix)

        // Real export produces a verified mp4 with matching duration.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await MacTimelineExporter().export(draft: draft, assets: [movie: info], to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let verified = await MacTimelineExporter.verify(destination, expectedDuration: build.duration)
        XCTAssertTrue(verified)
        let exportedAsset = AVURLAsset(url: destination)
        let exportedDuration = try await exportedAsset.load(.duration).seconds
        XCTAssertEqual(exportedDuration, info.duration, accuracy: 0.35)
    }

    func testEmptyTimelineRefusesExport() async throws {
        let draft = try MacTimelineDraft(name: "Empty")
        await XCTAssertThrowsAsyncError({ try await MacTimelineCompositionBuilder.build(draft: draft, assets: [:]) }) {
            XCTAssertEqual($0 as? MacTimelineExportError, .emptyTimeline)
        }
    }

    // MARK: - Draft store

    func testDraftStoreRoundtripAndConflict() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MacTimelineDraftStore(directory: directory)

        var draft = try MacTimelineDraft(name: "Persisted")
        _ = try draft.addTrack(.visual)
        try store.save(draft)
        XCTAssertEqual(try store.load(id: draft.id), draft)
        XCTAssertEqual(try store.loadAll().map(\.id), [draft.id])

        // Revision-guarded save: a stale writer is refused, current is not.
        var edited = draft
        try edited.rename("Persisted v2")
        try store.save(edited, expectedRevision: draft.revision)
        XCTAssertThrowsError(try store.save(draft, expectedRevision: draft.revision)) { _ in }
        XCTAssertEqual(try store.load(id: draft.id).name, "Persisted v2")

        try store.remove(id: draft.id)
        XCTAssertTrue(try store.loadAll().isEmpty)

        // Hand-edited invariant violations (overlap) are rejected on load.
        var hostile = try MacTimelineDraft(name: "Hostile")
        let track = try hostile.addTrack(.visual)
        let url = URL(fileURLWithPath: "/tmp/x.mov")
        let a = try MacTimelineClip.media(sourceURL: url, title: "a", timelineStart: 0, duration: 2)
        try hostile.addClip(a, toTrack: track.id)
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(hostile)) as! [String: Any]
        object["name"] = ""
        let badData = try JSONSerialization.data(withJSONObject: object)
        try badData.write(to: directory.appendingPathComponent(hostile.id.uuidString + ".json"))
        XCTAssertThrowsError(try store.loadAll())
    }

    // MARK: - Fixtures

    private static func identityLUT() throws -> MacColorLUT {
        // 2-sample identity: min and max corners map to themselves.
        let values: [Float] = [
            0, 0, 0, 1,   1, 0, 0, 1,
            0, 1, 0, 1,   1, 1, 0, 1,
            0, 0, 1, 1,   1, 0, 1, 1,
            0, 1, 1, 1,   1, 1, 1, 1,
        ]
        return try MacColorLUT(dimension: 2, rgba: values.withUnsafeBytes { Data($0) })
    }

    private static func solidImage(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) throws -> CIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(red: r, green: g, blue: b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return CIImage(cgImage: cg)
    }

    private static func renderedBytes(_ image: CIImage, context: CIContext) throws -> [UInt8] {
        guard let cg = context.createCGImage(image, from: image.extent) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let width = cg.width, height = cg.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let raw = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        raw.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    /// Writes a tiny, real H.264/AVC movie (solid color frames) through
    /// AVAssetWriter so composition/export tests exercise actual codecs.
    private static func makeSyntheticMovie(seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-movie-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let size = CGSize(width: 320, height: 240)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        let frameCount = max(2, Int(seconds * 30))
        let frameDuration = CMTime(value: 1, timescale: 30)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var pointer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pointer)
            guard let buffer = pointer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<Int(size.height) {
                let line = base!.advanced(by: row * bytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                for column in 0..<Int(size.width) * 4 {
                    line[column] = UInt8((index * 7 + column) % 255)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private func XCTAssertThrowsAsyncError<T>(
        _ expression: () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ verifier: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected asynchronous throw: \(message())", file: file, line: line)
        } catch {
            verifier(error)
        }
    }
}
