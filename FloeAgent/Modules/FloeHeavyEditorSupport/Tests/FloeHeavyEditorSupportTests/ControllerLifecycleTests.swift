#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import FloeHeavyEditorSupport

private enum ControllerQualificationError: Error { case deadline }

@MainActor
private final class ControllerTestResult<Value: Sendable> {
    var value: Result<Value, any Error>?
}

@MainActor
private struct ControllerFixture {
    let directory: URL
    let store: HeavyEditorProjectStore
    let controller: HeavyEditorController

    init() async throws {
        _ = NSApplication.shared
        let base = ProcessInfo.processInfo.environment["FLOE_RQ21_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let web = directory.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Self.html.write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let document = HeavyEditorDocument(kind: .gis, title: "RQ21 fixture", content: .object(["data": .object(["title": .string("RQ21 fixture"), "value": .number(0)])]))
        store = try HeavyEditorProjectStore(directory: directory, documentID: document.id, kind: .gis)
        try await store.create(document)
        let descriptor = HeavyEditorDescriptor(kind: .gis, title: "Fixture", symbol: "map", resourceRoot: web, projectExtension: "fixture", importExtensions: [])
        let hooks = HeavyEditorHostHooks(authorize: { _ in }, didSave: { _ in }, export: { _, _ in throw HeavyEditorError.invalidDocument })
        controller = try HeavyEditorController(descriptor: descriptor, document: document, store: store, owner: .qualification(document.id), hooks: hooks)
        try await controller.waitUntilReady(timeout: .seconds(10))
    }

    func close() {
        controller.cancel()
        controller.webView.stopLoading()
        try? FileManager.default.removeItem(at: directory)
    }

    static let html = #"""
    <!doctype html><meta charset="utf-8"><script>
    const entries = [
      {id:'append',access:'edit',fields:[]},
      {id:'block',access:'read',fields:[]},
      {id:'cooperative',access:'edit',fields:[]},
      {id:'uncooperative',access:'edit',fields:[]}
    ];
    window.pending = null;
    window.releaseActive = () => { const p=window.pending;window.pending=null;p?.resolve(); };
    window.FloeEditor = {
      commandIndex(){return entries},
      command(name){if(window.slowMetadata){const end=Date.now()+250;while(Date.now()<end){}}return entries.find(x=>x.id===name)},
      formDescription(name){if(window.throwOnForm)throw Error('form exploded');const entry=entries.find(x=>x.id===name);return {...entry,fields:[{key:'amount',label:'Amount',type:'number',default:1}]}},
      async setNativeChrome(){},
      async load(value){this.payload=structuredClone(value.content);this.revision=value.revision;return {ready:true}},
      nativeSnapshot(){return {value:this.payload.data.value}},
      async execute(request){
        if(request.revision!==this.revision)throw Error('revision conflict');
        if(request.command==='append')this.payload.data.value+=request.arguments.amount??1;
        else {
          if(request.command!=='block')this.payload.data.value=99;
          await new Promise((resolve,reject)=>window.pending={resolve,reject,kind:request.command});
          if(request.command!=='block')this.payload.data.value=100;
        }
        return {state:request.command==='block'?null:structuredClone(this.payload),result:{value:this.payload.data.value},artifacts:[]};
      },
      acknowledge(value){this.revision=value},
      cancel(){if(window.pending?.kind==='cooperative'){window.pending.reject(Error('Cancelled'));window.pending=null}},
      hostReply(){}
    };
    window.webkit.messageHandlers.floeEditor.postMessage({type:'ready'});
    </script>
    """#
}

@Suite("RQ21 actual WebKit controller lifecycle", .serialized)
@MainActor
struct ControllerLifecycleTests {
    private func start<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> Value) -> (Task<Void, Never>, ControllerTestResult<Value>) {
        let result = ControllerTestResult<Value>()
        let task = Task { @MainActor in
            do { result.value = .success(try await operation()) }
            catch { result.value = .failure(error) }
        }
        return (task, result)
    }

    private func until(timeout: Duration = .seconds(6), _ check: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: timeout)
        while !check() {
            guard ContinuousClock.now < end else { throw ControllerQualificationError.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func result<Value: Sendable>(_ captured: ControllerTestResult<Value>) async throws -> Result<Value, any Error> {
        try await until { captured.value != nil }
        return captured.value!
    }

    @Test("Actual queued cancellation cannot overtake a blocked WK command; remaining edit saves once")
    func queuedCancellationDoesNotOvertakeWebKit() async throws {
        let fixture = try await ControllerFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let (first, firstResult) = start { try await controller.execute("block", expectedRevision: 0) }
        defer { first.cancel(); controller.webView.evaluateJavaScript("window.releaseActive()", completionHandler: nil) }
        try await until { controller.operationPhase == .running }
        _ = try await controller.commandMetadata("block")
        let (middle, middleResult) = start { try await controller.execute("append", expectedRevision: 0) }
        let (last, lastResult) = start { try await controller.execute("append", expectedRevision: 0) }
        defer { middle.cancel(); last.cancel() }
        try await until { controller.queuedOperationCount == 2 }
        middle.cancel()
        if case .failure(let error) = try await result(middleResult) { #expect(error is CancellationError) }
        else { Issue.record("Cancelled queued edit succeeded") }
        #expect(lastResult.value == nil)
        #expect(try await fixture.store.read().revision == 0)
        controller.webView.evaluateJavaScript("window.releaseActive()", completionHandler: nil)
        _ = try await result(firstResult).get()
        _ = try await result(lastResult).get()
        #expect(try await fixture.store.read().revision == 1)
        #expect(try await fixture.store.read().content["data"]["value"] == .number(1))
    }

    @Test("Single-command describe waits for active work; cancellation never reads a late page")
    func describeWaitsForActiveWorkAndCancellation() async throws {
        let fixture = try await ControllerFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let (active, activeResult) = start { try await controller.execute("block", expectedRevision: 0) }
        defer { active.cancel(); controller.webView.evaluateJavaScript("window.releaseActive()", completionHandler: nil) }
        try await until { controller.operationPhase == .running }

        let (describe, describeResult) = start { try await controller.describe(command: "append") }
        // The old route threw unavailable immediately while another command
        // ran. The guarded route must still be waiting here.
        try await Task.sleep(for: .milliseconds(120))
        #expect(describeResult.value == nil)
        controller.webView.evaluateJavaScript("window.releaseActive()", completionHandler: nil)
        _ = try await result(activeResult).get()
        let form = try await result(describeResult).get()
        #expect(form["form"]["id"].string == "append")
        #expect(form["form"]["fields"].array.count == 1)
        #expect(controller.isReady)

        // A cancelled describe leaves the active command untouched and cannot
        // publish a result from a page read after cancellation.
        let (active2, active2Result) = start { try await controller.execute("block", expectedRevision: 0) }
        defer { active2.cancel(); controller.webView.evaluateJavaScript("window.releaseActive()", completionHandler: nil) }
        try await until { controller.operationPhase == .running }
        let (cancelled, cancelledResult) = start { try await controller.describe(command: "append") }
        try await Task.sleep(for: .milliseconds(80))
        cancelled.cancel()
        if case .failure(let error) = try await result(cancelledResult) { #expect(error is CancellationError) }
        else { Issue.record("Cancelled describe succeeded") }
        #expect(active2Result.value == nil)
        controller.webView.evaluateJavaScript("window.releaseActive()", completionHandler: nil)
        _ = try await result(active2Result).get()
        #expect(controller.isReady)
    }

    @Test("A bundled schema exception keeps its actual message")
    func schemaExceptionKeepsItsMessage() async throws {
        let fixture = try await ControllerFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.webView.evaluateJavaScript("window.throwOnForm=true", completionHandler: nil)
        do {
            _ = try await controller.describe(command: "append")
            Issue.record("schema exception unexpectedly succeeded")
        } catch let error as HeavyEditorError {
            guard case .engine(let message) = error else { Issue.record("expected engine, got \(error)"); return }
            #expect(message == "form exploded")
        }
    }

    @Test("Actual cooperative cancellation restores the saved original and allows a subsequent edit")
    func cooperativeCancellationRestoresOriginal() async throws {
        let fixture = try await ControllerFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let (running, output) = start { try await controller.execute("cooperative", expectedRevision: 0) }
        defer { running.cancel() }
        try await until { controller.operationPhase == .running }
        _ = try await controller.commandMetadata("cooperative")
        running.cancel()
        if case .failure(let error) = try await result(output) { #expect(error is CancellationError) }
        else { Issue.record("Cancelled active edit succeeded") }
        try await until { !controller.isWorking }
        #expect(controller.isReady)
        #expect(try await fixture.store.read().revision == 0)
        #expect(controller.presentation["value"] == .number(0))
        _ = try await controller.execute("append", expectedRevision: 0)
        #expect(try await fixture.store.read().content["data"]["value"] == .number(1))
        #expect(try await fixture.store.read().revision == 1)
    }

    @Test("Cancelling independent metadata discovery must not abort the active edit")
    func metadataCancellationDoesNotAbortAnotherOperation() async throws {
        let fixture = try await ControllerFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let (active, activeResult) = start { try await controller.execute("cooperative", expectedRevision: 0) }
        defer { active.cancel() }
        try await until { controller.operationPhase == .running }
        _ = try await controller.commandMetadata("cooperative")
        controller.webView.evaluateJavaScript("window.slowMetadata=true", completionHandler: nil)
        let (metadata, metadataResult) = start { try await controller.commandMetadata("append") }
        defer { metadata.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        metadata.cancel()
        if case .failure(let error) = try await result(metadataResult) { #expect(error is CancellationError) }
        else { Issue.record("Cancelled metadata call succeeded") }
        try await Task.sleep(for: .milliseconds(350))
        #expect(activeResult.value == nil)
        #expect(controller.isWorking)
        controller.webView.evaluateJavaScript("window.slowMetadata=false", completionHandler: nil)
        active.cancel()
        _ = try await result(activeResult)
        try await until { !controller.isWorking }
    }

    @Test("An uncooperative old WK command quarantines the page; its late result cannot save or start the successor")
    func uncooperativeCancellationFencesLateResult() async throws {
        let fixture = try await ControllerFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let (running, output) = start { try await controller.execute("uncooperative", expectedRevision: 0) }
        defer { running.cancel(); controller.webView.evaluateJavaScript("window.releaseActive()", completionHandler: nil) }
        try await until { controller.operationPhase == .running }
        _ = try await controller.commandMetadata("uncooperative")
        let (next, nextResult) = start { try await controller.execute("append", expectedRevision: 0) }
        defer { next.cancel() }
        try await until { controller.queuedOperationCount == 1 }
        running.cancel()
        if case .failure(let error) = try await result(output) { #expect(error is CancellationError) }
        else { Issue.record("Uncooperative cancelled edit succeeded") }
        try await until { !controller.isWorking && !controller.isReady }
        if case .failure = try await result(nextResult) { }
        else { Issue.record("Successor ran on a quarantined page") }
        controller.webView.evaluateJavaScript("window.releaseActive()", completionHandler: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await fixture.store.read().revision == 0)
        #expect(try await fixture.store.read().content["data"]["value"] == .number(0))
        #expect(controller.document.revision == 0)
        #expect(!controller.isReady)
    }
}
#endif
