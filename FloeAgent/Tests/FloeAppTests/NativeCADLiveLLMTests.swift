// SPDX-License-Identifier: MPL-2.0
//
// FloeAppTests — OPT-IN, App-hosted, REAL-LLM native CAD acceptance.
//
// This is source preparation only in the current worker. The primary must
// register the file in `FloeAgent/project.yml`, freeze the source, compile the
// App test host once and run this ONE selector on the canonical iPad
// Simulator after that compile. No App/SPM build, test execution, Simulator,
// paid model call or credential read outside the App was performed while
// writing this file.
//
// What the test proves WHEN IT ACTUALLY RUNS
// ------------------------------------------
// One synthetic, task-owned native `.floecad` bracket flows through the real
// configured chat model, the real App tool catalog (`cad.document`) and the
// real `ConversationRunService`, across FOUR ordinary turns:
//
//   1. create the native package, a 80 × 50 × 10 mm plate and a Ø6 through
//      hole, then save;
//   2. capture an actual 1024 × 768 engineering viewport PNG of that saved
//      revision, receive it as a real outbound provider image part, then make
//      the requested correction on the EXISTING hole circle (same sketch/entity
//      identity, Ø6 → Ø8), add a 2 mm fillet on the vertical corner edge(s)
//      and save;
//   3. undo the fillet and the hole edit with the real native `parameters`
//      action "undo" (each undo is one saved undoable command), read the state
//      back and save;
//   4. close the live bridge through its owner lifecycle, reopen the same saved
//      package from disk, make one further real edit to the SAME hole (radius
//      3 → 5, Ø10), save it, read it back, and capture the final engineering
//      viewport PNG as the LAST tool call so the image binds the final package.
//
// Why four turns instead of the original three: the real undo stack only
// survives while the SAME live bridge/document session stays open, and the
// acceptance also requires closing that bridge, reopening the saved package and
// editing it again. Combining undo and reopen in one turn would either lose the
// native undo stack or leave no independent on-disk state to verify after the
// undo. Four bounded turns keep every important state independently verifiable
// on disk without adding another model, tool or engine. The aggregate ceiling
// is unchanged: ONE 1,000,000 reported-token budget across every owned run and
// one 2,700 s aggregate wall-clock deadline (900 s per turn).
//
// The assertions read the bytes on disk with an independent `FloeCADDocument`
// reopen: body identity, analytic B-rep, hole diameter, fillet radius/edge
// count, exact plate-minus-hole-minus-fillet volume, the exact canonical model
// identity after undo, revision growth and both capture PNGs. The visual
// receipt is not inferred from `supportsVision`: the bounded observer below
// reads the durable provider-dispatch checkpoint and requires the exact
// capture image to be present as an outbound image part for the selected
// vision model, then binds the following correction to the same document
// revision and stable hole identity. Model prose is never evidence. A tool
// success string alone is never evidence. A text-only model that did not
// deliver an actual image part is an explicit failure, not a pass.
//
// Opt-in and credential policy
// ----------------------------
// The test is DISABLED unless a coordinator/primary writes this non-secret
// cache file for the simulator App container:
//
//   <Caches>/FloeNativeCADLiveQualification/opt-in.json
//
// See the private handoff for the exact schema. The file contains policy
// metadata only (optional provider/model UUID pins, an explicit acceptance of
// the ordinary App run context, token/cost/time ceilings, and an optional
// prepaid budget basis). It NEVER contains an API key. An optional
// owned-route.json contains only test provider metadata. If the coordinator
// explicitly forwards a test-runner credential, the owned-route helper puts it
// in a random non-syncing App Keychain account, removes its own
// provider/account after the run and never changes an existing provider or
// default. Otherwise it asks the App's own
// `ConversationCenter.resolveCredentials`
// whether the selected provider has a usable key and then hands the run to the
// same production `ConversationCenter.runService` the UI uses. A missing file,
// missing cheap/tool-capable cloud model, missing App credential or missing
// pricing metadata is an explicit `XCTSkip` and a handoff blocker — never a
// live pass.
//
// The opt-in may instead declare `prepaidBudgetBasis: true` for the reviewed
// owned Agent Plan route. That mode is accepted only with the exact reserved
// provider/model UUIDs, the exact Agent Plan base URL, a reviewed same-plan
// remote model ID, a capability flag that matches that review (native image
// input on or off exactly as reviewed), no usable model pricing metadata, no
// unpinned/fallback selection and explicit zero input/output increments.
// Usage is then reported as prepaid-plan consumption with the ordinary token
// and wall-clock ceilings; it is never described as free market pricing and
// never becomes a generic zero-price model path. The reviewed native-image
// candidates are metadata-only allowlist entries copied from the official
// Agent Plan supported-models page (updated 2026-10-29); no model, URL or
// price is hard-pinned here and no entitlement is assumed. The private source
// receipt is `verification/cad-live-vision-route-source-review.json`.
//
// The X35 selector itself requires a direct-vision route: the model that
// actually receives the capture must declare image input, and the outbound
// request must carry the verified image part. A text-only primary model whose
// image was only described by a helper, OCR text, tool metadata or model prose
// cannot pass this selector; that is an honest insufficiency, not a skip.
//
// Cost/data bounding and approval policy
// --------------------------------------
// The synthetic task gets its OWN durable task policy:
//   * `approvalMode = automatic` (the real App policy; native CAD document
//     edits are deterministically exempt, so no approval popup or approval
//     model is required);
//   * the executable tool ceiling is exactly `cad.document` (no browser,
//     shell, Linux guest, Python, filesystem-wide, network or external-send
//     tool can be called);
//   * the workspace is the conversation's own private task workspace.
// No fake approval grant is minted or supplied. The model's apply calls must
// omit `grant_id`; the runtime-issued authority for the exact call is the only
// path exercised. The test asserts there is no approval event and no pending
// approval.
//
// A watchdog polls the durable usage records and cancels the run if the
// computed model cost, an individual token dimension or the reported aggregate
// token budget exceeds the opt-in ceiling. Every run also has a wall-clock
// deadline. Those are hard stops, not claims that a skipped/failed turn passed.
//
// The token budget is ONE aggregate cap across all owned model turns:
// `maxTotalTokens` counts uncached input + cache read + output, summed over
// every run. Reasoning tokens are already inside the provider's output count
// and cache-write tokens are already inside its input count, so neither is
// added again. `maxInputTokens` and `maxOutputTokens` may each be 1,000,000,
// but the aggregate guard still stops the combined reported total at the cap.
// The reviewed prepaid basis requires `maxTotalTokens`; a legacy metered
// opt-in that omits it keeps the previous separate input/output caps only.
// `maxTotalSeconds` is enforced as a real aggregate deadline in addition to
// the XCTest time allowance, so four turns cannot silently outlive the
// approved 2,700 s window.
//
// Isolation and cleanup
// ---------------------
// The test creates a fresh conversation UUID, lets `RunLaunchStore` create its
// private task workspace atomically, and deliberately calls
// `ConversationCenter.runService` + `ConversationRunService.startPrepared`
// instead of `startTask`/`startRun`. That is the same production service the
// UI constructs, but it does not run the conversation-center post-run
// personalization/title/memory-dream hooks for a synthetic goal. It does NOT
// strip the ordinary App's bounded personalization context from the provider
// prompt; the opt-in must explicitly acknowledge that real-App context. Empty
// `memoryQuery` avoids the embedding write path.
//
// Cleanup first cancels and joins every owned run service (no late callback
// can land in another document), then removes ONLY this task's
// conversation/workspace, every owned run ID's content snapshots, skill run
// snapshots and CAD viewport artifact directories, plus the bridge's live
// document. The App's saved provider
// configuration, global default model, personalization documents and memory
// are never written by this test. The durable CAD proposal store keeps the
// settled proposal record(s) for the deleted synthetic document (the product
// store has no delete-settled API; it prunes oldest settled records at its
// bound). That bounded, non-secret residue is disclosed in the handoff.
//
// Integration (primary)
// ---------------------
// 1. Add `Tests/FloeAppTests/NativeCADLiveLLMTests.swift` to the FloeAppTests
//    sources in `FloeAgent/project.yml` and regenerate the project.
// 2. Compile the App test host once in the normal batch.
// 3. Write the private opt-in and owned-route metadata into the launched App's
//    Caches directory. For this selector the owned-route `remoteModelID` must
//    be one of the reviewed same-plan native-image candidates and
//    `supportsVision` must be true; the opt-in must name the same remote ID.
// 4. Run only:
//      FloeAppTests/NativeCADLiveLLMTests/
//        testRealModelCreatesEditsHoleFilletsCapturesAndReopensNativeBracket
//    on the canonical reused iPad Simulator, with parallel testing disabled.
// 5. A skip is zero live evidence. Do not report this acceptance as passed
//    from a skip or from this source-only handoff.
//
// The non-paid contract tests in this file (`NativeCADLiveBudgetTests`,
// `NativeCADLiveVisionContractTests` and `NativeCADSaveIdentityAppTests`) may
// be run without an opt-in file, provider credential or provider request.
//
// The exact scenario, ceilings and cleanup limitations are documented in
// `Local/Private/cad106-native-closure-20261031/cad-live-visual-loop-acceptance/`
// and the original handoff in `Local/Private/native-browser-cad-context-20261030/
// continuation/native-cad-llm-acceptance/`.

#if canImport(UIKit) && DEBUG && targetEnvironment(simulator)
import Foundation
import XCTest
import CoreGraphics
import ImageIO
import FloeCore
import FloeModels
import FloePersistence
import GRDB
import FloeProviders
import FloeTools
import FloeWorkbench
import FloeAgentRuntime
import FloeEnvironments
import FloeSecurity
import FloeCAD
@testable import FloeApp

@MainActor
final class NativeCADLiveLLMTests: XCTestCase {

    func testRealModelCreatesEditsHoleFilletsCapturesAndReopensNativeBracket() async throws {
        let optIn = try NativeCADLiveOptIn.load()
        executionTimeAllowance = optIn.executionTimeAllowance
        continueAfterFailure = true

        // Joins the ACTUAL launched App graph (same database, provider list,
        // tool registry, CAD host and credential resolution). Never creates a
        // second environment or a replacement provider.
        let environment = try await appQualificationEnvironment()
        let center = environment.conversationCenter

        // Optional coordinator-owned route: non-secret metadata plus an
        // explicitly forwarded test-runner credential. The App still stores
        // and resolves the credential through its ordinary Keychain service.
        let installed = try await NativeCADLiveOwnedRoute.installIfRequested(environment: environment)
        do {
            let route = try NativeCADLiveRoute.select(optIn: optIn, center: center)
            try NativeCADLivePreflight.requireNativeCADCapabilities()
            // The enhanced X35 loop needs direct image delivery to the model
            // that makes the correction. This is checked before any paid turn;
            // a text-only route is an explicit insufficiency, never a pass.
            try NativeCADLivePreflight.requireDirectVision(route: route)
            let session = NativeCADLiveSession(
                environment: environment, center: center, route: route, optIn: optIn)
            do { try await session.runAll() }
            catch {
                session.recordFailure(error)
                await session.cleanup()
                throw error
            }
            await session.cleanup()
        } catch {
            try await installed?.remove(environment: environment)
            throw error
        }
        try await installed?.remove(environment: environment)
    }

    func testRealModelBindsVariablesRebuildsAndUndoesNativeFormulas() async throws {
        let optIn = try NativeCADLiveOptIn.load()
        executionTimeAllowance = optIn.executionTimeAllowance
        continueAfterFailure = true
        let environment = try await appQualificationEnvironment()
        let center = environment.conversationCenter
        let installed = try await NativeCADLiveOwnedRoute.installIfRequested(environment: environment)
        do {
            let route = try NativeCADLiveRoute.select(optIn: optIn, center: center)
            try NativeCADLivePreflight.requireNativeCADCapabilities()
            let session = NativeCADLiveSession(
                environment: environment, center: center, route: route, optIn: optIn)
            do { try await session.runVariableFormulaLoop() }
            catch {
                session.recordFailure(error)
                await session.cleanup()
                throw error
            }
            await session.cleanup()
        } catch {
            try await installed?.remove(environment: environment)
            throw error
        }
        try await installed?.remove(environment: environment)
    }
}

