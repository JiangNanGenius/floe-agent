// SPDX-License-Identifier: MPL-2.0
// Portable receipt value types extracted from public iOS source 10fc0083.
// Android renderer implementations stay behind MediaProjectHost; these types
// contain verified output facts only and perform no rendering or file IO.
import Foundation

public struct WorkbenchImageExportReceipt: Sendable, Hashable {
    public var url: URL
    public var width: Int
    public var height: Int
    public var format: String
    public var byteCount: Int64

    public init(url: URL, width: Int, height: Int, format: String, byteCount: Int64) {
        self.url = url
        self.width = width
        self.height = height
        self.format = format
        self.byteCount = byteCount
    }
}

public struct WorkbenchVideoExportReceipt: Sendable, Hashable {
    public var url: URL
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var codec: String
    public var hasAudio: Bool
    public var byteCount: Int64

    public init(url: URL, durationSeconds: Double, width: Int, height: Int, frameRate: Double, codec: String, hasAudio: Bool, byteCount: Int64) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.hasAudio = hasAudio
        self.byteCount = byteCount
    }
}
