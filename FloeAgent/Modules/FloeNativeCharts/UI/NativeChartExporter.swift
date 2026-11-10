// SPDX-License-Identifier: MPL-2.0
#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeNativeChartsCore

public enum NativeChartExporter {
    public static func png(_ scene:NativeChartScene,scale:Double = 1) throws -> Data {
        try Task.checkCancellation()
        try check(scene)
        let width=ceil(scene.frame.width*scale),height=ceil(scene.frame.height*scale)
        try chartExportCheck(scale.isFinite && scale>0 && width<=8192 && height<=8192 && width*height<=24_000_000,"PNG dimensions exceed 8192 pixels or 24 megapixels")
        guard let context=CGContext(data:nil,width:Int(width),height:Int(height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw ChartIssue(path:"export",problem:"could not allocate PNG context")}
        context.translateBy(x:0,y:height);context.scaleBy(x:scale,y:-scale)
        NativeChartCGRenderer.draw(scene,in:context)
        guard let image=context.makeImage() else{throw ChartIssue(path:"export",problem:"could not render image")}
        let bytes=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil) else{throw ChartIssue(path:"export",problem:"could not create PNG encoder")}
        CGImageDestinationAddImage(destination,image,nil)
        try chartExportCheck(CGImageDestinationFinalize(destination),"PNG encoding failed")
        try chartExportCheck(bytes.length>0 && bytes.length<=12*1_048_576,"PNG output exceeds 12 MiB")
        try Task.checkCancellation();return bytes as Data
    }
    public static func pdf(_ scenes:[NativeChartScene]) throws -> Data {
        try chartExportCheck(!scenes.isEmpty && scenes.count<=16,"PDF requires 1...16 pages")
        let bytes=NSMutableData()
        guard let consumer=CGDataConsumer(data:bytes),let context=CGContext(consumer:consumer,mediaBox:nil,nil) else{throw ChartIssue(path:"export",problem:"could not create PDF context")}
        for scene in scenes {
            try Task.checkCancellation();try check(scene)
            var rect=CGRect(x:0,y:0,width:scene.frame.width,height:scene.frame.height)
            let box=NSData(bytes:&rect,length:MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String:box] as CFDictionary)
            context.saveGState();context.translateBy(x:0,y:scene.frame.height);context.scaleBy(x:1,y:-1)
            NativeChartCGRenderer.draw(scene,in:context)
            context.restoreGState();context.endPDFPage()
            try chartExportCheck(bytes.length<=16*1_048_576,"PDF output exceeds 16 MiB")
        }
        context.closePDF();try chartExportCheck(bytes.length>0 && bytes.length<=16*1_048_576,"PDF output exceeds 16 MiB")
        try Task.checkCancellation();return bytes as Data
    }
    /// Source document export, never a filtered or viewport-only replacement.
    public static func json(_ source:PreparedChart) throws -> Data {try ChartDocumentCodec.encode(source.document)}
    static func check(_ scene:NativeChartScene) throws {
        try chartExportCheck(scene.frame.isValid && scene.frame.width<=8192 && scene.frame.height<=8192,"invalid export frame")
    }
}
private func chartExportCheck(_ condition:Bool,_ message:String) throws {
    if !condition{throw ChartIssue(path:"export",problem:message)}
}
#endif
