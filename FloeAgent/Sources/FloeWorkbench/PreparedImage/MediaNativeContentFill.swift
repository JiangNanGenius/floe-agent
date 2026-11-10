// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage
import FloeCore

public enum MediaContentFillMode:String,Sendable,Codable,CaseIterable { case adaptive,texture }
public enum MediaContentFillQuality:Int,Sendable,Codable,CaseIterable { case fast=0,balanced=1,detailed=2 }
/// Bounded exemplar synthesis: compare known patch context, copy texture from
/// real unselected source patches, then continue inward. No blur, box fill,
/// fixed clone offset, network or model service substitutes for the operation.
public enum MediaNativeContentFill {
    private static func text(_ zh:String,_ en:String) -> String { FloeL10n.isChinese ? zh:en }
    public static func fill(_ image:CGImage,selection:ImageSelection,mode:MediaContentFillMode = .adaptive,quality:MediaContentFillQuality = .balanced,nearbyOnly:Bool=true,samplingBounds:NormalizedRect?=nil) throws -> CGImage {
        guard image.width>0,image.height>0,image.width<=8192,image.height<=8192,image.width*image.height<=8_388_608 else { throw MediaPreparedCoreError.limitsExceeded(text("请将图像控制在 800 万像素以内。", "Use an image up to8 megapixels.")) }
        try Task.checkCancellation()
        let w=image.width,h=image.height,n=w*h,r=3,extent=CGRect(x:0,y:0,width:w,height:h)
        guard let coverage=ImageSelectionRasterizer.maskImage(for:selection,canvas:extent.size),let mask=CIContext(options:[.cacheIntermediates:false]).createCGImage(coverage,from:extent) else { throw MediaPreparedCoreError.invalidOperation(text("请先选择需要填补的区域。", "Select the area to fill first.")) }
        let original=try MediaNativeSelection.rgba(image,maxEdge:8192).pixels,maskPixels=try MediaNativeSelection.rgba(mask,maxEdge:8192).pixels
        let alpha=stride(from:3,to:maskPixels.count,by:4).map{maskPixels[$0]}
        var state=alpha.map{UInt8($0>0 ? 1:0)},minX=w,minY=h,maxX = -1,maxY = -1,count=0
        for index in 0..<n where state[index]==1 { minX=min(minX,index%w);maxX=max(maxX,index%w);minY=min(minY,index/w);maxY=max(maxY,index/w);count+=1 }
        guard count>0 else { throw MediaPreparedCoreError.invalidOperation(text("请先选择需要填补的区域。", "Select the area to fill first.")) }
        guard count<=65_536,maxX-minX<2048,maxY-minY<2048 else { throw MediaPreparedCoreError.limitsExceeded(text("请缩小选区，分几次填补较大的区域。", "Use a smaller selection and fill larger areas in stages.")) }
        var left=r,top=r,right=w-r-1,bottom=h-r-1
        if let rect=samplingBounds {
            guard [rect.x,rect.y,rect.width,rect.height].allSatisfy(\.isFinite),rect.x>=0,rect.y>=0,rect.width>0,rect.height>0,rect.x+rect.width<=1,rect.y+rect.height<=1 else { throw MediaPreparedCoreError.invalidOperation("sampling bounds must fit the normalized image") }
            left=max(left,Int(ceil(rect.x*Double(w)))+r);top=max(top,Int(ceil(rect.y*Double(h)))+r)
            right=min(right,Int(floor((rect.x+rect.width)*Double(w)))-r-1);bottom=min(bottom,Int(floor((rect.y+rect.height)*Double(h)))-r-1)
        } else if nearbyOnly {
            let margin=max(24,min(256,max(maxX-minX,maxY-minY)/2+24))
            left=max(left,minX-margin+r);top=max(top,minY-margin+r);right=min(right,maxX+margin-r);bottom=min(bottom,maxY+margin-r)
        }
        guard left<=right,top<=bottom else { throw MediaPreparedCoreError.invalidOperation(text("周围没有足够的取样画面，请扩大取样范围。", "Not enough surrounding image is available. Expand the sampling area.")) }
        let row=w+1
        var invalid=[Int32](repeating:0,count:(w+1)*(h+1))
        for y in 0..<h {
            if y%32==0 { try Task.checkCancellation() }
            var sum:Int32=0
            for x in 0..<w { let index=y*w+x;sum += (state[index]==1 || original[index*4+3]==0) ? 1:0;invalid[(y+1)*row+x+1]=invalid[y*row+x+1]+sum }
        }
        func valid(_ x:Int,_ y:Int) -> Bool {
            guard x>=left,x<=right,y>=top,y<=bottom else { return false }
            let x0=x-r,y0=y-r,x1=x+r+1,y1=y+r+1
            return invalid[y1*row+x1]-invalid[y0*row+x1]-invalid[y1*row+x0]+invalid[y0*row+x0]==0
        }
        var pool:[Int]=[],seen=0,random:UInt64=0x4D4544494146494C
        for y in top...bottom {
            if y%32==0 { try Task.checkCancellation() }
            for x in left...right where valid(x,y) {
                seen+=1;random=random &* 6364136223846793005 &+ 1442695040888963407
                if pool.count<8192 { pool.append(y*w+x) }
                else { let slot=Int(random%UInt64(seen));if slot<8192 { pool[slot]=y*w+x } }
            }
        }
        guard !pool.isEmpty else { throw MediaPreparedCoreError.invalidOperation(text("请保留一些未选中的画面作为填补来源。", "Leave some unselected image available as a fill source.")) }
        func neighbors(_ index:Int) -> [Int] { let x=index%w,y=index/w;return [x>0 ? index-1:nil,x+1<w ? index+1:nil,y>0 ? index-w:nil,y+1<h ? index+w:nil].compactMap{$0} }
        var queue:[Int]=[];queue.reserveCapacity(count)
        for y in minY...maxY { for x in minX...maxX { let index=y*w+x;if state[index]==1 && neighbors(index).contains(where:{state[$0]==0}) { state[index]=2;queue.append(index) } } }
        var cursor=0
        while cursor<queue.count { let index=queue[cursor];cursor+=1;for next in neighbors(index) where state[next]==1 { state[next]=2;queue.append(next) } }
        guard queue.count==count else { throw MediaPreparedCoreError.invalidOperation("fill boundary is not reachable") }
        var output=original
        let trials:Int=switch quality { case .fast:64;case .balanced:192;case .detailed:512 }
        let offsets=(-r...r).flatMap{y in (-r...r).map{x in (x,y)}}
        func pixel(_ bytes:[UInt8],_ i:Int) -> SIMD4<Float> { .init(Float(bytes[i*4]),Float(bytes[i*4+1]),Float(bytes[i*4+2]),Float(bytes[i*4+3])) }
        for (iteration,target) in queue.enumerated() where state[target]==2 {
            if iteration%16==0 { try Task.checkCancellation() }
            let x=target%w,y=target/w
            let known=offsets.filter { dx,dy in let tx=x+dx,ty=y+dy;return tx>=0 && tx<w && ty>=0 && ty<h && state[ty*w+tx] != 2 }
            guard !known.isEmpty else { throw MediaPreparedCoreError.invalidOperation("fill context is empty") }
            let targetMean=known.reduce(SIMD4<Float>.zero){$0+pixel(output,(y+$1.1)*w+x+$1.0)}/Float(known.count)
            var best:Int?,bestShift=SIMD4<Float>.zero,bestScore=Float.greatestFiniteMagnitude
            func consider(_ candidate:Int) {
                let sx=candidate%w,sy=candidate/w
                guard valid(sx,sy) else { return }
                let mean=known.reduce(SIMD4<Float>.zero){$0+pixel(original,(sy+$1.1)*w+sx+$1.0)}/Float(known.count)
                var shift=mode == .adaptive ? targetMean-mean:.zero;shift.w=0
                var score:Float=0
                for (dx,dy) in known {
                    let delta=pixel(output,(y+dy)*w+x+dx)-pixel(original,(sy+dy)*w+sx+dx)-shift
                    score += delta.x*delta.x+delta.y*delta.y+delta.z*delta.z+delta.w*delta.w
                    if score/Float(known.count)>bestScore { return }
                }
                score=score/Float(known.count)+(shift.x*shift.x+shift.y*shift.y+shift.z*shift.z)*0.02+Float((sx-x)*(sx-x)+(sy-y)*(sy-y))*0.000_001
                if score<bestScore { best=candidate;bestScore=score;bestShift=shift }
            }
            for dy in stride(from:-16,through:16,by:4) { for dx in stride(from:-16,through:16,by:4) { let sx=x+dx,sy=y+dy;if sx>=0,sx<w,sy>=0,sy<h { consider(sy*w+sx) } } }
            let start=Int((UInt64(target) &* 0x9E3779B97F4A7C15)%UInt64(pool.count))
            for attempt in 0..<min(trials,pool.count) { if attempt%64==0 { try Task.checkCancellation() };consider(pool[(start+attempt*104729)%pool.count]) }
            guard let source=best else { throw MediaPreparedCoreError.invalidOperation("no matching fill patch") }
            let sx=source%w,sy=source/w
            for (dx,dy) in offsets {
                let tx=x+dx,ty=y+dy
                guard tx>=0,tx<w,ty>=0,ty<h else { continue }
                let destination=ty*w+tx
                guard state[destination]==2 else { continue }
                let donor=(sy+dy)*w+sx+dx,a=original[donor*4+3]
                for channel in 0..<3 { output[destination*4+channel]=UInt8(max(0,min(Float(a),(Float(original[donor*4+channel])+bestShift[channel]).rounded()))) }
                output[destination*4+3]=a;state[destination]=3
            }
        }
        for index in queue {
            let amount=Float(alpha[index])/255
            for channel in 0..<4 { output[index*4+channel]=UInt8(max(0,min(255,(Float(output[index*4+channel])*amount+Float(original[index*4+channel])*(1-amount)).rounded()))) }
        }
        try Task.checkCancellation()
        guard let provider=CGDataProvider(data:Data(output) as CFData),let result=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw MediaPreparedCoreError.invalidOperation("could not produce filled pixels") }
        return result
    }
}
