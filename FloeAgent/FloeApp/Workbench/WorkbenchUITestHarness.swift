// FloeApp — DEBUG-only workbench UI fixture harness.
//
// Launch with `-ui-testing --ui-test-workbench-fixture` to open the unified
// workbench on synthetic, self-contained media (no bundled fixtures needed):
// a generated image, a landscape + portrait video pair with different frame
// rates, and a generated music track. Used by the rendered-UI acceptance.
//
// Add `--ui-test-workbench-preview-probe` with the video fixture to play the
// rendered preview proxy and record decoded-frame/playback evidence to
// Documents/workbench-preview-probe.json.
//
// Add `--ui-test-workbench-modal` to present the same fixture through a real
// native sheet. Production Close/Discard/swipe dismissal then run against a
// modal presenter instead of a root view; the underlying DEBUG host stays a
// closed/reopen surface and never re-presents on its own.

#if DEBUG
import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeWorkbench
#if canImport(UIKit)
import UIKit
#endif

struct WorkbenchUITestHarness: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var kind: MediaProjectKind = {
        ProcessInfo.processInfo.arguments.contains("--ui-test-workbench-video") ? .video : .image
    }()
    @State private var fixtures: WorkbenchUIFixtureBuilder.Fixtures?
    @State private var generation = 0
    @State private var showsFixtureSheet = false
    @State private var didAutoPresentModal = false

    private var isModalLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-workbench-modal")
    }

    var body: some View {
        if isModalLaunch {
            // The sheet inherits the harness environment (including the shared
            // AppEnvironment); it is passed explicitly so the production
            // bootstrap always resolves the same workbench center.
            modalHost
                .sheet(isPresented: $showsFixtureSheet) {
                    fixtureContent
                        .environmentObject(environment)
                }
                .overlay(alignment: .top) { fixturePicker }
        } else {
            fixtureContent
                .overlay(alignment: .top) { fixturePicker }
        }
    }

    @ViewBuilder
    private var fixtureContent: some View {
        if let fixtures {
            // Reuses the production bootstrap path so fixture failures
            // show the same actionable error UI as real entrances.
            WorkbenchBootstrapSheet(
                center: environment.workbenchCenter,
                title: "Workbench UI Fixture",
                kind: kind,
                urls: kind == .image ? [fixtures.image]
                                     : [fixtures.landscapeVideo, fixtures.portraitVideo],
                musicURL: kind == .video ? fixtures.music : nil,
                owner: WorkbenchCenter.Owner(kind: .standalone, id: nil, environmentID: nil),
                allowsResume: false)
                .id("\(kind.rawValue)-\(generation)")
                .task(id: kind) {
                    guard kind == .video,
                          ProcessInfo.processInfo.arguments.contains("--ui-test-workbench-preview-probe")
                    else { return }
                    await WorkbenchPreviewProbe.run(center: environment.workbenchCenter)
                }
        } else {
            ProgressView("Preparing workbench fixtures…")
                .task { await loadFixtures() }
        }
    }

    /// DEBUG-only host behind the native sheet. The identifiers stay stable so
    /// acceptance can verify the closed state and reopen the production sheet.
    /// Nothing here re-presents automatically after a production dismiss().
    private var modalHost: some View {
        VStack(spacing: 14) {
            Image(systemName: showsFixtureSheet ? "rectangle.on.rectangle" : "rectangle.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            if showsFixtureSheet {
                Text("Workbench fixture open in a modal sheet")
                    .accessibilityIdentifier("workbench.harness.modal.open")
            } else {
                Text("Workbench fixture closed")
                    .accessibilityIdentifier("workbench.harness.modal.closed")
            }
            Button("Reopen fixture") {
                // A reopen starts a fresh synthetic session rather than
                // reusing the session the production UI just closed.
                generation += 1
                showsFixtureSheet = true
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(showsFixtureSheet || fixtures == nil)
            .accessibilityIdentifier("workbench.harness.modal.reopen")
            if fixtures == nil {
                ProgressView()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadFixtures() }
    }

    private var fixturePicker: some View {
        Picker("Fixture", selection: $kind) {
            Text("Image").tag(MediaProjectKind.image)
            Text("Video").tag(MediaProjectKind.video)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier("workbench.harness.kind")
        .onChange(of: kind) { _, _ in generation += 1 }
    }

    @MainActor
    private func loadFixtures() async {
        guard fixtures == nil else { return }
        let made = await WorkbenchUIFixtureBuilder.makeFixtures()
        guard let made else { return }
        fixtures = made
        guard isModalLaunch, !didAutoPresentModal else { return }
        didAutoPresentModal = true
        showsFixtureSheet = true
    }
}

/// DEBUG-only launch probe that plays the real preview and records the
/// decoded frame/playback evidence on the device/simulator it runs on. The
/// worker uses it to verify that the preview actually renders and advances
/// instead of trusting the project JSON.
enum WorkbenchPreviewProbe {
    @MainActor
    static func run(center: WorkbenchCenter) async {
        var report: [String: Any] = [:]
        // Wait for the bootstrap to render the preview proxy.
        var waited = 0.0
        while center.playerItem == nil, waited < 30 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 0.25
        }
        report["previewError"] = center.previewError ?? ""
        report["isRenderingPreview"] = center.isRenderingPreview
        guard let item = center.playerItem else {
            report["error"] = "no player item"
            write(report)
            return
        }
        report["hasVideoComposition"] = item.videoComposition != nil
        report["itemURL"] = item.asset is AVURLAsset ? (item.asset as? AVURLAsset)?.url.lastPathComponent ?? "" : ""
        var statusWaited = 0.0
        while item.status == .unknown, statusWaited < 15 {
            try? await Task.sleep(for: .milliseconds(200))
            statusWaited += 0.2
        }
        report["itemStatus"] = item.status.rawValue
        if let error = item.error { report["itemError"] = String(describing: error) }
        guard item.status == .readyToPlay else {
            write(report)
            return
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let model = center.playerModel
        model.setItem(item)
        model.togglePlay()
        try? await Task.sleep(for: .seconds(2))
        let time = model.currentTime
        report["playbackAdvanced"] = time > 0.5
        report["currentTime"] = time
        report["isPlaying"] = model.isPlaying
        if let buffer = output.copyPixelBuffer(forItemTime: CMTime(seconds: time, preferredTimescale: 600),
                                               itemTimeForDisplay: nil) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytes = CVPixelBufferGetBytesPerRow(buffer)
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                var total = 0.0, count = 0.0
                for row in stride(from: 0, to: height, by: max(1, height / 16)) {
                    let ptr = base.advanced(by: row * bytes).assumingMemoryBound(to: UInt8.self)
                    for column in stride(from: 0, to: width, by: max(1, width / 16)) {
                        total += Double(ptr[column * 4]) + Double(ptr[column * 4 + 1]) + Double(ptr[column * 4 + 2])
                        count += 3
                    }
                }
                let average = count > 0 ? total / count / 255 : 0
                report["frameAverageColor"] = average
                report["frameNonBlack"] = average > 0.02
            }
        } else {
            report["frameNonBlack"] = false
            report["frameNote"] = "no pixel buffer at current time"
        }
        model.togglePlay()
        write(report)
    }

    private static func write(_ report: [String: Any]) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: documents.appendingPathComponent("workbench-preview-probe.json"), options: .atomic)
    }
}

