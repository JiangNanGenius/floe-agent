// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
import AVFoundation
@testable import FloeWorkbench

@Suite(.serialized)
struct MediaVideoColorMatchTests {
    @Test func measuredLabTransferActuallyMatchesReferencePixelsAndMixZeroPreservesTarget() async throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let target = try gradient(shift: [0,0,0]), reference = try gradient(shift: [6,8,10])
        let targetURL = root.appendingPathComponent("target.png"), referenceURL = root.appendingPathComponent("reference.png")
        let targetBytes = try #require(WorkbenchPNG.encode(target)), referenceBytes = try #require(WorkbenchPNG.encode(reference))
        try targetBytes.write(to: targetURL);try referenceBytes.write(to: referenceURL)
        let service = MediaVideoColorMatchService(), targetID = UUID(), referenceID = UUID()
        let match = try await service.match(target: .init(assetID: targetID,assetRevision: 1,url: targetURL,kind: .image,expectedContentHash: nil,sourceSeconds: 0),
            reference: .init(assetID: referenceID,assetRevision: 1,url: referenceURL,kind: .image,expectedContentHash: nil,sourceSeconds: 0),referenceClipID: UUID())
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let output = try #require(context.createCGImage(match.apply(to: CIImage(cgImage: target)),from: CGRect(x: 0,y: 0,width: target.width,height: target.height),format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let measured = try MediaLabColorMath.moments(output), wanted = try MediaLabColorMath.moments(reference)
        let before = distance(match.target.moments.mean,wanted.mean), after = distance(measured.mean,wanted.mean)
        #expect(before > 10 && after < 2 && after < before*0.15)
        var identity = match;identity.mix = 0
        let unchanged = try #require(context.createCGImage(identity.apply(to: CIImage(cgImage: target)),from: CGRect(x: 0,y: 0,width: target.width,height: target.height),format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        #expect(distance(try MediaLabColorMath.moments(unchanged).mean,match.target.moments.mean)<0.5)
        #expect(try Data(contentsOf: targetURL) == targetBytes)
        #expect(try Data(contentsOf: referenceURL) == referenceBytes)
        try record("M49-target.png",targetBytes);try record("M49-reference.png",referenceBytes)
        try record("M49-matched.png",try #require(WorkbenchPNG.encode(output)))
        try record("M49-measured-Lab.json",try JSONSerialization.data(withJSONObject: ["beforeDistance":before,"afterDistance":after,
            "target":match.target.moments.mean,"reference":wanted.mean,"matched":measured.mean],options: [.prettyPrinted,.sortedKeys]))
    }

