package com.floe.android.core.officeengine

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.res.Configuration
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeTheme
import com.floe.android.design.FloeThemeMode
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import org.libreoffice.androidlib.COWebView
import com.floe.android.core.officeengine.pdf.OfficeExportPurpose
import com.floe.android.core.officeengine.pdf.OfficePdfExportLedger
import com.floe.android.core.officeengine.pdf.OfficePdfPreviewActivity
import com.floe.android.core.officeengine.pdf.OfficePdfPreviewRequest
import com.floe.android.core.officeengine.pdf.OfficePdfPrintFlow
import com.floe.android.core.officeengine.pdf.OfficePdfReceiptPolicy
import com.floe.android.core.officeengine.pdf.OfficePdfRenderHost
import com.floe.android.core.officeengine.pdf.PdfDocResult
import com.floe.android.core.officeengine.pdf.PrintStartOutcome
import com.floe.android.core.officeengine.pdf.VerifiedPdfSnapshot

/**
 * The R1 viewer surface: Floe toolbar chrome (Back left, centered title,
 * contextual info action right) over the native engine WebView. The
 * engine/service lifetime is owned by [OfficeEngineService]; the composition
 * can disappear and rebuild without minting a new document or save authority
 * (the same session token reopens through the settle-then-create path).
 *
 * Main owns final visual acceptance and App routing; this chrome reuses the
 * pinned :core:designsystem components already accepted across the app (no
 * default Android toolbar, no new glyph approximations).
 */
class OfficePreviewActivity : ComponentActivity(), OfficeEngineService.OfficeEngineListener {

    private var service: OfficeEngineService? = null
    private var request: OfficePreviewRequest? = null
    private var bound = false
    private var ownerBound = false
    private var ownerConnected = false
    private var sessionBegunFor: OfficePreviewRequest? = null
    private var terminalOutcome: OfficeViewerOutcome? = null
    private var viewerView: COWebView? = null
    private var nativeGeneration = 0L

    /**
     * Parent close-intent capability + the parent-minted opaque viewer
     * incarnation, received ONLY from this Activity's own launch Intent
     * (OfficeCloseAckPolicy). They are handed to the service so an exact
     * user close can be acknowledged back to the App process before the
     * native BYE ends this process. Never written to logs or documents.
     */
    private var closeAck: android.os.IBinder? = null
    private var viewerIncarnation = -1L

    /**
     * Parent approval-notice capability + the App-minted review target
     * (OfficeApprovalNoticePolicy), received ONLY from this Activity's own
     * launch Intent. Present only for OWNED opens: the foreground viewer
     * polls the capability while resumed and, when the OWNING conversation
     * holds a captured pending approval, shows one banner whose Review
     * action raises the existing chat Activity (the review ComponentName)
     * WITHOUT closing this document. The banner grants, approves, cancels
     * and replays nothing — review stays on the ordinary conversation card.
     */
    private var approvalNoticeCapability: android.os.IBinder? = null
    private var reviewComponent: ComponentName? = null

    /** Live pending-approval answer for this exact mount (null = none/not
     *  applicable). Display state only: the parent re-validates ownership on
     *  EVERY query, so a close/settle/replacement withdraws the banner by
     *  itself on the next poll. The tool name is a GATE signal only: the
     *  banner never renders it (office-return109 product-copy rule) — the
     *  identifier stays where it is meaningful, the explicit approval card
     *  in the owning conversation. */
    private var approvalNoticeTool: String? by mutableStateOf(null)

    /** One dedicated poll thread: the synchronous parent transact never runs
     *  on the main thread. Started only in onResume, torn down in onPause. */
    private var noticeThread: HandlerThread? = null
    private var noticeHandler: Handler? = null
    // EXPLICIT Looper (office-return109, Main review): a field initializer
    // runs while the Activity base context is NOT yet attached, so the
    // ContextWrapper.getMainLooper() receiver behind a bare `mainLooper`
    // risks a launch NPE. Looper.getMainLooper() is a static and attaches
    // nothing. The poll stays one background HandlerThread with the main
    // apply kept sequence-fenced through this handler.
    private val mainHandler = Handler(android.os.Looper.getMainLooper())
    private var noticeSeq = 0L

    /**
     * R2 generic host save-target channel (OfficeHostSaveChannel), received
     * ONLY from this Activity's own launch Intent. The App prepares the
     * CREATE_DOCUMENT Intent; THIS foreground Activity launches it (the
     * background App process must not assume background-activity-launch
     * permission) and forwards the actual URI + returned flags back. The
     * module never resolves, grants or writes through the URI.
     */
    private var hostSaveChannel: android.os.IBinder? = null

    /** Live observed edit state for the exact mount (never a readiness claim). */
    private var editState: OfficeEditState? by mutableStateOf(null)

    /** Receipts issued for this mount, bounded for the details sheet. */
    private val saveReceipts = ArrayList<OfficeSaveReceipt>()

    /** Save-target handoff in flight (opId -> format), fenced by opId. */
    private var pendingHandoffOpId: String? = null
    private var pendingHandoffFormat: String? = null

    /** Export ops awaiting OUTPUT_READY (opId -> format), fenced by opId. */
    private val pendingExportFormats = HashMap<String, String>()

    /**
     * Exact-once op->purpose ledger (pdf package). OUTPUT_READY for a LOCAL
     * PDF purpose may open ONLY the isolated preview or the system print
     * dialog — never the SAF picker, never a "saved" claim, never a dirty
     * state change; SAF purposes keep the existing Save-Copy handoff
     * behaviour untouched (Main contract 2026-10-27). A stale or duplicate
     * terminal receipt whose op was already consumed opens NOTHING.
     */
    private val exportPurposes = OfficePdfExportLedger()

    /** Local PDF flows in flight ("export" | "print") under the busy cover. */
    private var pdfBusyKey: String? by mutableStateOf(null)

    /** Renderer host used only to obtain the REAL page count before print. */
    private var pdfRenderHost: OfficePdfRenderHost? = null

    /**
     * Ops whose picker result was delivered to the App and that now await
     * the App's real settlement (COPY_SAVED/FAILED/CANCELLED). A settlement
     * is accepted for a known pending op EXACTLY ONCE; unknown/stale/
     * duplicate settlements never replace the current notice or close
     * (Main UI acceptance 2026-10-26).
     */
    private val awaitingSettlementOps = HashSet<String>()

    /**
     * External dirty-sheet "Save Copy and close" state: the export op whose
     * verified App COPY_SAVED settlement authorizes the close. Native
     * FLUSHED / UNMODIFIED / ModifiedStatus facts describe the PRIVATE
     * working copy only and never authorize this external close. (The
     * separate internal Notes lane uses [internalSaveOpId] + the App's
     * verified working-copy snapshot.)
     */
    private var closeAfterExportOpId: String? = null

    /** Busy-cover phases while a close-save is in flight (input frozen). */
    private enum class CloseSavePhase { EXPORTING, AWAITING_PICKER, AWAITING_APP, SAVING }
    private var closeSavePhase: CloseSavePhase? by mutableStateOf(null)

    /**
     * R3 internal Notes save: this mount's App host owns a private
     * working-copy commit (launch Intent extra). The dirty sheet's primary
     * action then performs one real `.uno:Save` flush and hands the verified
     * working-copy facts to that host; no system file picker is involved.
     * The ordinary "Save Copy" menu keeps the unchanged external SAF path.
     */
    private var internalSaveEnabled = false

    /**
     * The one internal-save op in flight for this mount. Its terminal receipt
     * is consumed here (never by the external close-save path); a stale or
     * duplicate receipt after the op settled opens nothing.
     */
    private var internalSaveOpId: String? = null

    /** One handoff verification in flight (never two snapshots per op). */
    private var internalSaveHandoffInFlight = false

    /** True once the page reported EDITMODE on at any point in this mount. */
    private var everEnteredEditMode = false

    private var opCounter = 0

    private var progress: OfficeViewerProgress? by mutableStateOf(null)
    private var noticeKey: String? by mutableStateOf(null)
    private var noticeDetail: String? by mutableStateOf(null)
    private var viewerUrl: String? by mutableStateOf(null)
    private var localFailure: Pair<OfficeFailureCode, String?>? by mutableStateOf(null)
    private var showDirtyCloseSheet by mutableStateOf(false)
    private var diagnosticEvents: List<OfficeSessionDiagnostics.Event> by mutableStateOf(emptyList())

