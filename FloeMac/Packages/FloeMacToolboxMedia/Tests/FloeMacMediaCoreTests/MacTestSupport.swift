import Foundation
import CoreGraphics
import CoreText
import FloeMacMediaCore
import FloeToolboxUtilities

// MARK: - Deterministic authorizers

final class MacDeferredAuthorizer: MacMediaAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MacMediaAuthorization, Never>?
    private var requests = 0
    private let status: MacMediaAuthorization

    init(status: MacMediaAuthorization = .notDetermined) {
        self.status = status
    }

    func authorization(for kind: MacMediaKind) -> MacMediaAuthorization { status }

    func requestAuthorization(for kind: MacMediaKind) async -> MacMediaAuthorization {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            requests += 1
            lock.unlock()
        }
    }

    var hasPendingRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func resume(_ value: MacMediaAuthorization) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

// MARK: - Fake audio source

final class MacFakeAudioSource: MacAudioInputSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reader: (@Sendable (MacSoundReading) -> Void)?
    private var failer: (@Sendable (MacMediaFailure) -> Void)?
    private var starts = 0
    private var stops = 0
    var startError: MacMediaFailure?
    var stopConfirmed: Bool { lock.withLock { stops > 0 } }

    func start(
        onReading: @escaping @Sendable (MacSoundReading) -> Void,
        onFailure: @escaping @Sendable (MacMediaFailure) -> Void
    ) throws {
        lock.lock()
        starts += 1
        if let startError {
            lock.unlock()
            throw startError
        }
        reader = onReading
        failer = onFailure
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stops += 1
        reader = nil
        failer = nil
        lock.unlock()
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func emit(_ reading: MacSoundReading) {
        lock.lock()
        let reader = self.reader
        lock.unlock()
        reader?(reading)
    }

    func fail(_ failure: MacMediaFailure) {
        lock.lock()
        let failer = self.failer
        lock.unlock()
        failer?(failure)
    }
}

final class MacFakeAudioProvider: MacAudioInputProviding, @unchecked Sendable {
    let source = MacFakeAudioSource()
    var available = true
    var makeError: MacMediaFailure?

    func inputAvailable() -> Bool { available }

    func makeSource() throws -> any MacAudioInputSource {
        if let makeError { throw makeError }
        return source
    }
}

// MARK: - Fixtures

enum MacTestFixtures {
    static func reading(
        level: Double = -20,
        peak: Double = -10,
        frequency: Double? = 440,
        append: Bool
    ) -> MacSoundReading {
        MacSoundReading(
            levelDBFS: level,
            peakDBFS: peak,
            dominantFrequency: frequency,
            spectrum: MacSoundSpectrum(bands: [0.5], bandFrequencies: [frequency ?? 0]),
            appendToHistory: append
        )
    }

    /// Deterministic sine frame used by the analysis test.
    static func sine(frequency: Double, sampleRate: Double, frameCount: Int, amplitude: Float) -> [Float] {
        (0..<frameCount).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    static func colorImage(width: Int, height: Int, gray: CGFloat = 0.5) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Renders one line of large black text on white for on-device OCR.
    static func textImage(_ text: String, width: Int = 1_000, height: Int = 320) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 108, nil)
        // Use CoreText keys directly: the AppKit .font/.foregroundColor keys
        // expect NSFont/NSColor and can be ignored by CTLineDraw.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        context.textPosition = CGPoint(x: 40, y: 110)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    static func pngData(for image: CGImage) throws -> Data {
        try OpticsScanExport.png(image)
    }

    /// Task-exclusive test root. Never uses the system temporary directory:
    /// every byte stays under the candidate package inside the authorized
    /// `Local/Scratch/mac-toolbox-device-20261117` scope. Tests remove their own
    /// directory; the coordinator can remove `.test-tmp` after a run.
    static func makeTempDirectory() throws -> URL {
        // Derive the package root from this source file, not the process CWD, so
        // the test root is always inside the authorized task directory.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FloeMacMediaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // candidate
        let root = packageRoot.appendingPathComponent(".test-tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    @MainActor
    static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
