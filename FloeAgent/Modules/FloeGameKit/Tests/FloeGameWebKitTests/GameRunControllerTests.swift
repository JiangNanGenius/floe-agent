// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
#if os(iOS)
import UIKit
#endif
import FloeGameCore
import FloeGameWebKit

private actor ContextHost: GameRunContextHost {
    var context: GameProjectContext
    init(_ context: GameProjectContext) { self.context = context }
    func currentContext(for captured: GameProjectContext) -> GameProjectContext { context }
    func replace(_ value: GameProjectContext) { context = value }
}
private actor PreparationHost: GameWebRunPreparationHost {
    let output: GamePreparedWebRun
    var waiting = false
    var continuation: CheckedContinuation<GamePreparedWebRun, any Error>?
    init(_ output: GamePreparedWebRun) { self.output = output }
    func prepare(_ request: GameWebRunRequest) async throws -> GamePreparedWebRun {
        try await withCheckedThrowingContinuation { continuation in self.continuation = continuation; waiting = true }
    }
    func cancel(_ request: GameWebRunRequest) {
        let pending = continuation; continuation = nil; pending?.resume(throwing: CancellationError())
    }
    func finish() { let pending = continuation; continuation = nil; pending?.resume(returning: output) }
    func waitUntilStarted() async throws {
        for _ in 0..<100 { if waiting { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw GameProjectError.invalidContext
    }
}

@MainActor final class GameRunControllerTests: XCTestCase {
    func testCallerRequestIDKeepsStopScopedAndRejectsDuplicateLaunch() async throws {
        let (root, context, package) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let host = PreparationHost(package), controller = GameProjectRunController(contexts: ContextHost(context), preparation: host)
        let id = UUID(), task = Task { try await controller.run(context: context, engine: .phaser, requestID: id) }
        try await host.waitUntilStarted()
        XCTAssertEqual(controller.activeRunID, id)
        let foreignStopped = await controller.stop(runID: UUID())
        XCTAssertFalse(foreignStopped)
        XCTAssertEqual(controller.activeRunID, id)
        do { try await controller.run(context: context, engine: .phaser, requestID: id); XCTFail("duplicate ID") }
        catch GameWebPlayerError.staleRun { }
        let stopped = await controller.stop(runID: id)
        XCTAssertTrue(stopped)
        do { try await task.value; XCTFail("cancelled preparation") } catch is CancellationError { }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.player)
    }

    private func fixture(html: String = "<html><p>Contract fixture</p></html>") throws -> (URL, GameProjectContext, GamePreparedWebRun) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: source.appendingPathComponent("index.html"))
        try Data(#"{"dependencies":{"phaser":"3.90.0"}}"#.utf8).write(to: source.appendingPathComponent("package.json"))
        let id = UUID(), context = try GameProjectContext(projectID: id, owner: .space(recordID: id), rootURL: source, savedRevision: "r1", environmentID: "existing-linux")
        let package = try GameWebArtifactPackage.build(source: context, engine: .phaser, entry: GameRelativePath("index.html"), to: root.appendingPathComponent("artifact"))
        return (root, context, .init(inspection: try GameProjectInspector().inspect(context: context), package: package))
    }
    #if os(iOS)
    func testChatScreenshotCapturesPaintedPixelsWithoutPresentingTheGame() async throws {
        let html = """
        <html><body style="margin:0"><canvas width="800" height="600"></canvas><script>
        const c = document.querySelector('canvas').getContext('2d');
        c.fillStyle = '#d32640'; c.fillRect(0,0,800,600);
        </script></body></html>
        """
        let (root, context, prepared) = try fixture(html: html)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PreparationHost(prepared)
        let controller = GameProjectRunController(contexts: ContextHost(context), preparation: host)
        let task = Task { try await controller.run(context: context, engine: .phaser) }
        try await host.waitUntilStarted()
        await host.finish()
        try await task.value
        let player = try XCTUnwrap(controller.player)
        XCTAssertNil(player.webView.window)
        for _ in 0..<200 where !player.loaded { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(player.loaded)
        // A busy game renderer may take longer than the input-command budget
        // to service the next WebKit snapshot request during scene creation.
        player.webView.evaluateJavaScript("const until = performance.now() + 4500; while (performance.now() < until) {}", completionHandler: nil)
        let data = try await player.capturePNG()
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { buffer in
            let ctx = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(rgba[0], 170)
        XCTAssertLessThan(rgba[1], 80)
        XCTAssertLessThan(rgba[2], 110)
        _ = await controller.stop()
    }
    #endif

    func testStopCancelsOwnedPreparationAndCannotStartAPlayerLater() async throws {
        let (root, context, package) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let host = PreparationHost(package), controller = GameProjectRunController(contexts: ContextHost(context), preparation: host)
        let task = Task { try await controller.run(context: context, engine: .phaser) }
        try await host.waitUntilStarted()
        let stopped = await controller.stop(); XCTAssertTrue(stopped)
        do { try await task.value; XCTFail("Expected cancelled preparation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(controller.phase, .idle); XCTAssertNil(controller.player); XCTAssertNil(controller.context)
    }
    func testRevisionDriftDuringBuildRejectsArtifactBeforeWebKitLaunch() async throws {
        let (root, context, package) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let host = PreparationHost(package), contexts = ContextHost(context)
        let controller = GameProjectRunController(contexts: contexts, preparation: host)
        let task = Task { try await controller.run(context: context, engine: .phaser) }
        try await host.waitUntilStarted()
        try await contexts.replace(GameProjectContext(projectID: context.projectID, owner: context.owner, rootURL: context.rootURL, savedRevision: "r2", environmentID: context.environmentID))
        await host.finish()
        do { try await task.value; XCTFail("Expected stale artifact") } catch { XCTAssertEqual(error as? GameProjectError, .contextChanged(.revision)) }
        XCTAssertNil(controller.player)
        guard case .failed = controller.phase else { return XCTFail("Expected actionable failed state") }
    }
}