    /**
     * System save-target picker launcher. Registered before composition; the
     * result (including cancellation) is forwarded EXACTLY as returned to
     * the App capability — the module draws no success conclusion from it.
     * Delivery means "accepted for processing" ONLY; the honest terminal
     * outcome arrives later via [onHostSaveSettlement].
     */
    private val saveTargetLauncher =
        registerForActivityResult(androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()) { result ->
            val opId = pendingHandoffOpId
            val token = request?.sessionToken.orEmpty()
            pendingHandoffOpId = null
            pendingHandoffFormat = null
            if (opId == null) return@registerForActivityResult
            val uriString = result.data?.data?.toString()
            val delivered = OfficeHostSaveChannel.deliverPickResult(
                hostSaveChannel,
                opId,
                token,
                nativeGeneration,
                result.resultCode,
                uriString,
                result.data?.flags ?: 0,
            )
            val isCloseSave = closeAfterExportOpId == opId
            when {
                result.resultCode != RESULT_OK -> {
                    // User cancelled the system picker: nothing was granted,
                    // the staged copy is retained, the editor stays open.
                    if (isCloseSave) abortCloseSave()
                    noticeKey = "pickerCancelled"
                    noticeDetail = null
                }
                !delivered -> {
                    if (isCloseSave) abortCloseSave()
                    noticeKey = "hostTargetUnavailable"
                    noticeDetail = null
                }
                else -> {
                    awaitingSettlementOps.add(opId)
                    if (isCloseSave) {
                        closeSavePhase = CloseSavePhase.AWAITING_APP
                    } else {
                        noticeKey = "copyHandedToApp"
                        noticeDetail = null
                    }
                }
            }
        }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val engine = (binder as? OfficeEngineService.LocalBinder)?.service ?: return
            service = engine
            engine.addListener(this@OfficePreviewActivity)
            engine.setAppearance(appearanceOverride())
            maybeBeginSession()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // Engine process died (crash or reclamation): the exact mount is
            // gone. Originals and staged snapshots remain untouched.
            service = null
            deliverLocalFailure(OfficeFailureCode.PROCESS_LOST, null)
        }
    }

    /**
     * Connection to the inert App-process (main) host owner anchor. The
     * returned Binder carries no commands: connection success itself is the
     * signal that the cached freezer must keep the parent process — owner of
     * the close capability — available while this viewer is visible.
     */
    private val ownerConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            ownerConnected = true
            maybeBeginSession()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // The App process that owns the close capability died or the
            // binding was lost. No guessed wait and no continue-without-owner:
            // the session can never be closed exactly, so fail honestly.
            ownerConnected = false
            deliverLocalFailure(OfficeFailureCode.PROCESS_LOST, null)
        }
    }

    /**
     * Admit the native session exactly once per request, only after BOTH (a)
     * the engine service in this process is connected and (b) the App-process
     * host owner is bound. Idempotent across connection ordering and engine
     * reconnects; never begins twice for the current request.
     */
    private fun maybeBeginSession() {
        val engine = service ?: return
        if (!ownerConnected) return
        val current = request ?: return
        if (sessionBegunFor === current) return
        sessionBegunFor = current
        engine.beginSession(current, closeAck, viewerIncarnation, hostSaveChannel)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val received = if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(
                OfficeViewerOutcome.EXTRA_REQUEST,
                OfficePreviewRequest::class.java,
            )
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<OfficePreviewRequest>(OfficeViewerOutcome.EXTRA_REQUEST)
        }
        if (received == null) {
            finishWithOutcome(
                OfficeViewerOutcome("", false, OfficeFailureCode.INTERNAL, "missing request", 0, 0),
            )
            return
        }
        // Strict revalidation of anything that crossed a process boundary
        // (Main review 2026-10-26): shape rules again, and the parcelled
        // format must agree with the staged path; parse failures are kept.
        val valid = received.revalidated()
        if (valid.isFailure) {
            val exception = valid.exceptionOrNull() as? OfficeException
            finishWithOutcome(
                OfficeViewerOutcome(
                    sessionToken = received.sessionToken,
                    closedCleanly = false,
                    failure = exception?.code ?: OfficeFailureCode.INTERNAL,
                    message = exception?.message,
                    witnessWidthTwip = 0,
                    witnessHeightTwip = 0,
                ),
            )
            return
        }
        request = valid.getOrNull()

        // Capability extras are inert references owned by the launching App
        // process; read once from our own non-exported launch Intent. An
        // IBinder is NOT a Parcelable: it travels through the Bundle's
        // putBinder/getBinder pair (API 18+), never the getParcelable family.
        viewerIncarnation = intent.getLongExtra(OfficeCloseAckPolicy.EXTRA_VIEWER_INCARNATION, -1L)
        closeAck = intent.extras?.getBinder(OfficeCloseAckPolicy.EXTRA_CLOSE_ACK)
        // R2 host save-target channel: same trust model as the close-ack
        // capability — an inert IBinder reference from our own non-exported
        // launch Intent, used only for the fenced handoff transactions.
        hostSaveChannel = intent.extras?.getBinder(OfficeEngineCommandsPolicy.EXTRA_HOST_SAVE_CHANNEL)
        // R3 internal destination: the App declares that it owns a private
        // working-copy commit (Notes). The capability itself is still the
        // same-UID host save channel; this extra only selects the dirty-sheet
        // action. Without it everything below behaves exactly as before.
        internalSaveEnabled = intent.getBooleanExtra(OfficeHostSaveHandoffPolicy.EXTRA_INTERNAL_SAVE, false) &&
            hostSaveChannel != null
        // G05-R3 approval-notice capability + App-owned review target: same
        // trust model again. Both are present only for OWNED opens; either
        // missing simply means this surface never shows the banner.
        approvalNoticeCapability = intent.extras?.getBinder(OfficeApprovalNoticePolicy.EXTRA_APPROVAL_NOTICE)
        reviewComponent = if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(
                OfficeApprovalNoticePolicy.EXTRA_REVIEW_COMPONENT,
                ComponentName::class.java,
            )
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<ComponentName>(OfficeApprovalNoticePolicy.EXTRA_REVIEW_COMPONENT)
        }

        if (!OfficeWebViewDirectory.ensureOnce()) {
            deliverLocalFailure(OfficeFailureCode.WEBVIEW_ISOLATION_FAILED, null)
            return
        }

        // Bind the App-process (main) host owner first: BIND_ADJUST_WITH_ACTIVITY
        // keeps the parent — owner of the close capability — unfrozen while
        // this viewer is visible. Inert Binder, same-UID, never exported.
        val ownerStart = Intent(this, OfficeHostOwnerService::class.java)
        ownerBound = bindService(
            ownerStart,
            ownerConnection,
            Context.BIND_AUTO_CREATE or Context.BIND_ADJUST_WITH_ACTIVITY,
        )
        if (!ownerBound) {
            deliverLocalFailure(OfficeFailureCode.INTERNAL, "host owner unavailable")
            return
        }

        val start = Intent(this, OfficeEngineService::class.java)
        bound = bindService(start, connection, Context.BIND_AUTO_CREATE)
        if (!bound) {
            deliverLocalFailure(OfficeFailureCode.INTERNAL, "engine service unavailable")
            return
        }

        setContent {
            val theme = runCatching { FloeThemeMode.valueOf(intent.getStringExtra("com.floe.office.THEME_MODE").orEmpty()) }
                .getOrDefault(FloeThemeMode.AUTO)
            FloeTheme(themeMode = theme) {
                OfficeWindowAppearance(this, theme)
                OfficeViewerScreen(
                    title = request?.displayName.orEmpty(),
                    progress = progress,
                    noticeKey = noticeKey,
                    noticeDetail = noticeDetail,
                    failure = localFailure,
                    viewerUrl = viewerUrl,
                    editableSession = request?.permission == OfficePermission.EDIT,
                    internalSaveSession = internalSaveEnabled,
                    editState = editState,
                    diagnosticEvents = diagnosticEvents,
                    busyPhaseKey = closeSavePhase?.let { phase ->
                        when (phase) {
                            CloseSavePhase.EXPORTING -> "exporting"
                            CloseSavePhase.AWAITING_PICKER -> "picker"
                            CloseSavePhase.AWAITING_APP -> "app"
                            CloseSavePhase.SAVING -> "saving"
                        }
                    } ?: pdfBusyKey?.let { if (it == "export") "pdfExport" else "pdfPrint" },
                    onBack = ::performBack,
                    onToggleEdit = ::toggleEditMode,
                    onSaveCopy = { startSaveCopy(forClose = false) },
                    onSavePdfCopy = { startExportOp(OfficeExportPurpose.SAF_COPY) },
                    onPreviewPdf = { startExportOp(OfficeExportPurpose.PDF_PREVIEW) },
                    onPrintPdf = { startExportOp(OfficeExportPurpose.PDF_PRINT) },
                    onUndo = { requestEditHistory(redo = false) },
                    onRedo = { requestEditHistory(redo = true) },
                    onRefreshDiagnostics = ::refreshDiagnostics,
                    onOpenNotices = {
                        startActivity(Intent(this, OfficeNoticesActivity::class.java).apply {
                            putExtra("com.floe.office.THEME_MODE", intent.getStringExtra("com.floe.office.THEME_MODE"))
                        })
                    },
                    createView = { context -> service?.newViewerWebView(context) },
                    onViewReady = { view ->
                        val token = request?.sessionToken
                        if (view != null && token != null) {
                            viewerView = view
                            service?.attachWebView(view, token, nativeGeneration)
                        } else if (view == null) {
                            deliverLocalFailure(OfficeFailureCode.WEBVIEW_ISOLATION_FAILED, null)
                        }
                    },
                    onViewLeaving = { view ->
                        val token = request?.sessionToken
                        if (token != null) service?.detachWebView(view, token, nativeGeneration)
                        if (viewerView === view) viewerView = null
                        view.destroy()
                    },
                    approvalNoticeTool = approvalNoticeTool,
                    onReviewApproval = {
                        // Bring the existing chat Activity forward WITHOUT
                        // closing this document: the owned editContext stays
                        // valid and the ordinary approval card is already
                        // projected there. Return to THIS viewer is the
                        // explicit "Back to document" strip the App shows on
                        // the owning conversation while this mount is live
                        // (office-return109). System Back on a compact chat
                        // surface keeps its ordinary New Task semantics and
                        // must NOT be claimed to return here — that was the
                        // unproven 107 assumption Main's review rejected.
                        val target = reviewComponent
                        if (target != null) {
                            runCatching {
                                startActivity(
                                    Intent().setComponent(target)
                                        .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                                )
                            }
                        }
                    },
                )
                // Dirty-close guard (editable mounts): explicit user choice,
                // honest outcomes only. An internal-Notes mount offers "Save
                // and close" (one real flush, App-owned snapshot, no picker);
                // a generic host keeps "Save Copy and close", which closes
                // ONLY after the App's verified COPY_SAVED settlement for that
                // exact op. Failure/cancel/UNKNOWN keeps the editor open with
                // everything retained.
                FloeActionSheet(
                    visible = showDirtyCloseSheet,
                    onDismiss = { showDirtyCloseSheet = false },
                    maxCardWidth = 420.dp,
                ) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        FloeText(stringResource(R.string.office_viewer_dirty_title), style = Floe.typography.toolbarTitle)
                        FloeText(
                            stringResource(
                                if (internalSaveEnabled) {
                                    R.string.office_viewer_dirty_internal_message
                                } else {
                                    R.string.office_viewer_dirty_message
                                },
                            ),
                            color = Floe.colors.secondaryLabel,
                        )
                        if (internalSaveEnabled) {
                            FloeCapsuleButton(stringResource(R.string.office_action_save_note_close), onClick = {
                                startInternalSaveAndClose()
                            })
                        } else {
                            FloeCapsuleButton(stringResource(R.string.office_action_save_close), onClick = {
                                startSaveCopy(forClose = true)
                            })
                        }
                        FloeCapsuleButton(stringResource(R.string.office_action_discard_close), onClick = ::discardAndClose)
                        FloeCapsuleButton(stringResource(R.string.office_action_keep_editing), onClick = {
                            showDirtyCloseSheet = false
                        })
                    }
                }
            }
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = performBack()
        })
    }

    private fun performBack() {
        val token = request?.sessionToken
        val engine = service
        if (token == null || engine == null) {
            finishWithOutcome(
                terminalOutcome ?: OfficeViewerOutcome(token.orEmpty(), true, null, null, 0, 0),
            )
            return
        }
        // A close-save is in flight (input frozen, busy cover up): Back is
        // ignored until the App settles or the flow aborts honestly. The same
        // holds for a local PDF export/print hand-off: its terminal receipt
        // decides what opens, and leaving mid-flight could race that proof.
        if (closeSavePhase != null) return
        if (pdfBusyKey != null) return
        if (engine.isMobileWizardVisible(token)) {
            engine.sendMobileWizardBack(token)
            return
        }
        // Conservative dirty-close guard for editable mounts (Main UI
        // acceptance 2026-10-26): once editing was entered OR the kit reports
        // the working copy modified, an ordinary Back never closes silently.
        // Only the explicit Discard choice or a verified App COPY_SAVED
        // close-save bypasses it. Native FLUSHED/UNMODIFIED/ModifiedStatus
        // facts describe the PRIVATE working copy only and never authorize a
        // close (no original writeback or user-visible recovery exists yet).
        val state = editState
        if (request?.permission == OfficePermission.EDIT &&
            (state?.documentModified == true || everEnteredEditMode) &&
            closeAfterExportOpId == null
        ) {
            showDirtyCloseSheet = true
            return
        }
        engine.requestClose(token, "user-back", userInitiated = true)
    }

    // --- R2 edit/save flows (module viewer chrome) ---

    private fun newOpId(prefix: String): String {
        opCounter++
        val suffix = java.util.UUID.randomUUID().toString().replace("-", "").take(12)
        return "$prefix-$opCounter-$suffix"
    }

    /** Suggested export name: the display name with the target extension. */
    private fun suggestedExportName(format: String): String {
        val base = request?.displayName.orEmpty().substringBeforeLast('.', "document")
        return (base.ifBlank { "document" } + "." + format).take(240)
    }

    private fun toggleEditMode() {
        val token = request?.sessionToken ?: return
        val engine = service ?: return
        val enable = editState?.pageEditMode != true
        if (!engine.requestEdit(token, nativeGeneration, enable)) {
            noticeKey = "editUnavailable"
            noticeDetail = null
        }
    }

    /**
     * First-slice Save Copy: exports the CURRENT document in its SAME format
     * (DOCX/XLSX/PPTX; ODF choices stay hidden until separately qualified)
     * to a module-private staged output, then hands the picker flow to the
     * App. The PDF variants live in the editor menu beside it and reuse the
     * same pinned STAGED_EXPORT + OUTPUT_READY proof (Main qualified the
     * local PDF slice 2026-10-27). [forClose] arms the verified-settlement close path:
     * the editor closes ONLY after the App's real COPY_SAVED settlement for
     * that exact op.
     */
    private fun startSaveCopy(forClose: Boolean) {
        val token = request?.sessionToken ?: return
        val format = request?.format?.fileExtension ?: return
        val opId = newOpId("export")
        val op = OfficeSaveRequest.of(
            opId = opId,
            sessionToken = token,
            generation = nativeGeneration,
            operation = OfficeSaveOperation.STAGED_EXPORT,
            format = format,
            suggestedName = suggestedExportName(format),
        ).getOrNull() ?: run {
            noticeKey = "saveFailed"
            noticeDetail = "invalid export request"
            return
        }
        exportPurposes.register(opId, OfficeExportPurpose.SAF_COPY)
        if (forClose) {
            showDirtyCloseSheet = false
            closeAfterExportOpId = opId
            closeSavePhase = CloseSavePhase.EXPORTING
            // Freeze user document input from export through the settlement
            // so no later edit is silently discarded (defocus + hide IME;
            // the busy cover absorbs touches).
            freezeDocumentInput()
        }
        pendingExportFormats[opId] = format
        val receipt = service?.submitSaveOperation(op) ?: run {
            exportPurposes.consume(opId)
            pendingExportFormats.remove(opId)
            if (forClose) abortCloseSave()
            return
        }
        // SUBMITTED/terminal receipts also arrive through onSaveReceipt; only
        // a synchronous REJECTED (never dispatched to listeners) is applied
        // here, so one op can never double-record.
        if (receipt.state == OfficeSaveState.REJECTED) applyReceipt(receipt)
    }

    /**
     * One bounded PDF export op for an explicit LOCAL purpose (preview or
     * print) or the PDF variant of the EXISTING Save-Copy handoff. Reuses
     * the pinned STAGED_EXPORT executor (JNI saveAs + whole-file
     * regular/magic/length/SHA verification) — never a JavaScript egress,
     * WebView screenshot or void=success path. A close-save or another PDF
     * flow already in flight refuses silently (the menu is closed and the
     * busy cover owns input while either runs).
     */
    private fun startExportOp(purpose: OfficeExportPurpose) {
        if (closeSavePhase != null || pdfBusyKey != null) return
        val token = request?.sessionToken ?: return
        val opId = newOpId("export")
        val op = OfficeSaveRequest.of(
            opId = opId,
            sessionToken = token,
            generation = nativeGeneration,
            operation = OfficeSaveOperation.STAGED_EXPORT,
            format = "pdf",
            suggestedName = suggestedExportName("pdf"),
        ).getOrNull() ?: run {
            noticeKey = if (purpose == OfficeExportPurpose.SAF_COPY) "saveFailed" else "pdfFailed"
            noticeDetail = "invalid export request"
            return
        }
        exportPurposes.register(opId, purpose)
        if (purpose == OfficeExportPurpose.SAF_COPY) {
            // Exactly the existing handoff path (App prepares + settles the
            // SAF target; PDF is one of its already-supported formats).
            pendingExportFormats[opId] = "pdf"
        } else {
            pdfBusyKey = "export"
        }
        val receipt = service?.submitSaveOperation(op) ?: run {
            exportPurposes.consume(opId)
            if (purpose != OfficeExportPurpose.SAF_COPY) pdfBusyKey = null
            return
        }
        if (receipt.state == OfficeSaveState.REJECTED) applyReceipt(receipt)
    }

    /**
     * The ONLY path from a LOCAL PDF purpose to a surface: the exact owned
     * receipt re-proved against the real bytes (canonical containment under
     * this app's owned outputs root + op-name binding + %PDF- magic + exact
     * length + whole-file SHA) may open the isolated preview or start print.
     * Nothing here opens the SAF picker, clears dirty state, reports a
     * user-file save or deletes anything.
     */
    private fun openVerifiedPdf(receipt: OfficeSaveReceipt, forPrint: Boolean) {
        pdfBusyKey = null
        val token = request?.sessionToken ?: return
        val (snapshot, error) = OfficePdfReceiptPolicy.openFromReceipt(
            receipt,
            noBackupFilesDir,
            token,
            nativeGeneration,
            receipt.opId,
        )
        if (snapshot == null) {
            noticeKey = "pdfFailed"
            // Path-free identity: the policy enum name only.
            noticeDetail = error?.name
            return
        }
        if (!forPrint) {
            val preview = Intent(this, OfficePdfPreviewActivity::class.java).apply {
                putExtra(
                    OfficePdfPreviewRequest.EXTRA_REQUEST,
                    OfficePdfPreviewRequest.of(snapshot, request?.displayName.orEmpty()),
                )
                putExtra("com.floe.office.THEME_MODE", intent.getStringExtra("com.floe.office.THEME_MODE"))
            }
            runCatching { startActivity(preview) }.onFailure {
                noticeKey = "pdfFailed"
                noticeDetail = "preview-unavailable"
            }
        } else {
            startPdfPrint(snapshot)
        }
    }

    /**
     * Print over the verified snapshot: the REAL page count comes from the
     * isolated renderer first (never guessed), then the foreground system
     * PrintManager dialog. Dialog/scope acceptance is NOT printing — the
     * notice says "handed to the system", and no UI path claims completion.
     */
    private fun startPdfPrint(snapshot: VerifiedPdfSnapshot) {
        val host = pdfRenderHost ?: OfficePdfRenderHost(this).also { pdfRenderHost = it }
        pdfBusyKey = "print"
        val label = suggestedExportName("pdf")
        host.documentInfo(snapshot) { result ->
            pdfBusyKey = null
            if (isDestroyed || isFinishing) return@documentInfo
            when (result) {
                is PdfDocResult.Ready -> OfficePdfPrintFlow.requestPrint(
                    this,
                    snapshot,
                    result.pageCount,
                    label,
                ) { outcome ->
                    if (isDestroyed || isFinishing) return@requestPrint
                    noticeKey = when (outcome) {
                        PrintStartOutcome.DialogOpened -> "printSubmitted"
                        PrintStartOutcome.NoPrintService -> "printUnavailable"
                        PrintStartOutcome.ActivityRetired -> "printUnavailable"
                        PrintStartOutcome.SourceUnavailable -> "pdfFailed"
                    }
                    noticeDetail = null
                }
                is PdfDocResult.Failed -> {
                    noticeKey = "pdfFailed"
                    noticeDetail = when (result.failure) {
                        com.floe.android.core.officeengine.pdf.PdfFailure.PasswordProtected -> "PASSWORD"
                        com.floe.android.core.officeengine.pdf.PdfFailure.InvalidPdf -> "INVALID_PDF"
                        com.floe.android.core.officeengine.pdf.PdfFailure.Busy -> "BUSY"
                        com.floe.android.core.officeengine.pdf.PdfFailure.Transport -> "TRANSPORT"
                    }
                }
            }
        }
    }

    /** Maps one receipt to the honest transient notice + Save-Copy handoff. */
    private fun applyReceipt(receipt: OfficeSaveReceipt) {
        if (receipt.generation != 0L && !accepts(receipt.sessionToken, receipt.generation)) return
        synchronized(saveReceipts) {
            saveReceipts.add(receipt)
            while (saveReceipts.size > OfficeViewerOutcome.MAX_RECEIPT_DESCRIPTORS) saveReceipts.removeAt(0)
        }
        // Internal Notes save is its own narrowed lane: never let its
        // FLUSHED/UNMODIFIED receipt clear the external copy state or show
        // the working-copy-only "Saved" notice. A duplicate after settlement
        // opens nothing.
        if (receipt.opId == internalSaveOpId) {
            applyInternalSaveReceipt(receipt)
            return
        }
        val isCloseSave = closeAfterExportOpId == receipt.opId
        when (receipt.state) {
            OfficeSaveState.SUBMITTED -> Unit // no notice: terminal states speak
            OfficeSaveState.FLUSHED -> {
                // Working-copy fact only — never clears the user-destination
                // unsaved state and never authorizes a close.
                noticeKey = "saveFlushed"
                noticeDetail = null
            }
            OfficeSaveState.UNMODIFIED -> {
                noticeKey = "saveUnmodified"
                noticeDetail = null
            }
            OfficeSaveState.OUTPUT_READY -> {
                // Exact-once purpose consumption decides EVERYTHING (Main
                // contract 2026-10-27): a stale, foreign or duplicate
                // terminal for an already-consumed op opens nothing at all.
                when (exportPurposes.consume(receipt.opId)) {
                    null -> Unit
                    OfficeExportPurpose.SAF_COPY -> {
                        if (isCloseSave) closeSavePhase = CloseSavePhase.AWAITING_PICKER
                        else noticeKey = "copyStaged"
                        beginHostSaveHandoff(receipt)
                    }
                    OfficeExportPurpose.PDF_PREVIEW -> openVerifiedPdf(receipt, forPrint = false)
                    OfficeExportPurpose.PDF_PRINT -> openVerifiedPdf(receipt, forPrint = true)
                }
            }
            OfficeSaveState.FAILED, OfficeSaveState.UNKNOWN -> {
                val purpose = exportPurposes.consume(receipt.opId)
                val localPdf = purpose == OfficeExportPurpose.PDF_PREVIEW ||
                    purpose == OfficeExportPurpose.PDF_PRINT
                if (purpose == OfficeExportPurpose.SAF_COPY) pendingExportFormats.remove(receipt.opId)
                if (isCloseSave) abortCloseSave()
                if (localPdf) {
                    pdfBusyKey = null
                    noticeKey = "pdfFailed"
                } else {
                    noticeKey = if (receipt.state == OfficeSaveState.UNKNOWN) "saveUnknown" else "saveFailed"
                }
                noticeDetail = (receipt.failure?.name ?: "") + (receipt.message?.let { ": $it" } ?: "")
            }
            OfficeSaveState.CANCELLED -> {
                val purpose = exportPurposes.consume(receipt.opId)
                if (purpose == OfficeExportPurpose.PDF_PREVIEW || purpose == OfficeExportPurpose.PDF_PRINT) {
                    pdfBusyKey = null
                }
                if (purpose == OfficeExportPurpose.SAF_COPY) pendingExportFormats.remove(receipt.opId)
                if (isCloseSave) abortCloseSave()
            }
            OfficeSaveState.REJECTED -> {
                val purpose = exportPurposes.consume(receipt.opId)
                if (purpose == OfficeExportPurpose.PDF_PREVIEW || purpose == OfficeExportPurpose.PDF_PRINT) {
                    pdfBusyKey = null
                }
                if (purpose == OfficeExportPurpose.SAF_COPY) pendingExportFormats.remove(receipt.opId)
                if (isCloseSave) abortCloseSave()
                noticeKey = if (purpose == OfficeExportPurpose.PDF_PREVIEW || purpose == OfficeExportPurpose.PDF_PRINT) {
                    "pdfFailed"
                } else {
                    "saveFailed"
                }
                noticeDetail = receipt.failure?.name
            }
        }
    }

    /**
     * OUTPUT_READY is a PRIVATE staged artifact, never "Saved". The generic
     * host seam hands the App the exact op identity so IT can prepare the
     * system save-target picker; THIS foreground Activity launches it (the
     * background App must not assume BAL permission) and forwards the actual
     * URI + returned flags back. No SAF logic lives here.
     */
    private fun beginHostSaveHandoff(receipt: OfficeSaveReceipt) {
        val format = receipt.format ?: pendingExportFormats[receipt.opId] ?: run {
            if (closeAfterExportOpId == receipt.opId) abortCloseSave()
            return
        }
        val channel = hostSaveChannel
        val prepared = channel?.let {
            OfficeHostSaveChannel.requestPrepareTarget(
                it,
                receipt.opId,
                receipt.sessionToken,
                receipt.generation,
                format,
                receipt.suggestedName ?: suggestedExportName(format),
            )
        }
        if (prepared == null) {
            if (closeAfterExportOpId == receipt.opId) abortCloseSave()
            noticeKey = "hostTargetUnavailable"
            noticeDetail = receipt.outputDocumentPath
            return
        }
        pendingHandoffOpId = receipt.opId
        pendingHandoffFormat = format
        runCatching { saveTargetLauncher.launch(prepared) }.onFailure {
            pendingHandoffOpId = null
            pendingHandoffFormat = null
            if (closeAfterExportOpId == receipt.opId) abortCloseSave()
            noticeKey = "hostTargetUnavailable"
            noticeDetail = receipt.outputDocumentPath
        }
    }

    /**
     * R3 internal Notes save-and-close. One real `WORKING_COPY_FLUSH` on the
     * existing engine lane (`.uno:Save`, dontTerminateEdit=1) writes the
     * latest in-memory state to the App-owned working copy; the engine
     * re-reads and digests it. Only a FLUSHED/UNMODIFIED receipt with real
     * working-copy facts is offered to the host, which re-verifies and
     * snapshots the bytes before answering. Accepted -> close; refused,
     * failed or unknown -> the editor stays open with the working copy and
     * any recovery data retained. No SAF, URI or path is created here.
     */
    private fun startInternalSaveAndClose() {
        if (closeSavePhase != null || pdfBusyKey != null) return
        // Never start a working-copy flush underneath an external Save-Copy
        // picker/settlement: the two destinations must not interleave.
        if (pendingHandoffOpId != null) return
        if (synchronized(awaitingSettlementOps) { awaitingSettlementOps.isNotEmpty() }) return
        val token = request?.sessionToken ?: return
        if (request?.permission != OfficePermission.EDIT) return
        val opId = newOpId("internal")
        val op = OfficeSaveRequest.of(
            opId = opId,
            sessionToken = token,
            generation = nativeGeneration,
            operation = OfficeSaveOperation.WORKING_COPY_FLUSH,
            // false = dontSaveIfUnmodified=0: an explicit user save must
            // produce a real write + verified digest, never a silent skip.
            saveIfUnmodified = false,
        ).getOrNull() ?: run {
            noticeKey = "saveFailed"
            noticeDetail = "invalid internal save request"
            return
        }
        showDirtyCloseSheet = false
        internalSaveOpId = opId
        closeSavePhase = CloseSavePhase.SAVING
        // No input may land between this freeze and the flush; the busy
        // cover also absorbs touches.
        freezeDocumentInput()
        val receipt = service?.submitSaveOperation(op) ?: run {
            internalSaveOpId = null
            abortCloseSave()
            noticeKey = "saveFailed"
            noticeDetail = "editor unavailable"
            return
        }
        // A synchronous REJECTED was never dispatched to listeners; apply it
        // through the same narrowed handler exactly once.
        if (receipt.state == OfficeSaveState.REJECTED) applyReceipt(receipt)
    }

    private fun applyInternalSaveReceipt(receipt: OfficeSaveReceipt) {
        when (receipt.state) {
            OfficeSaveState.SUBMITTED -> Unit
            OfficeSaveState.FLUSHED, OfficeSaveState.UNMODIFIED -> {
                if (internalSaveHandoffInFlight) return
                val sha = receipt.workingCopySha256
                val bytes = receipt.workingCopyBytes
                val format = request?.format?.fileExtension
                if (sha == null || bytes <= 0L || format == null) {
                    abortInternalSave("saveFailed", "working copy unavailable")
                    return
                }
                val notice = OfficeHostSaveHandoffPolicy.InternalSaveNotice(
                    opId = receipt.opId,
                    sessionToken = receipt.sessionToken,
                    generation = receipt.generation,
                    format = format,
                    workingCopySha256 = sha,
                    workingCopyBytes = bytes,
                )
                internalSaveHandoffInFlight = true
                // The App re-reads/digests/snapshots its own working copy, so
                // this bounded verification runs off the main thread; the
                // busy cover keeps input frozen until the answer arrives.
                runCatching {
                    Thread({
                        val answer = OfficeHostSaveChannel.postInternalSave(hostSaveChannel, notice)
                        mainHandler.post {
                            internalSaveHandoffInFlight = false
                            if (isDestroyed || isFinishing) return@post
                            if (answer != OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_ACCEPTED &&
                                answer != OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_UNCHANGED
                            ) {
                                if (answer == OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REFUSED) {
                                    abortInternalSave("hostTargetUnavailable", null)
                                } else {
                                    abortInternalSave("saveFailed", "internalDestinationRejected")
                                }
                                return@post
                            }
                            // The App verified + snapshotted the exact bytes;
                            // only now may this mount close. The App commits
                            // the Note after the Activity result (its own
                            // Root/revision checks still apply).
                            internalSaveOpId = null
                            closeSavePhase = null
                            noticeKey = null
                            noticeDetail = null
                            request?.sessionToken?.let { token ->
                                service?.requestClose(token, "user-back", userInitiated = true)
                            }
                        }
                    }, "office-internal-save").start()
                }.onFailure {
                    internalSaveHandoffInFlight = false
                    abortInternalSave("saveFailed", "internalSaveUnavailable")
                }
            }
            OfficeSaveState.FAILED, OfficeSaveState.UNKNOWN -> {
                abortInternalSave(
                    if (receipt.state == OfficeSaveState.UNKNOWN) "saveUnknown" else "saveFailed",
                    (receipt.failure?.name ?: "") + (receipt.message?.let { ": $it" } ?: ""),
                )
            }
            OfficeSaveState.CANCELLED, OfficeSaveState.REJECTED ->
                abortInternalSave("saveFailed", receipt.failure?.name)
            else -> abortInternalSave("saveFailed", "unexpected internal save state")
        }
    }

    private fun abortInternalSave(notice: String, detail: String?) {
        internalSaveOpId = null
        internalSaveHandoffInFlight = false
        closeSavePhase = null
        unfreezeDocumentInput()
        noticeKey = notice
        noticeDetail = detail
    }

    /**
     * Ends a close-save attempt honestly: the editor stays open, input is
     * unfrozen, the staged output and working copy are retained, and no
     * close is authorized.
     */
    private fun abortCloseSave() {
        closeAfterExportOpId = null
        closeSavePhase = null
        unfreezeDocumentInput()
    }

    /**
     * The ONLY non-settlement close bypass of the dirty guard: an explicit
     * user Discard. Nothing is auto-saved; the working copy and any staged
     * outputs stay on disk for the App's recovery ledgers.
     */
    private fun discardAndClose() {
        showDirtyCloseSheet = false
        request?.sessionToken?.let { service?.requestClose(it, "user-back", userInitiated = true) }
    }

    private fun freezeDocumentInput() {
        runCatching {
            val focused = currentFocus
            if (focused != null) {
                (getSystemService(Context.INPUT_METHOD_SERVICE) as? android.view.inputmethod.InputMethodManager)
                    ?.hideSoftInputFromWindow(focused.windowToken, 0)
                focused.clearFocus()
            }
        }
    }

    private fun unfreezeDocumentInput() {
        // The busy cover is state-driven; focus returns to the page on the
        // next user interaction (no forced focus stealing).
        runCatching { viewerView?.requestFocus() }
    }

    private fun requestEditHistory(redo: Boolean) {
        val token = request?.sessionToken ?: return
        if (service?.requestEditHistory(token, nativeGeneration, redo) != true) {
            noticeKey = "editUnavailable"
            noticeDetail = null
        }
    }

    private fun refreshDiagnostics() {
        val token = request?.sessionToken ?: return
        diagnosticEvents = service?.diagnosticsSnapshot(token, nativeGeneration) ?: emptyList()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val dark = newConfig.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        service?.setAppearance(appearanceOverride())
        service?.onNightModeChanged(appearanceOverride() ?: dark)
    }

    private fun appearanceOverride(): Boolean? = when (intent.getStringExtra("com.floe.office.THEME_MODE")) {
        "LIGHT" -> false
        "DARK" -> true
        else -> null
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) request?.sessionToken?.let { service?.refreshVisibleFrame(it, nativeGeneration) }
    }

    override fun onResume() {
        super.onResume()
        startApprovalNoticePoll()
    }

    override fun onPause() {
        stopApprovalNoticePoll()
        super.onPause()
    }

    /**
     * Starts the approval-notice poll for THIS exact mount. The synchronous
     * parent query runs on ONE dedicated background thread (never the main
     * thread); results are applied on the main thread behind a generation
     * fence, so an answer that outlives its poll round (pause/close) can
     * never overwrite newer state. No query is issued for unowned opens or
     * while the capability is absent — the banner simply never exists there.
     * The poll re-checks continuously because an approval may be captured at
     * any time while the document is open, and resolved just as freely in
     * the chat the banner routes to.
     */
    private fun startApprovalNoticePoll() {
        if (noticeThread != null) return
        val capability = approvalNoticeCapability ?: return
        val token = request?.sessionToken ?: return
        val ownerTaskId = request?.ownerTaskId ?: return
        val incarnation = viewerIncarnation
        if (incarnation < 1L) return
        val thread = HandlerThread("office-approval-notice").apply { start() }
        val handler = Handler(thread.looper)
        noticeThread = thread
        noticeHandler = handler
        val seq = ++noticeSeq
        val poll = object : Runnable {
            override fun run() {
                val answer = OfficeApprovalNotice.queryPending(
                    capability,
                    token,
                    incarnation,
                    ownerTaskId,
                )
                mainHandler.post {
                    // The parent validated the exact current VIEWING operation
                    // on every query: a close/settle/replacement simply
                    // answers null and the banner withdraws by itself.
                    if (seq == noticeSeq) approvalNoticeTool = answer
                }
                handler.postDelayed(this, APPROVAL_NOTICE_POLL_MS)
            }
        }
        handler.post(poll)
    }

    /** Tears the poll down and invalidates any in-flight answer. */
    private fun stopApprovalNoticePoll() {
        noticeSeq++
        noticeHandler?.removeCallbacksAndMessages(null)
        noticeThread?.quitSafely()
        noticeHandler = null
        noticeThread = null
    }

    override fun onDestroy() {
        stopApprovalNoticePoll()
        internalSaveOpId = null
        internalSaveHandoffInFlight = false
        exportPurposes.clear()
        pdfBusyKey = null
        pdfRenderHost?.release()
        pdfRenderHost = null
        if (bound) {
            runCatching { unbindService(connection) }
            bound = false
        }
        if (ownerBound) {
            runCatching { unbindService(ownerConnection) }
            ownerBound = false
        }
        ownerConnected = false
        service?.removeListener(this)
        super.onDestroy()
    }

    // --- OfficeEngineService.OfficeEngineListener (main thread) ---

    override fun onProgress(progress: OfficeViewerProgress) {
        if (!accepts(progress.sessionToken, progress.generation)) return
        this.progress = progress
        if ((progress.state == OfficeViewerState.READY_READ_ONLY ||
                progress.state == OfficeViewerState.READY_EDITABLE) &&
            noticeKey == "awaitingRender"
        ) {
            noticeKey = null
            noticeDetail = null
        }
    }

    private fun accepts(token: String, generation: Long): Boolean {
        if (isDestroyed || isFinishing || token != request?.sessionToken || generation < nativeGeneration) return false
        if (generation > nativeGeneration) nativeGeneration = generation
        return true
    }

    override fun onNotice(sessionToken: String, generation: Long, key: String, detail: String?) {
        if (!accepts(sessionToken, generation)) return
        noticeKey = key
        noticeDetail = detail
    }

    override fun onSaveReceipt(receipt: OfficeSaveReceipt) {
        applyReceipt(receipt)
    }

    override fun onEditState(state: OfficeEditState) {
        if (!accepts(state.sessionToken, state.generation)) return
        if (state.pageEditMode) everEnteredEditMode = true
        editState = state
    }

    /**
     * The App's terminal Save-Copy settlement — the ONLY event that may show
     * a saved-to-destination outcome or authorize a close-save (COPY_SAVED
     * after the real provider write + readback). Fenced by token+generation
     * AND the exact pending opId, accepted exactly once per op: unknown,
     * stale or duplicate settlements are ignored and never replace the
     * current notice or close the editor (Main UI acceptance 2026-10-26).
     */
    override fun onHostSaveSettlement(settlement: OfficeHostSaveSettlement) {
        if (!accepts(settlement.sessionToken, settlement.generation)) return
        val known = synchronized(awaitingSettlementOps) { awaitingSettlementOps.remove(settlement.opId) }
        if (!known) return
        val isCloseSave = closeAfterExportOpId == settlement.opId
        when (settlement.verdict) {
            OfficeHostSaveVerdict.COPY_SAVED -> {
                if (isCloseSave) {
                    closeAfterExportOpId = null
                    closeSavePhase = null
                    noticeKey = "copySaved"
                    noticeDetail = null
                    request?.sessionToken?.let {
                        service?.requestClose(it, "user-back", userInitiated = true)
                    }
                } else {
                    noticeKey = "copySaved"
                    noticeDetail = settlement.message?.take(240)
                }
            }
            OfficeHostSaveVerdict.COPY_FAILED -> {
                if (isCloseSave) abortCloseSave()
                noticeKey = "copyFailed"
                noticeDetail = settlement.message?.take(240)
            }
            OfficeHostSaveVerdict.COPY_CANCELLED -> {
                if (isCloseSave) abortCloseSave()
                noticeKey = "pickerCancelled"
                noticeDetail = settlement.message?.take(240)
            }
        }
    }

    override fun onLoadUrl(sessionToken: String, generation: Long, url: String) {
        if (!accepts(sessionToken, generation)) return
        viewerUrl = url
    }

    /** Renderer success is separately verified by the owned canvas hook.
     * Here the visual-state callback and PixelCopy SUCCESS confirm that the
     * same live WebView surface reached the compositor. Pixel variance is
     * deliberately irrelevant: a legitimate blank document must pass.
     */
    override fun onPaintProbeRequested(sessionToken: String, generation: Long) {
        if (!accepts(sessionToken, generation)) return
        val view = viewerView
        if (view == null) { service?.reportPaintProbe(sessionToken, generation, false); return }
        val engine = service ?: return
        fun currentFrame(): Boolean = viewerView === view && !isDestroyed && !isFinishing &&
            request?.sessionToken == sessionToken && nativeGeneration == generation &&
            view.isAttachedToWindow && view.isShown && view.width >= 48 && view.height >= 48 && hasWindowFocus()
        fun answer(passed: Boolean) {
            if (viewerView === view && !isDestroyed && request?.sessionToken == sessionToken && nativeGeneration == generation)
                engine.reportPaintProbe(sessionToken, generation, passed)
        }
        if (!currentFrame()) { answer(false); return }
        try {
            view.postVisualStateCallback(generation, object : android.webkit.WebView.VisualStateCallback() {
                override fun onComplete(requestId: Long) {
                    if (!currentFrame()) { answer(false); return }
                    view.postOnAnimation frame@ {
                        if (!currentFrame()) { answer(false); return@frame }
                        val location = IntArray(2)
                        view.getLocationInWindow(location)
                        val width = minOf(view.width, 720)
                        val height = minOf(view.height, 480)
                        val x = location[0] + (view.width - width) / 2
                        val y = location[1] + (view.height - height) / 2
                        val bitmap = android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888)
                        try {
                            android.view.PixelCopy.request(window, android.graphics.Rect(x, y, x + width, y + height), bitmap,
                                { result ->
                                    bitmap.recycle()
                                    answer(result == android.view.PixelCopy.SUCCESS && currentFrame())
                                }, android.os.Handler(mainLooper))
                        } catch (_: Exception) {
                            bitmap.recycle()
                            answer(false)
                        }
                    }
                }
            })
        } catch (_: Exception) { answer(false) }
    }

    override fun onTerminal(outcome: OfficeViewerOutcome) {
        if (outcome.sessionToken != request?.sessionToken || isDestroyed || isFinishing) return
        if (outcome.generation != 0L && !accepts(outcome.sessionToken, outcome.generation)) return
        finishWithOutcome(outcome)
    }

    private fun deliverLocalFailure(code: OfficeFailureCode, message: String?) {
        localFailure = code to message
        finishWithOutcome(
            OfficeViewerOutcome(
                sessionToken = request?.sessionToken.orEmpty(),
                closedCleanly = false,
                failure = code,
                message = message,
                witnessWidthTwip = 0,
                witnessHeightTwip = 0,
            ),
        )
    }

    private fun finishWithOutcome(outcome: OfficeViewerOutcome) {
        if (terminalOutcome != null) return
        terminalOutcome = outcome
        val data = Intent().apply {
            putExtra(OfficeViewerOutcome.EXTRA_SESSION_TOKEN, outcome.sessionToken)
            putExtra(OfficeViewerOutcome.EXTRA_CLOSED_CLEANLY, outcome.closedCleanly)
            outcome.failure?.let { failure ->
                putExtra(OfficeViewerOutcome.EXTRA_FAILURE_CODE, failure.name)
                outcome.message?.let { putExtra(OfficeViewerOutcome.EXTRA_FAILURE_MESSAGE, it) }
            }
            putExtra(OfficeViewerOutcome.EXTRA_WITNESS_WIDTH, outcome.witnessWidthTwip)
            putExtra(OfficeViewerOutcome.EXTRA_WITNESS_HEIGHT, outcome.witnessHeightTwip)
            putExtra(OfficeViewerOutcome.EXTRA_GENERATION, outcome.generation)
            // R2 honest close facts (all default-safe for R1 readers).
            putExtra(OfficeViewerOutcome.EXTRA_DIRTY_AT_CLOSE, outcome.dirtyAtClose)
            putExtra(
                OfficeViewerOutcome.EXTRA_EDIT_PERMISSION_ESTABLISHED,
                outcome.editPermissionEstablished,
            )
            putExtra(OfficeViewerOutcome.EXTRA_SAVE_RECEIPT_COUNT, outcome.saveReceiptCount)
            if (outcome.saveReceiptDescriptors.isNotEmpty()) {
                putStringArrayListExtra(
                    OfficeViewerOutcome.EXTRA_SAVE_RECEIPT_DESCRIPTORS,
                    ArrayList(outcome.saveReceiptDescriptors),
                )
            }
        }
        val resultCode = if (outcome.failure == null) RESULT_OK else RESULT_CANCELED
        setResult(resultCode, data)
        finish()
    }

    companion object {
        /** Approval-notice poll cadence while the viewer is foreground. A
         *  captured Ask-first approval is human-driven state (it resolves
         *  only by an explicit chat decision), so a one-second visibility
         *  delay is honest and cheap; the query itself is a tiny same-UID
         *  binder round-trip on a dedicated thread. */
        private const val APPROVAL_NOTICE_POLL_MS = 1_000L

        internal fun intentFor(context: Context, request: OfficePreviewRequest): Intent =
            Intent(context, OfficePreviewActivity::class.java).apply {
                putExtra(OfficeViewerOutcome.EXTRA_REQUEST, request)
            }
    }
}