/// Receipt pairing and an optional replay of actual retained tool events.
/// This class never starts a run, resolves a credential or requests a model.
@MainActor
final class NativeCADLiveCaptureEvidenceTests: XCTestCase {
    private func event(_ sequence: Int, _ kind: RunEventRecord.Kind,
                       _ payload: [String: Any]) throws -> RunEventRecord {
        RunEventRecord(runID: UUID(), sequence: sequence, kind: kind,
                       payloadJSON: String(decoding: try JSONSerialization.data(
                        withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self))
    }

    private func captureRequest(_ sequence: Int, _ id: String) throws -> RunEventRecord {
        try event(sequence, .toolRequest, ["tool": CadDocumentTool.name, "id": id,
                                          "input": #"{"action":"capture"}"#])
    }

    private func captureResult(_ sequence: Int, _ id: String,
                               status: String = "ok") throws -> RunEventRecord {
        try event(sequence, .toolResult, ["tool": CadDocumentTool.name, "id": id,
                                         "status": status, "summary": "capture receipt"])
    }

    func testRejectedCaptureRetrySelectsTheSuccessfulReceiptRequest() throws {
        let events = try [captureRequest(1, "rejected"),
                          captureResult(3, "rejected", status: "failed"),
                          captureRequest(6, "captured"), captureResult(9, "captured")]
        let request = try XCTUnwrap(NativeCADLiveEvidence.successfulCaptureRequest(
            events, resultSequence: 9))
        XCTAssertEqual(request.callID, "captured")
        XCTAssertEqual(request.sequence, 6)
    }

    func testFailedOrUnpairedCaptureCannotSatisfyTheReceipt() throws {
        let rejected = try [captureRequest(1, "rejected"),
                            captureResult(3, "rejected", status: "failed")]
        XCTAssertNil(NativeCADLiveEvidence.successfulCaptureRequest(rejected, resultSequence: 3))
        let unpaired = try [captureRequest(1, "requested"), captureResult(3, "different")]
        XCTAssertNil(NativeCADLiveEvidence.successfulCaptureRequest(unpaired, resultSequence: 3))
        let reversed = try [captureResult(1, "reversed"), captureRequest(3, "reversed")]
        XCTAssertNil(NativeCADLiveEvidence.successfulCaptureRequest(reversed, resultSequence: 1))
    }

    func testLaterSuccessfulCaptureCannotReplaceTheVerifiedResultSequence() throws {
        let events = try [captureRequest(1, "verified"), captureResult(3, "verified"),
                          captureRequest(6, "later"), captureResult(9, "later")]
        XCTAssertEqual(NativeCADLiveEvidence.successfulCaptureRequest(
            events, resultSequence: 3)?.callID, "verified")
        XCTAssertNil(NativeCADLiveEvidence.successfulCaptureRequest(events, resultSequence: 8))
    }

    func testObservedLiveCaptureRetryPassesTheFullOriginalVisualTurnChecks() throws {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
            .appendingPathComponent(NativeCADLiveOptIn.directoryName, isDirectory: true)
        let recordURL = caches.appendingPathComponent("observed-replay.json")
        let imageURL = caches.appendingPathComponent("observed-capture.png")
        guard FileManager.default.fileExists(atPath: recordURL.path),
              FileManager.default.fileExists(atPath: imageURL.path) else {
            throw XCTSkip("No retained live tool-event replay was supplied; not live acceptance evidence.")
        }
        let data = try Data(contentsOf: recordURL)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runs = try XCTUnwrap(record["runs"] as? [String: [String: Any]])
        let observed = try runs.map { runID, run -> [RunEventRecord] in
            let id = try XCTUnwrap(UUID(uuidString: runID))
            return try XCTUnwrap(run["events"] as? [[String: Any]]).map { raw in
                RunEventRecord(runID: id,
                    sequence: try XCTUnwrap(raw["sequence"] as? Int),
                    kind: try XCTUnwrap(RunEventRecord.Kind(
                        rawValue: try XCTUnwrap(raw["kind"] as? String))),
                    payloadJSON: try XCTUnwrap(raw["payloadJSON"] as? String))
            }
        }
        let visualTurns = observed.filter { events in
            events.contains { event in
                guard event.kind == .toolResult,
                      let payload = NativeCADLiveJSON.object(event.payloadJSON) else { return false }
                return payload["status"] as? String == "ok"
                    && (payload["summary"] as? String ?? "").contains("cad.document capture:")
            } && events.contains { event in
                event.kind == .toolResult
                    && NativeCADLiveJSON.object(event.payloadJSON)?["status"] as? String == "failed"
            }
        }
        XCTAssertEqual(visualTurns.count, 1)
        let events = try XCTUnwrap(visualTurns.first)
        let captured = try XCTUnwrap(events.first { event in
            guard event.kind == .toolResult,
                  let payload = NativeCADLiveJSON.object(event.payloadJSON) else { return false }
            return payload["status"] as? String == "ok"
                && (payload["summary"] as? String ?? "").contains("cad.document capture:")
        })
        let result = try XCTUnwrap(NativeCADLiveJSON.object(captured.payloadJSON))
        let receipt = try XCTUnwrap(NativeCADLiveJSON.objects(
            in: try XCTUnwrap(result["summary"] as? String)).last)
        let png = try Data(contentsOf: imageURL)
        let capture = NativeCADLiveCapture(png: png,
            imageSHA256: try XCTUnwrap(receipt["image_sha256"] as? String),
            contentSHA256: try XCTUnwrap(receipt["content_sha256"] as? String),
            revision: try XCTUnwrap(NativeCADLiveJSON.int(receipt["revision"])),
            width: try XCTUnwrap(NativeCADLiveJSON.int(receipt["width"])),
            height: try XCTUnwrap(NativeCADLiveJSON.int(receipt["height"])),
            byteCount: try XCTUnwrap(NativeCADLiveJSON.int(receipt["byte_count"])),
            renderer: try XCTUnwrap(receipt["renderer"] as? String),
            relativePath: try XCTUnwrap(receipt["artifact"] as? String),
            callID: try XCTUnwrap(result["id"] as? String), resultSequence: captured.sequence)
        XCTAssertEqual(FloeDigest.sha256Hex(png), capture.imageSHA256)
        XCTAssertEqual(png.count, capture.byteCount)
        var originalCircle: NativeCADLiveCircle?
        for event in events where event.kind == .toolResult {
            guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  payload["status"] as? String == "ok",
                  let summary = payload["summary"] as? String,
                  let object = NativeCADLiveJSON.objects(in: summary).last,
                  let result = object["result"] as? [String: Any],
                  let rows = result["rows"] as? [[String: Any]] else { continue }
            for sketch in rows {
                guard let id = sketch["id"] as? String,
                      let entities = sketch["entityRows"] as? [[String: Any]] else { continue }
                for entity in entities where entity["kind"] as? String == "circle" {
                    guard let entityID = entity["id"] as? String,
                          let radius = NativeCADLiveJSON.number(entity["radius"]), radius == 3,
                          let diameter = NativeCADLiveJSON.number(entity["diameterMM"]) else { continue }
                    originalCircle = NativeCADLiveCircle(sketchID: id, entityID: entityID,
                                                         radius: radius, diameter: diameter)
                }
            }
        }
        let calls = try NativeCADLiveEvidence.assertTurnTwoEvidence(
            events, capture: capture, initialCircle: XCTUnwrap(originalCircle))
        XCTAssertFalse(calls.correctionCallID.isEmpty)
        XCTAssertFalse(calls.filletCallID.isEmpty)
        let attachment = XCTAttachment(string:
            "Observed events sha256=\(FloeDigest.sha256Hex(data)); PNG sha256=\(capture.imageSHA256); "
                + "captureCall=\(capture.callID); resultSequence=\(capture.resultSequence). "
                + "Full original visual-turn assertions replayed; no new model request.")
        attachment.name = "observed-live-capture-replay-provenance.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Non-paid accounting tests for the one aggregate CAD budget. They exercise
/// the same ledger the live acceptance uses, but never touch the App graph, a
/// provider, a credential, an opt-in file, the network or a model request.
@MainActor
final class NativeCADLiveBudgetTests: XCTestCase {

    /// Synthetic, test-only pricing. The metered basis uses positive exact
    /// integers; the prepaid basis stays on the reviewed exact-route shape.
    private func makeLedger(
        basis: NativeCADLiveBudgetBasis = .prepaidAgentPlan,
        maxInput: Int = 1_000_000,
        maxOutput: Int = 1_000_000,
        maxTotal: Int?
    ) -> NativeCADLiveLedger {
        let pricing: NativeCADLivePricing
        switch basis {
        case .prepaidAgentPlan:
            pricing = NativeCADLivePricing(
                inputPerMillion: .zero,
                outputPerMillion: .zero,
                basis: .prepaidAgentPlan
            )
        case .meteredUSD:
            pricing = NativeCADLivePricing(
                inputPerMillion: Decimal(1),
                outputPerMillion: Decimal(2),
                basis: .meteredUSD
            )
        }
        return NativeCADLiveLedger(
            pricing: pricing,
            maxCost: Decimal(10),
            maxInputTokens: maxInput,
            maxOutputTokens: maxOutput,
            maxTotalTokens: maxTotal
        )
    }

    private func record(
        _ runID: UUID,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0
    ) -> RunUsageRecord {
        RunUsageRecord(
            runID: runID,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning
        )
    }

    func testReportedAggregateCountsEachDimensionOnce() async {
        let runID = UUID()
        let ledger = makeLedger(maxTotal: 1_000_000)
        let totals = await ledger.update(runID: runID, records: [
            record(
                runID,
                input: 500_000,
                output: 80_000,
                cacheRead: 400_000,
                cacheWrite: 50_000,
                reasoning: 70_000
            ),
        ])
        XCTAssertEqual(totals.inputTokens, 500_000)
        XCTAssertEqual(totals.outputTokens, 80_000)
        XCTAssertEqual(totals.cacheReadTokens, 400_000)
        XCTAssertEqual(
            totals.reportedTotalTokens,
            980_000,
            "The aggregate must be uncached input + cache read + output; cache write is already "
                + "inside provider input and reasoning is already inside output."
        )
        XCTAssertTrue(totals.hasUsage)
        XCTAssertFalse(totals.exceeds)
        XCTAssertEqual(totals.cost, Decimal.zero)
    }

    func testCacheReadOnlyUsageCountsAsReportedUsage() async {
        let runID = UUID()
        let ledger = makeLedger(maxTotal: 1_000_000)
        let totals = await ledger.update(runID: runID, records: [
            record(runID, input: 0, output: 0, cacheRead: 750_000),
        ])
        XCTAssertEqual(totals.inputTokens, 0)
        XCTAssertEqual(totals.outputTokens, 0)
        XCTAssertEqual(totals.cacheReadTokens, 750_000)
        XCTAssertEqual(totals.reportedTotalTokens, 750_000)
        XCTAssertTrue(
            totals.hasUsage,
            "A fully cached prompt with no new output is still reported token usage."
        )
        XCTAssertFalse(totals.exceeds)
    }

    func testAggregateBoundaryIsInclusiveAndOneTokenOverFails() async {
        let runID = UUID()
        let ledger = makeLedger(maxTotal: 1_000_000)
        let atBoundary = await ledger.update(runID: runID, records: [
            record(runID, input: 500_000, output: 100_000, cacheRead: 400_000),
        ])
        XCTAssertEqual(atBoundary.reportedTotalTokens, 1_000_000)
        XCTAssertFalse(atBoundary.exceeds, "Exactly the aggregate cap is allowed.")

        let over = await ledger.update(runID: runID, records: [
            record(runID, input: 500_001, output: 100_000, cacheRead: 400_000),
        ])
        XCTAssertEqual(over.reportedTotalTokens, 1_000_001)
        XCTAssertTrue(over.exceeds, "One token over the aggregate cap must stop the run.")
    }

    func testRepeatedWatcherSnapshotsReplaceInsteadOfAppend() async {
        let runID = UUID()
        let ledger = makeLedger(maxTotal: 1_000_000)
        _ = await ledger.update(runID: runID, records: [
            record(runID, input: 600_000, output: 50_000),
        ])
        let second = await ledger.update(runID: runID, records: [
            record(runID, input: 600_000, output: 50_000),
            record(runID, input: 200_000, output: 20_000),
        ])
        XCTAssertEqual(
            second.reportedTotalTokens,
            870_000,
            "The durable snapshot for one run contains exactly its own requests."
        )

        let repeated = await ledger.update(runID: runID, records: [
            record(runID, input: 600_000, output: 50_000),
            record(runID, input: 200_000, output: 20_000),
        ])
        XCTAssertEqual(
            repeated.reportedTotalTokens,
            870_000,
            "Polling the same watcher snapshot again must replace, never append, the run's usage."
        )
    }

    func testAggregateSumsEveryOwnedRunID() async {
        let ledger = makeLedger(maxTotal: 1_000_000)
        let first = UUID()
        let second = UUID()
        let third = UUID()
        _ = await ledger.update(runID: first, records: [
            record(first, input: 300_000, output: 20_000),
        ])
        _ = await ledger.update(runID: second, records: [
            record(second, input: 300_000, output: 20_000),
        ])
        let all = await ledger.update(runID: third, records: [
            record(third, input: 300_000, output: 60_000),
        ])
        XCTAssertEqual(all.inputTokens, 900_000)
        XCTAssertEqual(all.outputTokens, 100_000)
        XCTAssertEqual(all.reportedTotalTokens, 1_000_000)
        XCTAssertFalse(all.exceeds, "All three owned runs at exactly the aggregate cap are allowed.")

        let over = await ledger.update(runID: third, records: [
            record(third, input: 300_001, output: 60_000),
        ])
        XCTAssertEqual(over.reportedTotalTokens, 1_000_001)
        XCTAssertTrue(over.exceeds, "The aggregate must include every owned run ID.")
    }

    func testLegacyMeteredOptInWithoutTotalKeepsSeparateCaps() async {
        let runID = UUID()
        let ledger = makeLedger(
            basis: .meteredUSD,
            maxInput: 600_000,
            maxOutput: 100_000,
            maxTotal: nil
        )
        let within = await ledger.update(runID: runID, records: [
            record(runID, input: 600_000, output: 50_000, cacheRead: 500_000),
        ])
        XCTAssertEqual(within.reportedTotalTokens, 1_150_000)
        XCTAssertFalse(
            within.exceeds,
            "A legacy metered opt-in without maxTotalTokens keeps only its separate input/output "
                + "caps; cache reads must not create an unrequested aggregate cap."
        )

        let inputOver = await ledger.update(runID: runID, records: [
            record(runID, input: 600_001, output: 50_000, cacheRead: 500_000),
        ])
        XCTAssertTrue(inputOver.exceeds)

        let outputOver = await ledger.update(runID: runID, records: [
            record(runID, input: 1, output: 100_001),
        ])
        XCTAssertTrue(outputOver.exceeds)
    }
}

/// The reviewed prepaid Agent Plan routes this test may account as zero
/// incremental USD. These are test-only constants: they do not change
/// production provider configuration or enable any generic free-model path.
///
/// The reviewed remote-model rows come from the official Agent Plan supported
/// models page (updated 2026-10-29) and its source receipt
/// `Local/Private/cad106-native-closure-20261031/verification/
/// cad-live-vision-route-source-review.json`. That page documents native image
/// input and a 1,048,576-token context for `glm-5.3-flash`,
/// `deepseek-v4.1-flash` and `deepseek-v4.1-flash-economy` on the SAME Agent
/// Plan route. No account entitlement is assumed here: Root selects and probes
/// the actual current candidate. The historical text-only `deepseek-v4-flash`
/// row is retained so prior opt-ins and the 64K/128K compaction selectors keep
/// their exact old behavior.
private enum NativeCADLivePrepaidRoute {
    struct ReviewedModel: Sendable, Equatable {
        var remoteModelID: String
        /// Whether the reviewed row declares native image input. The owned
        /// model capability flag must match this exactly.
        var supportsVision: Bool
        /// Documented context window for this reviewed row.
        var documentedContextTokens: Int
        /// Highest output limit this harness accepts for the row. The
        /// documented v4.1 Flash maximum is 393,216; the legacy row keeps the
        /// previous 32,768 harness bound. GLM's output maximum is not
        /// documented on the reviewed page, so it also keeps that bound.
        var maximumOutputTokens: Int
        var review: String
    }

    static let providerID = UUID(uuidString: "A3060000-0000-4000-8000-000000000001")!
    static let modelID = UUID(uuidString: "A3060000-0000-4000-8000-000000000002")!
    static let baseURL = URL(string: "https://ark.cn-beijing.volces.com/api/plan/v3")!
    static let legacyRemoteModelID = "deepseek-v4-flash"
    static let recordedContextTokens = 1_048_576
    static let maxInputTokens = 1_000_000
    static let maxOutputTokens = 1_000_000
    static let maxTotalTokens = 1_000_000
    static let maxPerRunSeconds: Double = 900
    static let maxTotalSeconds: Double = 2_700

    static let reviewedModels: [ReviewedModel] = [
        ReviewedModel(
            remoteModelID: legacyRemoteModelID,
            supportsVision: false,
            documentedContextTokens: 1_000_000,
            maximumOutputTokens: 32_768,
            review: "Historical text-only same-plan row; preserves the prior opt-ins and compaction tests."
        ),
        ReviewedModel(
            remoteModelID: "glm-5.3-flash",
            supportsVision: true,
            documentedContextTokens: recordedContextTokens,
            maximumOutputTokens: 32_768,
            review: "Official Agent Plan supported-models page, updated 2026-10-29: native image input."
        ),
        ReviewedModel(
            remoteModelID: "deepseek-v4.1-flash",
            supportsVision: true,
            documentedContextTokens: recordedContextTokens,
            maximumOutputTokens: 393_216,
            review: "Official Agent Plan supported-models page, updated 2026-10-29: native image input; documented max output 393,216."
        ),
        ReviewedModel(
            remoteModelID: "deepseek-v4.1-flash-economy",
            supportsVision: true,
            documentedContextTokens: recordedContextTokens,
            maximumOutputTokens: 393_216,
            review: "Official Agent Plan supported-models page, updated 2026-10-29: native image input."
        ),
    ]

    static func reviewedModel(_ remoteModelID: String?) -> ReviewedModel? {
        guard let remoteModelID, !remoteModelID.isEmpty else { return nil }
        // Exact remote identity, never a prefix or alias match.
        return reviewedModels.first { $0.remoteModelID == remoteModelID }
    }

    static func isReviewed(remoteModelID: String?) -> Bool {
        reviewedModel(remoteModelID) != nil
    }

    /// Exact profile shape created by `NativeCADLiveOwnedRoute` for the
    /// reserved IDs above. No opt-in pin alone can authorize another base or
    /// model as a zero-increment route, and the owned model's actual
    /// capability/limits must match the reviewed row exactly.
    static func matches(provider: ProviderProfile, model: ModelProfile) -> Bool {
        guard let reviewed = reviewedModel(model.remoteModelID) else { return false }
        let declaresVision = model.capabilities.contains(.vision)
        return provider.id == providerID
            && model.id == modelID
            && model.providerID == provider.id
            && provider.isEnabled
            && provider.kind == .openAI
            && provider.wireProtocol == .openAIChatCompletions
            && provider.baseURL == baseURL
            && provider.baseURL.user == nil
            && provider.baseURL.password == nil
            && provider.baseURL.query == nil
            && provider.baseURL.fragment == nil
            && provider.displayName == "Native CAD qualification"
            && provider.toolNameCompatibility
            && provider.secretRef?.synchronizable == false
            && provider.secretRef?.keychainAccount.hasPrefix("native-cad-qualification.") == true
            && model.remoteModelID == reviewed.remoteModelID
            && model.displayName == "Native CAD qualification"
            && model.isHiddenFromPrimaryPicker == true
            && model.pricing == nil
            && model.capabilities.contains(.text)
            && model.capabilities.contains(.tools)
            && declaresVision == reviewed.supportsVision
            && model.limits.contextTokens >= 16_384
            && model.limits.contextTokens <= reviewed.documentedContextTokens
            && model.limits.maxOutputTokens >= 1_024
            && model.limits.maxOutputTokens <= reviewed.maximumOutputTokens
    }
}

/// A qualification-only configuration, isolated from existing providers and
/// defaults. No API key is accepted in the metadata file or attachment output.
@MainActor
private struct NativeCADLiveOwnedRoute {
    struct Metadata: Decodable {
        var providerID: UUID
        var modelID: UUID
        var baseURL: URL
        var remoteModelID: String
        var contextTokens: Int
        var maxOutputTokens: Int
        var supportsVision: Bool?
    }
    static let providerID = NativeCADLivePrepaidRoute.providerID
    static let modelID = NativeCADLivePrepaidRoute.modelID
    let provider: ProviderProfile
    let account: String

    static func installIfRequested(environment: AppEnvironment) async throws -> Self? {
        guard let key = ProcessInfo.processInfo.environment["FLOE_NATIVE_CAD_LIVE_KEY"],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(NativeCADLiveOptIn.directoryName)
        let metadata = try JSONDecoder().decode(Metadata.self,
            from: Data(contentsOf: root.appendingPathComponent("owned-route.json")))
        guard let reviewed = NativeCADLivePrepaidRoute.reviewedModel(metadata.remoteModelID),
              metadata.providerID == providerID, metadata.modelID == modelID,
              metadata.baseURL.absoluteString == ProcessInfo.processInfo.environment["FLOE_NATIVE_CAD_LIVE_BASE_URL"],
              metadata.remoteModelID == ProcessInfo.processInfo.environment["FLOE_NATIVE_CAD_LIVE_MODEL"],
              metadata.baseURL.scheme == "https", metadata.baseURL.host != nil,
              metadata.baseURL.user == nil, metadata.baseURL.password == nil,
              metadata.baseURL.query == nil,
              (16_384...reviewed.documentedContextTokens).contains(metadata.contextTokens),
              (1_024...reviewed.maximumOutputTokens).contains(metadata.maxOutputTokens),
              (metadata.supportsVision == true) == reviewed.supportsVision,
              !metadata.remoteModelID.isEmpty else {
            throw FloeError.validationFailed(
                "Invalid owned qualification route metadata: the remote model, capability flag "
                    + "or limits do not match a reviewed same-plan route")
        }
        let existing = try await environment.configurationStore.provider(id: providerID)
        let existingModel = try await environment.configurationStore.model(id: modelID)
        guard existing == nil, existingModel == nil else {
            throw FloeError.validationFailed("Owned qualification provider already exists; inspect and clean its recorded state before retrying")
        }
        let account = "native-cad-qualification." + UUID().uuidString
        let keychain = KeychainStore(service: "org.floeagent.ios.secrets", synchronizable: false)
        let provider = ProviderProfile(id: providerID, kind: .openAI,
            wireProtocol: .openAIChatCompletions, baseURL: metadata.baseURL,
            displayName: "Native CAD qualification",
            secretRef: SecretReference(keychainAccount: account, synchronizable: false),
            toolNameCompatibility: true)
        let owned = Self(provider: provider, account: account)
        try keychain.store(account: account, secret: Data(key.utf8))
        do {
            try await environment.configurationStore.saveProvider(provider)
            try await environment.configurationStore.saveModel(ModelProfile(
                id: modelID, providerID: providerID, remoteModelID: metadata.remoteModelID,
                displayName: "Native CAD qualification",
                limits: ModelLimits(contextTokens: metadata.contextTokens,
                    maxOutputTokens: metadata.maxOutputTokens),
                capabilities: metadata.supportsVision == true ? [.text, .tools, .vision] : [.text, .tools],
                useSurfaces: [.chatAgent], reasoningEffort: .automatic, isHiddenFromPrimaryPicker: true))
            await environment.conversationCenter.reload()
            return owned
        } catch {
            try? await owned.remove(environment: environment)
            throw error
        }
    }

    func remove(environment: AppEnvironment) async throws {
        if let current = try await environment.configurationStore.provider(id: provider.id) {
            guard current.baseURL == provider.baseURL,
                  current.displayName == provider.displayName,
                  current.secretRef?.keychainAccount == account else {
                throw FloeError.validationFailed("Qualification provider ownership changed; configuration preserved")
            }
            try await environment.configurationStore.deleteProvider(id: provider.id)
        }
        try KeychainStore(service: "org.floeagent.ios.secrets", synchronizable: false)
            .delete(account: account)
        await environment.conversationCenter.reload()
    }
}

// MARK: - Opt-in metadata (non-secret, test-only cache file)

private struct NativeCADLiveOptIn: Sendable {
    static let directoryName = "FloeNativeCADLiveQualification"
    static let fileName = "opt-in.json"

    var providerID: UUID?
    var modelID: UUID?
    var remoteModelID: String?
    var allowAnyCheapCloudChatModel: Bool
    var prepaidBudgetBasis: Bool
    var inputPerMillionUSD: Decimal?
    var outputPerMillionUSD: Decimal?
    var maxCost: Decimal
    var maxInputTokens: Int
    var maxOutputTokens: Int
    /// One aggregate reported-token budget across every run: uncached input +
    /// cache read + output. Nil preserves the legacy metered separate caps.
    var maxTotalTokens: Int?
    var perRunTimeoutSeconds: Double
    var maxTotalSeconds: Double

    var executionTimeAllowance: TimeInterval { maxTotalSeconds + 60 }

    private struct Raw: Decodable {
        var schemaVersion: Int?
        var enabled: Bool?
        var acceptRealAppOrdinaryRunContext: Bool?
        var providerID: UUID?
        var modelID: UUID?
        var remoteModelID: String?
        var allowAnyCheapCloudChatModel: Bool?
        var prepaidBudgetBasis: Bool?
        var inputPerMillionUSD: Double?
        var outputPerMillionUSD: Double?
        var maxEstimatedCostUSD: Double?
        var maxInputTokens: Int?
        var maxOutputTokens: Int?
        var maxTotalTokens: Int?
        var perRunTimeoutSeconds: Double?
        var maxTotalSeconds: Double?
    }

    /// Reads the coordinator-provided policy file. The file is never created
    /// or modified by this test, and it must not contain credentials.
    static func load() throws -> NativeCADLiveOptIn {
        let caches: URL
        do {
            caches = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw XCTSkip("Live native CAD acceptance skipped: the App Caches directory is unavailable (\(error.localizedDescription)). A skip is not live evidence.")
        }
        let url = caches
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: no opt-in policy at \(url.path). "
                    + "The primary must write the non-secret policy file described in the handoff; "
                    + "a skip is not live evidence."
            )
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 64 * 1024 else {
            throw XCTSkip("Live native CAD acceptance skipped: the opt-in policy file is empty or larger than 64 KiB. A skip is not live evidence.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw XCTSkip("Live native CAD acceptance skipped: the opt-in policy file could not be read (\(error.localizedDescription)). A skip is not live evidence.")
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            throw XCTSkip("Live native CAD acceptance skipped: the opt-in policy is not valid JSON with the documented schema. A skip is not live evidence.")
        }
        guard raw.schemaVersion == nil || raw.schemaVersion == 1 else {
            throw XCTSkip("Live native CAD acceptance skipped: unsupported opt-in policy schemaVersion \(raw.schemaVersion ?? -1). A skip is not live evidence.")
        }
        guard raw.enabled == true else {
            throw XCTSkip("Live native CAD acceptance skipped: the opt-in policy is disabled. A skip is not live evidence.")
        }
        guard raw.acceptRealAppOrdinaryRunContext == true else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: the opt-in policy does not explicitly accept "
                    + "the ordinary App run context (bounded App personalization may accompany the "
                    + "synthetic CAD prompt to the configured provider). A skip is not live evidence."
            )
        }

        let prepaid = raw.prepaidBudgetBasis == true
        let overrideInput = raw.inputPerMillionUSD
        let overrideOutput = raw.outputPerMillionUSD
        guard (overrideInput == nil) == (overrideOutput == nil) else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: inputPerMillionUSD and outputPerMillionUSD "
                    + "must be supplied together (both or neither). A skip is not live evidence."
            )
        }
        if prepaid {
            let trimmedRemote = raw.remoteModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.providerID == NativeCADLivePrepaidRoute.providerID,
                  raw.modelID == NativeCADLivePrepaidRoute.modelID,
                  NativeCADLivePrepaidRoute.isReviewed(remoteModelID: trimmedRemote),
                  raw.allowAnyCheapCloudChatModel != true,
                  let overrideInput, let overrideOutput,
                  overrideInput == 0, overrideOutput == 0 else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: prepaidBudgetBasis is accepted only "
                        + "for the exact reserved owned Agent Plan provider/model IDs, a reviewed "
                        + "same-plan remote model and both explicit zero per-million increments; "
                        + "unpinned free-model and PAYG fallbacks are not permitted. A skip is not "
                        + "live evidence."
                )
            }
        } else if let overrideInput, let overrideOutput {
            guard overrideInput.isFinite, overrideOutput.isFinite,
                  overrideInput > 0, overrideOutput > 0,
                  overrideInput <= 1.5, overrideOutput <= 6.0 else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: the explicit USD pricing override is "
                        + "outside the cheap-model band (input ≤ 1.5, output ≤ 6.0 per million) "
                        + "and zero rates require prepaidBudgetBasis for the reviewed owned route. "
                        + "A skip is not live evidence."
                )
            }
        }

        let maxCostDouble = raw.maxEstimatedCostUSD ?? 0.25
        guard maxCostDouble.isFinite, maxCostDouble > 0, maxCostDouble <= 2.0 else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: maxEstimatedCostUSD must be greater than zero "
                    + "and at most 2.0. A skip is not live evidence."
            )
        }
        let maxInput = raw.maxInputTokens ?? 400_000
        guard (1...1_000_000).contains(maxInput) else {
            throw XCTSkip("Live native CAD acceptance skipped: maxInputTokens must be 1...1,000,000. A skip is not live evidence.")
        }
        let maxOutput = raw.maxOutputTokens ?? 30_000
        guard (1...1_000_000).contains(maxOutput) else {
            throw XCTSkip("Live native CAD acceptance skipped: maxOutputTokens must be 1...1,000,000. A skip is not live evidence.")
        }
        let maxTotal: Int?
        if let declaredTotal = raw.maxTotalTokens {
            guard (1...1_000_000).contains(declaredTotal) else {
                throw XCTSkip("Live native CAD acceptance skipped: maxTotalTokens must be 1...1,000,000. A skip is not live evidence.")
            }
            maxTotal = declaredTotal
        } else if prepaid {
            throw XCTSkip(
                "Live native CAD acceptance skipped: prepaidBudgetBasis requires maxTotalTokens "
                    + "so the one aggregate budget across every run is explicit. A skip is not live evidence."
            )
        } else {
            maxTotal = nil
        }
        let perRun = raw.perRunTimeoutSeconds ?? 300
        guard perRun.isFinite, (30...900).contains(perRun) else {
            throw XCTSkip("Live native CAD acceptance skipped: perRunTimeoutSeconds must be 30...900. A skip is not live evidence.")
        }
        let total = raw.maxTotalSeconds ?? 1_500
        guard total.isFinite, (60...2_700).contains(total), total >= perRun else {
            throw XCTSkip("Live native CAD acceptance skipped: maxTotalSeconds must be 60...2,700 and at least perRunTimeoutSeconds. A skip is not live evidence.")
        }

        if prepaid {
            guard let maxTotal,
                  maxTotal <= NativeCADLivePrepaidRoute.maxTotalTokens,
                  maxInput <= NativeCADLivePrepaidRoute.maxInputTokens,
                  maxOutput <= NativeCADLivePrepaidRoute.maxOutputTokens,
                  perRun <= NativeCADLivePrepaidRoute.maxPerRunSeconds,
                  total <= NativeCADLivePrepaidRoute.maxTotalSeconds else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: prepaidBudgetBasis may not exceed the "
                        + "approved 1,000,000-token aggregate (uncached input + cache read + "
                        + "output), 1,000,000 input, 1,000,000 output, 900 s per turn or "
                        + "2,700 s total. A skip is not live evidence."
                )
            }
        }

        let trimmedRemote = raw.remoteModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NativeCADLiveOptIn(
            providerID: raw.providerID,
            modelID: raw.modelID,
            remoteModelID: (trimmedRemote?.isEmpty ?? true) ? nil : trimmedRemote,
            allowAnyCheapCloudChatModel: raw.allowAnyCheapCloudChatModel == true,
            prepaidBudgetBasis: prepaid,
            inputPerMillionUSD: overrideInput.map { Decimal($0) },
            outputPerMillionUSD: overrideOutput.map { Decimal($0) },
            maxCost: Decimal(maxCostDouble),
            maxInputTokens: maxInput,
            maxOutputTokens: maxOutput,
            maxTotalTokens: maxTotal,
            perRunTimeoutSeconds: perRun,
            maxTotalSeconds: total
        )
    }
}

// MARK: - Route selection (actual App configuration only)

private enum NativeCADLiveBudgetBasis: String, Sendable, Equatable {
    case meteredUSD
    case prepaidAgentPlan
}

private struct NativeCADLivePricing: Sendable {
    var inputPerMillion: Decimal
    var outputPerMillion: Decimal
    var basis: NativeCADLiveBudgetBasis

    func cost(inputTokens: Int, outputTokens: Int) -> Decimal {
        Decimal(inputTokens) * inputPerMillion / 1_000_000
            + Decimal(outputTokens) * outputPerMillion / 1_000_000
    }
}

private struct NativeCADLiveRoute: Sendable {
    var provider: ProviderProfile
    var model: ModelProfile
    var pricing: NativeCADLivePricing

    /// Picks a currently configured, enabled, cheap, tool-capable cloud chat
    /// model from the live App configuration. DeepSeek Flash is preferred when
    /// present. No provider, model, key or account is created or changed.
    @MainActor
    static func select(
        optIn: NativeCADLiveOptIn,
        center: ConversationCenter
    ) throws -> NativeCADLiveRoute {
        let providers = center.providers
        guard !providers.isEmpty else {
            throw XCTSkip("Live native CAD acceptance skipped: the App has no enabled provider after launch. A skip is not live evidence.")
        }
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        if optIn.prepaidBudgetBasis {
            guard optIn.providerID == NativeCADLivePrepaidRoute.providerID,
                  optIn.modelID == NativeCADLivePrepaidRoute.modelID,
                  NativeCADLivePrepaidRoute.isReviewed(remoteModelID: optIn.remoteModelID),
                  !optIn.allowAnyCheapCloudChatModel else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: the prepaid budget basis requires the "
                        + "exact reserved owned Agent Plan provider/model IDs, a reviewed same-plan "
                        + "remote model and no fallback model. A skip is not live evidence."
                )
            }
        }

        var candidates: [(provider: ProviderProfile, model: ModelProfile)] = []
        if let modelID = optIn.modelID {
            guard let pair = center.providerAndModel(modelID: modelID) else {
                throw XCTSkip("Live native CAD acceptance skipped: the pinned modelID \(modelID.uuidString) is not an enabled chat model in the App. A skip is not live evidence.")
            }
            if let providerID = optIn.providerID, pair.0.id != providerID {
                throw XCTSkip("Live native CAD acceptance skipped: the pinned model belongs to a different provider than the pinned providerID. A skip is not live evidence.")
            }
            candidates = [(provider: pair.0, model: pair.1)]
        } else if let remote = optIn.remoteModelID {
            candidates = center.availableAgentModels.compactMap { model -> (provider: ProviderProfile, model: ModelProfile)? in
                guard model.remoteModelID.caseInsensitiveCompare(remote) == .orderedSame,
                      let provider = providersByID[model.providerID] else { return nil }
                if let providerID = optIn.providerID, provider.id != providerID { return nil }
                return (provider: provider, model: model)
            }
        } else if let providerID = optIn.providerID {
            guard let provider = providersByID[providerID] else {
                throw XCTSkip("Live native CAD acceptance skipped: the pinned providerID is not enabled in the App. A skip is not live evidence.")
            }
            candidates = center.availableAgentModels.compactMap { model -> (provider: ProviderProfile, model: ModelProfile)? in
                model.providerID == provider.id ? (provider: provider, model: model) : nil
            }
        } else {
            candidates = center.availableAgentModels.compactMap { model -> (provider: ProviderProfile, model: ModelProfile)? in
                providersByID[model.providerID].map { (provider: $0, model: model) }
            }
        }

        let eligible = candidates.filter { pair in
            isEligible(provider: pair.provider, model: pair.model, optIn: optIn)
        }
        guard !eligible.isEmpty else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: no configured, enabled, cheap, tool-capable "
                    + "cloud chat model with a bounded metered price or the exact prepaid route "
                    + "is visible to the App. A skip is not live evidence."
            )
        }

        let deepSeekFlash = eligible.filter { pair in
            let name = "\(pair.model.remoteModelID) \(pair.model.displayName)".lowercased()
            return name.contains("deepseek") && name.contains("flash")
        }
        let selectable: [(provider: ProviderProfile, model: ModelProfile)]
        if optIn.modelID != nil || optIn.remoteModelID != nil {
            selectable = eligible
        } else if !deepSeekFlash.isEmpty {
            selectable = deepSeekFlash
        } else if optIn.allowAnyCheapCloudChatModel {
            selectable = eligible
        } else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: no enabled DeepSeek Flash chat model is "
                    + "visible to the App, and the opt-in does not allow another cheap model. "
                    + "Pin an approved cheap model or set allowAnyCheapCloudChatModel only after "
                    + "an explicit cost/data decision. A skip is not live evidence."
            )
        }

        guard let chosen = selectable.min(by: { lhs, rhs in
            priceRank(lhs.model, optIn: optIn) < priceRank(rhs.model, optIn: optIn)
        }), let pricing = pricing(for: chosen.model, optIn: optIn) else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: the selected model has no usable metered "
                    + "USD pricing or exact prepaid basis, so cost cannot be bounded. "
                    + "A skip is not live evidence."
            )
        }
        if optIn.prepaidBudgetBasis {
            guard NativeCADLivePrepaidRoute.matches(
                provider: chosen.provider, model: chosen.model
            ), pricing.basis == .prepaidAgentPlan,
               let declaredRemote = optIn.remoteModelID,
               declaredRemote == chosen.model.remoteModelID else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: prepaidBudgetBasis requires the exact "
                        + "reserved imported Agent Plan provider/model route, the same declared "
                        + "reviewed remote model and both explicit zero increments; no PAYG or "
                        + "alternate-channel fallback is allowed. A skip is not live evidence."
                )
            }
        }

        // App-owned credential resolution only. The value is checked for
        // presence and immediately discarded; it is never logged, printed,
        // persisted or passed through this file's error messages.
        let credentials = center.resolveCredentials(for: chosen.provider)
        guard credentials.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: the selected provider record exists, but the "
                    + "App's credential resolution returned no API key. Configure/repair the key in "
                    + "the App, then re-run; the key is never read outside the App. "
                    + "A skip is not live evidence."
            )
        }

        return NativeCADLiveRoute(
            provider: chosen.provider,
            model: chosen.model,
            pricing: pricing
        )
    }

    private static func isEligible(
        provider: ProviderProfile,
        model: ModelProfile,
        optIn: NativeCADLiveOptIn
    ) -> Bool {
        guard provider.isEnabled,
              provider.kind != .local,
              provider.id != ProviderProfile.onDeviceProviderID else { return false }
        guard model.isEnabled,
              model.capabilities.contains(.text),
              model.capabilities.contains(.tools),
              model.supportsChatAgentSurface else { return false }
        guard let pricing = pricing(for: model, optIn: optIn) else { return false }

        let name = "\(model.remoteModelID) \(model.displayName)".lowercased()
        if name.contains("ultra") || name.contains("opus") { return false }
        if name.contains("kimi") && (name.contains("max") || name.contains("ultra")) { return false }

        let input = NSDecimalNumber(decimal: pricing.inputPerMillion).doubleValue
        let output = NSDecimalNumber(decimal: pricing.outputPerMillion).doubleValue
        switch pricing.basis {
        case .prepaidAgentPlan:
            // Zero incremental USD is valid only for the exact reserved,
            // imported prepaid route. It is not a generic free-model path.
            guard optIn.prepaidBudgetBasis,
                  NativeCADLivePrepaidRoute.matches(provider: provider, model: model),
                  input == 0, output == 0 else { return false }
        case .meteredUSD:
            // An explicit, conservative "cheap" ceiling. A model outside this
            // band needs a deliberate product decision, not a silent fallback.
            guard input > 0, output > 0, input <= 1.5, output <= 6.0 else { return false }
        }
        return true
    }

    private static func pricing(
        for model: ModelProfile,
        optIn: NativeCADLiveOptIn
    ) -> NativeCADLivePricing? {
        if let metadata = model.pricing,
           metadata.currency.uppercased() == "USD",
           let input = metadata.inputPerMillion,
           let output = metadata.outputPerMillion {
            let inputNumber = NSDecimalNumber(decimal: input).doubleValue
            let outputNumber = NSDecimalNumber(decimal: output).doubleValue
            // A zero or incomplete saved price is not a metered rate. It must
            // never become an arbitrary free-model candidate.
            guard inputNumber.isFinite, outputNumber.isFinite,
                  inputNumber > 0, outputNumber > 0 else { return nil }
            return NativeCADLivePricing(
                inputPerMillion: input,
                outputPerMillion: output,
                basis: .meteredUSD
            )
        }
        // Explicit, non-secret USD price supplied by the primary when the App
        // has no usable USD pricing metadata. The price is only a test bound;
        // it never edits the saved provider/model configuration.
        guard let input = optIn.inputPerMillionUSD,
              let output = optIn.outputPerMillionUSD else { return nil }
        if optIn.prepaidBudgetBasis {
            guard input == Decimal.zero, output == Decimal.zero else { return nil }
            return NativeCADLivePricing(
                inputPerMillion: input,
                outputPerMillion: output,
                basis: .prepaidAgentPlan
            )
        }
        guard input > Decimal.zero, output > Decimal.zero else { return nil }
        return NativeCADLivePricing(
            inputPerMillion: input,
            outputPerMillion: output,
            basis: .meteredUSD
        )
    }

    private static func priceRank(_ model: ModelProfile, optIn: NativeCADLiveOptIn) -> Decimal {
        guard let pricing = pricing(for: model, optIn: optIn) else { return Decimal(1_000_000) }
        return pricing.inputPerMillion + pricing.outputPerMillion
    }
}