enum WorkbenchUIFixtureBuilder {
    struct Fixtures {
        var image: URL
        var landscapeVideo: URL
        var portraitVideo: URL
        var music: URL
    }

    static func makeFixtures() async -> Fixtures? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-workbench-ui-fixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("fixture-image.png")
        let landscape = root.appendingPathComponent("fixture-landscape.mp4")
        let portrait = root.appendingPathComponent("fixture-portrait.mp4")
        let music = root.appendingPathComponent("fixture-music.m4a")
        guard let imageData = makeImageData() else { return nil }
        try? imageData.write(to: image, options: .atomic)
        if !FileManager.default.fileExists(atPath: landscape.path) {
            try? await makeMovie(at: landscape, width: 640, height: 360, fps: 24, seconds: 3, hue: 0.6)
        }
        if !FileManager.default.fileExists(atPath: portrait.path) {
            try? await makeMovie(at: portrait, width: 360, height: 640, fps: 30, seconds: 3, hue: 0.1)
        }
        if !FileManager.default.fileExists(atPath: music.path) {
            try? makeTone(at: music, seconds: 5, frequency: 220)
        }
        return Fixtures(image: image, landscapeVideo: landscape, portraitVideo: portrait, music: music)
    }

    static func makeImageData() -> Data? {
        let width = 960, height = 540
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.35, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 120, y: 120, width: 300, height: 300))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 520, y: 160, width: 280, height: 220))
        guard let image = ctx.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func makeMovie(at url: URL, width: Int, height: Int, fps: Int, seconds: Double,
                          hue: CGFloat) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let pixel = buffer else { break }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                let bytes = CVPixelBufferGetBytesPerRow(pixel)
                for row in 0..<height {
                    let ptr = base.advanced(by: row * bytes).assumingMemoryBound(to: UInt32.self)
                    for column in 0..<width {
                        let value = UInt32(hue * 255) << 16 | UInt32((Double(column) / Double(width)) * 200) << 8
                        ptr[column] = 0xFF000000 | value
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            _ = adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    static func makeTone(at url: URL, seconds: Double, frequency: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) {
                samples[index] = Float(sin(Double(index) * frequency * 2 * .pi / 44_100) * 0.25)
            }
        }
        try file.write(from: buffer)
    }
}
#endif
