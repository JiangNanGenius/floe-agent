import BridgeCore
import CoreGraphics
import Foundation
import ImageIO

struct MediaTestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func mediaExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MediaTestFailure("expectation failed: \(message)") }
}

func mediaExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw MediaTestFailure("\(message): expected \(expected), got \(actual)")
    }
}

func mediaExpectGreaterThan<T: Comparable>(_ actual: T, _ threshold: T, _ message: String) throws {
    if !(actual > threshold) {
        throw MediaTestFailure("\(message): expected > \(threshold), got \(actual)")
    }
}

func mediaWaitUntil(timeout: TimeInterval = 12,
                    _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    throw MediaTestFailure("timed out after \(timeout)s waiting for condition")
}

/// Generates deterministic offscreen colour fixtures. No screen, XCTest,
/// device or network is involved. Fixtures live only in this test target.
enum MediaFixtures {
    static func makeScreenFrame(width: Int,
                                height: Int,
                                variant: Int = 0,
                                encoding: BridgeScreenFrame.Encoding = .png) -> BridgeScreenFrame {
        let image = makeImage(width: width, height: height, variant: variant)
        let data = encode(image, encoding: encoding)
        return BridgeScreenFrame(imageData: data,
                                 encoding: encoding,
                                 pixelWidth: width,
                                 pixelHeight: height,
                                 pointWidth: Double(width) / 2,
                                 pointHeight: Double(height) / 2,
                                 capturedAt: Date())
    }

    static func makeImage(width: Int, height: Int, variant: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil,
                                width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: width * 4,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.95, green: 0.15, blue: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let cell = max(8, min(width, height) / 12)
        var row = 0
        var y = 0
        while y < height {
            var column = 0
            var x = 0
            while x < width {
                let red = CGFloat((column * 37 + row * 17 + variant * 53) % 256) / 255
                let green = CGFloat((column * 11 + row * 41 + variant * 29) % 256) / 255
                let blue = CGFloat((column * 23 + row * 7 + variant * 71) % 256) / 255
                context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell
                column += 1
            }
            y += cell
            row += 1
        }
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(4)
        context.stroke(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, encoding: BridgeScreenFrame.Encoding) -> Data {
        let data = NSMutableData()
        let type = encoding == .png ? "public.png" as CFString : "public.jpeg" as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }
}

/// Thread-safe mock provider. It deliberately tracks concurrent captures so a
/// test can prove the service never races two `captureFrame()` calls.
final class MockFrameProvider: BridgeScreenFrameProvider, @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var frames: [BridgeScreenFrame]
    private var index = 0
    private var ready = true
    private var captureDelayNanoseconds: UInt64 = 0
    private var inFlight = 0
    private var maximumInFlight = 0
    private var captureCount = 0

    init(frames: [BridgeScreenFrame]) {
        self.frames = frames
    }

    var frameCaptureReady: Bool {
        lock.withLock { ready }
    }

    func captureFrame() async -> BridgeScreenFrame? {
        lock.lock()
        captureCount += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        let delay = captureDelayNanoseconds
        let isReady = ready
        let frame: BridgeScreenFrame?
        if frames.isEmpty {
            frame = nil
        } else {
            let base = frames[index % frames.count]
            index += 1
            frame = BridgeScreenFrame(imageData: base.imageData,
                                      encoding: base.encoding,
                                      pixelWidth: base.pixelWidth,
                                      pixelHeight: base.pixelHeight,
                                      pointWidth: base.pointWidth,
                                      pointHeight: base.pointHeight,
                                      capturedAt: Date())
        }
        lock.unlock()

        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }

        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
        return isReady ? frame : nil
    }

    func setFrames(_ frames: [BridgeScreenFrame]) {
        lock.withLock {
            self.frames = frames
            self.index = 0
        }
    }

    func setReady(_ value: Bool) {
        lock.withLock { ready = value }
    }

    func setCaptureDelay(milliseconds: Int) {
        lock.withLock {
            captureDelayNanoseconds = UInt64(max(0, milliseconds)) * 1_000_000
        }
    }

    func resetMetrics() {
        lock.withLock {
            captureCount = 0
            maximumInFlight = 0
        }
    }

    var metrics: (captures: Int, maximumInFlight: Int) {
        lock.withLock { (captureCount, maximumInFlight) }
    }
}

/// Drains a bounded stream channel on a background task and records bytes.
final class StreamCollector: @unchecked Sendable {
    private let channel: BridgeRPCStreamChannel
    private let lock = BridgeRPCLock()
    private var buffer = Data()
    private var finished = false
    private var task: Task<Void, Never>?

    init(channel: BridgeRPCStreamChannel) {
        self.channel = channel
    }

    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            for await chunk in self.channel.sequence {
                self.append(chunk)
            }
            self.lock.withLock { self.finished = true }
        }
    }

    private func append(_ chunk: Data) {
        lock.withLock { buffer.append(chunk) }
    }

    var data: Data {
        lock.withLock { buffer }
    }

    var byteCount: Int {
        lock.withLock { buffer.count }
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func waitForBytes(_ count: Int, timeout: TimeInterval = 12) async throws {
        try await mediaWaitUntil(timeout: timeout) { [weak self] in
            (self?.byteCount ?? 0) >= count
        }
    }

    func waitUntilFinished(timeout: TimeInterval = 12) async throws {
        try await mediaWaitUntil(timeout: timeout) { [weak self] in
            self?.isFinished == true
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

func mediaArtifactDirectory() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["MEDIA_ARTIFACT_DIR"],
          !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
