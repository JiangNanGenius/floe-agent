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
import androidx.compose.runtime.LaunchedEffect
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
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewAnswer
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewNaming
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewRole
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewAction
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewAnswer
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewChannel
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewState
import com.floe.android.core.officeengine.revisionreview.OfficeRevisionAction
import com.floe.android.core.officeengine.revisionreview.OfficeRevisionDispatch
import com.floe.android.core.officeengine.revisionreview.OfficeRevisionPdfProof
import com.floe.android.core.officeengine.revisionreview.OfficeRevisionState
import com.floe.android.core.officeengine.revisionreview.OfficeRevisionSupport
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

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

    /** C08 observed tracked-change/review projection for this exact mount. */
    private var revisionState: OfficeRevisionState? by mutableStateOf(null)
    private var revisionProof: OfficeRevisionPdfProof? by mutableStateOf(null)

    /**
     * One App-minted keep-revisions PDF export. The proof is emitted by the
     * engine for this exact opId; the existing SAF handoff then proceeds
     * unchanged.
     */
    private var revisionPdfOpId: String? = null

    /**
     * Same-UID conflict-review capability from this Activity's own launch
     * Intent. Null for read-only or legacy launches; the review sheet then
     * reports that original comparison is unavailable rather than inventing
     * one.
     */
    private var reviewChannel: android.os.IBinder? = null
    private var conflictReview: OfficeConflictReviewAnswer? by mutableStateOf(null)
    private var conflictReviewLoading by mutableStateOf(false)
    private var conflictResolving by mutableStateOf(false)
    private var conflictReviewMessage: String? by mutableStateOf(null)
    private var conflictReviewSeq = 0L

    /**
     * C08 retained-snapshot preview. The viewer asks the App for ONE bounded
     * text projection of the exact record/role/digest; the reply is a
     * relative App-owned receipt plus a cleanup lease. The snapshot itself
     * and the live editor are never touched. The lease is released when this
     * sheet closes, the review is refreshed or the Activity is destroyed.
     */
    private var conflictPreviewRole: OfficeConflictPreviewRole? by mutableStateOf(null)
    private var conflictPreviewSnapshotSha: String? by mutableStateOf(null)
    private var conflictPreviewText: String? by mutableStateOf(null)
    private var conflictPreviewTruncated by mutableStateOf(false)
    private var conflictPreviewLoading by mutableStateOf(false)
    private var conflictPreviewMessage: String? by mutableStateOf(null)
    private var conflictPreviewVisible by mutableStateOf(false)
    private var conflictPreviewSeq = 0L
    private var conflictPreviewLeaseId: String? = null
    /** Exact mount generation the preview lease was admitted for. */
    private var conflictPreviewGeneration = 0L

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
     * Manual workspace original save (OFC-SAVE-REOPEN): this mount's App
     * host owns the workspace-original commit and explicitly accepts
     * [OfficeSaveOriginalHandoffPolicy.TRANSACTION_SAVE_ORIGINAL] (launch
     * Intent extra + same-UID capability binder). The visible "Save Original"
     * action performs one real `.uno:Save` flush and hands the verified
     * working-copy facts to that host; the App alone re-verifies its OWN
     * working copy and runs the existing native workspace CAS. Save Copy
     * stays fully available beside it. Present ONLY for ordinary task-owned
     * workspace EDIT mounts — never provider/run-output/recovery mounts.
     */
    private var saveOriginalEnabled = false
    private var saveOriginalChannel: android.os.IBinder? = null

    /**
     * The one original-save op in flight for this mount. Its terminal
     * receipt is consumed here (never by the external/internal lanes); a
     * stale or duplicate receipt after the op settled opens nothing.
     */
    private var saveOriginalOpId: String? = null

    /** One handoff verification in flight (never two original saves per op). */
    private var saveOriginalHandoffInFlight = false

    /** True when the accepted answer must close this mount (dirty sheet). */
    private var saveOriginalClosePending = false

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

    /**
     * C08: the user chose the dirty sheet's explicit Discard action. It is
     * carried out ONLY in this Activity result so the App can distinguish a
     * deliberate discard from a process-loss/unknown close. It never deletes
     * anything here; the App owns its retained artifacts.
     */
    private var userDiscarded = false
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
        // C08 same-UID original review capability (editable mounts only).
        reviewChannel = intent.extras?.getBinder(OfficeConflictReviewChannel.EXTRA_REVIEW_CHANNEL)
        // R3 internal destination: the App declares that it owns a private
        // working-copy commit (Notes). The capability itself is still the
        // same-UID host save channel; this extra only selects the dirty-sheet
        // action. Without it everything below behaves exactly as before.
        internalSaveEnabled = intent.getBooleanExtra(OfficeHostSaveHandoffPolicy.EXTRA_INTERNAL_SAVE, false) &&
            hostSaveChannel != null
        // Manual workspace original save: same trust model — an inert
        // same-UID capability reference from our own non-exported launch
        // Intent, present only when the App declared the mount eligible.
        saveOriginalChannel = intent.extras?.getBinder(OfficeSaveOriginalHandoffPolicy.EXTRA_SAVE_ORIGINAL_CHANNEL)
        saveOriginalEnabled = intent.getBooleanExtra(OfficeSaveOriginalHandoffPolicy.EXTRA_SAVE_ORIGINAL, false) &&
            saveOriginalChannel != null
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
                    originalSaveSession = saveOriginalEnabled,
                    editState = editState,
                    revisionState = revisionState,
                    revisionProof = revisionProof,
                    conflictReview = conflictReview,
                    conflictReviewLoading = conflictReviewLoading,
                    conflictResolving = conflictResolving,
                    conflictReviewMessage = conflictReviewMessage,
                    conflictPreviewRole = conflictPreviewRole,
                    conflictPreviewSnapshotSha = conflictPreviewSnapshotSha,
                    conflictPreviewText = conflictPreviewText,
                    conflictPreviewTruncated = conflictPreviewTruncated,
                    conflictPreviewLoading = conflictPreviewLoading,
                    conflictPreviewMessage = conflictPreviewMessage,
                    conflictPreviewVisible = conflictPreviewVisible,
                    onPreviewVersion = ::loadConflictPreview,
                    onCloseConflictPreview = ::closeConflictPreview,
                    onRevisionAction = ::requestRevisionAction,
                    onCheckOriginal = ::checkOriginalReview,
                    onKeepCurrent = { resolveOriginalConflict(OfficeConflictReviewAction.KEEP_CURRENT) },
                    onSaveMineAsCopy = { resolveOriginalConflict(OfficeConflictReviewAction.PRESERVE_MINE_AS_COPY) },
                    onSavePdfKeepingRevisions = ::startRevisionPdfExport,
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
                    onSaveOriginal = { startSaveOriginal(forClose = false) },
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
                // a workspace-original mount offers "Save Original and close"
                // (one real flush, App-owned workspace CAS proof) with Save
                // Copy kept beside it; a generic host keeps "Save Copy and
                // close", which closes ONLY after the App's verified
                // COPY_SAVED settlement for that exact op. Failure/cancel/
                // UNKNOWN keeps the editor open with everything retained.
                FloeActionSheet(
                    visible = showDirtyCloseSheet,
                    onDismiss = { showDirtyCloseSheet = false },
                    maxCardWidth = 420.dp,
                ) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        FloeText(stringResource(R.string.office_viewer_dirty_title), style = Floe.typography.toolbarTitle)
                        FloeText(
                            stringResource(
                                when {
                                    internalSaveEnabled -> R.string.office_viewer_dirty_internal_message
                                    saveOriginalEnabled -> R.string.office_viewer_dirty_original_message
                                    else -> R.string.office_viewer_dirty_message
                                },
                            ),
                            color = Floe.colors.secondaryLabel,
                        )
                        when {
                            internalSaveEnabled -> {
                                FloeCapsuleButton(stringResource(R.string.office_action_save_note_close), onClick = {
                                    startInternalSaveAndClose()
                                })
                            }
                            saveOriginalEnabled -> {
                                FloeCapsuleButton(stringResource(R.string.office_action_save_original_close), onClick = {
                                    startSaveOriginal(forClose = true)
                                })
                                FloeCapsuleButton(stringResource(R.string.office_action_save_close), onClick = {
                                    startSaveCopy(forClose = true)
                                })
                            }
                            else -> {
                                FloeCapsuleButton(stringResource(R.string.office_action_save_close), onClick = {
                                    startSaveCopy(forClose = true)
                                })
                            }
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
        // close (the App recovery review exists, but it never turns a private
        // working-copy fact into a completed save or an automatic close).
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
        userDiscarded = false
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
        val generation = nativeGeneration.takeIf { it > 0L }
            ?: service?.currentGenerationFor(token)?.takeIf { it > 0L }
            ?: return
        val opId = newOpId("export")
        val op = OfficeSaveRequest.of(
            opId = opId,
            sessionToken = token,
            generation = generation,
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
        // The manual original-save lane is narrowed the same way: its
        // FLUSHED/UNMODIFIED receipt must never clear the external copy
        // state, and a stale/duplicate terminal for a settled op is dropped.
        if (receipt.opId == saveOriginalOpId) {
            applySaveOriginalReceipt(receipt)
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
        userDiscarded = false
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

    // --- Manual workspace original save (OFC-SAVE-REOPEN) ---

    /**
     * The visible "Save Original" action for an ordinary task-owned
     * workspace mount. One real `WORKING_COPY_FLUSH` on the existing engine
     * lane (`.uno:Save`, dontTerminateEdit=1) writes the latest in-memory
     * state to the App-owned working copy; the engine re-reads and digests
     * it. Only a FLUSHED/UNMODIFIED receipt with real working-copy facts is
     * offered to the App host, which re-verifies its OWN working copy and
     * runs the existing native workspace CAS before answering. Accepted ->
     * the original carries the verified edit (and the armed close proceeds
     * when [forClose]); refused/rejected/unknown -> the editor stays open
     * with the working copy and any recovery data retained, and a rejected
     * (conflict-shaped) answer points at the existing original-version
     * review. No model content operation is faked and no edit is reapplied;
     * Save Copy remains available beside this action.
     */
    private fun startSaveOriginal(forClose: Boolean) {
        userDiscarded = false
        if (!saveOriginalEnabled) return
        if (closeSavePhase != null || pdfBusyKey != null) return
        // Never start an original save underneath an external Save-Copy
        // picker/settlement or an internal-save handoff: the destinations
        // must not interleave.
        if (pendingHandoffOpId != null) return
        if (synchronized(awaitingSettlementOps) { awaitingSettlementOps.isNotEmpty() }) return
        if (internalSaveOpId != null || internalSaveHandoffInFlight) return
        if (saveOriginalOpId != null || saveOriginalHandoffInFlight) return
        val token = request?.sessionToken ?: return
        if (request?.permission != OfficePermission.EDIT) return
        val opId = newOpId("original")
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
            noticeDetail = "invalid original save request"
            return
        }
        showDirtyCloseSheet = false
        saveOriginalOpId = opId
        saveOriginalClosePending = forClose
        // The input stays frozen through the handoff answer in both the
        // menu and the dirty-close case: the App re-verifies the exact
        // working-copy digest, so no later edit may land underneath it. The
        // busy cover absorbs touches while the App verifies + commits.
        closeSavePhase = CloseSavePhase.SAVING
        freezeDocumentInput()
        val receipt = service?.submitSaveOperation(op) ?: run {
            saveOriginalOpId = null
            abortSaveOriginal("saveFailed", "editor unavailable")
            return
        }
        // A synchronous REJECTED was never dispatched to listeners; apply it
        // through the same narrowed handler exactly once.
        if (receipt.state == OfficeSaveState.REJECTED) applyReceipt(receipt)
    }

    private fun applySaveOriginalReceipt(receipt: OfficeSaveReceipt) {
        when (receipt.state) {
            OfficeSaveState.SUBMITTED -> Unit
            OfficeSaveState.FLUSHED, OfficeSaveState.UNMODIFIED -> {
                if (saveOriginalHandoffInFlight) return
                val mountFormat = request?.format?.fileExtension
                val notice = OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(receipt, mountFormat)
                if (notice == null) {
                    abortSaveOriginal("saveFailed", "working copy unavailable")
                    return
                }
                saveOriginalHandoffInFlight = true
                // The App re-reads/digests/commits against its own working
                // copy, so this bounded verification runs off the main
                // thread; the busy cover keeps input frozen until the answer.
                runCatching {
                    Thread({
                        val answer = OfficeSaveOriginalChannel.postSaveOriginal(saveOriginalChannel, notice)
                        mainHandler.post {
                            saveOriginalHandoffInFlight = false
                            if (isDestroyed || isFinishing) return@post
                            when (answer) {
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED -> {
                                    // The App proved the workspace original
                                    // now carries the verified edit.
                                    saveOriginalOpId = null
                                    closeSavePhase = null
                                    noticeKey = "originalSaved"
                                    noticeDetail = null
                                    if (saveOriginalClosePending) {
                                        saveOriginalClosePending = false
                                        request?.sessionToken?.let { token ->
                                            service?.requestClose(token, "user-back", userInitiated = true)
                                        }
                                    } else {
                                        unfreezeDocumentInput()
                                    }
                                }
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED -> {
                                    // The working copy still equals the
                                    // authoritative original: nothing to
                                    // commit, which is an honest success.
                                    saveOriginalOpId = null
                                    closeSavePhase = null
                                    noticeKey = "saveUnmodified"
                                    noticeDetail = null
                                    if (saveOriginalClosePending) {
                                        saveOriginalClosePending = false
                                        request?.sessionToken?.let { token ->
                                            service?.requestClose(token, "user-back", userInitiated = true)
                                        }
                                    } else {
                                        unfreezeDocumentInput()
                                    }
                                }
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED -> {
                                    // A real conflict / verification refusal:
                                    // the original stays untouched, the
                                    // working copy is retained, and the
                                    // existing original-version review
                                    // decides. The editor stays open.
                                    abortSaveOriginal("originalSaveConflict", null)
                                }
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_PENDING ->
                                    finishSaveOriginalSourcePending(savedLocally = true, conflict = false)
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_CONFLICT ->
                                    finishSaveOriginalSourcePending(savedLocally = true, conflict = true)
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_PENDING ->
                                    finishSaveOriginalSourcePending(savedLocally = false, conflict = false)
                                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_CONFLICT ->
                                    finishSaveOriginalSourcePending(savedLocally = false, conflict = true)
                                else -> {
                                    // Transport/fence refusal: nothing was
                                    // proven either way; the editor stays
                                    // open with everything retained.
                                    abortSaveOriginal("originalSaveFailed", null)
                                }
                            }
                        }
                    }, "office-original-save").start()
                }.onFailure {
                    saveOriginalHandoffInFlight = false
                    abortSaveOriginal("saveFailed", "originalSaveUnavailable")
                }
            }
            OfficeSaveState.FAILED, OfficeSaveState.UNKNOWN -> {
                abortSaveOriginal(
                    if (receipt.state == OfficeSaveState.UNKNOWN) "saveUnknown" else "saveFailed",
                    (receipt.failure?.name ?: "") + (receipt.message?.let { ": $it" } ?: ""),
                )
            }
            OfficeSaveState.CANCELLED, OfficeSaveState.REJECTED ->
                abortSaveOriginal("saveFailed", receipt.failure?.name)
            else -> abortSaveOriginal("saveFailed", "unexpected original save state")
        }
    }

    /** Ends an original-save attempt honestly: the editor stays open, input
     *  is unfrozen, the working copy is retained, and no close is
     *  authorized. A conflict-shaped refusal surfaces the existing review
     *  entry so the user can compare versions deliberately. */
    private fun abortSaveOriginal(notice: String, detail: String?) {
        saveOriginalOpId = null
        saveOriginalClosePending = false
        saveOriginalHandoffInFlight = false
        closeSavePhase = null
        unfreezeDocumentInput()
        noticeKey = notice
        noticeDetail = detail
    }

    /**
     * The LOCAL workspace original is proven saved (or already current) but
     * the attached provider sync did not complete — never close as if fully
     * synced. The editor stays open with the working copy retained, an
     * actionable bilingual notice says exactly what did and didn't happen,
     * and the existing Save Copy / close choices stay usable. The journaled
     * provider row keeps its recovery identity for the existing reconcile
     * flow; nothing is replayed here.
     */
    private fun finishSaveOriginalSourcePending(savedLocally: Boolean, conflict: Boolean) {
        saveOriginalOpId = null
        saveOriginalClosePending = false
        closeSavePhase = null
        unfreezeDocumentInput()
        noticeKey = when {
            savedLocally && conflict -> "originalSavedSourceConflict"
            savedLocally -> "originalSavedSourcePending"
            conflict -> "originalUnchangedSourceConflict"
            else -> "originalUnchangedSourcePending"
        }
        noticeDetail = null
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
        val token = request?.sessionToken
        val engine = service
        if (token == null || engine == null) return
        // Mark the result only when an exact close request was actually
        // issued; a failed keep-editing path must not tag a later save.
        userDiscarded = true
        engine.requestClose(token, "user-back", userInitiated = true, discarded = true)
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
        // Release any open preview lease first; the generic review release
        // below then retires the record and drains only after that reader.
        closeConflictPreview()
        // Drop only this review's temporary snapshots. The App controller
        // also releases on settle; this covers an Activity recreation where
        // the Compose sheet state is gone but the session stays live.
        val reviewToken = request?.sessionToken
        val reviewGeneration = nativeGeneration
        val reviewBinder = reviewChannel
        if (reviewToken != null && reviewGeneration > 0L && reviewBinder != null) {
            runCatching {
                Thread({
                    OfficeConflictReviewChannel.release(
                        reviewBinder, reviewToken, reviewGeneration, null,
                    )
                }, "office-review-release").start()
            }
        }
        internalSaveOpId = null
        internalSaveHandoffInFlight = false
        saveOriginalOpId = null
        saveOriginalHandoffInFlight = false
        saveOriginalClosePending = false
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

    override fun onCloseRequested(sessionToken: String, generation: Long) {
        if (accepts(sessionToken, generation)) performBack()
    }

    override fun onSaveReceipt(receipt: OfficeSaveReceipt) {
        applyReceipt(receipt)
    }

    override fun onEditState(state: OfficeEditState) {
        if (!accepts(state.sessionToken, state.generation)) return
        if (state.pageEditMode) everEnteredEditMode = true
        editState = state
    }

    override fun onRevisionState(state: OfficeRevisionState) {
        if (!accepts(state.sessionToken, state.generation)) return
        revisionState = state
    }

    override fun onRevisionPdfProof(proof: OfficeRevisionPdfProof) {
        if (!accepts(proof.sessionToken, proof.generation)) return
        if (proof.opId != revisionPdfOpId) return
        revisionProof = proof
        if (proof.completed) {
            noticeKey = if (proof.revisionsPreserved) "pdfRevisionsKept" else "pdfRevisionWarning"
            noticeDetail = proof.verdict
        }
    }

    /** Sends one real tracked-change command through the engine service. */
    private fun requestRevisionAction(action: OfficeRevisionAction) {
        val token = request?.sessionToken ?: return
        val engine = service
        if (engine == null) {
            noticeKey = "revisionFailed"
            noticeDetail = OfficeRevisionDispatch.NO_LIVE_EDIT_SESSION.name
            return
        }
        val generation = nativeGeneration.takeIf { it > 0L }
            ?: engine.currentGenerationFor(token).takeIf { it > 0L }
            ?: return
        val dispatch = engine.requestRevisionAction(token, generation, action)
        if (dispatch == OfficeRevisionDispatch.ACCEPTED) {
            noticeKey = "revisionPending"
            noticeDetail = action.name
        } else {
            noticeKey = "revisionFailed"
            noticeDetail = dispatch.name
        }
    }

    /**
     * Reads the exact current original through the App-owned channel. The
     * call runs off the main thread because it can perform one bounded
     * provider/workspace read; no UI state is treated as proof.
     */
    private fun checkOriginalReview() {
        if (conflictReviewLoading || conflictResolving) return
        // A fresh check invalidates any preview lease bound to the old record.
        closeConflictPreview()
        val token = request?.sessionToken ?: return
        val generation = nativeGeneration.takeIf { it > 0L }
            ?: service?.currentGenerationFor(token)?.takeIf { it > 0L }
            ?: return
        val binder = reviewChannel
        if (binder == null) {
            conflictReview = null
            conflictReviewMessage = "noReviewCapability"
            return
        }
        val seq = ++conflictReviewSeq
        conflictReviewLoading = true
        conflictReviewMessage = null
        conflictReview = null
        val requestId = "r" + seq + "-" + System.currentTimeMillis()
        runCatching {
            Thread({
                val answer = OfficeConflictReviewChannel.review(binder, token, generation, requestId)
                mainHandler.post {
                    if (seq != conflictReviewSeq || isDestroyed || isFinishing) return@post
                    conflictReviewLoading = false
                    if (answer == null) {
                        conflictReviewMessage = "reviewUnavailable"
                    } else {
                        conflictReview = answer
                        if (answer.state == OfficeConflictReviewState.CHANGED) {
                            noticeKey = "originalChanged"
                            noticeDetail = null
                        } else if (answer.state == OfficeConflictReviewState.UNCHANGED) {
                            noticeKey = "originalUnchanged"
                            noticeDetail = null
                        }
                    }
                }
            }, "office-original-review").start()
        }.onFailure {
            conflictReviewLoading = false
            conflictReviewMessage = "reviewUnavailable"
        }
    }

    /** Applies one deliberate decision; the App re-reads the original first. */
    private fun resolveOriginalConflict(action: OfficeConflictReviewAction) {
        if (conflictResolving) return
        val token = request?.sessionToken ?: return
        val generation = nativeGeneration.takeIf { it > 0L }
            ?: service?.currentGenerationFor(token)?.takeIf { it > 0L }
            ?: return
        val binder = reviewChannel ?: return
        val recordId = conflictReview?.recordId ?: return
        conflictResolving = true
        conflictReviewMessage = null
        runCatching {
            Thread({
                val result = OfficeConflictReviewChannel.resolve(
                    binder, token, generation, recordId, action,
                )
                mainHandler.post {
                    if (isDestroyed || isFinishing) return@post
                    conflictResolving = false
                    if (result == null) {
                        conflictReviewMessage = "resolutionUnavailable"
                        return@post
                    }
                    when {
                        result.accepted && action == OfficeConflictReviewAction.KEEP_CURRENT -> {
                            conflictReview = null
                            noticeKey = "originalKept"
                            noticeDetail = result.code
                        }
                        result.accepted && action == OfficeConflictReviewAction.PRESERVE_MINE_AS_COPY -> {
                            conflictReview = null
                            // Existing verified Save Copy; the original stays
                            // untouched and the working version is retained.
                            startSaveCopy(forClose = false)
                        }
                        result.code == "reviewStale" -> {
                            conflictReview = null
                            conflictReviewMessage = "reviewStale"
                            noticeKey = "originalStale"
                            noticeDetail = null
                        }
                        else -> {
                            conflictReviewMessage = result.code
                            noticeKey = "revisionFailed"
                            noticeDetail = result.code
                        }
                    }
                }
            }, "office-original-resolution").start()
        }.onFailure {
            conflictResolving = false
            conflictReviewMessage = "resolutionUnavailable"
        }
    }

    /**
     * Loads ONE retained version's bounded text projection through the
     * App-owned review channel. The reply carries only a relative receipt and
     * a cleanup lease; the viewer re-proves the App review root, the exact
     * leaf, the length and the text-file digest before showing anything.
     * Runs off the main thread because the App re-verifies and may project a
     * bounded package part. The editor session is never commanded.
     */
    private fun loadConflictPreview(role: OfficeConflictPreviewRole) {
        if (conflictPreviewLoading) return
        val review = conflictReview ?: return
        val recordId = review.recordId ?: return
        val expectedSha = when (role) {
            OfficeConflictPreviewRole.MINE -> review.mineSha256
            OfficeConflictPreviewRole.CURRENT -> review.currentSha256
        } ?: return
        val token = request?.sessionToken ?: return
        val generation = nativeGeneration.takeIf { it > 0L }
            ?: service?.currentGenerationFor(token)?.takeIf { it > 0L }
            ?: run {
                conflictPreviewRole = role
                conflictPreviewVisible = true
                conflictPreviewMessage = "sessionFenced"
                return
            }
        val binder = reviewChannel
        releaseConflictPreviewLease()
        val seq = ++conflictPreviewSeq
        conflictPreviewGeneration = generation
        conflictPreviewRole = role
        conflictPreviewSnapshotSha = expectedSha
        conflictPreviewText = null
        conflictPreviewTruncated = false
        conflictPreviewMessage = null
        conflictPreviewLoading = true
        conflictPreviewVisible = true
        if (binder == null) {
            conflictPreviewLoading = false
            conflictPreviewMessage = "noReviewCapability"
            return
        }
        runCatching {
            Thread({
                val receipt = OfficeConflictReviewChannel.preview(
                    binder, token, generation, recordId, role, expectedSha,
                )
                val text = receipt
                    ?.takeIf { it.ready && it.matches(recordId, role, expectedSha) }
                    ?.let { readConflictPreviewText(it) }
                mainHandler.post {
                    if (seq != conflictPreviewSeq || isDestroyed || isFinishing) {
                        // The sheet was closed or the Activity ended while the
                        // binder call was in flight: hand the lease straight
                        // back so the App can drain the review directory.
                        if (receipt != null && receipt.ready) {
                            releaseConflictPreviewLease(binder, token, generation, receipt.leaseId)
                        }
                        return@post
                    }
                    conflictPreviewLoading = false
                    if (receipt == null) {
                        conflictPreviewMessage = "previewUnavailable"
                    } else if (!receipt.ready) {
                        conflictPreviewMessage = receipt.reason ?: "previewUnavailable"
                    } else if (text == null) {
                        releaseConflictPreviewLease(binder, token, generation, receipt.leaseId)
                        conflictPreviewMessage = "previewUnavailable"
                    } else {
                        conflictPreviewText = text
                        conflictPreviewTruncated = receipt.truncated
                        conflictPreviewLeaseId = receipt.leaseId
                    }
                }
            }, "office-conflict-preview").start()
        }.onFailure {
            conflictPreviewLoading = false
            conflictPreviewMessage = "previewUnavailable"
        }
    }

    /** Returns to the review sheet; releases the cleanup lease exactly once. */
    private fun closeConflictPreview() {
        conflictPreviewSeq++
        conflictPreviewVisible = false
        conflictPreviewLoading = false
        conflictPreviewText = null
        conflictPreviewTruncated = false
        conflictPreviewMessage = null
        conflictPreviewRole = null
        conflictPreviewSnapshotSha = null
        releaseConflictPreviewLease()
        conflictPreviewGeneration = 0L
    }

    private fun releaseConflictPreviewLease() {
        val leaseId = conflictPreviewLeaseId ?: return
        conflictPreviewLeaseId = null
        val token = request?.sessionToken ?: return
        // Release under the EXACT generation the lease was admitted for: a
        // later engine generation must not strand the App cleanup lease.
        val generation = conflictPreviewGeneration.takeIf { it > 0L } ?: return
        val binder = reviewChannel ?: return
        releaseConflictPreviewLease(binder, token, generation, leaseId)
    }

    private fun releaseConflictPreviewLease(
        binder: android.os.IBinder,
        token: String,
        generation: Long,
        leaseId: String?,
    ) {
        if (leaseId == null) return
        runCatching {
            Thread({
                OfficeConflictReviewChannel.releasePreview(binder, token, generation, leaseId)
            }, "office-preview-lease-release").start()
        }
    }

    /**
     * Re-proves that the receipt names exactly one App-owned review file under
     * this process's own root, with the expected role leaf, length and SHA-256.
     * Only then is the bounded UTF-8 text returned. No path is displayed or
     * logged, and a swapped/short/oversize file yields an honest refusal.
     */
    private fun readConflictPreviewText(receipt: OfficeConflictPreviewAnswer): String? {
        val relative = receipt.relativePath ?: return null
        val role = receipt.role ?: return null
        if (!OfficeConflictPreviewNaming.isValidRelativePath(relative, role)) return null
        val directoryName = relative.substringBefore('/')
        val fileName = relative.substringAfter('/')
        val root = runCatching {
            File(noBackupFilesDir, OfficeConflictPreviewNaming.REVIEW_ROOT).canonicalFile
        }.getOrNull() ?: return null
        val directory = runCatching { File(root, directoryName).canonicalFile }.getOrNull()
            ?: return null
        if (directory.parentFile?.canonicalFile != root) return null
        val file = runCatching { File(directory, fileName).canonicalFile }.getOrNull()
            ?: return null
        if (file.parentFile?.canonicalFile != directory) return null
        if (Files.isSymbolicLink(file.toPath())) return null
        if (!file.isFile || file.length() != receipt.previewBytes) return null
        if (file.length() !in 1L..OfficeConflictPreviewAnswer.MAX_PREVIEW_FILE_BYTES) return null
        // Bounded read: never trust the pre-read length for allocation, and
        // refuse a stream that does not end at the exact receipt length.
        val bytes = runCatching {
            java.io.FileInputStream(file).use { input ->
                val buffer = ByteArray(OfficeConflictPreviewAnswer.MAX_PREVIEW_FILE_BYTES.toInt() + 1)
                var offset = 0
                while (offset < buffer.size) {
                    val read = input.read(buffer, offset, buffer.size - offset)
                    if (read < 0) break
                    if (read == 0) continue
                    offset += read
                }
                if (offset != receipt.previewBytes.toInt()) null else buffer.copyOf(offset)
            }
        }.getOrNull() ?: return null
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        if (!digest.equals(receipt.previewSha256, ignoreCase = true)) return null
        return String(bytes, Charsets.UTF_8)
            .replace("\u0000", "")
            .take(OfficeConflictPreviewAnswer.MAX_TEXT_CHARS)
    }

    /**
     * The keep-revisions PDF case: the SAME pinned STAGED_EXPORT, with the
     * engine's source-side proof. It never accepts/rejects/flushes the
     * document and never claims the PDF is an editable revision container.
     */
    private fun startRevisionPdfExport() {
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
            noticeKey = "pdfFailed"
            noticeDetail = "invalid export request"
            return
        }
        val engine = service ?: run {
            noticeKey = "pdfFailed"
            noticeDetail = "editor unavailable"
            return
        }
        exportPurposes.register(opId, OfficeExportPurpose.SAF_COPY)
        pendingExportFormats[opId] = "pdf"
        revisionPdfOpId = opId
        revisionProof = null
        // The source digest is measured before dispatch. Keep that bounded
        // file read off the UI thread; the export itself still runs on the
        // engine control lane, and terminal receipts stay on the main thread.
        runCatching {
            Thread({
                val receipt = runCatching { engine.submitRevisionPreservingPdfExport(op) }.getOrNull()
                mainHandler.post {
                    if (isDestroyed || isFinishing || request?.sessionToken != token) return@post
                    if (receipt == null) {
                        exportPurposes.consume(opId)
                        pendingExportFormats.remove(opId)
                        revisionPdfOpId = null
                        noticeKey = "pdfFailed"
                        noticeDetail = "revisionExportUnavailable"
                    } else if (receipt.state == OfficeSaveState.REJECTED) {
                        applyReceipt(receipt)
                    }
                }
            }, "office-revision-pdf").start()
        }.onFailure {
            exportPurposes.consume(opId)
            pendingExportFormats.remove(opId)
            revisionPdfOpId = null
            noticeKey = "pdfFailed"
            noticeDetail = "revisionExportUnavailable"
        }
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
                userDiscarded = false
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
            if (userDiscarded) putExtra(EXTRA_USER_DISCARDED, true)
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

        /** App-owned recovery result flag: explicit user discard (never a save). */
        const val EXTRA_USER_DISCARDED = "com.floe.android.office.USER_DISCARDED"

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
    /** Manual workspace original save: this mount may write the workspace
     *  original through the App-owned CAS (the "Save Original" action). */
    originalSaveSession: Boolean = false,
    editState: OfficeEditState?,
    revisionState: OfficeRevisionState?,
    revisionProof: OfficeRevisionPdfProof?,
    conflictReview: OfficeConflictReviewAnswer?,
    conflictReviewLoading: Boolean,
    conflictResolving: Boolean,
    conflictReviewMessage: String?,
    conflictPreviewRole: OfficeConflictPreviewRole?,
    conflictPreviewSnapshotSha: String?,
    conflictPreviewText: String?,
    conflictPreviewTruncated: Boolean,
    conflictPreviewLoading: Boolean,
    conflictPreviewMessage: String?,
    conflictPreviewVisible: Boolean,
    onPreviewVersion: (OfficeConflictPreviewRole) -> Unit,
    onCloseConflictPreview: () -> Unit,
    onRevisionAction: (OfficeRevisionAction) -> Unit,
    onCheckOriginal: () -> Unit,
    onKeepCurrent: () -> Unit,
    onSaveMineAsCopy: () -> Unit,
    onSavePdfKeepingRevisions: () -> Unit,
    diagnosticEvents: List<OfficeSessionDiagnostics.Event>,
    busyPhaseKey: String?,
    onBack: () -> Unit,
    onToggleEdit: () -> Unit,
    onSaveCopy: () -> Unit,
    onSaveOriginal: () -> Unit,
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
    var showReview by remember { mutableStateOf(false) }
    // Opening the review sheet performs ONE read-only original check (when
    // the App supplied the capability). It never saves or overwrites.
    LaunchedEffect(showReview) {
        if (showReview) onCheckOriginal()
    }

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
            FloeCapsuleButton(reviewText("Review changes", "审阅更改"), onClick = {
                showEditorMenu = false
                showReview = true
            })
            if (originalSaveSession) {
                // Manual workspace original save (OFC-SAVE-REOPEN): one
                // visible action that saves the verified working copy back
                // to the task workspace original through the App-owned CAS.
                // Save Copy stays right below it, always.
                FloeCapsuleButton(stringResource(R.string.office_action_save_original), onClick = {
                    showEditorMenu = false
                    onSaveOriginal()
                })
            }
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
    FloeActionSheet(visible = showReview, onDismiss = { showReview = false }, maxCardWidth = 560.dp) {
        Column(
            Modifier
                .heightIn(max = 620.dp)
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            FloeText(reviewText("Changes & versions", "更改与版本"), style = Floe.typography.toolbarTitle)
            FloeText(
                reviewText(
                    "Review tracked changes and the original version. Commands are sent to the document; the result appears only after the engine reports it.",
                    "审阅修订和原始版本。命令会发送到文档，仅在引擎回报后显示结果。",
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            FloeText(reviewText("Tracked changes", "修订"), style = Floe.typography.bodyEmphasized)
            val revision = revisionState
            when {
                revision == null -> FloeText(
                    reviewText("Tracked-change state is not available yet.", "尚未获得修订状态。"),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                revision.support == OfficeRevisionSupport.WRITER_ONLY -> FloeText(
                    reviewText(
                        "Tracked-change review is available for Word documents in this engine build.",
                        "此引擎版本的修订审阅仅适用于 Word 文档。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                revision.support == OfficeRevisionSupport.REVIEW_NOT_AUTHORIZED -> FloeText(
                    reviewText(
                        "The document did not grant redline management for this view.",
                        "当前视图未获得红线管理权限。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                revision.support == OfficeRevisionSupport.EDIT_MODE_REQUIRED -> FloeText(
                    reviewText(
                        "Enter Edit Copy to review tracked changes.",
                        "进入编辑副本后才能审阅修订。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                revision.support == OfficeRevisionSupport.NO_LIVE_EDIT_SESSION -> FloeText(
                    reviewText(
                        "Open the document for editing to review changes.",
                        "请以编辑方式打开文档后再审阅更改。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                revision.support == OfficeRevisionSupport.NATIVE_LEASE_BUSY -> FloeText(
                    reviewText(
                        "Another document operation is still using the editor.",
                        "另一个文档操作仍占用编辑器。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                else -> {
                    FloeText(
                        reviewText(
                            "Record changes: ${onOff(revision.recording)}",
                            "记录修订：${onOff(revision.recording)}",
                        ),
                        style = Floe.typography.metadata,
                    )
                    FloeText(
                        reviewText(
                            "Show changes: ${onOff(revision.showingChanges)}",
                            "显示修订：${onOff(revision.showingChanges)}",
                        ),
                        style = Floe.typography.metadata,
                    )
                    if (revision.pendingAction != null) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            FloeActivityIndicator(modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            FloeText(
                                reviewText(
                                    "Waiting for the document to acknowledge the last change…",
                                    "正在等待文档确认上一项更改…",
                                ),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                    } else if (revision.lastFailure == "noAcknowledgement") {
                        FloeText(
                            reviewText(
                                "The document did not report a state change. Check the document and retry.",
                                "文档未回报状态变化。请检查文档后重试。",
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.accent,
                        )
                    } else if (revision.lastAcknowledged != null) {
                        FloeText(
                            reviewText("The document reported the change.", "文档已回报该更改。"),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    val controls = revision.supported && revision.pendingAction == null && revision.pageEditMode
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeCapsuleButton(
                            label = if (revision.recording == true) {
                                reviewText("Stop recording", "停止记录")
                            } else {
                                reviewText("Record changes", "记录修订")
                            },
                            onClick = { onRevisionAction(OfficeRevisionAction.TOGGLE_RECORDING) },
                            modifier = Modifier.weight(1f),
                            enabled = controls,
                        )
                        FloeCapsuleButton(
                            label = if (revision.showingChanges == true) {
                                reviewText("Hide changes", "隐藏修订")
                            } else {
                                reviewText("Show changes", "显示修订")
                            },
                            onClick = { onRevisionAction(OfficeRevisionAction.SHOW_CHANGES) },
                            modifier = Modifier.weight(1f),
                            enabled = controls,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeCapsuleButton(
                            label = reviewText("Accept change", "接受更改"),
                            onClick = { onRevisionAction(OfficeRevisionAction.ACCEPT_CURRENT) },
                            modifier = Modifier.weight(1f),
                            enabled = controls && revision.acceptCurrentAvailable != false,
                        )
                        FloeCapsuleButton(
                            label = reviewText("Reject change", "拒绝更改"),
                            onClick = { onRevisionAction(OfficeRevisionAction.REJECT_CURRENT) },
                            modifier = Modifier.weight(1f),
                            enabled = controls && revision.rejectCurrentAvailable != false,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeCapsuleButton(
                            label = reviewText("Accept all", "全部接受"),
                            onClick = { onRevisionAction(OfficeRevisionAction.ACCEPT_ALL) },
                            modifier = Modifier.weight(1f),
                            enabled = controls && revision.acceptAllAvailable != false,
                        )
                        FloeCapsuleButton(
                            label = reviewText("Reject all", "全部拒绝"),
                            onClick = { onRevisionAction(OfficeRevisionAction.REJECT_ALL) },
                            modifier = Modifier.weight(1f),
                            enabled = controls && revision.rejectAllAvailable != false,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeCapsuleButton(
                            label = reviewText("Previous change", "上一处更改"),
                            onClick = { onRevisionAction(OfficeRevisionAction.PREVIOUS) },
                            modifier = Modifier.weight(1f),
                            enabled = controls && revision.previousAvailable != false,
                        )
                        FloeCapsuleButton(
                            label = reviewText("Next change", "下一处更改"),
                            onClick = { onRevisionAction(OfficeRevisionAction.NEXT) },
                            modifier = Modifier.weight(1f),
                            enabled = controls && revision.nextAvailable != false,
                        )
                    }
                }
            }

            FloeText(reviewText("PDF with revisions", "保留修订的 PDF"), style = Floe.typography.bodyEmphasized)
            FloeText(
                reviewText(
                    "Exports a PDF through the existing verified save pipeline. It never accepts or rejects changes. A PDF cannot store editable revisions; the source document keeps them.",
                    "通过现有已验证的保存流程导出 PDF。此过程不会接受或拒绝修订。PDF 无法保存可编辑的修订记录，源文档仍会保留。",
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            FloeCapsuleButton(
                label = reviewText("Save PDF (keep revisions)", "保存 PDF（保留修订）"),
                onClick = onSavePdfKeepingRevisions,
            )
            revisionProof?.let { proof ->
                val verdict = when (proof.verdict) {
                    "revisionsKeptSourceUnchanged" -> reviewText(
                        "PDF created. Revisions were kept and the source file was unchanged during export.",
                        "PDF 已创建。修订已保留，导出期间源文件未改变。",
                    )
                    "revisionsKeptSourceChanged" -> reviewText(
                        "PDF created with no accept/reject action. The working copy changed during export, so the PDF may not match the latest edit.",
                        "PDF 已创建，且未执行接受/拒绝操作。导出期间工作副本发生变化，PDF 可能与最新编辑不一致。",
                    )
                    "revisionsKeptSourceUnmeasured" -> reviewText(
                        "PDF created with no accept/reject action. The source digest could not be measured.",
                        "PDF 已创建，且未执行接受/拒绝操作。无法测量源文件摘要。",
                    )
                    "revisionActionDuringExport" -> reviewText(
                        "An accept/reject action was observed during export. Export again for a clean keep-revisions proof.",
                        "导出期间观察到接受/拒绝操作。请重新导出以获得完整的保留修订证明。",
                    )
                    else -> reviewText("No PDF was created.", "未创建 PDF。")
                }
                FloeText(verdict, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                FloeText(
                    reviewText(
                        "Source unchanged during export: ${onOff(proof.sourceUnchanged)}",
                        "导出期间源文件未改变：${onOff(proof.sourceUnchanged)}",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }

            FloeText(reviewText("Original version", "原始版本"), style = Floe.typography.bodyEmphasized)
            FloeText(
                reviewText(
                    "Compares the version you opened with the current original. This check is read-only; it never saves or overwrites the original.",
                    "将打开时的版本与当前原始文件进行比较。此检查为只读，不会保存或覆盖原始文件。",
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            when {
                conflictReviewLoading -> Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeActivityIndicator(modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    FloeText(
                        reviewText("Reading the current original…", "正在读取当前原始文件…"),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                conflictReview == null -> {
                    conflictReviewMessage?.let { code ->
                        FloeText(
                            reviewMessageText(code),
                            style = Floe.typography.metadata,
                            color = Floe.colors.accent,
                        )
                    }
                    FloeCapsuleButton(
                        label = reviewText("Check original version", "检查原始版本"),
                        onClick = onCheckOriginal,
                        enabled = !conflictResolving,
                    )
                }
                else -> {
                    val answer = conflictReview!!
                    when (answer.state) {
                        OfficeConflictReviewState.UNCHANGED -> {
                            FloeText(
                                reviewText(
                                    "The original still matches the version you opened.",
                                    "原始文件仍与打开时的版本一致。",
                                ),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                            ReviewVersionLine("My version (saved working copy)", answer.mineSha256, answer.mineBytes, null)
                            ReviewVersionLine("Current original", answer.currentSha256, answer.currentBytes, answer.currentRevision)
                            FloeCapsuleButton(
                                label = reviewText("Check again", "重新检查"),
                                onClick = onCheckOriginal,
                                enabled = !conflictResolving,
                            )
                        }
                        OfficeConflictReviewState.CHANGED -> {
                            FloeText(
                                reviewText(
                                    "The original changed since you opened it. Both versions are retained; choose deliberately.",
                                    "打开后原始文件已发生变化。两个版本都会保留，请明确选择。",
                                ),
                                style = Floe.typography.metadata,
                                color = Floe.colors.accent,
                            )
                            ReviewVersionLine("My version (saved working copy)", answer.mineSha256, answer.mineBytes, null)
                            ReviewVersionLine("Current original", answer.currentSha256, answer.currentBytes, answer.currentRevision)
                            if (answer.recordId != null) {
                                FloeCapsuleButton(
                                    label = reviewText("View my version", "查看我的版本"),
                                    onClick = { onPreviewVersion(OfficeConflictPreviewRole.MINE) },
                                    enabled = !conflictResolving && !conflictPreviewLoading,
                                )
                                FloeCapsuleButton(
                                    label = reviewText("View current original", "查看当前原始版本"),
                                    onClick = { onPreviewVersion(OfficeConflictPreviewRole.CURRENT) },
                                    enabled = !conflictResolving && !conflictPreviewLoading,
                                )
                                FloeText(
                                    reviewText(
                                        "Previews show the saved text of each version. The editor and your changes stay untouched.",
                                        "预览显示各版本已保存的文本。编辑器和你的更改保持不变。",
                                    ),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                            if (conflictResolving) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    FloeActivityIndicator(modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(8.dp))
                                    FloeText(
                                        reviewText("Checking the current original again…", "正在重新检查当前原始文件…"),
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                    )
                                }
                            }
                            FloeCapsuleButton(
                                label = reviewText("Keep current original", "保留当前原始文件"),
                                onClick = onKeepCurrent,
                                enabled = answer.canKeepCurrent && !conflictResolving,
                            )
                            FloeCapsuleButton(
                                label = reviewText("Save my version as a copy", "将我的版本另存为副本"),
                                onClick = {
                                    showReview = false
                                    onSaveMineAsCopy()
                                },
                                enabled = answer.canPreserveMineAsCopy && !conflictResolving,
                            )
                            FloeText(
                                reviewText(
                                    "Overwriting the original is not available from this viewer. The original can only change through its own compare-and-swap path.",
                                    "此查看器不提供覆盖原始文件的选项。原始文件只能通过其自身的比较并交换路径修改。",
                                ),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                        OfficeConflictReviewState.UNAVAILABLE -> {
                            FloeText(
                                reviewText(
                                    "The original could not be read (${answer.reason ?: "unavailable"}). Nothing was changed.",
                                    "无法读取原始文件（${answer.reason ?: "不可用"}）。未更改任何内容。",
                                ),
                                style = Floe.typography.metadata,
                                color = Floe.colors.accent,
                            )
                            FloeCapsuleButton(
                                label = reviewText("Check again", "重新检查"),
                                onClick = onCheckOriginal,
                                enabled = !conflictResolving,
                            )
                        }
                        OfficeConflictReviewState.NOT_APPLICABLE -> FloeText(
                            reviewText(
                                "This document has no workspace or provider original to compare.",
                                "此文档没有可比较的工作区或提供商原始文件。",
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                    conflictReviewMessage?.let { code ->
                        FloeText(
                            reviewMessageText(code),
                            style = Floe.typography.metadata,
                            color = Floe.colors.accent,
                        )
                    }
                }
            }
            FloeCapsuleButton(
                label = reviewText("Done", "完成"),
                onClick = { showReview = false },
            )
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
    // Full-sheet read-only view of ONE retained version. The review sheet
    // stays composed underneath; closing this returns exactly to the version
    // comparison and releases the App cleanup lease.
    FloeActionSheet(
        visible = conflictPreviewVisible,
        onDismiss = onCloseConflictPreview,
        maxCardWidth = 680.dp,
    ) {
        Column(
            Modifier
                .heightIn(max = 640.dp)
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            val previewRole = conflictPreviewRole
            FloeText(
                reviewText(
                    if (previewRole == OfficeConflictPreviewRole.CURRENT) {
                        "Current original"
                    } else {
                        "My version (saved working copy)"
                    },
                    if (previewRole == OfficeConflictPreviewRole.CURRENT) {
                        "当前原始文件"
                    } else {
                        "我的版本（已保存的工作副本）"
                    },
                ),
                style = Floe.typography.toolbarTitle,
            )
            FloeText(
                reviewText(
                    "Read-only text preview. The editor and your changes stay untouched; nothing is saved or overwritten.",
                    "只读文本预览。编辑器和你的更改保持不变，不会保存或覆盖任何内容。",
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            var showVersionDetails by remember(conflictPreviewRole, conflictPreviewSnapshotSha) {
                mutableStateOf(false)
            }
            FloeCapsuleButton(
                label = reviewText("Version details", "版本信息"),
                onClick = { showVersionDetails = !showVersionDetails },
            )
            if (showVersionDetails) {
                FloeText(
                    "SHA-256 ${shortSha(conflictPreviewSnapshotSha)}",
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            when {
                conflictPreviewLoading -> Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeActivityIndicator(modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    FloeText(
                        reviewText("Reading the retained version…", "正在读取保留的版本…"),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
                conflictPreviewMessage != null -> FloeText(
                    reviewMessageText(conflictPreviewMessage.orEmpty()),
                    style = Floe.typography.metadata,
                    color = Floe.colors.accent,
                )
                conflictPreviewText.isNullOrEmpty() -> FloeText(
                    reviewText(
                        "No readable text was found in this version.",
                        "此版本中未找到可读取的文本。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                else -> FloeText(
                    conflictPreviewText.orEmpty(),
                    style = Floe.typography.body,
                )
            }
            if (conflictPreviewTruncated && conflictPreviewText != null) {
                FloeText(
                    reviewText(
                        "Preview limited to the first part of this version.",
                        "预览仅显示此版本的前一部分。",
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            FloeText(
                reviewText(
                    "Text only from the main document body. Layout, images, comments, headers and tracked deletions are not shown. The full document stays in the editor.",
                    "仅显示文档正文文本。不显示版式、图片、批注、页眉页脚和已删除的修订内容。完整文档仍保留在编辑器中。",
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            FloeCapsuleButton(
                label = reviewText("Back to review", "返回对比"),
                onClick = onCloseConflictPreview,
            )
        }
    }
}

private fun reviewText(english: String, chinese: String): String =
    if (java.util.Locale.getDefault().language == "zh") chinese else english

private fun onOff(value: Boolean?): String = when (value) {
    true -> reviewText("On", "开")
    false -> reviewText("Off", "关")
    null -> reviewText("Unknown", "未知")
}

private fun shortSha(sha: String?): String = sha?.take(12) ?: "—"

private fun reviewMessageText(code: String): String = when (code) {
    "noReviewCapability" -> reviewText(
        "This view has no original-version review capability.",
        "此视图没有原始版本审阅能力。",
    )
    "reviewUnavailable" -> reviewText(
        "The original version could not be read. Nothing was changed.",
        "无法读取原始版本。未更改任何内容。",
    )
    "resolutionUnavailable" -> reviewText(
        "The decision could not be admitted. Nothing was overwritten.",
        "无法受理该决定。未覆盖任何内容。",
    )
    "reviewStale" -> reviewText(
        "The original changed again after review. Check it again before deciding.",
        "审阅后原始文件又发生变化。请重新检查后再决定。",
    )
    "originalUnavailable" -> reviewText(
        "The current original could not be read again. Nothing was written and the review is retained.",
        "无法再次读取当前原始文件。未写入任何内容，审阅记录仍保留。",
    )
    "originalCasUnavailable", "originalCasNotImplemented" -> reviewText(
        "Overwriting the original is not available here; this viewer owns no original compare-and-swap authority.",
        "此处不支持覆盖原始文件；此查看器没有原始文件的比较并交换权限。",
    )
    "sessionFenced", "sessionMismatch" -> reviewText(
        "The document session changed. Reopen the review.",
        "文档会话已变化。请重新打开审阅。",
    )
    "reviewExpired" -> reviewText(
        "This review expired. Check the original again.",
        "此审阅已过期。请重新检查原始文件。",
    )
    "previewUnavailable", "previewUnreadable", "previewStorageUnavailable", "previewFailed" -> reviewText(
        "The saved version could not be read for preview. Nothing was changed.",
        "无法读取该已保存版本进行预览。未更改任何内容。",
    )
    "previewEmpty" -> reviewText(
        "No readable text was found in this version.",
        "此版本中未找到可读取的文本。",
    )
    "previewUnsupported" -> reviewText(
        "This version cannot be shown as a text preview.",
        "此版本无法以文本预览显示。",
    )
    "previewTooLarge" -> reviewText(
        "This version is too large for the text preview.",
        "此版本过大，无法进行文本预览。",
    )
    "previewBusy" -> reviewText(
        "Another preview is still open. Close it and try again.",
        "另一个预览仍处于打开状态。请关闭后重试。",
    )
    "snapshotMismatch" -> reviewText(
        "This version changed after it was reviewed. Check the original again.",
        "此版本在审阅后发生变化。请重新检查原始文件。",
    )
    else -> reviewText(
        "The original was not changed ($code).",
        "原始文件未更改（$code）。",
    )
}

@Composable
private fun ReviewVersionLine(
    label: String,
    sha256: String?,
    bytes: Long,
    revision: String?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        FloeText(
            text = if (java.util.Locale.getDefault().language == "zh") {
                when (label) {
                    "My version (saved working copy)" -> "我的版本（已保存的工作副本）"
                    "Current original" -> "当前原始文件"
                    else -> label
                }
            } else {
                label
            },
            style = Floe.typography.bodyEmphasized,
        )
        FloeText(
            text = "SHA-256 ${shortSha(sha256)} · ${bytes} B" +
                (revision?.takeIf { it.isNotBlank() }?.let { " · rev " + it.take(24) } ?: ""),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
    }
}

@Composable
private fun NoticeGlyph(key: String) {
    val icon = when (key) {
        "loadError", "transportFailed", "jsError", "saveFailed", "copyFailed",
        "editPermissionDenied", "protectedDocument", "editEntryUnavailable",
        "pdfFailed", "printUnavailable" -> FloeIcons.WarningTriangle
        "saveUnknown" -> FloeIcons.WarningTriangle
        "saveFlushed", "copySaved", "pdfRevisionsKept", "originalUnchanged",
        "originalKept", "originalSaved" -> FloeIcons.CheckCircle
        "macroBlocked" -> FloeIcons.ShieldAlert
        "revisionFailed", "pdfRevisionWarning", "originalStale",
        "originalSaveConflict", "originalSaveFailed" -> FloeIcons.WarningTriangle
        "originalSavedSourcePending", "originalSavedSourceConflict",
        "originalUnchangedSourcePending", "originalUnchangedSourceConflict",
        -> FloeIcons.WarningTriangle
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
        "revisionPending" -> reviewText(
            "Change request sent; waiting for the document to acknowledge it.",
            "更改请求已发送；正在等待文档确认。",
        )
        "revisionFailed" -> reviewText(
            "The tracked-change request was not sent.",
            "修订请求未发送。",
        )
        "pdfRevisionsKept" -> reviewText(
            "PDF created. Revisions remain in the source document.",
            "PDF 已创建。修订仍保留在源文档中。",
        )
        "pdfRevisionWarning" -> reviewText(
            "PDF created, but an accept/reject action was observed during export.",
            "PDF 已创建，但导出期间观察到接受/拒绝操作。",
        )
        "originalChanged" -> reviewText(
            "The original changed since you opened it. Review both versions before deciding.",
            "打开后原始文件已变化。决定前请审阅两个版本。",
        )
        "originalUnchanged" -> reviewText(
            "The original still matches the version you opened.",
            "原始文件仍与打开时的版本一致。",
        )
        "originalKept" -> reviewText(
            "The current original was kept; your version remains retained.",
            "当前原始文件已保留；你的版本仍被保存。",
        )
        "originalStale" -> reviewText(
            "The original changed again. Check it again before deciding.",
            "原始文件又发生变化。决定前请重新检查。",
        )
        // Manual workspace original save (OFC-SAVE-REOPEN): honest wording —
        // "saved" only after the App's real CAS answer; a conflict keeps the
        // editor open and routes the decision to the existing review.
        "originalSaved" -> reviewText(
            "Saved to the original in your workspace.",
            "已保存到工作空间中的原始文件。",
        )
        "originalSaveConflict" -> reviewText(
            "The original changed and wasn\'t overwritten. Your version is kept — review both versions to decide.",
            "原始文件已变化，未覆盖。你的版本已保留——请审阅两个版本后再决定。",
        )
        "originalSaveFailed" -> reviewText(
            "Couldn\'t save to the original. Your working copy is kept.",
            "保存到原始文件失败，工作副本已保留。",
        )
        // The local original is saved (or already current) but the attached
        // provider sync is incomplete — never worded as a fully synced save,
        // and the editor stays open with everything retained.
        "originalSavedSourcePending" -> reviewText(
            "Saved to the original in your workspace. Syncing to your connected file provider is still pending — reconcile it from Provider files.",
            "已保存到工作空间中的原始文件。与已连接文件提供方的同步仍在等待——可在“外部文件”中核对处理。",
        )
        "originalSavedSourceConflict" -> reviewText(
            "Saved to the original in your workspace. Your file provider has a conflicting version — review it in Provider files.",
            "已保存到工作空间中的原始文件。你的文件提供方存在冲突版本——请在“外部文件”中审阅处理。",
        )
        "originalUnchangedSourcePending" -> reviewText(
            "Your edits are already saved in the workspace original. Syncing to your connected file provider is still pending — reconcile it from Provider files.",
            "你的更改已保存在工作空间原始文件中。与已连接文件提供方的同步仍在等待——可在“外部文件”中核对处理。",
        )
        "originalUnchangedSourceConflict" -> reviewText(
            "Your edits are already saved in the workspace original. Your file provider has a conflicting version — review it in Provider files.",
            "你的更改已保存在工作空间原始文件中。你的文件提供方存在冲突版本——请在“外部文件”中审阅处理。",
        )
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