// MARK: - Native CAD tool discovery

private enum NativeCADLivePreflight {
    @MainActor
    static func requireNativeCADCapabilities() throws {
        guard ToolRunnerRegistry.shared.runner(named: CadDocumentTool.name) != nil else {
            XCTFail(
                "The actual App graph does not expose \(CadDocumentTool.name); "
                    + "native CAD acceptance cannot run."
            )
            throw NativeCADLiveError.toolUnavailable(
                "The App's runtime tool registry has no executable \(CadDocumentTool.name)."
            )
        }
        let requiredOperations = [
            "sketch.create", "sketch.addEntities", "feature.extrude", "feature.fillet",
        ]
        for operation in requiredOperations {
            guard FloeCADDocument.nativeOperationNames.contains(operation) else {
                XCTFail(
                    "The actual FloeCAD kernel does not advertise \(operation); "
                        + "the synthetic bracket flow cannot be executed."
                )
                throw NativeCADLiveError.toolUnavailable(
                    "FloeCAD does not advertise the required operation \(operation)."
                )
            }
        }
        // The undo leg uses the REAL `parameters` payload action, not a
        // versions restore or a hand-edited package. The same typed parameter
        // service also carries M11's variable/formula actions; this selector
        // does not invent a second formula scenario, but it refuses to run on
        // a tool surface that has lost those native commands.
        let requiredParameterActions = Set([
            "updateSketchEntity", "undo", "redo",
            "variable.create", "variable.update", "variable.delete",
            "feature.setExpression",
        ])
        for action in requiredParameterActions {
            guard CadNativeEditActions.parameters.contains(action) else {
                XCTFail(
                    "The actual cad.document parameters action surface does not advertise "
                        + "\(action); the native undo/parameter acceptance cannot run."
                )
                throw NativeCADLiveError.toolUnavailable(
                    "cad.document parameters does not advertise \(action)."
                )
            }
        }
    }

    /// The X35 selector requires the model that actually receives the capture
    /// to declare direct image input. The bounded image-receipt observer below
    /// then verifies the actual outbound image part; this preflight only avoids
    /// spending paid turns on a route that cannot possibly deliver one.
    static func requireDirectVision(route: NativeCADLiveRoute) throws {
        guard route.model.capabilities.contains(.vision) else {
            XCTFail(
                "The X35 selector requires a reviewed same-plan model with native image input; "
                    + "the selected model \(route.model.remoteModelID) is text-only. Configure a "
                    + "reviewed direct-vision route (or rerun the compaction selectors for a "
                    + "text-only route). A text-only run is not visual acceptance."
            )
            throw NativeCADLiveError.insufficientVisualRoute(route.model.remoteModelID)
        }
        guard route.model.limits.contextTokens >= 32_768 else {
            XCTFail(
                "The selected vision route's context window is too small for a real viewport image "
                    + "plus the CAD tool transcript: \(route.model.limits.contextTokens) tokens."
            )
            throw NativeCADLiveError.insufficientVisualRoute(route.model.remoteModelID)
        }
    }
}

// MARK: - Stop signal, budget ledger and errors

private enum NativeCADLiveError: Error, Sendable, CustomStringConvertible {
    case toolUnavailable(String)
    case invalidContextWindow(Int)
    case timedOut(UUID)
    case aggregateTimeExceeded(Double)
    case budgetExceeded(String)
    case runIncomplete(state: String, detail: String)
    case missingUsage
    case missingDocument(String)
    case invalidDocument(String)
    case missingCapture
    case invalidCapture(String)
    case insufficientVisualRoute(String)
    case missingVisionReceipt(String)
    case invalidVisionReceipt(String)

    var description: String {
        switch self {
        case .toolUnavailable(let detail):
            return "Native CAD tool unavailable: \(detail)"
        case .invalidContextWindow(let tokens):
            return "The model context window does not match the selected compaction acceptance; found \(tokens)."
        case .timedOut(let runID):
            return "Live native CAD turn \(runID.uuidString) exceeded its wall-clock deadline and was cancelled."
        case .aggregateTimeExceeded(let seconds):
            return "Live native CAD acceptance exceeded its approved aggregate wall-clock deadline of \(seconds) seconds."
        case .budgetExceeded(let detail):
            return "Live native CAD acceptance exceeded its approved cost/data ceiling: \(detail)"
        case .runIncomplete(let state, let detail):
            return "Live native CAD run did not complete successfully (state \(state)): \(detail)"
        case .missingUsage:
            return "The live model run produced no durable usage record, so cost/data cannot be bounded or evidenced."
        case .missingDocument(let path):
            return "The native CAD package was not found at \(path) after the model turn."
        case .invalidDocument(let detail):
            return "The native CAD package could not be verified: \(detail)"
        case .missingCapture:
            return "No successful cad.document capture result with a real PNG artifact was found."
        case .invalidCapture(let detail):
            return "The CAD viewport capture was refused as evidence: \(detail)"
        case .insufficientVisualRoute(let model):
            return "The selected route \(model) cannot provide direct image input for the X35 visual loop."
        case .missingVisionReceipt(let detail):
            return "No actual outbound image receipt was observed for the capture: \(detail)"
        case .invalidVisionReceipt(let detail):
            return "The outbound visual evidence was refused as proof of image receipt: \(detail)"
        }
    }
}

private actor NativeCADLiveStopSignal {
    private var failure: NativeCADLiveError?

    func set(_ failure: NativeCADLiveError) {
        if self.failure == nil { self.failure = failure }
    }

    func throwIfStopped() throws {
        if let failure { throw failure }
    }
}

private struct NativeCADLiveTotals: Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    /// Uncached input + cache read + output, counted once across every run.
    var reportedTotalTokens: Int
    var cost: Decimal
    var maxCost: Decimal
    var maxInputTokens: Int
    var maxOutputTokens: Int
    var maxTotalTokens: Int?
    var basis: NativeCADLiveBudgetBasis

    var hasUsage: Bool { reportedTotalTokens > 0 }
    var exceeds: Bool {
        if cost > maxCost { return true }
        if inputTokens > maxInputTokens { return true }
        if outputTokens > maxOutputTokens { return true }
        if let maxTotalTokens, reportedTotalTokens > maxTotalTokens { return true }
        return false
    }

    var description: String {
        let aggregate: String
        if let maxTotalTokens {
            aggregate = "reported aggregate \(reportedTotalTokens)/\(maxTotalTokens) tokens "
                + "(uncached input + cache read + output)"
        } else {
            aggregate = "reported aggregate \(reportedTotalTokens) tokens "
                + "(uncached input + cache read + output; legacy opt-in has no aggregate cap)"
        }
        let tokens = "uncached input \(inputTokens)/\(maxInputTokens) tokens, "
            + "cache read \(cacheReadTokens) tokens, "
            + "output \(outputTokens)/\(maxOutputTokens) tokens, "
            + aggregate
        switch basis {
        case .meteredUSD:
            return "\(tokens), estimated metered cost \(cost) USD (cap \(maxCost) USD)"
        case .prepaidAgentPlan:
            return "\(tokens), 0 incremental USD from prepaid Agent Plan consumption "
                + "(prepaid allowance, not a metered market price or free-model claim; "
                + "cost guard \(maxCost) USD remains in force)"
        }
    }
}

private actor NativeCADLiveLedger {
    private let pricing: NativeCADLivePricing
    private let maxCost: Decimal
    private let maxInputTokens: Int
    private let maxOutputTokens: Int
    private let maxTotalTokens: Int?
    private var recordsByRun: [UUID: [RunUsageRecord]] = [:]

    init(
        pricing: NativeCADLivePricing,
        maxCost: Decimal,
        maxInputTokens: Int,
        maxOutputTokens: Int,
        maxTotalTokens: Int?
    ) {
        self.pricing = pricing
        self.maxCost = maxCost
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxTotalTokens = maxTotalTokens
    }

    /// The watcher polls the same run repeatedly, so each call REPLACES that
    /// run's snapshot. Assigning (rather than appending) is what makes a
    /// repeated watcher observation count one model request exactly once.
    func update(runID: UUID, records: [RunUsageRecord]) -> NativeCADLiveTotals {
        recordsByRun[runID] = records
        return totalsLocked()
    }

    func totals() -> NativeCADLiveTotals {
        totalsLocked()
    }

    private func totalsLocked() -> NativeCADLiveTotals {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cost = Decimal.zero
        for records in recordsByRun.values {
            for record in records {
                // Cost keeps using the provider's uncached input and output
                // fields. Reasoning is already part of output; cache write is
                // already part of provider input on wires that report it.
                input += record.inputTokens
                output += record.outputTokens
                cacheRead += record.cacheReadTokens ?? 0
                cost += pricing.cost(inputTokens: record.inputTokens, outputTokens: record.outputTokens)
            }
        }
        return NativeCADLiveTotals(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            reportedTotalTokens: input + cacheRead + output,
            cost: cost,
            maxCost: maxCost,
            maxInputTokens: maxInputTokens,
            maxOutputTokens: maxOutputTokens,
            maxTotalTokens: maxTotalTokens,
            basis: pricing.basis
        )
    }
}

// MARK: - One owned task/workspace and the four-turn visual loop

@MainActor
private final class NativeCADLiveSession {
    private let environment: AppEnvironment
    private let center: ConversationCenter
    private let route: NativeCADLiveRoute
    private let optIn: NativeCADLiveOptIn
    private let ledger: NativeCADLiveLedger
    private let conversationID = UUID()
    private let documentName: String
    private let title: String

    private var sessionStartedAt = Date()
    private var runIDs: [UUID] = []
    private var services: [ConversationRunService] = []
    private var workspaceID: UUID?
    private var workspaceRoot: URL?
    private var documentURL: URL?
    private var captureRelativePaths: [String] = []
    private var visionReceipts: [NativeCADLiveVisionReceipt] = []
    private var visionCaptureRevision: Int?
    private var visionCaptureContentSHA256: String?
    private var visionCaptureImageSHA256: String?
    private var undoEvidence: NativeCADLiveUndoEvidence?
    private var reopenEvidence: NativeCADLiveReopenEvidence?
    private var cleanupStarted = false
    private var failureDescription: String?
    private var documentWitnessCount = 0

    init(
        environment: AppEnvironment,
        center: ConversationCenter,
        route: NativeCADLiveRoute,
        optIn: NativeCADLiveOptIn
    ) {
        self.environment = environment
        self.center = center
        self.route = route
        self.optIn = optIn
        self.ledger = NativeCADLiveLedger(
            pricing: route.pricing,
            maxCost: optIn.maxCost,
            maxInputTokens: optIn.maxInputTokens,
            maxOutputTokens: optIn.maxOutputTokens,
            maxTotalTokens: optIn.maxTotalTokens
        )
        self.documentName = "NativeBracket-\(String(UUID().uuidString.prefix(8))).floecad"
        self.title = "Native CAD live acceptance \(String(UUID().uuidString.prefix(6)))"
    }

    func runAll() async throws {
        sessionStartedAt = Date()
        try ensureAggregateTimeRemaining()

        // Turn 1 — create the native package, plate and Ø6 through-hole.
        let firstGoal = turnOneGoal()
        let first = try await prepare(goal: firstGoal, firstTurn: true)
        let firstEvents = try await runTurn(prepared: first, goal: firstGoal, observeVision: false)
        try NativeCADLiveEvidence.assertTurnOneEvidence(firstEvents)

        let url = try XCTUnwrap(documentURL, "The private task workspace root was not resolved.")
        let afterCreate = try await inspectDocument(at: url)
        try assertInitialGeometry(afterCreate)
        guard afterCreate.bodyCount == 1,
              afterCreate.bodyIsAnalytic,
              afterCreate.circles.count == 1,
              abs((afterCreate.circles.first?.radius ?? -1) - 3.0) < 1e-3 else {
            throw NativeCADLiveError.invalidDocument(
                "Initial bracket geometry assertions failed; stopping before the next paid turn."
            )
        }

        // Turn 2 — actual viewport image, actual provider image delivery, then
        // the requested correction on the SAME existing hole (and fillet).
        let secondGoal = turnTwoGoal(documentPath: documentName)
        let second = try await prepare(goal: secondGoal, firstTurn: false)
        let secondEvents = try await runTurn(prepared: second, goal: secondGoal, observeVision: true)
        let preCorrectionCapture = try validateCapture(
            events: secondEvents,
            runID: second.run.id,
            requirement: .exactly(afterCreate.revision),
            preferLast: false
        )
        try assertCaptureMatches(
            preCorrectionCapture,
            state: afterCreate,
            label: "pre-correction"
        )
        attach(preCorrectionCapture.png, name: "native-cad-live-pre-correction.png")
        visionCaptureRevision = preCorrectionCapture.revision
        visionCaptureContentSHA256 = preCorrectionCapture.contentSHA256
        visionCaptureImageSHA256 = preCorrectionCapture.imageSHA256
        let preCorrectionReceipt = try requireVisionReceipt(
            runID: second.run.id,
            capture: preCorrectionCapture
        )
        let correctionCallIDs = try NativeCADLiveEvidence.assertTurnTwoEvidence(
            secondEvents,
            capture: preCorrectionCapture,
            initial: afterCreate
        )
        // The correction and fillet must be generated in a provider dispatch
        // AFTER the one that delivered the image. If either call id was part
        // of the capture's own batch, the model proposed it before receiving
        // the image; that is not a visual-feedback correction.
        XCTAssertFalse(
            preCorrectionReceipt.pendingCallIDs.contains(correctionCallIDs.correctionCallID),
            "The hole correction was batched with the capture, before image delivery."
        )
        XCTAssertFalse(
            preCorrectionReceipt.pendingCallIDs.contains(correctionCallIDs.filletCallID),
            "The fillet proposal was batched with the capture, before image delivery."
        )

        let afterEdit = try await inspectDocument(at: url)
        try assertEditedGeometry(afterEdit, initial: afterCreate)
        guard afterEdit.bodyID == afterCreate.bodyID,
              afterEdit.bodyIsAnalytic,
              abs((afterEdit.circles.first?.radius ?? -1) - 4.0) < 1e-3,
              let editedFillet = afterEdit.fillet,
              abs(editedFillet.radius - 2.0) < 1e-3,
              (1...4).contains(editedFillet.edgeCount) else {
            throw NativeCADLiveError.invalidDocument(
                "Ø8 existing-hole/fillet geometry assertions failed; stopping before the undo turn."
            )
        }
        XCTAssertGreaterThan(
            afterEdit.revision,
            preCorrectionCapture.revision,
            "The correction must create a newer committed package revision than the image."
        )
        XCTAssertNotEqual(
            afterEdit.contentSHA256,
            preCorrectionCapture.contentSHA256,
            "The correction must change the package content the image was bound to."
        )
        XCTAssertEqual(
            preCorrectionReceipt.sourceSHA256,
            preCorrectionCapture.imageSHA256.lowercased(),
            "The outbound visual evidence must be bound to the exact captured image digest."
        )

        // Turn 3 — real native undo of the fillet and then the hole edit. The
        // SAME live bridge/session must remain open here: the real undo stack
        // does not cross a close/reopen.
        try ensureAggregateTimeRemaining()
        let thirdGoal = turnThreeGoal(documentPath: documentName)
        let third = try await prepare(goal: thirdGoal, firstTurn: false)
        let thirdEvents = try await runTurn(prepared: third, goal: thirdGoal, observeVision: false)
        let undoReceipt = try NativeCADLiveEvidence.assertTurnThreeUndoEvidence(thirdEvents)

        let afterUndo = try await inspectDocument(at: url)
        try assertUndoRestoredGeometry(afterUndo, initial: afterCreate, edited: afterEdit)
        undoEvidence = NativeCADLiveUndoEvidence(
            initialRevision: afterCreate.revision,
            editedRevision: afterEdit.revision,
            undoneRevision: afterUndo.revision,
            undoCommandCount: undoReceipt.commandCount,
            lastUndoReceiptRevision: undoReceipt.lastRevision,
            initialModelSHA256: afterCreate.modelSHA256 ?? "",
            restoredModelSHA256: afterUndo.modelSHA256 ?? ""
        )

        // Close the real bridge through its owner lifecycle, then reopen the
        // saved package through the same owner API. The captured instance
        // identity proves the live session really was replaced, and the
        // independent FloeCADDocument reopen below proves the saved identity.
        try ensureAggregateTimeRemaining()
        let liveBeforeClose = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertEqual(
            liveBeforeClose.revision,
            afterUndo.revision,
            "The live bridge and the independently verified undo state disagree before close."
        )
        let previousInstance = ObjectIdentifier(liveBeforeClose)
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let reopenedInstance = ObjectIdentifier(reopened)
        XCTAssertNotEqual(
            previousInstance,
            reopenedInstance,
            "The owner close/reopen did not replace the live document instance; the bridge stayed open."
        )
        XCTAssertFalse(reopened.isReadOnly, "The reopened package unexpectedly became read-only.")
        // The owner close performs one clean package save, which legitimately
        // bumps the package revision/content metadata. The CANONICAL model
        // identity must not move: that is the stable proof that reopen kept the
        // exact undo-restored definitions.
        XCTAssertGreaterThanOrEqual(
            reopened.revision,
            afterUndo.revision,
            "The reopened package is older than the verified undo state."
        )
        let undoModelSHA = afterUndo.modelSHA256 ?? ""
        XCTAssertFalse(undoModelSHA.isEmpty)
        XCTAssertEqual(
            reopened.modelSHA256,
            undoModelSHA,
            "The owner close/reopen changed the canonical CAD model identity."
        )

        let afterReopen = try await inspectDocument(at: url)
        try assertReopenRetainedGeometry(afterReopen, initial: afterCreate)
        XCTAssertEqual(afterReopen.revision, reopened.revision)
        XCTAssertEqual(afterReopen.contentSHA256, reopened.contentSHA256)
        XCTAssertEqual(afterReopen.modelSHA256, afterUndo.modelSHA256)
        XCTAssertGreaterThanOrEqual(afterReopen.revision, afterUndo.revision)
        reopenEvidence = NativeCADLiveReopenEvidence(
            instanceChanged: previousInstance != reopenedInstance,
            revisionBefore: afterUndo.revision,
            revisionAfter: afterReopen.revision,
            contentSHA256After: afterReopen.contentSHA256,
            modelSHA256After: afterReopen.modelSHA256 ?? ""
        )

        // Turn 4 — after the real disk reopen, make one further edit on the
        // SAME body/hole identity, then read back and capture the final state.
        try ensureAggregateTimeRemaining()
        let fourthGoal = turnFourGoal(documentPath: documentName)
        let fourth = try await prepare(goal: fourthGoal, firstTurn: false)
        let fourthEvents = try await runTurn(prepared: fourth, goal: fourthGoal, observeVision: false)
        let afterFinal = try await inspectDocument(at: url)
        try assertFurtherEditedGeometry(afterFinal, initial: afterCreate, reopened: afterReopen)
        let finalCapture = try validateCapture(
            events: fourthEvents,
            runID: fourth.run.id,
            requirement: .atLeast(afterFinal.revision),
            preferLast: true
        )
        try assertCaptureMatches(finalCapture, state: afterFinal, label: "final")
        attach(finalCapture.png, name: "native-cad-live-final.png")
        try NativeCADLiveEvidence.assertTurnFourEvidence(
            fourthEvents,
            initial: afterCreate,
            reopenedRevision: afterReopen.revision,
            finalState: afterFinal
        )

        let finalLive = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertEqual(
            ObjectIdentifier(finalLive),
            reopenedInstance,
            "The further edit did not run on the reopened bridge instance."
        )
        XCTAssertEqual(finalLive.revision, afterFinal.revision)
        XCTAssertEqual(finalLive.contentSHA256, afterFinal.contentSHA256)

        XCTAssertEqual(
            runIDs.count,
            4,
            "The visual acceptance must own exactly four bounded model turns."
        )
        XCTAssertEqual(
            Set(visionReceipts.map(\.runID)),
            Set([second.run.id]),
            "The image receipt must be observed for the capture turn only."
        )

        let totals = await ledger.totals()
        let expectedBasis: NativeCADLiveBudgetBasis = optIn.prepaidBudgetBasis
            ? .prepaidAgentPlan
            : .meteredUSD
        XCTAssertEqual(
            totals.basis,
            expectedBasis,
            "The usage ledger must account the configured prepaid or metered basis exactly."
        )
        if optIn.prepaidBudgetBasis {
            XCTAssertEqual(
                totals.cost,
                Decimal.zero,
                "Prepaid Agent Plan usage must not invent a metered per-token charge."
            )
        }
        XCTAssertTrue(totals.hasUsage, "The real model run must produce durable token usage.")
        XCTAssertFalse(totals.exceeds, "Hard cost/data ceiling exceeded: \(totals.description)")
        XCTAssertLessThanOrEqual(totals.cost, optIn.maxCost)
        if let maxTotalTokens = optIn.maxTotalTokens {
            XCTAssertLessThanOrEqual(
                totals.reportedTotalTokens,
                maxTotalTokens,
                "The one aggregate budget (uncached input + cache read + output) was exceeded: \(totals.description)"
            )
        }
        attachUsage(totals)
    }

    /// M11 uses the same App, model route, CAD-only authority, usage watchdog,
    /// durable events and cleanup as the visual loop, without paying to replay
    /// that unchanged four-turn scenario. Only the model authors the edits.
    func runVariableFormulaLoop() async throws {
        sessionStartedAt = Date()
        try ensureAggregateTimeRemaining()
        let goal = """
        Native CAD formula acceptance. Create \(documentName) in this task workspace
        through cad.document. Use its help/query and ordinary propose/apply/parameters
        commands, not scripts, package JSON editing or replacement geometry.
        Create one 80 by 50 mm rectangular plate, extruded along +Y. Add a native
        throughAll hole at the rectangle's center using one placement circle.
        Create a CAD variable named width with expression "10". The rectangle's
        80 by 50 mm footprint stays fixed: bind the plate extrusion distance to
        expression "width" using feature.setExpression. Bind the placement
        circle's diameter to "width / 2" using setSketchDimension, kind diameter,
        expression rather than a fixed numeric value. Thus initially the plate
        is 10 mm thick and its through hole is 5 mm diameter. Query the actual
        IDs, variables, feature parameters and driving dimension, then save.
        Do not use undo/redo in this first turn. Do not supply a grant_id.
        """
        let first = try await prepare(goal: goal, firstTurn: true)
        let firstEvents = try await runTurn(prepared: first, goal: goal, observeVision: false)
        try NativeCADLiveEvidence.assertFormulaTurn(
            firstEvents, required: ["variable.create", "feature.setExpression", "setSketchDimension"],
            allowed: ["list", "variable.create", "feature.setExpression", "setSketchDimension"],
            allowGeometryEdits: true, undoCount: 0)
        let url = try XCTUnwrap(documentURL)
        let initial = try await inspectFormulaState(at: url, width: 10)

        let change = """
        Continue the SAME saved \(documentName). Query its existing width variable,
        then use cad.document parameters variable.update to change only its
        expression from "10" to "20". Its existing formulas must drive the SAME
        extrusion to 20 mm and the SAME hole to 10 mm diameter. Do not edit the
        feature or circle numerically, replace any model, add features, rewrite
        formulas, or undo/redo. Read back actual dimensions and volume, then save.
        """
        let second = try await prepare(goal: change, firstTurn: false)
        let secondEvents = try await runTurn(prepared: second, goal: change, observeVision: false)
        try NativeCADLiveEvidence.assertFormulaTurn(
            secondEvents, required: ["variable.update"], allowed: ["list", "variable.update"],
            allowGeometryEdits: false, undoCount: 0)
        let changed = try await inspectFormulaState(at: url, width: 20, ids: initial.ids)
        XCTAssertNotEqual(changed.state.modelSHA256, initial.state.modelSHA256)

        let undo = """
        Continue the SAME \(documentName). Use the ordinary cad.document parameters
        undo action exactly once to undo the last width-variable change and all
        its dependent geometry together. Do not set the variable back manually,
        edit features, restore a version, recreate the model or use redo. Query
        the restored width, extrusion and hole, and save. Expected width 10,
        thickness 10 mm, hole diameter 5 mm, with every existing ID unchanged.
        """
        let third = try await prepare(goal: undo, firstTurn: false)
        let thirdEvents = try await runTurn(prepared: third, goal: undo, observeVision: false)
        try NativeCADLiveEvidence.assertFormulaTurn(
            thirdEvents, required: ["undo"], allowed: ["list", "undo"],
            allowGeometryEdits: false, undoCount: 1)
        let restored = try await inspectFormulaState(at: url, width: 10, ids: initial.ids)
        XCTAssertEqual(restored.state.modelSHA256, initial.state.modelSHA256,
                       "One model-issued undo must restore the complete original canonical model")

        let live = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let oldInstance = ObjectIdentifier(live)
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertNotEqual(ObjectIdentifier(reopened), oldInstance)
        let retained = try await inspectFormulaState(at: url, width: 10, ids: initial.ids)
        XCTAssertEqual(retained.state.modelSHA256, initial.state.modelSHA256)
        XCTAssertEqual(runIDs.count, 3)
        let totals = await ledger.totals()
        XCTAssertTrue(totals.hasUsage)
        XCTAssertFalse(totals.exceeds, totals.description)
        XCTAssertLessThanOrEqual(totals.cost, optIn.maxCost)
        if let ceiling = optIn.maxTotalTokens {
            XCTAssertLessThanOrEqual(totals.reportedTotalTokens, ceiling)
        }
        attachUsage(totals)
    }

