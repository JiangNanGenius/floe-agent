// SPDX-License-Identifier: MPL-2.0
//
// Bounded framebuffer allocation for the Android VNC port. RoyalVNCKit's
// default malloc allocator trusts the server's ServerInit width/height.
// A malformed or hostile RFB peer can declare 65535x65535 and force a
// multi-gigabyte allocation. This allocator is the hard stop.

import Foundation
import RoyalVNCKit

public enum VNCFloeFrameBounds {
    /// Largest accepted framebuffer width or height.
    public static let maximumDimension = 8_192
    /// Largest accepted pixel count (3840x2160). 8,294,400 * 4 = 33,177,600.
    public static let maximumPixels = 8_294_400
    /// Largest accepted RGBA8 byte count.
    public static let maximumBytes = maximumPixels * 4
    /// A VNC viewer holds at most four leases for the same session.
    public static let maximumLeasesPerSession = 4

    /// Returns a typed failure for a malformed ServerInit geometry, or nil
    /// when the framebuffer is inside the bounded envelope.
    public static func validate(width: Int, height: Int) -> VNCFloeFailure? {
        guard width > 0, height > 0 else {
            return VNCFloeFailure(
                category: .framebufferTooLarge,
                stage: .framebuffer,
                retryable: false,
                message: "The VNC server declared an empty framebuffer."
            )
        }
        guard width <= maximumDimension, height <= maximumDimension else {
            return VNCFloeFailure(
                category: .framebufferTooLarge,
                stage: .framebuffer,
                retryable: false,
                message: "The VNC framebuffer exceeds the supported \(maximumDimension)-pixel dimension."
            )
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumPixels else {
            return VNCFloeFailure(
                category: .framebufferTooLarge,
                stage: .framebuffer,
                retryable: false,
                message: "The VNC framebuffer exceeds the supported \(maximumPixels)-pixel area."
            )
        }
        return nil
    }
}

/// Allocation is checked against the same byte ceiling. The framebuffer
/// allocator is the last line of defence because RoyalVNCKit creates the
/// library buffer before the delegate sees `didCreateFramebuffer`.
public final class VNCFloeBoundedAllocator: VNCFramebufferAllocator, @unchecked Sendable {
    public let maximumBytes: Int
    private let lock = NSLock()

    public init(maximumBytes: Int = VNCFloeFrameBounds.maximumBytes) {
        self.maximumBytes = max(1, maximumBytes)
    }

    public func allocate(size: Int) throws -> UnsafeMutableRawPointer {
        guard size > 0, size <= maximumBytes else {
            throw VNCFloeFailure(
                category: .framebufferTooLarge,
                stage: .framebuffer,
                retryable: false,
                message: "The VNC framebuffer allocation exceeds the \(maximumBytes)-byte bound."
            )
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<UInt8>.alignment
        )
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        return buffer
    }

    public func deallocate(buffer: UnsafeMutableRawPointer) {
        buffer.deallocate()
    }

    public func lockReadOnly() {
        lock.lock()
    }

    public func unlockReadOnly() {
        lock.unlock()
    }

    public func lockReadWrite() {
        lock.lock()
    }

    public func unlockReadWrite() {
        lock.unlock()
    }
}
