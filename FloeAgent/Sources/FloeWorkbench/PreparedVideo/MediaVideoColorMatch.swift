// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage

public struct MediaLabMoments: Sendable, Codable, Hashable {
    public var mean: [Double]
    public var deviation: [Double]
    public var pixelCount: Int
    public init(mean: [Double], deviation: [Double], pixelCount: Int) {
        self.mean = mean; self.deviation = deviation; self.pixelCount = pixelCount
    }
    public func validate() throws {
        guard mean.count == 3, deviation.count == 3, mean.allSatisfy({ $0.isFinite && abs($0) <= 160 }),
              (0...100.001).contains(mean[0]), deviation.allSatisfy({ $0.isFinite && (0...160).contains($0) }),
              (1...1_048_576).contains(pixelCount) else { throw MediaPreparedCoreError.invalidDocument("invalid measured Lab color moments") }
    }
}

public struct MediaVideoColorMatchFrame: Sendable, Codable, Hashable {
    public var assetID: UUID
    public var assetRevision: UInt64
    public var contentHash: String
    public var sourceSeconds: Double
    public var moments: MediaLabMoments
    public init(assetID: UUID, assetRevision: UInt64, contentHash: String, sourceSeconds: Double, moments: MediaLabMoments) {
        self.assetID = assetID; self.assetRevision = assetRevision; self.contentHash = contentHash
        self.sourceSeconds = sourceSeconds; self.moments = moments
    }
    public func validate() throws {
        try moments.validate()
        guard assetRevision < UInt64.max, sourceSeconds.isFinite, sourceSeconds >= 0,
              contentHash.range(of: "^[a-f0-9]{64}$",options: .regularExpression) != nil else {
            throw MediaPreparedCoreError.invalidDocument("invalid color-reference source binding")
        }
    }
}

/// A captured reference look. Later edits/deletion of the reference clip do
/// not change the saved correction. Target replacement requires re-analysis.
public struct MediaVideoColorMatch: Sendable, Codable, Hashable {
    public var target: MediaVideoColorMatchFrame
    public var reference: MediaVideoColorMatchFrame
    public var referenceClipID: UUID
    public var mix: Double
    public var matchesContrast: Bool
    public init(target: MediaVideoColorMatchFrame, reference: MediaVideoColorMatchFrame,
                referenceClipID: UUID, mix: Double = 1, matchesContrast: Bool = true) {
        self.target = target; self.reference = reference; self.referenceClipID = referenceClipID
        self.mix = mix; self.matchesContrast = matchesContrast
    }
    public func validate() throws {
        try target.validate(); try reference.validate()
        guard mix.isFinite, (0...1).contains(mix) else { throw MediaPreparedCoreError.invalidDocument("color match strength must be in 0...1") }
        if matchesContrast {
            for i in 0..<3 where target.moments.deviation[i] >= 0.1 {
                guard reference.moments.deviation[i]/target.moments.deviation[i] <= 32 else {
                    throw MediaPreparedCoreError.invalidOperation("choose a more detailed target frame or turn off contrast matching")
                }
            }
        }
    }
    public func cubeData(dimension: Int = 32) throws -> Data {
        try validate()
        guard dimension == 32 else { throw MediaPreparedCoreError.invalidOperation("unsupported color-match cube dimension") }
        var cube = [Float]();cube.reserveCapacity(dimension*dimension*dimension*4)
        for b in 0..<dimension {
            try Task.checkCancellation()
            for g in 0..<dimension { for r in 0..<dimension {
                let rgb = [Double(r)/31,Double(g)/31,Double(b)/31]
                let original = MediaLabColorMath.lab(linearRGB: rgb)
                let corrected = (0..<3).map { i -> Double in
                    let ratio = matchesContrast && target.moments.deviation[i] >= 0.1 ? reference.moments.deviation[i]/target.moments.deviation[i] : 1
                    let fitted = (original[i]-target.moments.mean[i])*ratio+reference.moments.mean[i]
                    return original[i]+(fitted-original[i])*mix
                }
                let output = MediaLabColorMath.linearRGB(lab: corrected).map { min(1,max(0,$0)) }
                cube.append(contentsOf: output.map(Float.init));cube.append(1)
            } }
        }
        return cube.withUnsafeBytes { Data($0) }
    }
    public func apply(to image: CIImage, cubeData: Data? = nil) throws -> CIImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else { throw PreparedVideoError.renderFailed("linear sRGB unavailable") }
        let data = try cubeData ?? self.cubeData()
        guard data.count == 32*32*32*4*MemoryLayout<Float>.stride else { throw MediaPreparedCoreError.invalidOperation("invalid color-match cube") }
        return image.applyingFilter("CIColorCubeWithColorSpace",parameters: ["inputCubeDimension": 32,"inputCubeData": data,"inputColorSpace": colorSpace])
    }
}

