// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeWorkbench

@Suite("Editable compound source contracts")
struct MediaPreparedCompoundTests {
    @Test func signatureIsStableAcrossUUIDDictionaryOrderAndCanonicalReopenMetadata() throws {
        let assets=(0..<12).map{MediaAssetReference(kind:.image,relativePath:"Assets/\($0).png",originalName:"\($0)")}
        let document=MediaPreparedDocument(id:UUID(),kind:.video,name:"Source",assets:assets)
        var original=document;original.assetRevisions=Dictionary(uniqueKeysWithValues:assets.enumerated().map{($0.element.id,UInt64($0.offset))})
        let expected=try MediaPreparedCompounds.sourceSignature(original)
        for offset in 0..<12 {
            var shifted=document
            let indices=(offset..<12).map{$0}+(0..<offset).map{$0}
            shifted.assetRevisions=Dictionary(uniqueKeysWithValues:indices.map{(assets[$0].id,UInt64($0))})
            shifted.revision=99;shifted.updatedAt=Date(timeIntervalSince1970:1_700_000_000)
            #expect(try MediaPreparedCompounds.sourceSignature(shifted) == expected)
        }
        original.assetRevisions?[assets[0].id]=1
        #expect(try MediaPreparedCompounds.sourceSignature(original) != expected)
    }
    @Test func selectionAdmitsExactClipIDsAndRejectsMissingOrInterleavedTargets() throws {
        let range=try MediaTimeRange(start:.seconds(0),duration:.seconds(1))
        let source=MediaAssetReference(kind:.image,relativePath:"source.png",originalName:"Source")
        let visual=MediaPreparedClip(assetID:source.id,timelineRange:range,sourceRange:range)
        let other=MediaPreparedClip(assetID:source.id,timelineRange:range,sourceRange:range)
        let above=MediaPreparedClip(assetID:source.id,timelineRange:range,sourceRange:range)
        let graph=MediaPreparedTrackGraph(tracks:[.init(kind:.visual,name:"Bottom",clips:[visual]),.init(kind:.visual,name:"Between",clips:[other]),.init(kind:.visual,name:"Top",clips:[above])],frameRate:try .init(value:15,timescale:1))
        let document=MediaPreparedDocument(id:UUID(),kind:.video,name:"Root",canvas:.init(width:64,height:64,frameRate:15),assets:[source],trackGraph:graph)
        #expect(throws:(any Error).self) { try MediaPreparedCompounds.selection(clipIDs:[UUID()],in:document) }
        #expect(throws:(any Error).self) { try MediaPreparedCompounds.selection(clipIDs:[visual.id,above.id],in:document) }
        #expect(try MediaPreparedCompounds.selection(clipIDs:[visual.id,other.id,above.id],in:document).clipIDs.count == 3)
    }
}