/**
 * Viewer layout: compact Floe toolbar row (Back left, title, contextual
 * actions right), the document content area (engine WebView) below, an
 * honest progress row outside the document viewport until real paint
 * witnesses arrive, an optional notice line for refused routes, and a
 * terminal error view. Native content fills only the content area and never
 * covers the host toolbar.
 *
 * R2 editor chrome (editable mounts only, Main UI contract 2026-10-26):
 * ONE explicit Edit Copy toggle (the existing square_pencil glyph
 * FloeIcons.NewTask, matching iOS square.and.pencil) + ellipsis document
 * menu in the existing toolbar — no floating engine buttons, no new large
 * command bars, and NO public private-flush save button in this slice (the
 * flush API remains internal for the App stage). The menu's primary Save
 * Copy exports the current same format directly; unqualified ODF/PDF
 * choices stay hidden until separately qualified. A close-save in flight
 * shows an owned busy cover that absorbs touches so no later edit is
 * silently discarded.
 */
@Composable
private fun OfficeViewerScreen(
    title: String,
    progress: OfficeViewerProgress?,
    noticeKey: String?,
    noticeDetail: String?,
    failure: Pair<OfficeFailureCode, String?>?,
    viewerUrl: String?,
    editableSession: Boolean,
    internalSaveSession: Boolean = false,
    editState: OfficeEditState?,
    diagnosticEvents: List<OfficeSessionDiagnostics.Event>,
    busyPhaseKey: String?,
    onBack: () -> Unit,
    onToggleEdit: () -> Unit,
    onSaveCopy: () -> Unit,
    onSavePdfCopy: () -> Unit,
    onPreviewPdf: () -> Unit,
    onPrintPdf: () -> Unit,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onRefreshDiagnostics: () -> Unit,
    onOpenNotices: () -> Unit,
    createView: (Context) -> COWebView?,
    onViewReady: (COWebView?) -> Unit,
    onViewLeaving: (COWebView) -> Unit,
    /** G05-R3 approval notice: non-null ONLY while the parent answers that
     *  this exact mount's OWNING conversation holds a captured pending
     *  approval (the tool name itself is an admission signal and is NOT
     *  rendered here — office-return109). The row below the toolbar appears
     *  ONLY while pending; it navigates to review and never decides
     *  anything itself. */
    approvalNoticeTool: String? = null,
    onReviewApproval: () -> Unit = {},
) {
    val state = progress?.state ?: OfficeViewerState.IDLE
    val editorReady = editableSession &&
        (state == OfficeViewerState.READY_EDITABLE || editState?.editPermissionEstablished == true)
    val pageEditing = editState?.pageEditMode == true
    var showInfo by remember { mutableStateOf(false) }
    var showDetails by remember { mutableStateOf(false) }
    var showEditorMenu by remember { mutableStateOf(false) }

    FloeActionSheet(visible = showDetails, onDismiss = { showDetails = false }, maxCardWidth = 560.dp) {
        Column(Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            FloeText(stringResource(R.string.office_viewer_details), style = Floe.typography.toolbarTitle)
            // Bounded RAM-only session history survives later notices (R1 C8
            // lesson). Local explicit view only: never logged or persisted.
            if (diagnosticEvents.isEmpty()) {
                FloeText(stringResource(R.string.office_viewer_details_empty), style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel)
            } else {
                diagnosticEvents.forEach { event ->
                    FloeText(
                        text = "${event.elapsedRealtimeMs} ${event.kind} ${event.detail}".trim(),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
            // The transient notice detail stays reachable too.
            FloeText(noticeDetail.orEmpty().take(3072), style = Floe.typography.metadata)
            FloeCapsuleButton(stringResource(R.string.office_viewer_done), onClick = { showDetails = false })
        }
    }
    FloeActionSheet(visible = showEditorMenu, onDismiss = { showEditorMenu = false }, maxCardWidth = 420.dp) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            FloeCapsuleButton(stringResource(R.string.office_action_save_copy), onClick = {
                showEditorMenu = false
                onSaveCopy()
            })
            FloeCapsuleButton(stringResource(R.string.office_action_save_pdf), onClick = {
                showEditorMenu = false
                onSavePdfCopy()
            })
            FloeCapsuleButton(stringResource(R.string.office_action_pdf_preview), onClick = {
                showEditorMenu = false
                onPreviewPdf()
            })
            FloeCapsuleButton(stringResource(R.string.office_action_pdf_print), onClick = {
                showEditorMenu = false
                onPrintPdf()
            })
            FloeCapsuleButton(stringResource(R.string.office_action_undo), onClick = {
                showEditorMenu = false
                onUndo()
            })
            FloeCapsuleButton(stringResource(R.string.office_action_redo), onClick = {
                showEditorMenu = false
                onRedo()
            })
            FloeCapsuleButton(stringResource(R.string.office_viewer_details), onClick = {
                showEditorMenu = false
                onRefreshDiagnostics()
                showDetails = true
            })
            FloeCapsuleButton(stringResource(R.string.office_viewer_notices), onClick = {
                showEditorMenu = false
                onOpenNotices()
            })
            FloeCapsuleButton(stringResource(R.string.office_viewer_done), onClick = { showEditorMenu = false })
        }
    }
    FloeActionSheet(visible = showInfo, onDismiss = { showInfo = false }, maxCardWidth = 420.dp) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            FloeText(
                stringResource(
                    if (editableSession) R.string.office_viewer_editing_cd else R.string.office_viewer_readonly_cd,
                ),
                style = Floe.typography.toolbarTitle,
            )
            FloeText(
                stringResource(
                    when {
                        !editableSession -> R.string.office_viewer_preview_info
                        internalSaveSession -> R.string.office_viewer_edit_note_info
                        else -> R.string.office_viewer_edit_info
                    },
                ),
                color = Floe.colors.secondaryLabel,
            )
            // The bounded session history is an EXPLICIT local view, reachable
            // in every state (Main observation 2026-10-26: a stuck "Opening"
            // session records no jsError, so gating this on one notice key made
            // the actual facts uninspectable exactly when they were needed).
            // It is never a readiness shortcut: opening it changes no state and
            // claims nothing.
            FloeCapsuleButton(stringResource(R.string.office_viewer_details), onClick = {
                showInfo = false
                onRefreshDiagnostics()
                showDetails = true
            })
            FloeCapsuleButton(stringResource(R.string.office_viewer_notices), onClick = {
                showInfo = false
                onOpenNotices()
            })
            FloeCapsuleButton(stringResource(R.string.office_viewer_done), onClick = { showInfo = false })
        }
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface)
            .safeDrawingPadding(),
    ) {
        FloeToolbar(
            title = title,
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.office_viewer_back_cd),
                    onClick = onBack,
                )
            },
            actions = {
                if (editorReady) {
                    // The ONE Office Edit Copy action: existing square_pencil
                    // glyph (FloeIcons.NewTask), Office-specific description,
                    // matching the agreed iOS square.and.pencil contract.
                    FloeCircleButton(
                        icon = FloeIcons.NewTask,
                        contentDescription = stringResource(
                            if (pageEditing) R.string.office_viewer_view_cd else R.string.office_viewer_edit_cd,
                        ),
                        onClick = onToggleEdit,
                    )
                    FloeCircleButton(
                        icon = FloeIcons.Ellipsis,
                        contentDescription = stringResource(R.string.office_viewer_more_cd),
                        onClick = { showEditorMenu = true },
                    )
                } else {
                    FloeCircleButton(
                        icon = FloeIcons.InfoCircle,
                        contentDescription = stringResource(R.string.office_viewer_readonly_cd),
                        onClick = {
                            // Refresh for EVERY session kind: the Info sheet's
                            // Technical details action is now always reachable.
                            onRefreshDiagnostics()
                            showInfo = true
                        },
                    )
                }
            },
            showHairline = true,
        )
        // G05-R3 approval notice (office-approval107, copy amended by
        // office-return109): one slim row, shown ONLY while the parent
        // answers that THIS exact mount's owning conversation holds a
        // captured pending approval (the parent re-validates on every poll,
        // so close/settle/replacement withdraws it by itself). Tapping
        // Review raises the existing chat Activity — the document stays
        // open underneath and the approval is reviewed and decided on the
        // ordinary conversation card. The compact return back to THIS
        // document is the explicit "Back to document" strip the App owns on
        // the conversation surface (109); Back here is NOT claimed. The
        // pending tool identifier is deliberately NOT rendered in this row:
        // product copy stays human ("review it in the chat task") and the
        // identifier remains on the explicit approval card where it is
        // meaningful. This row never decides anything and never renders
        // engine details.
        if (approvalNoticeTool != null) {
            val approvalTitle = stringResource(R.string.office_approval_banner_title)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .clickable(onClick = onReviewApproval)
                    .semantics { contentDescription = approvalTitle }
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Image(
                    imageVector = FloeIcons.ShieldAlert,
                    contentDescription = null,
                    colorFilter = ColorFilter.tint(Floe.colors.pending),
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    FloeText(
                        text = approvalTitle,
                        style = Floe.typography.metadata,
                        color = Floe.colors.label,
                    )
                    FloeText(
                        text = stringResource(R.string.office_approval_banner_body),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                Spacer(Modifier.width(10.dp))
                FloeText(
                    text = stringResource(R.string.office_approval_banner_review),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.accent,
                )
            }
        }
        // Honest lifecycle representation (Main decision 2026-10-26): the
        // opening row is shown only while a document genuinely still opens.
        // FAILED keeps the notice row with the actual error detail; CLOSING
        // waits on the bounded close/reclaim path. Neither may keep claiming
        // "Opening" indefinitely. Same rows and layout, state condition only.
        if (failure == null && state != OfficeViewerState.READY_READ_ONLY &&
            state != OfficeViewerState.READY_EDITABLE &&
            state != OfficeViewerState.FAILED && state != OfficeViewerState.CLOSING
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 36.dp).padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeActivityIndicator(modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                FloeText(
                    text = stringResource(R.string.office_viewer_opening),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        noticeKey?.let { key ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 40.dp)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                NoticeGlyph(key)
                Spacer(Modifier.width(10.dp))
                FloeText(
                    text = noticeText(key, noticeDetail),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            val failureState = failure
            if (failureState != null) {
                FloeUnavailableView(
                    icon = FloeIcons.WarningTriangle,
                    title = stringResource(R.string.office_viewer_failed_title),
                    description = failureMessage(failureState.first, failureState.second),
                    modifier = Modifier.align(Alignment.Center),
                )
            } else {
                val url = viewerUrl
                if (url != null) {
                    AndroidView(
                        factory = { context ->
                            val view = createView(context)
                            onViewReady(view)
                            view ?: android.view.View(context)
                        },
                        modifier = Modifier.fillMaxSize(),
                        onRelease = { view ->
                            if (view is COWebView) onViewLeaving(view)
                        },
                    )
                }
            }
            // Owned busy cover while a close-save is in flight: absorbs
            // touches over the engine view (IME already hidden, focus
            // cleared) so no edit lands between export and the App's
            // verified settlement. Honest phase text; never a fake success.
            if (busyPhaseKey != null && failureState == null) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Floe.colors.readingSurface.copy(alpha = 0.92f))
                        .clickable(
                            interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                            indication = null,
                            onClick = {},
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        FloeActivityIndicator(modifier = Modifier.size(22.dp))
                        FloeText(
                            text = stringResource(
                                when (busyPhaseKey) {
                                    "picker" -> R.string.office_busy_awaiting_picker
                                    "app" -> R.string.office_busy_awaiting_app
                                    "saving" -> R.string.office_busy_saving
                                    "pdfExport" -> R.string.office_pdf_busy_export
                                    "pdfPrint" -> R.string.office_pdf_busy_print
                                    else -> R.string.office_busy_exporting
                                },
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun NoticeGlyph(key: String) {
    val icon = when (key) {
        "loadError", "transportFailed", "jsError", "saveFailed", "copyFailed",
        "editPermissionDenied", "protectedDocument", "editEntryUnavailable",
        "pdfFailed", "printUnavailable" -> FloeIcons.WarningTriangle
        "saveUnknown" -> FloeIcons.WarningTriangle
        "saveFlushed", "copySaved" -> FloeIcons.CheckCircle
        "macroBlocked" -> FloeIcons.ShieldAlert
        else -> FloeIcons.InfoCircle
    }
    Image(
        imageVector = icon,
        contentDescription = null,
        colorFilter = ColorFilter.tint(Floe.colors.secondaryLabel),
        modifier = Modifier.size(18.dp),
    )
}

@Composable
private fun noticeText(key: String, detail: String?): String {
    val base = when (key) {
        "saveRouteUnavailable" -> stringResource(R.string.office_notice_save_unavailable)
        "editModeBlocked" -> stringResource(R.string.office_notice_readonly_only)
        "linkBlocked" -> stringResource(R.string.office_notice_link_blocked)
        "macroBlocked" -> stringResource(R.string.office_notice_macro_blocked)
        "transportFailed" -> stringResource(R.string.office_notice_transport_failed)
        "loadError" -> stringResource(R.string.office_notice_load_error)
        "jsError" -> stringResource(R.string.office_notice_internal_error)
        "awaitingRender" -> stringResource(R.string.office_notice_awaiting_render)
        // R2 editing/save notices (honest wording: staged != saved).
        "saveFlushed" -> stringResource(R.string.office_notice_save_flushed)
        "saveUnmodified" -> stringResource(R.string.office_notice_save_unmodified)
        "saveFailed" -> stringResource(R.string.office_notice_save_failed)
        "saveUnknown" -> stringResource(R.string.office_notice_save_unknown)
        "copyStaged" -> stringResource(R.string.office_notice_copy_staged)
        "copyHandedToApp" -> stringResource(R.string.office_notice_copy_handed)
        "copySaved" -> stringResource(R.string.office_notice_copy_saved)
        "copyFailed" -> stringResource(R.string.office_notice_copy_failed)
        "pickerCancelled" -> stringResource(R.string.office_notice_picker_cancelled)
        "hostTargetUnavailable" -> stringResource(R.string.office_notice_host_unavailable)
        "editUnavailable" -> stringResource(R.string.office_notice_edit_unavailable)
        "protectedDocument" -> stringResource(R.string.office_notice_protected_document)
        "editPermissionDenied" -> stringResource(R.string.office_notice_edit_denied)
        "editPermissionUnconfirmed" -> stringResource(R.string.office_notice_edit_unconfirmed)
        "editEntryUnavailable" -> stringResource(R.string.office_notice_edit_entry_unavailable)
        // AI precision-edit busy notice emitted by the engine service
        // (Main-owned aligned copy, 2026-10-27; ordinary language, never
        // the raw key).
        "precisionBusy" -> stringResource(R.string.office_notice_precision_busy)
        // PDF export/preview/print (honest wording: staged != saved;
        // dialog-open != printed — Main UI contract 2026-10-27).
        "pdfFailed" -> stringResource(R.string.office_notice_pdf_failed)
        "printSubmitted" -> stringResource(R.string.office_notice_print_submitted)
        "printUnavailable" -> stringResource(R.string.office_notice_print_unavailable)
        else -> stringResource(R.string.office_notice_internal_error)
    }
    return base
}

@Composable
private fun failureMessage(code: OfficeFailureCode, detail: String?): String {
    val base = when (code) {
        OfficeFailureCode.STAGED_FILE_MISSING -> stringResource(R.string.office_fail_missing)
        OfficeFailureCode.STAGED_FILE_MISMATCH -> stringResource(R.string.office_fail_mismatch)
        OfficeFailureCode.UNSUPPORTED_FORMAT -> stringResource(R.string.office_fail_format)
        OfficeFailureCode.PAYLOAD_PREPARE_FAILED -> stringResource(R.string.office_fail_prepare)
        OfficeFailureCode.NATIVE_LOAD_FAILED -> stringResource(R.string.office_fail_native)
        OfficeFailureCode.ENGINE_BUSY -> stringResource(R.string.office_fail_busy)
        OfficeFailureCode.WEBVIEW_ISOLATION_FAILED -> stringResource(R.string.office_fail_isolation)
        OfficeFailureCode.LOAD_ERROR -> stringResource(R.string.office_fail_load)
        OfficeFailureCode.TRANSPORT_FAILURE -> stringResource(R.string.office_fail_transport)
        OfficeFailureCode.ROUTE_UNAVAILABLE -> stringResource(R.string.office_fail_route)
        OfficeFailureCode.SESSION_CANCELLED -> stringResource(R.string.office_fail_cancelled)
        OfficeFailureCode.PROCESS_LOST -> stringResource(R.string.office_fail_process_lost)
        OfficeFailureCode.INTERNAL -> stringResource(R.string.office_fail_internal)
    }
    return base
}
