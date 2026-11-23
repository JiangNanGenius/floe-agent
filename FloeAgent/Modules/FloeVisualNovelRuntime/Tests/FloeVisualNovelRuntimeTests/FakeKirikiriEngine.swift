// SPDX-License-Identifier: MPL-2.0
import Foundation
@testable import FloeVisualNovelRuntime

/// Scripted engine used to verify the session lifecycle without the real
/// ShioriKrkr binary (the iOS slices cannot load on macOS). The session is
/// main-actor isolated, so the recorded state is effectively single-threaded.
final class FakeKirikiriEngine: @unchecked Sendable {
    struct RecordedCall: Equatable {
        enum Kind: Equatable {
            case start(gameRoot: String)
            case tick
            case stop
            case pointer(Int32, Float, Float, Int32)
            case key(Int32, Int32)
        }
        let kind: Kind
    }

    private(set) var calls: [RecordedCall] = []
    var tickResults: [Int32] = []
    private var tickIndex = 0
    var started = false

    /// Bytes the fake writes into the frame buffer on `frame`.
    var frameBytes = (0..<KirikiriEngineAPI.FrameLayout.size).map { UInt8($0 % 251) }
    var hasFrame = true

    func makeAPI() -> KirikiriEngineAPI {
        KirikiriEngineAPI(
            start: { [self] config in
                let root = config.load(fromByteOffset: KirikiriEngineAPI.ConfigLayout.gameRootOff,
                                       as: UnsafePointer<CChar>?.self)
                let rootString = root.map { String(cString: $0) } ?? ""
                let size = config.load(fromByteOffset: KirikiriEngineAPI.ConfigLayout.structSizeOff,
                                       as: UInt32.self)
                calls.append(.init(kind: .start(gameRoot: rootString)))
                // The config must be laid out exactly like the C header.
                precondition(size == UInt32(KirikiriEngineAPI.ConfigLayout.structSize))
                started = true
                return 0
            },
            tick: { [self] in
                calls.append(.init(kind: .tick))
                if tickIndex < tickResults.count {
                    defer { tickIndex += 1 }
                    return tickResults[tickIndex]
                }
                return 1
            },
            canvasSize: { width, height in
                width.pointee = 640
                height.pointee = 480
            },
            pointer: { [self] phase, x, y, button in
                calls.append(.init(kind: .pointer(phase, x, y, button)))
            },
            wheel: { _, _, _ in },
            touch: { _, _, _, _ in },
            key: { [self] virtualKey, down in
                calls.append(.init(kind: .key(virtualKey, down)))
            },
            stop: { [self] in
                calls.append(.init(kind: .stop))
            },
            frame: { [self] buffer in
                guard hasFrame else { return 0 }
                buffer.copyMemory(from: frameBytes, byteCount: frameBytes.count)
                return 1
            },
            cursor: { _, _, _, _, _, _ in 0 })
    }
}
