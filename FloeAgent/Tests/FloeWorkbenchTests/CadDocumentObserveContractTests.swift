// FloeWorkbenchTests — `cad.document action=observe` contract for the native
// read-only observation closure.
//
// This suite is DELIBERATELY host-only (no Metal, no OCCT package): it locks
// down argument normalization, generation-pin conflicts, native-selection
// refusals, original-file pin refusal, cancellation forwarding and the
// includeImages/no-artifact boundary. Real native pixels are covered by the
// App-host suite (Tests/FloeAppTests/CadNativeObservationTests.swift), which
// Root runs on the pinned Simulator.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import FloeWorkbench
import FloeTools
import FloeCore
import FloeModels

// MARK: - Recording host

/// Minimal real protocol conformance whose only interesting method is the
/// token-aware observation. Everything else stays an inert stub so the test
/// proves the TOOL contract instead of a fake engine.
actor ObserveRecordingHost: CadDocumentHost {
    var authorized = true
    var observeRequests: [(documentID: String, request: CadModelObservationRequest)] = []
    var lastCancellation: CancellationToken?
    var observeResult = CadModelObservationResult(summaryJSON: #"{"ok":true}"#, frames: [])
    var observeError: Error?

    func setAuthorized(_ value: Bool) { authorized = value }
    func setObserveResult(_ result: CadModelObservationResult) { observeResult = result }
    func setObserveError(_ error: Error?) { observeError = error }

    func authorizeAccess(access: CadDocumentAccess) async throws {
        if !authorized { throw FloeError.unauthorized }
    }

    func observeModel(documentID: String, request: CadModelObservationRequest,
                      access: CadDocumentAccess) async throws -> CadModelObservationResult {
        observeRequests.append((documentID, request))
        if let observeError { throw observeError }
        return observeResult
    }

    /// The production token-aware overload. A cancelled token must refuse
    /// BEFORE any work (the stub records only after the first check).
    func observeModel(documentID: String, request: CadModelObservationRequest,
                      access: CadDocumentAccess,
                      cancellation: CancellationToken) async throws -> CadModelObservationResult {
        try cancellation.throwIfCancelled()
        lastCancellation = cancellation
        observeRequests.append((documentID, request))
        if let observeError { throw observeError }
        try cancellation.throwIfCancelled()
        return observeResult
    }

    func capabilities(access: CadDocumentAccess) async throws -> String { #"{"ok":true}"# }

    func snapshot(documentID: String, access: CadDocumentAccess) async throws -> CadDocumentSnapshot {
        CadDocumentSnapshot(documentID: documentID, format: "floecad", revision: 1,
                            sha256: String(repeating: "a", count: 64), unit: "mm",
                            activeLayer: "0", entityCount: 0, layerCount: 0,
                            editable: true, diagnostics: [], capabilitiesJSON: "{}")
    }

    func query(documentID: String, requestJSON: String,
               access: CadDocumentAccess) async throws -> String { #"{"ok":true}"# }

    func prepareProposal(documentID: String, snapshot: CadDocumentSnapshot,
                         summary: String, operationsJSON: String,
                         access: CadDocumentAccess) async throws -> CadProposal {
        CadProposal(documentID: documentID, baseRevision: snapshot.revision,
                    baseSHA256: snapshot.sha256, summary: summary,
                    operationsJSON: operationsJSON,
                    preview: CadDiffPreview(added: [], changed: [], deleted: [],
                                            counts: ["added": 0, "changed": 0, "deleted": 0],
                                            truncated: false, note: "unused"))
    }

    func storeProposal(_ proposal: CadProposal) async throws {}
    func loadProposal(id: UUID, access: CadDocumentAccess) async throws -> CadProposal? { nil }
    func loadProposalOutcome(id: UUID,
                             access: CadDocumentAccess) async throws -> CadProposalOutcome? { nil }
    func verifyProposalBinding(_ proposal: CadProposal, documentID: String,
                               access: CadDocumentAccess) async throws {}
    func removeProposal(id: UUID) async throws {}

    func consumeGrant(grantID: String, proposalID: UUID, documentID: String,
                      revision: Int64, sha256: String) async -> CadGrantDecision {
        .unknownGrant
    }

    func apply(proposal: CadProposal, grantID: String, requestID: String,
               access: CadDocumentAccess) async throws -> CadDocumentReceipt {
        throw FloeError.unauthorized
    }

    func save(documentID: String, expectedSHA256: String, requestID: String,
              access: CadDocumentAccess) async throws -> CadDocumentReceipt {
        throw FloeError.unauthorized
    }

    func export(documentID: String, relativeOutput: String,
                access: CadDocumentAccess) async throws -> CadExportReceipt {
        throw FloeError.unauthorized
    }
}

// MARK: - Helpers

@Suite("cad.document observe contract")
struct CadDocumentObserveContractTests {
    private let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("observe-contract-\(UUID().uuidString)", isDirectory: true)

    private func context(_ token: CancellationToken = CancellationToken()) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "observe-call-\(UUID().uuidString)",
                    scope: .local, workspaceRootURL: workspace,
                    cancellation: token, environmentID: "env-1", conversationID: UUID())
    }

    private func decode(_ json: String) throws -> CadDocumentArguments {
        try JSONDecoder().decode(CadDocumentArguments.self, from: Data(json.utf8))
    }

    /// Builds the payload JSON string from a Swift dictionary so quoting never
    /// changes the field names under test.
    private func payload(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func observeArguments(path: String,
                                  payload object: [String: Any] = ["includeImages": false],
                                  revision: Int64? = nil) throws -> CadDocumentArguments {
        var fields: [String: Any] = [
            "action": "observe",
            "path": path,
            "payload": try payload(object),
        ]
        if let revision { fields["revision"] = revision }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return try JSONDecoder().decode(CadDocumentArguments.self, from: data)
    }

    // MARK: Native arguments

    @Test("native observe is accepted for an authorised .floecad path and forwards the exact token")
    func nativeObserveForwardsRequestAndToken() async throws {
        let host = ObserveRecordingHost()
        let tool = CadDocumentTool(host: host)
        let token = CancellationToken()
        let args = try observeArguments(path: "parts/plate.floecad")
        try tool.validate(args)
        let output = try await tool.execute(args, context: context(token))
        #expect(output.summary.hasPrefix("cad.document observe:"))
        #expect(output.artifacts.isEmpty)

        let requests = await host.observeRequests
        #expect(requests.count == 1)
        #expect(requests.first?.documentID == "parts/plate.floecad")
        #expect(requests.first?.request.includeImages == false)
        #expect(requests.first?.request.nodeOffset == 0)
        #expect(requests.first?.request.nodeLimit == 200)
        let forwarded = try #require(await host.lastCancellation)
        #expect(forwarded === token, "the host must receive the exact per-call token")
    }

    @Test("the reported named-view request reaches the native observer as real camera angles")
    func namedViewsReachNativeObserver() async throws {
        let host = ObserveRecordingHost()
        let tool = CadDocumentTool(host: host)
        let args = try observeArguments(path: "gear20.floecad", payload: [
            "views": ["isometric", "top", "front"],
            "projection": "orthographic", "includeImages": false,
        ])
        try tool.validate(args)
        _ = try await tool.execute(args, context: context())
        let request = try #require(await host.observeRequests.first?.request)
        #expect(request.views == [
            .init(azimuthDegrees: 36, elevationDegrees: 180 / 7),
            .init(azimuthDegrees: 0, elevationDegrees: 90),
            .init(azimuthDegrees: 0, elevationDegrees: 0),
        ])
        #expect(request.projection == .orthographic)
        let encoded = try JSONEncoder().encode(request)
        let reopened = try JSONDecoder().decode(CadModelObservationRequest.self, from: encoded)
        #expect(reopened == request)
    }

    @Test("unknown view names produce actionable validation instead of a generic decoder error")
    func unknownViewNamesAreActionable() throws {
        let tool = CadDocumentTool(host: ObserveRecordingHost())
        let args = try observeArguments(path: "p.floecad", payload: ["views": ["sideways"]])
        do {
            try tool.validate(args)
            Issue.record("Unknown view name was accepted")
        } catch let error as FloeError {
            #expect(error.localizedDescription.contains("azimuthDegrees"))
            #expect(error.localizedDescription.contains("front"))
        }
    }

    @Test("the top-level revision actually reaches the host as the native generation pin")
    func topLevelRevisionReachesHost() async throws {
        let host = ObserveRecordingHost()
        let tool = CadDocumentTool(host: host)
        let args = try observeArguments(path: "p.floecad", revision: 11)
        try tool.validate(args)
        _ = try await tool.execute(args, context: context())
        let requests = await host.observeRequests
        #expect(requests.count == 1)
        #expect(requests.first?.request.expectedRevision == 11)
    }

    @Test("top-level revision is the SAME native pin as payload.expectedRevision")
    func topLevelRevisionPinMergesAndConflicts() throws {
        let tool = CadDocumentTool(host: ObserveRecordingHost())

        // Top-level only.
        var request = try CadDocumentTool.modelObservationRequest(
            try observeArguments(path: "p.floecad", revision: 9), native: true)
        #expect(request.expectedRevision == 9)

        // Payload pin only.
        request = try CadDocumentTool.modelObservationRequest(
            try observeArguments(path: "p.floecad",
                                 payload: ["includeImages": false, "expectedRevision": 9]),
            native: true)
        #expect(request.expectedRevision == 9)

        // Equal pins are accepted.
        request = try CadDocumentTool.modelObservationRequest(
            try observeArguments(path: "p.floecad",
                                 payload: ["includeImages": false, "expectedRevision": 9],
                                 revision: 9),
            native: true)
        #expect(request.expectedRevision == 9)

        // Disagreeing pins are refused.
        #expect(throws: FloeError.self) {
            _ = try CadDocumentTool.modelObservationRequest(
                try observeArguments(path: "p.floecad",
                                     payload: ["includeImages": false, "expectedRevision": 9],
                                     revision: 10),
                native: true)
        }
        // A negative top-level revision is refused before the host.
        #expect(throws: FloeError.self) {
            try tool.validate(try observeArguments(path: "p.floecad", revision: -1))
        }
    }

    @Test("native generation pins survive the Codable round trip and validate")
    func pinCodableRoundTrip() throws {
        let request = CadModelObservationRequest(
            expectedRevision: 3, expectedChangeCount: 7, includeImages: false)
        try request.validate()
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CadModelObservationRequest.self, from: data)
        #expect(decoded.expectedRevision == 3)
        #expect(decoded.expectedChangeCount == 7)
        #expect(decoded.hasNativeGenerationPins)
        var negative = CadModelObservationRequest(expectedRevision: -1,
                                                  includeImages: false)
        #expect(throws: FloeError.self) { try negative.validate() }
        negative = CadModelObservationRequest(expectedChangeCount: -1,
                                              includeImages: false)
        #expect(throws: FloeError.self) { try negative.validate() }
    }

    @Test("near-miss pin spellings are refused instead of silently ignored")
    func nearMissPinsAreRefused() throws {
        let tool = CadDocumentTool(host: ObserveRecordingHost())
        #expect(throws: FloeError.self) {
            try tool.validate(try observeArguments(
                path: "p.floecad", payload: ["includeImages": false, "revision": 4]))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(try observeArguments(
                path: "p.floecad",
                payload: ["includeImages": false, "expected_change_count": 4]))
        }
    }

    @Test("the top-level reference CAS field is refused instead of being ignored by observe")
    func topLevelSourceCASIsNotAnObservePin() throws {
        let fields: [String: Any] = [
            "action": "observe",
            "path": "p.floecad",
            "payload": try payload(["includeImages": false]),
            "expected_source_sha256": String(repeating: "a", count: 64),
        ]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let args = try JSONDecoder().decode(CadDocumentArguments.self, from: data)
        #expect(throws: FloeError.self) {
            _ = try CadDocumentTool.modelObservationRequest(args, native: true)
        }
    }

    @Test("native selection refuses asset camera, clip, time and non-root scene")
    func nativeSelectionRefusals() throws {
        let tool = CadDocumentTool(host: ObserveRecordingHost())
        for payloadObject in [
            ["includeImages": false, "cameraIndex": 0],
            ["includeImages": false, "clipIndex": 0],
            ["includeImages": false, "clipIndex": 0, "timeSeconds": 0.5],
            ["includeImages": false, "timeSeconds": 1],
            ["includeImages": false, "sceneIndex": 1],
        ] as [[String: Any]] {
            #expect(throws: FloeError.self) {
                try tool.validate(try observeArguments(path: "p.floecad",
                                                       payload: payloadObject))
            }
        }
        // sceneIndex 0 / time 0 remain valid no-op selections.
        try tool.validate(try observeArguments(
            path: "p.floecad",
            payload: ["includeImages": false, "sceneIndex": 0, "timeSeconds": 0]))
    }

    @Test("native observe reports unsupported selections with the animation route")
    func nativeSelectionMessageNamesAnimationRoute() throws {
        let request = CadModelObservationRequest(clipIndex: 0, includeImages: false)
        let refusal = try #require(request.nativeSelectionRefusal())
        #expect(refusal.contains("animation"))
        let camera = CadModelObservationRequest(cameraIndex: 0, includeImages: false)
        #expect(try #require(camera.nativeSelectionRefusal()).contains("cameraIndex"))
        let scene = CadModelObservationRequest(sceneIndex: 2, includeImages: false)
        #expect(try #require(scene.nativeSelectionRefusal()).contains("sceneIndex"))
    }

    // MARK: Original behaviour

    @Test("original observation refuses native-only pins instead of ignoring them")
    func originalRefusesNativePins() throws {
        let tool = CadDocumentTool(host: ObserveRecordingHost())
        for payloadObject in [
            ["includeImages": false, "expectedRevision": 3],
            ["includeImages": false, "expectedChangeCount": 4],
        ] as [[String: Any]] {
            #expect(throws: FloeError.self) {
                try tool.validate(try observeArguments(path: "wedge.stl",
                                                       payload: payloadObject))
            }
        }
        // A top-level revision is native-only for observe as well.
        #expect(throws: FloeError.self) {
            try tool.validate(try observeArguments(path: "wedge.stl", revision: 3))
        }
        // The historical original request stays valid.
        try tool.validate(try observeArguments(
            path: "wedge.stl",
            payload: ["includeImages": false,
                      "expectedSourceSHA256": String(repeating: "a", count: 64)]))
    }

    @Test("includeImages=false gets the query-only result and never writes artifacts")
    func includeImagesFalseIsQueryOnly() async throws {
        let host = ObserveRecordingHost()
        await host.setObserveResult(CadModelObservationResult(
            summaryJSON: #"{"ok":true,"representation":"native_floecad","hierarchy":{"rows":[]}}"#,
            frames: []))
        let tool = CadDocumentTool(host: host)
        let output = try await tool.execute(
            try observeArguments(path: "p.floecad"), context: context())
        #expect(output.artifacts.isEmpty)
        #expect(output.summary.contains(#""representation":"native_floecad""#))
        #expect(await host.observeRequests.count == 1)
    }

    @Test("observe publishes no workspace output files and never asks for user action")
    func observeIsReadOnlyOutsideItsImageArtifacts() async throws {
        let host = ObserveRecordingHost()
        await host.setObserveResult(CadModelObservationResult(
            summaryJSON: #"{"ok":true,"representation":"native_floecad"}"#, frames: []))
        let tool = CadDocumentTool(host: host)
        let output = try await tool.execute(
            try observeArguments(path: "p.floecad"), context: context())
        #expect(output.outputFiles.isEmpty)
        #expect(output.requiresUserAction == false)
        #expect(output.artifacts.isEmpty)
    }

    @Test("a requested image must actually be returned as bounded PNG frames")
    func requestedImagesMustBeReturned() async throws {
        let host = ObserveRecordingHost()
        await host.setObserveResult(CadModelObservationResult(summaryJSON: #"{"ok":true}"#,
                                                              frames: []))
        let tool = CadDocumentTool(host: host)
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(
                try observeArguments(path: "p.floecad", payload: ["includeImages": true]),
                context: context())
        }
    }

    @Test("an already-cancelled run refuses before the host observes")
    func cancelledTokenRefusesBeforeHost() async throws {
        let host = ObserveRecordingHost()
        let tool = CadDocumentTool(host: host)
        let token = CancellationToken()
        token.cancel()
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(try observeArguments(path: "p.floecad"),
                                       context: context(token))
        }
        #expect(await host.observeRequests.isEmpty)
    }

    // MARK: Discovery surface

    @Test("tool description and payload schema advertise the native observation contract")
    func discoveryAdvertisesNativePins() throws {
        let payloadHelp = try #require(CadDocumentHelp.fullText(for: "payloads"))
        #expect(payloadHelp.contains("expectedRevision"))
        #expect(payloadHelp.contains("expectedChangeCount"))
        #expect(payloadHelp.contains("renderer=engineering"))
        let data = Data(CadDocumentTool.parametersJSON.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        let enumValues = Set(try #require(action["enum"] as? [String]))
        #expect(enumValues.contains("observe"))
        let payloadDescription = try #require(
            (properties["payload"] as? [String: Any])?["description"] as? String)
        #expect(payloadDescription.contains("expectedRevision"))
        #expect(payloadDescription.contains("expectedChangeCount"))
        #expect(payloadDescription.contains("present_pixels=false"))
        #expect(payloadDescription.contains("nodeOffset"))
        let revisionDescription = try #require(
            (properties["revision"] as? [String: Any])?["description"] as? String)
        #expect(revisionDescription.contains("observe"))
    }
}
