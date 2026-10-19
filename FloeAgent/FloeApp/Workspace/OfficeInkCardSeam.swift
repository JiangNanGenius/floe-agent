// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import SwiftUI
import WebKit
#if canImport(FloeOfficeNative)
import FloeOfficeNative
#endif

/// DEBUG-only, launch-argument-gated injected-pen seam for the actual
/// Main-App saved-ink library-card UI loop acceptance.
///
/// What it is: one clearly labeled fixture control (identifier family
/// `office.ink-fixture.*`) mounted inside the SAME `OfficeDocumentSurface`
/// every owning surface already hosts, armed only while the explicit
/// `OfficeInkCardLoopFixture` launch arguments are present. Its single action
/// validates ownership, applies a deterministic RED/MARKER/2.0mm/0%-opacity
/// stroke through the production `OfficeInkPreferences` +
/// `OfficeFileSession.applyInkPreferences()` path (saving and restoring the
/// document's own prior stroke), then dispatches EXACTLY ONE labeled
/// synthetic pen PointerEvent curve through the production canvas capture
/// handlers already installed by FloeOfficeNative (`window.__floeOfficePenState`
/// counters before/after) into the CURRENT editor's own WKWebView.
///
/// Owner fencing is per-event AND per-hop, not post-hoc: at ownership
/// establishment the fixed capture script validates the whole live ownership
/// chain and then stores ONE in-page binding (`window.__floeInkFixtureOwner`)
/// holding the exact live `window.app`, `app.map` object, live
/// `map._docLayer` object, backend permission object (`app.file`, still
/// writable), host's frozen mount-facts object (`window.__floeOfficeSession`),
/// the exact raw document string (`map.options.doc`) and the document canvas
/// node, plus a per-run owner token. Every later step — the style dispatch,
/// the nine-event contact (BEFORE EACH event), the dirty-state polling, every
/// restore hop and the final post-restore check — revalidates the CURRENT
/// live objects against that captured binding. A navigation, a document,
/// layer, permission, mount or canvas replacement (including a same-path,
/// same-value copied object), a document swap, drawing disarm or lease theft
/// fails closed; cleanup is SKIPPED rather than applied to the replacement.
/// The binding is never refreshed from current values, so a fresh semantic
/// path/value probe can never stand in for identity. On the Swift side the
/// run task is retained, cancellable, and cancelled when the view disappears;
/// every hop re-checks the captured controller identity as well. Because
/// cancelling a Swift task cannot interrupt an already-awaiting page, an
/// invalidation (or task cancellation) additionally REVOKES exactly this
/// run's captured lease on exactly the captured old surface — the next
/// in-page event then fails the fence and dispatch stops — and a replacement
/// controller or a later page owner token is never touched. Ownership,
/// cancellation and the captured page binding are rechecked again after the
/// awaited style restore, so a teardown or replacement during that restore can
/// never publish the verified token. The style restore itself is awaited and
/// touches ONLY the still-current session/preferences object AND the still-
/// intact captured page binding; if either is lost it is skipped, never
/// forced, so cleanup can never race a replacement generation.
///
/// Readiness is state-observed, never time-observed: the seam publishes
/// `lifted` only when the production bridge reports the contact drained
/// (`activeStroke == false`, `strokes` delta), then `ink-dirty-verified` only
/// when BOTH the engine's own `.uno:ModifiedStatus` probe
/// (`OfficeExplicitSaveBridge.modifiedStatusProbeScript`, fail-closed on
/// unknown) AND the session's published `hasUncommittedChanges` report dirty.
/// `bridgeActiveObserved`/`bridgePreviewFlagObserved` are the bridge's own
/// state flags recorded during the contact — bridge bookkeeping evidence,
/// NOT painted-frame proof. The painted evidence is the UI test's real
/// editor screenshot delta and the saved vector verified by the read-only
/// postflight. The seam sleeps no fixed duration and never requests or fakes
/// the save itself — the real Back guard owns the asynchronous save/commit,
/// exactly as in production. There is no alternate environment, no hidden
/// runtime, no fake PNG/SVG/OOXML insertion and no manual cover seeding.
/// There is no generic execution surface: every script is one fixed literal
/// that only ever performs this one labeled fixture workflow. The only
/// private data arguments are a per-run lease token, a per-run owner token
/// and this controller's canonical staged working-copy path (a PRIVATE
/// capture-only comparison argument; the fixture-owned file name is used only
/// for the App-side live session registry binding). No path, name, token,
/// document text or error text ever reaches a status, fact or receipt.
///
/// Release builds: the entire file compiles out (`#if DEBUG`), the mount
/// hunk is inside `#if DEBUG`, and ordinary DEBUG runs without the explicit
/// launch arguments render `EmptyView` — no new control, no automatic
/// drawing, no behavior change. This family is disjoint from the passive
/// `office.touch-qualification.*` probe: it never reads or mutates trusted
/// pinch input or probe evidence.
@MainActor
final class OfficeInkCardSeamModel: ObservableObject {
    @Published private(set) var status = "ready"
    @Published private(set) var facts = ""
    @Published private(set) var busy = false

    private var runTask: Task<Void, Never>?
    private var invalidated = false
    private var completed = false

    /// Lifecycle-owned revocation state. While the contact script is in
    /// flight the model holds a WEAK reference to the exact captured surface
    /// plus the exact lease token it took, so an invalidation (or a Swift
    /// Task cancellation) can revoke that lease ON THAT CAPTURED SURFACE
    /// ONLY — a replacement controller is never touched, and the in-page
    /// per-event fence then stops any further dispatch at the next event.
    /// These references are cleared as soon as the script returns, because
    /// from that point no further pointer dispatch is pending.
    private weak var capturedLeaseWeb: WKWebView?
    private var capturedLeaseToken: String?
    private var capturedLeaseOwnerToken: String?
    private var revocationTask: Task<Void, Never>?

    /// Capture-once page ownership binding. `capturedOwnerWeb` is the exact
    /// old surface the binding was installed on; `capturedOwnerToken` is the
    /// per-run identity of the binding. It is retained through the style
    /// dispatch, the contact, the dirty wait, every restore hop and the final
    /// post-restore check, and is released only after the run has finished.
    /// Revocation and release scripts require this exact token, so a later
    /// page owner's token is never cleared.
    private weak var capturedOwnerWeb: WKWebView?
    private var capturedOwnerToken: String?

