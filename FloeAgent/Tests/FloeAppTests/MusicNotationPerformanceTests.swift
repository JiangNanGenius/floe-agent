// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import SwiftUI
import UIKit
import XCTest
import FloeCore
import FloeHeavyEditorSupport
import FloeMusicCore
import FloeMusicNative
@testable import FloeApp

/// App-host coverage: real mounted score, AudioKit WAVs and the production
/// MusicProjectSession import/store path. No fake renderer or commit is used.
@MainActor final class MusicNotationPerformanceTests: XCTestCase {
    @MainActor private final class Mounted {
        let session: MusicProjectSession
        let notation: MusicNotationSession
        let controller: HeavyEditorController
        let window: UIWindow
        init(session: MusicProjectSession, notation: MusicNotationSession,
             controller: HeavyEditorController, window: UIWindow) {
            self.session = session; self.notation = notation; self.controller = controller; self.window = window
        }
        func close() async {
            notation.arrangement.cancel(); controller.cancel(); notation.stopAudio()
            await controller.endPresentation()
            window.isHidden = true; window.rootViewController = nil
        }
    }
    @MainActor private final class ContinuationGate {
        let arrangement: MusicNotationArrangement
        let initialWAV: URL?
        var reached = false
        var release = false
        var revoked = false
        init(_ arrangement: MusicNotationArrangement) { self.arrangement = arrangement; initialWAV = arrangement.recoverableWAV }
        func authorize(_ request: HeavyEditorAccessRequest) async throws {
            guard request.command == "score.playback.arrange" else { return }
            if let completed = arrangement.recoverableWAV, completed != initialWAV {
                reached = true
                while !release { try await Task.sleep(for: .milliseconds(10)) }
            }
            if revoked { throw CancellationError() }
        }
    }
    private func wait(_ reason: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), reason)
        guard condition() else { throw HeavyEditorError.unavailable }
    }
    private func mount(_ session: MusicProjectSession) async throws -> Mounted {
        let host = UIHostingController(rootView: MusicNotationWorkbench(session: session, onAssistant: {}, onClose: {}))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: -2_000, y: 0, width: 1_120, height: 720))
        window.frame = CGRect(x: -2_000, y: 0, width: 1_120, height: 720)
        window.rootViewController = host; window.isHidden = false
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        do {
            try await wait("Production score did not publish its controller") { session.notation?.controller != nil }
            let notation = try XCTUnwrap(session.notation), controller = try XCTUnwrap(notation.controller)
            try await wait("Production score WKWebView was never mounted") {
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                return controller.webView.window === window && controller.webView.bounds.width > 0
            }
            try await controller.waitUntilReady()
            return Mounted(session: session, notation: notation, controller: controller, window: window)
        } catch { window.isHidden = true; window.rootViewController = nil; throw error }
    }
    private func fixture() async throws -> Mounted {
        let record = try await PersonalContentService.shared.create(kind: .music, title: "QA-ScorePerformance-" + UUID().uuidString)
        let location = try await PersonalContentService.shared.library().resolve(record.id)
        let session = try await MusicProjectSession.open(id: record.id, directory: location.url.appendingPathComponent("Music"), environment: FloeAgentApp.liveEnvironment)
        let evidence = XCTAttachment(string: "Owned score-performance fixture: \(record.id.uuidString)\n\(location.url.path)\nKeep for Root readback; delete only this ID through normal Library actions after UI acceptance.")
        evidence.name = "Owned score performance project"; evidence.lifetime = .keepAlways; add(evidence)
        let mounted = try await mount(session), controller = mounted.controller
        _ = try await controller.execute("score.project.template", arguments: .object(["template": .string("song"), "bars": .number(1)]), expectedRevision: controller.document.revision)
        let empty = try await controller.execute("score.playback.compile")
        let parts = empty["result"]["parts"].array
        XCTAssertEqual(parts.count, 2)
        for (index, part) in parts.enumerated() {
            let id = try XCTUnwrap(part["id"].string)
            _ = try await controller.execute("score.edit.insert", arguments: .object([
                "part": .string(id), "pitch": .string("C4"), "type": .string("half"),
                "voice": .number(1), "staff": .number(1), "mode": .string("replace")]), expectedRevision: controller.document.revision)
            _ = try await controller.execute("score.playback.timbre", arguments: .object(["part": .string(id), "preset": .number(index == 0 ? 2 : 14)]), expectedRevision: controller.document.revision)
        }
        try await controller.save()
        return mounted
    }
    private func compiled(_ controller: HeavyEditorController) async throws -> EditorJSON {
        try await controller.execute("score.playback.compile")["result"]
    }
    private func samples(_ file: URL) throws -> [Float] {
        let reader = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 32_768))
        try reader.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
    func testTwoPartRealSoundsWAVPlacementPersistenceAndUndo() async throws {
        let mounted = try await fixture(), session = mounted.session, controller = mounted.controller
        do {
            let base = session.document, score = controller.document, performance = try await compiled(controller)
            XCTAssertEqual(Set(performance["events"].array.compactMap { $0["nativePreset"].number }), Set([2, 14]))
            XCTAssertEqual(Set(performance["events"].array.compactMap { $0["pitch"].number }), Set([60]))
            let projection = try MusicNotationPerformance.document(performance, parent: base)
            XCTAssertEqual(Set(projection.tracks.compactMap { $0.instrument?.presetIndex }), Set([2, 14]))
            var audio: [[Float]] = []
            for preset in [2, 14] {
                guard case .object(var one) = performance else { throw HeavyEditorError.invalidDocument }
                one["events"] = .array(performance["events"].array.filter { $0["nativePreset"].number == Double(preset) })
                let document = try MusicNotationPerformance.document(.object(one), parent: base)
                let output = session.root.appendingPathComponent("Exports/sound-\(preset)-" + UUID().uuidString + ".wav")
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let lease = try MusicRenderLease(document: document, ownerToken: session.notationOwnerToken)
                let rendered = try await session.notationRenderer.render(document: document, sources: [], destination: output, lease: lease, tailFrames: 0)
                XCTAssertEqual(rendered.sha256, try MusicAudioPreparation.hashFile(output))
                audio.append(try samples(output))
            }
            XCTAssertEqual(audio[0].count, audio[1].count)
            XCTAssertGreaterThan(audio[0].reduce(0.0) { $0 + Double($1 * $1) }, 0.001)
            XCTAssertGreaterThan(audio[1].reduce(0.0) { $0 + Double($1 * $1) }, 0.001)
            XCTAssertGreaterThan(zip(audio[0], audio[1]).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) } / Double(audio[0].count), 0.001,
                                 "Identical notes using different actual native presets must produce different non-silent PCM")
            _ = try await controller.execute("score.playback.control", arguments: .object(["action": .string("start")]), expectedRevision: score.revision)
            _ = try await controller.execute("score.playback.control", arguments: .object(["action": .string("stop")]), expectedRevision: score.revision)
            XCTAssertEqual(session.document, base, "Ordinary Play must not add a track")
            session.playheadSeconds = 1.25
            let result = try await controller.execute("score.playback.arrange", arguments: .object(["musicRevision": .number(Double(base.revision))]), expectedRevision: score.revision)
            let receipt = try XCTUnwrap(mounted.notation.arrangement.lastReceipt)
            XCTAssertEqual(result["result"], try receipt.json())
            XCTAssertEqual(receipt.projectID, session.id); XCTAssertEqual(receipt.positionSeconds, 1.25)
            XCTAssertEqual(session.document.tracks.count, base.tracks.count + 1)
            let track = try XCTUnwrap(session.document.tracks.last), clip = try XCTUnwrap(track.clips.first)
            XCTAssertEqual(clip.offset.value, Int64(1.25 * Double(base.tempoMap.sampleRate)))
            XCTAssertEqual(receipt.trackIDs, [track.id.rawValue]); XCTAssertEqual(receipt.clipIDs, [clip.id.rawValue])
            let source = try mounted.notation.performanceFileURL(fileID: receipt.fileID)
            XCTAssertEqual(try MusicAudioPreparation.hashFile(source), receipt.sha256)
            let canonical = try await session.repository.resolvedURL(for: XCTUnwrap(session.document.assets.last))
            XCTAssertEqual(try MusicAudioPreparation.hashFile(canonical), receipt.sha256)
            XCTAssertGreaterThan(try AVAudioFile(forReading: canonical).length, 0)
            let disk = try NativeMusicRepository(root: session.root)
            let reopened = try await disk.load(projectID: session.document.id)
            XCTAssertEqual(reopened, session.document)
            let savedScore = try XCTUnwrap(MusicNotationPackage.readOriginal(root: session.root, parentID: session.id))
            XCTAssertEqual(savedScore.document, score, "Rendering must preserve the notation original")
            await session.undo()
            XCTAssertEqual(session.document.tracks, base.tracks)
            await session.undo(redo: true)
            XCTAssertEqual(session.document.tracks, reopened.tracks)
            let evidence = XCTAttachment(string: String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self))
            evidence.name = "Actual native WAV and persisted timeline receipt"; evidence.lifetime = .keepAlways; add(evidence)
            await mounted.close()
            session.notation = MusicNotationSession(parent: session)
            let fresh = try await mount(session)
            let restored = try await compiled(fresh.controller)
            XCTAssertEqual(Set(restored["events"].array.compactMap { $0["nativePreset"].number }), Set([2, 14]), "Per-part sounds must survive a fresh controller reading the saved original")
            await fresh.close()
        } catch { await mounted.close(); throw error }
    }
    func testCompletedWAVCancellationCASAndRevocationNeverInsertATrack() async throws {
        let mounted = try await fixture(), session = mounted.session, service = mounted.notation.arrangement
        do {
            let performance = try await compiled(mounted.controller)
            for boundary in ["cancel", "revision", "revoke"] {
                let before = session.document, revision = before.revision
                var fired = false
                do {
                    _ = try await service.run(performance: performance, scoreRevision: mounted.controller.document.revision,
                        musicRevision: revision, positionSeconds: 0.5, invocation: UUID(), validate: {
                            guard service.recoverableWAV != nil, !fired else { return }
                            fired = true
                            if boundary == "cancel" { service.cancel() }
                            if boundary == "revision" { try await session.apply([.setName("Concurrent arrangement change")], expectedRevision: revision) }
                            if boundary == "revoke" { throw CancellationError() }
                        })
                    XCTFail("A \(boundary) fence accepted a completed performance")
                } catch {}
                XCTAssertTrue(fired, "The fence must run after real WAV completion")
                XCTAssertEqual(session.document.tracks, before.tracks)
                XCTAssertEqual(session.document.assets, before.assets)
                XCTAssertNotNil(service.recoverableWAV)
                XCTAssertFalse(service.isBusy)
                if let kept = service.recoverableWAV { XCTAssertGreaterThan(try AVAudioFile(forReading: kept).length, 0) }
            }
            // The caller task changes while the real original authorization is
            // suspended. Its old native UUID may not resume into a commit.
            for revoke in [true, false] {
                let gate = ContinuationGate(service), before = session.document
                let operation = Task { @MainActor in
                    try await mounted.controller.execute("score.playback.arrange", arguments: .object(["musicRevision": .number(Double(before.revision))]),
                        expectedRevision: mounted.controller.document.revision, authorization: { request in try await gate.authorize(request) })
                }
                do {
                    try await wait("Native continuation did not reauthorize after its WAV completed") { gate.reached }
                    if revoke { gate.revoked = true } else { mounted.controller.cancel() }
                    gate.release = true
                    do { _ = try await operation.value; XCTFail("Old or revoked native continuation committed") } catch {}
                } catch { gate.release = true; operation.cancel(); _ = try? await operation.value; throw error }
                try await wait("Owned render must settle before admission is released") { !service.isBusy }
                XCTAssertEqual(session.document.tracks, before.tracks); XCTAssertEqual(session.document.assets, before.assets)
                XCTAssertNotNil(service.recoverableWAV)
            }
            await mounted.close()
        } catch { await mounted.close(); throw error }
    }
}
#endif