public enum MediaLabColorMath {
    /// Measure alpha-weighted colors in a bounded display-sRGB observation.
    /// No luminance histogram is substituted for actual three-channel color.
    public static func moments(_ image: CGImage) throws -> MediaLabMoments {
        guard image.width > 0, image.height > 0, image.width <= 1024, image.height <= 1024 else {
            throw MediaPreparedCoreError.limitsExceeded("color observation exceeds 1024 pixels per edge")
        }
        var bytes = [UInt8](repeating: 0,count: image.width*image.height*4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,
                bytesPerRow: image.width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw PreparedVideoError.renderFailed("could not sample source colors")
            }
            context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        }
        var mean = [0.0,0,0], m2 = [0.0,0,0], weight = 0.0, count = 0
        for row in 0..<image.height {
            try Task.checkCancellation()
            for column in 0..<image.width {
                let i = (row*image.width+column)*4, a = Double(bytes[i+3])/255
                guard a > 0 else { continue }
                let rgb = (0..<3).map { decodeSRGB(min(1,Double(bytes[i+$0])/255/a)) }, value = lab(linearRGB: rgb)
                let nextWeight = weight+a
                for c in 0..<3 {
                    let delta = value[c]-mean[c];mean[c] += delta*a/nextWeight
                    m2[c] += a*delta*(value[c]-mean[c])
                }
                weight = nextWeight;count += 1
            }
        }
        guard count > 0,weight > 0 else { throw MediaPreparedCoreError.invalidOperation("the selected frame has no visible color samples") }
        let result = MediaLabMoments(mean: mean,deviation: m2.map { sqrt(max(0,$0/weight)) },pixelCount: count)
        try result.validate();return result
    }
    static func decodeSRGB(_ value: Double) -> Double {
        value <= 0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4)
    }
    static func encodeSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? value*12.92 : 1.055*pow(value,1/2.4)-0.055
    }
    static func lab(linearRGB: [Double]) -> [Double] {
        let r = linearRGB[0],g = linearRGB[1],b = linearRGB[2]
        let x = (0.4124564*r+0.3575761*g+0.1804375*b)/0.95047
        let y = 0.2126729*r+0.7151522*g+0.0721750*b
        let z = (0.0193339*r+0.1191920*g+0.9503041*b)/1.08883
        func f(_ v: Double) -> Double { v > 216.0/24389 ? cbrt(v) : (24389.0/27*v+16)/116 }
        let fx = f(x),fy = f(y),fz = f(z)
        return [116*fy-16,500*(fx-fy),200*(fy-fz)]
    }
    static func linearRGB(lab: [Double]) -> [Double] {
        let fy = (lab[0]+16)/116,fx = fy+lab[1]/500,fz = fy-lab[2]/200
        func f(_ t: Double) -> Double { let v = t*t*t;return v > 216.0/24389 ? v : (116*t-16)/(24389.0/27) }
        let x = f(fx)*0.95047,y = f(fy),z = f(fz)*1.08883
        return [3.2404542*x-1.5371385*y-0.4985314*z,
                -0.969266*x+1.8760108*y+0.041556*z,
                0.0556434*x-0.2040259*y+1.0572252*z]
    }
}
