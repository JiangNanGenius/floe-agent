// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit
import AVFoundation
import Testing
import FloeNotes
import FloeChemistryCore
import FloeMusicCore
@testable import FloeApp

@Suite("Real personal content previews", .serialized)
@MainActor struct PersonalContentPreviewTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalPreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
    private func png(_ color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        return try #require(image.pngData())
    }
    private func imageBytes(_ artifact: PersonalContentPreviewArtifact) throws -> Data {
        guard case .image(let bytes) = artifact.content else { throw PersonalContentPreviewError.unavailable }
        return bytes
    }

    @Test func actualImageCacheRejectsOldRevisionAndOriginalStaysUnchanged() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png"), original = try png(.red)
        try original.write(to: url)
        let service = PersonalContentPreviewService(maximumBytes: 1_024 * 1_024, maximumEntries: 2)
        let first = try await PersonalContentPreviewProducers.file(ownerID: root.lastPathComponent, objectID: "asset", revision: "1",
            root: root, url: url, maximumPixelSize: 96, validate: {})
        let result = try await service.preview(first)
        let bytes = try imageBytes(result), decoded = try #require(UIImage(data: bytes)?.cgImage)
        #expect(result.provenance == .originalImage && decoded.width == 96 && decoded.height <= 96)
        #expect(try Data(contentsOf: url) == original)
        #expect(try imageBytes(await service.preview(first)) == bytes)
        #expect(service.cachedEntryCount == 1)
        let replacement = try png(.blue); try replacement.write(to: url, options: .atomic)
        do { _ = try await service.preview(first); Issue.record("A stale request served a replaced original") }
        catch { #expect(error as? PersonalContentPreviewError == .sourceChanged) }
        let second = try await PersonalContentPreviewProducers.file(ownerID: root.lastPathComponent, objectID: "asset", revision: "2",
            root: root, url: url, maximumPixelSize: 96, validate: {})
        #expect(try imageBytes(await service.preview(second)) != bytes)
        #expect(service.cachedEntryCount == 1 && service.cachedByteCount <= 1_024 * 1_024)
        #expect(try Data(contentsOf: url) == replacement)
    }

    @Test func realPDFAndNotesPageReuseExistingRenderersWithoutEditingOriginal() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 240, height: 320)).pdfData { context in
            context.beginPage()
            ("Original first page" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let file = root.appendingPathComponent("original.pdf"); try pdf.write(to: file)
        let service = PersonalContentPreviewService()
        let request = try await PersonalContentPreviewProducers.file(ownerID: root.lastPathComponent, objectID: "pdf", revision: "1",
            root: root, url: file, maximumPixelSize: 160, validate: {})
        let result = try await service.preview(request)
        #expect(result.provenance == .pdfPage)
        #expect(try #require(UIImage(data: imageBytes(result))?.cgImage).height <= 160)
        #expect(try Data(contentsOf: file) == pdf)
        let store = try NotesStore(root: root.appendingPathComponent("Notes", isDirectory: true))
        var document = NoteDocument(title: "Original notebook")
        document.pages[0].elements = [.init(kind: .text, text: "A real Notes page")]
        document = try await store.create(document)
        let note = PersonalContentPreviewProducers.notes(document: document, store: store, ownerID: root.lastPathComponent, maximumPixelSize: 160)
        let noteResult = try await service.preview(note)
        #expect(noteResult.provenance == .notePage)
        #expect(UIImage(data: try imageBytes(noteResult)) != nil)
        let after = try await store.document(document.id)
        #expect(after == document)
    }

    @Test func actualMonoEightKHzAudioUsesSharedDecoderAndRealDuration() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mono.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_000))
            buffer.frameLength = 8_000
            let channel = try #require(buffer.floatChannelData?[0])
            for i in 0..<8_000 { channel[i] = Float(0.25 * sin(Double(i) * 2 * .pi * 400 / 8_000)) }
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: url)
        let request = try await PersonalContentPreviewProducers.file(ownerID: root.lastPathComponent, objectID: "audio", revision: "1",
            root: root, url: url, maximumPixelSize: 160, validate: {})
        let result = try await PersonalContentPreviewService().preview(request)
        guard case .waveform(let waveform) = result.content else { Issue.record("No actual waveform");return }
        #expect(result.provenance == .audioWaveform && waveform.channels.count == 1)
        #expect(abs(waveform.durationSeconds - 1) < 0.002 && waveform.startSeconds == 0)
        #expect(abs(waveform.endSeconds - 1) < 0.002)
        #expect(waveform.channels[0].minimum.count == 64 && waveform.channels[0].maximum.count == 64)
        #expect((waveform.channels[0].minimum.min() ?? 0) < -0.24 && (waveform.channels[0].maximum.max() ?? 0) > 0.24)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func lastSubscriberCancellationReturnsBeforeNonCooperativeProducerAndDropsLateImage() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png"); try png(.green).write(to: url)
        let genuine = try await PersonalContentPreviewProducers.file(ownerID: root.lastPathComponent, objectID: "late", revision: "1",
            root: root, url: url, maximumPixelSize: 96, validate: {})
        let service = PersonalContentPreviewService(maximumWorkers: 1)
        let hold = PreviewProducerHold()
        let held = PersonalContentPreviewRequest(key: genuine.key, validate: genuine.validate, produce: {
            let actual = try await genuine.produce(); await hold.wait(); return actual
        })
        let subscriber = Task { try await service.preview(held) }
        defer { subscriber.cancel(); hold.release() }
        for _ in 0..<100 where !hold.entered { try await Task.sleep(for: .milliseconds(50)) }
        try #require(hold.entered)
        subscriber.cancel()
        do { _ = try await subscriber.value; Issue.record("Cancelled subscriber received a late image") }
        catch { #expect(error is CancellationError) }
        #expect(service.cachedEntryCount == 0)
        let next = PersonalContentPreviewRequest(key: .init(ownerID: root.lastPathComponent, objectID: "next", revision: "1"),
            validate: genuine.validate, produce: genuine.produce)
        let queued = Task { try await service.preview(next) }
        hold.release()
        #expect(UIImage(data: try imageBytes(await queued.value)) != nil)
        #expect(service.cachedEntryCount == 1, "The abandoned original result must never enter the cache")
    }

    @Test func symlinkAssetCannotEscapeTheAuthorizedOriginalRoot() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeRoot(); defer { try? FileManager.default.removeItem(at: outside) }
        let original = outside.appendingPathComponent("outside.png"); try png(.yellow).write(to: original)
        let link = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        do {
            _ = try await PersonalContentPreviewProducers.file(ownerID: root.lastPathComponent, objectID: "link", revision: "1", root: root, url: link, validate: {})
            Issue.record("A linked source escaped the preview's original root")
        } catch { #expect(error as? PersonalContentPreviewError == .unavailable) }
    }

    @Test func realChemicalDrawingUsesItsBondsAndDoesNotInventMissingCoordinates() async throws {
        let ket = #"{"root":{"nodes":[{"$ref":"mol0"}]},"mol0":{"type":"molecule","atoms":[{"label":"C","location":[0,0,0]},{"label":"O","location":[1.4,0,0]}],"bonds":[{"type":1,"atoms":[0,1]}]}}"#
        let object = ChemicalObject(title: "C–O", format: "ket", source: ket)
        let drawing = try ChemicalDrawing2D(ket)
        #expect(drawing.atoms.count == 2 && drawing.bonds.count == 1)
        let request = PersonalContentPreviewProducers.chemical(object: object, ownerID: UUID().uuidString, maximumPixelSize: 160, validate: {})
        let result = try await PersonalContentPreviewService().preview(request)
        let chemicalImage = UIImage(data: try imageBytes(result))
        #expect(result.provenance == .chemicalDrawing && chemicalImage != nil)
        #expect(object.source == ket)
        let unprepared = ChemicalObject(title: "Unprepared bond graph", format: "smiles", source: "CO")
        let graph = PersonalContentPreviewProducers.chemical(object: unprepared, ownerID: UUID().uuidString, validate: {})
        do { _ = try await PersonalContentPreviewService().preview(graph); Issue.record("A graph without drawing coordinates was presented as a structure image") }
        catch { #expect(error as? PersonalContentPreviewError == .notPrepared) }
    }

    @Test func savedMusicPianoRollReadsNativeNotesWithoutRenderingAudioOrWritingDocument() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let content = PersonalContentService(root: root)
        let library = try await content.library(), id = UUID()
        let record = try await library.create(kind: .music, title: "Saved notes", id: id) { directory, id in
            let trackID = MusicTrackID()
            let notes = [try MusicMIDINote(pitch: 60, startTick: .init(0), durationTicks: 480, velocity: 90),
                         try MusicMIDINote(pitch: 67, startTick: .init(480), durationTicks: 480, velocity: 100)]
            let clip = try MusicClip(name: "Actual notes", trackID: trackID, offset: .init(0),
                body: .midi(.init(durationTicks: 960, notes: notes)))
            let track = try MusicTrack(id: trackID, name: "Piano", kind: .midi, clips: [clip])
            let document = try MusicDocument(id: .init(rawValue: id.uuidString.lowercased()), name: "Saved notes", tracks: [track])
            let repository = try NativeMusicRepository(root: directory.appendingPathComponent("Music"))
            _ = try await repository.save(document: document, expectedRevision: nil, fence: nil)
        }
        let location = try await library.resolve(id)
        let documentFile = location.url.appendingPathComponent("Music/documents/\(previewHash(Data(id.uuidString.lowercased().utf8))).json")
        let original = try Data(contentsOf: documentFile)
        let service = PersonalContentPreviewService()
        let request = try await service.request(for: record, contentService: content, maximumPixelSize: 160)
        let result = try await service.preview(request)
        let canvasImage = UIImage(data: try imageBytes(result))
        #expect(result.provenance == .moduleSnapshot && canvasImage != nil)
        #expect(result.detail?.contains("MIDI") == true)
        #expect(try Data(contentsOf: documentFile) == original)
        #expect(!FileManager.default.fileExists(atPath: location.url.appendingPathComponent("Music/Exports").path))
    }

    @Test func realSavedCanvasRendersItsCommittedTextWithoutChangingManifest() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let content = PersonalContentService(root: root)
        let record = try await content.createCanvas(template: nil, chinese: false, goal: "Real committed canvas text")
        let location = try await content.library().resolve(record.id)
        let manifest = location.url.appendingPathComponent("Canvas/canvases/\(record.id.uuidString)/manifest.json")
        let original = try Data(contentsOf: manifest)
        let service = PersonalContentPreviewService()
        let request = try await service.request(for: record, contentService: content, maximumPixelSize: 160)
        let result = try await service.preview(request)
        let savedCanvasImage = UIImage(data: try imageBytes(result))
        #expect(result.provenance == .moduleSnapshot && savedCanvasImage != nil)
        #expect(try Data(contentsOf: manifest) == original)
    }
}

@MainActor private final class PreviewProducerHold {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
