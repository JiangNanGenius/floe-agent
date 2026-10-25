// FloeAppTests — A2 native Impeccable capture/Needs bridge (job-163156a65d574569).
//
// These are production-path source tests for the frozen v1 contract: the real
// service ingress validation, synchronous fencing, budgets, exact-bit
// Needs/Facts handling, bridge staging and truthful result assessment. The
// fixed producer *script execution* (real WebKit isolated world) and the
// guest engine run are pending with the Main owner: this suite injects the
// transport seam (a deterministic envelope stand-in for the WebKit callback)
// so every native rule is exercised without mocking the rules themselves.
// Nothing here claims the riscv64 engine, goldens or launcher passed — those
// are pending in the H3 lane.
//
// They are not executed in the code-first stage. Run them at the unified App
// freeze together with the existing BrowserTaskSession suites.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebKit
import FloeCore
@testable import FloeApp

// MARK: - File-private fixtures (non-isolated builders)

private let impeccableTestHost = "example.test"
private let impeccableStyleColumns: [String] = (0..<138).map { "column\($0)" }
private let impeccablePseudoColumns: [String] = (0..<23).map { "pseudo\($0)" }

private func impeccableSnapshotDictionary(
    captureId: String,
    documentId: String,
    columnCount: Int = 138,
    elementCount: Int = 1,
    innerWidth: Double = 1_024,
    innerHeight: Double = 768,
    scrollX: Double = 0,
    scrollY: Double = 0,
    hostname: String = impeccableTestHost,
    includeFloe: Bool = true,
    floeCaptureId: String? = nil,
    redaction: [String: Any]? = nil
) -> [String: Any] {
    var els: [[String: Any]] = []
    for _ in 0..<elementCount {
        els.append([
            "t": "HTML",
            "p": 0,
            "c": [Any](),
            "s": [Int](repeating: 0, count: columnCount),
            "v": 1,
            "m": [NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull()],
        ] as [String: Any])
    }
    var dictionary: [String: Any] = [
        "v": 1,
        "hostname": hostname,
        "quirks": false,
        "innerWidth": innerWidth,
        "innerHeight": innerHeight,
        "scrollX": scrollX,
        "scrollY": scrollY,
        "html": "<html><head><title>t</title></head><body><p>offline</p></body></html>",
        "keyframes": [Any](),
        "keyframeKeys": [String](),
        "linkedCss": "",
        "styleProps": Array(impeccableStyleColumns.prefix(min(columnCount, 138)))
            + (columnCount > 138 ? ((138..<columnCount).map { "extra\($0)" }) : []),
        "pseudoProps": impeccablePseudoColumns,
        "strings": [""],
        "els": els,
        "documentElement": 1,
        "body": 1,
        "bodyInnerText": "offline",
        "textLines": true,
        "hits": [Any](),
        "anim": false,
        "shadow": false,
    ]
    if includeFloe {
        let block: [String: Any] = [
            "captureId": floeCaptureId ?? captureId,
            "documentId": documentId,
            "contractVersion": 1,
            "redaction": redaction ?? [
                "policy": ImpeccableContract.redactionPolicy,
                "applied": true,
                "passwordInputs": 0,
                "formValues": 0,
                "credentialAttributes": [String](),
                "textRuns": 0,
            ],
        ]
        dictionary["floe"] = block
    }
    return dictionary
}

private func impeccableMeasurement(
    documentId: String,
    snapshot: [String: Any],
    view: ImpeccableSize? = nil,
    scroll: ImpeccablePoint? = nil,
    redaction: ImpeccableRedactionReceipt? = ImpeccableRedactionReceipt(
        policy: ImpeccableContract.redactionPolicy,
        applied: true,
        passwordInputs: 0,
        formValues: 0,
        credentialAttributes: [],
        textRuns: 0
    ),
    elementsMeasured: Int = 1
) -> ImpeccableCaptureMeasurement {
    let data = (try? JSONSerialization.data(withJSONObject: snapshot)) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? "{}"
    return ImpeccableCaptureMeasurement(
        snapshotText: text,
        hostname: (snapshot["hostname"] as? String) ?? impeccableTestHost,
        viewport: view ?? ImpeccableSize(
            width: (snapshot["innerWidth"] as? NSNumber)?.doubleValue ?? 1_024,
            height: (snapshot["innerHeight"] as? NSNumber)?.doubleValue ?? 768
        ),
        scroll: scroll ?? ImpeccablePoint(
            x: (snapshot["scrollX"] as? NSNumber)?.doubleValue ?? 0,
            y: (snapshot["scrollY"] as? NSNumber)?.doubleValue ?? 0
        ),
        redaction: redaction,
        elementsMeasured: elementsMeasured
    )
}

