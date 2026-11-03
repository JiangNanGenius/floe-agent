// SPDX-License-Identifier: MPL-2.0
//
// Deterministic VNC core tests (authored, NOT RUN in this lane).
// They exercise the bounded framebuffer gate and the Android RGBA channel
// conversion without a display, device or network.

import Foundation
import Testing
@testable import FloeVNC

@Suite("VNC frame bounds and pixel format")
struct VNCFloeCoreTests {
    @Test("Oversized and empty framebuffer declarations are refused")
    func frameBounds() {
        #expect(VNCFloeFrameBounds.validate(width: 65535, height: 65535) != nil)
        #expect(VNCFloeFrameBounds.validate(width: 8193, height: 1) != nil)
        #expect(VNCFloeFrameBounds.validate(width: 0, height: 1) != nil)
        #expect(VNCFloeFrameBounds.validate(width: 4097, height: 2160) != nil)
        #expect(VNCFloeFrameBounds.validate(width: 1920, height: 1080) == nil)
        #expect(VNCFloeFrameBounds.validate(width: 3840, height: 2160) == nil)
        #expect(VNCFloeFrameBounds.maximumBytes == 33_177_600)
    }

    @Test("BGRA to RGBA keeps red and blue on the correct channels")
    func channelOrder() {
        // One BGRA pixel: blue=0, green=0, red=255, alpha=255.
        let red = Data([0, 0, 255, 255])
        #expect([UInt8](VNCFloePixelFormat.rgbaFromBGRA(red)) == [255, 0, 0, 255])

        // Blue pixel: B=255, G=0, R=0.
        let blue = Data([255, 0, 0, 255])
        #expect([UInt8](VNCFloePixelFormat.rgbaFromBGRA(blue)) == [0, 0, 255, 255])

        // Asymmetric test pattern: B=1, G=2, R=3, A=4 -> R=3,G=2,B=1,A=4.
        let pattern = Data([1, 2, 3, 4, 9, 8, 7, 6])
        #expect([UInt8](VNCFloePixelFormat.rgbaFromBGRA(pattern)) == [3, 2, 1, 4, 7, 8, 9, 6])
    }

    @Test("Bounded allocator refuses an oversized framebuffer and zeroes memory")
    func allocator() throws {
        let allocator = VNCFloeBoundedAllocator(maximumBytes: 64)
        do {
            _ = try allocator.allocate(size: 65)
            Issue.record("oversized allocation must throw")
        } catch let failure as VNCFloeFailure {
            #expect(failure.category == .framebufferTooLarge)
        }
        let pointer = try allocator.allocate(size: 16)
        let bytes = UnsafeRawBufferPointer(start: pointer, count: 16)
        #expect(bytes.allSatisfy { $0 == 0 })
        allocator.deallocate(buffer: pointer)
    }
}
