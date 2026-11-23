// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Owns one live Kirikiri game on the main thread.
///
/// Threading contract (from the engine header): every call happens on the
/// thread that called `start`, which is the main thread in the App. The view
/// drives `tick()` from a display link; input is forwarded as normalized
/// engine-view coordinates.
@MainActor
public final class KirikiriGameSession: VisualNovelGameSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case running
        /// The game quit on its own (`tick` returned 0).
        case finished
        case failed(String)
    }

    private let api: KirikiriEngineAPI
    private let sandbox: KirikiriSandbox
    private let exeName: String?
    private let logSink: KirikiriLogSink
    /// Retains C strings and the log trampoline for the engine's lifetime.
    private var configStorage: ConfigStorage?
    private var didStop = false
    private nonisolated(unsafe) var frameBuffer: UnsafeMutableRawPointer
    public private(set) var phase: Phase = .idle

    private var isLive: Bool {
        switch phase {
        case .running, .finished: return true
        case .idle, .failed: return false
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    public init(api: KirikiriEngineAPI,
                sandbox: KirikiriSandbox,
                exeName: String? = nil,
                logSink: KirikiriLogSink = .init(receive: { _ in })) {
        self.api = api
        self.sandbox = sandbox
        self.exeName = exeName
        self.logSink = logSink
        self.frameBuffer = .allocate(byteCount: KirikiriEngineAPI.FrameLayout.size, alignment: 8)
    }

    deinit {
        frameBuffer.deallocate()
    }

    /// Persistent per-game save directory the engine writes through
    /// `gameRoot/savedata`.
    public nonisolated var savesDirectory: URL { sandbox.savesDirectory }

    /// Starts the engine and runs startup scripts up to the first wait.
    public func start() throws {
        guard phase == .idle else {
            throw VisualNovelRuntimeError.invalidSessionState("start requires an idle session")
        }
        let storage = ConfigStorage(gameRoot: sandbox.gameRoot.path,
                                    exeName: exeName ?? "game.exe",
                                    logSink: logSink)
        configStorage = storage
        let status = storage.withConfigPointer { config in
            api.start(config)
        }
        guard status == 0 else {
            phase = .failed("shiorikrkr_start failed with code \(status)")
            throw VisualNovelRuntimeError.engineStartFailed(status)
        }
        phase = .running
    }

    /// Advances one frame. Returns false once the game has quit; the session
    /// then moves to `.finished` and accepts no further input.
    @discardableResult
    public func tick() -> Bool {
        guard phase == .running else { return false }
        let running = api.tick() != 0
        if !running { phase = .finished }
        return running
    }

    /// The latest composed frame, valid until the next `tick`.
    public func currentFrame() -> VisualNovelFrame? {
        guard phase == .running || phase == .finished else { return nil }
        let hasFrame = api.frame(frameBuffer) != 0
        guard hasFrame else { return nil }
        let buffer = frameBuffer
        func load<T>(_ offset: Int, _ type: T.Type) -> T {
            buffer.load(fromByteOffset: offset, as: type)
        }
        return VisualNovelFrame(
            pixels: load(KirikiriEngineAPI.FrameLayout.pixelsOff, UnsafeRawPointer?.self),
            width: load(KirikiriEngineAPI.FrameLayout.widthOff, Int32.self),
            height: load(KirikiriEngineAPI.FrameLayout.heightOff, Int32.self),
            pitch: load(KirikiriEngineAPI.FrameLayout.pitchOff, Int32.self),
            serial: load(KirikiriEngineAPI.FrameLayout.serialOff, UInt64.self),
            isBlank: load(KirikiriEngineAPI.FrameLayout.blankOff, Int32.self) != 0,
            isBGRA: load(KirikiriEngineAPI.FrameLayout.formatOff, Int32.self)
                == 1 /* SHIORIKRKR_FRAME_BGRA */,
            texture: load(KirikiriEngineAPI.FrameLayout.textureOff, UnsafeRawPointer?.self),
            event: load(KirikiriEngineAPI.FrameLayout.eventOff, UnsafeRawPointer?.self),
            eventValue: load(KirikiriEngineAPI.FrameLayout.eventValueOff, UInt64.self))
    }

    public func canvasSize() -> (width: Int32, height: Int32) {
        var width: Int32 = 0, height: Int32 = 0
        withUnsafeMutablePointers(&width, &height) { w, h in
            api.canvasSize(w, h)
        }
        return (width, height)
    }

    public func currentCursor() -> KirikiriCursor? {
        guard phase == .running || phase == .finished else { return nil }
        var rgba: UnsafePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0, hotX: Int32 = 0, hotY: Int32 = 0, kind: Int32 = 0
        let serial = withUnsafeMutablePointers(&rgba, &width, &height, &hotX, &hotY, &kind) {
            api.cursor($0, $1, $2, $3, $4, $5)
        }
        return KirikiriCursor(rgba: rgba, width: width, height: height,
                              hotX: hotX, hotY: hotY,
                              kind: KirikiriCursor.Kind(rawValue: kind) ?? .system,
                              serial: serial)
    }

    // MARK: - Input (normalized 0...1 engine-view coordinates)

    public func pointerDown(x: Float, y: Float, button: Int32 = 0) {
        guard phase == .running else { return }
        api.pointer(0, x, y, button)
    }

    public func pointerMoved(x: Float, y: Float, button: Int32 = 0) {
        guard phase == .running else { return }
        api.pointer(1, x, y, button)
    }

    public func pointerUp(x: Float, y: Float, button: Int32 = 0) {
        guard phase == .running else { return }
        api.pointer(2, x, y, button)
    }

    public func pointerCancelled(x: Float, y: Float, button: Int32 = 0) {
        guard phase == .running else { return }
        api.pointer(3, x, y, button)
    }

    /// Two-finger tap as a right click (KAG's menu).
    public func rightClick(x: Float, y: Float) {
        guard phase == .running else { return }
        api.pointer(0, x, y, 1)
        api.pointer(2, x, y, 1)
    }

    public func wheel(dy: Float, x: Float, y: Float) {
        guard phase == .running else { return }
        api.wheel(dy, x, y)
    }

    public func touch(phase: Int32, x: Float, y: Float, id: Int32) {
        guard self.phase == .running else { return }
        api.touch(phase, x, y, id)
    }

    public func key(virtualKey: Int32, down: Bool) {
        guard phase == .running else { return }
        api.key(virtualKey, down ? 1 : 0)
    }

    /// Ends the game (exit handlers + audio) and disposes the run sandbox.
    /// The save directory persists for the next run.
    public func stop() {
        guard isLive, !didStop else { return }
        didStop = true
        api.stop()
        configStorage = nil
        try? sandbox.dispose()
        if !isFailed {
            phase = .finished
        }
    }
}

/// C-side lifetime for the config block: owns the raw buffer, the C strings
/// and the log trampoline box while the engine may reference them.
private final class ConfigStorage {
    let buffer: UnsafeMutableRawPointer
    private let gameRootCString: UnsafeMutablePointer<CChar>
    private let exeNameCString: UnsafeMutablePointer<CChar>
    private let logBox: Unmanaged<LogBox>

    init(gameRoot: String, exeName: String, logSink: KirikiriLogSink) {
        let layout = KirikiriEngineAPI.ConfigLayout.self
        buffer = .allocate(byteCount: layout.structSize, alignment: 8)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: layout.structSize)
        gameRootCString = strdup(gameRoot)!
        exeNameCString = strdup(exeName)!
        logBox = Unmanaged.passRetained(LogBox(sink: logSink))
        buffer.storeBytes(of: UInt32(layout.structSize), toByteOffset: layout.structSizeOff, as: UInt32.self)
        buffer.storeBytes(of: gameRootCString, toByteOffset: layout.gameRootOff, as: UnsafeMutablePointer<CChar>.self)
        buffer.storeBytes(of: exeNameCString, toByteOffset: layout.exeNameOff, as: UnsafeMutablePointer<CChar>.self)
        // cx_scheme_path / arguments stay zero (nil).
        buffer.storeBytes(of: logTrampoline, toByteOffset: layout.logOff, as: LogTrampoline.self)
        buffer.storeBytes(of: logBox.toOpaque(), toByteOffset: layout.logContextOff, as: UnsafeMutableRawPointer.self)
        // message stays nil: the engine auto-answers with the first button.
        buffer.storeBytes(of: Int32(1), toByteOffset: layout.hostPresentsOff, as: Int32.self)
        // emote stays nil: E-mote characters need the optional host player.
    }

    func withConfigPointer<T>(_ body: (UnsafeRawPointer) throws -> T) rethrows -> T {
        try body(UnsafeRawPointer(buffer))
    }

    deinit {
        logBox.release()
        free(gameRootCString)
        free(exeNameCString)
        buffer.deallocate()
    }
}