    /// Retained, single-run lifecycle. The UI test's explicit tap arms it;
    /// unmount or a replacement editor cancels it. No second run starts
    /// without a fresh view identity.
    func start(session: OfficeFileSession) {
        guard runTask == nil else {
            status = "failed-already-running"
            return
        }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(session: session)
            self.runTask = nil
        }
    }

    /// View disappeared (navigation, gate closed, editor replaced): stop
    /// claiming any state, cancel the owned task AND revoke the in-flight
    /// lease on the captured surface only. Cancelling the Swift Task alone
    /// cannot interrupt an already-running `callAsyncJavaScript` whose page
    /// still has the same map/document/canvas/drawing (a teardown where the
    /// old WKWebView stays connected): the revocation makes the in-page
    /// per-event fence fail at the next dispatched event, which is the
    /// authoritative mid-script stop. A replacement controller is never
    /// touched, and no unowned cleanup task is created.
    func invalidate() {
        guard !completed else { return }
        invalidated = true
        runTask?.cancel()
        runTask = nil
        revokeCapturedLease()
        if status == "ready" || status == "verifying" || status == "injecting" || status == "lifted" {
            status = "cancelled"
        }
    }

    /// Scoped revocation: touches ONLY the weakly captured old surface and
    /// ONLY clears the lease when BOTH this run's exact lease token AND its
    /// exact captured owner token still match. A later page owner (different
    /// owner token or different lease) is never wiped. Idempotent; safe after
    /// page teardown (the evaluation simply fails and nothing is pending).
    private func revokeCapturedLease() {
        guard let web = capturedLeaseWeb, let lease = capturedLeaseToken,
              let ownerToken = capturedLeaseOwnerToken,
              Self.isLeaseToken(lease), Self.isOwnerToken(ownerToken) else { return }
        revocationTask?.cancel()
        revocationTask = Task { @MainActor [weak self] in
            _ = try? await web.callAsyncJavaScript(
                Self.leaseRevocationScript,
                arguments: ["lease": lease, "ownerToken": ownerToken],
                in: nil,
                contentWorld: .page)
            guard let self, self.capturedLeaseToken == lease else { return }
            self.capturedLeaseToken = nil
            self.capturedLeaseOwnerToken = nil
        }
    }

    private static func isLeaseToken(_ value: String) -> Bool {
        value.hasPrefix("floe-ink-fixture-") && value.count <= 80 &&
        value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func isOwnerToken(_ value: String) -> Bool {
        value.hasPrefix("floe-ink-owner-") && value.count <= 80 &&
        value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Fixed literal; `lease` and `ownerToken` are `callAsyncJavaScript`
    /// arguments. It clears ONLY the exact captured lease and owner binding,
    /// so a delayed revocation from this run can never wipe a later owner.
    private static let leaseRevocationScript = #"""
    (() => {
        if (window.__floeInkFixtureLease === lease
            && window.__floeInkFixtureLeaseOwner === ownerToken
            && window.__floeInkFixtureOwner
            && window.__floeInkFixtureOwner.token === ownerToken) {
            window.__floeInkFixtureLease = null;
            window.__floeInkFixtureLeaseOwner = null;
            return 'revoked';
        }
        return 'foreign';
    })()
    """#

    /// One bounded action. Every failure is terminal for this view identity
    /// and leaves the document untouched apart from the already-dispatched
    /// style (which is restored only while the owner is still current).
    private func run(session: OfficeFileSession) async {
        guard !invalidated, !Task.isCancelled else { return }
        if completed {
            status = "failed-already-run"
            return
        }
        busy = true
        defer { busy = false }
        guard OfficeInkCardLoopFixture.isArmed,
              let format = OfficeInkCardLoopFixture.requestedFormat,
              let token = OfficeInkCardLoopFixture.requestedToken else {
            status = "failed-not-armed"
            return
        }
        status = "verifying"
        // (1) Current-editor state, captured once and re-verified after every
        // hop. Only an editable, ready, drawing-armed session is eligible.
        guard session.phase == .ready, session.canAct, !session.readOnly,
              session.documentActionsReady, session.drawingMode,
              session.inkError == nil,
              let controller = session.controller else {
            status = "failed-state-invalid"
            return
        }
        #if canImport(FloeOfficeNative)
        guard let native = controller as? FloeOfficeNativeViewController,
              let web = OfficeExplicitSaveBridge.findWebView(in: native.view) else {
            status = "failed-state-invalid"
            return
        }
        // (2) Ownership identity against the ACTUAL pinned native host. The
        // bundled engine (verified against the exact pinned browser bundle
        // b95ed4e6…) exposes no document-name accessor, and the local-kit
        // mount binds the engine document to the staged working-copy PATH,
        // not the library file name. The Swift-side chain is checked first:
        // the production live session registry binds the fixture-owned file
        // name to this exact session, and this session's captured controller
        // still owns the exact staged working copy (`workingFileURL`). Then
        // the page identity is captured ONCE as real object references plus
        // the exact raw document string, validated against this controller's
        // canonical staged path with one exact path equality. Without this
        // capture there is no dispatch; with it, every later hop compares the
        // CURRENT objects to the captured binding, never to fresh values.
        let ownedFileName = OfficeInkCardLoopFixture.ownedFileName(format: format, token: token)
        let stagedPath = native.workingFileURL.path
        guard stagedPath.hasPrefix("/"), stagedPath.count > 1, stagedPath.count <= 4096 else {
            facts = "ownerProbe=staged-identity-unavailable"
            status = "failed-owner-unknown"
            return
        }
        guard stillOwns(session: session, controller: controller) else {
            status = "failed-owner-lost"
            return
        }
        guard OfficeLiveSessionRegistry.shared.session(root: nil, relativePath: ownedFileName) === session else {
            status = "failed-owner-mismatch"
            return
        }
        let ownerToken = "floe-ink-owner-" + UUID().uuidString
        guard Self.isOwnerToken(ownerToken) else {
            facts = "ownerProbe=owner-token-invalid"
            status = "failed-owner-unknown"
            return
        }
        // Register the exact captured surface and token BEFORE capture so the
        // binding is released even if the capture await is cancelled or the
        // page installs the binding and then loses the Swift task.
        capturedOwnerWeb = web
        capturedOwnerToken = ownerToken
        let ownerProbe = await captureOwner(web: web, stagedPath: stagedPath, ownerToken: ownerToken)
        guard ownerProbe == "ok" else {
            await releaseCapturedOwner()
            if ownerProbe == "cancelled" || invalidated || Task.isCancelled {
                status = "cancelled"
                return
            }
            facts = "ownerProbe=\(ownerProbe)"
            switch ownerProbe {
            case "engine-app-unavailable", "engine-map-unavailable",
                 "engine-document-unloaded", "engine-backend-unknown",
                 "host-facts-absent", "canvas-unavailable", "canvas-disconnected",
                 "owner-binding-busy", "probe-arguments-invalid", "probe-threw",
                 "js-error", "probe-absent", "cancelled":
                status = "failed-owner-unknown"
            default:
                status = "failed-owner-mismatch"
            }
            return
        }
        // The captured binding is the page identity for the rest of this run.
        // It is retained through the style dispatch, the contact, the dirty
        // wait, every restore hop and the final post-restore check, and is
        // released only after this local run body returns.
        func driveCaptured() async {
        // Capture the document-scoped preferences once and require the SAME
        // object through every later Swift check: a replaced preferences
        // object is a new document context, not this run's owner.
        let preferences = session.inkPreferences
        let savedStroke = preferences.stroke
        // The capture call was an await. Before any style is applied, recheck
        // the Swift owner and the captured binding it just installed.
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            facts = "ownerCheck=swift-owner-lost restore=skipped-owner"
            status = ownerLossStatus("swift-owner-lost")
            return
        }
        let startOwnerCode = await ownerBindingStatus(web: web, ownerToken: ownerToken)
        // POST-AWAIT Swift identity/cancellation check, BEFORE the first
        // preferences mutation. A page result from the old WKWebView can be
        // "ok" while this session has already replaced its controller or
        // rebound its document-scoped preferences.
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            facts = "ownerCheck=swift-owner-lost restore=skipped-owner"
            status = ownerLossStatus("swift-owner-lost")
            return
        }
        guard startOwnerCode == "ok" else {
            facts = "ownerCheck=\(startOwnerCode) restore=skipped-owner"
            status = ownerLossStatus(startOwnerCode)
            return
        }
        // (3) Deterministic style through the production preferences path,
        // with the document's own prior stroke saved. Transparency is pinned
        // to 0 explicitly; it never inherits a global or previous
        // transparency state. The restore at every exit path is awaited and
        // owner-guarded (step 6 and `restore`).
        preferences.setPreset(.marker)
        preferences.setColorHex("#FF0000")
        preferences.setWidthMillimeters(2.0)
        preferences.setTransparencyPercent(0)
        await session.applyInkPreferences()
        // The style dispatch was an await. A same-value page replacement can
        // happen during it without changing this Swift controller, so both the
        // Swift owner and the CAPTURED page binding are rechecked. If the page
        // owner is gone, no engine-visible restore is attempted at all.
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            facts = "ownerCheck=swift-owner-lost restore=skipped-owner"
            status = ownerLossStatus("swift-owner-lost")
            return
        }
        let styleOwnerCode = await ownerBindingStatus(web: web, ownerToken: ownerToken)
        // POST-AWAIT Swift identity/cancellation check before reading the
        // applied style or starting the contact.
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            facts = "ownerCheck=swift-owner-lost restore=skipped-owner"
            status = ownerLossStatus("swift-owner-lost")
            return
        }
        guard styleOwnerCode == "ok" else {
            facts = "ownerCheck=\(styleOwnerCode) restore=skipped-owner"
            status = ownerLossStatus(styleOwnerCode)
            return
        }
        let stroke = preferences.stroke
        guard stroke.preset == .marker, stroke.colorHex == "#FF0000",
              abs(stroke.widthMillimeters - 2.0) < 0.001,
              stroke.transparencyPercent == 0,
              session.inkApplyOutcome == .verified, session.inkError == nil else {
            let restored = await restore(preferences, savedStroke, session: session,
                                         controller: controller, web: web,
                                         ownerToken: ownerToken)
            status = failureAfterRestore("failed-style", restored: restored)
            return
        }
        // (4) Exactly one labeled synthetic pen curve through the real
        // canvas handlers. The fixed script NEVER captures new page values:
        // it revalidates the CAPTURED app/map/docLayer/backend/mount/canvas/
        // raw-document binding before the contact and before EVERY event,
        // probes ALL NINE dispatched points for canvas ownership, and checks
        // the armed drawing state and the exact lease/owner token pair. It
        // fails closed before dispatch unless drawing is armed, no previous
        // stroke is active and the real visible document area is large
        // enough. A fence loss mid-contact stops at that event and releases
        // the lease; nothing continues into a replaced owner.
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            facts += " ownerCheck=swift-owner-lost restore=skipped-owner"
            status = ownerLossStatus("swift-owner-lost")
            return
        }
        let preCurveOwnerCode = await ownerBindingStatus(web: web, ownerToken: ownerToken)
        // POST-AWAIT Swift check immediately before arming the contact; the
        // pointer dispatch must never start for a replaced controller.
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            facts += " ownerCheck=swift-owner-lost restore=skipped-owner"
            status = ownerLossStatus("swift-owner-lost")
            return
        }
        guard preCurveOwnerCode == "ok" else {
            facts = "ownerCheck=\(preCurveOwnerCode) restore=skipped-owner"
            status = ownerLossStatus(preCurveOwnerCode)
            return
        }
        status = "injecting"
        let lease = "floe-ink-fixture-" + UUID().uuidString
        guard Self.isLeaseToken(lease) else {
            facts += " restore=skipped-owner"
            status = "failed-route"
            return
        }
        // Register the lifecycle-owned lease BEFORE dispatch. `invalidate()`
        // and the cancellation handler below can then revoke EXACTLY this
        // lease on EXACTLY this captured surface; the in-page per-event fence
        // stops the next delayed event. Swift Task cancellation alone cannot
        // interrupt an already-awaiting callAsyncJavaScript page, so the
        // revocation — not the task cancel — is the authoritative stop.
        capturedLeaseWeb = web
        capturedLeaseToken = lease
        capturedLeaseOwnerToken = ownerToken
        let receiptJSON: String?
        do {
            receiptJSON = try await withTaskCancellationHandler {
                try await web.callAsyncJavaScript(
                    Self.curveScript,
                    arguments: ["lease": lease, "ownerToken": ownerToken],
                    in: nil,
                    contentWorld: .page) as? String
            } onCancel: {
                // Cancellation may arrive on any thread; hop to the main
                // actor and revoke the captured lease. Scoped to the weak
                // captured old surface and this run's exact owner token,
                // never a replacement controller or a later owner token.
                Task { @MainActor [weak self] in self?.revokeCapturedLease() }
            }
        } catch {
            capturedLeaseWeb = nil
            capturedLeaseToken = nil
            capturedLeaseOwnerToken = nil
            let nsError = error as NSError
            facts = "route-error domain=\(nsError.domain) code=\(nsError.code)"
            let restored = await restore(preferences, savedStroke, session: session,
                                         controller: controller, web: web,
                                         ownerToken: ownerToken)
            status = failureAfterRestore("failed-route", restored: restored)
            return
        }
        // Once the script returns there is no pending pointer dispatch, so
        // the lease-revocation window is closed. The OWNER binding is not
        // cleared here: it must fence every restore hop below.
        capturedLeaseWeb = nil
        capturedLeaseToken = nil
        capturedLeaseOwnerToken = nil
        guard !invalidated, !Task.isCancelled else { status = "cancelled"; return }
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            facts += " owner=lost-after-lift restore=skipped-owner"
            status = ownerLossStatus("swift-owner-lost")
            return
        }
        let postCurveOwnerCode = await ownerBindingStatus(web: web, ownerToken: ownerToken)
        // POST-AWAIT Swift identity/cancellation check before parsing the
        // receipt or reading engine/session state.
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            facts += " ownerCheck=swift-owner-lost restore=skipped-owner"
            status = ownerLossStatus("swift-owner-lost")
            return
        }
        guard postCurveOwnerCode == "ok" else {
            facts += " ownerCheck=\(postCurveOwnerCode) restore=skipped-owner"
            status = ownerLossStatus(postCurveOwnerCode)
            return
        }
        guard let receiptJSON,
              let receiptData = receiptJSON.data(using: .utf8),
              let receipt = try? JSONSerialization.jsonObject(with: receiptData) as? [String: Any] else {
            let restored = await restore(preferences, savedStroke, session: session,
                                         controller: controller, web: web,
                                         ownerToken: ownerToken)
            status = failureAfterRestore("failed-route", restored: restored)
            return
        }
        facts = Self.redactedFacts(receipt)
        guard (receipt["routeReady"] as? Bool) == true,
              (receipt["ownerBindingHeld"] as? Bool) == true,
              (receipt["fenceHeld"] as? Bool) == true,
              (receipt["pointsProbed"] as? Int) == 9,
              (receipt["strokesDelta"] as? Int) == 1,
              (receipt["eventsDispatched"] as? Int) == 9,
              (receipt["movesDispatched"] as? Int) == 7,
              (receipt["activeAfterUp"] as? Bool) == false,
              (receipt["bridgeActiveObserved"] as? Bool) == true else {
            if (receipt["reason"] as? String)?.hasPrefix("owner-fence-lost") == true {
                // The curve itself proved the captured owner was lost. Do not
                // invoke the restore at all: no engine-visible cleanup may be
                // applied to the replacement owner.
                facts += " restore=skipped-owner"
                status = "failed-owner-lost"
            } else {
                let restored = await restore(preferences, savedStroke, session: session,
                                             controller: controller, web: web,
                                             ownerToken: ownerToken)
                status = failureAfterRestore("failed-route", restored: restored)
            }
            return
        }
        status = "lifted"
        // (5) State-observed ink commitment — no fixed delay standing in for
        // a flush. Bounded polling of the engine's authoritative modified
        // flag AND the session's own published dirty state. `null`/unknown
        // is never read as clean; the deadline is an honest failure, not a
        // silent success. The real Back guard still owns the save itself.
        var dirtyObserved = false
        var engineSaidModified = false
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard stillOwns(session: session, controller: controller,
                        preferences: preferences),
                  !invalidated, !Task.isCancelled else {
                facts += " restore=skipped-owner"
                status = (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
                return
            }
            // The engine probe below is another await. Check the captured
            // binding BEFORE and AFTER it; a replacement in either window
            // stops the wait and skips every engine-visible restore.
            let loopOwnerCode = await ownerBindingStatus(web: web, ownerToken: ownerToken)
            // POST-AWAIT Swift identity/cancellation check before reading
            // session dirty state or issuing the engine probe.
            guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
                facts += " ownerCheck=swift-owner-lost restore=skipped-owner"
                status = (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
                return
            }
            guard loopOwnerCode == "ok" else {
                facts += " ownerCheck=\(loopOwnerCode) restore=skipped-owner"
                status = (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
                return
            }
            dirtyObserved = session.hasUncommittedChanges
            let probe = try? await web.evaluateJavaScript(
                OfficeExplicitSaveBridge.modifiedStatusProbeScript)
            // POST-AWAIT: the engine probe can suspend; a replacement must not
            // inherit its result or the next binding check.
            guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
                facts += " ownerCheck=swift-owner-lost restore=skipped-owner"
                status = (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
                return
            }
            let probeOwnerCode = await ownerBindingStatus(web: web, ownerToken: ownerToken)
            // POST-AWAIT before using the probe result.
            guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
                facts += " ownerCheck=swift-owner-lost restore=skipped-owner"
                status = (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
                return
            }
            guard probeOwnerCode == "ok" else {
                facts += " ownerCheck=\(probeOwnerCode) restore=skipped-owner"
                status = (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
                return
            }
            if let number = probe as? NSNumber, number.boolValue {
                engineSaidModified = true
            } else if let text = probe as? String, text == "true" {
                engineSaidModified = true
            }
            if dirtyObserved, engineSaidModified { break }
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard dirtyObserved, engineSaidModified else {
            facts += " dirty=\(dirtyObserved ? 1 : 0) modified=\(engineSaidModified ? 1 : 0)"
            let restored = await restore(preferences, savedStroke, session: session,
                                         controller: controller, web: web,
                                         ownerToken: ownerToken)
            status = failureAfterRestore("failed-engine-state", restored: restored)
            return
        }
        // (6) The deterministic style restore, awaited and owner-guarded: it
        // only ever touches the still-current session's own preferences
        // object AND the captured page binding, and can never act on a
        // replacement controller or a replacement page owner.
        let restored = await restore(preferences, savedStroke, session: session,
                                     controller: controller, web: web,
                                     ownerToken: ownerToken)
        guard restored else {
            status = (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
            return
        }
        // (7) Recheck ownership/cancellation AND the captured page binding
        // AFTER the restore await before publishing the verified token: a
        // teardown, controller replacement or same-value page-owner
        // replacement during that await must never produce a success for a
        // stale owner.
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            status = (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
            return
        }
        let finalOwnerCode = await ownerBindingStatus(web: web, ownerToken: ownerToken)
        // POST-AWAIT Swift identity/cancellation check BEFORE publishing.
        // The final page verify can return "ok" from the old WKWebView after
        // this session has replaced its controller or the task was cancelled.
        guard stillOwns(session: session, controller: controller,
                        preferences: preferences) else {
            facts += " ownerCheck=swift-owner-lost"
            status = (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
            return
        }
        guard finalOwnerCode == "ok" else {
            facts += " ownerCheck=\(finalOwnerCode)"
            status = ownerLossStatus(finalOwnerCode)
            return
        }
        completed = true
        status = "ink-dirty-verified"
        }
        await driveCaptured()
        await releaseCapturedOwner()
        #else
        status = "failed-native-unavailable"
        #endif
    }

    /// A cancellation observed AFTER an await. Guard terms evaluated before
    /// an `ownerBindingStatus`/`ownerBindingIntact` await are not sufficient:
    /// the task can be cancelled while the page call is in flight, so callers
    /// must re-read this state once the call resumes.
    private func postAwaitCancelled() -> Bool {
        invalidated || Task.isCancelled
    }

    /// Strict current-owner check used after every page-binding await and
    /// before any style mutation, pointer dispatch, engine probe or publish.
    private func stillOwns(session: OfficeFileSession,
                           controller: UIViewController,
                           preferences: OfficeInkPreferences? = nil) -> Bool {
        !postAwaitCancelled()
            && session.controller === controller
            && (preferences.map { session.inkPreferences === $0 } ?? true)
            && session.phase == .ready
            && session.canAct
            && session.drawingMode
    }

    /// A cancellation is reported as cancellation, not as an owner mismatch;
    /// any other failed binding check is an owner loss.
    private func ownerLossStatus(_ code: String) -> String {
        (code == "cancelled" || invalidated || Task.isCancelled)
            ? "cancelled" : "failed-owner-lost"
    }

    /// Maps a post-restore failure to its truthful terminal status. A restore
    /// skipped because the owner was lost is never reported as the original
    /// style/route/dirty failure: the run lost its owner and nothing was
    /// cleaned on the replacement.
    private func failureAfterRestore(_ primary: String, restored: Bool) -> String {
        if restored { return primary }
        return (invalidated || Task.isCancelled) ? "cancelled" : "failed-owner-lost"
    }

    /// Installs the capture-once page binding. Only bounded fixed codes are
    /// returned; a JS error is folded to `js-error` and never carries page
    /// text, a path, the token or an NSError message.
    private func captureOwner(web: WKWebView, stagedPath: String, ownerToken: String) async -> String {
        guard !invalidated, !Task.isCancelled else { return "cancelled" }
        do {
            let result = try await web.callAsyncJavaScript(
                Self.ownerCaptureScript,
                arguments: ["expectedDocPath": stagedPath, "ownerToken": ownerToken],
                in: nil,
                contentWorld: .page) as? [String: Any]
            // Re-read cancellation once the page await resumes; the binding
            // may have been installed even though this run must not continue.
            guard !postAwaitCancelled() else { return "cancelled" }
            guard let result,
                  (result["v"] as? Bool) == true,
                  let rawCode = result["code"] as? String else { return "probe-absent" }
            let code = String(rawCode.prefix(48))
            return ((result["ok"] as? Bool) == true && code == "ok") ? "ok" : code
        } catch {
            return "js-error"
        }
    }

    /// Revalidates the CURRENT page against the captured binding on the
    /// EXACT captured surface. Only bounded codes are returned. This is NOT
    /// a fresh semantic probe: every identity field is compared to the
    /// object/string captured once at ownership establishment.
    private func ownerBindingStatus(web: WKWebView, ownerToken: String) async -> String {
        guard !invalidated, !Task.isCancelled else { return "cancelled" }
        do {
            let result = try await web.callAsyncJavaScript(
                Self.ownerVerifyScript,
                arguments: ["ownerToken": ownerToken],
                in: nil,
                contentWorld: .page) as? [String: Any]
            // A cancellation that arrived during the page call wins over a
            // page result that looks intact.
            guard !postAwaitCancelled() else { return "cancelled" }
            guard let result,
                  (result["v"] as? Bool) == true,
                  let rawCode = result["code"] as? String else { return "probe-absent" }
            let code = String(rawCode.prefix(48))
            return ((result["ok"] as? Bool) == true && code == "ok") ? "ok" : code
        } catch {
            return "js-error"
        }
    }

    private func ownerBindingIntact(web: WKWebView, ownerToken: String) async -> Bool {
        await ownerBindingStatus(web: web, ownerToken: ownerToken) == "ok"
    }

    /// Post-await Swift owner check for the restore's settle phase. It does
    /// NOT require `canAct`: the restore intentionally waits for the session
    /// to settle before touching preferences. It always re-reads the CURRENT
    /// controller, preferences identity and cancellation state, so a term
    /// evaluated before an awaited page check can never authorize a later
    /// mutation.
    private func restoreOwnerCurrent(_ preferences: OfficeInkPreferences,
                                     session: OfficeFileSession,
                                     controller: UIViewController) -> Bool {
        !postAwaitCancelled()
            && session.controller === controller
            && session.inkPreferences === preferences
    }

    /// Releases ONLY this run's binding, after every restore hop and the final
    /// check. A later owner has a different token and is left untouched.
    private func releaseCapturedOwner() async {
        guard let web = capturedOwnerWeb, let ownerToken = capturedOwnerToken,
              Self.isOwnerToken(ownerToken) else {
            capturedOwnerWeb = nil
            capturedOwnerToken = nil
            return
        }
        capturedOwnerWeb = nil
        capturedOwnerToken = nil
        _ = try? await web.callAsyncJavaScript(
            Self.releaseOwnerBindingScript,
            arguments: ["ownerToken": ownerToken],
            in: nil,
            contentWorld: .page)
    }

    /// Awaited, owner-scoped style restore. If the editor or the captured page
    /// binding was replaced or is gone, this SKIPS instead of forcing cleanup
    /// into a new generation (the document-scoped preferences simply keep
    /// their persisted values, which the next production entry re-applies on
    /// its own). A brief bounded wait tolerates a still-settling `operating`
    /// flag. The captured binding is revalidated before the settle wait, after
    /// it, immediately before the engine-visible apply and again after that
    /// await; a failure at any point returns false so the caller cannot
    /// publish success.
    private func restore(_ preferences: OfficeInkPreferences,
                         _ stroke: OfficeInkStroke,
                         session: OfficeFileSession,
                         controller: UIViewController,
                         web: WKWebView,
                         ownerToken: String) async -> Bool {
        guard !postAwaitCancelled() else { facts += " restore=cancelled"; return false }
        guard restoreOwnerCurrent(preferences, session: session, controller: controller) else {
            facts += " restore=skipped-owner"
            return false
        }
        guard await ownerBindingIntact(web: web, ownerToken: ownerToken) else {
            facts += " restore=skipped-owner"
            return false
        }
        // POST-AWAIT: re-read controller/preferences/cancellation; a Swift
        // term evaluated before the page call does not authorize mutation.
        guard restoreOwnerCurrent(preferences, session: session, controller: controller) else {
            facts += " restore=skipped-owner"
            return false
        }
        let settle = Date().addingTimeInterval(2)
        while !session.canAct, Date() < settle {
            guard restoreOwnerCurrent(preferences, session: session, controller: controller) else {
                facts += " restore=skipped-owner"
                return false
            }
            guard await ownerBindingIntact(web: web, ownerToken: ownerToken) else {
                facts += " restore=skipped-owner"
                return false
            }
            // POST-AWAIT
            guard restoreOwnerCurrent(preferences, session: session, controller: controller) else {
                facts += " restore=skipped-owner"
                return false
            }
            try? await Task.sleep(for: .milliseconds(80))
            // POST-SLEEP-AWAIT
            guard restoreOwnerCurrent(preferences, session: session, controller: controller) else {
                facts += " restore=skipped-owner"
                return false
            }
        }
        guard restoreOwnerCurrent(preferences, session: session, controller: controller),
              session.canAct else {
            facts += " restore=skipped-owner"
            return false
        }
        guard await ownerBindingIntact(web: web, ownerToken: ownerToken) else {
            facts += " restore=skipped-owner"
            return false
        }
        // POST-AWAIT immediately before the preferences mutation and the
        // engine-visible apply.
        guard restoreOwnerCurrent(preferences, session: session, controller: controller),
              session.canAct else {
            facts += " restore=skipped-owner"
            return false
        }
        preferences.setPreset(stroke.preset)
        preferences.setColorHex(stroke.colorHex)
        preferences.setWidthMillimeters(stroke.widthMillimeters)
        preferences.setTransparencyPercent(stroke.transparencyPercent)
        await session.applyInkPreferences()
        // POST-APPLY / POST-AWAIT: the apply can suspend; re-read the Swift
        // owner before the page verification and again after it.
        guard restoreOwnerCurrent(preferences, session: session, controller: controller) else {
            facts += " restore=lost-after-apply"
            return false
        }
        guard await ownerBindingIntact(web: web, ownerToken: ownerToken) else {
            facts += " restore=lost-after-apply"
            return false
        }
        guard restoreOwnerCurrent(preferences, session: session, controller: controller) else {
            facts += " restore=lost-after-apply"
            return false
        }
        facts += session.inkError == nil ? " restore=ok" : " restore=unverified"
        return true
    }

    /// Bounded, content-free receipt summary: counters and booleans only.
    /// Never a path, never document text, never a raw coordinate beyond the
    /// fixture band's own rounded client numbers.
    private static func redactedFacts(_ receipt: [String: Any]) -> String {
        var parts: [String] = []
        if let value = receipt["strokesDelta"] as? Int { parts.append("strokes=+\(value)") }
        if let value = receipt["coreEventDelta"] as? Int { parts.append("core=+\(value)") }
        if (receipt["fenceHeld"] as? Bool) == true { parts.append("fence=9/9") }
        if (receipt["bridgeActiveObserved"] as? Bool) == true { parts.append("bridgeActive=1") }
        if (receipt["bridgePreviewFlagObserved"] as? Bool) == true { parts.append("bridgePreviewFlag=1") }
        if let reason = receipt["reason"] as? String { parts.append("reason=\(reason.prefix(48))") }
        return parts.joined(separator: " ")
    }

    // MARK: - Scripts

    /// Capture ONCE, at ownership establishment. Verified against the exact
    /// bundled engine (`browserBundleSHA256` b95ed4e6…): it exposes no
    /// `getDocumentName`/`_docName`; a local-kit mount binds its live document
    /// through `app.map.options.doc` (the canonical local `file_path` the
    /// controller loaded), the engine's own backing permission
    /// `app.file.readOnly`, the current `map._docLayer`, and the host's frozen
    /// per-mount facts (`window.__floeOfficeSession`) built from THIS
    /// controller's staged working copy. The document path is compared as ONE
    /// exact canonical local-path equality against the private
    /// `expectedDocPath` argument (remote or synthetic protocols, traversal,
    /// empty or duplicated segments, query suffixes and percent-encoding are
    /// canonicalized or rejected; prefixes, suffixes and deeper unrelated
    /// paths never match). On success it installs the immutable in-page
    /// binding holding the EXACT live app/map/docLayer/file/mount/canvas
    /// references, the exact raw document string and this run's owner token.
    /// It returns only a fixed reason code — never a path, name, token,
    /// document text or error text — and fails closed at the call site.
    private static let ownerCaptureScript = #"""
    return (() => {
        const canonicalLocalPath = (raw) => {
            if (typeof raw !== 'string' || !raw) return null;
            let s = raw;
            const cut = s.search(/[?#]/);
            if (cut !== -1) s = s.slice(0, cut);
            s = s.replace(/^file:\/\/(localhost)?/i, '');
            if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(s) || s.indexOf('://') !== -1) return null;
            if (s.charCodeAt(0) !== 47) return null;
            try { s = decodeURIComponent(s); } catch (_) { return null; }
            const segments = s.split('/');
            if (segments[0] !== '') return null;
            for (let i = 1; i < segments.length; ++i) {
                const seg = segments[i];
                if (!seg || seg === '.' || seg === '..') return null;
            }
            return s.length > 1 && s.length <= 4096 ? s : null;
        };

        const code = (ok, reason) => ({ v: true, ok, code: reason });
        try {
            if (typeof ownerToken !== 'string'
                || !/^floe-ink-owner-[A-Za-z0-9-]{8,64}$/.test(ownerToken))
                return code(false, 'probe-arguments-invalid');
            if (typeof expectedDocPath !== 'string' || expectedDocPath.charCodeAt(0) !== 47
                || expectedDocPath.length <= 1 || expectedDocPath.length > 4096
                || expectedDocPath.indexOf('://') !== -1
                || /\.{2,}/.test(expectedDocPath) || /\/{2,}/.test(expectedDocPath))
                return code(false, 'probe-arguments-invalid');
            // One fixture run at a time on this page. A live lease or a live
            // binding from another run is never overwritten.
            if (window.__floeInkFixtureLease !== undefined
                && window.__floeInkFixtureLease !== null)
                return code(false, 'owner-binding-busy');
            if (window.__floeInkFixtureOwner !== undefined
                && window.__floeInkFixtureOwner !== null)
                return code(false, 'owner-binding-busy');
            const slash = expectedDocPath.lastIndexOf('/');
            const expectedLeaf = slash > 0 ? expectedDocPath.slice(slash + 1) : '';
            if (!expectedLeaf) return code(false, 'probe-arguments-invalid');
            const mount = window.__floeOfficeSession;
            if (!mount || typeof mount !== 'object') return code(false, 'host-facts-absent');
            if (mount.fileName !== expectedLeaf) return code(false, 'host-name-mismatch');
            const dot = expectedLeaf.lastIndexOf('.');
            const expectedExtension = dot >= 0 ? expectedLeaf.slice(dot + 1).toLowerCase() : '';
            if (typeof mount.extension !== 'string'
                || (expectedExtension && mount.extension !== expectedExtension))
                return code(false, 'host-extension-mismatch');
            if (mount.editable !== true || mount.readOnly !== false)
                return code(false, 'host-mount-not-editable');
            const app = window.app;
            if (!app) return code(false, 'engine-app-unavailable');
            if (!app.file || typeof app.file.readOnly !== 'boolean')
                return code(false, 'engine-backend-unknown');
            if (app.file.readOnly === true) return code(false, 'engine-backend-readonly');
            const map = app.map;
            if (!map) return code(false, 'engine-map-unavailable');
            const docLayer = map._docLayer;
            if (!docLayer) return code(false, 'engine-document-unloaded');
            const options = map.options;
            const raw = options ? options.doc : undefined;
            if (typeof raw !== 'string' || !raw) return code(false, 'engine-document-unloaded');
            const canonical = canonicalLocalPath(raw);
            if (!canonical || canonical !== expectedDocPath)
                return code(false, 'engine-document-identity-mismatch');
            const container = app.sectionContainer;
            const canvas = container && container.canvas;
            if (!canvas || typeof canvas !== 'object')
                return code(false, 'canvas-unavailable');
            if (canvas.isConnected !== true) return code(false, 'canvas-disconnected');
            window.__floeInkFixtureOwner = Object.freeze({
                v: 1,
                token: ownerToken,
                app: app,
                map: map,
                docLayer: docLayer,
                file: app.file,
                mount: mount,
                mountName: mount.fileName,
                mountExtension: mount.extension,
                canvas: canvas,
                options: options,
                docRaw: raw
            });
            return code(true, 'ok');
        } catch (_) {
            return code(false, 'probe-threw');
        }
    })()
    """#

    /// Compare the CURRENT page to the binding captured ONCE above. This is a
    /// reference/string identity comparison, not a semantic path probe: every
    /// captured object must still be the same live object and the raw document
    /// string must still be exactly the same. A same-value copied object at
    /// the same path is therefore a LOST owner, not a pass. Returns only a
    /// fixed code.
    private static let ownerVerifyScript = #"""
    return (() => {
        const code = (ok, reason) => ({ v: true, ok, code: reason });
        try {
            if (typeof ownerToken !== 'string'
                || !/^floe-ink-owner-[A-Za-z0-9-]{8,64}$/.test(ownerToken))
                return code(false, 'probe-arguments-invalid');
            const binding = window.__floeInkFixtureOwner;
            if (!binding || typeof binding !== 'object')
                return code(false, 'owner-binding-absent');
            if (binding.v !== 1 || binding.token !== ownerToken)
                return code(false, 'owner-binding-token-mismatch');
            const app = window.app;
            if (!app) return code(false, 'engine-app-unavailable');
            if (app !== binding.app) return code(false, 'owner-app-replaced');
            if (app.map !== binding.map) return code(false, 'owner-map-replaced');
            if (!binding.map || binding.map._docLayer !== binding.docLayer)
                return code(false, 'owner-doc-layer-replaced');
            const file = app.file;
            if (!file || file !== binding.file) return code(false, 'owner-backend-replaced');
            if (file.readOnly !== false) return code(false, 'engine-backend-readonly');
            const mount = window.__floeOfficeSession;
            if (!mount || mount !== binding.mount) return code(false, 'owner-mount-replaced');
            if (mount.fileName !== binding.mountName
                || mount.extension !== binding.mountExtension)
                return code(false, 'owner-mount-replaced');
            if (mount.editable !== true || mount.readOnly !== false)
                return code(false, 'host-mount-not-editable');
            if (!binding.canvas || binding.canvas.isConnected !== true)
                return code(false, 'owner-canvas-disconnected');
            const container = app.sectionContainer;
            if (!container || container.canvas !== binding.canvas)
                return code(false, 'owner-canvas-replaced');
            const options = binding.map.options;
            if (!options || options !== binding.options || typeof options.doc !== 'string'
                || options.doc !== binding.docRaw)
                return code(false, 'owner-doc-binding-replaced');
            return code(true, 'ok');
        } catch (_) {
            return code(false, 'probe-threw');
        }
    })()
    """#

    /// Release ONLY this run's token. A later owner token is never touched,
    /// and the lease is cleared only when it belongs to this exact owner.
    private static let releaseOwnerBindingScript = #"""
    (() => {
        const binding = window.__floeInkFixtureOwner;
        if (!binding || binding.token !== ownerToken) return 'foreign';
        window.__floeInkFixtureOwner = null;
        if (window.__floeInkFixtureLeaseOwner === ownerToken) {
            window.__floeInkFixtureLease = null;
            window.__floeInkFixtureLeaseOwner = null;
        }
        return 'released';
    })()
    """#

    /// EXACTLY one labeled synthetic pen contact: one pointerdown, seven
    /// pointermoves and one pointerup at a real arc inside the actual visible
    /// document rectangle, dispatched on the CAPTURED document canvas so the
    /// production window-capture gate installed by FloeOfficeNative owns the
    /// contact. NO overlay substitute, NO preview-only shape, NO SVG/bitmap
    /// injection, NO second contact. Owner fencing never captures new values:
    /// it requires the exact capture-once binding (same owner token and the
    /// same app/map/docLayer/file/mount/canvas object references plus the
    /// exact raw document string), takes the in-page lease bound to that
    /// owner token, and revalidates binding + lease + armed drawing BEFORE
    /// EACH of the nine events; every one of the nine dispatch points is
    /// probed with the engine's own hit test before the contact begins. The
    /// lease is released at the end, but the owner binding is intentionally
    /// left installed so the caller's restore hops can keep fencing on it.
    /// `bridgeActiveObserved` and `bridgePreviewFlagObserved` are bridge
    /// state flags recorded during the contact — bookkeeping that the
    /// production gate owned the contact, not painted-frame proof.
    private static let curveScript = #"""
    const ownerTokenValid = typeof ownerToken === 'string'
        && /^floe-ink-owner-[A-Za-z0-9-]{8,64}$/.test(ownerToken);
    const leaseValid = typeof lease === 'string' && lease.length > 0 && lease.length <= 80
        && /^floe-ink-fixture-[A-Za-z0-9_-]+$/.test(lease);
    if (!ownerTokenValid || !leaseValid
        || typeof window.PointerEvent !== 'function'
        || typeof window.__floeOfficePenState !== 'function')
        throw new Error('production pen bridge or captured owner binding unavailable');
    const binding = window.__floeInkFixtureOwner;
    const bindingIntact = () => {
        try {
            if (!binding || typeof binding !== 'object') return false;
            if (window.__floeInkFixtureOwner !== binding) return false;
            if (binding.v !== 1 || binding.token !== ownerToken) return false;
            const liveApp = window.app;
            if (!liveApp || liveApp !== binding.app) return false;
            if (!binding.map || liveApp.map !== binding.map) return false;
            if (binding.map._docLayer !== binding.docLayer) return false;
            if (!binding.file || liveApp.file !== binding.file) return false;
            if (binding.file.readOnly !== false) return false;
            if (!binding.mount || window.__floeOfficeSession !== binding.mount) return false;
            if (binding.mount.fileName !== binding.mountName
                || binding.mount.extension !== binding.mountExtension) return false;
            if (binding.mount.editable !== true || binding.mount.readOnly !== false) return false;
            if (!binding.canvas || binding.canvas.isConnected !== true) return false;
            const liveContainer = liveApp.sectionContainer;
            if (!liveContainer || liveContainer.canvas !== binding.canvas) return false;
            const options = binding.map.options;
            if (!options || options !== binding.options || typeof options.doc !== 'string'
                || options.doc !== binding.docRaw) return false;
            return true;
        } catch (_) { return false; }
    };
    const bindingLostReceipt = (phase) => JSON.stringify({
        routeReady: false, reason: 'owner-fence-lost', phase,
        eventsDispatched: 0, movesDispatched: 0
    });
    if (!bindingIntact()) return bindingLostReceipt('owner-binding');
    const app = binding.app;
    const canvas = binding.canvas;
    const container = app.sectionContainer;
    const layout = app.activeDocument && app.activeDocument.activeLayout;
    const size = app.activeDocument && app.activeDocument.fileSize;
    if (!container || typeof container.getDocumentAnchorSection !== 'function'
        || !layout || !size)
        throw new Error('production pen bridge or native document canvas unavailable');
    const before = window.__floeOfficePenState();
    if (before.drawing !== true)
        return JSON.stringify({ routeReady: false, reason: 'drawing-not-armed' });
    if (before.activeStroke === true)
        return JSON.stringify({ routeReady: false, reason: 'previous-active-stroke' });
    // Take the single in-page fixture lease. A second concurrent fixture can
    // never run in this page while the lease is held, and any later script
    // that does not present the same owner token stops immediately.
    if (window.__floeInkFixtureLease !== undefined && window.__floeInkFixtureLease !== null)
        return JSON.stringify({ routeReady: false, reason: 'fixture-lease-busy' });
    window.__floeInkFixtureLease = lease;
    window.__floeInkFixtureLeaseOwner = ownerToken;
    let eventsDispatched = 0;
    let movesDispatched = 0;
    const releaseLease = () => {
        if (window.__floeInkFixtureLease === lease
            && window.__floeInkFixtureLeaseOwner === ownerToken) {
            window.__floeInkFixtureLease = null;
            window.__floeInkFixtureLeaseOwner = null;
        }
    };
    // Per-event owner fence: the CAPTURED live identity — the same
    // window.app object, same map object, same live document layer, same
    // backend permission object still reporting editability, same frozen
    // host mount-facts object, same canvas node and exact raw document
    // string — not a post-hoc Swift check and never a fresh semantic probe.
    // A navigation, document swap, permission relaxation, copied object,
    // teardown, drawing disarm or lease/owner loss stops the script at the
    // affected event.
    const fenceHolds = () => {
        try {
            if (window.__floeInkFixtureLease !== lease) return false;
            if (window.__floeInkFixtureLeaseOwner !== ownerToken) return false;
            if (!bindingIntact()) return false;
            const state = window.__floeOfficePenState();
            if (state.drawing !== true) return false;
            return true;
        } catch (_) { return false; }
    };
    const round2 = (value) => Math.round(value * 100) / 100;
    const lostReceipt = (phase) => {
        releaseLease();
        return JSON.stringify({ routeReady: false, reason: 'owner-fence-lost', phase,
                                eventsDispatched, movesDispatched });
    };
    const rect = canvas.getBoundingClientRect();
    const section = container.getDocumentAnchorSection();
    const scaleX = rect.width / canvas.width, scaleY = rect.height / canvas.height;
    if (!section || !section.myTopLeft || !section.size
        || !Number.isFinite(scaleX) || !Number.isFinite(scaleY)) {
        releaseLease();
        return JSON.stringify({ routeReady: false, reason: 'document-geometry-unavailable' });
    }
    const origin = size.clone(); origin.pX = 0; origin.pY = 0;
    const end = size.clone();
    const dx1 = layout.documentToViewX(origin), dy1 = layout.documentToViewY(origin);
    const dx2 = layout.documentToViewX(end), dy2 = layout.documentToViewY(end);
    const x1 = rect.left + Math.max(0, section.myTopLeft[0], Math.min(dx1, dx2)) * scaleX;
    const y1 = rect.top + Math.max(0, section.myTopLeft[1], Math.min(dy1, dy2)) * scaleY;
    const x2 = rect.left + Math.min(canvas.width, section.myTopLeft[0] + section.size[0], Math.max(dx1, dx2)) * scaleX;
    const y2 = rect.top + Math.min(canvas.height, section.myTopLeft[1] + section.size[1], Math.max(dy1, dy2)) * scaleY;
    if (![x1, y1, x2, y2].every(Number.isFinite) || x2 - x1 < 240 || y2 - y1 < 160) {
        releaseLease();
        return JSON.stringify({ routeReady: false, reason: 'visible-document-area-too-small' });
    }
    const hitIsCanvas = (px, py) => {
        try {
            const hit = document.elementFromPoint(px, py);
            return !!hit && (hit === canvas || canvas.contains(hit));
        } catch (_) { return false; }
    };
    // Real layout-fraction candidates. A candidate is usable only when ALL
    // NINE actual dispatch points (down, seven moves, up) hit inside the
    // document canvas and the band stays inside the visible rectangle —
    // nothing dispatches outside a probed point.
    const candidates = [[0.50, 0.62], [0.44, 0.70], [0.55, 0.55], [0.40, 0.58], [0.58, 0.68]];
    let chosen = null;
    for (const [fx, fy] of candidates) {
        if (!fenceHolds()) return lostReceipt('candidate-scan');
        const x = x1 + fx * (x2 - x1), y = y1 + fy * (y2 - y1);
        const length = Math.min(140, (x2 - x1) * 0.30);
        const amplitude = Math.min(28, (y2 - y1) * 0.10);
        const endY = y + Math.sin(3.5) * amplitude;
        if (x + length > x2 - 8 || y + amplitude > y2 - 8) continue;
        const points = [[x, y]];
        for (let i = 1; i <= 7; ++i) {
            const px = x + i * length / 7;
            const py = i === 7 ? endY : y + Math.sin(i / 2.0) * amplitude;
            points.push([px, py]);
        }
        points.push([x + length, endY]);
        if (points.length !== 9) { releaseLease(); return JSON.stringify({ routeReady: false, reason: 'curve-point-count-defect' }); }
        if (points.every(([px, py]) => hitIsCanvas(px, py))) {
            chosen = { x, y, length, amplitude, endY, points };
            break;
        }
    }
    if (!chosen) {
        releaseLease();
        return JSON.stringify({ routeReady: false, reason: 'no-clean-canvas-curve-band' });
    }
    const pointerId = 971;
    const send = (type, px, py, buttons) => canvas.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, pointerType: 'pen', pointerId,
        isPrimary: true, clientX: px, clientY: py, button: 0, buttons,
        pressure: buttons ? 0.5 : 0 }));
    let bridgeActiveObserved = false;
    let bridgePreviewFlagObserved = false;
    if (!fenceHolds()) return lostReceipt('pre-down');
    send('pointerdown', chosen.points[0][0], chosen.points[0][1], 1);
    eventsDispatched += 1;
    {
        const state = window.__floeOfficePenState();
        if (state.activeStroke === true) bridgeActiveObserved = true;
        if (state.livePreview === true) bridgePreviewFlagObserved = true;
    }
    await new Promise(resolve => setTimeout(resolve, 40));
    for (let i = 1; i <= 7; ++i) {
        if (!fenceHolds()) return lostReceipt('move-' + i);
        send('pointermove', chosen.points[i][0], chosen.points[i][1], 1);
        eventsDispatched += 1;
        movesDispatched += 1;
        await new Promise(resolve => setTimeout(resolve, 30));
        const state = window.__floeOfficePenState();
        if (state.activeStroke === true) bridgeActiveObserved = true;
        if (state.livePreview === true) bridgePreviewFlagObserved = true;
    }
    if (!fenceHolds()) return lostReceipt('pre-up');
    const upPoint = chosen.points[8];
    send('pointerup', upPoint[0], upPoint[1], 0);
    eventsDispatched += 1;
    const after = window.__floeOfficePenState();
    if (!bindingIntact()) return lostReceipt('post-up');
    releaseLease();
    return JSON.stringify({
        routeReady: true, label: 'office-ink-card-fixture-pen-curve',
        ownerBindingHeld: true,
        fenceHeld: eventsDispatched === 9 && movesDispatched === 7 && after.activeStroke === false,
        pointsProbed: 9, eventsDispatched, movesDispatched, pointerId,
        strokesDelta: after.strokes - before.strokes,
        coreEventDelta: after.coreEvents - before.coreEvents,
        activeAfterUp: after.activeStroke === true,
        bridgeActiveObserved, bridgePreviewFlagObserved,
        band: { x: round2(chosen.x), y: round2(chosen.y), length: round2(chosen.length) },
        pressureSource: 'synthetic-known-finite'
    });
    """#
}

/// The gated fixture controls. Mounted by a one-line DEBUG hunk inside the
/// existing `OfficeDocumentSurface` ZStack; invisible unless the ink-card
/// launch family is armed AND THIS mounted session is currently the editable
/// drawing-ready editor. Tapping the control runs the one-shot seam; the
/// status/facts nodes are the bounded readiness surface the UI test polls.
/// Unmounting cancels the owned run task.
struct OfficeInkCardSeamOverlay: View {
    @ObservedObject var session: OfficeFileSession

    var body: some View {
        OfficeInkCardSeamContent(session: session)
    }
}

private struct OfficeInkCardSeamContent: View {
    @ObservedObject var session: OfficeFileSession
    @StateObject private var model = OfficeInkCardSeamModel()

    var body: some View {
        // Armed only by the explicit launch family; ordinary and release
        // runs never render anything here.
        if OfficeInkCardLoopFixture.isArmed,
           !session.readOnly, session.documentActionsReady, session.drawingMode {
            VStack(alignment: .trailing, spacing: 6) {
                Button("注入一笔（夹具）") {
                    model.start(session: session)
                }
                .font(.footnote)
                .disabled(model.busy)
                .accessibilityIdentifier("office.ink-fixture.inject")
                Text(model.status)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .accessibilityIdentifier("office.ink-fixture.status")
                    .accessibilityValue(model.status)
                Text(model.facts)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .accessibilityIdentifier("office.ink-fixture.facts")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            // The seam is a ZStack child: pin it to the bottom-trailing
            // corner without stretching the editor surface hit-testing.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 12)
            .padding(.bottom, 96)
            .onDisappear { model.invalidate() }
        }
    }
}
#endif
