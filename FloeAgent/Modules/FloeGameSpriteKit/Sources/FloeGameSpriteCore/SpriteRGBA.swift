// SPDX-License-Identifier: MPL-2.0
import Foundation

/// An exact 8-bit straight-alpha color. Sprite pixels are stored in this
/// order; no premultiplication happens in the model.
public struct SpriteRGBA: Hashable, Codable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(white: UInt8, alpha: UInt8 = 255) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    public static let clear = SpriteRGBA(red: 0, green: 0, blue: 0, alpha: 0)
    public static let black = SpriteRGBA(red: 0, green: 0, blue: 0, alpha: 255)
    public static let white = SpriteRGBA(red: 255, green: 255, blue: 255, alpha: 255)

    public var isTransparent: Bool { alpha == 0 }
    public var isOpaque: Bool { alpha == 255 }

    /// Straight-alpha source-over. Used only for UI presentation/contrast;
    /// stored pixels remain exactly `self`.
    public func composited(over background: SpriteRGBA) -> SpriteRGBA {
        if alpha == 255 { return self }
        if alpha == 0 { return background }
        let foreground = Int(alpha)
        let inverse = 255 - foreground
        let denominator = 255
        return SpriteRGBA(
            red: UInt8((Int(red) * foreground + Int(background.red) * inverse) / denominator),
            green: UInt8((Int(green) * foreground + Int(background.green) * inverse) / denominator),
            blue: UInt8((Int(blue) * foreground + Int(background.blue) * inverse) / denominator),
            alpha: UInt8(min(255, foreground + Int(background.alpha) * inverse / 255))
        )
    }

    public var hexString: String {
        let value = (UInt32(red) << 24) | (UInt32(green) << 16) | (UInt32(blue) << 8) | UInt32(alpha)
        return String(format: "%08X", value)
    }

    public init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 8, let parsed = UInt32(value, radix: 16) else { return nil }
        self.init(red: UInt8((parsed >> 24) & 0xFF),
                  green: UInt8((parsed >> 16) & 0xFF),
                  blue: UInt8((parsed >> 8) & 0xFF),
                  alpha: UInt8(parsed & 0xFF))
    }
}
