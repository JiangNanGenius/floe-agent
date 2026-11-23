// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Loads the embedded ShioriKrkr framework once per process and resolves the
/// bounded engine surface. Mirrors `shiorikrkr_loader.h` in Swift: the App
/// embeds the framework without linking (SDL3/OpenGLES ordering), so symbols
/// are resolved with `dlopen`/`dlsym` at game-start time.
public enum KirikiriEngineLoader {
    /// Expected framework name inside the App bundle's Frameworks directory.
    public static let frameworkName = "ShioriKrkr.framework"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: KirikiriEngineAPI?

    /// Resolves the framework binary inside a bundle (the App bundle in
    /// production; tests pass any bundle containing the framework).
    public static func frameworkBinary(in bundle: Bundle) -> URL? {
        bundle.privateFrameworksURL?
            .appendingPathComponent(frameworkName, isDirectory: true)
            .appendingPathComponent("ShioriKrkr")
    }

    /// Returns the process-wide engine table, loading it on first use.
    /// Concurrent callers share one dlopen handle. A failure is reported once
    /// per process and never cached as success.
    public static func load(bundle: Bundle = .main) throws -> KirikiriEngineAPI {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let binary = frameworkBinary(in: bundle) else {
            throw VisualNovelRuntimeError.engineUnavailable(
                "\(Self.frameworkName) is not embedded in \(bundle.bundlePath)")
        }
        let path = binary.path
        let handle = path.withCString { cPath -> UnsafeMutableRawPointer? in
            dlopen(cPath, RTLD_NOW | RTLD_LOCAL)
        }
        guard let handle else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw VisualNovelRuntimeError.engineUnavailable(reason)
        }
        defer { if cached == nil { dlclose(handle) } }
        func resolve<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let symbol = dlsym(handle, name) else {
                throw VisualNovelRuntimeError.engineInterfaceMissing(name)
            }
            return unsafeBitCast(symbol, to: type)
        }
        typealias StartFn = @convention(c) (UnsafeRawPointer) -> Int32
        typealias TickFn = @convention(c) () -> Int32
        typealias CanvasFn = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
        typealias PointerFn = @convention(c) (Int32, Float, Float, Int32) -> Void
        typealias WheelFn = @convention(c) (Float, Float, Float) -> Void
        typealias TouchFn = @convention(c) (Int32, Float, Float, Int32) -> Void
        typealias KeyFn = @convention(c) (Int32, Int32) -> Void
        typealias StopFn = @convention(c) () -> Void
        typealias FrameFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
        typealias CursorFn = @convention(c) (UnsafeMutablePointer<UnsafePointer<UInt8>?>,
                                             UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                             UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                             UnsafeMutablePointer<Int32>) -> UInt32

        let start: StartFn = try resolve("shiorikrkr_start", StartFn.self)
        let tick: TickFn = try resolve("shiorikrkr_tick", TickFn.self)
        let canvas: CanvasFn = try resolve("shiorikrkr_canvas_size", CanvasFn.self)
        let pointer: PointerFn = try resolve("shiorikrkr_pointer", PointerFn.self)
        let wheel: WheelFn = try resolve("shiorikrkr_wheel", WheelFn.self)
        let touch: TouchFn = try resolve("shiorikrkr_touch", TouchFn.self)
        let key: KeyFn = try resolve("shiorikrkr_key", KeyFn.self)
        let stop: StopFn = try resolve("shiorikrkr_stop", StopFn.self)
        let frame: FrameFn = try resolve("shiorikrkr_frame", FrameFn.self)
        let cursor: CursorFn = try resolve("shiorikrkr_cursor", CursorFn.self)

        // Deliberately unresolved: shiorikrkr_eval (process-crash risk on
        // function-literal syntax errors) and shiorikrkr_capture (test-only
        // BMP writer that escapes the sandbox whitelist model).
        let api = KirikiriEngineAPI(
            start: { start($0) },
            tick: { tick() },
            canvasSize: { canvas($0, $1) },
            pointer: { pointer($0, $1, $2, $3) },
            wheel: { wheel($0, $1, $2) },
            touch: { touch($0, $1, $2, $3) },
            key: { key($0, $1) },
            stop: { stop() },
            frame: { frame($0) },
            cursor: { cursor($0, $1, $2, $3, $4, $5) })
        cached = api
        return api
    }

}