private typealias LogTrampoline = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

/// Global C trampoline: the engine log callback forwards to the App sink.
/// A global function (no captures) keeps the function pointer stable.
private let logTrampoline: LogTrampoline = { context, line in
    guard let context, let line else { return }
    let box = Unmanaged<LogBox>.fromOpaque(context).takeUnretainedValue()
    box.sink.receive(String(cString: line))
}

private final class LogBox {
    let sink: KirikiriLogSink
    init(sink: KirikiriLogSink) { self.sink = sink }
}

/// Small helper for multiple inout pointers without nested closures.
private func withUnsafeMutablePointers<A, B, T>(_ a: inout A, _ b: inout B,
                                                _ body: (UnsafeMutablePointer<A>, UnsafeMutablePointer<B>) -> T) -> T {
    withUnsafeMutablePointer(to: &a) { pa in
        withUnsafeMutablePointer(to: &b) { pb in body(pa, pb) }
    }
}

private func withUnsafeMutablePointers<A, B, C, D, E, F, T>(
    _ a: inout A, _ b: inout B, _ c: inout C, _ d: inout D, _ e: inout E, _ f: inout F,
    _ body: (UnsafeMutablePointer<A>, UnsafeMutablePointer<B>, UnsafeMutablePointer<C>,
             UnsafeMutablePointer<D>, UnsafeMutablePointer<E>, UnsafeMutablePointer<F>) -> T) -> T {
    withUnsafeMutablePointer(to: &a) { pa in
        withUnsafeMutablePointer(to: &b) { pb in
            withUnsafeMutablePointer(to: &c) { pc in
                withUnsafeMutablePointer(to: &d) { pd in
                    withUnsafeMutablePointer(to: &e) { pe in
                        withUnsafeMutablePointer(to: &f) { pf in body(pa, pb, pc, pd, pe, pf) }
                    }
                }
            }
        }
    }
}
