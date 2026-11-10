// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import AVFoundation
import CoreML
import Testing
import FloeCore
import FloeMedia
import FloeSecurity
import FloeWorkbench
@testable import FloeApp

private enum StemBoundaryFailure:Error { case forcedStore,forcedDelete,unexpectedProvider }
/// Synthetic-only isolated vault: never constructs or calls a real KeychainStore.
private final class StemBoundaryKeychain:KeychainProbeStore,@unchecked Sendable {
    private struct State { var values:[String:Data]=[:];var failStore=false;var failDelete=false;var stores=0;var deletes=0 }
    private let lock=NSLock()
    private var state:State
    init(seed:Data,account:String) { state=State(values:[account:seed]) }
    func failures(store:Bool=false,delete:Bool=false) { lock.withLock { state.failStore=store;state.failDelete=delete } }
    var storeAttempts:Int { lock.withLock{state.stores} }
    var deleteAttempts:Int { lock.withLock{state.deletes} }
    func store(account:String,secret:Data) throws { try lock.withLock { state.stores += 1;if state.failStore { throw StemBoundaryFailure.forcedStore };state.values[account]=secret } }
    func read(account:String) throws -> Data { try lock.withLock { guard let value=state.values[account] else { throw KeychainStoreError.itemNotFound };return value } }
    func delete(account:String) throws { try lock.withLock { state.deletes += 1;if state.failDelete { throw StemBoundaryFailure.forcedDelete };state.values.removeValue(forKey:account) } }
}
private actor StemBoundaryTransport:MusicAIStemHTTPTransport {
    private(set) var requests=0
    private(set) var credentialReads=0
    func credential() -> String { credentialReads += 1;return "unit-only-never-a-provider-secret" }
    func send(_ request:MusicAIStemHTTPRequest,work:AudioPCMWork) async throws -> MusicAIStemHTTPResponse { requests += 1;throw StemBoundaryFailure.unexpectedProvider }
}