private func impeccableNeedsData(points: [(Double, Double)], round: Int = 1, scrollProbes: [Int] = []) -> Data {
    let object: [String: Any] = [
        "hitTests": points.map { [$0.0, $0.1] },
        "hitTestsBits": points.map {
            [ImpeccableDoubleBits.u64String(from: $0.0), ImpeccableDoubleBits.u64String(from: $0.1)]
        },
        "scrollProbes": scrollProbes,
        "round": round,
    ]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

@Suite("FloeApp.BrowserImpeccableCapture", .serialized)
@MainActor
struct BrowserImpeccableCaptureTests {
    // MARK: - Fixtures

    @MainActor
    private final class SpyHost: BrowserTaskSessionHost {
        func browserSessionRequestedUserControl(_ session: BrowserTaskSession, reason: String) {}
    }

    @MainActor
    private final class StubTransport: ImpeccableMeasurementTransport {
        var captureHandler: (@MainActor ([String: Any], UUID) throws -> ImpeccableCaptureMeasurement)?
        var answerHandler: (@MainActor ([String: Any], UUID) throws -> ImpeccableAnswerOutcome)?
        var probeHandler: (@MainActor ([String: Any], UUID) throws -> ImpeccableProbeOutcome)?
        private(set) var fencedInFlight: [UUID] = []
        private(set) var allFenceCount = 0
        private(set) var lastAnswerArguments: [String: Any]?
        private(set) var lastProbeArguments: [String: Any]?
        private(set) var probeCount = 0

        func runCapture(
            script: ImpeccableProducerScript.Loaded,
            arguments: [String: Any],
            in webView: WKWebView,
            contentWorld: WKContentWorld,
            captureId: UUID,
            deadline: ContinuousClock.Instant
        ) async throws -> ImpeccableCaptureMeasurement {
            guard let captureHandler else {
                throw ImpeccableCaptureError.webKit("stub has no capture handler")
            }
            return try captureHandler(arguments, captureId)
        }

        func runAnswer(
            script: ImpeccableProducerScript.Loaded,
            arguments: [String: Any],
            in webView: WKWebView,
            contentWorld: WKContentWorld,
            captureId: UUID,
            deadline: ContinuousClock.Instant
        ) async throws -> ImpeccableAnswerOutcome {
            lastAnswerArguments = arguments
            guard let answerHandler else {
                throw ImpeccableCaptureError.webKit("stub has no answer handler")
            }
            return try answerHandler(arguments, captureId)
        }

        func runProbe(
            script: ImpeccableProducerScript.Loaded,
            arguments: [String: Any],
            in webView: WKWebView,
            contentWorld: WKContentWorld,
            captureId: UUID,
            deadline: ContinuousClock.Instant
        ) async throws -> ImpeccableProbeOutcome {
            lastProbeArguments = arguments
            probeCount += 1
            guard let probeHandler else {
                throw ImpeccableCaptureError.webKit("stub has no probe handler")
            }
            return try probeHandler(arguments, captureId)
        }

        func fenceInFlight(captureId: UUID, reason: String) {
            fencedInFlight.append(captureId)
        }

        func fenceAllInFlight(reason: String) {
            allFenceCount += 1
        }
    }

    private func makeSession(html pageHTML: String? = nil) -> (BrowserTaskSession, UUID) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeImpeccableTests-\(UUID().uuidString)", isDirectory: true)
        let configuration = BrowserTaskSessionConfiguration(
            protocolVersion: "FloeBrowser/test",
            contentWorld: WKContentWorld.world(name: "org.floeagent.browser.tests.\(UUID().uuidString)"),
            artifactDirectory: directory,
            maximumTabs: 2,
            maximumEventsPerTab: 8
        )
        let session = BrowserTaskSession(
            conversationID: UUID(),
            generation: 1,
            configuration: configuration,
            host: SpyHost()
        )
        guard let tabID = session.createTab() else {
            Issue.record("test session could not create a tab")
            preconditionFailure("unreachable")
        }
        // The native URL/hostname cross-check requires a committed document.
        // `loadHTMLString` with an https baseURL gives the tab a real origin
        // without any network use.
        let html = pageHTML ?? "<!doctype html><html><head><title>t</title></head><body><p>offline</p></body></html>"
        if let tab = session.tabs.first(where: { $0.id == tabID }) {
            tab.webView.loadHTMLString(html, baseURL: URL(string: "https://\(impeccableTestHost)/")!)
        }
        return (session, tabID)
    }

    private func waitLoaded(_ session: BrowserTaskSession, tabID: UUID) async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let tab = session.tabs.first(where: { $0.id == tabID }),
               tab.webView.url?.host == impeccableTestHost {
                try? await Task.sleep(for: .milliseconds(80))
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("offline test page did not commit")
    }

    private func makeService(
        session: BrowserTaskSession,
        transport: StubTransport,
        budgets: ImpeccableBudgets = .frozenV1
    ) -> BrowserImpeccableCaptureService {
        BrowserImpeccableCaptureService(
            session: session,
            transport: transport,
            budgets: budgets,
            scriptLoader: { BrowserImpeccableCaptureService.fixtureLoadedScript(source: "fixture-producer") }
        )
    }

    /// Installs a trusted capture handler on the stub for this session's
    /// current document.
    private func installTrustedCapture(
        on transport: StubTransport,
        session: BrowserTaskSession,
        tabID: UUID,
        elementCount: Int = 1
    ) {
        let documentID = session.tabs.first(where: { $0.id == tabID })?.documentID ?? ""
        transport.captureHandler = { _, captureId in
            let snapshot = impeccableSnapshotDictionary(
                captureId: captureId.uuidString,
                documentId: documentID,
                elementCount: elementCount
            )
            return impeccableMeasurement(documentId: documentID, snapshot: snapshot, elementsMeasured: elementCount)
        }
    }

    private func trustedTicket(
        session: BrowserTaskSession,
        tabID: UUID,
        transport: StubTransport
    ) async throws -> ImpeccableCaptureTicket {
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let service = makeService(session: session, transport: transport)
        return try await service.capture(tabID: tabID)
    }

    // MARK: - Identity ingress (trusted vs forged)

    private let expectedDigest = "a" + String(repeating: "0", count: 63)

    private func baseIdentity(captureId: String = UUID().uuidString) -> ImpeccableIdentity {
        ImpeccableIdentity(
            taskId: UUID().uuidString,
            sessionId: UUID().uuidString,
            tabId: UUID().uuidString,
            documentId: UUID().uuidString,
            captureId: captureId,
            documentGeneration: 3,
            url: "https://\(impeccableTestHost)/",
            hostname: impeccableTestHost,
            viewport: ImpeccableSize(width: 1_024, height: 768),
            scroll: ImpeccablePoint(x: 0, y: 0),
            capturedAtMs: 1_760_000_000_000,
            producerTrust: ImpeccableContract.producerTrust,
            producer: ImpeccableProducerInfo(
                name: ImpeccableContract.producerName,
                version: ImpeccableContract.producerVersion,
                engine: ImpeccableContract.producerEngine,
                scriptDigest: expectedDigest
            ),
            redaction: .emptyNative,
            fenced: false
        )
    }

    private let agreement = ImpeccableIdentity.SnapshotAgreement(
        hostname: impeccableTestHost,
        innerWidth: 1_024,
        innerHeight: 768,
        scrollX: 0,
        scrollY: 0
    )

    @Test("Trusted native-fixed-script identity passes ingress")
    func trustedIdentityPasses() {
        #expect(baseIdentity().ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest).isEmpty)
    }

    @Test("Model-declared producer trust is rejected")
    func modelDeclaredTrustRejected() {
        var identity = baseIdentity()
        identity.producerTrust = "model-declared-trust"
        #expect(identity.ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest)
            .contains { $0.contains("untrusted") })
    }

    @Test("Synthetic all-zero script digest is never a real capture")
    func zeroDigestRejected() {
        var identity = baseIdentity()
        identity.producer.scriptDigest = ImpeccableContract.syntheticScriptDigest
        let rejections = identity.ingressRejections(
            snapshot: agreement,
            expectedScriptDigest: ImpeccableContract.syntheticScriptDigest
        )
        #expect(rejections.contains { $0.contains("synthetic all-zero") })
        let hostile = identity.ingressRejections(
            snapshot: agreement,
            expectedScriptDigest: identity.producer.scriptDigest
        )
        #expect(hostile.contains { $0.contains("synthetic all-zero") })
    }

    @Test("Foreign script digest is rejected")
    func foreignDigestRejected() {
        let rejections = baseIdentity().ingressRejections(
            snapshot: agreement,
            expectedScriptDigest: "b" + String(repeating: "1", count: 63)
        )
        #expect(rejections.contains { $0.contains("pinned fixed producer") })
    }

    @Test("Unapplied or foreign redaction policy is rejected")
    func redactionNotAppliedRejected() {
        var identity = baseIdentity()
        identity.redaction.applied = false
        #expect(identity.ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest)
            .contains { $0.contains("redaction") })
        var foreign = baseIdentity()
        foreign.redaction.policy = "some-other-policy"
        #expect(foreign.ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest)
            .contains { $0.contains("redaction") })
    }

    @Test("Missing session/tab binding is rejected")
    func missingBindingRejected() {
        var identity = baseIdentity()
        identity.sessionId = ""
        #expect(identity.ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest)
            .contains { $0.contains("required binding absent") })
        var noTab = baseIdentity()
        noTab.tabId = ""
        #expect(noTab.ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest)
            .contains { $0.contains("required binding absent") })
    }

    @Test("Identity must agree with the snapshot hostname/viewport/scroll")
    func identityViewAgreement() {
        var host = baseIdentity()
        host.hostname = "other.test"
        #expect(!host.ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest).isEmpty)
        var viewport = baseIdentity()
        viewport.viewport.height = 768.000_000_000_000_1
        #expect(!viewport.ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest).isEmpty)
        var scroll = baseIdentity()
        scroll.scroll.y = 0.5
        #expect(!scroll.ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest).isEmpty)
    }

    @Test("Fenced identity is superseded, never used")
    func fencedIdentitySuperseded() {
        var identity = baseIdentity()
        identity.fenced = true
        #expect(identity.ingressRejections(snapshot: agreement, expectedScriptDigest: expectedDigest)
            .contains { $0.contains("superseded") })
    }

    // MARK: - Needs exact bits

    @Test("Needs bits round-trip exactly and are authoritative")
    func needsBitsExact() throws {
        let x = 1_023.999_999_999_999_9
        let y = 0.1
        let needs = ImpeccableNeeds(
            hitTests: [[x, y]],
            hitTestsBits: [[ImpeccableDoubleBits.u64String(from: x), ImpeccableDoubleBits.u64String(from: y)]],
            scrollProbes: [],
            round: 1
        )
        let points = try needs.verifiedPoints()
        #expect(points.first!.x.bitPattern == x.bitPattern)
        #expect(points.first!.y.bitPattern == y.bitPattern)
    }

    @Test("Tampered decimal, missing bits or count drift are rejected")
    func needsBitsTampered() {
        let tampered = ImpeccableNeeds(
            hitTests: [[100.0, 200.0]],
            hitTestsBits: [[ImpeccableDoubleBits.u64String(from: 100.0), "99999999999999999999"]],
            scrollProbes: [],
            round: 1
        )
        #expect(throws: ImpeccableCaptureError.self) { try tampered.verifiedPoints() }
        let missing = ImpeccableNeeds(hitTests: [[100.0, 200.0]], hitTestsBits: nil, scrollProbes: [], round: 1)
        #expect(throws: ImpeccableCaptureError.self) { try missing.verifiedPoints() }
        let shortBits = ImpeccableNeeds(
            hitTests: [[100.0, 200.0], [1.0, 2.0]],
            hitTestsBits: [[ImpeccableDoubleBits.u64String(from: 100.0), ImpeccableDoubleBits.u64String(from: 200.0)]],
            scrollProbes: [],
            round: 1
        )
        #expect(throws: ImpeccableCaptureError.self) { try shortBits.verifiedPoints() }
    }

    @Test("NaN points cannot round-trip through the bit rule")
    func needsNaNRejected() {
        let nan = Double.nan
        let needs = ImpeccableNeeds(
            hitTests: [[nan, nan]],
            hitTestsBits: [[ImpeccableDoubleBits.u64String(from: nan), ImpeccableDoubleBits.u64String(from: nan)]],
            scrollProbes: [],
            round: 1
        )
        #expect(throws: ImpeccableCaptureError.self) { try needs.verifiedPoints() }
    }

    // MARK: - Facts binding rejection table

    private let testBinding = ImpeccableCaptureBinding(
        taskId: "task", sessionId: "session", tabId: "tab",
        documentId: "document", documentGeneration: 1, captureId: "capture"
    )

    private func baseFacts(binding: ImpeccableCaptureBinding) -> ImpeccableFacts {
        ImpeccableFacts(
            taskId: binding.taskId,
            sessionId: binding.sessionId,
            tabId: binding.tabId,
            documentId: binding.documentId,
            captureId: binding.captureId,
            documentGeneration: binding.documentGeneration,
            fenced: false,
            hits: [ImpeccableFactHit(
                x: 10, y: 20,
                xBits: ImpeccableDoubleBits.u64String(from: 10),
                yBits: ImpeccableDoubleBits.u64String(from: 20),
                top: 1, stack: [1]
            )],
            shownOnScroll: []
        )
    }

    @Test("Facts for a stale capture, other tab or fence are rejected, not merged")
    func factsBindingRejections() {
        let asked = [(x: 10.0, y: 20.0)]
        #expect(baseFacts(binding: testBinding).rejections(against: testBinding, askedPoints: asked, elementCount: 4).isEmpty)
        var stale = baseFacts(binding: testBinding)
        stale.captureId = "other-capture"
        #expect(stale.rejections(against: testBinding, askedPoints: asked, elementCount: 4).contains { $0.contains("binding differs") })
        var otherTab = baseFacts(binding: testBinding)
        otherTab.tabId = "other-tab"
        #expect(otherTab.rejections(against: testBinding, askedPoints: asked, elementCount: 4).contains { $0.contains("binding differs") })
        var fenced = baseFacts(binding: testBinding)
        fenced.fenced = true
        #expect(fenced.rejections(against: testBinding, askedPoints: asked, elementCount: 4).contains { $0.contains("fenced") })
        var bits = baseFacts(binding: testBinding)
        bits.hits[0].xBits = ImpeccableDoubleBits.u64String(from: 10.5)
        #expect(bits.rejections(against: testBinding, askedPoints: asked, elementCount: 4).contains { $0.contains("bits differ") })
        var silentZero = baseFacts(binding: testBinding)
        silentZero.hits[0].top = 0
        silentZero.hits[0].stack = []
        #expect(silentZero.rejections(against: testBinding, askedPoints: asked, elementCount: 4).contains { $0.contains("unanswerable") })
        var outside = baseFacts(binding: testBinding)
        outside.hits[0].stack = [999]
        #expect(outside.rejections(against: testBinding, askedPoints: asked, elementCount: 4).contains { $0.contains("outside the capture") })
    }

    // MARK: - Capture ingress (production service paths with stubbed transport)

    @Test("Trusted measurement stages snapshot + identity into the task-owned bridge")
    func captureStagesTrustedFiles() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let ticket = try await trustedTicket(session: session, tabID: tabID, transport: transport)
        #expect(ticket.scriptDigest == BrowserImpeccableCaptureService.fixtureLoadedScript(source: "fixture-producer").runDigest)
        #expect(ticket.binding.taskId == session.conversationID.uuidString)
        #expect(ticket.binding.sessionId == session.sessionID.uuidString)
        #expect(ticket.elementCount == 1)
        #expect(FileManager.default.fileExists(atPath: ticket.snapshotFile.path))
        #expect(FileManager.default.fileExists(atPath: ticket.identityFile.path))
        let decoded = try JSONDecoder().decode(ImpeccableIdentity.self, from: try Data(contentsOf: ticket.identityFile))
        #expect(decoded.producerTrust == ImpeccableContract.producerTrust)
        #expect(decoded.documentGeneration == ticket.documentGeneration)
        #expect(decoded.captureId == ticket.captureID.uuidString)
        #expect(decoded.producer.scriptDigest == ticket.scriptDigest)
        let staged = try JSONSerialization.jsonObject(with: try Data(contentsOf: ticket.snapshotFile)) as? [String: Any]
        #expect((staged?["floe"] as? [String: Any])?["captureId"] as? String == ticket.captureID.uuidString)
    }

    @Test("Schema-mismatch snapshot is refused at ingress")
    func captureRejectsSchemaMismatch() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let documentID = session.tabs.first!.documentID
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        transport.captureHandler = { _, captureId in
            let snapshot = impeccableSnapshotDictionary(captureId: captureId.uuidString, documentId: documentID, columnCount: 137)
            return impeccableMeasurement(documentId: documentID, snapshot: snapshot)
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.capture(tabID: tabID)
        }
        transport.captureHandler = { _, captureId in
            let snapshot = impeccableSnapshotDictionary(captureId: captureId.uuidString, documentId: documentID, includeFloe: false)
            return impeccableMeasurement(documentId: documentID, snapshot: snapshot)
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.capture(tabID: tabID)
        }
        transport.captureHandler = { _, captureId in
            let snapshot = impeccableSnapshotDictionary(captureId: "wrong-capture-id", documentId: documentID)
            return impeccableMeasurement(documentId: documentID, snapshot: snapshot)
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.capture(tabID: tabID)
        }
    }

    @Test("Envelope/snapshot view disagreement is refused")
    func captureRejectsViewDisagreement() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let documentID = session.tabs.first!.documentID
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        transport.captureHandler = { _, captureId in
            let snapshot = impeccableSnapshotDictionary(captureId: captureId.uuidString, documentId: documentID, innerHeight: 600)
            return impeccableMeasurement(
                documentId: documentID,
                snapshot: snapshot,
                view: ImpeccableSize(width: 1_024, height: 768)
            )
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.capture(tabID: tabID)
        }
    }

    @Test("Native URL and measured hostname must agree")
    func captureRejectsHostDisagreement() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let documentID = session.tabs.first!.documentID
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        transport.captureHandler = { _, captureId in
            let snapshot = impeccableSnapshotDictionary(captureId: captureId.uuidString, documentId: documentID, hostname: "elsewhere.test")
            return impeccableMeasurement(documentId: documentID, snapshot: snapshot)
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.capture(tabID: tabID)
        }
    }

    @Test("A document swap during measurement refuses the late result")
    func captureRefusedWhenDocumentSwaps() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        let documentID = session.tabs.first!.documentID
        transport.captureHandler = { _, captureId in
            session.invalidateDocumentsForHandoff()
            let snapshot = impeccableSnapshotDictionary(captureId: captureId.uuidString, documentId: documentID)
            return impeccableMeasurement(documentId: documentID, snapshot: snapshot)
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.capture(tabID: tabID)
        }
    }

    @Test("Budget caps are failures, never partial passes")
    func captureBudgets() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let documentID = session.tabs.first!.documentID
        let transport = StubTransport()
        let tinyBytes = ImpeccableBudgets(
            maxSnapshotBytes: 64, maxElements: 30_000, maxRounds: 4,
            maxHitTestsPerRound: 4_096, maxHitTestsTotal: 16_384, timeoutMs: 120_000
        )
        let byteService = makeService(session: session, transport: transport, budgets: tinyBytes)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        await #expect(throws: ImpeccableCaptureError.self) {
            try await byteService.capture(tabID: tabID)
        }
        let tinyElements = ImpeccableBudgets(
            maxSnapshotBytes: 50_331_648, maxElements: 0, maxRounds: 4,
            maxHitTestsPerRound: 4_096, maxHitTestsTotal: 16_384, timeoutMs: 120_000
        )
        let elementService = makeService(session: session, transport: transport, budgets: tinyElements)
        transport.captureHandler = { _, captureId in
            let snapshot = impeccableSnapshotDictionary(captureId: captureId.uuidString, documentId: documentID, elementCount: 1)
            return impeccableMeasurement(documentId: documentID, snapshot: snapshot, elementsMeasured: 1)
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await elementService.capture(tabID: tabID)
        }
    }

    // MARK: - Needs answering through the real service

    @Test("Trusted round stages facts with exact bits and full binding")
    func answerNeedsTrustedRound() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        transport.answerHandler = { _, _ in
            .answered(hits: [ImpeccableAnswerOutcome.Hit(top: 1, stack: [1], unanswerable: false, reason: nil)])
        }
        let factsURL = try await service.answerNeeds(captureID: ticket.captureID, needsJSON: impeccableNeedsData(points: [(10.0, 20.0)]))
        let facts = try JSONDecoder().decode(ImpeccableFacts.self, from: try Data(contentsOf: factsURL))
        #expect(facts.captureId == ticket.captureID.uuidString)
        #expect(facts.taskId == ticket.binding.taskId)
        #expect(facts.sessionId == ticket.binding.sessionId)
        #expect(facts.tabId == ticket.binding.tabId)
        #expect(facts.documentId == ticket.binding.documentId)
        #expect(facts.documentGeneration == ticket.binding.documentGeneration)
        #expect(facts.fenced == false)
        #expect(facts.hits.first?.top == 1)
        #expect(facts.hits.first!.xBits == ImpeccableDoubleBits.u64String(from: 10.0))
        #expect(facts.hits.first!.yBits == ImpeccableDoubleBits.u64String(from: 20.0))
        #expect(facts.shownOnScroll.isEmpty)
    }

    @Test("Scroll probes are never invented; they stay unanswered")
    func scrollProbesStayUnanswered() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        transport.answerHandler = { _, _ in
            .answered(hits: [ImpeccableAnswerOutcome.Hit(top: 0, stack: [], unanswerable: true, reason: "no-captured-element-at-point")])
        }
        let factsURL = try await service.answerNeeds(
            captureID: ticket.captureID,
            needsJSON: impeccableNeedsData(points: [(10.0, 20.0)], scrollProbes: [1])
        )
        let facts = try JSONDecoder().decode(ImpeccableFacts.self, from: try Data(contentsOf: factsURL))
        #expect(facts.shownOnScroll.isEmpty)
        #expect(facts.hits.first?.unanswerable == true)
        #expect(facts.hits.first?.reason == "no-captured-element-at-point")
        // The answer surface carries only hit points: the page is never moved.
        let floeArgs = transport.lastAnswerArguments?["floeArgs"] as? [String: Any]
        #expect((floeArgs?["points"] as? [[Any]])?.count == 1)
    }

    @Test("Viewport drift at answer time fences the capture and refuses the round")
    func answerFencesOnDrift() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        transport.answerHandler = { _, _ in .fenced(reason: "viewport-or-scroll-changed") }
        let needs = impeccableNeedsData(points: [(10.0, 20.0)])
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: needs)
        }
        #expect(service.status(captureID: ticket.captureID) == .fenced(reason: "viewport"))
        // A fenced capture's files are deleted immediately; nothing stale can
        // be staged or scanned later.
        #expect(!FileManager.default.fileExists(atPath: ticket.snapshotFile.path))
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: needs)
        }
    }

    @Test("Replaced producer world fences and refuses")
    func answerRefusesLostWorld() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        transport.answerHandler = { _, _ in .rejected(code: "no-such-capture") }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: impeccableNeedsData(points: [(10.0, 20.0)]))
        }
        #expect(service.status(captureID: ticket.captureID) == .fenced(reason: "navigation"))
    }

    @Test("Round and hit-test budgets fail closed")
    func answerBudgets() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let budgets = ImpeccableBudgets(
            maxSnapshotBytes: 50_331_648, maxElements: 30_000, maxRounds: 4,
            maxHitTestsPerRound: 2, maxHitTestsTotal: 3, timeoutMs: 120_000
        )
        let service = makeService(session: session, transport: transport, budgets: budgets)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        transport.answerHandler = { _, _ in
            .answered(hits: Array(
                repeating: ImpeccableAnswerOutcome.Hit(top: 1, stack: [1], unanswerable: false, reason: nil),
                count: 3
            ))
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: impeccableNeedsData(points: [(10, 20), (30, 40), (50, 60)]))
        }
        transport.answerHandler = { _, _ in
            .answered(hits: Array(
                repeating: ImpeccableAnswerOutcome.Hit(top: 1, stack: [1], unanswerable: false, reason: nil),
                count: 2
            ))
        }
        _ = try await service.answerNeeds(captureID: ticket.captureID, needsJSON: impeccableNeedsData(points: [(10, 20), (30, 40)]))
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: impeccableNeedsData(points: [(10, 20), (30, 40)], round: 2))
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: impeccableNeedsData(points: [(10, 20)], round: 4))
        }
        // Out-of-order round for a fresh capture: round 2 before round 1.
        let secondTicket = try await service.capture(tabID: tabID)
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: secondTicket.captureID, needsJSON: impeccableNeedsData(points: [(10, 20)], round: 2))
        }
    }

    @Test("Facts with ids outside the capture are refused before staging")
    func answerRefusesForeignIDs() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID, elementCount: 1)
        let ticket = try await service.capture(tabID: tabID)
        transport.answerHandler = { _, _ in
            .answered(hits: [ImpeccableAnswerOutcome.Hit(top: 42, stack: [42], unanswerable: false, reason: nil)])
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: impeccableNeedsData(points: [(10.0, 20.0)]))
        }
        // A forged answer does not fence the capture; it just gets refused.
        #expect(service.status(captureID: ticket.captureID) == .active)
    }

    @Test("Synchronous fences refuse any late answer")
    func fencesRefuseLateAnswers() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        let needs = impeccableNeedsData(points: [(10.0, 20.0)])
        transport.answerHandler = { _, _ in
            .answered(hits: [ImpeccableAnswerOutcome.Hit(top: 1, stack: [1], unanswerable: false, reason: nil)])
        }
        for reason in [
            BrowserImpeccableCaptureService.FenceReason.navigation,
            .reload, .scroll, .viewport, .tabClosed, .userTakeover,
            .ownerHandoff, .released, .taskCancelled, .documentSwap,
        ] {
            let fresh = try await service.capture(tabID: tabID)
            service.fence(captureID: fresh.captureID, reason: reason)
            await #expect(throws: ImpeccableCaptureError.self) {
                try await service.answerNeeds(captureID: fresh.captureID, needsJSON: needs)
            }
        }
        // The original capture was fenced by the first iteration too.
        service.fence(captureID: ticket.captureID, reason: .navigation)
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: needs)
        }
        // A tab-wide fence covers every record on that tab.
        let another = try await service.capture(tabID: tabID)
        service.fence(tabID: tabID, reason: .scroll)
        #expect(service.status(captureID: another.captureID) == .fenced(reason: "scroll"))
        // The WebKit in-flight surface was notified on every state-changing fence.
        #expect(transport.fencedInFlight.count >= 12)
    }

    // MARK: - Result ingress (truthful coverage)

    private func resultJSON(
        status: String,
        verdict: String,
        identity: ImpeccableIdentity? = nil,
        identityCheck: String? = nil,
        extras: [String: Any] = [:]
    ) -> Data {
        var object: [String: Any] = [
            "contract": ImpeccableContract.name,
            "contractVersion": 1,
            "status": status,
            "verdict": verdict,
            "engine": ["engineId": "impeccable-0.1.17+floe.1.0.0"],
            "coverage": [
                "passes": [["id": "core-rule-pass", "state": "covered", "requiredForCleanVerdict": true]],
                "uncoveredRequired": ImpeccableCoverage.uncoveredRequiredInV1,
                "unknownStyleProps": [String](),
            ],
        ]
        if let identity {
            // The legitimate fixture echoes the *native-issued* identity
            // byte-for-byte: a result without the full frozen identity can
            // never carry usable findings.
            object["identity"] = (try? JSONSerialization.jsonObject(with: identity.encodedJSON()))
        }
        if let identityCheck {
            object["identityCheck"] = ["state": identityCheck, "mismatches": [String]()]
        }
        for (key, value) in extras { object[key] = value }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test("v1 never reports a page clean; a clean claim is surfaced as inconclusive")
    func cleanClaimDowngraded() throws {
        let document = try ImpeccableResultDocument.parse(from: resultJSON(status: "complete", verdict: "clean"))
        let assessment = ImpeccableCoverage.assess(result: document, parseFailure: nil, recordFenced: false, bindingMatches: true)
        #expect(assessment.exit == .inconclusive)
        #expect(!assessment.uncoveredRequired.isEmpty)
        #expect(ImpeccableCoverage.cleanVerdictReachableInV1 == false)
        let gate = ImpeccableCoverage.cleanGateFailures(for: document)
        #expect(!gate.isEmpty)
    }

    @Test("Needs is exit 3, findings exit 2, inconclusive exit 4, failure exit 1")
    func exitMapping() throws {
        let needsExtras: [String: Any] = [
            "needs": [
                "hitTests": [[10.0, 20.0]],
                "hitTestsBits": [[ImpeccableDoubleBits.u64String(from: 10.0), ImpeccableDoubleBits.u64String(from: 20.0)]],
                "scrollProbes": [Int](),
                "round": 1,
            ],
        ]
        let needsDocument = try ImpeccableResultDocument.parse(from: resultJSON(status: "needs-facts", verdict: "none", extras: needsExtras))
        #expect(needsDocument.engineExit == .needsFacts)
        let findingsDocument = try ImpeccableResultDocument.parse(from: resultJSON(
            status: "complete", verdict: "findings",
            extras: ["findings": ["groups": [["items": [["rule": "x"]]]], "pageLevel": [], "counts": ["total": 1]]]
        ))
        #expect(findingsDocument.engineExit == .findings)
        #expect(findingsDocument.findingCount == 1)
        let inconclusiveDocument = try ImpeccableResultDocument.parse(from: resultJSON(status: "complete", verdict: "inconclusive"))
        #expect(inconclusiveDocument.engineExit == .inconclusive)
        let failedDocument = try ImpeccableResultDocument.parse(from: resultJSON(
            status: "failed", verdict: "none",
            extras: ["error": ["code": "snapshot-parse", "message": "truncated"]]
        ))
        #expect(failedDocument.engineExit == .failure)
    }

    @Test("A malformed result is never a pass")
    func malformedResultFails() {
        #expect(throws: ImpeccableCaptureError.self) {
            try ImpeccableResultDocument.parse(from: Data("not json".utf8))
        }
        #expect(throws: ImpeccableCaptureError.self) {
            try ImpeccableResultDocument.parse(from: Data("{}".utf8))
        }
    }

    /// The identity the service actually issued for one capture, read back
    /// from the staged native-owned identity file — legitimate by
    /// construction, exactly the bytes the engine would echo.
    private func issuedIdentity(ticket: ImpeccableCaptureTicket) throws -> ImpeccableIdentity {
        try JSONDecoder().decode(ImpeccableIdentity.self, from: try Data(contentsOf: ticket.identityFile))
    }

    /// Installs a probe handler reporting exactly the captured state: the
    /// world still holds the capture and the current CSS view equals the
    /// identity's viewport/scroll.
    private func installMatchingProbe(on transport: StubTransport, ticket: ImpeccableCaptureTicket) {
        transport.probeHandler = { _, _ in
            ImpeccableProbeOutcome(
                holdsCapture: true,
                recordedDocumentId: ticket.binding.documentId,
                viewport: ticket.viewport,
                scroll: ticket.scroll,
                hostname: impeccableTestHost
            )
        }
    }

    @Test("A fenced capture's result is superseded regardless of content")
    func fencedCaptureResultSuperseded() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        installMatchingProbe(on: transport, ticket: ticket)
        let issued = try issuedIdentity(ticket: ticket)
        let data = resultJSON(
            status: "complete", verdict: "findings", identity: issued,
            extras: ["findings": ["groups": [], "pageLevel": [], "counts": ["total": 2]]]
        )
        // The legitimate full-identity result on an unmoved page is usable.
        let usable = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
        #expect(usable.exit == .findings)
        #expect(usable.identityState == "verified")
        #expect(usable.findingCount == 2)
        #expect(usable.identityRejections.isEmpty)
        service.fence(tabID: tabID, reason: .navigation)
        let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
        #expect(assessment.exit == .failure)
        #expect(assessment.identityState == "superseded")
        #expect(assessment.findingCount == 0)
    }

    // MARK: - Verified result identity (R2 regressions)

    @Test("A result without the native-issued identity never carries findings")
    func resultMissingIdentityRejected() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        installMatchingProbe(on: transport, ticket: ticket)
        let data = resultJSON(
            status: "complete", verdict: "findings",
            extras: ["findings": ["groups": [], "pageLevel": [], "counts": ["total": 3]]]
        )
        let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
        #expect(assessment.exit == .failure)
        #expect(assessment.identityState == "absent")
        #expect(assessment.findingCount == 0)
        #expect(assessment.needsOutstanding == nil)
        #expect(!assessment.identityRejections.isEmpty)
        // Refused before any probe runs, and a foreign result never fences
        // the legitimate capture.
        #expect(transport.probeCount == 0)
        #expect(service.status(captureID: ticket.captureID) == .active)
    }

    @Test("Same captureId with any foreign identity field is a failure")
    func resultForeignIdentityRejected() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        installMatchingProbe(on: transport, ticket: ticket)
        let issued = try issuedIdentity(ticket: ticket)
        let findings: [String: Any] = ["groups": [], "pageLevel": [], "counts": ["total": 3]]

        var cases: [(label: String, identity: ImpeccableIdentity)] = []
        func foreign(_ label: String, _ mutate: (inout ImpeccableIdentity) -> Void) {
            var copy = issued
            mutate(&copy)
            cases.append((label, copy))
        }
        foreign("taskId") { $0.taskId = UUID().uuidString }
        foreign("sessionId") { $0.sessionId = UUID().uuidString }
        foreign("tabId") { $0.tabId = UUID().uuidString }
        foreign("documentId") { $0.documentId = UUID().uuidString }
        foreign("captureId") { $0.captureId = UUID().uuidString }
        foreign("documentGeneration") { $0.documentGeneration += 1 }
        foreign("url") { $0.url = "https://attacker.test/" }
        foreign("hostname") { $0.hostname = "attacker.test" }
        foreign("viewport.width") { $0.viewport.width = 1_025 }
        foreign("viewport.height-sub-ulp") { $0.viewport.height = 768.000_000_000_000_1 }
        foreign("scroll.y") { $0.scroll.y = 1 }
        foreign("capturedAtMs") { $0.capturedAtMs += 1 }
        foreign("producerTrust") { $0.producerTrust = "model-declared-trust" }
        foreign("producer.name") { $0.producer.name = "some-other-producer" }
        foreign("producer.version") { $0.producer.version = "9.9.9" }
        foreign("producer.engine") { $0.producer.engine = "Blink" }
        foreign("producer.scriptDigest") { $0.producer.scriptDigest = "b" + String(repeating: "1", count: 63) }
        foreign("redaction.policy") { $0.redaction.policy = "some-other-policy" }
        foreign("redaction.applied") { $0.redaction.applied = false }
        foreign("redaction.formValues") { $0.redaction.formValues = 5 }
        foreign("redaction.credentialAttributes") { $0.redaction.credentialAttributes = ["token"] }
        foreign("fenced") { $0.fenced = true }

        for (label, foreignIdentity) in cases {
            let data = resultJSON(
                status: "complete", verdict: "findings", identity: foreignIdentity,
                extras: ["findings": findings]
            )
            let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
            #expect(assessment.exit == .failure, "foreign \(label) must fail")
            #expect(assessment.identityState == "mismatch", "foreign \(label)")
            #expect(assessment.findingCount == 0, "foreign \(label) must never carry counts")
            #expect(assessment.needsOutstanding == nil, "foreign \(label)")
            #expect(!assessment.identityRejections.isEmpty, "foreign \(label)")
        }
        // Forged results never fence the legitimate capture.
        #expect(service.status(captureID: ticket.captureID) == .active)
    }

    @Test("A malformed identity echo is a failure, never a partial identity")
    func resultMalformedIdentityRejected() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        installMatchingProbe(on: transport, ticket: ticket)
        let findings: [String: Any] = ["groups": [], "pageLevel": [], "counts": ["total": 3]]
        let malformed: [(label: String, value: Any)] = [
            ("not-an-object", "identity-was-a-string"),
            ("null-identity-object", NSNull()),
            ("partial-object", ["taskId": "task", "captureId": ticket.captureID.uuidString]),
            ("fractional-generation", ["documentGeneration": 3.5]),
        ]
        for (label, value) in malformed {
            let data = resultJSON(
                status: "complete", verdict: "findings",
                extras: ["identity": value, "findings": findings]
            )
            let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
            #expect(assessment.exit == .failure, "malformed \(label) must fail")
            #expect(assessment.findingCount == 0, "malformed \(label)")
            #expect(!assessment.identityRejections.isEmpty, "malformed \(label)")
        }
        // Missing scriptDigest inside producer: decode via a mutated dictionary.
        let issued = try issuedIdentity(ticket: ticket)
        var dictionary = (try JSONSerialization.jsonObject(with: issued.encodedJSON())) as! [String: Any]
        var producer = (dictionary["producer"] as? [String: Any]) ?? [:]
        producer.removeValue(forKey: "scriptDigest")
        dictionary["producer"] = producer
        let noDigest = resultJSON(
            status: "complete", verdict: "findings",
            extras: ["identity": dictionary, "findings": findings]
        )
        let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: noDigest)
        #expect(assessment.exit == .failure)
        #expect(assessment.identityState == "mismatch")
        #expect(assessment.findingCount == 0)
        #expect(assessment.identityRejections.contains { $0.contains("scriptDigest") })
    }

    @Test("Engine-reported identityCheck mismatch or superseded is never a scan result")
    func engineIdentityCheckGateRefuses() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        installMatchingProbe(on: transport, ticket: ticket)
        let issued = try issuedIdentity(ticket: ticket)
        let findings: [String: Any] = ["groups": [], "pageLevel": [], "counts": ["total": 5]]
        for state in ["mismatch", "superseded"] {
            let data = resultJSON(
                status: "complete", verdict: "findings",
                identity: issued, identityCheck: state,
                extras: ["findings": findings]
            )
            let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
            #expect(assessment.exit == .failure)
            #expect(assessment.identityState == state)
            #expect(assessment.findingCount == 0)
        }
        // An engine-claimed "verified" alone grants nothing new: the native
        // comparison already ran, and a clean claim still downgrades.
        let clean = resultJSON(status: "complete", verdict: "clean", identity: issued, identityCheck: "verified")
        let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: clean)
        #expect(assessment.exit == .inconclusive)
        #expect(assessment.findingCount == 0)
        #expect(assessment.uncoveredRequired.count == 6)
        #expect(ImpeccableCoverage.cleanVerdictReachableInV1 == false)
    }

    @Test("Needs-facts survives ingress only with full identity and an unmoved page")
    func needsFactsResultIngress() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        installMatchingProbe(on: transport, ticket: ticket)
        let issued = try issuedIdentity(ticket: ticket)
        let needsExtras: [String: Any] = [
            "needs": [
                "hitTests": [[10.0, 20.0]],
                "hitTestsBits": [[ImpeccableDoubleBits.u64String(from: 10.0), ImpeccableDoubleBits.u64String(from: 20.0)]],
                "scrollProbes": [Int](),
                "round": 1,
            ],
        ]
        let data = resultJSON(status: "needs-facts", verdict: "none", identity: issued, extras: needsExtras)
        let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
        #expect(assessment.exit == .needsFacts)
        #expect(assessment.identityState == "verified")
        #expect(assessment.findingCount == 0)
        #expect(assessment.needsOutstanding?.round == 1)
        // The same document without identity is refused.
        let anonymous = resultJSON(status: "needs-facts", verdict: "none", extras: needsExtras)
        let refused = await service.resultAssessment(captureID: ticket.captureID, resultJSON: anonymous)
        #expect(refused.exit == .failure)
        #expect(refused.needsOutstanding == nil)
    }

    @Test("A result arriving after document handoff is superseded even unfenced")
    func lateResultAfterHandoffSuperseded() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        installMatchingProbe(on: transport, ticket: ticket)
        let issued = try issuedIdentity(ticket: ticket)
        let data = resultJSON(
            status: "complete", verdict: "findings", identity: issued,
            extras: ["findings": ["groups": [], "pageLevel": [], "counts": ["total": 2]]]
        )
        // The handoff bumps the live document and fences the *session's own*
        // service; this detached test service's record is still active — the
        // ingress live-binding gate must refuse the late result anyway.
        session.invalidateDocumentsForHandoff()
        #expect(service.status(captureID: ticket.captureID) == .active)
        let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
        #expect(assessment.exit == .failure)
        #expect(assessment.identityState == "superseded")
        #expect(assessment.findingCount == 0)
        #expect(service.status(captureID: ticket.captureID) == .fenced(reason: "documentSwap"))
        #expect(!FileManager.default.fileExists(atPath: ticket.snapshotFile.path))
    }

    @Test("A result arriving after session release is superseded")
    func resultAfterReleaseSuperseded() async throws {
        let (session, tabID) = makeSession()
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        let issued = try issuedIdentity(ticket: ticket)
        let data = resultJSON(
            status: "complete", verdict: "findings", identity: issued,
            extras: ["findings": ["groups": [], "pageLevel": [], "counts": ["total": 2]]]
        )
        session.release()
        let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
        #expect(assessment.exit == .failure)
        #expect(assessment.identityState == "superseded")
        #expect(assessment.findingCount == 0)
    }

    @Test("Probe drift and lost worlds supersede late results")
    func probeCurrencyRefusals() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        let issued = try issuedIdentity(ticket: ticket)
        let data = resultJSON(
            status: "complete", verdict: "findings", identity: issued,
            extras: ["findings": ["groups": [], "pageLevel": [], "counts": ["total": 2]]]
        )
        // The page moved with no native event at all: only the fixed probe
        // can see it. The late result is refused and the capture fenced.
        transport.probeHandler = { _, _ in
            ImpeccableProbeOutcome(
                holdsCapture: true,
                recordedDocumentId: ticket.binding.documentId,
                viewport: ticket.viewport,
                scroll: ImpeccablePoint(x: 0, y: 40),
                hostname: impeccableTestHost
            )
        }
        let drifted = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
        #expect(drifted.exit == .failure)
        #expect(drifted.identityState == "superseded")
        #expect(drifted.findingCount == 0)
        #expect(service.status(captureID: ticket.captureID) == .fenced(reason: "viewport"))

        // A replaced world no longer holds the capture run.
        let second = try await service.capture(tabID: tabID)
        let secondIssued = try issuedIdentity(ticket: second)
        let secondData = resultJSON(
            status: "complete", verdict: "findings", identity: secondIssued,
            extras: ["findings": ["groups": [], "pageLevel": [], "counts": ["total": 1]]]
        )
        transport.probeHandler = { _, _ in
            ImpeccableProbeOutcome(
                holdsCapture: false,
                recordedDocumentId: "",
                viewport: second.viewport,
                scroll: second.scroll,
                hostname: impeccableTestHost
            )
        }
        let lost = await service.resultAssessment(captureID: second.captureID, resultJSON: secondData)
        #expect(lost.exit == .failure)
        #expect(lost.identityState == "superseded")
        #expect(service.status(captureID: second.captureID) == .fenced(reason: "navigation"))
    }

    @Test("An unavailable probe never turns into a pass")
    func probeFailureRefusesResult() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        let issued = try issuedIdentity(ticket: ticket)
        let data = resultJSON(
            status: "complete", verdict: "findings", identity: issued,
            extras: ["findings": ["groups": [], "pageLevel": [], "counts": ["total": 2]]]
        )
        // No probe handler installed: the currency re-measurement fails, so
        // the result is refused with zero findings — and the record stays
        // active because nothing was proven to have moved.
        let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
        #expect(assessment.exit == .failure)
        #expect(assessment.findingCount == 0)
        #expect(assessment.headline.contains("could not be re-measured"))
        #expect(service.status(captureID: ticket.captureID) == .active)
    }

    // MARK: - External native viewport/scroll fences (R2)

    @Test("Native observer fences synchronously and stops when invalidated")
    func observerSynchronousFenceAndInvalidation() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 320, height: 4_000)
        var fired: [ImpeccableViewportObserver.Drift] = []
        let observer = ImpeccableViewportObserver(scrollView: scrollView) { observed in
            fired.append(observed.driftKind ?? .scroll)
        }
        // Main-thread KVO delivers synchronously: the fence lands before the
        // next statement runs — this is the moment-of-change guarantee.
        scrollView.contentOffset = CGPoint(x: 0, y: 120)
        #expect(fired == [.scroll])
        #expect(observer.hasDrifted)
        #expect(observer.driftReason == BrowserImpeccableCaptureService.FenceReason.scroll)
        #expect(observer.recheckNow())
        observer.invalidate()
        fired.removeAll()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        #expect(fired.isEmpty)
        #expect(observer.recheckNow())

        let resizable = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        var kinds: [ImpeccableViewportObserver.Drift] = []
        let resizeObserver = ImpeccableViewportObserver(scrollView: resizable) { observed in
            kinds.append(observed.driftKind ?? .scroll)
        }
        resizable.bounds = CGRect(x: 0, y: 0, width: 400, height: 480)
        #expect(kinds == [.viewport])
        #expect(resizeObserver.driftReason == BrowserImpeccableCaptureService.FenceReason.viewport)
        resizeObserver.invalidate()
    }

    @Test("An external page scroll fences the capture and refuses late work")
    func externalNativeScrollFence() async throws {
        let tallHTML = "<!doctype html><html><head><title>t</title></head><body><div style=\"height:5000px\">tall</div></body></html>"
        let (session, tabID) = makeSession(html: tallHTML)
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        installMatchingProbe(on: transport, ticket: ticket)
        #expect(service.status(captureID: ticket.captureID) == .active)
        guard let tab = session.tabs.first(where: { $0.id == tabID }) else {
            Issue.record("tab disappeared"); return
        }
        // A scroll nobody commanded natively (page script or user finger):
        // the per-capture observer must fence this capture.
        tab.webView.scrollView.setContentOffset(CGPoint(x: 0, y: 140), animated: false)
        var fenced = service.status(captureID: ticket.captureID) == .fenced(reason: "scroll")
        if !fenced {
            // WebKit may re-deliver the geometry change on a later turn.
            let deadline = Date().addingTimeInterval(2)
            while !fenced && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
                fenced = service.status(captureID: ticket.captureID) == .fenced(reason: "scroll")
            }
        }
        #expect(fenced)
        #expect(!FileManager.default.fileExists(atPath: ticket.snapshotFile.path))
        // Late answer and late result are both refused.
        transport.answerHandler = { _, _ in
            .answered(hits: [ImpeccableAnswerOutcome.Hit(top: 1, stack: [1], unanswerable: false, reason: nil)])
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: impeccableNeedsData(points: [(10.0, 20.0)]))
        }
        let issued = try issuedIdentity(ticket: ticket)
        let data = resultJSON(
            status: "complete", verdict: "findings", identity: issued,
            extras: ["findings": ["groups": [], "pageLevel": [], "counts": ["total": 2]]]
        )
        let assessment = await service.resultAssessment(captureID: ticket.captureID, resultJSON: data)
        #expect(assessment.exit == .failure)
        #expect(assessment.identityState == "superseded")
        #expect(assessment.findingCount == 0)
    }

    @Test("An external resize fences with the viewport reason")
    func externalNativeResizeFence() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let ticket = try await service.capture(tabID: tabID)
        installMatchingProbe(on: transport, ticket: ticket)
        guard let tab = session.tabs.first(where: { $0.id == tabID }) else {
            Issue.record("tab disappeared"); return
        }
        tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        var fenced = service.status(captureID: ticket.captureID) == .fenced(reason: "viewport")
        if !fenced {
            let deadline = Date().addingTimeInterval(2)
            while !fenced && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
                fenced = service.status(captureID: ticket.captureID) == .fenced(reason: "viewport")
            }
        }
        #expect(fenced)
        await #expect(throws: ImpeccableCaptureError.self) {
            try await service.answerNeeds(captureID: ticket.captureID, needsJSON: impeccableNeedsData(points: [(10.0, 20.0)]))
        }
    }

    @Test("An old capture's cleanup never fences or deletes a newer capture")
    func oldCaptureNeverTouchesNew() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let first = try await service.capture(tabID: tabID)
        let second = try await service.capture(tabID: tabID)
        service.cleanup(captureID: first.captureID)
        #expect(!FileManager.default.fileExists(atPath: first.snapshotFile.path))
        #expect(FileManager.default.fileExists(atPath: second.snapshotFile.path))
        #expect(service.status(captureID: second.captureID) == .active)
        // Re-fencing the removed record is a no-op that cannot touch the
        // newer capture or its observer.
        service.fence(captureID: first.captureID, reason: .scroll)
        #expect(service.status(captureID: second.captureID) == .active)
        #expect(FileManager.default.fileExists(atPath: second.snapshotFile.path))
        // The newer capture still answers normally.
        transport.answerHandler = { _, _ in
            .answered(hits: [ImpeccableAnswerOutcome.Hit(top: 1, stack: [1], unanswerable: false, reason: nil)])
        }
        let factsURL = try await service.answerNeeds(
            captureID: second.captureID,
            needsJSON: impeccableNeedsData(points: [(10.0, 20.0)])
        )
        #expect(FileManager.default.fileExists(atPath: factsURL.path))
    }

    // MARK: - Trusted task workspace bridge root (R2)

    @Test("Trusted workspace root stages UUID-only files; symlinked bridges rejected")
    func trustedBridgeRootStaging() async throws {
        let (session, tabID) = makeSession()
        defer { session.release() }
        await waitLoaded(session, tabID: tabID)
        let transport = StubTransport()
        let service = makeService(session: session, transport: transport)
        installTrustedCapture(on: transport, session: session, tabID: tabID)
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("FloeImpeccableWorkspace-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }
        let resolvedWorkspace = workspace.standardizedFileURL.resolvingSymlinksInPath()

        let ticket = try await service.capture(tabID: tabID, bridgeRoot: workspace)
        #expect(ticket.bridgeRootIsTaskWorkspace)
        #expect(ticket.bridgeRoot == resolvedWorkspace)
        #expect(ticket.relativeDirectory == "Impeccable/\(ticket.binding.taskId)/\(ticket.captureID.uuidString)")
        #expect(ticket.relativeSnapshotFile == ticket.relativeDirectory + "/snapshot.v1.json")
        #expect(ticket.relativeIdentityFile == ticket.relativeDirectory + "/identity.v1.json")
        #expect(ticket.snapshotFile.path.hasPrefix(resolvedWorkspace.path + "/"))
        #expect(fileManager.fileExists(atPath: ticket.snapshotFile.path))
        #expect(fileManager.fileExists(atPath: ticket.identityFile.path))

        // The receipt is metadata-only: relative paths, binding, counts and
        // digests — no absolute host paths, no DOM, no snapshot bytes.
        let receipt = ticket.receipt
        #expect(receipt.captureId == ticket.captureID.uuidString)
        #expect(receipt.binding == ticket.binding)
        #expect(receipt.bridgeRootIsTaskWorkspace)
        #expect(receipt.relativeSnapshotFile == ticket.relativeSnapshotFile)
        #expect(receipt.scriptDigest == ticket.scriptDigest)
        let receiptText = try #require(String(data: receipt.encodedJSON(), encoding: .utf8))
        #expect(!receiptText.contains(resolvedWorkspace.path))
        #expect(!receiptText.contains("snapshotJson"))
        #expect(!receiptText.contains("<html"))

        // Facts also stage under the trusted root and report relative paths.
        transport.answerHandler = { _, _ in
            .answered(hits: [ImpeccableAnswerOutcome.Hit(top: 1, stack: [1], unanswerable: false, reason: nil)])
        }
        let factsURL = try await service.answerNeeds(
            captureID: ticket.captureID,
            needsJSON: impeccableNeedsData(points: [(10.0, 20.0)])
        )
        #expect(factsURL.path.hasPrefix(resolvedWorkspace.path + "/"))
        #expect(service.relativeBridgePath(of: factsURL, captureID: ticket.captureID)
            == ticket.relativeDirectory + "/facts.round1.v1.json")
        #expect(service.relativeBridgePath(of: URL(fileURLWithPath: "/etc/hosts"), captureID: ticket.captureID) == nil)

        // Cleanup deletes only the capture subtree, never the workspace.
        service.cleanup(captureID: ticket.captureID)
        #expect(!fileManager.fileExists(atPath: ticket.snapshotFile.path))
        #expect(fileManager.fileExists(atPath: resolvedWorkspace.path))

        // A symlinked bridge parent is rejected and never written through.
        let hostileTarget = fileManager.temporaryDirectory
            .appendingPathComponent("FloeImpeccableHostile-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: hostileTarget, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: hostileTarget) }
        let hostileWorkspace = fileManager.temporaryDirectory
            .appendingPathComponent("FloeImpeccableHostileRoot-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: hostileWorkspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: hostileWorkspace) }
        try fileManager.createSymbolicLink(
            at: hostileWorkspace.appendingPathComponent("Impeccable"),
            withDestinationURL: hostileTarget
        )
        await #expect(throws: ImpeccableCaptureError.self) {
            _ = try await service.capture(tabID: tabID, bridgeRoot: hostileWorkspace)
        }
        // Nothing was ever written through the substituted link (the empty
        // scaffolding directories the failed capture created are removed
        // with the temporary target; no staged file may exist).
        let hostileSubpaths = fileManager.subpathsOfDirectory(atPath: hostileTarget.path, errorHandler: nil) ?? []
        #expect(!hostileSubpaths.contains { $0.hasSuffix(".v1.json") })

        // Missing and non-directory roots are rejected before any work.
        await #expect(throws: ImpeccableCaptureError.self) {
            _ = try await service.capture(
                tabID: tabID,
                bridgeRoot: resolvedWorkspace.appendingPathComponent("does-not-exist")
            )
        }
        let fileRoot = resolvedWorkspace.appendingPathComponent("plain-file.txt")
        try Data("x".utf8).write(to: fileRoot)
        await #expect(throws: ImpeccableCaptureError.self) {
            _ = try await service.capture(tabID: tabID, bridgeRoot: fileRoot)
        }
        await #expect(throws: ImpeccableCaptureError.self) {
            _ = try await service.capture(tabID: tabID, bridgeRoot: URL(string: "https://example.test/")!)
        }
        // A symlinked root resolves to the same physical workspace instead of
        // staging through the link (iOS `/var` is itself a system symlink).
        let link = fileManager.temporaryDirectory
            .appendingPathComponent("FloeImpeccableLink-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: resolvedWorkspace)
        defer { try? fileManager.removeItem(at: link) }
        let resolvedTicket = try await service.capture(tabID: tabID, bridgeRoot: link)
        #expect(resolvedTicket.bridgeRoot == resolvedWorkspace)
        #expect(resolvedTicket.bridgeRootIsTaskWorkspace)
        #expect(fileManager.fileExists(atPath: resolvedTicket.snapshotFile.path))
    }

    // MARK: - Cancellation / in-flight fence (WebKit call mechanics)

    @Test("Task cancellation resolves the pending WebKit call exactly once")
    func callCancellation() async {
        let call = ImpeccableCall()
        let task = Task { @MainActor in
            try await call.run(deadline: ContinuousClock.now.advanced(by: .seconds(30))) { _ in
                // Deliberately never completes: only cancellation resolves it.
            }
        }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled call must throw")
        } catch let error as ImpeccableCaptureError {
            if case .cancelled = error {} else {
                Issue.record("expected cancelled, got \(error)")
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Fencing a pending WebKit call resolves it as superseded")
    func callFence() async {
        let call = ImpeccableCall()
        let task = Task { @MainActor in
            try await call.run(deadline: ContinuousClock.now.advanced(by: .seconds(30))) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(80))
        call.fence(reason: "navigation")
        do {
            _ = try await task.value
            Issue.record("fenced call must throw")
        } catch let error as ImpeccableCaptureError {
            if case .superseded = error {} else {
                Issue.record("expected superseded, got \(error)")
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A late WebKit callback cannot resume a finished call")
    func callSingleResolution() async {
        let call = ImpeccableCall()
        var storedCompletion: ImpeccableCall.Completion?
        let task = Task { @MainActor in
            try await call.run(deadline: ContinuousClock.now.advanced(by: .seconds(30))) { completion in
                storedCompletion = completion
            }
        }
        try? await Task.sleep(for: .milliseconds(80))
        call.fence(reason: "released")
        var superseded = false
        do {
            _ = try await task.value
        } catch let error as ImpeccableCaptureError {
            if case .superseded = error { superseded = true }
        }
        #expect(superseded)
        // A real callback landing afterwards must be ignored, not a second resume.
        storedCompletion?(.success(["ok": true]))
    }

    // MARK: - Frozen constants

    @Test("Frozen constants match the contract twin")
    func frozenConstants() {
        #expect(ImpeccableContract.stylePropCount == 138)
        #expect(ImpeccableContract.pseudoPropCount == 23)
        #expect(ImpeccableContract.statePseudoCount == 31)
        #expect(ImpeccableBudgets.frozenV1.maxSnapshotBytes == 50_331_648)
        #expect(ImpeccableBudgets.frozenV1.maxElements == 30_000)
        #expect(ImpeccableBudgets.frozenV1.maxRounds == 4)
        #expect(ImpeccableBudgets.frozenV1.maxHitTestsPerRound == 4_096)
        #expect(ImpeccableBudgets.frozenV1.maxHitTestsTotal == 16_384)
        #expect(ImpeccableBudgets.frozenV1.timeoutMs == 120_000)
        #expect(ImpeccableCoverage.v1Passes.count == 18)
        #expect(ImpeccableCoverage.uncoveredRequiredInV1.count == 6)
        #expect(ImpeccableContract.producerTrust == "native-fixed-script")
        #expect(ImpeccableContract.syntheticScriptDigest != ImpeccableProducerScript.pinnedRunBytesSHA256)
    }
}
#endif
