// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreText
import Testing
import FloeHeavyEditorSupport
@testable import FloeFontKit

private func fixture(_ name:String)throws->Data { try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"zip",subdirectory:"Fixtures")!) }
private func tableTag(_ string:String)->UInt32 { string.utf8.reduce(0){($0<<8)|UInt32($1)} }
private func fontFrom(_ data:Data)throws->CTFont {
    guard let descriptors=CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],let descriptor=descriptors.first else{throw HeavyEditorError.invalidDocument}
    return CTFontCreateWithFontDescriptor(descriptor,1000,nil)
}
private func advance(_ font:CTFont,_ scalar:UniChar)->Double {
    var character=scalar,glyph=CGGlyph(),size=CGSize.zero
    guard CTFontGetGlyphsForCharacters(font,&character,&glyph,1) else{return 0}
    return CTFontGetAdvancesForGlyphs(font,.horizontal,&glyph,&size,1)
}
@Test func realNativeVariableFontAndOpenTypeShape()async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let compiler=try FontCompilerService(scratchRoot:root)
    let response=try await compiler.compile(.object(["archive":.string(try fixture("variable-ligature").base64EncodedString())]))
    let encoded=try #require(response["base64"].string)
    let data=try #require(Data(base64Encoded:encoded))
    if let path=ProcessInfo.processInfo.environment["FLOE_FONT_TEST_ARTIFACTS"] {
        let directory=URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try data.write(to:directory.appendingPathComponent("variable-ligature.ttf"),options:.atomic)
    }
    let font=try fontFrom(data)
    for name in ["glyf","fvar","gvar","GSUB","GPOS"] { #expect(CTFontCopyTable(font,tableTag(name),[]) != nil) }
    let axisKey=NSNumber(value:tableTag("wght"))
    let variation=CTFontDescriptorCreateCopyWithVariation(CTFontCopyFontDescriptor(font),axisKey,700)
    let bold=CTFontCreateWithFontDescriptor(variation,1000,nil)
    #expect(advance(bold,65)>advance(font,65)+90)
    let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTLigatureAttributeName as String):1]
    let ligature=CTLineCreateWithAttributedString(NSAttributedString(string:"fi",attributes:attributes))
    #expect(CTLineGetGlyphCount(ligature)==1)
    let kerned=CTLineCreateWithAttributedString(NSAttributedString(string:"AV",attributes:attributes))
    let width=CTLineGetTypographicBounds(kerned,nil,nil,nil)
    #expect(width<advance(font,65)+advance(font,86)-40)
    #expect((try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)).isEmpty)
}
private func variationFont(_ font:CTFont,_ values:[String:Double])->CTFont {
    let variation=Dictionary(uniqueKeysWithValues:values.map{(NSNumber(value:tableTag($0.key)),$0.value)})
    let descriptor=CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(font),[kCTFontVariationAttribute:variation] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor,1000,nil)
}
@Test func twoAxesCorrectionMasterKerningAndVerticalMetrics()async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let compiler=try FontCompilerService(scratchRoot:root)
    let response=try await compiler.compile(.object(["archive":.string(try fixture("multi-axis").base64EncodedString())]))
    let encoded=try #require(response["base64"].string)
    let data=try #require(Data(base64Encoded:encoded)),font=try fontFrom(data)
    if let path=ProcessInfo.processInfo.environment["FLOE_FONT_TEST_ARTIFACTS"] {
        let directory=URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try data.write(to:directory.appendingPathComponent("multi-axis.ttf"),options:.atomic)
    }
    for name in ["fvar","gvar","HVAR","VVAR","vhea","vmtx","GPOS"]{#expect(CTFontCopyTable(font,tableTag(name),[]) != nil)}
    let middle=variationFont(font,["wght":550,"wdth":125]),quarter=variationFont(font,["wght":475,"wdth":112.5])
    #expect(abs(advance(middle,65)-900)<1)
    #expect(abs(advance(quarter,65)-712.5)<1)
    let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):quarter]
    let line=CTLineCreateWithAttributedString(NSAttributedString(string:"AV",attributes:attributes))
    #expect(abs(CTLineGetTypographicBounds(line,nil,nil,nil)-(advance(quarter,65)+advance(quarter,86)-50))<1)
    var character:UniChar=65,glyph=CGGlyph(),size=CGSize.zero
    #expect(CTFontGetGlyphsForCharacters(quarter,&character,&glyph,1))
    let verticalAdvance=CTFontGetAdvancesForGlyphs(quarter,.vertical,&glyph,&size,1)
    #expect(abs(verticalAdvance-1112.5)<1)
}
@Test func staticUFOCompilesWithoutInventingAVariationAxis()async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let compiler=try FontCompilerService(scratchRoot:root)
    let response=try await compiler.compile(.object(["archive":.string(try fixture("static-layout").base64EncodedString()),"static":.bool(true)]))
    let encoded=try #require(response["base64"].string)
    let data=try #require(Data(base64Encoded:encoded)),font=try fontFrom(data)
    #expect(CTFontCopyTable(font,tableTag("fvar"),[]) == nil)
    #expect(CTFontCopyTable(font,tableTag("GSUB"),[]) != nil)
    let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font]
    let line=CTLineCreateWithAttributedString(NSAttributedString(string:"A\u{0301}",attributes:attributes))
    let runs=CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    let positions=runs.flatMap { run in
        var values=[CGPoint](repeating:.zero,count:CTRunGetGlyphCount(run))
        CTRunGetPositions(run,CFRange(location:0,length:0),&values)
        return values
    }
    #expect(positions.count==2)
    #expect(positions.contains{abs($0.x-250)<1 && abs($0.y-700)<1})
    if let path=ProcessInfo.processInfo.environment["FLOE_FONT_TEST_ARTIFACTS"] {
        let directory=URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try data.write(to:directory.appendingPathComponent("static-layout.ttf"),options:.atomic)
    }
}
@Test func generatedCFFCanLoadAndShapeInCoreText()throws {
    let url=try #require(Bundle.module.url(forResource:"static-layout",withExtension:"otf",subdirectory:"Fixtures"))
    let font=try fontFrom(Data(contentsOf:url))
    #expect(CTFontCopyTable(font,tableTag("CFF "),[]) != nil)
    #expect(CTFontCopyTable(font,tableTag("glyf"),[]) == nil)
    let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTLigatureAttributeName as String):1]
    #expect(CTLineGetGlyphCount(CTLineCreateWithAttributedString(NSAttributedString(string:"fi",attributes:attributes)))==1)
}
@Test func invalidFeatureIsARealCompilerFailure()async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let compiler=try FontCompilerService(scratchRoot:root)
    do { _=try await compiler.compile(.object(["archive":.string(try fixture("invalid-feature").base64EncodedString())]));Issue.record("Invalid glyph reference compiled") }
    catch HeavyEditorError.engine(let message){#expect(!message.isEmpty)}
}
@Test func featureIncludeCannotReadOutsideTheStagedFont()async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let compiler=try FontCompilerService(scratchRoot:root)
    do { _=try await compiler.compile(.object(["archive":.string(try fixture("external-include").base64EncodedString())]));Issue.record("External include accepted") }
    catch HeavyEditorError.engine(let message){#expect(message.contains("include")||message.contains("引用"))}
}