    private func inspectFormulaState(
        at url: URL, width: Double, ids expectedIDs: [String: String]? = nil
    ) async throws -> (state: NativeCADLiveDocumentState, ids: [String: String]) {
        let state = try await inspectDocument(at: url)
        let expectedVolume = 80 * 50 * width - Double.pi * pow(width / 4, 2) * width
        guard state.bodyCount == 1, state.bodyIsAnalytic, state.circles.count == 1,
              abs(state.circles[0].diameter - width / 2) < 1e-5,
              abs(state.bodyVolumeMM3 - expectedVolume) < 0.01,
              state.cylindricalRadii.contains(where: { abs($0 - width / 4) < 1e-5 }),
              let modelSHA = state.modelSHA256, !modelSHA.isEmpty else {
            throw NativeCADLiveError.invalidDocument("Formula fan-out did not produce the actual expected analytic plate and hole.")
        }
        let document = try await FloeCADDocument.open(at: url)
        defer { document.close() }
        let variables = try nativeRows(document, scope: "variables")
        let variable = try XCTUnwrap(variables.first { $0["name"] as? String == "width" })
        guard let actualWidth = NativeCADLiveJSON.number(variable["value"]),
              abs(actualWidth - width) < 1e-9, variable["status"] as? String == "ok" else {
            throw NativeCADLiveError.invalidDocument("The saved width variable did not retain its expected resolved value.")
        }
        let features = try nativeRows(document, scope: "features")
        let extrusion = try XCTUnwrap(features.first { $0["kind"] as? String == "extrude" })
        let hole = try XCTUnwrap(features.first { $0["kind"] as? String == "hole" })
        let parameters = try XCTUnwrap(extrusion["parameters"] as? [[String: Any]])
        let distance = try XCTUnwrap(parameters.first { $0["name"] as? String == "distance" })
        guard let actualDistance = NativeCADLiveJSON.number(distance["value"]),
              abs(actualDistance - width) < 1e-9,
              (distance["formula"] as? String)?.contains("width") == true else {
            throw NativeCADLiveError.invalidDocument("The actual extrusion lost its width expression or rebuilt distance.")
        }
        let dimensions = try nativeRows(document, scope: "constraints")
        let driving = try XCTUnwrap(dimensions.first {
            $0["row_kind"] as? String == "dimension"
                && $0["sketchID"] as? String == state.circles[0].sketchID
                && ($0["formula_reference_names"] as? [String]) == ["width"]
        })
        let ids = [
            "body": state.bodyID,
            "variable": try XCTUnwrap(variable["id"] as? String),
            "extrusion": try XCTUnwrap(extrusion["id"] as? String),
            "hole": try XCTUnwrap(hole["id"] as? String),
            "sketch": state.circles[0].sketchID,
            "circle": state.circles[0].entityID,
            "dimension": try XCTUnwrap(driving["id"] as? String),
        ]
        if let expectedIDs, ids != expectedIDs {
            throw NativeCADLiveError.invalidDocument("The formula edit replaced an existing feature, variable, circle or dimension identity.")
        }
        return (state, ids)
    }

    // MARK: Prepare (durable, task-owned)

    private func prepare(goal: String, firstTurn: Bool) async throws -> PreparedRun {
        let runID = UUID()
        let request = RunLaunchRequest(
            conversationID: firstTurn ? nil : conversationID,
            newConversationID: firstTurn ? conversationID : nil,
            conversationTitle: title,
            runID: runID,
            goal: goal,
            workspaceID: firstTurn ? nil : workspaceID,
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(approvalMode: .automatic),
            providerID: route.provider.id,
            modelID: route.model.id,
            providerName: route.provider.displayName ?? route.provider.kind.rawValue,
            modelName: route.model.displayName
        )
        let prepared = try await environment.runLaunchStore.prepare(request)

        if firstTurn {
            workspaceID = prepared.workspace.id
            let root = try NativeCADLivePaths.workspaceRoot(
                for: prepared.workspace,
                conversationID: conversationID
            )
            workspaceRoot = root
            documentURL = root.appendingPathComponent(documentName, isDirectory: true)
            try await saveOwnedTaskPolicy(conversationID: conversationID)
        }
        runIDs.append(runID)
        return prepared
    }

    private func saveOwnedTaskPolicy(conversationID: UUID) async throws {
        let policy = TaskPolicy(
            conversationID: conversationID,
            approvalMode: TaskApprovalMode.automatic.rawValue,
            allowedToolNames: Set([CadDocumentTool.name]),
            filePaths: [],
            networkAllowed: false,
            browserControlAllowed: false,
            uploadAllowed: false,
            credentialsAllowed: false,
            remoteExecutionAllowed: false,
            recoveryPolicy: .safePoint,
            notificationPolicy: .stages
        )
        try await SQLiteWorkspaceStore(database: environment.database)
            .saveTaskPolicy(policy)
    }

    // MARK: One real model/service turn

    private func runTurn(
        prepared: PreparedRun,
        goal: String,
        observeVision: Bool
    ) async throws -> [RunEventRecord] {
        let runID = prepared.run.id
        let history = try await ConversationHistoryAssembler(store: environment.conversationStore)
            .build(conversationID: conversationID)
            .filter { $0.id != prepared.userMessage.id }

        // The exact production service factory used by ConversationCenter's
        // deferred launch. Passing `.continuation` prevents the one auxiliary
        // automatic-reasoning-effort classifier request (and a possible second
        // paid model) — this acceptance exercises the selected CAD model, not a
        // helper route.
        let service = try await center.runService(
            for: conversationID,
            provider: route.provider,
            model: route.model,
            runID: runID,
            executionMode: .agent,
            runSurface: .ordinary,
            workspaceID: prepared.workspace.id,
            memoryQuery: "",
            conversationHistory: history,
            automaticReasoningEffortIngress: .continuation
        )
        services.append(service)

        // Bounded, metadata-only observation of the ACTUAL dispatch boundary.
        // It reads the same durable provider-dispatch checkpoint the runtime
        // writes immediately before a provider request, remembers only image
        // digest/size/MIME/model capability/call ids and never retains the
        // base64 image or conversation text.
        let collector = observeVision ? NativeCADLiveVisionCollector() : nil
        let checkpointStore = environment.checkpointStore
        let collectorDeadline = Date().addingTimeInterval(optIn.perRunTimeoutSeconds + 15)
        let watcher = collector.map { collector in
            Task {
                await collector.watch(
                    checkpointStore: checkpointStore,
                    runID: runID,
                    deadline: collectorDeadline
                )
            }
        }
        do {
            try await execute(service: service, runID: runID, goal: goal)
        } catch {
            watcher?.cancel()
            _ = await watcher?.value
            if let collector {
                visionReceipts.append(contentsOf: await collector.snapshot())
            }
            throw error
        }
        watcher?.cancel()
        _ = await watcher?.value
        if let collector {
            visionReceipts.append(contentsOf: await collector.snapshot())
        }

        let events = try await environment.runStore.events(runID: runID)
        try NativeCADLiveEvidence.assertToolSurface(
            events: events,
            documentName: documentName,
            turn: runIDs.count
        )
        guard let record = try await environment.runStore.run(id: runID) else {
            throw NativeCADLiveError.runIncomplete(
                state: "missingRunRecord",
                detail: "The completed run has no durable record."
            )
        }
        XCTAssertEqual(
            record.conversationID,
            conversationID,
            "An owned run was recorded under a different conversation."
        )
        return events
    }

    private func ensureAggregateTimeRemaining() throws {
        let elapsed = Date().timeIntervalSince(sessionStartedAt)
        guard elapsed < optIn.maxTotalSeconds else {
            throw NativeCADLiveError.aggregateTimeExceeded(optIn.maxTotalSeconds)
        }
    }