    @Test func sourceSamplingUsesSavedGradingMaskAndRealSourceHashAndCancellation() async throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let image = try gradient(shift: [0,20,0]), url = root.appendingPathComponent("source.png")
        let original = try #require(WorkbenchPNG.encode(image));try original.write(to: url)
        let service = MediaVideoColorMatchService(), id = UUID()
        let request = MediaVideoColorFrameRequest(assetID: id,assetRevision: 1,url: url,kind: .image,expectedContentHash: nil,
            sourceSeconds: 0,grade: .init(filterID: "CIPhotoEffectMono"),mask: .init(shapes: [.init(kind: .rectangle,points: [.init(x: 0,y: 0),.init(x: 0.5,y: 1)])]))
        let sample = try await service.sample(request)
        #expect(abs(sample.frame.moments.mean[1])<0.5 && abs(sample.frame.moments.mean[2])<0.5)
        #expect(sample.frame.moments.pixelCount < image.width*image.height*3/4)
        var wrong = request;wrong.expectedContentHash = String(repeating: "f",count: 64)
        await #expect(throws: (any Error).self) { try await service.sample(wrong) }
        let cancelled = PreparedVideoCancellation();cancelled.cancel()
        await #expect(throws: (any Error).self) { try await service.sample(request,cancellation: cancelled) }
        var malformed = sample.frame.moments;malformed.mean = []
        #expect(throws: (any Error).self) { try malformed.validate() }
        #expect(try Data(contentsOf: url) == original)
        var pinned = request;pinned.expectedContentHash = sample.frame.contentHash
        let modified = original+Data([0]);try modified.write(to: url)
        await #expect(throws: (any Error).self) { try await service.sample(pinned) }
        #expect(try Data(contentsOf: url) == modified)
    }

    @Test func generatedColorMatchExampleUsesARealReadableLockedReferenceAndReportsMissingPair() throws {
        let a = MediaAssetReference(kind: .image,relativePath: "target.png",originalName: "Target")
        let b = MediaAssetReference(kind: .image,relativePath: "reference.png",originalName: "Reference")
        var project = MediaProject(kind: .video,name: "Guide",canvas: .init(width: 128,height: 96,frameRate: 10));project.assets = [a,b]
        var doc = try MediaPreparedUpgrade.document(from: project)
        let empty = try MediaPreparedToolInputGuide.make(document: doc,implementedToolIDs: ["video.color-match"])
        #expect(empty.count == 1 && empty[0].inputJSON == nil && empty[0].unavailableReason != nil)
        let range = try MediaTimeRange(start: .seconds(0),duration: .seconds(1))
        let target = MediaPreparedClip(assetID: a.id,timelineRange: range,sourceRange: range)
        let reference = MediaPreparedClip(assetID: b.id,timelineRange: range,sourceRange: range)
        doc.trackGraph.tracks = [.init(kind: .visual,name: "Target",clips: [target]),.init(kind: .visual,name: "Reference",isLocked: true,clips: [reference])]
        let examples = try MediaPreparedToolInputGuide.make(document: doc,implementedToolIDs: ["video.color-match"])
        let json = try #require(examples.first?.inputJSON), fields = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String:Any])
        #expect(fields["objectID"] as? String == target.id.uuidString && fields["property"] as? String == reference.id.uuidString)
        #expect(fields["expectedRevision"] as? String == String(doc.revision))
    }

    @Test func nativeGradeMatchPersistsUndoAndPreviewMatchesActualMP4WithoutReferenceDependency() async throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("original.png"), referenceURL = root.appendingPathComponent("reference.png")
        let targetBytes = try #require(WorkbenchPNG.encode(gradient(shift: [0,0,0]))), referenceBytes = try #require(WorkbenchPNG.encode(gradient(shift: [6,8,10])))
        try targetBytes.write(to: targetURL);try referenceBytes.write(to: referenceURL)
        let source = MediaAssetReference(kind: .image,relativePath: "original.png",originalName: "Original"), reference = MediaAssetReference(kind: .image,relativePath: "reference.png",originalName: "Reference")
        let project = MediaProject(kind: .video,name: "Match",canvas: .init(width: 128,height: 96,frameRate: 10))
        let store = MediaProjectStore(directory: root.appendingPathComponent("store")), coordinator = MediaPreparedCoordinator(store: store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id: project.id)
        let range = try MediaTimeRange(start: .seconds(0),duration: .seconds(0.3)), track = MediaPreparedTrack(kind: .visual,name: "Shot")
        let clip = MediaPreparedClip(assetID: source.id,timelineRange: range,sourceRange: range)
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(source)),.init(action: .insertAsset(reference)),
            .init(action: .insertTrack(track: track,index: nil)),.init(action: .insertClip(trackID: track.id,clip: clip,index: nil))],to: project.id)
        let doc = try await coordinator.loadDocument(id: project.id), referenceClipID = UUID()
        let match = try await MediaVideoColorMatchService.shared.match(target: .init(assetID: source.id,assetRevision: doc.assetRevisions?[source.id] ?? 0,url: targetURL,kind: .image,expectedContentHash: nil,sourceSeconds: 0),
            reference: .init(assetID: reference.id,assetRevision: doc.assetRevisions?[reference.id] ?? 0,url: referenceURL,kind: .image,expectedContentHash: nil,sourceSeconds: 0),referenceClipID: referenceClipID)
        var next = try #require(doc.trackGraph.clip(id: clip.id)?.clip);next.videoGrade = .init(colorMatch: match)
        let commit = try await coordinator.applyUserOperations([.init(action: .replaceClip(trackID: track.id,clipID: clip.id,expectedRevision: next.revision,clip: next))],to: project.id)
        let reopened = try await MediaPreparedCoordinator(store: MediaProjectStore(directory: root.appendingPathComponent("store"))).loadDocument(id: project.id)
        #expect(reopened.trackGraph.clip(id: clip.id)?.clip.videoGrade?.colorMatch == match)
        // The source snapshot is sufficient; no live reference clip/asset is
        // required by rendering after a user has captured the look.
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(reopened,assetURLs: [source.id:targetURL],includeAudio: false)
        let settings = try PreparedVideoOutputSettings(width: 128,height: 96,frameRate: plan.frameRate)
        let rendered = try await PreparedVideoFrameRenderer().renderFrame(plan: plan,frameIndex: 0,settings: settings)
        #expect(distance(try MediaLabColorMath.moments(rendered.image).mean,match.reference.moments.mean)<2)
        let output = root.appendingPathComponent("M49-matched-export.mp4"), window = try PreparedVideoFrameWindow(range: .init(start: .init(seconds: 0,timescale: plan.timeScale),duration: plan.duration),frameRate: plan.frameRate)
        _ = try await PreparedVideoExporter().renderWindow(plan: plan,window: window,settings: settings,destination: output,overwrite: false,cancellation: .none,progress: { _ in })
        let decoded = try await AVAssetImageGenerator(asset: AVURLAsset(url: output)).image(at: .zero).image
        #expect(distance(try MediaLabColorMath.moments(decoded).mean,try MediaLabColorMath.moments(rendered.image).mean)<2)
        _ = try await coordinator.undoGroup(commit.groupID,in: project.id)
        #expect(try await coordinator.loadDocument(id: project.id).trackGraph.clip(id: clip.id)?.clip.videoGrade == nil)
        _ = try await coordinator.redoGroup(commit.groupID,in: project.id)
        #expect(try await coordinator.loadDocument(id: project.id).trackGraph.clip(id: clip.id)?.clip.videoGrade?.colorMatch == match)
        var stale = reopened;stale.assetRevisions?[source.id] = (doc.assetRevisions?[source.id] ?? 0)+1
        #expect(throws: (any Error).self) { try MediaPreparedVideoDocumentAdapter.resolve(stale,assetURLs: [source.id:targetURL],includeAudio: false) }
        #expect(try Data(contentsOf: targetURL) == targetBytes)
        try record(output.lastPathComponent,Data(contentsOf: output))
    }

    private func gradient(shift: [Double]) throws -> CGImage {
        let width = 128,height = 96
        var pixels = [UInt8]();pixels.reserveCapacity(width*height*4)
        for y in 0..<height { for x in 0..<width {
            let lab = [40+30*Double(x)/127+shift[0],-10+15*Double(y)/95+shift[1],-15+10*Double(x+y)/222+shift[2]]
            let rgb = MediaLabColorMath.linearRGB(lab: lab).map { UInt8((min(1,max(0,MediaLabColorMath.encodeSRGB($0)))*255).rounded()) }
            pixels.append(contentsOf: rgb);pixels.append(255)
        } }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("color-match-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true);return root
    }
    private func distance(_ a: [Double],_ b: [Double]) -> Double { sqrt(zip(a,b).reduce(0) { $0+pow($1.0-$1.1,2) }) }
    private func record(_ name: String,_ data: Data) throws {
        if let directory = ProcessInfo.processInfo.environment["FLOE_MEDIA_COLOR_MATCH_PRODUCTS"] {
            let root = URL(fileURLWithPath: directory);try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(name))
        }
    }
}
