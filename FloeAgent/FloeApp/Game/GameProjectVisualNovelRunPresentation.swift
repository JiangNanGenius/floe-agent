// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import CoreImage
import FloeCore
import FloeGameIDEBridge
import FloeGameWebKit
import FloeVisualNovelRuntime
import Metal
import Observation
import SwiftUI
import Synchronization

/// The project's owned native run, shared by the workspace, IDE and tools.
@MainActor @Observable
final class GameProjectVisualNovelRunPresentation {
    let request: GameIDEProjectRunRequest
    let view: VisualNovelGameView
    private let game: any VisualNovelGameSession
    private final class Logs: Sendable {
        let lines = Mutex<[String]>([])
    }

    private let logsBuffer: Logs
    private static var activeRequest: UUID?
    private(set) var isRunning = true
    private var sendingKeys = false

    init(request: GameIDEProjectRunRequest, sandbox: KirikiriSandbox) throws {
        guard Self.activeRequest == nil else {
            throw FloeError.validationFailed(IDELanguageRunText.t(
                "请先关闭正在运行的吉里吉里游戏。", "Close the running KiriKiri game first."))
        }
        let buffer = Logs()
        // The runtime has one process-global interpreter. Only this request
        // can drive it or release it after a later launch attempt.
        let game = try KirikiriGameSession(api: KirikiriEngineLoader.load(), sandbox: sandbox,
            logSink: .init(receive: { line in
                buffer.lines.withLock {
                    $0.append(String(line.prefix(2048)))
                    if $0.count > 200 { $0.removeFirst($0.count - 200) }
                }
            }))
        guard let view = VisualNovelGameView(session: game) else {
            throw FloeError.validationFailed(IDELanguageRunText.t(
                "无法创建吉里吉里的游戏画面。", "KiriKiri could not create its display."))
        }
        self.request = request
        self.view = view
        self.game = game
        logsBuffer = buffer
        try game.start()
        Self.activeRequest = request.id
        view.onGameFinished = { [weak self] in self?.stop() }
        view.startDisplay()
    }

    func stop() {
        guard isRunning, Self.activeRequest == request.id else { return }
        view.stopDisplay()
        game.stop()
        Self.activeRequest = nil
        isRunning = false
    }

    var logs: String { logsBuffer.lines.withLock { $0.joined(separator: "\n") } }

    func sendKeys(_ keys: [GameKeyboardKey], durationMilliseconds: Int) async throws {
        guard isRunning else { throw GameWorkspaceRegistryError.noSavedRun }
        guard !sendingKeys else { throw GameWorkspaceRegistryError.editorBusy }
        sendingKeys = true
        var seen = Set<Int32>()
        let virtualKeys = keys.map { Int32($0.descriptor.keyCode) }.filter { seen.insert($0).inserted }
        virtualKeys.forEach { game.key(virtualKey: $0, down: true) }
        defer {
            if isRunning { virtualKeys.reversed().forEach { game.key(virtualKey: $0, down: false) } }
            sendingKeys = false
        }
        try await Task.sleep(for: .milliseconds(min(1_000, max(30, durationMilliseconds))))
        guard isRunning else { throw GameIDEBridgeError.superseded }
    }

    func screenshot() throws -> Data {
        guard isRunning, let frame = game.currentFrame(), !frame.isBlank,
              let image = Self.capture(frame), let bytes = UIImage(cgImage: image).pngData() else {
            throw FloeError.validationFailed(IDELanguageRunText.t(
                "游戏画面还未就绪，请稍后截图。", "Wait for the game frame, then retry the screenshot."))
        }
        return bytes
    }

    private static func capture(_ frame: VisualNovelFrame) -> CGImage? {
        if let address = frame.texture {
            let texture = Unmanaged<MTLTexture>.fromOpaque(address).takeUnretainedValue()
            if let eventAddress = frame.event {
                let event = Unmanaged<MTLSharedEvent>.fromOpaque(eventAddress).takeUnretainedValue()
                guard event.wait(untilSignaledValue: frame.eventValue, timeoutMS: 100) else { return nil }
            }
            guard let input = CIImage(mtlTexture: texture, options: nil) else { return nil }
            return CIContext(mtlDevice: texture.device).createCGImage(input, from: input.extent)
        }
        let width = Int(frame.width), height = Int(frame.height), pitch = Int(frame.pitch)
        guard let pixels = frame.pixels, width > 0, height > 0, pitch >= width * 4,
              pitch <= (64 * 1024 * 1024) / height else { return nil }
        let info: CGBitmapInfo = frame.isBGRA
            ? [.byteOrder32Little, .init(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
            : [.byteOrder32Big, .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)]
        guard let provider = CGDataProvider(data: Data(bytes: pixels, count: pitch * height) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: pitch, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct GameVisualNovelViewport: UIViewRepresentable {
    let presentation: GameProjectVisualNovelRunPresentation

    func makeUIView(context: Context) -> VisualNovelGameView { presentation.view }
    func updateUIView(_ view: VisualNovelGameView, context: Context) {}
}
#endif