    private func execute(
        service: ConversationRunService,
        runID: UUID,
        goal: String
    ) async throws {
        let runStore = environment.runStore
        let ledger = self.ledger
        let stop = NativeCADLiveStopSignal()
        let aggregateLimit = optIn.maxTotalSeconds
        let perRunLimit = optIn.perRunTimeoutSeconds
        let remaining = aggregateLimit - Date().timeIntervalSince(sessionStartedAt)
        guard remaining > 1 else {
            throw NativeCADLiveError.aggregateTimeExceeded(aggregateLimit)
        }
        let turnTimeout = min(perRunLimit, remaining)
        let timeoutMilliseconds = max(1_000, Int64(turnTimeout * 1000))

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await service.startPrepared(goal: goal)
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                    if remaining < perRunLimit {
                        await stop.set(.aggregateTimeExceeded(aggregateLimit))
                        await service.cancel()
                        throw NativeCADLiveError.aggregateTimeExceeded(aggregateLimit)
                    }
                    await stop.set(.timedOut(runID))
                    await service.cancel()
                    throw NativeCADLiveError.timedOut(runID)
                }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(2_000))
                        let records = (try? await runStore.usage(runID: runID)) ?? []
                        let totals = await ledger.update(runID: runID, records: records)
                        if totals.exceeds {
                            let message = totals.description
                            await stop.set(.budgetExceeded(message))
                            await service.cancel()
                            throw NativeCADLiveError.budgetExceeded(message)
                        }
                    }
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }

            try await stop.throwIfStopped()

            var snapshot = await service.snapshot()
            for _ in 0..<50 where !snapshot.isTerminal {
                try? await Task.sleep(for: .milliseconds(100))
                snapshot = await service.snapshot()
            }
            guard snapshot.isTerminal else {
                await service.cancel()
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "The run never reached a terminal state."
                )
            }
            guard snapshot.stateName == "completed" else {
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "The run did not complete; acceptance never retries a failed model turn."
                )
            }
            guard snapshot.pendingApproval == nil else {
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "A call remained awaiting interactive approval; the owned task policy is automatic."
                )
            }

            let records = (try? await runStore.usage(runID: runID)) ?? []
            let totals = await ledger.update(runID: runID, records: records)
            guard !records.isEmpty else {
                throw NativeCADLiveError.missingUsage
            }
            let runReportedTokens = records.reduce(0) { partial, record in
                partial + record.inputTokens + (record.cacheReadTokens ?? 0) + record.outputTokens
            }
            guard runReportedTokens > 0 else {
                throw NativeCADLiveError.missingUsage
            }
            guard totals.hasUsage else { throw NativeCADLiveError.missingUsage }
            guard !totals.exceeds else {
                throw NativeCADLiveError.budgetExceeded(totals.description)
            }
            if Date().timeIntervalSince(sessionStartedAt) > optIn.maxTotalSeconds {
                throw NativeCADLiveError.aggregateTimeExceeded(optIn.maxTotalSeconds)
            }
        } catch {
            await service.cancel()
            throw error
        }
    }

    // MARK: On-disk independent verification

    private func inspectDocument(at url: URL) async throws -> NativeCADLiveDocumentState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NativeCADLiveError.missingDocument(url.path)
        }
        // Keep the exact synthetic package before any identity/geometry
        // assertion. Cleanup removes the task, so hashes and prose alone
        // would otherwise make a failure impossible to reproduce.
        try attachDocumentWitness(at: url, phase: "inspect")
        let manifest = url.appendingPathComponent("manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw NativeCADLiveError.invalidDocument("the versioned package has no manifest.json")
        }
        guard let stored = await FloeCADDocument.storedIdentity(at: url) else {
            throw NativeCADLiveError.invalidDocument("the versioned store rejected the package identity")
        }

        let document = try await FloeCADDocument.open(at: url)
        defer { document.close() }
        let summary = document.summary()
        let bodies = try nativeRows(document, scope: "bodies")
        guard let body = bodies.first, let bodyID = body["id"] as? String else {
            throw NativeCADLiveError.invalidDocument("the package has no body")
        }
        let isAnalytic = (body["analyticBRep"] as? Bool) == true
        let volume = try measureVolume(document, bodyID: bodyID)
        let sketches = try nativeRows(document, scope: "sketches")
        let features = try nativeRows(document, scope: "features")
        let faces = try nativeRows(document, scope: "faces")

        var circles: [NativeCADLiveCircle] = []
        for sketch in sketches {
            guard let sketchID = sketch["id"] as? String,
                  let entityRows = sketch["entityRows"] as? [[String: Any]] else { continue }
            for row in entityRows {
                guard (row["kind"] as? String) == "circle",
                      (row["construction"] as? Bool) != true,
                      let entityID = row["id"] as? String,
                      let radius = NativeCADLiveJSON.number(row["radius"]),
                      let diameter = NativeCADLiveJSON.number(row["diameterMM"]) else { continue }
                circles.append(NativeCADLiveCircle(
                    sketchID: sketchID,
                    entityID: entityID,
                    radius: radius,
                    diameter: diameter
                ))
            }
        }

        var fillet: NativeCADLiveFillet?
        for row in features where (row["kind"] as? String) == "fillet" {
            guard let id = row["id"] as? String,
                  let parameters = row["parameters"] as? [[String: Any]] else { continue }
            let radius = parameters.first { ($0["name"] as? String) == "radius" }
                .flatMap { NativeCADLiveJSON.number($0["value"]) }
            let edgeCount = parameters.first { ($0["name"] as? String) == "edge_count" }
                .flatMap { NativeCADLiveJSON.int($0["value"]) }
            if let radius, let edgeCount {
                fillet = NativeCADLiveFillet(id: id, radius: radius, edgeCount: edgeCount)
                break
            }
        }

        let cylindricalRadii = faces.compactMap { row -> Double? in
            guard (row["kind"] as? String) == "cylindrical" else { return nil }
            return NativeCADLiveJSON.number(row["radiusMM"])
        }

        return NativeCADLiveDocumentState(
            revision: stored.revision,
            contentSHA256: stored.contentSHA256,
            modelSHA256: stored.modelSHA256,
            bodyCount: summary.bodyCount,
            sketchCount: summary.sketchCount,
            featureCount: summary.featureCount,
            bodyID: bodyID,
            bodyIsAnalytic: isAnalytic,
            bodyVolumeMM3: volume,
            circles: circles,
            fillet: fillet,
            cylindricalRadii: cylindricalRadii
        )
    }

    private func assertInitialGeometry(_ state: NativeCADLiveDocumentState) throws {
        XCTAssertEqual(state.bodyCount, 1, "The bracket must be one body after the hole cut.")
        XCTAssertTrue(state.bodyIsAnalytic, "The plate+hole body must remain an analytic B-rep.")
        XCTAssertEqual(state.circles.count, 1, "The bracket must contain exactly one non-construction hole circle.")
        let circle = try XCTUnwrap(state.circles.first, "The initial Ø6 hole circle was not found.")
        XCTAssertEqual(circle.radius, 3.0, accuracy: 1e-6)
        XCTAssertEqual(circle.diameter, 6.0, accuracy: 1e-6)

        let expected = 80.0 * 50.0 * 10.0 - Double.pi * 3.0 * 3.0 * 10.0
        XCTAssertEqual(
            state.bodyVolumeMM3,
            expected,
            accuracy: 1.0,
            "The Ø6 through-hole volume is not the actual 80×50×10 plate minus the hole."
        )
        XCTAssertNil(state.fillet, "The first turn must not create the turn-two fillet.")
        XCTAssertGreaterThan(state.revision, 0)
        XCTAssertEqual(state.contentSHA256.count, 64)
    }

    private func assertEditedGeometry(
        _ state: NativeCADLiveDocumentState,
        initial: NativeCADLiveDocumentState
    ) throws {
        XCTAssertEqual(state.bodyCount, 1, "The hole edit/fillet must keep one body.")
        XCTAssertEqual(state.bodyID, initial.bodyID, "Editing the existing hole must keep the SAME body identity.")
        XCTAssertTrue(state.bodyIsAnalytic, "The edited body must remain an analytic B-rep.")
        XCTAssertEqual(state.circles.count, 1)
        let circle = try XCTUnwrap(state.circles.first)
        let initialCircle = try XCTUnwrap(initial.circles.first)
        XCTAssertEqual(circle.sketchID, initialCircle.sketchID, "The hole edit must reuse the SAME hole sketch.")
        XCTAssertEqual(circle.entityID, initialCircle.entityID, "The hole edit must reuse the SAME circle entity.")
        XCTAssertEqual(circle.radius, 4.0, accuracy: 1e-6, "The existing hole must be exactly Ø8 (radius 4 mm).")
        XCTAssertEqual(circle.diameter, 8.0, accuracy: 1e-6)

        let fillet = try XCTUnwrap(state.fillet, "No real fillet feature was found after the edit turn.")
        XCTAssertEqual(fillet.radius, 2.0, accuracy: 1e-6, "The fillet radius must be exactly 2 mm.")
        XCTAssertTrue((1...4).contains(fillet.edgeCount), "The synthetic flow requests 1...4 vertical corner edges, got \(fillet.edgeCount).")
        XCTAssertTrue(
            state.cylindricalRadii.contains { abs($0 - 4.0) < 1e-4 },
            "Query kind=faces must report the rebuilt Ø8 cylindrical hole; found \(state.cylindricalRadii)."
        )

        let expected = 80.0 * 50.0 * 10.0
            - Double.pi * 4.0 * 4.0 * 10.0
            - Double(fillet.edgeCount) * 10.0 * (4.0 - Double.pi)
        XCTAssertEqual(
            state.bodyVolumeMM3,
            expected,
            accuracy: 2.0,
            "The actual volume must match the Ø8 hole plus the reported \(fillet.edgeCount) corner fillet(s)."
        )
        XCTAssertGreaterThan(state.revision, initial.revision, "The edit turn must commit a newer package revision.")
        XCTAssertNotEqual(state.contentSHA256, initial.contentSHA256, "The edit turn must change the verified package content.")
        if let initialModelSHA = initial.modelSHA256, let editedModelSHA = state.modelSHA256 {
            XCTAssertNotEqual(
                editedModelSHA,
                initialModelSHA,
                "The edit turn must change the canonical CAD model identity."
            )
        } else {
            XCTFail("The verified package did not expose its additive modelSHA256 identity.")
        }
    }

    /// The two native undos must restore the exact pre-correction model, not
    /// merely a similar-looking shape. `modelSHA256` covers the canonical model
    /// records and blobs (preview excluded), so equality with the initial state
    /// is an independent identity proof that the SAME hole entity and the
    /// absence of the fillet were restored.
    private func assertUndoRestoredGeometry(
        _ state: NativeCADLiveDocumentState,
        initial: NativeCADLiveDocumentState,
        edited: NativeCADLiveDocumentState
    ) throws {
        XCTAssertEqual(state.bodyCount, 1, "Undo must keep exactly one body.")
        XCTAssertEqual(state.bodyID, initial.bodyID, "Undo must keep the SAME body identity.")
        XCTAssertTrue(state.bodyIsAnalytic, "The undone body must remain an analytic B-rep.")
        XCTAssertEqual(state.circles.count, 1)
        let circle = try XCTUnwrap(state.circles.first)
        let initialCircle = try XCTUnwrap(initial.circles.first)
        XCTAssertEqual(circle.sketchID, initialCircle.sketchID, "Undo must keep the SAME hole sketch.")
        XCTAssertEqual(circle.entityID, initialCircle.entityID, "Undo must keep the SAME hole circle entity.")
        XCTAssertEqual(circle.radius, 3.0, accuracy: 1e-6, "Undo must restore the original Ø6 radius 3 mm.")
        XCTAssertEqual(circle.diameter, 6.0, accuracy: 1e-6)
        XCTAssertNil(state.fillet, "Undo must remove the 2 mm fillet feature.")
        XCTAssertFalse(
            state.cylindricalRadii.contains { abs($0 - 4.0) < 1e-4 },
            "Undo must remove the Ø8 cylindrical hole; found \(state.cylindricalRadii)."
        )

        let expected = 80.0 * 50.0 * 10.0 - Double.pi * 3.0 * 3.0 * 10.0
        XCTAssertEqual(
            state.bodyVolumeMM3,
            expected,
            accuracy: 1.0,
            "Undo must restore the exact Ø6 plate-minus-hole volume."
        )
        XCTAssertGreaterThan(state.revision, edited.revision, "The undo turn must commit newer revisions.")
        XCTAssertNotEqual(state.contentSHA256, edited.contentSHA256, "Undo must change the verified package content.")
        guard let initialModelSHA = initial.modelSHA256, let undoneModelSHA = state.modelSHA256 else {
            XCTFail("The verified package did not expose its additive modelSHA256 identity across undo.")
            throw NativeCADLiveError.invalidDocument("modelSHA256 was unavailable before or after undo")
        }
        XCTAssertEqual(
            undoneModelSHA,
            initialModelSHA,
            "Undo did not restore the exact canonical model identity of the original Ø6 part."
        )
        guard undoneModelSHA == initialModelSHA else {
            throw NativeCADLiveError.invalidDocument(
                "Native undo did not restore the original canonical model identity."
            )
        }
    }

    /// The package reopened from disk after the real bridge close must still
    /// expose the exact original definitions and canonical model identity.
    private func assertReopenRetainedGeometry(
        _ state: NativeCADLiveDocumentState,
        initial: NativeCADLiveDocumentState
    ) throws {
        XCTAssertEqual(state.bodyCount, 1)
        XCTAssertEqual(state.bodyID, initial.bodyID, "Disk reopen changed the body identity.")
        XCTAssertTrue(state.bodyIsAnalytic)
        XCTAssertEqual(state.circles.count, 1)
        let circle = try XCTUnwrap(state.circles.first)
        let initialCircle = try XCTUnwrap(initial.circles.first)
        XCTAssertEqual(circle.sketchID, initialCircle.sketchID, "Disk reopen changed the hole sketch identity.")
        XCTAssertEqual(circle.entityID, initialCircle.entityID, "Disk reopen changed the hole circle identity.")
        XCTAssertEqual(circle.radius, 3.0, accuracy: 1e-6)
        XCTAssertNil(state.fillet)
        guard let initialModelSHA = initial.modelSHA256, let reopenedModelSHA = state.modelSHA256 else {
            XCTFail("The verified package did not expose its additive modelSHA256 identity across reopen.")
            throw NativeCADLiveError.invalidDocument("modelSHA256 was unavailable before or after reopen")
        }
        XCTAssertEqual(
            reopenedModelSHA,
            initialModelSHA,
            "The saved package reopened from disk did not retain its exact canonical model identity."
        )
        guard reopenedModelSHA == initialModelSHA else {
            throw NativeCADLiveError.invalidDocument(
                "The reopened package lost the original canonical model identity."
            )
        }
    }

    /// One further edit after the real disk reopen must land on the SAME body
    /// and hole entity and be independently visible in the committed geometry.
    private func assertFurtherEditedGeometry(
        _ state: NativeCADLiveDocumentState,
        initial: NativeCADLiveDocumentState,
        reopened: NativeCADLiveDocumentState
    ) throws {
        XCTAssertEqual(state.bodyCount, 1)
        XCTAssertEqual(state.bodyID, initial.bodyID, "The post-reopen edit changed the body identity.")
        XCTAssertTrue(state.bodyIsAnalytic, "The post-reopen body must remain an analytic B-rep.")
        XCTAssertEqual(state.circles.count, 1)
        let circle = try XCTUnwrap(state.circles.first)
        let initialCircle = try XCTUnwrap(initial.circles.first)
        XCTAssertEqual(circle.sketchID, initialCircle.sketchID, "The post-reopen edit changed the hole sketch.")
        XCTAssertEqual(circle.entityID, initialCircle.entityID, "The post-reopen edit changed the hole circle entity.")
        XCTAssertEqual(circle.radius, 5.0, accuracy: 1e-6, "The post-reopen hole must be exactly Ø10 (radius 5 mm).")
        XCTAssertEqual(circle.diameter, 10.0, accuracy: 1e-6)
        XCTAssertNil(state.fillet, "The post-reopen flow did not re-add a fillet.")
        XCTAssertTrue(
            state.cylindricalRadii.contains { abs($0 - 5.0) < 1e-4 },
            "Query kind=faces must report the rebuilt Ø10 cylindrical hole; found \(state.cylindricalRadii)."
        )

        let expected = 80.0 * 50.0 * 10.0 - Double.pi * 5.0 * 5.0 * 10.0
        XCTAssertEqual(
            state.bodyVolumeMM3,
            expected,
            accuracy: 2.0,
            "The final volume must match the same 80×50×10 plate minus the Ø10 through-hole."
        )
        XCTAssertGreaterThan(state.revision, reopened.revision, "The further edit must commit a newer revision.")
        XCTAssertNotEqual(state.contentSHA256, reopened.contentSHA256)
        guard let reopenedModelSHA = reopened.modelSHA256, let finalModelSHA = state.modelSHA256 else {
            XCTFail("The verified package did not expose its additive modelSHA256 identity after the further edit.")
            throw NativeCADLiveError.invalidDocument("modelSHA256 was unavailable after the further edit")
        }
        XCTAssertNotEqual(
            finalModelSHA,
            reopenedModelSHA,
            "The further edit did not change the canonical model identity."
        )
    }

    // MARK: Capture evidence

    private func validateCapture(
        events: [RunEventRecord],
        runID: UUID,
        requirement: NativeCADLiveRevisionRequirement,
        preferLast: Bool
    ) throws -> NativeCADLiveCapture {
        var selected: NativeCADLiveCapture?
        for event in events where event.kind == .toolResult {
            guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  (payload["tool"] as? String) == CadDocumentTool.name,
                  (payload["status"] as? String) == "ok",
                  let summary = payload["summary"] as? String else { continue }
            for object in NativeCADLiveJSON.objects(in: summary) {
                guard (object["action"] as? String) == "capture",
                      (object["ok"] as? Bool) != false,
                      let relative = object["artifact"] as? String,
                      let imageSHA = object["image_sha256"] as? String,
                      let contentSHA = object["content_sha256"] as? String,
                      let width = NativeCADLiveJSON.int(object["width"]),
                      let height = NativeCADLiveJSON.int(object["height"]),
                      let byteCount = NativeCADLiveJSON.int(object["byte_count"]),
                      let renderer = object["renderer"] as? String,
                      let callID = payload["id"] as? String else { continue }

                let revision = try XCTUnwrap(
                    NativeCADLiveJSON.int(object["revision"]),
                    "The successful capture receipt did not report a document revision."
                )
                guard requirement.accepts(revision) else { continue }

                guard width == 1024, height == 768 else {
                    throw NativeCADLiveError.invalidCapture("Expected a 1024×768 engineering PNG, got \(width)×\(height).")
                }
                guard renderer == "engineering" else {
                    throw NativeCADLiveError.invalidCapture("Expected the engineering viewport renderer, got \(renderer).")
                }
                guard contentSHA.count == 64, imageSHA.count == 64 else {
                    throw NativeCADLiveError.invalidCapture(
                        "The capture does not carry a 64-character content/image identity."
                    )
                }
                let components = relative.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count >= 3,
                      components[0] == "CADViewportArtifacts",
                      components[1] == runID.uuidString else {
                    throw NativeCADLiveError.invalidCapture(
                        "The capture artifact is not owned by run \(runID.uuidString): \(relative)"
                    )
                }

                let url = try NativeCADLivePaths.captureArtifactURL(relativePath: relative)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw NativeCADLiveError.invalidCapture("The reported capture artifact does not exist at \(relative).")
                }
                let png = try Data(contentsOf: url)
                guard png.count == byteCount else {
                    throw NativeCADLiveError.invalidCapture("The capture file byte count \(png.count) differs from the tool receipt \(byteCount).")
                }
                guard FloeDigest.sha256Hex(png) == imageSHA else {
                    throw NativeCADLiveError.invalidCapture("The capture file SHA-256 does not match the tool receipt.")
                }
                guard url.lastPathComponent == "\(imageSHA).png" else {
                    throw NativeCADLiveError.invalidCapture("The artifact file name is not the image digest.")
                }
                let pngMagic = Array(png.prefix(8))
                guard pngMagic == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
                    throw NativeCADLiveError.invalidCapture("The artifact does not begin with the PNG signature.")
                }

                if let artifactRefsJSON = payload["artifactRefsJSON"] as? String,
                   let refsData = artifactRefsJSON.data(using: .utf8),
                   let refs = (try? JSONSerialization.jsonObject(with: refsData)) as? [[String: Any]] {
                    let matching = refs.first {
                        ($0["relativePath"] as? String) == relative
                    }
                    XCTAssertNotNil(matching, "The persisted tool result does not carry the capture artifact reference.")
                    XCTAssertTrue((matching?["sha256"] as? String) == imageSHA)
                    XCTAssertEqual(NativeCADLiveJSON.int(matching?["byteCount"]) ?? -1, png.count)
                } else {
                    XCTFail("The successful capture tool result did not persist its artifact reference.")
                }

                let stats = try NativeCADLivePixels.stats(png)
                XCTAssertEqual(stats.width, 1024)
                XCTAssertEqual(stats.height, 768)
                XCTAssertGreaterThan(stats.uniqueColorBuckets, 16, "The capture is effectively blank/flat.")
                XCTAssertGreaterThan(stats.nonBackgroundFraction, 0.005, "The capture contains no visible rendered body.")

                captureRelativePaths.append(relative)
                XCTAssertTrue(runIDs.last == runID, "The capture must come from the current owned run.")
                let capture = NativeCADLiveCapture(
                    png: png,
                    imageSHA256: imageSHA,
                    contentSHA256: contentSHA,
                    revision: revision,
                    width: width,
                    height: height,
                    byteCount: byteCount,
                    renderer: renderer,
                    relativePath: relative,
                    callID: callID,
                    resultSequence: event.sequence
                )
                selected = capture
                if !preferLast { return capture }
            }
        }
        guard let selected else {
            throw NativeCADLiveError.missingCapture
        }
        return selected
    }

    private func assertCaptureMatches(
        _ capture: NativeCADLiveCapture,
        state: NativeCADLiveDocumentState,
        label: String
    ) throws {
        XCTAssertEqual(
            capture.revision,
            state.revision,
            "The \(label) capture revision does not match the independently verified package revision."
        )
        XCTAssertEqual(
            capture.contentSHA256,
            state.contentSHA256,
            "The \(label) capture is not bound to the exact verified package content identity."
        )
        guard capture.revision == state.revision,
              capture.contentSHA256 == state.contentSHA256 else {
            throw NativeCADLiveError.invalidCapture(
                "The \(label) capture does not belong to the verified package revision/content."
            )
        }
    }

    private func requireVisionReceipt(
        runID: UUID,
        capture: NativeCADLiveCapture
    ) throws -> NativeCADLiveVisionReceipt {
        guard let receipt = visionReceipts.first(where: {
            $0.runID == runID
                && $0.sourceSHA256 == capture.imageSHA256.lowercased()
                && $0.modelDeclaresVision
                && $0.imagePartCount >= 1
                && $0.deliveredSHA256 == $0.attachedSHA256
                && $0.deliveredByteCount == $0.attachedBytes
        }) else {
            XCTFail(
                "No actual outbound image part was observed for the pre-correction capture. "
                    + "The durable dispatch checkpoint did not show the verified image delivered "
                    + "to a vision-declaring model. A capture result alone is not image receipt."
            )
            throw NativeCADLiveError.missingVisionReceipt(
                "run \(runID.uuidString), image \(capture.imageSHA256)"
            )
        }

        XCTAssertEqual(receipt.providerID, route.provider.id)
        XCTAssertEqual(receipt.modelID, route.model.id)
        XCTAssertEqual(receipt.remoteModelID, route.model.remoteModelID)
        XCTAssertTrue(receipt.modelDeclaresVision)
        XCTAssertGreaterThanOrEqual(receipt.imagePartCount, 1)
        XCTAssertEqual(receipt.attachedSHA256, receipt.deliveredSHA256)
        XCTAssertEqual(receipt.attachedBytes, receipt.deliveredByteCount)
        XCTAssertTrue(ProviderImageEvidencePolicy.supportedMIMETypes.contains(receipt.deliveredMIMEType))
        XCTAssertTrue(
            receipt.captureCallIDs.contains(capture.callID),
            "The image dispatch does not belong to the capture tool call."
        )
        XCTAssertTrue(
            receipt.resultCallIDs.contains(capture.callID),
            "The image dispatch does not carry the capture result in the same provider request."
        )
        XCTAssertTrue(
            ["original", "derived-preview"].contains(receipt.representation),
            "Unexpected image representation: \(receipt.representation)"
        )
        if receipt.representation == "original" {
            XCTAssertEqual(receipt.deliveredSHA256, capture.imageSHA256.lowercased())
        } else {
            XCTAssertEqual(receipt.deliveredMIMEType, "image/jpeg")
        }

        guard receipt.providerID == route.provider.id,
              receipt.modelID == route.model.id,
              receipt.remoteModelID == route.model.remoteModelID,
              receipt.modelDeclaresVision,
              receipt.imagePartCount >= 1,
              receipt.attachedSHA256 == receipt.deliveredSHA256,
              receipt.attachedBytes == receipt.deliveredByteCount,
              ProviderImageEvidencePolicy.supportedMIMETypes.contains(receipt.deliveredMIMEType),
              receipt.captureCallIDs.contains(capture.callID),
              receipt.resultCallIDs.contains(capture.callID),
              ["original", "derived-preview"].contains(receipt.representation),
              receipt.representation != "original"
                || receipt.deliveredSHA256 == capture.imageSHA256.lowercased() else {
            throw NativeCADLiveError.invalidVisionReceipt(
                "digest/bytes/model/call binding did not match the captured viewport"
            )
        }
        return receipt
    }

    private func attach(_ png: Data, name: String) {
        let attachment = XCTAttachment(data: png)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { activity in
            activity.add(attachment)
        }
    }

    private func attachUsage(_ totals: NativeCADLiveTotals) {
        let attachment = XCTAttachment(string: totals.description)
        attachment.name = "native-cad-live-usage.txt"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Native CAD live model usage") { activity in
            activity.add(attachment)
        }
    }

    // MARK: Durable failure evidence, attached before owned cleanup deletes it

    func recordFailure(_ error: Error) {
        if failureDescription == nil {
            failureDescription = String(describing: error)
        }
    }

    /// Only the one synthetic package owned by this test may be retained.
    /// Copy bytes into attachments now: a file-backed attachment can outlive
    /// the task's deletion without having copied the original file yet.
    private func attachDocumentWitness(at url: URL, phase: String) throws {
        guard let workspaceRoot,
              url.standardizedFileURL == workspaceRoot
                .appendingPathComponent(documentName, isDirectory: true).standardizedFileURL else {
            throw NativeCADLiveError.invalidDocument("Refusing evidence outside the owned synthetic document.")
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        func files(in directory: URL) throws -> [URL] {
            let values = try directory.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw NativeCADLiveError.invalidDocument("The synthetic package contains an unsafe directory.")
            }
            var result: [URL] = []
            for file in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys)
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    throw NativeCADLiveError.invalidDocument("The synthetic package contains a symbolic link.")
                }
                if values.isDirectory == true {
                    result += try files(in: file)
                } else if values.isRegularFile == true {
                    result.append(file)
                }
            }
            return result
        }
        let packageFiles = try files(in: url)
        documentWitnessCount += 1
        let prefix = "native-cad-live-package-\(documentWitnessCount)-\(phase)"
        var index: [[String: Any]] = []
        for (offset, file) in packageFiles.enumerated() {
            let relative = String(file.path.dropFirst(url.path.count + 1))
            let data = try Data(contentsOf: file)
            let name = "\(prefix)-\(offset)-\(file.lastPathComponent)"
            let attachment = XCTAttachment(
                data: data,
                uniformTypeIdentifier: file.pathExtension == "json" ? "public.json" : "public.data")
            attachment.name = name
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Native CAD exact package: \(phase)") { activity in
                activity.add(attachment)
            }
            index.append(["path": relative, "attachment": name,
                          "bytes": data.count, "sha256": FloeDigest.sha256Hex(data)])
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["document": documentName, "phase": phase, "files": index],
            options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(prefix)-index.json"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Native CAD exact package index") { activity in
            activity.add(attachment)
        }
    }

    /// Reads the exact durable usage and tool lifecycle rows for every owned
    /// run and attaches a bounded, prompt-free text copy. Cleanup deletes the
    /// conversation/run rows, so this must run first on every exit path.
    private func attachDurableEvidence() async {
        let runStore = environment.runStore
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("native-cad-live durable evidence")
        lines.append("source=run_usage and run_events read before owned cleanup")
        lines.append("captured_at=\(formatter.string(from: Date()))")
        if let failureDescription {
            lines.append("failure=\(evidenceText(failureDescription))")
        } else {
            lines.append("failure=none observed on the success path")
        }
        let totals = await ledger.totals()
        lines.append("ledger_totals=\(totals.description)")
        lines.append("ledger_reported_total_tokens=\(totals.reportedTotalTokens)")
        lines.append("ledger_cache_read_tokens=\(totals.cacheReadTokens)")
        lines.append("ledger_has_usage=\(totals.hasUsage)")
        lines.append("run_count=\(runIDs.count)")
        lines.append("vision_receipt_count=\(visionReceipts.count)")
        if let visionCaptureRevision, let visionCaptureContentSHA256, let visionCaptureImageSHA256 {
            lines.append(
                "vision_capture revision=\(visionCaptureRevision)"
                    + " content_sha256=\(visionCaptureContentSHA256)"
                    + " image_sha256=\(visionCaptureImageSHA256)"
            )
        }
        for (index, receipt) in visionReceipts.enumerated() {
            lines.append(
                "vision_receipt[\(index)] run=\(receipt.runID.uuidString)"
                    + " provider=\(receipt.providerID.uuidString)"
                    + " model=\(receipt.modelID.uuidString)"
                    + " remote=\(receipt.remoteModelID)"
                    + " model_declares_vision=\(receipt.modelDeclaresVision)"
                    + " image_parts=\(receipt.imagePartCount)"
                    + " source_sha256=\(receipt.sourceSHA256)"
                    + " attached_sha256=\(receipt.attachedSHA256)"
                    + " bytes=\(receipt.attachedBytes)"
                    + " representation=\(receipt.representation)"
                    + " mime=\(receipt.deliveredMIMEType)"
                    + " delivered_bytes=\(receipt.deliveredByteCount)"
                    + " pending_calls=\(receipt.pendingCallIDs.count)"
                    + " capture_calls=\(receipt.captureCallIDs.count)"
                    + " result_calls=\(receipt.resultCallIDs.count)"
            )
        }
        if let undoEvidence {
            lines.append(
                "undo_evidence commands=\(undoEvidence.undoCommandCount)"
                    + " revisions=\(undoEvidence.initialRevision)->\(undoEvidence.editedRevision)->\(undoEvidence.undoneRevision)"
                    + " last_undo_receipt_revision=\(undoEvidence.lastUndoReceiptRevision)"
                    + " model_sha_equal=\(undoEvidence.initialModelSHA256 == undoEvidence.restoredModelSHA256)"
            )
        }
        if let reopenEvidence {
            lines.append(
                "reopen_evidence instance_changed=\(reopenEvidence.instanceChanged)"
                    + " revisions=\(reopenEvidence.revisionBefore)->\(reopenEvidence.revisionAfter)"
                    + " content_sha256_after=\(reopenEvidence.contentSHA256After)"
                    + " model_sha256_after=\(reopenEvidence.modelSHA256After)"
            )
        }

        for (index, runID) in runIDs.enumerated() {
            lines.append("")
            lines.append("run[\(index)] \(runID.uuidString)")
            let usageRows = try? await runStore.usage(runID: runID)
            let usage = usageRows ?? []
            lines.append("usage_records=\(usage.count)")
            for (offset, record) in usage.enumerated() {
                lines.append(
                    "  usage[\(offset)] input_tokens=\(record.inputTokens)"
                        + " output_tokens=\(record.outputTokens)"
                        + " cache_read_tokens=\(intText(record.cacheReadTokens))"
                        + " cache_miss_tokens=\(intText(record.cacheMissTokens))"
                        + " cache_write_tokens=\(intText(record.cacheWriteTokens))"
                        + " reasoning_tokens=\(intText(record.reasoningTokens))"
                        + " estimated=\(record.isEstimated)"
                        + " total_duration_ms=\(intText(record.totalDurationMs))"
                        + " time_to_first_token_ms=\(intText(record.timeToFirstTokenMs))"
                        + " tokens_per_second=\(doubleText(record.tokensPerSecond))"
                        + " cost_estimate=\(record.costEstimate ?? "nil")"
                        + " recorded_at=\(formatter.string(from: record.recordedAt))"
                )
            }
            if let usageRows {
                if usageRows.isEmpty {
                    lines.append("  exact_usage_unavailable=no durable run_usage row existed before cleanup")
                }
            } else {
                lines.append("  exact_usage_unavailable=run_usage could not be read before cleanup")
            }

            let eventRows = try? await runStore.events(runID: runID)
            let events = eventRows ?? []
            lines.append("events=\(events.count)")
            if eventRows == nil {
                lines.append("  tool_evidence_unavailable=run_events could not be read before cleanup")
            }
            for event in events {
                switch event.kind {
                case .toolRequest, .toolResult:
                    if let line = toolEvidenceLine(event: event) {
                        lines.append(line)
                    }
                case .error:
                    if let payload = NativeCADLiveJSON.object(event.payloadJSON) {
                        var parts = ["kind=error", "sequence=\(event.sequence)"]
                        for key in ["kind", "message", "httpStatus", "recoverable"] {
                            if let value = payload[key] as? String, !value.isEmpty {
                                parts.append("\(key)=\(evidenceText(value))")
                            }
                        }
                        lines.append("  " + parts.joined(separator: " "))
                    }
                default:
                    break
                }
            }
        }

        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "native-cad-live-durable-evidence.txt"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Native CAD live durable run evidence") { activity in
            activity.add(attachment)
        }
    }

    private func toolEvidenceLine(event: RunEventRecord) -> String? {
        guard let payload = NativeCADLiveJSON.object(event.payloadJSON) else {
            return "  kind=\(event.kind.rawValue) sequence=\(event.sequence) unreadable_payload"
        }
        var parts = [
            "kind=\(event.kind.rawValue)",
            "sequence=\(event.sequence)",
        ]
        if let id = payload["id"] as? String { parts.append("call_id=\(id)") }
        if let tool = payload["tool"] as? String { parts.append("tool=\(tool)") }
        if let status = payload["status"] as? String { parts.append("status=\(status)") }
        if event.kind == .toolRequest,
           let input = payload["input"] as? String,
           let arguments = NativeCADLiveJSON.object(input) {
            if let action = arguments["action"] as? String { parts.append("action=\(action)") }
            if let op = arguments["op"] as? String { parts.append("op=\(op)") }
            if let path = arguments["path"] as? String {
                parts.append("path=\((path as NSString).lastPathComponent)")
            }
            if let summary = arguments["summary"] as? String {
                parts.append("request_summary=\(evidenceText(summary))")
            }
        }
        if let summary = payload["summary"] as? String {
            parts.append("summary=\(evidenceText(summary))")
        }
        if let digest = payload["outputDigest"] as? String, !digest.isEmpty {
            parts.append("output_digest=\(digest)")
        }
        for key in ["durationMs", "queuedMs"] {
            if let value = payload[key] as? String { parts.append("\(key)=\(value)") }
            else if let value = payload[key] as? Int { parts.append("\(key)=\(value)") }
        }
        for key in ["error", "errorCode"] {
            if let value = payload[key] as? String, !value.isEmpty {
                parts.append("\(key)=\(evidenceText(value))")
            }
        }
        return "  " + parts.joined(separator: " ")
    }

    private func intText(_ value: Int?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private func doubleText(_ value: Double?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private func evidenceText(_ value: String, limit: Int = 6_000) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…[truncated]"
    }

    // MARK: Small query helpers

    private func nativeRows(_ document: FloeCADDocument, scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope])
        guard outcome.isOK,
              let object = NativeCADLiveJSON.object(outcome.payload),
              let rows = object["rows"] as? [[String: Any]] else {
            throw NativeCADLiveError.invalidDocument(
                "query \(scope) failed: \(outcome.errorCode ?? "unknown") \(outcome.message ?? "")"
            )
        }
        return rows
    }

    private func measureVolume(_ document: FloeCADDocument, bodyID: String) throws -> Double {
        let outcome = document.measureJSON(["kind": "body", "bodyID": bodyID])
        guard outcome.isOK,
              let object = NativeCADLiveJSON.object(outcome.payload),
              let volume = NativeCADLiveJSON.number(object["volumeMM3"]) else {
            throw NativeCADLiveError.invalidDocument(
                "measure body failed: \(outcome.errorCode ?? "unknown") \(outcome.message ?? "")"
            )
        }
        return volume
    }

    // MARK: Prompts

    private func turnOneGoal() -> String {
        """
        Use the cad.document tool to create a real native CAD document named "\(documentName)".
        Work in the current task workspace; do not write package files by hand.

        Build a 80 mm x 50 mm x 10 mm plate:
        - sketch.create for the plate profile;
        - sketch.addEntities with a rect from [0,0] to [80,50];
        - feature.extrude with seedPoint [40,25] and distance 10.
        Then cut a Ø6 through-hole at the center:
        - query kind=bodies to get the plate body id;
        - sketch.create for the hole;
        - sketch.addEntities with a circle centered at [40,25] and radius 3;
        - feature.extrude with seedPoint [40,25], distance 40, symmetric true,
          boolean "subtract", and booleanTargets [<plate body id>].

        Apply every proposal you draft (omit grant_id; the runtime authorizes the
        exact approved call), save the document, and query kind=bodies and
        kind=sketches to confirm one body and the Ø6 circle. Do not only describe
        the steps: call the tool and verify the result. Do not add any other
        tool calls.
        """
    }

    private func turnTwoGoal(documentPath: String) -> String {
        """
        Open the same native CAD document "\(documentPath)". The rendered opening
        is too small for the intended Ø8 clearance. Inspect it and correct it.

        Do these steps IN ORDER; the first step must happen before any save or
        edit:
        1. Capture the CURRENT saved revision with cad.document action "capture",
           width 1024, height 768. The App attaches that actual PNG to your next
           turn because the selected model accepts image input; inspect the real
           image before editing.
        2. query kind=sketches, find the existing non-construction circle in the
           hole sketch, and keep its sketch id and stable entity id.
        3. Correct that SAME circle's radius from 3 to exactly 4 mm with
           cad.document action "parameters", payload JSON:
           {"action":"updateSketchEntity","sketch_id":"<id>","entity_id":"<id>",
            "radius":4,"expected_radius":3}
        4. query kind=bodies and kind=edges. Choose the vertical corner edge(s)
           of the 10 mm plate (their edge midpoints are near (0,5,0), (80,5,0),
           (0,5,-50), (80,5,-50)). Propose feature.fillet with bodyID, radius 2,
           the chosen edge indices, and the current query_token. Apply it
           (omit grant_id).
        5. Save the document, then query kind=features and kind=sketches and
           read back the actual hole diameter and fillet radius/edge count.

        Do not create a new hole or a new sketch. Do not rebuild the plate.
        Apply every proposal you draft and do not add any other tool calls.
        """
    }

    private func turnThreeGoal(documentPath: String) -> String {
        """
        The same native CAD document "\(documentPath)" is still open. Undo the
        last two native edits in this exact order with the REAL parameters undo
        command; do not use versions restore and do not edit geometry by hand.

        1. cad.document action "parameters", payload {"action":"undo"} — undo
           the 2 mm fillet.
        2. Query kind=features and kind=sketches, then repeat the same parameters
           undo command — undo the Ø8 hole radius edit and restore that SAME
           circle to radius 3.
        3. Query kind=features, kind=sketches and kind=bodies again and read
           back the actual hole radius/diameter and confirm no fillet remains.
        4. Save the document.

        Do not run redo, do not create anything, and do not add any other tool
        calls. Report only values the tool replies actually returned.
        """
    }

    private func turnFourGoal(documentPath: String) -> String {
        """
        The same native CAD package "\(documentPath)" was closed and reopened
        from disk. Continue on the SAME body and hole; do not create a new
        document, hole or sketch.

        1. query kind=sketches, kind=features and kind=bodies to re-read the
           stable sketch id, circle entity id and body id. Confirm the hole
           radius is 3 (Ø6) and the fillet is gone.
        2. Change that SAME circle from radius 3 to exactly 5 mm (Ø10) with
           cad.document action "parameters", payload JSON:
           {"action":"updateSketchEntity","sketch_id":"<id>","entity_id":"<id>",
            "radius":5,"expected_radius":3}
           Then save.
        3. query kind=sketches, kind=features and kind=faces and measure the
           body (handles ["body:<body id>"]) to read back the actual Ø10 hole
           and volume.
        4. Capture a real engineering viewport PNG of this final revision with
           cad.document action "capture", width 1024, height 768. The capture
           must be the LAST tool call: do not save or edit after it, so the
           captured revision is the committed final package.

        Do not undo or redo. Do not add any other tool calls.
        """
    }

    // MARK: Owned cleanup

    func cleanup() async {
        guard !cleanupStarted else { return }
        cleanupStarted = true

        // Cancel AND join every owned service before deleting its rows. A
        // terminal transition is what guarantees no late callback can target a
        // document after cleanup.
        for service in services {
            await service.cancel()
        }
        var allTerminal = true
        for service in services {
            var snapshot = await service.snapshot()
            for _ in 0..<50 where !snapshot.isTerminal {
                try? await Task.sleep(for: .milliseconds(100))
                snapshot = await service.snapshot()
            }
            if !snapshot.isTerminal { allTerminal = false }
        }

        // The owning conversation and its runs/usage/events are deleted below.
        // Attach the exact durable evidence first on every exit path.
        await attachDurableEvidence()

        // Never delete rows or close the document under a run that refused to
        // reach a terminal state. Leaving the task-owned rows intact is the
        // safe recovery choice; a late callback must not target a missing row.
        guard allTerminal else {
            XCTFail(
                "An owned run did not reach a terminal state after cancellation; "
                    + "task-owned rows and the live document were left intact for inspection."
            )
            return
        }

        if failureDescription != nil, let documentURL,
           FileManager.default.fileExists(atPath: documentURL.path) {
            do {
                try attachDocumentWitness(at: documentURL, phase: "failure-after-join")
            } catch {
                XCTFail("Could not retain the failed synthetic package; owned task left intact: \(error)")
                return
            }
        }

        if let documentURL {
            for proposal in await environment.cadDocumentCenter.pendingNativeProposals(for: documentURL) {
                try? await environment.cadDocumentCenter.removeProposal(id: proposal.id)
            }
            await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
        }

        for runID in runIDs {
            await environment.contentUpdateCenter.releaseRunSnapshot(runID)
            NativeCADLivePaths.removeOwnedDirectory(
                NativeCADLivePaths.captureArtifactDirectory(runID: runID)
            )
            NativeCADLivePaths.removeOwnedDirectory(
                NativeCADLivePaths.skillRunSnapshotDirectory(runID: runID)
            )
        }
        for relative in captureRelativePaths {
            if let url = try? NativeCADLivePaths.captureArtifactURL(relativePath: relative) {
                NativeCADLivePaths.removeOwnedFile(url)
            }
        }

        do {
            try await center.deleteConversation(id: conversationID)
        } catch {
            XCTFail("Owned task cleanup failed: \(error.localizedDescription)")
        }

        for container in await environment.environmentRegistry.containersOwned(by: conversationID.uuidString) {
            try? await environment.environmentRegistry.remove(id: container.id)
        }

        if let workspaceRoot {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: workspaceRoot.path),
                "The owned private task workspace still exists after deletion: \(workspaceRoot.path)"
            )
        }
    }
}

// MARK: - Document state and evidence helpers

private struct NativeCADLiveCircle {
    var sketchID: String
    var entityID: String
    var radius: Double
    var diameter: Double
}

private struct NativeCADLiveFillet {
    var id: String
    var radius: Double
    var edgeCount: Int
}

private struct NativeCADLiveDocumentState {
    var revision: Int
    var contentSHA256: String
    var modelSHA256: String?
    var bodyCount: Int
    var sketchCount: Int
    var featureCount: Int
    var bodyID: String
    var bodyIsAnalytic: Bool
    var bodyVolumeMM3: Double
    var circles: [NativeCADLiveCircle]
    var fillet: NativeCADLiveFillet?
    var cylindricalRadii: [Double]
}

private enum NativeCADLiveRevisionRequirement {
    case exactly(Int)
    case atLeast(Int)

    func accepts(_ revision: Int) -> Bool {
        switch self {
        case .exactly(let expected): return revision == expected
        case .atLeast(let minimum): return revision >= minimum
        }
    }

    var label: String {
        switch self {
        case .exactly(let expected): return "revision == \(expected)"
        case .atLeast(let minimum): return "revision >= \(minimum)"
        }
    }
}

private struct NativeCADLiveCapture {
    var png: Data
    var imageSHA256: String
    var contentSHA256: String
    var revision: Int
    var width: Int
    var height: Int
    var byteCount: Int
    var renderer: String
    var relativePath: String
    var callID: String
    var resultSequence: Int
}

/// Metadata-only observation of one actual image delivery at the provider
/// dispatch boundary. It deliberately contains no base64 image and no
/// conversation/model text.
private struct NativeCADLiveVisionReceipt: Sendable {
    var runID: UUID
    var providerID: UUID
    var modelID: UUID
    var remoteModelID: String
    var modelDeclaresVision: Bool
    var sourceSHA256: String
    var attachedSHA256: String
    var attachedBytes: Int
    var representation: String
    var deliveredMIMEType: String
    var deliveredByteCount: Int
    var deliveredSHA256: String
    var pendingCallIDs: [String]
    var captureCallIDs: [String]
    var resultCallIDs: [String]
    var imagePartCount: Int
}

private struct NativeCADLiveUndoEvidence {
    var initialRevision: Int
    var editedRevision: Int
    var undoneRevision: Int
    var undoCommandCount: Int
    var lastUndoReceiptRevision: Int
    var initialModelSHA256: String
    var restoredModelSHA256: String
}

private struct NativeCADLiveReopenEvidence {
    var instanceChanged: Bool
    var revisionBefore: Int
    var revisionAfter: Int
    var contentSHA256After: String
    var modelSHA256After: String
}

/// Extracts only the bounded delivery receipt fields the runtime appends to
/// the visual-evidence message. It never parses or retains model text.
private enum NativeCADLiveVisionReceiptParser {
    struct Fields: Sendable, Equatable {
        var sourceSHA256: String
        var attachedSHA256: String
        var bytes: Int
        var representation: String
    }

