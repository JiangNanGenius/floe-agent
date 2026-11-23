// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeVisualNovelRuntime

struct KirikiriGameSessionTests {
    @MainActor private func makeSession(engine: FakeKirikiriEngine,
                                        test: Test? = nil) throws -> (KirikiriGameSession, KirikiriSandbox, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-vn-session-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("title".utf8).write(to: source.appendingPathComponent("startup.tjs"))
        let sandbox = try KirikiriSandboxBuilder.stage(
            gameRoot: source,
            savesDirectory: base.appendingPathComponent("saves", isDirectory: true),
            workDirectory: base.appendingPathComponent("work", isDirectory: true))
        let session = KirikiriGameSession(api: engine.makeAPI(), sandbox: sandbox)
        return (session, sandbox, base)
    }

    @MainActor @Test func startPassesSandboxGameRoot() throws {
        let engine = FakeKirikiriEngine()
        let (session, _, base) = try makeSession(engine: engine)
        try session.start()
        #expect(engine.calls.contains { call in
            guard case .start(let root) = call.kind else { return false }
            return root == session.savesDirectory.deletingLastPathComponent()
                .appendingPathComponent("work/game").path
        })
        session.stop()
        try? FileManager.default.removeItem(at: base)
    }

    @MainActor @Test func tickDrivesFramesAndExit() throws {
        let engine = FakeKirikiriEngine()
        engine.tickResults = [1, 1, 0]
        let (session, _, base) = try makeSession(engine: engine)
        try session.start()
        #expect(session.tick() == true)
        #expect(session.tick() == true)
        #expect(session.tick() == false)
        #expect(session.phase == .finished)
        // A finished session ignores further ticks and input.
        #expect(session.tick() == false)
        session.pointerDown(x: 0.5, y: 0.5)
        #expect(!engine.calls.contains { $0.kind == .pointer(0, 0.5, 0.5, 0) })
        session.stop()
        try? FileManager.default.removeItem(at: base)
    }

    @MainActor @Test func frameBytesDecodeWithBGRAFlag() throws {
        let engine = FakeKirikiriEngine()
        var bytes = [UInt8](repeating: 0, count: KirikiriEngineAPI.FrameLayout.size)
        // serial at 24, blank at 32, format at 36.
        bytes.replaceSubrange(24..<32, with: [0x39, 0x30, 0, 0, 0, 0, 0, 0])
        bytes.replaceSubrange(32..<36, with: [1, 0, 0, 0])
        bytes.replaceSubrange(36..<40, with: [1, 0, 0, 0])
        engine.frameBytes = bytes
        let (session, _, base) = try makeSession(engine: engine)
        try session.start()
        session.tick()
        let frame = try #require(session.currentFrame())
        #expect(frame.serial == 0x3039)
        #expect(frame.isBlank)
        #expect(frame.isBGRA)
        session.stop()
        try? FileManager.default.removeItem(at: base)
    }

    @MainActor @Test func inputAndStopOrdering() throws {
        let engine = FakeKirikiriEngine()
        let (session, _, base) = try makeSession(engine: engine)
        try session.start()
        session.pointerDown(x: 0.25, y: 0.75)
        session.key(virtualKey: 0x0D, down: true)
        session.rightClick(x: 0.5, y: 0.5)
        session.stop()
        let expected: [FakeKirikiriEngine.RecordedCall.Kind] = [
            .pointer(0, 0.25, 0.75, 0),
            .key(0x0D, 1),
            .pointer(0, 0.5, 0.5, 1),
            .pointer(2, 0.5, 0.5, 1),
            .stop
        ]
        let recorded = engine.calls.map(\.kind)
        for kind in expected {
            #expect(recorded.contains(kind), "missing \(kind)")
        }
        // Double stop is a no-op.
        session.stop()
        #expect(engine.calls.filter { $0.kind == .stop }.count == 1)
        try? FileManager.default.removeItem(at: base)
    }

    @Test func loaderFailsClosedOutsideAppBundle() {
        // A bundle without the embedded framework produces a clear error and
        // never a partial table.
        #expect(throws: VisualNovelRuntimeError.self) {
            try KirikiriEngineLoader.load(bundle: .main)
        }
    }
}