@Suite("M55 credential transaction and visual-route authority",.serialized)
@MainActor struct MediaVoiceSeparationBoundaryTests {
    @Test func blankAndFailedCredentialUpdatePreserveStoredKeyAndPersistedProfile() throws {
        let suite="m55-update-\(UUID())",defaults=try #require(UserDefaults(suiteName:suite));defer { defaults.removePersistentDomain(forName:suite) }
        let old="unit-old-key",next="unit-new-key",vault=StemBoundaryKeychain(seed:Data(old.utf8),account:MusicAIStemSettingsStore.credentialAccountName)
        let settings=MusicAIStemSettingsStore(defaults:defaults,keychain:vault)
        settings.setEnabled(true);try settings.setBaseURL("https://example.invalid/v1");try settings.setWorkflow("unit/stems")
        let before=try #require(defaults.data(forKey:MusicAIStemSettingsStore.defaultsKey))
        #expect(settings.hasCredential && settings.isReady)
        do { try settings.setCredential(" \n ");Issue.record("Blank form removed/replaced a saved key") } catch { }
        #expect(vault.storeAttempts == 0 && vault.deleteAttempts == 0)
        #expect(settings.hasCredential && settings.currentCredential() == old)
        vault.failures(store:true)
        do { try settings.setCredential(next);Issue.record("Forced Keychain update failure was swallowed") } catch StemBoundaryFailure.forcedStore { }
        #expect(settings.hasCredential && settings.currentCredential() == old)
        #expect(defaults.data(forKey:MusicAIStemSettingsStore.defaultsKey) == before)
        let reopened=MusicAIStemSettingsStore(defaults:defaults,keychain:vault)
        #expect(reopened.hasCredential && reopened.currentCredential() == old && reopened.enabled)
        vault.failures();try settings.setCredential("  \(next)  ")
        #expect(settings.hasCredential && settings.currentCredential() == next && vault.deleteAttempts == 0)
        #expect(defaults.data(forKey:MusicAIStemSettingsStore.defaultsKey) == before)
        #expect(before.range(of:Data(old.utf8)) == nil && before.range(of:Data(next.utf8)) == nil)
    }
    @Test func explicitCredentialDeleteFailurePreservesReadyStateUntilConfirmedVaultSuccess() throws {
        let suite="m55-delete-\(UUID())",defaults=try #require(UserDefaults(suiteName:suite));defer { defaults.removePersistentDomain(forName:suite) }
        let vault=StemBoundaryKeychain(seed:Data("unit-existing-key".utf8),account:MusicAIStemSettingsStore.credentialAccountName),settings=MusicAIStemSettingsStore(defaults:defaults,keychain:vault)
        settings.setEnabled(true);let before=try #require(defaults.data(forKey:MusicAIStemSettingsStore.defaultsKey))
        vault.failures(delete:true)
        do { try settings.setCredential(nil);Issue.record("Forced Keychain delete failure was swallowed") } catch StemBoundaryFailure.forcedDelete { }
        #expect(settings.hasCredential && settings.isReady && settings.currentCredential() == "unit-existing-key")
        let reopened=MusicAIStemSettingsStore(defaults:defaults,keychain:vault)
        #expect(reopened.hasCredential && reopened.isReady)
        #expect(defaults.data(forKey:MusicAIStemSettingsStore.defaultsKey) == before)
        vault.failures();try settings.setCredential(nil)
        #expect(!settings.hasCredential && !settings.isReady && settings.currentCredential() == nil)
        #expect(settings.enabled && defaults.data(forKey:MusicAIStemSettingsStore.defaultsKey) == before)
        #expect(vault.deleteAttempts == 2 && vault.storeAttempts == 0)
    }
    enum GateCase:String,CaseIterable,Sendable { case missingWithoutExtractedAudio,missingWithExistingAudio,staleInputRevision,staleSavedAuthority }
    @MainActor private final class Calls {
        var factories=0
        let transport=StemBoundaryTransport()
        func makeAPI() throws -> MusicAIStemAPI {
            factories += 1
            let transport=self.transport
            return try MusicAIStemAPI(configuration:.init(baseURL:URL(string:"https://example.invalid/v1")!),transport:transport,credential:{ await transport.credential() })
        }
        var handlers:MediaV2ProviderBridge.Handlers {
            .init(available:{[.stemSeparation]},imageRoutes:{[]},editImage:{_,_ in throw StemBoundaryFailure.unexpectedProvider},transcribeFile:{_,_ in throw StemBoundaryFailure.unexpectedProvider},translateCaptions:{_,_,_ in throw StemBoundaryFailure.unexpectedProvider},voiceSeparation:.init(makeAPI:{[self] in try makeAPI()}))
        }
    }
    @MainActor private struct Fixture { let root:URL;let store:MediaProjectStore;let session:MediaV2Session;let visualID:UUID;let audioID:UUID? }
    private func fixture(linked:Bool) async throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("m55-visual-gate-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        let wav=root.appendingPathComponent("Assets/source.wav"),format=try #require(AVAudioFormat(standardFormatWithSampleRate:48_000,channels:1))
        let pcm=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:19_200));pcm.frameLength=19_200
        for i in 0..<19_200 { pcm.floatChannelData![0][i]=Float(0.2*sin(2 * Double.pi * 440 * Double(i)/48_000)) }
        do { let file=try AVAudioFile(forWriting:wav,settings:format.settings);try file.write(from:pcm) }
        let range=try PreparedVideoTimeRange(startSeconds:0,durationSeconds:0.4,timescale:90_000),audioAssetID=UUID(),rate=try PreparedVideoFrameRate(numerator:10,denominator:1)
        let plan=try PreparedVideoPlan(id:.init(projectID:UUID(),revision:0),timeScale:90_000,frameRate:rate,duration:range.duration,canvas:.init(width:64,height:48),assets:[.init(id:audioAssetID,url:wav,kind:.audio,duration:range.duration)],visualTracks:[.init(id:UUID(),name:"Actual video source",clips:[.init(id:UUID(),content:.graphic(.init(shape:.rectangle,width:0.8,height:0.8,fillColor:.init(hex:"#884422"))),timelineRange:range)])],audio:.init(tracks:[.init(id:UUID(),name:"Actual source sound",clips:[.init(id:UUID(),assetID:audioAssetID,timelineRange:range,sourceRange:range)])],tailSeconds:0))
        let video=root.appendingPathComponent("Assets/source.mp4")
        _ = try await PreparedVideoExporter().renderWindow(plan:plan,window:.init(range:range,frameRate:rate),settings:.init(width:64,height:48,frameRate:rate),destination:video,overwrite:false,cancellation:.none,progress:{_ in})
        #expect(try await AVURLAsset(url:video).loadTracks(withMediaType:.audio).count == 1)
        let project=MediaProject(kind:.video,name:"Visual voice separation boundary",canvas:.init(width:64,height:48,frameRate:10))
        let store=MediaProjectStore(directory:root.appendingPathComponent("Projects")),coordinator=MediaPreparedCoordinator(store:store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let v=MediaAssetReference(kind:.video,relativePath:"Assets/source.mp4",originalName:"Original.mp4",byteCount:Int64(try Data(contentsOf:video).count),contentHash:try FloeDigest.sha256Hex(ofFileAt:video),metadata:.init(width:64,height:48,durationSeconds:0.4,frameRate:10,audioTracks:1))
        let audio=MediaAssetReference(kind:.audio,relativePath:"Assets/source.wav",originalName:"Original.wav",byteCount:Int64(try Data(contentsOf:wav).count),contentHash:try FloeDigest.sha256Hex(ofFileAt:wav),metadata:.init(durationSeconds:0.4,audioTracks:1))
        let clipRange=try MediaTimeRange(start:.seconds(0),duration:.seconds(0.4)),visual=MediaPreparedClip(assetID:v.id,timelineRange:clipRange,sourceRange:clipRange,isMuted:linked)
        var operations:[MediaPreparedOperation]=[.init(action:.insertAsset(v)),.init(action:.insertTrack(track:.init(kind:.visual,name:"Original video",clips:[visual]),index:nil))]
        let sound=MediaPreparedClip(assetID:audio.id,timelineRange:clipRange,sourceRange:clipRange,sourceVisualClipID:visual.id)
        if linked { operations += [.init(action:.insertAsset(audio)),.init(action:.insertTrack(track:.init(kind:.audio,name:"Explicit source audio",clips:[sound]),index:nil))] }
        _ = try await coordinator.applyUserOperations(operations,to:project.id)
        let saved=try #require(try await store.loadProject(id:project.id)),session=MediaV2Session(project:saved,root:root,store:store,coordinator:coordinator)
        return .init(root:root,store:store,session:session,visualID:visual.id,audioID:linked ? sound.id:nil)
    }
    private func fileHashes(_ root:URL) throws -> [String:String] {
        let files=try #require(FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey]))
        var result:[String:String]=[:]
        for case let url as URL in files where (try url.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile == true { result[String(url.path.dropFirst(root.path.count+1))]=try FloeDigest.sha256Hex(ofFileAt:url) }
        return result
    }
    @Test(arguments:GateCase.allCases) func modelVisualVoiceRouteCannotEditOrContactProviderBeforeCurrentAuthority(_ gate:GateCase) async throws {
        let f=try await fixture(linked:gate != .missingWithoutExtractedAudio);defer { f.session.stopPlayback();try? FileManager.default.removeItem(at:f.root) }
        let current=f.session.document.revision,calls=Calls()
        // Exercise the actual concrete API factory type, with a no-network
        // transport and synthetic credential; construction sends nothing.
        let typedAPI:MusicAIStemAPI=try calls.makeAPI();#expect(typedAPI.configuration.baseURL.host == "example.invalid");calls.factories=0
        var authority:MediaV2ProviderAuthority?
        if gate == .staleInputRevision || gate == .staleSavedAuthority { authority=try await .userAction(session:f.session,capability:.stemSeparation) }
        var input=MediaV2ToolInput();input.objectID=f.visualID;input.expectedRevision=gate == .staleInputRevision ? current-1:current;input.voiceSeparation = .init(mode:.musicAI)
        if gate == .staleSavedAuthority {
            let audioID=try #require(f.audioID),located=try #require(f.session.document.trackGraph.clip(id:audioID));var changed=located.clip;changed.volume=0.75
            let other=MediaPreparedCoordinator(store:MediaProjectStore(directory:URL(fileURLWithPath:f.store.storeRootPath,isDirectory:true)))
            _ = try await other.applyUserOperations([.init(action:.replaceClip(trackID:located.track.id,clipID:audioID,expectedRevision:located.clip.revision,clip:changed))],to:f.session.id)
            #expect(f.session.document.revision == current)
        }
        let before=try fileHashes(f.root),stored=try #require(try await f.store.loadProject(id:f.session.id))
        try await MediaV2ProviderBridge.withTemporaryHandlers(calls.handlers) {
            do { _ = try await f.session.performTool("video.voice-separate",input:input,actor:.model,providerAuthority:authority);Issue.record("Visual voice separation bypassed native authority/revision") }
            catch MediaPreparedCoreError.invalidOperation(_) { #expect(gate == .missingWithoutExtractedAudio || gate == .missingWithExistingAudio) }
            catch MediaPreparedCoreError.documentChanged { #expect(gate == .staleInputRevision || gate == .staleSavedAuthority) }
            #expect(calls.factories == 0 && !f.session.processingTool && !f.session.saving)
            let requests=await calls.transport.requests,credentials=await calls.transport.credentialReads
            #expect(requests == 0 && credentials == 0)
            #expect(try fileHashes(f.root) == before)
            let after=try #require(try await f.store.loadProject(id:f.session.id))
            #expect(after.id == stored.id && after.revision == stored.revision)
            #expect(after.prepared == stored.prepared && after.preparedJournal == stored.preparedJournal)
        }
    }
    @Test func actualLocalModelRunsThroughAppSessionAndSavesBothStemsWithUndo() async throws {
        // The linear fixture proves actual App->model store->Core ML->WAV->
        // original/undo wiring, without claiming trained separation quality.
        let f = try await fixture(linked: true)
        defer { f.session.stopPlayback(); try? FileManager.default.removeItem(at: f.root) }
        let targetID = try #require(f.audioID)
        let original = try #require(f.session.document.trackGraph.clip(id: targetID)?.clip)
        let source = f.root.appendingPathComponent("Assets/source.wav")
        let originalBytes = try Data(contentsOf: source)
        let beforeAssetIDs = Set(f.session.document.assets.map(\.id))
        let beforeTrackIDs = Set(f.session.document.trackGraph.tracks.map(\.id))
        let store = ModelArtifactStore(rootURL: f.root.appendingPathComponent("ModelStore")) { _, _ in
            throw CocoaError(.fileReadNoPermission) // A local import must never download.
        }
        let modelFolder = f.root.appendingPathComponent("SyntheticModel")
        let bundle = try await Task.detached {
            try AppStemLinearFixture.bundle(at: modelFolder, id: "test.app.audio.stems")
        }.value
        try await MediaV2StemLocalBridge.withTemporaryHandlers(MediaV2StemLocalInstaller.handlers(store: store)) {
            let installed = try await MediaV2StemLocalBridge.importBundle(bundle.0)
            #expect(installed.id == bundle.1.id)
            var input = MediaV2ToolInput()
            input.expectedRevision = f.session.document.revision
            input.objectID = targetID
            input.voiceSeparation = .init(mode: .localModel, modelID: installed.id)
            let receipt = try await f.session.performTool("video.voice-separate", input: input)
            #expect(receipt.voiceSeparation?.modelID == installed.id)
            #expect(!f.session.processingTool && !f.session.saving)
            let freshStore = MediaProjectStore(directory: f.root.appendingPathComponent("Projects"))
            let reopened = try #require(try await freshStore.loadProject(id: f.session.id)?.prepared)
            #expect(reopened.trackGraph.clip(id: targetID)?.clip.isMuted == true)
            let added = reopened.assets.filter { !beforeAssetIDs.contains($0.id) }
            let tracks = reopened.trackGraph.tracks.filter { !beforeTrackIDs.contains($0.id) }
            try #require(added.count == 2 && tracks.count == 2)
            func sample(_ url: URL) throws -> Float {
                let file = try AVAudioFile(forReading: url)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 128))
                try file.read(into: buffer, frameCount: 128)
                try #require(buffer.frameLength == 128)
                return try #require(buffer.floatChannelData).pointee[64]
            }
            let inputSample = try sample(source)
            try #require(abs(inputSample) > 0.01)
            var gains = [Float]()
            for asset in added {
                let url = f.root.appendingPathComponent(asset.relativePath)
                #expect(try FloeDigest.sha256Hex(ofFileAt: url) == asset.contentHash)
                let file = try AVAudioFile(forReading: url)
                #expect(file.length == 19_200 && file.processingFormat.sampleRate == 48_000)
                gains.append(try sample(url) / inputSample)
            }
            gains.sort()
            #expect(abs(gains[0] - 0.25) < 0.0001 && abs(gains[1] - 0.75) < 0.0001)
            for track in tracks {
                let clip = try #require(track.clips.first)
                #expect(clip.timelineRange == original.timelineRange && clip.sourcePlayback == original.sourcePlayback)
            }
            #expect(try Data(contentsOf: source) == originalBytes)
            let group = try #require(receipt.groupID)
            _ = try await f.session.coordinator.undoGroup(group, in: f.session.id)
            try await f.session.reload()
            #expect(f.session.document.trackGraph.clip(id: targetID)?.clip.isMuted == false)
            #expect(Set(f.session.document.trackGraph.tracks.map(\.id)) == beforeTrackIDs)
            _ = try await f.session.coordinator.redoGroup(group, in: f.session.id)
            try await f.session.reload()
            #expect(f.session.document.trackGraph.tracks.count == beforeTrackIDs.count + 2)
            #expect(try Data(contentsOf: source) == originalBytes)
        }
    }

}
private enum AppStemLinearFixture {
    private static func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        while value > 127 { result.append(UInt8(value & 127) | 128); value >>= 7 }
        result.append(UInt8(value)); return result
    }
    private static func integer(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    private static func message(_ field: Int, _ data: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(data.count)) + data }
    private static func string(_ field: Int, _ value: String) -> Data { message(field, Data(value.utf8)) }
    private static func float(_ field: Int, _ value: Float) -> Data {
        var bits = value.bitPattern.littleEndian
        return varint(UInt64(field << 3 | 5)) + withUnsafeBytes(of: &bits) { Data($0) }
    }
    private static func feature(_ name: String) -> Data {
        let array = integer(1, 1) + integer(1, 2) + integer(1, 1_024) + integer(2, 65_568)
        return string(1, name) + message(3, message(5, array))
    }
    private static func layer(_ name: String, _ gain: Float) -> Data {
        string(1, name + "-linear") + string(2, "audio") + string(3, name) + message(130, message(5, float(1, gain)))
    }
    private static func digest(_ data: Data) -> String { FloeDigest.sha256Hex(data) }
    static func bundle(at folder: URL, id: String = "test.audio.stems") throws -> (URL, AudioStemModelContract) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = integer(1, 4) + message(2, message(1, feature("audio")) + message(10, feature("voice")) + message(10, feature("music")))
            + message(500, message(1, layer("voice", 0.25)) + message(1, layer("music", 0.75)) + integer(5, 1))
        let original = folder.appendingPathComponent("linear-test.mlmodel")
        try model.write(to: original)
        let compiled = try MLModel.compileModel(at: original)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let root = folder.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: compiled, to: root.appendingPathComponent("model.mlmodelc"))
        let contract = AudioStemModelContract(id: id, version: "1.0.0", sampleRate: 48_000, channelCount: 2,
            chunkFrames: 1_024, overlapFrames: 128, input: .init(name: "audio"), vocals: .init(name: "voice"), accompaniment: .init(name: "music"),
            license: "Task-authored synthetic linear fixture; no trained separation weights.", source: "https://github.com/apple/coremltools",
            qualityNotes: ["Synthetic 0.25/0.75 tensor fixture. Not trained and not evidence of voice isolation quality."])
        try JSONEncoder().encode(contract).write(to: root.appendingPathComponent("contract.json"))
        try Data(contract.license.utf8).write(to: root.appendingPathComponent("LICENSE.txt"))
        try Data(#"{"synthetic":true,"trained":false,"purpose":"actual CoreML tensor runtime contract"}"#.utf8).write(to: root.appendingPathComponent("PROVENANCE.json"))
        var rows = [[String: Any]]()
        let entries = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let path as URL in entries {
            if try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let relative = String(path.path.dropFirst(root.path.count + 1)), bytes = try Data(contentsOf: path)
                rows.append(["path": relative, "sha256": digest(bytes), "sizeBytes": bytes.count])
            }
        }
        let manifest: [String: Any] = ["id": contract.id, "version": contract.version, "capability": contract.capability,
            "license": contract.license, "files": rows.sorted { ($0["path"] as! String) < ($1["path"] as! String) }]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: root.appendingPathComponent("manifest.json"))
        return (root, contract)
    }
}

#endif