    static func parse(_ text: String) -> [Fields] {
        var result: [Fields] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.contains("sourceSHA256="), line.contains("attachedSHA256=") else { continue }
            guard let source = value("sourceSHA256=", in: line),
                  let attached = value("attachedSHA256=", in: line),
                  let rawBytes = value("bytes=", in: line),
                  let bytes = Int(rawBytes),
                  bytes > 0,
                  let representation = value("representation=", in: line),
                  source.count == 64,
                  attached.count == 64 else { continue }
            result.append(Fields(
                sourceSHA256: source.lowercased(),
                attachedSHA256: attached.lowercased(),
                bytes: bytes,
                representation: representation
            ))
        }
        return result
    }

    private static func value(_ prefix: String, in line: String) -> String? {
        guard let range = line.range(of: prefix) else { return nil }
        let tail = line[range.upperBound...]
        let end = tail.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? tail.endIndex
        let value = String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Polls the durable recovery checkpoint only while one turn is running. A
/// dispatch checkpoint is written immediately before the provider request, so
/// the image-delivery request is observable as the actual outbound bytes. Only
/// image digest/size/MIME, model capability and call ids are retained; the
/// base64 payload and message text are discarded on every read.
private actor NativeCADLiveVisionCollector {
    private var receipts: [NativeCADLiveVisionReceipt] = []
    private var seenKeys: Set<String> = []
    private let maximumReceipts = 12

    func watch(
        checkpointStore: any CheckpointStore,
        runID: UUID,
        deadline: Date
    ) async {
        while !Task.isCancelled, Date() < deadline {
            if let checkpoint = try? await checkpointStore.load(runID: runID),
               let snapshot = checkpoint.providerDispatchRequest {
                ingest(snapshot, runID: runID)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func snapshot() -> [NativeCADLiveVisionReceipt] {
        receipts
    }

    private func ingest(
        _ snapshot: ProviderDispatchRequestSnapshot,
        runID: UUID
    ) {
        guard receipts.count < maximumReceipts else { return }
        let pendingCallIDs = snapshot.pendingToolCalls.map(\.id)
        let captureCallIDs = snapshot.pendingToolCalls.compactMap { call -> String? in
            guard call.toolName == CadDocumentTool.name,
                  let arguments = NativeCADLiveJSON.object(call.argumentsJSON),
                  (arguments["action"] as? String) == "capture" else { return nil }
            return call.id
        }
        let resultCallIDs = snapshot.toolResults.map(\.callID)

        for message in snapshot.messages where message.role == "user" {
            var textParts: [String] = []
            var images: [(mimeType: String, base64: String)] = []
            for part in message.content {
                switch part {
                case .text(let text):
                    textParts.append(text)
                case .imageData(let mimeType, let base64):
                    images.append((mimeType, base64))
                case .imageURL:
                    break
                }
            }
            let text = textParts.joined(separator: "\n")
            guard text.contains("Visual evidence delivery for the immediately preceding tool results")
                    || text.contains("Source delivery receipts:") else { continue }
            let fields = NativeCADLiveVisionReceiptParser.parse(text)
            guard !fields.isEmpty else { continue }

            for field in fields {
                guard receipts.count < maximumReceipts else { return }
                let key = [
                    runID.uuidString,
                    field.sourceSHA256,
                    field.attachedSHA256,
                    snapshot.model.id.uuidString,
                    String(images.count),
                ].joined(separator: "|")
                guard seenKeys.insert(key).inserted else { continue }

                var delivered: (mimeType: String, bytes: Int, sha256: String)?
                for image in images {
                    guard let data = Data(base64Encoded: image.base64) else { continue }
                    let digest = FloeDigest.sha256Hex(data).lowercased()
                    guard digest == field.attachedSHA256 else { continue }
                    delivered = (
                        ProviderImageEvidencePolicy.canonicalMIMEType(image.mimeType) ?? image.mimeType,
                        data.count,
                        digest
                    )
                    break
                }

                receipts.append(NativeCADLiveVisionReceipt(
                    runID: runID,
                    providerID: snapshot.provider.id,
                    modelID: snapshot.model.id,
                    remoteModelID: snapshot.model.remoteModelID,
                    modelDeclaresVision: snapshot.model.capabilities.contains(.vision),
                    sourceSHA256: field.sourceSHA256,
                    attachedSHA256: field.attachedSHA256,
                    attachedBytes: field.bytes,
                    representation: field.representation,
                    deliveredMIMEType: delivered?.mimeType ?? "",
                    deliveredByteCount: delivered?.bytes ?? 0,
                    deliveredSHA256: delivered?.sha256 ?? "",
                    pendingCallIDs: pendingCallIDs,
                    captureCallIDs: captureCallIDs,
                    resultCallIDs: resultCallIDs,
                    imagePartCount: images.count
                ))
            }
        }
    }
}

private enum NativeCADLiveEvidence {
    static func assertToolSurface(
        events: [RunEventRecord],
        documentName: String,
        turn: Int
    ) throws {
        var requests = 0
        var successfulResults = 0
        for event in events {
            switch event.kind {
            case .approval:
                XCTFail("Turn \(turn) produced an interactive approval event; the owned automatic policy should not ask.")
            case .toolRequest:
                guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                      let tool = payload["tool"] as? String else {
                    XCTFail("Turn \(turn) produced an unreadable tool request.")
                    continue
                }
                XCTAssertEqual(tool, CadDocumentTool.name, "Turn \(turn) called a tool outside the CAD-only ceiling.")
                requests += 1
                guard let input = payload["input"] as? String,
                      let arguments = NativeCADLiveJSON.object(input) else {
                    XCTFail("Turn \(turn) CAD request had no readable arguments.")
                    continue
                }
                if let path = arguments["path"] as? String {
                    XCTAssertEqual(
                        (path as NSString).lastPathComponent,
                        documentName,
                        "Turn \(turn) addressed a different native CAD document."
                    )
                    XCTAssertFalse(path.contains(".."), "Turn \(turn) used a traversal path.")
                }
                if (arguments["action"] as? String) == "apply" {
                    let grant = (arguments["grant_id"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    XCTAssertTrue(
                        grant.isEmpty,
                        "The model supplied a grant_id; this acceptance must exercise runtime authority, not a fabricated grant."
                    )
                }
            case .toolResult:
                guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                      let tool = payload["tool"] as? String else {
                    XCTFail("Turn \(turn) produced an unreadable tool result.")
                    continue
                }
                XCTAssertEqual(tool, CadDocumentTool.name)
                let status = payload["status"] as? String
                XCTAssertFalse(status == "needsUser", "Turn \(turn) stopped for user input.")
                if status == "ok" { successfulResults += 1 }
            default:
                break
            }
        }
        XCTAssertGreaterThan(requests, 0, "Turn \(turn) did not call the native CAD tool.")
        XCTAssertGreaterThan(successfulResults, 0, "Turn \(turn) had no successful native CAD tool result.")
    }

    static func assertFormulaTurn(
        _ events: [RunEventRecord], required: Set<String>, allowed: Set<String>,
        allowGeometryEdits: Bool, undoCount: Int
    ) throws {
        let all = requestRecords(events)
        let responses = responseRecords(events)
        let edits = all.compactMap { request -> (Request, String)? in
            guard let action = parameterPayload(request.arguments)?["action"] as? String else { return nil }
            return (request, action)
        }
        guard edits.allSatisfy({ allowed.contains($0.1) }),
              edits.filter({ $0.1 == "undo" }).count == undoCount else {
            throw NativeCADLiveError.invalidDocument("Formula turn used an unexpected parameter mutation or undo count.")
        }
        for action in required {
            guard edits.contains(where: { request, name in
                guard name == action, let response = responses[request.callID],
                      response.status == "ok", let object = receipt(response),
                      object["ok"] as? Bool != false else { return false }
                return true
            }) else {
                throw NativeCADLiveError.invalidDocument("Missing successful native formula action: \(action).")
            }
        }
        if !allowGeometryEdits {
            let readActions: Set<String> = [
                "query", "read", "three_d_snapshot", "three_d_measure", "measure", "help", "capture",
            ]
            guard all.allSatisfy({ request in
                let action = request.arguments["action"] as? String ?? ""
                return readActions.contains(action) || ["parameters", "save"].contains(action)
            }) else {
                throw NativeCADLiveError.invalidDocument("A variable-only turn bypassed formula fan-out with another geometry mutation.")
            }
        }
        guard successfulSaveRevision(events) != nil else {
            throw NativeCADLiveError.invalidDocument("The model did not successfully save its formula turn.")
        }
    }

    static func assertTurnOneEvidence(_ events: [RunEventRecord]) throws {
        let all = requests(events)
        XCTAssertTrue(
            all.contains { ($0["action"] as? String) == "create" },
            "The first turn did not call cad.document create."
        )
        XCTAssertTrue(
            all.contains { ($0["op"] as? String) == "sketch.create" },
            "The first turn did not draft the plate sketch."
        )
        XCTAssertTrue(
            all.contains { ($0["op"] as? String) == "feature.extrude" },
            "The first turn did not draft the extrusion/hole geometry."
        )
    }

    struct Request {
        var callID: String
        var arguments: [String: Any]
        var sequence: Int
    }

    struct Response {
        var callID: String
        var status: String
        var summary: String
        var sequence: Int
    }

    static func assertTurnTwoEvidence(
        _ events: [RunEventRecord],
        capture: NativeCADLiveCapture,
        initial: NativeCADLiveDocumentState
    ) throws -> (correctionCallID: String, filletCallID: String) {
        try assertTurnTwoEvidence(
            events, capture: capture,
            initialCircle: XCTUnwrap(initial.circles.first))
    }

    static func assertTurnTwoEvidence(
        _ events: [RunEventRecord],
        capture: NativeCADLiveCapture,
        initialCircle: NativeCADLiveCircle
    ) throws -> (correctionCallID: String, filletCallID: String) {
        let all = requestRecords(events)
        let responses = responseRecords(events)
        let captureRequest = try XCTUnwrap(
            successfulCaptureRequest(events, resultSequence: capture.resultSequence),
            "The visual turn has no request paired with the verified successful capture result."
        )
        XCTAssertEqual(captureRequest.callID, capture.callID)

        let corrections = all.compactMap { request -> (Request, [String: Any])? in
            guard request.sequence > capture.resultSequence,
                  let payload = parameterPayload(request.arguments),
                  (payload["action"] as? String) == "updateSketchEntity" else { return nil }
            return (request, payload)
        }
        XCTAssertEqual(
            corrections.count,
            1,
            "The visual turn must make exactly one existing-hole correction command."
        )
        guard corrections.count == 1,
              let (correctionRequest, correctionPayload) = corrections.first else {
            throw NativeCADLiveError.runIncomplete(
                state: "missingCorrection",
                detail: "No updateSketchEntity command followed the captured image."
            )
        }
        let sketchID = (correctionPayload["sketch_id"] as? String)
            ?? (correctionPayload["sketchID"] as? String)
        let entityID = (correctionPayload["entity_id"] as? String)
            ?? (correctionPayload["entityID"] as? String)
        XCTAssertEqual(sketchID, initialCircle.sketchID, "The correction did not address the existing hole sketch.")
        XCTAssertEqual(entityID, initialCircle.entityID, "The correction did not address the existing hole entity.")
        let radius = NativeCADLiveJSON.number(correctionPayload["radius"])
        let diameter = NativeCADLiveJSON.number(correctionPayload["diameter"])
        let correctionToEight = radius.map { abs($0 - 4.0) < 1e-9 } == true
            || diameter.map { abs($0 - 8.0) < 1e-9 } == true
        XCTAssertTrue(correctionToEight, "The correction must set the same hole to Ø8 (radius 4 or diameter 8).")
        if let radius {
            XCTAssertEqual(radius, 4.0, accuracy: 1e-9)
            if let expected = NativeCADLiveJSON.number(correctionPayload["expected_radius"]) {
                XCTAssertEqual(expected, 3.0, accuracy: 1e-9)
            }
        } else if let diameter {
            XCTAssertEqual(diameter, 8.0, accuracy: 1e-9)
            if let expected = NativeCADLiveJSON.number(correctionPayload["expected_diameter"]) {
                XCTAssertEqual(expected, 6.0, accuracy: 1e-9)
            }
        }
        guard sketchID == initialCircle.sketchID,
              entityID == initialCircle.entityID,
              correctionToEight else {
            throw NativeCADLiveError.runIncomplete(
                state: "wrongCorrectionTarget",
                detail: "The correction did not target the same stable hole identity at Ø8."
            )
        }

        guard let correctionResponse = responses[correctionRequest.callID],
              correctionResponse.status == "ok",
              let correctionReceipt = receipt(correctionResponse),
              correctionReceipt["saved"] as? Bool == true,
              let correctionRevision = NativeCADLiveJSON.int(correctionReceipt["revision"]),
              correctionRevision > capture.revision else {
            throw NativeCADLiveError.runIncomplete(
                state: "uncommittedCorrection",
                detail: "The existing-hole correction was not saved as a newer revision."
            )
        }

        let filletProposals = all.filter {
            $0.sequence > capture.resultSequence && operationName($0.arguments) == "feature.fillet"
        }
        XCTAssertFalse(filletProposals.isEmpty, "The visual turn did not propose feature.fillet.")
        guard let firstFillet = filletProposals.first else {
            throw NativeCADLiveError.runIncomplete(
                state: "missingFilletProposal",
                detail: "No feature.fillet proposal followed the image."
            )
        }
        let applyRequests = all.filter {
            $0.sequence > firstFillet.sequence
                && ["apply", "three_d_apply"].contains($0.arguments["action"] as? String ?? "")
        }
        let appliedFillet = applyRequests.first { request in
            responses[request.callID]?.status == "ok"
        }
        XCTAssertNotNil(appliedFillet, "The fillet proposal was not applied successfully.")
        guard let appliedFillet,
              let applyResponse = responses[appliedFillet.callID],
              let applyReceipt = receipt(applyResponse),
              let applyRevision = receiptRevision(applyReceipt),
              applyRevision >= correctionRevision else {
            throw NativeCADLiveError.runIncomplete(
                state: "uncommittedFillet",
                detail: "The fillet apply did not commit a newer saved revision."
            )
        }

        let readActions: Set<String> = ["query", "read", "three_d_snapshot", "three_d_measure", "measure"]
        XCTAssertTrue(
            all.contains { request in
                request.sequence > appliedFillet.sequence
                    && readActions.contains(request.arguments["action"] as? String ?? "")
            },
            "The visual turn did not read the corrected parameters back."
        )
        let saveRevision = try XCTUnwrap(
            successfulSaveRevision(events, after: appliedFillet.sequence),
            "No successful save followed the corrected geometry."
        )
        XCTAssertGreaterThanOrEqual(saveRevision, applyRevision)

        let otherParameterActions = all.compactMap { request -> String? in
            guard let payload = parameterPayload(request.arguments),
                  let action = payload["action"] as? String else { return nil }
            return action
        }.filter { !["updateSketchEntity", "list"].contains($0) }
        XCTAssertTrue(
            otherParameterActions.isEmpty,
            "The visual turn used unexpected parameter edits: \(otherParameterActions)"
        )
        XCTAssertFalse(
            all.contains { ($0.arguments["action"] as? String) == "versions" },
            "The visual turn used a versions action instead of ordinary CAD edits."
        )
        XCTAssertFalse(
            all.contains { ($0.arguments["action"] as? String) == "create" },
            "The visual turn created a second document."
        )
        let proposedOps = all.compactMap { request -> String? in
            guard ["propose", "three_d_propose"].contains(request.arguments["action"] as? String ?? "")
            else { return nil }
            return operationName(request.arguments)
        }
        XCTAssertEqual(
            Set(proposedOps),
            Set(["feature.fillet"]),
            "The visual turn proposed an unexpected operation: \(proposedOps)"
        )
        let allowedActions: Set<String> = [
            "query", "read", "locate", "three_d_snapshot", "three_d_measure", "measure",
            "propose", "three_d_propose", "apply", "three_d_apply", "save", "capture",
            "parameters",
        ]
        let unexpectedActions = all.compactMap { request -> String? in
            let action = request.arguments["action"] as? String ?? ""
            return allowedActions.contains(action) ? nil : action
        }
        XCTAssertTrue(
            unexpectedActions.isEmpty,
            "The visual turn used unexpected CAD actions: \(unexpectedActions)"
        )
        return (correctionCallID: corrections[0].0.callID, filletCallID: firstFillet.callID)
    }

    /// A rejected request may precede a successful capture retry. Keep the
    /// receipt's exact sequence and call binding instead of taking the first
    /// attempted capture; the caller still checks the independently verified
    /// image's call id against the selected request.
    static func successfulCaptureRequest(
        _ events: [RunEventRecord], resultSequence: Int
    ) -> Request? {
        let responses = responseRecords(events)
        return requestRecords(events).first { request in
            guard request.arguments["action"] as? String == "capture",
                  let response = responses[request.callID] else { return false }
            return response.status == "ok"
                && response.sequence == resultSequence
                && request.sequence < response.sequence
        }
    }

    /// The undo turn must issue exactly two real `parameters` undo commands,
    /// each committed by the owning bridge, and nothing else that mutates.
    static func assertTurnThreeUndoEvidence(
        _ events: [RunEventRecord]
    ) throws -> (commandCount: Int, lastRevision: Int) {
        let all = requestRecords(events)
        let responses = responseRecords(events)
        let undos = all.filter { parameterPayload($0.arguments)?["action"] as? String == "undo" }
        XCTAssertEqual(undos.count, 2, "The undo turn must issue exactly two native undo commands.")
        guard undos.count == 2 else {
            throw NativeCADLiveError.runIncomplete(
                state: "wrongUndoCount",
                detail: "Expected exactly two parameters undo commands; found \(undos.count)."
            )
        }
        var revisions: [Int] = []
        for undo in undos {
            guard let response = responses[undo.callID], response.status == "ok",
                  let object = receipt(response),
                  (object["action"] as? String) == "undo",
                  (object["mutated"] as? Bool) == true,
                  (object["saved"] as? Bool) == true,
                  let revision = NativeCADLiveJSON.int(object["revision"]) else {
                throw NativeCADLiveError.runIncomplete(
                    state: "uncommittedUndo",
                    detail: "One native undo did not report a saved, mutated command."
                )
            }
            XCTAssertEqual(object["can_redo"] as? Bool, true)
            revisions.append(revision)
        }
        XCTAssertGreaterThan(revisions[1], revisions[0], "The second undo must commit a newer revision.")

        XCTAssertFalse(
            all.contains { ($0.arguments["action"] as? String) == "versions" },
            "The undo turn used versions restore instead of the native undo command."
        )
        XCTAssertFalse(
            all.contains { parameterPayload($0.arguments)?["action"] as? String == "redo" },
            "The undo turn ran redo."
        )
        let readActions: Set<String> = ["query", "read", "three_d_snapshot", "three_d_measure", "measure"]
        for request in all {
            let action = request.arguments["action"] as? String ?? ""
            if let parameterAction = parameterPayload(request.arguments)?["action"] as? String {
                if parameterAction == "list" { continue }
                XCTAssertEqual(parameterAction, "undo", "Unexpected parameter edit in the undo turn.")
                continue
            }
            if ["save", "capture"].contains(action) || readActions.contains(action) { continue }
            XCTFail("The undo turn performed an unexpected mutating action: \(action)")
        }
        XCTAssertTrue(
            all.contains { request in
                readActions.contains(request.arguments["action"] as? String ?? "")
                    && request.sequence > undos[0].sequence
            },
            "The undo turn did not read the restored state back."
        )
        XCTAssertNotNil(
            successfulSaveRevision(events),
            "No successful save receipt was persisted in the undo turn."
        )
        return (undos.count, revisions.last ?? -1)
    }

    /// The post-reopen turn must make exactly one further existing-hole edit,
    /// read it back, save and capture the final revision.
    static func assertTurnFourEvidence(
        _ events: [RunEventRecord],
        initial: NativeCADLiveDocumentState,
        reopenedRevision: Int,
        finalState: NativeCADLiveDocumentState
    ) throws {
        let all = requestRecords(events)
        let responses = responseRecords(events)
        let initialCircle = try XCTUnwrap(initial.circles.first)
        let edits = all.compactMap { request -> (Request, [String: Any])? in
            guard let payload = parameterPayload(request.arguments),
                  (payload["action"] as? String) == "updateSketchEntity" else { return nil }
            return (request, payload)
        }
        XCTAssertEqual(edits.count, 1, "The post-reopen turn must make exactly one further hole edit.")
        guard edits.count == 1, let (editRequest, payload) = edits.first else {
            throw NativeCADLiveError.runIncomplete(
                state: "missingFurtherEdit",
                detail: "No further existing-hole edit followed the disk reopen."
            )
        }
        let sketchID = (payload["sketch_id"] as? String) ?? (payload["sketchID"] as? String)
        let entityID = (payload["entity_id"] as? String) ?? (payload["entityID"] as? String)
        XCTAssertEqual(sketchID, initialCircle.sketchID)
        XCTAssertEqual(entityID, initialCircle.entityID)
        let radius = NativeCADLiveJSON.number(payload["radius"])
        let diameter = NativeCADLiveJSON.number(payload["diameter"])
        let movesToTen = radius.map { abs($0 - 5.0) < 1e-9 } == true
            || diameter.map { abs($0 - 10.0) < 1e-9 } == true
        XCTAssertTrue(movesToTen, "The post-reopen edit must set the same hole to Ø10.")
        if let radius {
            XCTAssertEqual(radius, 5.0, accuracy: 1e-9)
            if let expected = NativeCADLiveJSON.number(payload["expected_radius"]) {
                XCTAssertEqual(expected, 3.0, accuracy: 1e-9)
            }
        } else if let diameter {
            XCTAssertEqual(diameter, 10.0, accuracy: 1e-9)
            if let expected = NativeCADLiveJSON.number(payload["expected_diameter"]) {
                XCTAssertEqual(expected, 6.0, accuracy: 1e-9)
            }
        }
        guard sketchID == initialCircle.sketchID, entityID == initialCircle.entityID, movesToTen else {
            throw NativeCADLiveError.runIncomplete(
                state: "wrongFurtherEdit",
                detail: "The post-reopen edit did not target the same stable hole identity at Ø10."
            )
        }
        guard let response = responses[editRequest.callID],
              response.status == "ok",
              let object = receipt(response),
              object["saved"] as? Bool == true,
              let editRevision = NativeCADLiveJSON.int(object["revision"]),
              editRevision > reopenedRevision else {
            throw NativeCADLiveError.runIncomplete(
                state: "uncommittedFurtherEdit",
                detail: "The post-reopen edit was not committed as a newer revision."
            )
        }
        XCTAssertGreaterThanOrEqual(finalState.revision, editRevision)

        let readActions: Set<String> = ["query", "read", "three_d_snapshot", "three_d_measure", "measure"]
        XCTAssertTrue(
            all.contains { request in
                request.sequence > editRequest.sequence
                    && readActions.contains(request.arguments["action"] as? String ?? "")
            },
            "The post-reopen turn did not read the further edit back."
        )
        let saveRevision = try XCTUnwrap(
            successfulSaveRevision(events, after: editRequest.sequence),
            "No successful save followed the post-reopen edit."
        )
        XCTAssertGreaterThanOrEqual(saveRevision, editRevision)
        let captureRequests = all.filter { request in
            (request.arguments["action"] as? String) == "capture"
                && request.sequence > editRequest.sequence
        }
        XCTAssertFalse(
            captureRequests.isEmpty,
            "The post-reopen turn did not capture after the further edit."
        )
        guard let lastCapture = captureRequests.last else {
            throw NativeCADLiveError.runIncomplete(
                state: "missingFinalCapture",
                detail: "No capture followed the post-reopen edit."
            )
        }
        XCTAssertFalse(
            all.contains { request in
                (request.arguments["action"] as? String) == "save"
                    && request.sequence > lastCapture.sequence
            },
            "The post-reopen turn saved after the final capture; the image would not bind the final package."
        )
        XCTAssertFalse(
            all.contains { request in
                let action = request.arguments["action"] as? String ?? ""
                let mutating = ["parameters", "apply", "three_d_apply",
                                "propose", "versions", "create"].contains(action)
                return mutating && request.sequence > lastCapture.sequence
            },
            "The post-reopen turn mutated the document after the final capture."
        )
        XCTAssertFalse(
            all.contains { request in
                ["undo", "redo"].contains(parameterPayload(request.arguments)?["action"] as? String ?? "")
            },
            "The post-reopen turn undid or redid an edit."
        )
        XCTAssertFalse(
            all.contains { ($0.arguments["action"] as? String) == "versions" },
            "The post-reopen turn used versions instead of an ordinary edit."
        )
        let parameterActions = all.compactMap { request -> String? in
            parameterPayload(request.arguments)?["action"] as? String
        }
        XCTAssertTrue(
            parameterActions.allSatisfy { ["updateSketchEntity", "list"].contains($0) },
            "The post-reopen turn used unexpected parameter edits: \(parameterActions)"
        )
        let otherMutations = all.filter { request in
            let action = request.arguments["action"] as? String ?? ""
            return !readActions.contains(action)
                && !["save", "capture", "parameters"].contains(action)
        }
        XCTAssertTrue(
            otherMutations.isEmpty,
            "The post-reopen turn used unexpected mutating actions."
        )
    }

    private static func requestRecords(_ events: [RunEventRecord]) -> [Request] {
        events.compactMap { event in
            guard event.kind == .toolRequest,
                  let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  (payload["tool"] as? String) == CadDocumentTool.name,
                  let callID = payload["id"] as? String,
                  let input = payload["input"] as? String,
                  let arguments = NativeCADLiveJSON.object(input) else { return nil }
            return Request(callID: callID, arguments: arguments, sequence: event.sequence)
        }
    }

    private static func responseRecords(_ events: [RunEventRecord]) -> [String: Response] {
        var result: [String: Response] = [:]
        for event in events where event.kind == .toolResult {
            guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  (payload["tool"] as? String) == CadDocumentTool.name,
                  let callID = payload["id"] as? String,
                  let status = payload["status"] as? String else { continue }
            result[callID] = Response(
                callID: callID,
                status: status,
                summary: payload["summary"] as? String ?? "",
                sequence: event.sequence
            )
        }
        return result
    }

    private static func parameterPayload(_ arguments: [String: Any]) -> [String: Any]? {
        guard (arguments["action"] as? String) == "parameters",
              let payloadString = arguments["payload"] as? String,
              let payload = NativeCADLiveJSON.object(payloadString) else { return nil }
        return payload
    }

    private static func operationName(_ arguments: [String: Any]) -> String? {
        if let op = arguments["op"] as? String { return op }
        return parameterPayload(arguments)?["op"] as? String
    }

    private static func receipt(_ response: Response) -> [String: Any]? {
        NativeCADLiveJSON.objects(in: response.summary).last
    }

    /// Native automatic apply wraps its committed receipt: the outer object
    /// carries `ok`/`replay` and `receipt` carries the actual revision. The
    /// ordinary parameter/save/undo replies carry the revision directly.
    private static func receiptRevision(_ object: [String: Any]) -> Int? {
        if let revision = NativeCADLiveJSON.int(object["revision"]) { return revision }
        if let nested = object["receipt"] as? [String: Any] {
            return NativeCADLiveJSON.int(nested["revision"])
        }
        return nil
    }

    private static func successfulSaveRevision(
        _ events: [RunEventRecord],
        after sequence: Int? = nil
    ) -> Int? {
        let all = requestRecords(events)
        let responses = responseRecords(events)
        let saves = all.filter { request in
            guard (request.arguments["action"] as? String) == "save" else { return false }
            if let sequence, request.sequence <= sequence { return false }
            return true
        }
        for save in saves.sorted(by: { $0.sequence > $1.sequence }) {
            guard let response = responses[save.callID], response.status == "ok",
                  let object = receipt(response),
                  (object["ok"] as? Bool) != false,
                  let revision = NativeCADLiveJSON.int(object["revision"]) else { continue }
            return revision
        }
        return nil
    }

    private static func requests(_ events: [RunEventRecord]) -> [[String: Any]] {
        events.compactMap { event in
            guard event.kind == .toolRequest,
                  let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  (payload["tool"] as? String) == CadDocumentTool.name,
                  let input = payload["input"] as? String else { return nil }
            return NativeCADLiveJSON.object(input)
        }
    }
}

// MARK: - JSON / path / pixel helpers

private enum NativeCADLiveJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func object(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return object(data)
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? NSNumber, value.doubleValue.isFinite { return value.doubleValue }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double, value.isFinite { return Int(value) }
        return nil
    }

    /// Balanced JSON objects embedded in a model/tool text projection. The
    /// runtime may prepend a provenance envelope, so callers search the
    /// objects rather than assuming the first one is the tool reply.
    static func objects(in text: String) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var searchStart = text.startIndex
        while let start = text[searchStart...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var index = start
            var end: String.Index?
            while index < text.endIndex {
                let character = text[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else {
                    if character == "\"" {
                        inString = true
                    } else if character == "{" {
                        depth += 1
                    } else if character == "}" {
                        depth -= 1
                        if depth == 0 {
                            end = index
                            break
                        }
                    }
                }
                index = text.index(after: index)
            }
            guard let end else { break }
            if let object = object(String(text[start...end])) {
                result.append(object)
            }
            searchStart = text.index(after: end)
        }
        return result
    }
}

private enum NativeCADLivePaths {
    static func applicationSupport() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }

    static func workspaceRoot(
        for workspace: WorkspaceRecord,
        conversationID: UUID
    ) throws -> URL {
        let relative = workspace.internalRelativePath ?? "PrivateTasks/\(conversationID.uuidString)"
        return try applicationSupport()
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
    }

    static func captureArtifactURL(relativePath: String) throws -> URL {
        guard relativePath.hasPrefix("CADViewportArtifacts/"),
              !relativePath.split(separator: "/").contains(where: { String($0) == ".." }) else {
            throw NativeCADLiveError.invalidCapture("The artifact path is outside the App-owned CAD capture root.")
        }
        return try applicationSupport()
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
    }

    static func captureArtifactDirectory(runID: UUID) -> URL? {
        guard let support = try? applicationSupport() else { return nil }
        return support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("CADViewportArtifacts", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    static func skillRunSnapshotDirectory(runID: UUID) -> URL? {
        guard let support = try? applicationSupport() else { return nil }
        return support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
            .appendingPathComponent(".run-snapshots", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    static func removeOwnedDirectory(_ url: URL?) {
        guard let url else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func removeOwnedFile(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private enum NativeCADLivePixels {
    struct Stats {
        var width: Int
        var height: Int
        var uniqueColorBuckets: Int
        var nonBackgroundFraction: Double
    }

    static func stats(_ png: Data) throws -> Stats {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NativeCADLiveError.invalidCapture("The artifact is not a decodable image.")
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height <= 16_000_000 else {
            throw NativeCADLiveError.invalidCapture("The capture image dimensions are invalid.")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else {
            throw NativeCADLiveError.invalidCapture("The capture image could not be rasterized.")
        }

        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            let offset = (y * width + x) * 4
            let r = UInt32(pixels[offset])
            let g = UInt32(pixels[offset + 1])
            let b = UInt32(pixels[offset + 2])
            return (r << 16) | (g << 8) | b
        }

        let background = pixel(0, 0)
        var buckets = Set<UInt32>()
        var samples = 0
        var nonBackground = 0
        let stepX = max(1, width / 128)
        let stepY = max(1, height / 96)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let color = pixel(x, y)
                let quantized = (((color >> 19) & 0x1F) << 10) | (((color >> 11) & 0x1F) << 5) | ((color >> 3) & 0x1F)
                buckets.insert(quantized)
                if color != background { nonBackground += 1 }
                samples += 1
                x += stepX
            }
            y += stepY
        }
        guard samples > 0 else {
            throw NativeCADLiveError.invalidCapture("The capture image produced no pixel samples.")
        }
        return Stats(
            width: width,
            height: height,
            uniqueColorBuckets: buckets.count,
            nonBackgroundFraction: Double(nonBackground) / Double(samples)
        )
    }
}

// MARK: - Real App context-compaction acceptance (test-only, no production path)

/// Four ACTUAL ordinary user messages go through the normal
/// `RunLaunchStore` + `ConversationRunService` path with the exact 65,536- or
/// 131,072-token window already written by the private owned-route metadata. Three
/// bounded synthetic data messages make the App's own `HybridContextEngine`
/// compact naturally; the final follow-up must recall the early exact facts
/// from the durable continuation record and then use a real workspace read.
/// The read is small enough to arrive complete; a separate `tools.readResult`
/// call verifies the exact indexed capture. This test does not claim that
/// truncation/compaction was necessary for that tool output.
@MainActor
final class NativeCADContextCompactionLiveTests: XCTestCase {

    func testRealModelCompactsAt64KContextAndRetainsEarlyFactsThenReadsExactCapture() async throws {
        try await runCompactionAcceptance(expectedContextTokens: 65_536)
    }

    func testRealModelCompactsAt128KContextAndRetainsEarlyFactsThenReadsExactCapture() async throws {
        try await runCompactionAcceptance(expectedContextTokens: 131_072)
    }

    private func runCompactionAcceptance(expectedContextTokens: Int) async throws {
        let optIn = try NativeCADLiveOptIn.load()
        executionTimeAllowance = optIn.executionTimeAllowance
        continueAfterFailure = true

        let environment = try await appQualificationEnvironment()
        let center = environment.conversationCenter
        let installed = try await NativeCADLiveOwnedRoute.installIfRequested(environment: environment)
        do {
            let route = try await NativeCADLiveRoute.select(optIn: optIn, center: center)
            guard optIn.prepaidBudgetBasis,
                  NativeCADLivePrepaidRoute.matches(provider: route.provider, model: route.model) else {
                throw XCTSkip(
                    "Context-compaction acceptance skipped: it requires the reviewed exact "
                        + "prepaid Agent Plan route and both explicit zero increments; no "
                        + "paid fallback is used here. A skip is not live evidence."
                )
            }
            guard route.model.limits.contextTokens == expectedContextTokens else {
                XCTFail(
                    "The owned route must configure the actual model context at exactly "
                        + "\(expectedContextTokens) tokens for this acceptance; found "
                        + "\(route.model.limits.contextTokens)."
                )
                throw NativeCADLiveError.invalidContextWindow(route.model.limits.contextTokens)
            }
            let session = NativeCADContextCompactionSession(
                environment: environment, center: center, route: route, optIn: optIn)
            do {
                try await session.run()
            } catch {
                session.recordFailure(error)
                await session.cleanup()
                throw error
            }
            await session.cleanup()
        } catch {
            try await installed?.remove(environment: environment)
            throw error
        }
        try await installed?.remove(environment: environment)
    }
}

private struct NativeCADLiveCompactionRow: Sendable {
    var id: UUID
    var sourceMessageIDs: [UUID]
    var summary: String
    var beforeTokens: Int
    var afterTokens: Int
}

private struct NativeCADLiveToolCall {
    var callID: String
    var tool: String
    var arguments: [String: Any]
    var requestSequence: Int
}

private struct NativeCADLiveToolResult {
    var callID: String
    var tool: String
    var status: String
    var summary: String
    var sequence: Int
}

@MainActor
private final class NativeCADContextCompactionSession {
    private let environment: AppEnvironment
    private let center: ConversationCenter
    private let route: NativeCADLiveRoute
    private let optIn: NativeCADLiveOptIn
    private let ledger: NativeCADLiveLedger

    private let conversationID = UUID()
    private let title: String
    private let fileRelativePath: String
    private let searchToken: String
    private let hiddenToken: String
    private let expectedPage: String
    private let alphaFact: String
    private let alphaInstruction: String
    private let betaFact: String
    private let latestCode: String
    /// Exact bytes written to the owned fixture. The retained capture is the
    /// workspace.readFile envelope line plus these bytes.
    private let fixtureByteCount = 12_288

    private var workspace: WorkspaceRecord?
    private var workspaceRootURL: URL?
    private var runIDs: [UUID] = []
    private var userMessageIDs: [UUID] = []
    private var userGoals: [String] = []
    private var services: [ConversationRunService] = []
    private var cleanupStarted = false
    private var conversationCreated = false
    private var bridgeFinalMessageID: UUID?
    private var failureDescription: String?

    init(
        environment: AppEnvironment,
        center: ConversationCenter,
        route: NativeCADLiveRoute,
        optIn: NativeCADLiveOptIn
    ) {
        let token = UUID().uuidString.lowercased()
        // Each retention marker carries its own opaque UUID. A shared suffix
        // would let a later summary "retain" alpha by reconstructing it from
        // beta or instruction text instead of preserving the original value.
        let alphaToken = UUID().uuidString.lowercased()
        let instructionToken = UUID().uuidString.lowercased()
        let betaToken = UUID().uuidString.lowercased()
        self.environment = environment
        self.center = center
        self.route = route
        self.optIn = optIn
        self.ledger = NativeCADLiveLedger(
            pricing: route.pricing,
            maxCost: optIn.maxCost,
            maxInputTokens: optIn.maxInputTokens,
            maxOutputTokens: optIn.maxOutputTokens,
            maxTotalTokens: optIn.maxTotalTokens
        )
        let search = "COMPACTION-SEARCH-\(token)"
        let hidden = "PAGED-HIDDEN-\(token.uppercased())"
        var block = "\(search)|\(hidden)|"
        if block.utf8.count < 160 {
            block += String(repeating: "X", count: 160 - block.utf8.count)
        }
        self.title = "Context compaction live acceptance \(String(token.prefix(6)))"
        self.fileRelativePath = "compaction-acceptance-\(String(token.prefix(8))).txt"
        self.searchToken = search
        self.hiddenToken = hidden
        self.expectedPage = String(block.prefix(160))
        self.alphaFact = "EARLY-FACT-ALPHA-\(alphaToken)"
        self.alphaInstruction = "EARLY-INSTRUCTION-\(instructionToken)"
        self.betaFact = "EARLY-FACT-BETA-\(betaToken)"
        self.latestCode = "LATEST-GOAL-\(token)"
    }

    func run() async throws {
        try await createOwnedConversation()
        try await createFixtureFile()

        // The first two user messages are actual durable user rows. Their
        // synthetic blocks are bounded test data, not a substitute history.
        let first = try await turn(goal: firstTurnGoal(), allowedTools: [], label: "turn1")
        try await assertAcknowledged(
            runID: first.runID,
            events: first.events,
            required: ["ACK-ALPHA"],
            label: "turn1"
        )

        let second = try await turn(goal: secondTurnGoal(), allowedTools: [], label: "turn2")
        let secondCompactions = try await compactionRows(runID: second.runID)
        XCTAssertFalse(
            secondCompactions.isEmpty,
            "The second actual user message did not trigger the App's natural context compaction at the configured \(route.model.limits.contextTokens)-token window."
        )
        if let row = secondCompactions.first {
            XCTAssertTrue(
                row.sourceMessageIDs.contains(userMessageIDs[0]),
                "The first actual user message was not a durable compaction source."
            )
            XCTAssertFalse(
                row.sourceMessageIDs.contains(userMessageIDs[1]),
                "The latest actual user message must stay protected, not be compacted."
            )
            XCTAssertGreaterThan(row.beforeTokens, row.afterTokens)
        }
        assertIntermediateRetention(secondCompactions, label: "turn2")
        try await assertAcknowledged(
            runID: second.runID,
            events: second.events,
            required: [alphaFact, betaFact],
            label: "turn2"
        )

        // A fourth actual user message keeps the recent protected tail free
        // of the exact early facts. The next compaction must therefore carry
        // them in the durable continuation record, not in a retained reply.
        let bridge = try await turn(goal: bridgeGoal(), allowedTools: [], label: "bridge")
        let bridgeCompactions = try await compactionRows(runID: bridge.runID)
        XCTAssertFalse(
            bridgeCompactions.isEmpty,
            "The bridge turn did not perform App-orchestrated compaction before its real provider request."
        )
        assertIntermediateRetention(bridgeCompactions, label: "bridge")
        try await assertAcknowledged(
            runID: bridge.runID,
            events: bridge.events,
            required: ["ACK-BRIDGE"],
            label: "bridge"
        )
        bridgeFinalMessageID = finalMessageID(events: bridge.events)
        XCTAssertNotNil(bridgeFinalMessageID, "The bridge turn has no durable final assistant message ID.")
        let bridgeText = try await finalAssistantText(runID: bridge.runID, events: bridge.events)
        XCTAssertFalse(
            bridgeText.contains(alphaFact)
                || bridgeText.contains(betaFact)
                || bridgeText.contains(alphaInstruction),
            "The bridge answer repeated early facts; the recent-tail retention proof would be ambiguous."
        )

        let third = try await turn(
            goal: followUpGoal(),
            allowedTools: ["workspace.readFile"],
            label: "turn3"
        )
        let thirdCompactions = try await compactionRows(runID: third.runID)
        XCTAssertFalse(
            thirdCompactions.isEmpty,
            "The follow-up run did not perform App-orchestrated compaction before its real provider request."
        )
        if let row = thirdCompactions.first {
            XCTAssertTrue(row.sourceMessageIDs.contains(userMessageIDs[0]))
            XCTAssertTrue(row.sourceMessageIDs.contains(userMessageIDs[1]))
            XCTAssertFalse(row.sourceMessageIDs.contains(userMessageIDs[3]))
            if let bridgeFinalMessageID = bridgeFinalMessageID {
                XCTAssertFalse(
                    row.sourceMessageIDs.contains(bridgeFinalMessageID),
                    "The recent bridge answer was compacted instead of retained as recent context."
                )
            }
            XCTAssertGreaterThan(row.beforeTokens, row.afterTokens)
        }
        assertIntermediateRetention(thirdCompactions, label: "turn3")

        try await assertToolPaging(runID: third.runID, events: third.events)
        try await assertHistoryRowsPreserved()
        try await assertFinalReply(runID: third.runID, events: third.events)
        try await assertCheckpointEvidence(runID: third.runID, rows: thirdCompactions)

        let totals = await ledger.totals()
        XCTAssertTrue(totals.hasUsage, "The real runs produced no durable token usage.")
        XCTAssertFalse(totals.exceeds, "The actual run usage exceeded the opt-in ceiling: \(totals.description)")
    }

    // MARK: Actual ordinary turns

    private func createOwnedConversation() async throws {
        let now = Date()
        try await environment.conversationStore.saveConversation(ConversationRecord(
            id: conversationID,
            title: title,
            createdAt: now,
            updatedAt: now
        ))
        conversationCreated = true
        let workspace = try await SQLiteWorkspaceStore(database: environment.database)
            .ensureWorkspace(conversationID: conversationID, title: title)
        let root = try NativeCADLivePaths.workspaceRoot(
            for: workspace,
            conversationID: conversationID
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.workspace = workspace
        self.workspaceRootURL = root
    }

    private func createFixtureFile() async throws {
        let root = try XCTUnwrap(workspaceRootURL, "The owned task workspace root was not resolved.")
        var bytes: [UInt8] = []
        let padding = Array("synthetic context-compaction file padding line; inert test data\n".utf8)
        while bytes.count < fixtureByteCount {
            bytes.append(contentsOf: padding)
        }
        bytes.removeLast(bytes.count - fixtureByteCount)
        let pageBytes = Array(expectedPage.utf8)
        guard pageBytes.count == 160 else {
            throw NativeCADLiveError.invalidContextWindow(0)
        }
        bytes.replaceSubrange(4_000..<4_160, with: pageBytes)
        try Data(bytes).write(to: root.appendingPathComponent(fileRelativePath), options: .atomic)
    }

    private func turn(
        goal: String,
        allowedTools: Set<String>,
        label: String
    ) async throws -> (runID: UUID, events: [RunEventRecord]) {
        guard let workspace else {
            throw NativeCADLiveError.runIncomplete(
                state: "noWorkspace",
                detail: "The owned workspace was not created before \(label)."
            )
        }
        try await setAllowedTools(allowedTools)
        let runID = UUID()
        let prepared = try await environment.runLaunchStore.prepare(RunLaunchRequest(
            conversationID: conversationID,
            runID: runID,
            goal: goal,
            workspaceID: workspace.id,
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(approvalMode: .automatic),
            providerID: route.provider.id,
            modelID: route.model.id,
            providerName: route.provider.displayName ?? route.provider.kind.rawValue,
            modelName: route.model.displayName
        ))
        let history = try await ConversationHistoryAssembler(store: environment.conversationStore)
            .build(conversationID: conversationID)
            .filter { $0.id != prepared.userMessage.id }
        let service = try await center.runService(
            for: conversationID,
            provider: route.provider,
            model: route.model,
            runID: runID,
            executionMode: .agent,
            runSurface: .ordinary,
            workspaceID: prepared.workspace.id,
            memoryQuery: "",
            conversationHistory: history,
            automaticReasoningEffortIngress: .continuation
        )
        services.append(service)
        runIDs.append(runID)
        userMessageIDs.append(prepared.userMessage.id)
        userGoals.append(goal)
        try await execute(service: service, runID: runID, goal: goal)
        let events = try await environment.runStore.events(runID: runID)
        return (runID, events)
    }

    private func setAllowedTools(_ names: Set<String>) async throws {
        try await SQLiteWorkspaceStore(database: environment.database).saveTaskPolicy(TaskPolicy(
            conversationID: conversationID,
            approvalMode: TaskApprovalMode.automatic.rawValue,
            allowedToolNames: names,
            filePaths: [],
            networkAllowed: false,
            browserControlAllowed: false,
            uploadAllowed: false,
            credentialsAllowed: false,
            remoteExecutionAllowed: false,
            recoveryPolicy: .safePoint,
            notificationPolicy: .stages
        ))
    }

    private func execute(service: ConversationRunService, runID: UUID, goal: String) async throws {
        let runStore = environment.runStore
        let ledger = self.ledger
        let stop = NativeCADLiveStopSignal()
        let timeoutMilliseconds = Int64(optIn.perRunTimeoutSeconds * 1000)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await service.startPrepared(goal: goal)
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                    await stop.set(.timedOut(runID))
                    await service.cancel()
                    throw NativeCADLiveError.timedOut(runID)
                }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(2_000))
                        let records = (try? await runStore.usage(runID: runID)) ?? []
                        let totals = await ledger.update(runID: runID, records: records)
                        if totals.exceeds {
                            let message = totals.description
                            await stop.set(.budgetExceeded(message))
                            await service.cancel()
                            throw NativeCADLiveError.budgetExceeded(message)
                        }
                    }
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }

            try await stop.throwIfStopped()

            var snapshot = await service.snapshot()
            for _ in 0..<50 where !snapshot.isTerminal {
                try? await Task.sleep(for: .milliseconds(100))
                snapshot = await service.snapshot()
            }
            guard snapshot.isTerminal else {
                await service.cancel()
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "The run never reached a terminal state."
                )
            }
            guard snapshot.stateName == "completed" else {
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "The run did not complete; acceptance never retries a failed model turn."
                )
            }
            guard snapshot.pendingApproval == nil else {
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "A call remained awaiting interactive approval; the owned policy is automatic."
                )
            }

            let records = (try? await runStore.usage(runID: runID)) ?? []
            let totals = await ledger.update(runID: runID, records: records)
            guard totals.hasUsage else { throw NativeCADLiveError.missingUsage }
            guard !totals.exceeds else {
                throw NativeCADLiveError.budgetExceeded(totals.description)
            }
        } catch {
            await service.cancel()
            throw error
        }
    }

    // MARK: Assertions

    private func assertAcknowledged(
        runID: UUID,
        events: [RunEventRecord],
        required: [String],
        label: String
    ) async throws {
        let realToolCalls = events.filter { event in
            guard event.kind == .toolRequest,
                  let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  let tool = payload["tool"] as? String else { return false }
            return tool == "workspace.readFile" || tool == "tools.readResult"
        }
        XCTAssertTrue(
            realToolCalls.isEmpty,
            "\(label) unexpectedly entered the tool phase; the first two turns are actual data-delivery messages only."
        )
        let text = try await finalAssistantText(runID: runID, events: events)
        for value in required {
            XCTAssertTrue(
                text.contains(value),
                "\(label) final answer did not retain \(value). Prefix: \(String(text.prefix(500)))"
            )
        }
    }

    /// Every compaction that consumed an early source message must carry the
    /// exact values from that source, not just the final compaction. This is
    /// applied to all rows, including intermediate/degraded records, on turn
    /// 2, the bridge turn and the follow-up turn.
    private func assertIntermediateRetention(
        _ rows: [NativeCADLiveCompactionRow],
        label: String
    ) {
        for (index, row) in rows.enumerated() {
            if row.sourceMessageIDs.contains(userMessageIDs[0]) {
                XCTAssertTrue(
                    row.summary.contains(alphaFact),
                    "\(label) compaction \(index) lost the early alpha fact."
                )
                XCTAssertTrue(
                    row.summary.contains(alphaInstruction),
                    "\(label) compaction \(index) lost the early instruction token."
                )
            }
            if row.sourceMessageIDs.contains(userMessageIDs[1]) {
                XCTAssertTrue(
                    row.summary.contains(betaFact),
                    "\(label) compaction \(index) lost the early beta fact."
                )
            }
        }
    }

    private func assertToolPaging(runID: UUID, events: [RunEventRecord]) async throws {
        let (requests, results) = toolEvents(events)
        let reads = requests.values.filter { call in
            call.tool == "workspace.readFile"
                && (call.arguments["path"] as? String) == fileRelativePath
        }
        guard let firstRead = reads.first(where: {
            (NativeCADLiveJSON.int($0.arguments["offset"]) ?? 0) == 0
        }) else {
            XCTFail("The follow-up did not issue the actual workspace read at offset 0.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingToolRead",
                detail: "One workspace.readFile call was required."
            )
        }
        guard let firstResult = results[firstRead.callID],
              firstResult.status == "ok" else {
            XCTFail("The required workspace read did not return a successful tool result.")
            throw NativeCADLiveError.runIncomplete(
                state: "failedToolRead",
                detail: "The workspace read must succeed."
            )
        }
        // The file is 12 KiB and the configured window retains it complete.
        // A complete read is PASS; this assertion does not claim that the
        // runtime had to truncate it.
        XCTAssertTrue(
            firstResult.summary.contains("truncated=false"),
            "The 12 KiB read was unexpectedly truncated; a complete read is required when the window permits it."
        )
        // The run-event summary is a bounded UI excerpt (4 KiB), not the
        // retained capture. The exact page bytes are asserted below from the
        // tools.readResult capture instead of weakening the read to fit the
        // excerpt.
        let firstLine = firstResult.summary.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? ""
        let expectedCaptureBytes = firstLine.utf8.count + 1 + fixtureByteCount

        let queryCalls = requests.values.filter { call in
            call.tool == "tools.readResult"
                && (call.arguments["query"] as? String) == searchToken
        }
        // A model can issue a lookup in the same batch as the read, observe
        // an empty index, and correctly retry after the capture is committed.
        // Dictionary iteration must not make that recovered sequence fail at
        // random. Require a later successful match for THIS read, then bind
        // the page to its exact ref and result sequence.
        var captureMatch: (result: NativeCADLiveToolResult, offset: Int, ref: String)?
        for call in queryCalls.sorted(by: { $0.requestSequence < $1.requestSequence }) {
            guard let result = results[call.callID], result.status == "ok",
                  result.sequence > firstResult.sequence else { continue }
            for line in result.summary.split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                func field(_ name: String) -> String? {
                    let prefix = name + "="
                    return fields.first(where: { $0.hasPrefix(prefix) })
                        .map { String($0.dropFirst(prefix.count)) }
                }
                guard field("callID") == firstRead.callID,
                      field("tool") == "workspace.readFile",
                      let rawOffset = field("matchOffset"), let offset = Int(rawOffset),
                      let ref = field("ref"), !ref.isEmpty else { continue }
                captureMatch = (result, offset, ref)
                break
            }
            if captureMatch != nil { break }
        }
        guard let captureMatch else {
            XCTFail("The follow-up did not search the retained capture for the exact unique token.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingPagingQuery",
                detail: "tools.readResult query did not return a match offset."
            )
        }

        let pageCalls = requests.values.filter { call in
            call.tool == "tools.readResult"
                && NativeCADLiveJSON.int(call.arguments["offset"]) == captureMatch.offset
                && (call.arguments["ref"] as? String) == captureMatch.ref
        }.sorted(by: { $0.requestSequence < $1.requestSequence })
        guard let pageCall = pageCalls.first(where: { results[$0.callID]?.status == "ok" }),
              let pageResult = results[pageCall.callID] else {
            XCTFail("The follow-up did not read the exact retained page after compaction.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingPagingRead",
                detail: "tools.readResult page did not succeed."
            )
        }
        XCTAssertGreaterThan(
            pageCall.requestSequence,
            captureMatch.result.sequence,
            "The retained-capture page was not requested after the matching capture search."
        )
        XCTAssertTrue(
            pageResult.summary.contains("callID=\(firstRead.callID)"),
            "The retained capture page did not identify the real workspace read."
        )
        XCTAssertTrue(
            pageResult.summary.contains("capture=complete"),
            "The retained capture was not reported complete."
        )
        XCTAssertTrue(
            pageResult.summary.contains("totalBytes=\(expectedCaptureBytes)"),
            "The retained capture did not preserve the exact full read bytes; "
                + "the run-event summary is only a bounded UI excerpt."
        )
        XCTAssertTrue(
            pageResult.summary.contains("returnedBytes=160"),
            "The paged result did not return the exact 160-byte page."
        )
        XCTAssertTrue(
            pageResult.summary.contains(expectedPage),
            "The paged result did not contain the exact retained 160-byte block; the capture was not byte-complete."
        )
        XCTAssertTrue(
            pageResult.summary.contains(hiddenToken),
            "The paged result omitted the unique token from the middle of the read."
        )
        XCTAssertFalse(events.contains { $0.kind == .approval })
    }

    private func assertHistoryRowsPreserved() async throws {
        let persisted = try await environment.conversationStore.messages(conversationID: conversationID)
        XCTAssertGreaterThanOrEqual(persisted.count, userMessageIDs.count + 2)
        for (index, messageID) in userMessageIDs.enumerated() {
            guard let row = persisted.first(where: { $0.id == messageID }) else {
                XCTFail("Actual user message \(index) disappeared after compaction.")
                continue
            }
            XCTAssertEqual(row.role, "user")
            XCTAssertTrue(
                row.content == userGoals[index],
                "Actual user message \(index) did not preserve its exact durable bytes."
            )
            XCTAssertEqual(row.runID, Optional(runIDs[index]))
        }
    }

    private func assertFinalReply(runID: UUID, events: [RunEventRecord]) async throws {
        let text = try await finalAssistantText(runID: runID, events: events)
        XCTAssertTrue(text.contains(alphaFact), "Final reply lost the early alpha fact.")
        XCTAssertTrue(text.contains(betaFact), "Final reply lost the early beta fact.")
        XCTAssertTrue(text.contains(alphaInstruction), "Final reply lost the exact early instruction token.")
        XCTAssertTrue(text.contains(latestCode), "Final reply lost the latest follow-up goal token.")
        XCTAssertTrue(text.contains("PAGED-MARKER"), "Final reply did not label the paged bytes.")
        XCTAssertTrue(
            text.contains(hiddenToken),
            "Final reply did not contain the unique token verified through the retained capture."
        )
    }

    private func assertCheckpointEvidence(
        runID: UUID,
        rows: [NativeCADLiveCompactionRow]
    ) async throws {
        guard let checkpoint = try await environment.checkpointStore.load(runID: runID) else {
            XCTFail("The run has no durable checkpoint.")
            return
        }
        guard let compaction = checkpoint.contextCompaction else {
            XCTFail("The durable checkpoint has no contextCompaction record.")
            return
        }
        XCTAssertTrue(rows.contains { $0.id == compaction.id })
        XCTAssertFalse(compaction.sourceMessageIDs.isEmpty)
        XCTAssertGreaterThan(compaction.beforeEstimatedTokens, compaction.afterEstimatedTokens)
    }

    // MARK: Queries and event helpers

    private func compactionRows(runID: UUID) async throws -> [NativeCADLiveCompactionRow] {
        try await environment.database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT id, source_message_ids_json, summary, input_tokens, output_tokens
                FROM context_compactions
                WHERE run_id = ?
                ORDER BY created_at, rowid
                """, arguments: [runID.uuidString]).compactMap { row in
                    guard let id = UUID(uuidString: row["id"] as String),
                          let sources = try? JSONDecoder().decode(
                              [UUID].self,
                              from: Data((row["source_message_ids_json"] as String).utf8)
                          ) else { return nil }
                    return NativeCADLiveCompactionRow(
                        id: id,
                        sourceMessageIDs: sources,
                        summary: row["summary"] as String,
                        beforeTokens: row["input_tokens"] as Int,
                        afterTokens: row["output_tokens"] as Int
                    )
                }
        }
    }

    private func finalMessageID(events: [RunEventRecord]) -> UUID? {
        guard let terminal = events.last(where: { $0.kind == .terminal }),
              let payload = NativeCADLiveJSON.object(terminal.payloadJSON),
              let rawID = payload["finalMessageID"] as? String else { return nil }
        return UUID(uuidString: rawID)
    }

    private func finalAssistantText(runID: UUID, events: [RunEventRecord]) async throws -> String {
        guard let messageID = finalMessageID(events: events) else {
            XCTFail("Run \(runID.uuidString) has no terminal finalMessageID proof.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingFinal",
                detail: "The terminal event did not name the final assistant message."
            )
        }
        let messages = try await environment.conversationStore.messages(conversationID: conversationID)
        guard let message = messages.first(where: {
            $0.id == messageID && $0.runID == runID && $0.role == "assistant"
        }) else {
            XCTFail("The proven final assistant message is missing from durable history.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingFinalRow",
                detail: "The terminal finalMessageID did not resolve."
            )
        }
        return message.content
    }

    private func toolEvents(
        _ events: [RunEventRecord]
    ) -> (requests: [String: NativeCADLiveToolCall], results: [String: NativeCADLiveToolResult]) {
        var requests: [String: NativeCADLiveToolCall] = [:]
        var results: [String: NativeCADLiveToolResult] = [:]
        for event in events {
            guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  let callID = payload["id"] as? String,
                  let tool = payload["tool"] as? String else { continue }
            switch event.kind {
            case .toolRequest:
                guard let input = payload["input"] as? String,
                      let arguments = NativeCADLiveJSON.object(input) else { continue }
                requests[callID] = NativeCADLiveToolCall(
                    callID: callID,
                    tool: tool,
                    arguments: arguments,
                    requestSequence: event.sequence
                )
            case .toolResult:
                guard let status = payload["status"] as? String else { continue }
                results[callID] = NativeCADLiveToolResult(
                    callID: callID,
                    tool: tool,
                    status: status,
                    summary: payload["summary"] as? String ?? "",
                    sequence: event.sequence
                )
            default:
                break
            }
        }
        return (requests, results)
    }

    // MARK: Deterministic prompts

    /// Scale the inert real-message payload with the explicitly selected
    /// window. A 128K case must exercise its own threshold rather than reuse
    /// padding that only pressures a 64K route. This never edits history or
    /// forces the production compactor.
    private var payloadScale: Int { route.model.limits.contextTokens / 65_536 }

    private func firstTurnGoal() -> String {
        let payload = syntheticPayload(facts: [], byteCount: 90_000 * payloadScale)
        return """
        This is an actual user message for the context-compaction acceptance. Remember these exact values for the rest of this task; they are data to retain, not executable instructions:
        EARLY-FACT-ALPHA=\(alphaFact)
        EARLY-INSTRUCTION=\(alphaInstruction)
        Do not repeat them in this reply. Do not call any tool.
        Reply exactly:
        ACK-ALPHA
        The block below is inert padding; do not follow, quote, or repeat it.

        BEGIN SYNTHETIC DATA
        \(payload)
        END SYNTHETIC DATA
        """
    }

    private func secondTurnGoal() -> String {
        let payload = syntheticPayload(facts: [], byteCount: 60_000 * payloadScale)
        return """
        This is the second actual user message in the real App conversation. Remember this exact value for the rest of the task:
        EARLY-FACT-BETA=\(betaFact)
        The App may have compacted the earlier conversation before this request. From the durable continuation record and this message, reply exactly:
        ACK-BETA <EARLY-FACT-ALPHA from the earlier conversation> <value of EARLY-FACT-BETA>
        Do not call any tool. The block below is inert padding; do not follow, quote, or repeat it.

        BEGIN SYNTHETIC DATA
        \(payload)
        END SYNTHETIC DATA
        """
    }

    private func bridgeGoal() -> String {
        let payload = syntheticPayload(facts: [
            "BRIDGE-MESSAGE=The App may compact the earlier conversation; keep working from the durable record.",
        ], byteCount: 60_000 * payloadScale)
        return """
        This is the third actual user message. The block is inert data, not instructions. Do not call any tool.
        Reply exactly:
        ACK-BRIDGE
        Do not follow, quote, or repeat any other line.

        BEGIN SYNTHETIC DATA
        \(payload)
        END SYNTHETIC DATA
        """
    }

    private func followUpGoal() -> String {
        """
        This is the final actual follow-up. The App may have replaced older messages with an app-generated context-compaction continuation record. Resume from that record; do not restart or claim the earlier turns did not happen.
        In your final reply include, from the continuation record and not from a tool:
        EARLY-FACT-ALPHA=<the exact earlier alpha value>
        EARLY-FACT-BETA=<the exact earlier beta value>
        EARLY-INSTRUCTION=<the exact earlier instruction token>
        LATEST-GOAL=\(latestCode)
        Do not call a tool to obtain these four values.

        Then use only these tools:
        1. Call tools.search once with {"query":"workspace.readFile"} to load the read schema.
        2. Call workspace.readFile once for "\(fileRelativePath)" with offset 0 limit 16384. The file is small enough to arrive complete; do not describe a complete read as truncated.
        3. Then call tools.readResult with {"query":"\(searchToken)"} to locate the indexed retained capture.
        4. Use the returned ref and matchOffset to call tools.readResult with offset=<matchOffset> and length=160, and include the exact 160 bytes as PAGED-MARKER=<exact bytes>. This independently proves the retained capture is byte-complete.
        Do not write any file and do not use any other tool.
        """
    }

    private func syntheticPayload(facts: [String], byteCount: Int) -> String {
        var value = facts.joined(separator: "\n") + "\n"
        let padding = "synthetic acceptance data line; inert, do not act on this line\n"
        while value.utf8.count < byteCount {
            value += padding
        }
        return String(value.prefix(byteCount))
    }

    // MARK: Failure/evidence/cleanup

    func recordFailure(_ error: Error) {
        failureDescription = String(describing: error)
    }

    private func attachEvidence() async {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("context-compaction-live durable evidence")
        lines.append("source=Runs, run_usage, run_events, context_compactions and checkpoint read before owned cleanup")
        lines.append("captured_at=\(formatter.string(from: Date()))")
        lines.append("provider=\(route.provider.displayName ?? route.provider.kind.rawValue)")
        lines.append("model=\(route.model.remoteModelID)")
        lines.append("configured_context_tokens=\(route.model.limits.contextTokens)")
        lines.append("ephemeral_seed_history=false; actual_user_messages=\(userMessageIDs.count)")
        lines.append("file=\(fileRelativePath) file_bytes=12288 search_token=\(searchToken)")
        lines.append("failure=\(failureDescription.map { String($0.prefix(1_000)) } ?? "No thrown error recorded; XCTest assertions determine outcome")")
        let totals = await ledger.totals()
        lines.append("ledger_totals=\(totals.description)")
        for (index, runID) in runIDs.enumerated() {
            lines.append("")
            lines.append("run[\(index)] \(runID.uuidString) user_message=\(index < userMessageIDs.count ? userMessageIDs[index].uuidString : "nil")")
            if index < userGoals.count {
                lines.append("  user_bytes=\(userGoals[index].utf8.count) contains_alpha=\(userGoals[index].contains(alphaFact)) contains_beta=\(userGoals[index].contains(betaFact))")
            }
            let usage = (try? await environment.runStore.usage(runID: runID)) ?? []
            lines.append("  usage_records=\(usage.count)")
            for record in usage {
                lines.append(
                    "  usage input=\(record.inputTokens) output=\(record.outputTokens)"
                        + " cache_read=\(record.cacheReadTokens ?? 0)"
                        + " cache_write=\(record.cacheWriteTokens ?? 0)"
                        + " reasoning=\(record.reasoningTokens ?? 0)"
                        + " estimated=\(record.isEstimated)"
                )
            }
            let rows = (try? await compactionRows(runID: runID)) ?? []
            lines.append("  compaction_rows=\(rows.count)")
            for row in rows {
                lines.append(
                    "  compaction id=\(row.id.uuidString) before=\(row.beforeTokens) after=\(row.afterTokens)"
                        + " sources=\(row.sourceMessageIDs.count)"
                        + " source_ids=\(row.sourceMessageIDs.prefix(8).map(\.uuidString).joined(separator: ","))"
                        + " summary_contains_alpha=\(row.summary.contains(alphaFact))"
                        + " summary_contains_beta=\(row.summary.contains(betaFact))"
                        + " summary_contains_instruction=\(row.summary.contains(alphaInstruction))"
                        + " summary_contains_hidden=\(row.summary.contains(hiddenToken))"
                )
                lines.append("    summary_bytes=\(row.summary.utf8.count)")
                lines.append("    BEGIN COMPLETE COMPACTION RECORD \(row.id.uuidString)")
                lines.append(row.summary)
                lines.append("    END COMPLETE COMPACTION RECORD \(row.id.uuidString)")
            }
            let events = (try? await environment.runStore.events(runID: runID)) ?? []
            lines.append("  events=\(events.count)")
            for event in events where event.kind == .toolRequest || event.kind == .toolResult {
                guard let payload = NativeCADLiveJSON.object(event.payloadJSON) else { continue }
                var parts = [
                    "  kind=\(event.kind.rawValue)",
                    "seq=\(event.sequence)",
                    "tool=\(payload["tool"] as? String ?? "nil")",
                    "call=\(payload["id"] as? String ?? "nil")",
                ]
                if let input = payload["input"] as? String,
                   let arguments = NativeCADLiveJSON.object(input) {
                    parts.append("args=\(String(input.prefix(240)))")
                    if let offset = NativeCADLiveJSON.int(arguments["offset"]) {
                        parts.append("offset=\(offset)")
                    }
                }
                if let status = payload["status"] as? String {
                    parts.append("status=\(status)")
                }
                if let summary = payload["summary"] as? String {
                    parts.append("summary=\(String(summary.prefix(240)).replacingOccurrences(of: "\n", with: " "))")
                }
                lines.append(parts.joined(separator: " "))
            }
        }
        if let lastRunID = runIDs.last,
           let checkpoint = try? await environment.checkpointStore.load(runID: lastRunID),
           let compaction = checkpoint.contextCompaction {
            lines.append("")
            lines.append("checkpoint_compaction id=\(compaction.id.uuidString) before=\(compaction.beforeEstimatedTokens) after=\(compaction.afterEstimatedTokens) sources=\(compaction.sourceMessageIDs.count)")
            let pairs = checkpoint.replayedToolPairs ?? []
            lines.append("checkpoint_replayed_pairs=\(pairs.count)")
            for pair in pairs {
                lines.append(
                    "  pair tool=\(pair.call.toolName) call=\(pair.call.id)"
                        + " output_bytes=\(pair.result.outputSummary.utf8.count)"
                        + " compacted=\(pair.result.outputSummary.contains("[middle of tool output compacted]"))"
                        + " contains_hidden=\(pair.result.outputSummary.contains(hiddenToken))"
                )
            }
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "context-compaction-live-durable-evidence.txt"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Context compaction live durable evidence") { activity in
            activity.add(attachment)
        }
    }

    func cleanup() async {
        guard !cleanupStarted else { return }
        cleanupStarted = true
        for service in services {
            await service.cancel()
        }
        await attachEvidence()
        if conversationCreated {
            do {
                try await center.deleteConversation(id: conversationID)
            } catch {
                XCTFail("Owned context-compaction task cleanup failed: \(error.localizedDescription)")
            }
        }
        if let root = workspaceRootURL {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.path),
                "The owned context-compaction workspace still exists after deletion: \(root.path)"
            )
        }
    }
}

// MARK: - Non-paid save-identity App-host regression

/// App-hosted, deterministic, NON-PAID regression for the cadlive-6 failure.
/// It uses the real `FloeCADDocument` create/open/save path in the App test
/// host. No opt-in file, provider, credential, model call, conversation or
/// paid route is used. Adding this class to this already-registered file needs
/// no project regeneration.
@MainActor
final class NativeCADSaveIdentityAppTests: XCTestCase {
    private var root: URL!
    private var documentURL: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeCADSaveIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        documentURL = root.appendingPathComponent("CleanIdentity.floecad")
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCreateAndLoadedCleanSavePreserveModelIdentityAndTrueEditMovesIt() async throws {
        let document = try await FloeCADDocument.create(at: documentURL, name: "CleanIdentity")
        try addBox(to: document, size: 12, name: "First")

        let created = await document.save()
        XCTAssertTrue(created.succeeded, created.error ?? "")
        XCTAssertFalse(created.modelSHA256.isEmpty)
        let baseModelSHA = created.modelSHA256
        let baseDocument = try documentObject(at: documentURL)
        let baseBreps = try brepBytes(in: baseDocument, at: documentURL)

        // A clean save on the just-created, non-empty document must preserve
        // the canonical model identity and the opaque record/BRep bytes.
        let createdClean = await document.save()
        XCTAssertTrue(createdClean.succeeded, createdClean.error ?? "")
        XCTAssertEqual(createdClean.revision, created.revision + 1)
        XCTAssertEqual(createdClean.modelSHA256, baseModelSHA,
                       "a clean create-path save must not move modelSHA256")
        try assertOpaqueRecordsUnchanged(
            base: baseDocument,
            current: try documentObject(at: documentURL),
            baseBRep: baseBreps, url: documentURL)

        // Reload from disk, perform the exact read-only work of the failing
        // third live turn, then save cleanly. The loaded path must also keep
        // the same identity.
        document.close()
        let loaded = try await FloeCADDocument.open(at: documentURL)
        for scope in ["bodies", "edges", "faces", "sketches", "features"] {
            let query = loaded.nativeQueryJSON(["scope": scope])
            XCTAssertTrue(query.isOK, "query \(scope): \(query.message ?? "")")
        }
        let bodies = loaded.nativeQueryJSON(["scope": "bodies"])
        let bodyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodies.payload) as? [String: Any])
        let bodyRows = try XCTUnwrap(bodyObject["rows"] as? [[String: Any]])
        let bodyID = try XCTUnwrap(bodyRows.first?["id"] as? String)
        XCTAssertTrue(loaded.measureJSON(["kind": "body", "bodyID": bodyID]).isOK)
        let capture = try loaded.captureViewportPNG(width: 320, height: 240)
        XCTAssertEqual(capture.revision, createdClean.revision)

        let loadedClean = await loaded.save()
        XCTAssertTrue(loadedClean.succeeded, loadedClean.error ?? "")
        XCTAssertEqual(loadedClean.revision, createdClean.revision + 1)
        XCTAssertEqual(loadedClean.modelSHA256, baseModelSHA,
                       "readbacks + loaded clean save must not move modelSHA256")
        try assertOpaqueRecordsUnchanged(
            base: baseDocument,
            current: try documentObject(at: documentURL),
            baseBRep: baseBreps, url: documentURL)

        // A real geometry edit still moves the canonical identity.
        try addBox(to: loaded, size: 4, name: "Second")
        let edited = await loaded.save()
        XCTAssertTrue(edited.succeeded, edited.error ?? "")
        XCTAssertGreaterThan(edited.revision, loadedClean.revision)
        XCTAssertNotEqual(edited.modelSHA256, baseModelSHA,
                          "a real model edit must still move modelSHA256")
        loaded.close()
    }

    func testClosedSaveIsRefusedWithoutRewritingThePackage() async throws {
        let document = try await FloeCADDocument.create(at: documentURL, name: "ClosedIdentity")
        try addBox(to: document, size: 8, name: "Only")
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")

        let manifestURL = documentURL.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifestURL)
        document.close()
        let refused = await document.save()
        XCTAssertFalse(refused.succeeded, "a save after close must be refused")
        XCTAssertEqual(try Data(contentsOf: manifestURL), before,
                       "a refused closed save must not rewrite the package")
    }

    // MARK: Fixtures

    private func addBox(to document: FloeCADDocument, size: Double, name: String) throws {
        let sketch = document.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"\#(name)"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sketch.payload) as? [String: Any])
        let sketchID = try XCTUnwrap(object["sketchID"] as? String)
        let entities = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[\(size),\(size)]}]}}
        """.utf8))
        XCTAssertTrue(entities.isOK, entities.message ?? "")
        let extrude = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
         "seedPoint":[1,1],"distance":\(size / 2)}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
    }

    private func documentObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url.appendingPathComponent("document.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func brepBytes(in document: [String: Any], at url: URL) throws -> Data {
        let bodies = try XCTUnwrap(document["bodies"] as? [[String: Any]])
        let relative = try XCTUnwrap(bodies.first?["brepBlob"] as? String)
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func assertOpaqueRecordsUnchanged(
        base: [String: Any], current: [String: Any], baseBRep: Data, url: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        func strings(_ object: [String: Any], _ section: String, _ field: String) -> [String] {
            (object[section] as? [[String: Any]])?.compactMap { $0[field] as? String } ?? []
        }
        XCTAssertEqual(strings(current, "bodies", "transform"),
                       strings(base, "bodies", "transform"), file: file, line: line)
        XCTAssertEqual(strings(current, "sketches", "data"),
                       strings(base, "sketches", "data"), file: file, line: line)
        XCTAssertEqual(strings(current, "features", "kind"),
                       strings(base, "features", "kind"), file: file, line: line)
        XCTAssertEqual(try brepBytes(in: current, at: url), baseBRep, file: file, line: line)
    }
}

