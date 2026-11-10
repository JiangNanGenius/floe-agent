// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import Compression

/// Bounded, embedded coverage mask. Pixel rows match CGImage provider order;
/// normalized placement scales with the canvas. Source image bytes stay in assets.
public struct ImageSelectionBitmap: Codable, Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let alpha: Data
    private let compressed: Data
    public init(width: Int, height: Int, alpha: Data) throws {
        guard width>0,height>0,width<=2048,height<=2048,alpha.count==width*height else {
            throw MediaPreparedCoreError.invalidDocument("selection mask dimensions or coverage bytes are invalid")
        }
        var storage=Data(count:alpha.count+alpha.count/16+1024)
        let count=storage.withUnsafeMutableBytes { destination in
            alpha.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,destination.count,source.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZFSE)
            }
        }
        guard count>0,count<=1_048_576 else{throw MediaPreparedCoreError.limitsExceeded("selection coverage exceeds its lossless storage budget; use a smaller mask")}
        storage.count=count
        self.width=width;self.height=height;self.alpha=alpha;self.compressed=storage
        try validate()
    }
    public func validate() throws {
        guard width>0,height>0,width<=2048,height<=2048,alpha.count==width*height else {
            throw MediaPreparedCoreError.invalidDocument("selection mask must be 1...2048 pixels per edge with exact coverage bytes")
        }
    }
    private enum Keys:String,CodingKey{case width,height,codec,data}
    public init(from decoder:any Decoder) throws {
        let values=try decoder.container(keyedBy:Keys.self)
        let width=try values.decode(Int.self,forKey:.width),height=try values.decode(Int.self,forKey:.height)
        guard width>0,height>0,width<=2048,height<=2048,try values.decode(String.self,forKey:.codec)=="lzfse-v1" else{throw MediaPreparedCoreError.invalidDocument("unsupported selection coverage format")}
        let storage=try values.decode(Data.self,forKey:.data)
        guard !storage.isEmpty,storage.count<=1_048_576 else{throw MediaPreparedCoreError.limitsExceeded("selection coverage storage bound")}
        var bytes=Data(count:width*height)
        let count=bytes.withUnsafeMutableBytes{destination in storage.withUnsafeBytes{source in
            compression_decode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,destination.count,source.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZFSE)
        }}
        guard count==width*height else{throw MediaPreparedCoreError.invalidDocument("damaged selection coverage")}
        try self.init(width:width,height:height,alpha:bytes)
    }
    public func encode(to encoder:any Encoder) throws {
        var values=encoder.container(keyedBy:Keys.self)
        try values.encode(width,forKey:.width);try values.encode(height,forKey:.height)
        try values.encode("lzfse-v1",forKey:.codec);try values.encode(compressed,forKey:.data)
    }
    public var cgImage: CGImage? {
        guard (try? validate()) != nil else{return nil}
        var rgba=Data(count:width*height*4)
        rgba.withUnsafeMutableBytes { destination in
            alpha.withUnsafeBytes { source in
                let a=source.bindMemory(to:UInt8.self),p=destination.bindMemory(to:UInt8.self)
                for i in 0..<a.count{p[i*4]=a[i];p[i*4+1]=a[i];p[i*4+2]=a[i];p[i*4+3]=a[i]}
            }
        }
        guard let provider=CGDataProvider(data:rgba as CFData) else{return nil}
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
}
