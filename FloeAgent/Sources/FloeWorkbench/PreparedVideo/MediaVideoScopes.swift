// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics

/// Bounded measurement of the rendered sRGB preview, not an HDR/broadcast
/// instrument. Counts are retained for both native plotting and model reads.
public struct MediaVideoScopeSnapshot: Sendable, Codable, Hashable {
    public let documentID: UUID
    public let revision: Int64
    public let timelineSeconds: Double
    public let signalSpace: String
    public let sampleWidth: Int
    public let sampleHeight: Int
    public let waveformWidth: Int
    public let waveformHeight: Int
    /// Row zero is zero luminance; each row contains waveformWidth bins.
    public let waveform: [UInt32]
    public let vectorscopeSize: Int
    /// Rec.709 Cb and Cr, each shifted by +0.5 into the plotted 0...1 range.
    /// Row zero is Cr=-0.5; each row contains vectorscopeSize Cb bins.
    public let vectorscope: [UInt32]
    public let sampledPixels: Int

    public static func measure(_ image: CGImage, documentID: UUID, revision: Int64,
                               timelineSeconds: Double) throws -> Self {
        guard timelineSeconds.isFinite,timelineSeconds >= 0,revision >= 0 else {
            throw MediaPreparedCoreError.invalidOperation("invalid video-scope snapshot identity")
        }
        try Task.checkCancellation()
        let raster = try MediaNativeSelection.rgba(image,maxEdge:256,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        let width = 64,height = 128,vectorSize = 64
        var waveform = [UInt32](repeating:0,count:width*height)
        var vectorscope = [UInt32](repeating:0,count:vectorSize*vectorSize)
        var sampled = 0
        for index in 0..<(raster.width*raster.height) {
            if index%4096 == 0 { try Task.checkCancellation() }
            let at = index*4,alpha = Double(raster.pixels[at+3])/255
            guard alpha > 0 else { continue }
            // Snapshot pixels are premultiplied. Recover code values before
            // computing luma/chroma so alpha does not lower signal readings.
            let red = Double(raster.pixels[at])/255/alpha,green = Double(raster.pixels[at+1])/255/alpha,blue = Double(raster.pixels[at+2])/255/alpha
            let luma = 0.2126*red+0.7152*green+0.0722*blue
            let x = min(width-1,(index%raster.width)*width/raster.width)
            let y = max(0,min(height-1,Int((luma*Double(height-1)).rounded())))
            waveform[y*width+x] += 1
            let cb = (blue-luma)/1.8556+0.5,cr = (red-luma)/1.5748+0.5
            let vx = max(0,min(vectorSize-1,Int((cb*Double(vectorSize-1)).rounded())))
            let vy = max(0,min(vectorSize-1,Int((cr*Double(vectorSize-1)).rounded())))
            vectorscope[vy*vectorSize+vx] += 1;sampled += 1
        }
        return .init(documentID:documentID,revision:revision,timelineSeconds:timelineSeconds,signalSpace:"sRGB-preview/Rec709-luma-chroma",
            sampleWidth:raster.width,sampleHeight:raster.height,waveformWidth:width,waveformHeight:height,waveform:waveform,
            vectorscopeSize:vectorSize,vectorscope:vectorscope,sampledPixels:sampled)
    }
}