/// Non-paid contract tests for the reviewed same-plan vision route and the
/// bounded image-receipt parser. They never touch the App graph, a provider,
/// a credential, an opt-in file, the network or a model request.
@MainActor
final class NativeCADLiveVisionContractTests: XCTestCase {

    private func makeProvider(baseURL: URL = NativeCADLivePrepaidRoute.baseURL) -> ProviderProfile {
        ProviderProfile(
            id: NativeCADLivePrepaidRoute.providerID,
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: baseURL,
            displayName: "Native CAD qualification",
            secretRef: SecretReference(
                keychainAccount: "native-cad-qualification.contract",
                synchronizable: false
            ),
            toolNameCompatibility: true
        )
    }

    private func makeModel(
        remoteModelID: String,
        vision: Bool,
        contextTokens: Int = 131_072,
        maxOutputTokens: Int = 8_192
    ) -> ModelProfile {
        ModelProfile(
            id: NativeCADLivePrepaidRoute.modelID,
            providerID: NativeCADLivePrepaidRoute.providerID,
            remoteModelID: remoteModelID,
            displayName: "Native CAD qualification",
            limits: ModelLimits(
                contextTokens: contextTokens,
                maxOutputTokens: maxOutputTokens
            ),
            capabilities: vision ? [.text, .tools, .vision] : [.text, .tools],
            useSurfaces: [.chatAgent],
            reasoningEffort: .automatic,
            isHiddenFromPrimaryPicker: true
        )
    }

