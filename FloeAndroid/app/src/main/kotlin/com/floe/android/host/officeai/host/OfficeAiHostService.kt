// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.core.officeengine.OfficeEngineCommandsPolicy
import com.floe.android.core.officeengine.OfficeSaveFailureCode
import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveRequest
import com.floe.android.core.officeengine.OfficeSaveState
import com.floe.android.core.officeengine.precision.OfficePrecisionAnswer
import com.floe.android.core.officeengine.precision.OfficePrecisionContentKind
import com.floe.android.core.officeengine.precision.OfficePrecisionContentReadback
import com.floe.android.core.officeengine.precision.OfficePrecisionRequest
import com.floe.android.core.officeengine.precision.OfficePrecisionResult
import com.floe.android.core.officeengine.precision.OfficePrecisionState
import com.floe.android.host.OfficePreviewController
import com.floe.android.host.WorkspaceOfficeSnapshotStager
import com.floe.android.host.WorkspaceSourceResult
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/** An immutable pre-edit baseline retained at capture (bytes copied from
 * the ACTUAL current flushed working copy, digest bound to the capture
 * attestation, never the initial immutable source snapshot hash). */
internal data class OfficeAiRetainedBaseline(val file: File, val sha256: String, val bytes: Long)

/** Engine facts for one exact session token + native mount generation. */
internal data class OfficeAiEngineEditFacts(
    val stateName: String?,
    val editPermissionEstablished: Boolean,
)

/**
 * The capability ports the Office AI host service executes against. Every
 * production implementation is a NARROW join onto the EXISTING owned objects
 * (never a parallel controller, client, gateway or second Save-Copy
 * instance): [com.floe.android.host.OfficePreviewController] for the owned
 * operation and owner-safe open, the one application-owned
 * [com.floe.android.host.OfficeSaveCopyHost] for the engine generation /
 * edit state / transaction-20 save submit + its OWNED receipt observer, the
 * typed [com.floe.android.host.OfficePrecisionClient] for P-A commands, and
 * the [com.floe.android.host.WorkspaceSourceHostController] headless
 * runtime-owned lane for the provider journal ladder. Fakes drive the same
 * production service in the JVM regressions.
 */
internal interface OfficeAiDocumentPorts {
    // ---- owned operation joins (OfficePreviewController) ----
    fun ownedSnapshot(taskID: String, workspaceID: String?, nativeEpoch: String): OfficePreviewController.OwnedOperationSnapshot?
    fun viewerDisplayName(): String?
    fun isDocumentSlotBusy(): Boolean
    fun openWorkspace(owner: WorkspaceOfficeSnapshotStager.Owner, logicalPath: String, ownerCurrent: () -> Boolean)
    fun openAdmissionError(): String?

    // ---- TRANSIENT launch admission (Main host20 final review) ----
    // These joins gate ONLY the window from a NEW launch request until the
    // viewer actually CLAIMS (never the durable document-owner fence, which
    // must survive MainActivity pause into the Office viewer, and never a
    // later snapshot return): the ACTUAL MainActivity resume/pause projection,
    // the pending platform picker slot, the exact visible conversation the
    // shell reports, the shell's modal projection (Settings/preview Dialog
    // and drawer — the privacy holder does NOT clear under the Dialog, so the
    // visible-chat fact alone cannot prove no modal), the controller's own
    // VIEWING-phase flip (after which transient admission is NEVER consulted
    // again), and the existing explicit-cancel lane used to retire only an
    // UNCLAIMED launch when the transient facts break during staging.
    fun isApplicationForeground(): Boolean
    fun isPlatformPickerPending(): Boolean
    fun isConversationCurrentlyVisible(taskID: String): Boolean
    fun isModalSurfaceOwned(): Boolean
    fun isOwnedOperationViewing(taskID: String, workspaceID: String, nativeEpoch: String): Boolean
    /** Owner-checked retirement of ONLY this exact owner's still-unclaimed
     * launch through the controller's existing explicit-cancel lane; another
     * surface's operation and any VIEWING document are never touched. */
    fun cancelUnclaimedLaunch(taskID: String, workspaceID: String, nativeEpoch: String)

    // ---- the SAME existing Save-Copy host instance ----
    fun engineGeneration(sessionToken: String): Long
    fun engineEditState(sessionToken: String, generation: Long): OfficeAiEngineEditFacts?
    /** Typed, dispatch-proof submit result (Main final review): NotBound
     * proves nothing was sent; AttemptedWithoutReply must resolve through the
     * registered receipt waiter or stay UNKNOWN/retained — never a re-send. */
    fun saveSubmit(request: OfficeSaveRequest): OfficeAiSaveSubmit
    fun attachSaveReceiptObserver(observer: (OfficeSaveReceipt) -> Unit)
    fun detachSaveReceiptObserver()

    // ---- typed P-A precision client ----
    suspend fun precision(request: OfficePrecisionRequest, deadlineMs: Long): OfficePrecisionResult

    // ---- headless runtime-owned provider lane ----
    suspend fun pushOriginalViaHeadlessLane(
        taskID: String, workspaceID: String, nativeEpoch: Long, hostGeneration: Long,
        logicalPath: String, ownerFence: () -> Boolean,
    ): WorkspaceSourceResult?

    // ---- owner/context + host file roots ----
    fun currentNativeEpoch(): Long?
    fun commandGeneration(): Long
    fun isOwnedOrdinaryTask(taskID: String): Boolean
    fun appDataRoot(): File?
    fun outputsRoot(): File
    fun baselineRoot(): File
    fun elapsedMs(): Long

    /** Lane teardown hook (production: release this lane's own precision
     * client connection only). */
    fun releaseTransports() = Unit
}

/** Tunable wait budgets; production defaults stay inside the Swift mailbox
 * per-operation budgets (open 150 s, command 120 s, save 180 s, verify
 * 120 s, reconcile 60 s, pushOriginal 300 s). */
internal class OfficeAiTiming(
    val openPollMillis: Long = 200L,
    val openWaitMillis: Long = 145_000L,
    val commandDeadlineMillis: Long = 110_000L,
    val flushWaitMillis: Long = 60_000L,
    val exportWaitMillis: Long = 150_000L,
    val maxWorkingCopyBytes: Long = 256L * 1024 * 1024,
)

/**
 * Executes one already-parsed ticket and produces exactly ONE settlement.
 * The pump owns serialization, NonCancellable execution and stop rechecks;
 * this service owns the per-operation fences and the honest typed facts.
 */
