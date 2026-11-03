// SPDX-License-Identifier: MPL-2.0
//
// FreeRDP publishes the desktop in BGRA32 order. The Android frame lane and
// the PNG artifact writer consume tightly packed RGBA8, so the conversion is
// explicit, bounded and unit tested. No pixel format is guessed from the
// server.

import Foundation

public enum RDPFloePixelFormat {
    /// Converts a BGRA32 framebuffer with an arbitrary stride into tightly
    /// packed RGBA8. Returns nil when the declared geometry is outside the
    /// frame bounds; callers treat that as a framebuffer failure rather than
    /// publishing a partial frame.
    public static func rgbaFromBGRA(
        _ source: Data,
        width: Int,
        height: Int,
        stride: Int
    ) -> Data? {
        guard RDPFloeFrameBounds.validate(width: width, height: height) == nil else {
            return nil
        }
        guard stride >= width * 4 else { return nil }
        let sourceBytes = stride.multipliedReportingOverflow(by: height)
        guard !sourceBytes.overflow, sourceBytes.partialValue <= source.count else {
            return nil
        }
        guard sourceBytes.partialValue >= width * height * 4 else { return nil }
        let destinationCount = width * height * 4
        var destination = Data(count: destinationCount)
        destination.withUnsafeMutableBytes { destinationRaw in
            guard let destinationBytes = destinationRaw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            source.withUnsafeBytes { sourceRaw in
                guard let sourceBytes = sourceRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }
                for row in 0..<height {
                    let sourceRow = sourceBytes.advanced(by: row * stride)
                    let destinationRow = destinationBytes.advanced(by: row * width * 4)
                    for column in 0..<width {
                        let sourcePixel = sourceRow.advanced(by: column * 4)
                        let destinationPixel = destinationRow.advanced(by: column * 4)
                        destinationPixel[0] = sourcePixel[2]
                        destinationPixel[1] = sourcePixel[1]
                        destinationPixel[2] = sourcePixel[0]
                        destinationPixel[3] = sourcePixel[3]
                    }
                }
            }
        }
        return destination
    }
}