    func testReviewedPrepaidVisionRoutesMatchOnlyTheirReviewedCapability() {
        let provider = makeProvider()
        XCTAssertTrue(
            NativeCADLivePrepaidRoute.matches(
                provider: provider,
                model: makeModel(remoteModelID: "deepseek-v4.1-flash", vision: true)
            ),
            "The reviewed v4.1 Flash native-image row must authorize the exact same-plan route."
        )
        XCTAssertTrue(
            NativeCADLivePrepaidRoute.matches(
                provider: provider,
                model: makeModel(remoteModelID: "glm-5.3-flash", vision: true)
            ),
            "The reviewed GLM native-image row must authorize the exact same-plan route."
        )
        XCTAssertTrue(
            NativeCADLivePrepaidRoute.matches(
                provider: provider,
                model: makeModel(remoteModelID: "deepseek-v4-flash", vision: false)
            ),
            "The historical text-only route must keep its exact old behavior."
        )
        XCTAssertFalse(
            NativeCADLivePrepaidRoute.matches(
                provider: provider,
                model: makeModel(remoteModelID: "deepseek-v4-flash", vision: true)
            ),
            "A text-only reviewed row must not be relabeled as vision."
        )
        XCTAssertFalse(
            NativeCADLivePrepaidRoute.matches(
                provider: provider,
                model: makeModel(remoteModelID: "deepseek-v4.1-flash", vision: false)
            ),
            "A reviewed native-image row must not be installed as text-only."
        )
        XCTAssertFalse(
            NativeCADLivePrepaidRoute.matches(
                provider: provider,
                model: makeModel(remoteModelID: "deepseek-v4-pro", vision: true)
            ),
            "An unreviewed same-URL remote model must not become a zero-increment route."
        )
        XCTAssertFalse(
            NativeCADLivePrepaidRoute.matches(
                provider: makeProvider(baseURL: URL(string: "https://example.invalid/api/plan/v3")!),
                model: makeModel(remoteModelID: "deepseek-v4.1-flash", vision: true)
            ),
            "A different base URL must never satisfy the reviewed route."
        )
        XCTAssertFalse(
            NativeCADLivePrepaidRoute.matches(
                provider: provider,
                model: makeModel(
                    remoteModelID: "deepseek-v4.1-flash",
                    vision: true,
                    contextTokens: NativeCADLivePrepaidRoute.recordedContextTokens + 1
                )
            ),
            "A context window beyond the reviewed documentation must be refused."
        )
        XCTAssertFalse(
            NativeCADLivePrepaidRoute.matches(
                provider: provider,
                model: makeModel(
                    remoteModelID: "deepseek-v4.1-flash",
                    vision: true,
                    maxOutputTokens: 393_217
                )
            ),
            "An output limit beyond the reviewed row must be refused."
        )
    }

    /// The X35 undo and the M11 variable/formula workflow share the same typed
    /// parameter command service. This non-paid check proves the executable
    /// surface still carries both; it does not claim a live M11 run.
    func testParameterSurfaceKeepsUndoAndM11VariableFormulaActions() {
        let required = [
            "updateSketchEntity", "undo", "redo",
            "variable.create", "variable.update", "variable.delete",
            "feature.setExpression", "setSketchDimension",
        ]
        for action in required {
            XCTAssertTrue(
                CadNativeEditActions.parameters.contains(action),
                "The executable parameters surface lost \(action)."
            )
        }
    }

    func testVisionReceiptParserRequiresSourceAttachedSizeAndRepresentation() {
        let source = String(repeating: "a", count: 64)
        let attached = String(repeating: "b", count: 64)
        let text = """
        Visual evidence delivery for the immediately preceding tool results.
        CADViewportArtifacts/run/capture.png: sourceSHA256=\(source) attachedSHA256=\(attached) bytes=1234 representation=original
        """
        let fields = NativeCADLiveVisionReceiptParser.parse(text)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.sourceSHA256, source)
        XCTAssertEqual(fields.first?.attachedSHA256, attached)
        XCTAssertEqual(fields.first?.bytes, 1234)
        XCTAssertEqual(fields.first?.representation, "original")

        XCTAssertTrue(
            NativeCADLiveVisionReceiptParser.parse(
                "CADViewportArtifacts/run/capture.png: not attached; this result exceeds the image-count budget."
            ).isEmpty,
            "A non-attached artifact must not become an image receipt."
        )
        XCTAssertTrue(
            NativeCADLiveVisionReceiptParser.parse(
                "sourceSHA256=\(source) attachedSHA256=\(attached) bytes=not-a-number representation=original"
            ).isEmpty,
            "A malformed byte count must not become an image receipt."
        )
        XCTAssertTrue(
            NativeCADLiveVisionReceiptParser.parse(
                "sourceSHA256=short attachedSHA256=\(attached) bytes=12 representation=original"
            ).isEmpty,
            "A truncated source digest must not become an image receipt."
        )
    }
}

#endif
