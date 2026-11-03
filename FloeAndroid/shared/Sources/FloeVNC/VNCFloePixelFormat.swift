// SPDX-License-Identifier: MPL-2.0
//
// Deterministic pixel conversion used by the Android frame lease. Android's
// ARGB_8888 Bitmap consumes RGBA8 bytes on the little-endian ABI; the
// RoyalVNCKit destination surface is BGRA8. Keeping the conversion here (and
// testing a red/blue asymmetric pattern) prevents the classic swapped-channel
// viewer.

import Foundation

public enum VNCFloePixelFormat {
    public static let format = VNCFloeFrame.pixelFormat
    public static let bytesPerPixel = 4

    /// Converts tightly packed BGRA8 bytes into tightly packed RGBA8 bytes.
    /// The output count equals the input count; a trailing partial pixel is
    /// copied as-is rather than reading past the input.
    public static func rgbaFromBGRA(_ source: Data) -> Data {
        let count = source.count
        var output = Data(count: count)
        source.withUnsafeBytes { sourceRaw in
            output.withUnsafeMutableBytes { destinationRaw in
                guard let src = sourceRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = destinationRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                let pixels = count / 4
                var index = 0
                while index < pixels {
                    let base = index * 4
                    dst[base] = src[base + 2]     // R <- B-G-R
                    dst[base + 1] = src[base + 1] // G
                    dst[base + 2] = src[base]     // B
                    dst[base + 3] = src[base + 3] // A
                    index += 1
                }
                let remainderStart = pixels * 4
                var remainder = remainderStart
                while remainder < count {
                    dst[remainder] = src[remainder]
                    remainder += 1
                }
            }
        }
        return output
    }
}