internal class OfficeAiHostService(
    private val epoch: Long,
    private val ports: OfficeAiDocumentPorts,
    private val binds: SessionBinds,
    private val captures: CaptureStore,
    private val effects: EffectLedger,
    private val selections: SelectionLedger,
    private val saveWaiters: SaveWaiters,
    private val verifier: OfficeAiSavedPackageVerifier,
    private val timing: OfficeAiTiming = OfficeAiTiming(),
) {
    private val epochText get() = epoch.toString()

    suspend fun execute(
        ticket: OfficeAiWire.Ticket,
        staged: ByteArray,
        stopSignal: () -> Boolean,
    ): OfficeAiWire.Settlement = try {
        when (ticket.operation) {
            "office.lookup" -> lookup(ticket)
            "office.open" -> open(ticket)
            "office.command" -> command(ticket, staged, stopSignal)
            "office.save" -> save(ticket, stopSignal)
            "office.verify" -> verify(ticket, staged)
            "office.reconcile" -> reconcile(ticket)
            "office.pushOriginal" -> pushOriginal(ticket, stopSignal)
            else -> OfficeAiWire.failureReply("internal", "unreachable operation")
        }
    } catch (refusal: OfficeAiWire.Refusal) {
        OfficeAiWire.failureReply(refusal.code, refusal.detail)
    } catch (cancellation: kotlinx.coroutines.CancellationException) {
        throw cancellation
    } catch (unexpected: Throwable) {
        // Identity-safe only: class name, never message/paths/content.
        OfficeAiWire.failureReply("internal", unexpected.javaClass.simpleName.take(64))
    }

    // ------------------------------------------------------------------
    // lookup / open
    // ------------------------------------------------------------------

    private suspend fun lookup(ticket: OfficeAiWire.Ticket): OfficeAiWire.Settlement {
        val taskID = ticket.required("taskID")
        val workspaceID = if (ticket.required("workspacePresent") == "exact") ticket.required("workspaceID") else null
        val snapshot = ports.ownedSnapshot(taskID, workspaceID, ticket.required("nativeEpoch"))
            ?: return OfficeAiWire.failureReply("noOwnedDocument",
                "the exact owner/workspace/epoch does not name a live owned Office operation")
        return documentSettlement(snapshot, openedNow = false, bind = true)
    }

    private suspend fun open(ticket: OfficeAiWire.Ticket): OfficeAiWire.Settlement {
        val taskID = ticket.required("taskID")
        val workspaceID = ticket.required("workspaceID")
        val path = ticket.required("logicalPath")
        // Re-run the owned fence first and RETURN the existing operation.
        ports.ownedSnapshot(taskID, workspaceID, epochText)?.let { existing ->
            return documentSettlement(existing, openedNow = false, bind = true)
        }
        if (ports.isDocumentSlotBusy()) {
            return OfficeAiWire.failureReply("busy", "another document owns the single viewer slot")
        }
        if (!ports.isOwnedOrdinaryTask(taskID)) {
            return OfficeAiWire.failureReply("notOwner",
                "the requesting conversation is not a live ordinary (non-temporary) task")
        }
        // Transient launch admission (Main final review): a NEW viewer launch
        // needs the App ACTUALLY foreground, no platform picker holding the
        // foreground lane, THIS conversation as the visible one, and NO
        // Settings/preview/drawer modal owning the shell (the privacy visible
        // holder stays bound under the Dialog, so the modal projection is a
        // separate real fact — and every one of these is read from an actual
        // production hook, never inferred from the root epoch). None of them
        // joins the durable owner fence below.
        if (!transientLaunchAdmissionOk(taskID)) {
            return transientLaunchRefusal()
        }
        if (ports.currentNativeEpoch() != epoch) return OfficeAiWire.failureReply("generationFenced")
        val hostGeneration = ports.commandGeneration()
        val owner = runCatching {
            WorkspaceOfficeSnapshotStager.Owner(taskID, workspaceID, epoch, hostGeneration)
        }.getOrNull() ?: return OfficeAiWire.failureReply("notOwner", "owner identity refused by the stager")
        // Long-lived document-owner fence (the exact WorkspaceFilesPane
        // rule): root epoch + App command generation + the task's ordinary
        // conversation. Pane navigation is deliberately NOT part of it —
        // a transient viewer/pane event must never invalidate an
        // otherwise-owned VIEWING document, and the open ticket's own
        // settlement never revokes ownership.
        val ownerCurrent = {
            ports.currentNativeEpoch() == epoch &&
                ports.commandGeneration() == hostGeneration &&
                ports.isOwnedOrdinaryTask(taskID)
        }
        ports.openWorkspace(owner, path, ownerCurrent)
        // Await the SAME owned operation + real engine readiness, bounded.
        // The transient admission is CARRIED through staging and the final
        // UI claim (Main review continuation): until the operation reaches
        // the VIEWING phase, a foreground/modal/visible-chat change retires
        // ONLY the unclaimed launch through the controller's existing
        // explicit-cancel lane; the instant the claim has actually happened,
        // transient admission stops being consulted entirely, so the
        // imminent MainActivity pause under the viewer can never revoke the
        // owned viewing document.
        val deadline = ports.elapsedMs() + timing.openWaitMillis
        while (ports.elapsedMs() < deadline) {
            val snapshot = ports.ownedSnapshot(taskID, workspaceID, epochText)
            if (snapshot != null) {
                if (!ports.isOwnedOperationViewing(taskID, workspaceID, epochText) &&
                    !transientLaunchAdmissionOk(taskID)
                ) {
                    // Still pre-claim (LAUNCH awaiting the effect) and the
                    // transient facts broke: retire the UNCLAIMED launch.
                    ports.cancelUnclaimedLaunch(taskID, workspaceID, epochText)
                    return OfficeAiWire.failureReply("sessionEnding",
                        "the foreground surface changed before the viewer claim; the unclaimed launch was retired")
                }
                val generation = ports.engineGeneration(snapshot.sessionToken)
                val edit = if (generation >= 1) ports.engineEditState(snapshot.sessionToken, generation) else null
                if (generation >= 1 && edit?.stateName == "READY_EDITABLE" &&
                    edit.editPermissionEstablished
                ) {
                    return documentSettlement(snapshot, openedNow = true, bind = true)
                }
                delay(timing.openPollMillis)
                continue
            }
            val error = ports.openAdmissionError()
            if (error != null) {
                return openAdmissionFailure(error)
            }
            if (!transientLaunchAdmissionOk(taskID)) {
                // Staging in flight with no owned operation yet: cancel ONLY
                // this owner's unclaimed staged launch (owner-checked; a
                // replaced operation is never touched).
                ports.cancelUnclaimedLaunch(taskID, workspaceID, epochText)
                return OfficeAiWire.failureReply("sessionEnding",
                    "the foreground surface changed during staging; the unclaimed launch was retired")
            }
            delay(timing.openPollMillis)
        }
        // Honest timeout: the viewer may now show the document; nothing is
        // torn down by force here.
        return OfficeAiWire.failureReply("engineNotReady",
            "the owned operation did not reach real engine edit readiness in the bounded window")
    }

    /** The transient admission facts, re-read (cheap volatile projections):
     * foreground + free picker lane + THIS visible chat + no modal surface. */
    private fun transientLaunchAdmissionOk(taskID: String): Boolean =
        ports.isApplicationForeground() &&
            !ports.isPlatformPickerPending() &&
            ports.isConversationCurrentlyVisible(taskID) &&
            !ports.isModalSurfaceOwned()

    /** Typed honest refusal for whichever transient fact broke. */
    private fun transientLaunchRefusal(): OfficeAiWire.Settlement {
        if (!ports.isApplicationForeground()) {
            return OfficeAiWire.failureReply("notOwner",
                "the App is not foregrounded; a new Office viewer launch was refused (no background launch, no surface steal)")
        }
        if (ports.isPlatformPickerPending()) {
            return OfficeAiWire.failureReply("busy",
                "a system picker owns the foreground lane; the Office open was refused without disturbing it")
        }
        if (ports.isModalSurfaceOwned()) {
            return OfficeAiWire.failureReply("busy",
                "a settings/preview/modal surface owns the shell; the Office open was refused without disturbing it")
        }
        return OfficeAiWire.failureReply("notOwner",
            "another conversation is currently visible; the open was refused without foreground stealing")
    }

    private fun openAdmissionFailure(error: String): OfficeAiWire.Settlement = when (error) {
        "owner" -> OfficeAiWire.failureReply("notOwner", "the foreground owner changed before the viewer launch")
        "busy" -> OfficeAiWire.failureReply("busy")
        "format" -> OfficeAiWire.failureReply("unsupportedFamily")
        "tooLarge" -> OfficeAiWire.failureReply("requestTooLarge", "the workspace document is too large")
        "viewer" -> OfficeAiWire.failureReply("engineNotReady", "the viewer launch was refused by the platform")
        else -> OfficeAiWire.failureReply("internal", "workspace source staging failed")
    }

    /** Build the lookup-shape success reply from a fresh owned snapshot and
     * the ENGINE's own generation/edit facts (never App-side optimism), and
     * upsert the session bind used by later command/save/verify rejoins. */
    private fun documentSettlement(
        snapshot: OfficePreviewController.OwnedOperationSnapshot,
        openedNow: Boolean,
        bind: Boolean,
    ): OfficeAiWire.Settlement {
        val format = snapshot.stagedWorkingCopyPath
            ?.substringAfterLast('.', "")?.lowercase(Locale.ROOT)
            ?.takeIf { it in OfficeAiWire.EXPORT_FORMATS }
            ?: return OfficeAiWire.failureReply("unsupportedFamily",
                "the owned working copy is not an OOXML family")
        val generation = ports.engineGeneration(snapshot.sessionToken)
        if (generation < 1) {
            return OfficeAiWire.failureReply("engineNotReady", "no live engine generation for the session")
        }
        val edit = ports.engineEditState(snapshot.sessionToken, generation)
        val displayName = ports.viewerDisplayName()
            ?: snapshot.sourceLogicalPath?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
            ?: "office-document.$format"
        if (bind) {
            binds.bind(OfficeAiSessionBind(
                sessionToken = snapshot.sessionToken,
                nativeGeneration = generation,
                ownerTaskID = snapshot.ownerTaskId ?: "",
                workspaceID = snapshot.workspaceId,
                nativeEpoch = epoch,
                viewerIncarnation = snapshot.viewerIncarnation,
                sourceLogicalPath = snapshot.sourceLogicalPath,
                stagedWorkingCopyPath = snapshot.stagedWorkingCopyPath,
                stagedWorkingCopySha256 = snapshot.stagedWorkingCopySha256,
                format = format,
                boundAtElapsedMs = ports.elapsedMs(),
            ))
        }
        return OfficeAiWire.successReply {
            put("sessionToken", snapshot.sessionToken)
            put("nativeGeneration", generation)
            put("viewerIncarnation", snapshot.viewerIncarnation)
            putOptional("hostGeneration", snapshot.hostGeneration)
            putOptional("nativeEpoch", snapshot.nativeEpoch)
            put("ownerTaskId", snapshot.ownerTaskId ?: "")
            putOptional("workspaceId", snapshot.workspaceId)
            putOptional("sourceLogicalPath", snapshot.sourceLogicalPath)
            putOptional("sourceId", snapshot.sourceId)
            putOptional("sourceRevision", snapshot.sourceRevision)
            put("route", if (snapshot.workspaceId != null) "workspace" else "runOutput")
            put("format", format)
            put("editable", snapshot.editable)
            putOptional("originalSnapshotSha256", snapshot.originalSnapshotSha256)
            put("originalSnapshotBytes", snapshot.originalSnapshotBytes)
            putOptional("stagedWorkingCopySha256", snapshot.stagedWorkingCopySha256)
            put("stagedWorkingCopyBytes", snapshot.stagedWorkingCopyBytes)
            put("displayName", displayName.take(120))
            putOptional("editStateName", edit?.stateName)
            put("editPermissionEstablished", edit?.editPermissionEstablished == true)
            put("openedNow", openedNow)
        }
    }

    // ------------------------------------------------------------------
    // command
    // ------------------------------------------------------------------

    private suspend fun command(
        ticket: OfficeAiWire.Ticket,
        staged: ByteArray,
        stopSignal: () -> Boolean,
    ): OfficeAiWire.Settlement {
        val sessionToken = ticket.required("sessionToken")
        val generation = ticket.required("generation").toLong()
        val opId = ticket.required("opId")
        val action = ticket.required("action")
        if (stopSignal()) return OfficeAiWire.failureReply("sessionEnding",
            "the ticket stopped before any dispatch")
        val fence = rejoinOrFailure(sessionToken, generation, ticket.field("taskID"))
        if (fence is FenceOutcome.Refused) return fence.settlement
        val bind = (fence as FenceOutcome.Granted).bind

        val request: OfficePrecisionRequest
        val isContentEffect = action == "applyText" || action == "setCellContent"
        var expectedRaw = ""
        when (action) {
            "captureTarget" -> request = OfficePrecisionClientCommands.capture(
                opId, sessionToken, generation, bind.ownerTaskID)
            "queryDocumentContext" -> request = OfficePrecisionClientCommands.documentContext(
                opId, sessionToken, generation)
            "queryTextSelection" -> request = OfficePrecisionClientCommands.textSelection(
                opId, sessionToken, generation)
            "queryCellCursor" -> request = OfficePrecisionClientCommands.cellCursor(
                opId, sessionToken, generation)
            "queryPresentationInfo" -> request = OfficePrecisionClientCommands.presentationInfo(
                opId, sessionToken, generation)
            "selectSlide" -> request = OfficePrecisionClientCommands.selectSlide(
                opId, sessionToken, generation, ticket.required("partId"))
            "selectAllText" -> request = OfficePrecisionClientCommands.selectAllText(
                opId, sessionToken, generation)
            "applyText" -> {
                expectedRaw = OfficeAiWire.decodeStaged(staged, ticket)
                if (expectedRaw.isEmpty() || expectedRaw.contains('\u0000')) {
                    return OfficeAiWire.failureReply("internal", "apply text is empty")
                }
                request = OfficePrecisionClientCommands.applyText(
                    opId, sessionToken, generation, expectedRaw, ticket.required("targetHandle").lowercase(Locale.ROOT))
            }
            "setCellContent" -> {
                expectedRaw = OfficeAiWire.decodeStaged(staged, ticket)
                if (expectedRaw.isEmpty() || expectedRaw.contains('\u0000')) {
                    return OfficeAiWire.failureReply("internal", "cell content is empty")
                }
                if (expectedRaw.any { it == '\t' || it == '\n' || it == '\r' }) {
                    return OfficeAiWire.failureReply("contentUnsafe",
                        "multi-cell spread is refused before dispatch")
                }
                val rawHandle = ticket.required("targetHandle").lowercase(Locale.ROOT)
                when (ticket.required("contentKind")) {
                    // Amendment/2 (Main ruling 2026-10-27): the tool literal
                    // is the EXACT wanted string (00123, leading =, dates,
                    // locale shapes, apostrophes included). The settled
                    // native apostrophe codec prefixes EVERY non-empty
                    // literal (a reinterpret guess list is incomplete), so a
                    // literal `=` never silently becomes a formula and a
                    // literal 00123 never silently becomes a number; the
                    // codec apostrophe is never part of the wanted value.
                    "literal" -> request = OfficePrecisionClientCommands.setCell(
                        opId, sessionToken, generation, ticket.required("cellAddress"),
                        OfficeAiWire.encodeNativeLiteral(expectedRaw),
                        OfficePrecisionContentKind.LITERAL, rawHandle,
                    )
                    // A NUMBER intent rides the native LITERAL with the raw
                    // canonical numeric text (no apostrophe): the persisted
                    // cell must be numeric; precision loss is caught by the
                    // verifier's actual-value comparison, never hidden here.
                    "number" -> {
                        if (!looksCanonicalNumber(expectedRaw)) {
                            return OfficeAiWire.failureReply("contentUnsafe",
                                "number intent requires canonical finite numeric text")
                        }
                        request = OfficePrecisionClientCommands.setCell(
                            opId, sessionToken, generation, ticket.required("cellAddress"),
                            expectedRaw, OfficePrecisionContentKind.LITERAL, rawHandle,
                        )
                    }
                    // A FORMULA must really carry the leading '='; a cached
                    // display value is never substituted.
                    else -> {
                        if (!expectedRaw.startsWith("=")) {
                            return OfficeAiWire.failureReply("contentUnsafe",
                                "formula intent requires the real leading =")
                        }
                        request = OfficePrecisionClientCommands.setCell(
                            opId, sessionToken, generation, ticket.required("cellAddress"),
                            expectedRaw, OfficePrecisionContentKind.FORMULA, rawHandle,
                        )
                    }
                }
            }
            else -> return OfficeAiWire.failureReply("internal", "unknown action")
        }

        if (isContentEffect) {
            // Same effect opId already dispatched for this session: refuse
            // BEFORE the engine sees it. A retry can never re-apply.
            if (effects.alreadyDispatched(sessionToken, opId)) {
                return OfficeAiWire.failureReply("applyConflict",
                    "this effect opId was already dispatched for the session; it will not be reapplied")
            }
            // A stale/foreign captured handle this host never recorded is
            // still decided by the ENGINE (the handle authority); the host
            // records the dispatch for its own proof correlation only.
            if (stopSignal()) return OfficeAiWire.failureReply("sessionEnding",
                "the ticket stopped before dispatch; nothing was sent to the engine")
            val effectTargetHandle = ticket.required("targetHandle").lowercase(Locale.ROOT)
            // No ambient selection is bound here. The content plan itself must
            // acquire fresh target/part/epoch-scoped evidence before paste and
            // return it inside this op's MutationApplied result; only that
            // typed result may later enter the verifier's baseline input.
            effects.recordDispatched(OfficeAiEffectRecord(
                sessionToken = sessionToken,
                generation = generation,
                ownerTaskID = bind.ownerTaskID,
                targetHandle = effectTargetHandle,
                opId = opId,
                action = action,
                expectedSha256 = sha256Hex(expectedRaw.toByteArray(Charsets.UTF_8)),
                terminalState = null,
                workingCopySha256AfterEffect = null,
                dispatchedAtElapsedMs = ports.elapsedMs(),
            ))
        }
        if (action == "selectSlide" || action == "selectAllText") {
            // A new preparatory action must not inherit an older pending
            // selection if its own readback fails or content is unavailable.
            selections.discardPending(sessionToken)
        }

        val result = ports.precision(request, timing.commandDeadlineMillis)
        return commandSettlement(action, sessionToken, generation, bind, opId, result, expectedRaw)
    }

    private fun commandSettlement(
        action: String,
        sessionToken: String,
        generation: Long,
        bind: OfficeAiSessionBind,
        opId: String,
        result: OfficePrecisionResult?,
        expectedRaw: String,
    ): OfficeAiWire.Settlement {
        if (result == null) {
            // Transport-level unknown: the engine ledger may still hold a
            // possible effect. NEVER auto-replay, auto-undo or restart.
            effects.settleOpId(sessionToken, opId, OfficePrecisionState.UNKNOWN, null)
            return commandStateReply(OfficePrecisionState.UNKNOWN, null, null,
                "client-transport-unknown", null, null)
        }
        val state = when (result.state) {
            OfficePrecisionState.ADMITTED -> OfficePrecisionState.UNKNOWN
            else -> result.state
        }
        if (action == "applyText" || action == "setCellContent") {
            effects.settleOpId(sessionToken, opId, state,
                (result.answer as? OfficePrecisionAnswer.MutationApplied)?.workingCopySha256)
        }
        var captureHandle: String? = null
        var facts: Map<String, Any?> = emptyMap()
        var readback: String? = null
        if (state == OfficePrecisionState.QUERY_OBSERVED &&
            result.answer is OfficePrecisionAnswer.TargetCaptured
        ) {
            val target = (result.answer as OfficePrecisionAnswer.TargetCaptured).target
            val handle = target.handleId.lowercase(Locale.ROOT)
            if (!handle.matches(Regex("^[0-9a-f]{32}$"))) {
                return OfficeAiWire.failureReply("internal", "capture handle shape refused")
            }
            captureHandle = handle
            facts = linkedMapOf(
                "docType" to target.docType,
                "partsCount" to target.partsCount,
                "selectedPart" to target.selectedPart,
                // The engine's SAME-answer witnessed logical ordinal: a real
                // braced presentation GUID has no decimal to parse here, and
                // re-deriving it at this boundary is exactly what returned
                // null and would refuse every PPTX saved verification. The
                // native identity stays byte-exact in "selectedPart".
                "partIndex" to target.selectedPartIndex,
                "documentModified" to target.documentModified,
            )
            // Main CAPTURE_BASELINE_WIRE_ADDENDUM (2026-10-27): forward the
            // CURRENT flushed working-copy identity ONLY from the actual
            // native TargetCaptured measurement for this exact handle. The
            // initial App-stage snapshot hash is never substituted, and an
            // absent/unprovable native digest simply omits the keys (Core
            // then refuses the context honestly instead of storing a stale
            // baseline). The retained pre-edit baseline below is matched to
            // this same native digest.
            target.workingCopySha256?.lowercase(Locale.ROOT)?.let { sha ->
                if (sha.matches(Regex("^[0-9a-f]{64}$")) &&
                    target.workingCopyBytes in 1..timing.maxWorkingCopyBytes
                ) {
                    facts["captureWorkingCopySha256"] = sha
                    facts["captureWorkingCopyBytes"] = target.workingCopyBytes
                }
            }
            val baseline = retainCaptureBaseline(bind, handle, target.workingCopySha256,
                target.workingCopyBytes)
            captures.put(OfficeAiCaptureRecord(
                sessionToken = sessionToken,
                generation = generation,
                ownerTaskID = bind.ownerTaskID,
                workspaceID = bind.workspaceID,
                targetHandle = handle,
                docType = target.docType,
                partsCount = target.partsCount,
                selectedPart = target.selectedPart,
                partIndex = target.selectedPartIndex,
                documentModified = target.documentModified,
                inputEpoch = target.inputEpoch,
                editEpoch = target.editEpoch,
                workingCopySha256AtCapture = target.workingCopySha256,
                workingCopyBytesAtCapture = target.workingCopyBytes,
                baselineFile = baseline?.file,
                baselineSha256 = baseline?.sha256,
                baselineBytes = baseline?.bytes ?: -1L,
                capturedAtElapsedMs = target.capturedAtElapsedMs,
                expiresAtElapsedMs = target.expiresAtElapsedMs,
            ))
        } else if (state == OfficePrecisionState.QUERY_OBSERVED) {
            when (val answer = result.answer) {
                is OfficePrecisionAnswer.DocumentContext -> facts = linkedMapOf(
                    "docType" to answer.docType, "partsCount" to answer.partsCount,
                    "selectedPart" to answer.selectedPart,
                    "partIndex" to answer.selectedPartIndex,
                    "viewID" to answer.viewId, "readOnly" to answer.readOnly,
                    "documentModified" to answer.documentModified,
                )
                is OfficePrecisionAnswer.TextSelection -> {
                    // Retain ordinary text for the ambient public-read view
                    // only (never effect proof); multi-MIME JSON is not text.
                    if (!answer.multiFormatJson) {
                        selections.observe(OfficeAiSelectionFact(sessionToken, generation,
                            answer.text, answer.byteCount, ports.elapsedMs()))
                    }
                    facts = linkedMapOf(
                        "selectionText" to answer.text,
                        "selectionByteCount" to answer.byteCount,
                    )
                }
                is OfficePrecisionAnswer.CellCursor -> facts = linkedMapOf(
                    "cursorColumn" to answer.column, "cursorRow" to answer.row,
                    "cursorEmpty" to answer.empty,
                )
                is OfficePrecisionAnswer.PresentationInfo -> facts = linkedMapOf(
                    "slideCount" to answer.slideCount,
                )
                else -> Unit
            }
        } else if ((state == OfficePrecisionState.NATIVE_COMPLETED ||
                state == OfficePrecisionState.MUTATION_VERIFIED)
        ) {
            when (val answer = result.answer) {
                is OfficePrecisionAnswer.SlideSelected -> facts = linkedMapOf(
                    "shownPart" to answer.shownPart, "selectedPart" to answer.shownPart,
                    "partIndex" to answer.shownPartIndex,
                )
                is OfficePrecisionAnswer.TextSelection -> {
                    // Keep this preparatory reply byte-count-only. Its text
                    // remains an ambient public-read observation; APPLY_TEXT
                    // must acquire its own fresh causal evidence before paste.
                    if (!answer.multiFormatJson) {
                        selections.observe(OfficeAiSelectionFact(sessionToken, generation,
                            answer.text, answer.byteCount, ports.elapsedMs()))
                    }
                    facts = linkedMapOf("selectedTextBytes" to answer.byteCount)
                }
                is OfficePrecisionAnswer.TextSelected -> facts = linkedMapOf(
                    "selectedTextBytes" to answer.effectPayloadBytes,
                )
                is OfficePrecisionAnswer.MutationApplied -> {
                    bindPreEffectEvidence(result, answer)
                    readback = camelReadback(answer.contentReadback)
                }
                else -> Unit
            }
        }
        return OfficeAiWire.successReply {
            put("state", commandStateToken(state))
            putOptional("failure", result.failure?.let { OfficeAiWire.camelToken(it.name) })
            putOptional("detail", result.detail?.take(OfficeAiWire.MAX_DETAIL_CHARS))
            put("attestation", result.attestation.take(OfficeAiWire.MAX_DETAIL_CHARS))
            putOptional("targetHandle", captureHandle)
            putOptional("contentReadback", readback)
            putFacts(facts)
        }
    }

    /** Bind only the causal evidence carried by this exact content result.
     * Any absent/mismatched fact simply leaves semantic delta unproven; the
     * mandatory core plan has already refused invalid evidence BEFORE paste. */
    private fun bindPreEffectEvidence(
        result: OfficePrecisionResult,
        applied: OfficePrecisionAnswer.MutationApplied,
    ) {
        if (result.action.effect != com.floe.android.core.officeengine.precision.OfficePrecisionEffect.CONTENT) {
            return
        }
        val evidence = applied.preEffectEvidence ?: return
        val handle = applied.consumedTargetHandle?.lowercase(Locale.ROOT) ?: return
        if (result.opId != evidence.opId || result.sessionToken != evidence.sessionToken ||
            result.generation != evidence.generation ||
            evidence.targetHandle.lowercase(Locale.ROOT) != handle
        ) {
            return
        }
        val capture = captures.get(result.sessionToken, handle) ?: return
        selections.bindPreEffect(
            OfficeAiPreEffectSelectionFact(
                sessionToken = evidence.sessionToken,
                generation = evidence.generation,
                targetHandle = handle,
                effectOpId = evidence.opId,
                partId = evidence.partId,
                inputEpoch = evidence.inputEpoch,
                editEpoch = evidence.editEpoch,
                selectionText = evidence.selectionText,
                selectionByteCount = evidence.selectionByteCount,
            ),
            capture,
        )
    }

    private fun commandStateToken(state: OfficePrecisionState): String = when (state) {
        OfficePrecisionState.QUERY_OBSERVED -> "queryObserved"
        OfficePrecisionState.NATIVE_COMPLETED -> "nativeCompleted"
        OfficePrecisionState.MUTATION_VERIFIED -> "mutationVerified"
        OfficePrecisionState.REJECTED -> "rejected"
        OfficePrecisionState.FAILED -> "failed"
        else -> "unknown"
    }

    private fun commandStateReply(
        state: OfficePrecisionState,
        failureToken: String?,
        detail: String?,
        attestation: String,
        readback: String?,
        facts: Map<String, Any?>?,
    ): OfficeAiWire.Settlement = OfficeAiWire.successReply {
        put("state", commandStateToken(state))
        putOptional("failure", failureToken)
        putOptional("detail", detail?.take(OfficeAiWire.MAX_DETAIL_CHARS))
        put("attestation", attestation.take(OfficeAiWire.MAX_DETAIL_CHARS))
        putOptional("contentReadback", readback)
        facts?.let { putFacts(it) }
    }

    private fun camelReadback(readback: OfficePrecisionContentReadback): String = when (readback) {
        OfficePrecisionContentReadback.MATCHED -> "matched"
        OfficePrecisionContentReadback.MISMATCHED -> "mismatched"
        OfficePrecisionContentReadback.FORMULA_NOT_COMPARABLE -> "formulaNotComparable"
        OfficePrecisionContentReadback.UNAVAILABLE -> "unavailable"
        OfficePrecisionContentReadback.NOT_ATTEMPTED -> "notAttempted"
    }

    /** Copy the CURRENT flushed working copy into the host-owned baseline
     * store and verify the copy against the capture's own engine-measured
     * digest. A mismatch or IO failure honestly yields null: the verifier
     * then reports the semantic delta unproven — it never sees a fabricated
     * baseline. */
    private fun retainCaptureBaseline(
        bind: OfficeAiSessionBind,
        handle: String,
        expectedSha256: String?,
        expectedBytes: Long,
    ): OfficeAiRetainedBaseline? {
        if (expectedSha256 == null || expectedBytes < 1 || expectedBytes > timing.maxWorkingCopyBytes) {
            return null
        }
        val source = bind.stagedWorkingCopyPath?.let { File(it) } ?: return null
        if (!source.isFile || Files.isSymbolicLink(source.toPath())) return null
        if (source.length() != expectedBytes) return null
        val directory = File(ports.baselineRoot(), bind.sessionToken)
        val target = File(directory, "$handle.bin")
        val temp = File(directory, "$handle.bin.tmp-${ports.elapsedMs()}")
        return runCatching {
            if (!directory.isDirectory && !directory.mkdirs()) return@runCatching null
            if (Files.isSymbolicLink(directory.toPath())) return@runCatching null
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(source).use { input ->
                FileOutputStream(temp).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > timing.maxWorkingCopyBytes) return@runCatching null
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                }
            }
            val sha = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            if (sha != expectedSha256.lowercase(Locale.ROOT)) {
                runCatching { temp.delete() }
                return@runCatching null
            }
            if (!temp.renameTo(target)) {
                runCatching { temp.delete() }
                return@runCatching null
            }
            OfficeAiRetainedBaseline(target, sha, expectedBytes)
        }.getOrNull()
    }

    // ------------------------------------------------------------------
    // save
    // ------------------------------------------------------------------

    private suspend fun save(
        ticket: OfficeAiWire.Ticket,
        stopSignal: () -> Boolean,
    ): OfficeAiWire.Settlement {
        val sessionToken = ticket.required("sessionToken")
        val generation = ticket.required("generation").toLong()
        val opId = ticket.required("opId")
        val saveOperation = ticket.required("saveOperation")
        if (stopSignal()) return OfficeAiWire.failureReply("sessionEnding",
            "the ticket stopped before any dispatch")
        val fence = rejoinOrFailure(sessionToken, generation, taskID = null)
        if (fence is FenceOutcome.Refused) return fence.settlement

        val request = runCatching {
            if (saveOperation == "flush") {
                OfficeSaveRequest.of(
                    opId, sessionToken, generation, OfficeSaveOperation.WORKING_COPY_FLUSH,
                    format = null, options = null, suggestedName = null,
                    // An explicit AI flush forces the real write path so an
                    // "unmodified" answer stays an honest failure instead of
                    // the autosave hint.
                    saveIfUnmodified = false,
                )
            } else {
                OfficeSaveRequest.of(
                    opId, sessionToken, generation, OfficeSaveOperation.STAGED_EXPORT,
                    format = ticket.required("format"), options = null,
                    suggestedName = ticket.field("suggestedName"),
                    saveIfUnmodified = false,
                )
            }
        }.getOrNull()
            ?: return OfficeAiWire.failureReply("requestTooLarge", "save request shape refused")
        request.exceptionOrNull()?.let { refusal ->
            val code = (refusal as? com.floe.android.core.officeengine.OfficeException)?.code
            return OfficeAiWire.successReply {
                put("state", "rejected")
                put("failure", if (code == com.floe.android.core.officeengine.OfficeFailureCode.UNSUPPORTED_FORMAT)
                    "unsupportedFamily" else "internal")
                put("attestation", "local-shape-refused")
            }
        }
        val validated = request.getOrNull()
            ?: return OfficeAiWire.failureReply("internal", "save request unavailable")

        // Register the OWNED waiter BEFORE dispatch, keyed by the EXACT
        // opId + sessionToken + native generation.
        val key = SaveWaiters.Key(sessionToken, generation, opId)
        val deferred = saveWaiters.register(key)
            ?: return OfficeAiWire.failureReply("internal", "a waiter already holds this exact save op")
        when (val submit = ports.saveSubmit(validated)) {
            is OfficeAiSaveSubmit.NotBound -> {
                // Proven pre-dispatch: the command binding was never there,
                // nothing reached the engine; a fresh ticket may retry.
                saveWaiters.remove(key)
                return OfficeAiWire.failureReply("transport",
                    "engine command binding unavailable; nothing was dispatched")
            }
            is OfficeAiSaveSubmit.Code -> if (submit.value != OfficeEngineCommandsPolicy.SUBMIT_ACCEPTED) {
                saveWaiters.remove(key)
                val (state, failure) = when (submit.value) {
                    OfficeEngineCommandsPolicy.SUBMIT_REJECTED_SHAPE -> "rejected" to "requestTooLarge"
                    OfficeEngineCommandsPolicy.SUBMIT_REJECTED_SESSION -> "rejected" to "sessionMismatch"
                    OfficeEngineCommandsPolicy.SUBMIT_REJECTED_BUSY -> "rejected" to "saveInFlight"
                    else -> "rejected" to "engineNotReady"
                }
                return OfficeAiWire.successReply {
                    put("state", state)
                    put("failure", failure)
                    put("attestation", "submit-refused-${submit.value}")
                }
            }
            // ATTEMPTED_WITHOUT_REPLY: the transaction was issued and the
            // reply lost — the op may hold the engine. Keep the exact-key
            // waiter and resolve through the REAL receipt below, or settle
            // honestly UNKNOWN/retained on the wait deadline. NEVER re-send.
            OfficeAiSaveSubmit.AttemptedWithoutReply -> Unit
        }
        val waitMillis = if (saveOperation == "flush") timing.flushWaitMillis else timing.exportWaitMillis
        val receipt = withTimeoutOrNull(waitMillis) { deferred.await() }
        saveWaiters.remove(key)
        if (receipt == null) {
            // Binding loss/timeout retains UNKNOWN honestly: the working copy
            // and every prior output stay; nothing is cancelled at the engine
            // and nothing is replayed.
            return OfficeAiWire.successReply {
                put("state", "unknown")
                put("failure", "saveUnknown")
                put("attestation", "host-wait-deadline")
            }
        }
        return saveSettlement(receipt)
    }

    private fun saveSettlement(receipt: OfficeSaveReceipt): OfficeAiWire.Settlement =
        OfficeAiWire.successReply {
            put("state", when (receipt.state) {
                OfficeSaveState.FLUSHED -> "flushed"
                OfficeSaveState.UNMODIFIED -> "unmodified"
                OfficeSaveState.OUTPUT_READY -> "outputReady"
                OfficeSaveState.FAILED -> "failed"
                OfficeSaveState.REJECTED -> "rejected"
                OfficeSaveState.CANCELLED -> "cancelled"
                else -> "unknown"
            })
            putOptional("failure", (receipt.failure
                // An UNKNOWN terminal receipt with no named cause is the honest
                // timeout shape (the engine table's timeoutWithoutAck token).
                ?: if (receipt.state == OfficeSaveState.UNKNOWN) OfficeSaveFailureCode.TIMEOUT_WITHOUT_ACK else null)
                ?.let { OfficeAiWire.camelToken(it.name) })
            when (receipt.state) {
                OfficeSaveState.FLUSHED, OfficeSaveState.UNMODIFIED -> {
                    putOptional("workingCopySHA256", receipt.workingCopySha256)
                    put("workingCopyBytes", receipt.workingCopyBytes)
                }
                OfficeSaveState.OUTPUT_READY -> {
                    putOptional("outputPath", receipt.outputDocumentPath)
                    putOptional("outputSHA256", receipt.outputSha256)
                    put("outputBytes", receipt.outputBytes)
                }
                else -> Unit
            }
            put("attestation", receipt.attestation.take(OfficeAiWire.MAX_DETAIL_CHARS))
        }

    // ------------------------------------------------------------------
    // verify (pure verifier 21 consumes the immutable input; the host owns
    // the byte pre-checks and the owned proof correlation)
    // ------------------------------------------------------------------

    private suspend fun verify(
        ticket: OfficeAiWire.Ticket,
        staged: ByteArray,
    ): OfficeAiWire.Settlement {
        val mode = ticket.required("verificationMode")
        val format = ticket.required("format")
        val declaredSha = ticket.required("sha256").lowercase(Locale.ROOT)
        val expectCommand = ticket.required("expectCommand")
        val expectedRaw = OfficeAiWire.decodeStaged(staged, ticket)
        if (expectedRaw.isEmpty() || expectedRaw.contains('\u0000')) {
            return OfficeAiWire.failureReply("internal", "expected text is empty")
        }
        if (expectCommand == "setCellContent" && mode == "liveEffect") {
            // kind-specific raw expectations: formula keeps its leading '='
            // (the verifier compares the persisted <f> SOURCE, never a
            // cached value); literal/number keep the RAW wanted value.
            when (ticket.field("contentKind")) {
                "formula" -> if (!expectedRaw.startsWith("=")) {
                    return OfficeAiWire.failureReply("internal", "formula expectation must start with =")
                }
                "number" -> if (!looksCanonicalNumber(expectedRaw)) {
                    return OfficeAiWire.failureReply("internal", "number expectation is not canonical")
                }
            }
        }

        // ---- byte facts BEFORE any content parsing (host pre-checks) ----
        val file = File(ticket.required("path"))
        val canonical = runCatching { file.canonicalFile }.getOrNull()
            ?: return OfficeAiWire.failureReply("packageUnreadable", "path unresolved")
        val root = ports.appDataRoot()?.let { runCatching { it.canonicalFile }.getOrNull() }
            ?: return OfficeAiWire.failureReply("packageUnreadable", "host root unavailable")
        if (canonical.path != root.path && !canonical.path.startsWith(root.path + File.separator)) {
            return OfficeAiWire.failureReply("packageUnreadable", "path leaves the app data root")
        }
        if (!canonical.isFile || Files.isSymbolicLink(file.toPath())) {
            return OfficeAiWire.failureReply("packageUnreadable", "not a plain regular file")
        }
        val measuredBytes = canonical.length()
        if (measuredBytes < 1 || measuredBytes > timing.maxWorkingCopyBytes) {
            return OfficeAiWire.failureReply("outputTooLarge", "artifact size outside the module cap")
        }
        val measuredSha = runCatching { sha256OfFile(canonical) }
            .getOrNull() ?: return OfficeAiWire.failureReply("packageUnreadable", "artifact unreadable")
        if (measuredSha != declaredSha) {
            return OfficeAiWire.failureReply("digestMismatch", "measured bytes differ from the descriptor")
        }

        // ---- owned proof correlation ----
        var nativeTargetEffectVerified = false
        var trustedCompletedJobProof = false
        var capture: OfficeAiCaptureRecord? = null
        var selection: OfficeAiPreEffectSelectionFact? = null
        when (mode) {
            "liveEffect" -> {
                val sessionToken = ticket.required("sessionToken")
                val generation = ticket.required("generation").toLong()
                val handle = ticket.required("targetHandle").lowercase(Locale.ROOT)
                val fence = rejoinOrFailure(sessionToken, generation, ticket.field("taskID"))
                if (fence is FenceOutcome.Refused) return fence.settlement
                val effectOpId = ticket.required("effectOpId")
                nativeTargetEffectVerified = effects.provesMutationVerified(
                    sessionToken, generation, handle, effectOpId,
                )
                capture = captures.get(sessionToken, handle)
                    ?: captures.latestForSession(sessionToken, generation)?.takeIf {
                        it.targetHandle == handle
                    }
                selection = selections.forEffect(sessionToken, generation, handle, effectOpId)
            }
            "completedJob" -> {
                // A valid historical proof must NOT require a still-live
                // native session: after Core's durable-v2 owner/seed/digest/
                // version validation the mailbox sends this private mode; the
                // digest equality above (measured BEFORE any parsing) binds
                // the exact artifact. Content is still inspected independently.
                trustedCompletedJobProof = true
                val handle = ticket.field("targetHandle")?.lowercase(Locale.ROOT)
                val sessionToken = ticket.field("sessionToken")
                if (handle != null && sessionToken != null) {
                    capture = captures.get(sessionToken, handle)
                    selection = selections.forEffect(sessionToken, capture?.generation ?: -1L,
                        handle, ticket.required("effectOpId"))
                }
            }
            "reconcile" -> {
                // Reconcile without a real exact owned proof stays false /
                // unprovable — never filename-only.
                val handle = ticket.field("targetHandle")?.lowercase(Locale.ROOT)
                val sessionToken = ticket.field("sessionToken")
                if (handle != null && sessionToken != null) {
                    capture = captures.get(sessionToken, handle)
                    selection = selections.forEffect(sessionToken, capture?.generation ?: -1L,
                        handle, ticket.required("effectOpId"))
                }
            }
        }

        // The logical part index rides CAPTURED native facts (never sheet1,
        // never a filename ordinal; the verifier resolves ordered rels).
        // The ticket's expectPartIndex is Core's RELAY of the captured
        // observation (shared OfficeAIHostBridge expectations.partIndex is
        // built from this host's own capture facts), never the model's
        // requested slide. Lineage rule (part-ordinal84): while this host
        // still holds the exact capture, its engine-witnessed ordinal is
        // authoritative — an unwitnessed capture is REFUSED instead of being
        // papered over by the relay (the old ticket-first fallback hid
        // exactly that null for every braced presentation GUID), and a
        // disagreeing relay refuses as a stale/crossed lineage. Only a
        // genuinely historical proof whose capture left with the session
        // (completedJob/reconcile) still rides the relay alone.
        val ticketPartIndex = ticket.field("expectPartIndex")?.toInt()
        val partIndex: Int? = if (format == "docx") {
            ticketPartIndex ?: capture?.partIndex
        } else if (capture != null) {
            val observed = capture.partIndex
            if (observed == null) {
                return OfficeAiWire.failureReply("structureInvalid",
                    "captured logical part index required for $format")
            }
            if (ticketPartIndex != null && ticketPartIndex != observed) {
                return OfficeAiWire.failureReply("structureInvalid",
                    "verification ticket part index disagrees with the captured native witness")
            }
            observed
        } else {
            ticketPartIndex
        }
        if (format != "docx" && partIndex == null) {
            return OfficeAiWire.failureReply("structureInvalid",
                "captured logical part index required for $format")
        }
        val baseline = capture?.takeIf { it.baselineFile?.isFile == true && it.baselineSha256 != null }
            ?.let {
                OfficeAiVerificationBaseline(
                    file = it.baselineFile!!,
                    sha256 = it.baselineSha256!!,
                    bytes = it.baselineBytes,
                    partIndex = it.partIndex,
                    priorSelectionText = selection?.selectionText,
                )
            }
        val input = OfficeAiVerificationInput(
            file = canonical,
            sha256 = measuredSha,
            bytes = measuredBytes,
            format = format,
            command = expectCommand,
            expectedText = expectedRaw,
            contentKind = ticket.field("contentKind"),
            cellAddress = ticket.field("cellAddress"),
            partIndex = partIndex,
            baseline = baseline,
            nativeTargetEffectVerified = nativeTargetEffectVerified,
            trustedCompletedJobProof = trustedCompletedJobProof,
        )
        return when (val outcome = verifier.inspect(input)) {
            is OfficeAiVerificationResult.Refused ->
                OfficeAiWire.failureReply(outcome.code, null)
            is OfficeAiVerificationResult.Verified -> {
                val facts = outcome.facts
                OfficeAiWire.successReply {
                    put("inspected", true)
                    putOptional("partName", facts.partName)
                    putOptional("expectedTextFound", facts.expectedTextFound)
                    putOptional("occurrenceCount", facts.occurrenceCount)
                    putOptional("replacementScope", facts.replacementScope)
                    facts.cellTypeAttribute?.let { put("cellTypeAttribute", it) }
                    putOptional("cellHasFormula", facts.cellHasFormula)
                    putOptional("cellPersistedValue", facts.cellPersistedValue)
                    putOptional("cellTypeMatchesIntent", facts.cellTypeMatchesIntent)
                    // changedFromOriginal is a byte-hash fact the HOST owns
                    // when the verifier cannot measure it (no retained
                    // baseline): the descriptor's pre-edit digest bound at
                    // capture versus the measured export digest — never a
                    // model-declared value.
                    putOptional("changedFromOriginal", facts.changedFromOriginal
                        ?: ticket.field("preEditSha256")?.lowercase(Locale.ROOT)
                            ?.let { measuredSha != it })
                    putOptional("expectedContentMatches", facts.expectedContentMatches)
                    putOptional("targetEffectVerified", facts.targetEffectVerified)
                    putOptional("semanticDeltaVerified", facts.semanticDeltaVerified)
                    putOptional("proofReused", facts.proofReused)
                    put("proofVersion", 2)
                    if (facts.limitations.isNotEmpty()) {
                        put("limitations", buildJsonArray {
                            facts.limitations.take(8).forEach { add(it.take(160)) }
                        })
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // reconcile
    // ------------------------------------------------------------------

    private fun reconcile(ticket: OfficeAiWire.Ticket): OfficeAiWire.Settlement {
        val exportOpId = ticket.required("exportOpId")
        val format = ticket.required("format")
        val root = ports.outputsRoot()
        val matches = ArrayList<File>()
        val generationDirectories = root.listFiles()?.filter { child ->
            child.isDirectory && child.name.toLongOrNull() != null
        } ?: emptyList()
        for (directory in generationDirectories) {
            val children = directory.listFiles() ?: continue
            for (child in children) {
                val name = child.name
                if (!name.startsWith("$exportOpId-") || !name.endsWith(".$format")) continue
                val tail = name.removePrefix("$exportOpId-").removeSuffix(".$format")
                if (tail.isEmpty() || !tail.all { it in '0'..'9' }) continue
                if (!child.isFile || Files.isSymbolicLink(child.toPath())) continue
                matches.add(child)
            }
        }
        return when {
            matches.isEmpty() -> OfficeAiWire.successReply { put("found", false) }
            matches.size > 1 -> OfficeAiWire.failureReply("ambiguousArtifact",
                "more than one artifact matches the exact export opId")
            else -> OfficeAiWire.successReply {
                put("found", true)
                put("path", runCatching { matches.first().canonicalFile.path }
                    .getOrElse { matches.first().absolutePath })
            }
        }
    }

    // ------------------------------------------------------------------
    // pushOriginal (existing journal ladder on the headless runtime-owned
    // lane; local workspace CAS is Core's, reported separately)
    // ------------------------------------------------------------------

    private suspend fun pushOriginal(
        ticket: OfficeAiWire.Ticket,
        stopSignal: () -> Boolean,
    ): OfficeAiWire.Settlement {
        val taskID = ticket.required("taskID")
        val workspaceID = ticket.required("workspaceID")
        val path = ticket.required("logicalPath")
        if (ports.currentNativeEpoch() != epoch) return OfficeAiWire.failureReply("generationFenced")
        val snapshot = ports.ownedSnapshot(taskID, workspaceID, epochText)
            ?: return OfficeAiWire.failureReply("noOwnedDocument",
                "pushOriginal runs only for the current owned workspace document")
        if (snapshot.sourceLogicalPath != path) {
            return OfficeAiWire.failureReply("sessionMismatch",
                "the owned document path differs from the push request (manual retarget)")
        }
        if (!ports.isOwnedOrdinaryTask(taskID)) {
            return OfficeAiWire.failureReply("notOwner")
        }
        val bind = binds.get(snapshot.sessionToken)
            ?: return OfficeAiWire.failureReply("sessionMismatch", "no host session bind for the owned document")
        if (bind.ownerTaskID != taskID || bind.workspaceID != workspaceID) {
            return OfficeAiWire.failureReply("sessionMismatch")
        }
        if (stopSignal()) {
            return OfficeAiWire.failureReply("sessionEnding",
                "the ticket stopped before the ladder opened; nothing was dispatched")
        }
        val result = ports.pushOriginalViaHeadlessLane(
            taskID = taskID,
            workspaceID = workspaceID,
            nativeEpoch = epoch,
            hostGeneration = ports.commandGeneration(),
            logicalPath = path,
            // Owner fence = the live-ticket closure PLUS the document-owner
            // facts. The ladder itself runs to its honest terminal once a
            // provider permit was issued (no force clean-cancel mid-IO);
            // pre-dispatch stops settle honestly above.
            ownerFence = {
                ports.currentNativeEpoch() == epoch &&
                    ports.isOwnedOrdinaryTask(taskID) &&
                    ports.ownedSnapshot(taskID, workspaceID, epochText)?.sessionToken == snapshot.sessionToken
            },
        ) ?: return OfficeAiWire.failureReply("laneFenced",
            "no live accepted native root / bound gateway for the headless lane")
        val recoveryID = result.facts["recoveryID"]?.take(64)
        val status = when (result.status) {
            "ok" -> "ok"
            "sourceChangedSinceImport" -> "sourceChangedSinceImport"
            "conflict" -> if (result.detail == DRIFT_AT_CLAIM_DETAIL) "driftAtClaim" else "conflict"
            "rePickRequired" -> "rePickRequired"
            "revoked" -> "revoked"
            "readOnly" -> "readOnly"
            "journalRefused" -> "journalRefused"
            "unbound" -> "sourceUnbound"
            "providerOffline" -> if (recoveryID != null) "pendingRecoverable" else "providerOffline"
            else -> "unknown"
        }
        return OfficeAiWire.successReply {
            put("status", status)
            putOptional("recoveryID", recoveryID)
        }
    }

    // ------------------------------------------------------------------
    // shared session fence
    // ------------------------------------------------------------------

    private sealed class FenceOutcome {
        class Granted(val bind: OfficeAiSessionBind) : FenceOutcome()
        class Refused(val settlement: OfficeAiWire.Settlement) : FenceOutcome()
    }

    /** Exact session-bind + LIVE owned-operation rejoin BEFORE any effect.
     * A stale/foreign/manual retarget or closed root refuses here — never a
     * fallback to "whatever document is open". */
    private fun rejoinOrFailure(
        sessionToken: String,
        generation: Long,
        taskID: String?,
    ): FenceOutcome {
        if (ports.currentNativeEpoch() != epoch) {
            return FenceOutcome.Refused(OfficeAiWire.failureReply("generationFenced"))
        }
        val bind = binds.get(sessionToken)
            ?: return FenceOutcome.Refused(OfficeAiWire.failureReply("noOwnedDocument",
                "the host never resolved this session token for the bound epoch"))
        if (bind.nativeGeneration != generation) {
            return FenceOutcome.Refused(OfficeAiWire.failureReply("sessionMismatch",
                "the engine generation behind this session changed"))
        }
        if (taskID != null && taskID.isNotEmpty() && bind.ownerTaskID != taskID) {
            return FenceOutcome.Refused(OfficeAiWire.failureReply("sessionMismatch",
                "the owner echo does not match the bound session owner"))
        }
        val live = ports.ownedSnapshot(bind.ownerTaskID, bind.workspaceID, epochText)
            ?: return FenceOutcome.Refused(OfficeAiWire.failureReply("noOwnedDocument",
                "the document behind this session is no longer the owned open operation"))
        if (live.sessionToken != sessionToken) {
            return FenceOutcome.Refused(OfficeAiWire.failureReply("sessionMismatch",
                "the owned operation now carries a different session"))
        }
        // Keep the bind fresh (incarnation/working-copy facts may have been
        // refreshed by a legitimate recapture flow).
        binds.bind(bind.copy(
            viewerIncarnation = live.viewerIncarnation,
            stagedWorkingCopyPath = live.stagedWorkingCopyPath,
            stagedWorkingCopySha256 = live.stagedWorkingCopySha256,
        ))
        return FenceOutcome.Granted(bind)
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    private fun looksCanonicalNumber(raw: String): Boolean =
        raw == raw.trim() && raw.matches(Regex("^[+-]?((\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?)$")) &&
            raw.toDoubleOrNull()?.isFinite() == true &&
            !raw.startsWith("+") && !(raw.startsWith("-") && raw.substring(1).startsWith(".")) &&
            // A canonical finite value never carries redundant leading zeros
            // ("00123" is a LITERAL, not a number: the engine would number
            // it and the verifier would honestly fail).
            !(raw.trimStart('-', '+').let { intPart ->
                intPart.split('.', 'e', 'E').first().length > 1 &&
                    intPart.startsWith("0")
            })

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }

    private fun sha256OfFile(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    private fun kotlinx.serialization.json.JsonObjectBuilder.putFacts(
        facts: Map<String, Any?>,
    ) {
        if (facts.isEmpty()) return
        putJsonObject("facts") {
            for ((key, value) in facts) {
                when (value) {
                    null -> Unit
                    is String -> putOptional(key, value)
                    is Number -> putOptional(key, value)
                    is Boolean -> putOptional(key, value)
                    else -> Unit
                }
            }
        }
    }

    companion object {
        /** The production lane's exact drift-at-claim refusal detail (the
         * only stable discriminator between a generic provider conflict and
         * the write-permit-boundary drift terminal in the reused ladder). */
        const val DRIFT_AT_CLAIM_DETAIL = "the provider changed at the write-permit boundary"
    }
}

/** The exact builder seam of the delivered typed precision client (kept as a
 * tiny indirection so the service dispatches through the SAME companion
 * builders the App already uses — no request bypass, no raw wire). */
private object OfficePrecisionClientCommands {
    fun capture(opId: String, token: String, generation: Long, ownerTaskId: String?) =
        com.floe.android.host.OfficePrecisionClient.captureTargetRequest(opId, token, generation, ownerTaskId, null)

    fun documentContext(opId: String, token: String, generation: Long) =
        com.floe.android.host.OfficePrecisionClient.documentContextRequest(opId, token, generation)

    fun textSelection(opId: String, token: String, generation: Long) =
        com.floe.android.host.OfficePrecisionClient.textSelectionRequest(opId, token, generation)

    fun cellCursor(opId: String, token: String, generation: Long) =
        com.floe.android.host.OfficePrecisionClient.cellCursorRequest(opId, token, generation)

    fun presentationInfo(opId: String, token: String, generation: Long) =
        com.floe.android.host.OfficePrecisionClient.presentationInfoRequest(opId, token, generation)

    fun selectSlide(opId: String, token: String, generation: Long, partId: String) =
        com.floe.android.host.OfficePrecisionClient.selectSlideRequest(opId, token, generation, partId)

    fun selectAllText(opId: String, token: String, generation: Long) =
        com.floe.android.host.OfficePrecisionClient.selectAllTextRequest(opId, token, generation)

    fun applyText(opId: String, token: String, generation: Long, text: String, targetHandle: String) =
        com.floe.android.host.OfficePrecisionClient.applyTextRequest(opId, token, generation, text, targetHandle)

    fun setCell(
        opId: String, token: String, generation: Long, cellAddress: String,
        text: String, kind: OfficePrecisionContentKind, targetHandle: String,
    ) = com.floe.android.host.OfficePrecisionClient.setCellContentRequest(
        opId, token, generation, cellAddress, text, kind, targetHandle,
    )
}
