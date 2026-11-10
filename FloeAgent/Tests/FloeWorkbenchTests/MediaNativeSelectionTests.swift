// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
@testable import FloeWorkbench

@Suite("M01-M05 and M22 native coverage masks")
struct MediaNativeSelectionTests {
    func fixture() throws -> CGImage {
        let w=32,h=24
        var bytes=Data(count:w*h*4)
        bytes.withUnsafeMutableBytes{buffer in let pixels=buffer.bindMemory(to:UInt8.self);for y in 0..<h{for x in 0..<w{let i=(y*w+x)*4;pixels[i]=(x<8 || (x>=24 && y<8)) ? 255:0;pixels[i+1]=0;pixels[i+2]=pixels[i]==0 ? 255:0;pixels[i+3]=255}}}
        let provider=try #require(CGDataProvider(data:bytes as CFData))
        return try #require(CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    @Test func wandRetainsConnectedPixelsAndDisjointColorRegionsExactly() throws {
        let image=try fixture(),seed=ImageFreehandStroke.Point(x:0.1,y:0.5)
        let connected=try MediaNativeSelection.wand(image:image,point:seed,tolerance:0),all=try MediaNativeSelection.wand(image:image,point:seed,tolerance:0,contiguous:false)
        #expect(connected.alpha.filter{$0>0}.count==8*24)
        #expect(all.alpha.filter{$0>0}.count==8*24+8*8)
        #expect(connected.alpha[4*32+28]==0 && all.alpha[4*32+28]==255)
        #expect(throws:MediaPreparedCoreError.self){try MediaNativeSelection.wand(image:image,point:seed,tolerance:2)}
    }
    @Test func bitmapSelectionRefinementAndSubtractionKeepActualHolesAndPersist() throws {
        let mask=try ImageSelectionBitmap(width:32,height:24,alpha:Data((0..<32*24).map{let x=$0%32,y=$0/32;return x>=8 && x<24 && y>=6 && y<18 ? UInt8(255):UInt8(0)}))
        let selection=ImageSelection(bitmap:mask)
        let expanded=try MediaNativeSelection.refine(selection,width:32,height:24,mode:.expand,amount:2)
        let contracted=try MediaNativeSelection.refine(selection,width:32,height:24,mode:.expand,amount:-2)
        #expect(expanded.alpha.filter{$0>127}.count>mask.alpha.filter{$0>127}.count)
        #expect(contracted.alpha.filter{$0>127}.count<mask.alpha.filter{$0>127}.count)
        for mode in [MediaNativeSelection.Refinement.refine,.smooth]{let result=try MediaNativeSelection.refine(selection,width:32,height:24,mode:mode,amount:2);#expect(result.alpha.count==32*24 && result.alpha.contains{$0>0})}
        let ring=try MediaNativeSelection.combine(contracted,with:selection,operation:.subtract)
        #expect(ring.bitmap!.alpha[12*32+16]==0)
        let inverted=try MediaNativeSelection.flattened(.init(inverted:true,bitmap:mask),width:32,height:24)
        #expect(inverted.alpha[12*32+16]==0 && inverted.alpha[0]==255)
        let reopened=try JSONDecoder().decode(ImageSelection.self,from:JSONEncoder().encode(ring))
        #expect(reopened==ring)
        #expect(throws:MediaPreparedCoreError.self){try ImageSelectionBitmap(width:2049,height:1,alpha:Data(count:2049))}
    }
    @Test func subjectAdapterAndBackgroundMaskUseRealCoverageWithoutRectangularSubstitution() async throws {
        struct ControlledSubject:MediaSubjectMasking{
            func foregroundMask(_ image:CGImage) async throws -> ImageSelectionBitmap {
                try ImageSelectionBitmap(width:image.width,height:image.height,alpha:Data((0..<image.width*image.height).map{let x=$0%image.width,y=$0/image.width;return (x-16)*(x-16)+(y-12)*(y-12)<36 ? UInt8(255):UInt8(0)}))
            }
        }
        let image=try fixture(),mask=try await ControlledSubject().foregroundMask(image)
        let selection=ImageSelection(bitmap:mask),reopened=try JSONDecoder().decode(ImageSelection.self,from:JSONEncoder().encode(selection))
        #expect(reopened.bitmap!.alpha[12*32+16]==255 && reopened.bitmap!.alpha[0]==0)
        let ci=try #require(ImageSelectionRasterizer.maskImage(for:reopened,canvas:.init(width:32,height:24)))
        let transparent=CIImage(color:.clear).cropped(to:ci.extent)
        let output=CIImage(cgImage:image).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:transparent,kCIInputMaskImageKey:ci])
        let cg=try #require(CIContext().createCGImage(output,from:ci.extent)),pixels=try MediaNativeSelection.rgba(cg).pixels
        #expect(pixels[3]==0 && pixels[(12*32+16)*4+3]==255)
    }
}
