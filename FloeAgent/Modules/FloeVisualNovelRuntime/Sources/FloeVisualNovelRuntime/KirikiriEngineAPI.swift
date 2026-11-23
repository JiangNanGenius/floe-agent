// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Swift view of the ShioriKrkr C ABI (`shiorikrkr.h`, API version 4).
///
/// The framework is embedded in the App bundle, loaded with `dlopen` at game
/// start (never at launch: its SDL3 must not bind OpenGLES ahead of
/// MetalANGLE) and resolved through `dlsym`. The config and frame structs are
/// marshalled through explicitly laid-out raw memory so the Swift side never
/// relies on compiler-assumed C layout.
///
/// The engine's debug `eval` entry point is deliberately NOT part of this
/// table: TJS function-literal syntax errors crash the engine process
/// (runtime-qualification finding), so no Floe surface exposes it.
public struct KirikiriEngineAPI: Sendable {
    /// Config buffer offsets, derived from the C header field order
    /// (u32, 4 pointers, u32, pad, fnptr, ptr, fnptr, ptr, i32, pad, ptr).
    enum ConfigLayout {
        static let structSize = 96
        static let structSizeOff = 0
        static let gameRootOff = 8
        static let exeNameOff = 16
        static let cxSchemeOff = 24
        static let argumentsOff = 32
        static let argumentCountOff = 40
        static let logOff = 48
        static let logContextOff = 56
        static let messageOff = 64
        static let messageContextOff = 72
        static let hostPresentsOff = 80
        static let emoteOff = 88
    }

    /// Frame buffer offsets (ptr, 3×i32, pad, u64, 2×i32, ptr, ptr, u64).
    enum FrameLayout {
        static let pixelsOff = 0
        static let widthOff = 8
        static let heightOff = 12
        static let pitchOff = 16
        static let serialOff = 24
        static let blankOff = 32
        static let formatOff = 36
        static let textureOff = 40
        static let eventOff = 48
        static let eventValueOff = 56
        static let size = 64
    }

    public var start: @Sendable (UnsafeRawPointer) -> Int32
    public var tick: @Sendable () -> Int32
    public var canvasSize: @Sendable (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
    public var pointer: @Sendable (Int32, Float, Float, Int32) -> Void
    public var wheel: @Sendable (Float, Float, Float) -> Void
    public var touch: @Sendable (Int32, Float, Float, Int32) -> Void
    public var key: @Sendable (Int32, Int32) -> Void
    public var stop: @Sendable () -> Void
    public var frame: @Sendable (UnsafeMutableRawPointer) -> Int32
    public var cursor: @Sendable (UnsafeMutablePointer<UnsafePointer<UInt8>?>,
                                  UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                  UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                  UnsafeMutablePointer<Int32>) -> UInt32

    public init(start: @escaping @Sendable (UnsafeRawPointer) -> Int32,
                tick: @escaping @Sendable () -> Int32,
                canvasSize: @escaping @Sendable (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void,
                pointer: @escaping @Sendable (Int32, Float, Float, Int32) -> Void,
                wheel: @escaping @Sendable (Float, Float, Float) -> Void,
                touch: @escaping @Sendable (Int32, Float, Float, Int32) -> Void,
                key: @escaping @Sendable (Int32, Int32) -> Void,
                stop: @escaping @Sendable () -> Void,
                frame: @escaping @Sendable (UnsafeMutableRawPointer) -> Int32,
                cursor: @escaping @Sendable (UnsafeMutablePointer<UnsafePointer<UInt8>?>,
                                             UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                             UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                             UnsafeMutablePointer<Int32>) -> UInt32) {
        self.start = start
        self.tick = tick
        self.canvasSize = canvasSize
        self.pointer = pointer
        self.wheel = wheel
        self.touch = touch
        self.key = key
        self.stop = stop
        self.frame = frame
        self.cursor = cursor
    }
}

/// One composed frame from the engine. `texture`/`event`/`eventValue` are a
/// Metal surface produced by the engine; `pixels` is the CPU fallback
/// (RGBA8 or BGRA8 per `isBGRA`). Both are owned by the engine and stay valid
/// only until the next tick.
public struct VisualNovelFrame: @unchecked Sendable {
    public let pixels: UnsafeRawPointer?
    public let width: Int32
    public let height: Int32
    public let pitch: Int32
    public let serial: UInt64
    public let isBlank: Bool
    public let isBGRA: Bool
    public let texture: UnsafeRawPointer?
    public let event: UnsafeRawPointer?
    public let eventValue: UInt64
}

/// Cursor image reported by the game, straight-alpha RGBA, top row first.
public struct KirikiriCursor: @unchecked Sendable {
    public enum Kind: Int32, Sendable {
        case system = 0
        case image = 1
        case hidden = 2
    }
    public let rgba: UnsafePointer<UInt8>?
    public let width: Int32
    public let height: Int32
    public let hotX: Int32
    public let hotY: Int32
    public let kind: Kind
    public let serial: UInt32
}

/// Log sink wired into the engine config. Implemented by the App so lines go
/// to the existing diagnostic store instead of stdout.
public struct KirikiriLogSink: Sendable {
    public var receive: @Sendable (String) -> Void
    public init(receive: @escaping @Sendable (String) -> Void) {
        self.receive = receive
    }
}
