// SPDX-License-Identifier: MPL-2.0
//
// C07 App-entry host: the ONE Application-scoped owner for external SEND /
// SEND_MULTIPLE / VIEW arrivals, floe:// links and question/schedule
// notification taps.
//
// Boundaries:
//  * Incoming content is DATA, never authority. No route/tool/approval/run is
//    started, no model text or path is trusted, and no file is overwritten.
//  * Real destinations only: the existing Home attachment staging boundary
//    (installed by Main) and the existing NotesService import/create API.
//  * Grants are the App-wide SharedUriGrantAuthority leases for exactly this
//    intake; they are released on settle/cancel and never persisted as
//    permission truth. The tiny journal keeps only a digest + status.
//  * Deep links and notification taps re-read the EXISTING conversation /
//    schedule stores; a deleted or fenced target is refused with honest copy.
package com.floe.android.host.entryflow

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.floe.android.FloeApplication
import com.floe.android.FloeFoundation
import com.floe.android.HomeDraftTransfer
import com.floe.android.feature.entryflow.EntryExportReceiptUi
import com.floe.android.feature.entryflow.EntryFeedbackError
import com.floe.android.feature.entryflow.EntryFeedbackPhase
import com.floe.android.feature.entryflow.EntryFeedbackUi
import com.floe.android.feature.entryflow.EntryNoticeKind
import com.floe.android.feature.entryflow.EntryReviewAvailability
import com.floe.android.feature.entryflow.EntrySetupStep
import com.floe.android.feature.entryflow.EntrySetupUi
import com.floe.android.feature.entryflow.EntryShareDestination
import com.floe.android.feature.entryflow.EntryShareError
import com.floe.android.feature.entryflow.EntryShareItemUi
import com.floe.android.feature.entryflow.EntrySharePhase
import com.floe.android.feature.entryflow.EntryShareUi
import com.floe.android.feature.notes.NotesService
import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostOperationOutcome
import com.floe.android.host.HostScope
import com.floe.android.host.RuntimeHost
import com.floe.android.host.SharedUriGrantAuthority
import com.floe.android.safgateway.SafSharedGrantBroker
import com.floe.android.schedule.TaskScheduleCommands
import com.floe.android.schedule.TaskScheduleResult
import java.io.IOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Main composition installs the REAL existing Home draft staging adapter. It
 * must stage only the supplied content URIs into the CURRENT draft owner and
 * return false before starting any copy when that owner changed.
 */
internal fun interface C07HomeAttachmentStager {
    fun stage(uris: List<Uri>): Boolean
}

/**
 * The EXISTING package inspection/review owner (Data Exchange for
 * `.floenote`/`.flocanvas`/`.floebackup`, the CAD package/folder import for
 * `.floecad`). Main installs the real adapter; the entry flow never restores,
 * remaps or auto-imports a package itself.
 *
 * The implementation takes ownership of [releaseSource] and MUST invoke it
 * exactly once after its own source read/copy settles: the entry owner has
 * already transferred its reference at the moment [beginReview] returns true.
 * It must synchronously retain its own read reference before any asynchronous
 * work, exactly like the attachment-staging handoff.
 */
internal interface C07PackageReviewOwner {
    /** True only when this owner really offers the existing directory
     * `.floecad` tree/package import. A single-file Data Exchange owner
     * reports false so the sheet can state the precise missing path. */
    val supportsDirectoryPackages: Boolean get() = false

    /** Existing settings category that shows the live review, or null when the
     * owner has no public surface to open. */
    val settingsSectionKey: String? get() = null

    fun beginReview(
        uri: Uri,
        kind: C07EntryPackageKind,
        displayName: String,
        releaseSource: () -> Unit,
    ): Boolean
}

internal object C07EntryFlowHost {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val io = Dispatchers.IO
    private val admissionGeneration = AtomicLong(0L)
    private val focusSequence = AtomicLong(0L)
    private val draftRevision = AtomicLong(0L)

    private lateinit var appContext: Context
    private lateinit var intakeStore: C07EntryFlowStore
    private lateinit var setupStore: C07SetupGuideStore
    private var initialized = false

    private var runtimeHost: RuntimeHost? = null
    private var notes: NotesService? = null
    private var homeStager: C07HomeAttachmentStager? = null
    private var packageReviewOwner: C07PackageReviewOwner? = null
    private var admissionJob: Job? = null
    private var activeJob: Job? = null
    private var linkJob: Job? = null
    private var feedbackJob: Job? = null
    private var noticeJob: Job? = null
    private var pendingRawShare: C07RawShare? = null
    private var setupPendingOffer = false
    private val pendingRoutes = ArrayDeque<C07EntryRoute>()
    private val replayGuard = C07EntryReplayGuard()

    private val activeState = MutableStateFlow<ActiveIntake?>(null)
    private val shareUiState = MutableStateFlow<EntryShareUi?>(null)
    private val setupUiState = MutableStateFlow<EntrySetupUi?>(null)
    private val setupState = MutableStateFlow(C07SetupState())
    private val noticeState = MutableStateFlow<EntryNoticeKind?>(null)
    private val navigationState = MutableStateFlow<C07EntryNavigation?>(null)
    private val scheduleFocusState = MutableStateFlow<C07ScheduleFocus?>(null)
    private val homeDraftState = MutableStateFlow<C07HomeDraftAdoption?>(null)
    private val feedbackState = MutableStateFlow(EntryFeedbackUi())
    private val settingsSectionState = MutableStateFlow<String?>(null)

    val shareUi: StateFlow<EntryShareUi?> = shareUiState.asStateFlow()
    val setupUi: StateFlow<EntrySetupUi?> = setupUiState.asStateFlow()
    val notice: StateFlow<EntryNoticeKind?> = noticeState.asStateFlow()
    val navigation: StateFlow<C07EntryNavigation?> = navigationState.asStateFlow()
    val scheduleFocus: StateFlow<C07ScheduleFocus?> = scheduleFocusState.asStateFlow()
    val homeDraftAdoption: StateFlow<C07HomeDraftAdoption?> = homeDraftState.asStateFlow()
    val feedback: StateFlow<EntryFeedbackUi> = feedbackState.asStateFlow()

    /** One-shot request to open an EXISTING settings category (the package
     * review owner's page). Consumed by the shell surface; never navigates on
     * arrival or before the owner really accepted the handoff. */
    val openSettingsSection: StateFlow<String?> = settingsSectionState.asStateFlow()

    @Synchronized
    fun initialize(context: Context) {
        if (initialized) return
        appContext = context.applicationContext ?: context
        intakeStore = C07EntryFlowStore(appContext)
        setupStore = C07SetupGuideStore(appContext)
        setupState.value = setupStore.load()
        intakeStore.purge(System.currentTimeMillis())
        initialized = true
    }

    fun attach(host: RuntimeHost) {
        if (!initialized) initialize(host.appContextOrNull ?: return)
        if (runtimeHost === host) return
        runtimeHost = host
        notes = null
        val pending = pendingRoutes.toList()
        pendingRoutes.clear()
        pending.forEach { route ->
            when (route) {
                C07EntryRoute.NewTask -> navigationState.value =
                    C07EntryNavigation.OpenNewTask(null)
                is C07EntryRoute.Task -> resolveTaskRoute(route.conversationID)
                is C07EntryRoute.Schedule -> resolveScheduleRoute(route.scheduleID)
                is C07EntryRoute.Share -> Unit
            }
        }
        pendingRawShare?.let {
            pendingRawShare = null
            startAdmission(it)
        }
        maybeOfferInitialSetup()
    }

    fun installHomeAttachmentStager(stager: C07HomeAttachmentStager) {
        homeStager = stager
    }

    fun installPackageReviewOwner(owner: C07PackageReviewOwner) {
        packageReviewOwner = owner
    }

    fun consumeOpenSettingsSection(key: String) {
        settingsSectionState.compareAndSet(key, null)
    }

    /** Entry point from the Activity's onCreate + onNewIntent. Idempotent for
     * the same Intent (rotation/recreation/process-restart redelivery). */
    fun admit(context: Context, intent: Intent?) {
        initialize(context)
        val incoming = intent ?: return
        val componentPackage = incoming.component?.packageName
        if (componentPackage != null && componentPackage != context.packageName) return
        when (incoming.action) {
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> admitShare(incoming)
            Intent.ACTION_VIEW -> {
                val data = incoming.data ?: return
                if (data.scheme.equals("floe", ignoreCase = true)) {
                    admitLink(data.toString())
                } else {
                    admitShare(incoming)
                }
            }
            C07EntryNotification.ACTION_QUESTION -> admitQuestionTap(incoming)
            C07EntryNotification.ACTION_SCHEDULE -> admitScheduleTap(incoming)
            else -> if (incoming.hasExtra(C07EntryNotification.EXTRA_SCHEDULE_ID)) {
                admitScheduleTap(incoming)
            }
        }
    }

    fun consumeNavigation(expected: C07EntryNavigation) {
        if (navigationState.compareAndSet(expected, null)) {
            resumeDeferredSetup()
        }
    }

    fun consumeScheduleFocus(requestID: Long) {
        val current = scheduleFocusState.value
        if (current?.requestID == requestID) {
            scheduleFocusState.compareAndSet(current, null)
        }
    }

    fun consumeHomeDraftAdoption(revision: Long) {
        val current = homeDraftState.value
        if (current?.revision == revision) {
            homeDraftState.compareAndSet(current, null)
        }
    }

    fun dismissNotice() {
        noticeJob?.cancel()
        noticeState.value = null
    }

    /** The shell refused an ordinary route because a temporary-chat fence or
     * another real navigation won. Nothing was committed; say so. */
    fun navigationRefused() {
        showNotice(EntryNoticeKind.TEMP_REFUSED)
    }

    /* ------------------------------ setup guide ------------------------------ */

    fun openSetupGuide() {
        if (!initialized) return
        val state = setupState.value.copy(seen = true, updatedAt = now())
        setupState.value = state
        setupStore.save(state)
        publishSetup(visible = true)
    }

    fun nextSetupStep() {
        val state = C07SetupMachine.next(setupState.value, now())
        if (state == setupState.value) return
        setupState.value = state
        setupStore.save(state)
        publishSetup(visible = true)
    }

    fun previousSetupStep() {
        val state = C07SetupMachine.previous(setupState.value, now())
        if (state == setupState.value) return
        setupState.value = state
        setupStore.save(state)
        publishSetup(visible = true)
    }

    fun dismissSetupGuide() {
        val state = C07SetupMachine.dismiss(setupState.value, now())
        setupState.value = state
        setupStore.save(state)
        setupUiState.value = null
    }

    fun skipSetupGuide() {
        val state = C07SetupMachine.skip(setupState.value, now())
        setupState.value = state
        setupStore.save(state)
        setupUiState.value = null
    }

    fun finishSetupGuide() {
        val state = C07SetupMachine.finish(setupState.value, now())
        setupState.value = state
        setupStore.save(state)
        setupUiState.value = null
    }

    private fun maybeOfferInitialSetup() {
        if (setupState.value.seen || setupUiState.value != null) return
        if (activeState.value != null || pendingRawShare != null ||
            shareUiState.value != null || admissionJob?.isActive == true ||
            navigationState.value != null
        ) {
            setupPendingOffer = true
            return
        }
        // Showing the guide once consumes the automatic offer. It is never
        // forced on every startup; Settings can reopen it at any time.
        val (state, offered) = C07SetupMachine.offerOnce(setupState.value, now())
        if (!offered) return
        setupState.value = state
        setupStore.save(state)
        publishSetup(visible = true)
    }

    private fun publishSetup(visible: Boolean) {
        val state = setupState.value
        setupUiState.value = EntrySetupUi(
            step = when (state.step) {
                C07SetupStep.WELCOME -> EntrySetupStep.WELCOME
                C07SetupStep.MODELS -> EntrySetupStep.MODELS
                C07SetupStep.VOICE -> EntrySetupStep.VOICE
                C07SetupStep.FILES -> EntrySetupStep.FILES
                C07SetupStep.NOTIFICATIONS -> EntrySetupStep.NOTIFICATIONS
                C07SetupStep.DONE -> EntrySetupStep.DONE
            },
            index = state.step.ordinal,
            total = C07SetupStep.entries.size,
            visible = visible,
        )
    }

    /* ------------------------------ feedback ------------------------------ */

    fun updateFeedbackProblem(value: String) {
        feedbackState.value = feedbackState.value.copy(
            problem = value.take(ENTRY_MAX_FEEDBACK_CHARS),
            phase = EntryFeedbackPhase.IDLE,
            error = null,
            receipt = null,
        )
    }

    fun setFeedbackDiagnostics(include: Boolean) {
        feedbackState.value = feedbackState.value.copy(includeDiagnostics = include)
    }

    fun exportFeedback(uri: Uri, resultFlags: Int) {
        if (!initialized) {
            feedbackState.value = feedbackState.value.copy(
                phase = EntryFeedbackPhase.FAILED,
                error = EntryFeedbackError.UNAVAILABLE,
            )
            return
        }
        if (feedbackState.value.busy) return
        val problem = feedbackState.value.problem.trim()
        if (problem.isEmpty()) {
            feedbackState.value = feedbackState.value.copy(
                phase = EntryFeedbackPhase.FAILED,
                error = EntryFeedbackError.EMPTY_PROBLEM,
            )
            return
        }
        val include = feedbackState.value.includeDiagnostics
        feedbackState.value = feedbackState.value.copy(
            phase = EntryFeedbackPhase.PREPARING,
            error = null,
            receipt = null,
        )
        feedbackJob?.cancel()
        feedbackJob = scope.launch {
            try {
                val text = withContext(io) {
                    C07DiagnosticsExport.build(appContext, runtimeHost, problem, include)
                }
                feedbackState.value = feedbackState.value.copy(
                    phase = EntryFeedbackPhase.WRITING,
                )
                val receipt = withContext(io) {
                    C07DiagnosticsExport.write(appContext, uri, text, resultFlags)
                }
                withContext(Dispatchers.Main.immediate) {
                    feedbackState.value = feedbackState.value.copy(
                        phase = EntryFeedbackPhase.COMPLETE,
                        receipt = EntryExportReceiptUi(
                            byteCount = receipt.byteCount,
                            sha256Prefix = receipt.sha256Prefix,
                        ),
                        error = null,
                    )
                }
            } catch (cancelled: CancellationException) {
                withContext(NonCancellable + Dispatchers.Main.immediate) {
                    feedbackState.value = feedbackState.value.copy(
                        phase = EntryFeedbackPhase.CANCELLED,
                        error = EntryFeedbackError.CANCELLED,
                    )
                }
                throw cancelled
            } catch (_: Throwable) {
                withContext(Dispatchers.Main.immediate) {
                    feedbackState.value = feedbackState.value.copy(
                        phase = EntryFeedbackPhase.FAILED,
                        error = EntryFeedbackError.WRITE_FAILED,
                    )
                }
            }
        }
    }

    fun cancelFeedbackExport() {
        feedbackJob?.cancel()
    }

    fun feedbackExportUnavailable() {
        feedbackState.value = feedbackState.value.copy(
            phase = EntryFeedbackPhase.FAILED,
            error = EntryFeedbackError.UNAVAILABLE,
        )
    }

    fun dismissFeedbackReceipt() {
        feedbackState.value = feedbackState.value.copy(
            phase = EntryFeedbackPhase.IDLE,
            receipt = null,
            error = null,
        )
    }

    /* ------------------------------ share intake ------------------------------ */

    private fun admitLink(raw: String) {
        if (!markRecent("link:$raw")) return
        when (val parsed = C07EntryRouteParser.parse(raw)) {
            is C07RouteParse.Refused -> showNotice(EntryNoticeKind.INVALID_LINK)
            is C07RouteParse.Parsed -> when (val route = parsed.route) {
                C07EntryRoute.NewTask ->
                    navigationState.value = C07EntryNavigation.OpenNewTask(null)
                is C07EntryRoute.Task -> resolveTaskRoute(route.conversationID)
                is C07EntryRoute.Schedule -> resolveScheduleRoute(route.scheduleID)
                is C07EntryRoute.Share -> {
                    val intake = activeState.value
                    if (intake != null &&
                        (route.intakeID == null || route.intakeID == intake.id)
                    ) {
                        if (shareUiState.value == null) {
                            publishShare(intake, EntrySharePhase.READY)
                        }
                    } else {
                        showNotice(EntryNoticeKind.SHARE_UNAVAILABLE)
                    }
                }
            }
        }
    }

    private fun admitShare(intent: Intent) {
        val raw = C07ShareIntentReader.read(intent) ?: return
        val active = activeState.value
        if (active != null) {
            if (active.rawSignature == raw.signature) {
                // Rotation/recreation redelivery: keep the CURRENT working or
                // failed state. It must not reset a running destination to
                // READY and invite a second copy.
                if (shareUiState.value == null) {
                    publishShare(active, EntrySharePhase.READY)
                }
            } else {
                showNotice(EntryNoticeKind.BUSY)
            }
            return
        }
        if (admissionJob?.isActive == true) {
            showNotice(EntryNoticeKind.BUSY)
            return
        }
        if (raw.itemHint > ENTRY_MAX_ITEMS) {
            showNotice(EntryNoticeKind.ITEM_LIMIT)
            return
        }
        if (raw.itemHint <= 0) {
            showNotice(EntryNoticeKind.SHARE_UNAVAILABLE)
            return
        }
        if (runtimeHost == null) {
            pendingRawShare = raw
            shareUiState.value = EntryShareUi(
                items = emptyList(),
                textPreview = rawPreview(raw),
                phase = EntrySharePhase.PREPARING,
                totalCount = raw.itemHint,
            )
            return
        }
        startAdmission(raw)
    }

    private fun startAdmission(raw: C07RawShare) {
        val generation = admissionGeneration.incrementAndGet()
        shareUiState.value = EntryShareUi(
            items = emptyList(),
            textPreview = rawPreview(raw),
            phase = EntrySharePhase.PREPARING,
            totalCount = raw.itemHint,
        )
        admissionJob = scope.launch {
            val prepared = try {
                withContext(io) { prepare(raw, generation) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                Prepared.Refused(C07EntryRefusal.UNREADABLE)
            }
            withContext(Dispatchers.Main.immediate) {
                completeAdmission(raw, prepared, generation)
            }
        }
    }

    private sealed interface Prepared {
        data class Ok(
            val items: List<C07EntryCapturedItem>,
            val leases: List<SafSharedGrantBroker.Lease>,
            val fingerprint: String,
            val taskAvailable: Boolean,
            val notesAvailable: Boolean,
            val packageKind: C07EntryPackageKind,
        ) : Prepared

        data class Refused(val code: C07EntryRefusal) : Prepared
    }

    private suspend fun prepare(raw: C07RawShare, generation: Long): Prepared {
        val leases = mutableListOf<SafSharedGrantBroker.Lease>()
        var accepted = false
        try {
            if (admissionGeneration.get() != generation) {
                return Prepared.Refused(C07EntryRefusal.STALE)
            }
            val items = mutableListOf<C07EntryCapturedItem>()
            var index = 0
            raw.text?.takeIf { it.isNotBlank() }?.let { text ->
                items += C07EntryCapturedItem(
                    index = index++,
                    kind = C07EntryItemKind.TEXT,
                    uriString = null,
                    mimeType = "text/plain",
                    displayName = "Shared text",
                    declaredBytes = text.toByteArray(Charsets.UTF_8).size.toLong(),
                    text = text,
                    contentClass = C07EntryContentClass.TEXT,
                )
            }
            for (uriString in raw.uriStrings) {
                if (admissionGeneration.get() != generation) {
                    return Prepared.Refused(C07EntryRefusal.STALE)
                }
                val uri = runCatching { Uri.parse(uriString) }.getOrNull()
                    ?: return Prepared.Refused(C07EntryRefusal.INVALID_URI)
                if (uri.scheme != "content") {
                    return Prepared.Refused(C07EntryRefusal.INVALID_URI)
                }
                val tree = try {
                    DocumentsContract.isTreeUri(uri)
                } catch (_: RuntimeException) {
                    false
                }
                val lease = try {
                    SharedUriGrantAuthority.acquireRead(
                        resolver = appContext.contentResolver,
                        uri = uri,
                        allowPersistence = raw.persistable,
                    )
                } catch (_: SecurityException) {
                    return Prepared.Refused(C07EntryRefusal.GRANT_REVOKED)
                } catch (_: IllegalArgumentException) {
                    return Prepared.Refused(C07EntryRefusal.INVALID_URI)
                }
                leases += lease
                val meta = queryMeta(uri)
                val extensionPackage = C07EntryPackageKind.ofExtension(
                    C07SharePolicy.extension(meta.displayName),
                )
                if (tree) {
                    // A tree URI cannot be copied as one stream. Only the
                    // existing directory-package importer may take it, and
                    // only for an actual .floecad package.
                    if (extensionPackage != C07EntryPackageKind.CAD) {
                        return Prepared.Refused(C07EntryRefusal.INVALID_URI)
                    }
                    items += C07EntryCapturedItem(
                        index = index++,
                        kind = C07EntryItemKind.FILE,
                        uriString = uriString,
                        mimeType = "application/vnd.floe.cad.package",
                        displayName = meta.displayName,
                        declaredBytes = meta.byteCount.takeIf { it > 0L } ?: -1L,
                        text = null,
                        contentClass = C07EntryContentClass.PACKAGE,
                        packageKind = C07EntryPackageKind.CAD,
                        format = cadPackageFormat(meta.displayName),
                    )
                    continue
                }
                if (extensionPackage == C07EntryPackageKind.CAD) {
                    // A .floecad package is a DIRECTORY. Never open it as a
                    // single stream and never convert it to a ZIP guess.
                    items += C07EntryCapturedItem(
                        index = index++,
                        kind = C07EntryItemKind.FILE,
                        uriString = uriString,
                        mimeType = "application/vnd.floe.cad.package",
                        displayName = meta.displayName,
                        declaredBytes = meta.byteCount.takeIf { it > 0L } ?: -1L,
                        text = null,
                        contentClass = C07EntryContentClass.PACKAGE,
                        packageKind = C07EntryPackageKind.CAD,
                        format = cadPackageFormat(meta.displayName),
                    )
                    continue
                }
                val probe = try {
                    appContext.contentResolver.openInputStream(uri)?.use {
                        C07ContentSniffer.probe(it)
                    }
                } catch (_: SecurityException) {
                    return Prepared.Refused(C07EntryRefusal.GRANT_REVOKED)
                } catch (_: IOException) {
                    return Prepared.Refused(C07EntryRefusal.UNREADABLE)
                } ?: return Prepared.Refused(C07EntryRefusal.UNREADABLE)
                val decision = C07ContentSniffer.reconcile(
                    declaredRaw = meta.mimeType,
                    kind = probe,
                    displayName = meta.displayName,
                )
                val mime = decision.mimeType
                    ?: return Prepared.Refused(decision.refusal ?: C07EntryRefusal.UNSUPPORTED)
                val declaredBytes = when {
                    meta.byteCount > 0L -> meta.byteCount
                    // A package is copied by the existing review owner under
                    // its own budget; never spool/measure it here.
                    decision.packageKind.isPackage -> -1L
                    else -> try {
                        measureBytes(uri)
                    } catch (error: C07EntryImportException) {
                        return Prepared.Refused(error.refusal)
                    }
                }
                items += C07EntryCapturedItem(
                    index = index++,
                    kind = C07EntryItemKind.FILE,
                    uriString = uriString,
                    mimeType = mime,
                    displayName = meta.displayName,
                    declaredBytes = declaredBytes,
                    text = null,
                    contentClass = decision.contentClass,
                    packageKind = decision.packageKind,
                    format = decision.format,
                )
            }
            return when (val validation = C07SharePolicy.validate(items)) {
                is C07ShareValidation.Refused -> Prepared.Refused(validation.code)
                is C07ShareValidation.Accepted -> {
                    accepted = true
                    Prepared.Ok(
                        items = items,
                        leases = leases,
                        fingerprint = C07EntryFingerprint.of(raw.action, raw.subject, items),
                        taskAvailable = validation.taskAvailable,
                        notesAvailable = validation.notesAvailable,
                        packageKind = validation.packageKind,
                    )
                }
            }
        } finally {
            if (!accepted) leases.forEach { runCatching { it.release() } }
        }
    }

    private fun completeAdmission(
        raw: C07RawShare,
        prepared: Prepared,
        generation: Long,
    ) {
        if (generation != admissionGeneration.get()) {
            if (prepared is Prepared.Ok) {
                prepared.leases.forEach { runCatching { it.release() } }
            }
            return
        }
        if (activeState.value != null) {
            if (prepared is Prepared.Ok) {
                prepared.leases.forEach { runCatching { it.release() } }
            }
            showNotice(EntryNoticeKind.BUSY)
            return
        }
        when (prepared) {
            is Prepared.Refused -> {
                shareUiState.value = null
                showNotice(noticeFor(prepared.code))
            }
            is Prepared.Ok -> {
                val now = now()
                val fingerprint = prepared.fingerprint
                if (intakeStore.isDuplicate(fingerprint, null, now)) {
                    prepared.leases.forEach { runCatching { it.release() } }
                    shareUiState.value = null
                    showNotice(EntryNoticeKind.ALREADY_HANDLED)
                    return
                }
                val intake = ActiveIntake(
                    id = UUID.randomUUID().toString(),
                    fingerprint = fingerprint,
                    rawSignature = raw.signature,
                    subject = raw.subject,
                    items = prepared.items,
                    preview = C07EntryCopy.textPreview(prepared.items),
                    leases = prepared.leases.toMutableList(),
                    createdAt = now,
                    canTask = prepared.taskAvailable,
                    canNotes = prepared.notesAvailable,
                    packageKind = prepared.packageKind,
                )
                intakeStore.begin(fingerprint, intake.id, now)
                activeState.value = intake
                publishShare(intake, EntrySharePhase.READY)
            }
        }
    }

    fun chooseTaskDestination(intakeID: String) {
        val intake = activeState.value ?: return
        val phase = shareUiState.value?.phase
        if (intake.id != intakeID ||
            (phase != EntrySharePhase.READY && phase != EntrySharePhase.FAILED)
        ) {
            return
        }
        if (activeJob?.isActive == true) {
            showNotice(EntryNoticeKind.BUSY)
            return
        }
        if (!intake.canTask || intake.packageKind.isPackage) {
            // A package has one inspection/review owner; it is never staged
            // into a draft or a Notes file note by the generic destinations.
            publishShare(
                intake,
                EntrySharePhase.FAILED,
                error = EntryShareError.UNSUPPORTED,
                destination = EntryShareDestination.TASK,
            )
            return
        }
        val hasFiles = intake.items.any { it.kind == C07EntryItemKind.FILE }
        if (hasFiles &&
            (homeStager == null ||
                runtimeHost?.readiness?.value?.attachmentStagingAdmitted != true)
        ) {
            publishShare(
                intake,
                EntrySharePhase.FAILED,
                error = EntryShareError.STAGING_UNAVAILABLE,
                destination = EntryShareDestination.TASK,
            )
            return
        }
        publishShare(intake, EntrySharePhase.WORKING, destination = EntryShareDestination.TASK)
        navigationState.value = C07EntryNavigation.OpenNewTask(intake.id)
    }

    /** Called by the shell only AFTER the New Task route really committed. */
    fun applyTaskDestination(intakeID: String) {
        val intake = activeState.value ?: return
        if (intake.id != intakeID) return
        if (intake.packageKind.isPackage) {
            // Defensive: a package is never staged through the generic draft
            // boundary, even if a stale navigation callback arrives.
            failShare(intake, C07EntryRefusal.UNSUPPORTED)
            return
        }
        val text = intake.items
            .filter { it.kind == C07EntryItemKind.TEXT }
            .mapNotNull { it.text }
            .joinToString("\n\n")
            .trim()
        val files = intake.items
            .filter { it.kind == C07EntryItemKind.FILE }
            .mapNotNull { item ->
                item.uriString?.let { value -> runCatching { Uri.parse(value) }.getOrNull() }
            }
        if (text.isEmpty() && files.isEmpty()) {
            failShare(intake, C07EntryRefusal.EMPTY)
            return
        }
        val merged = if (text.isEmpty()) {
            HomeDraftTransfer.draft(FloeFoundation.draftStore)
        } else {
            C07EntryMerge.text(HomeDraftTransfer.draft(FloeFoundation.draftStore), text)
                ?: run {
                    publishShare(
                        intake,
                        EntrySharePhase.FAILED,
                        error = EntryShareError.TOO_LARGE,
                        destination = EntryShareDestination.TASK,
                    )
                    return
                }
        }
        if (files.isNotEmpty()) {
            val stager = homeStager
            if (stager == null ||
                runtimeHost?.readiness?.value?.attachmentStagingAdmitted != true
            ) {
                publishShare(
                    intake,
                    EntrySharePhase.FAILED,
                    error = EntryShareError.STAGING_UNAVAILABLE,
                    destination = EntryShareDestination.TASK,
                )
                return
            }
            val staged = runCatching { stager.stage(files) }.getOrDefault(false)
            if (!staged) {
                publishShare(
                    intake,
                    EntrySharePhase.FAILED,
                    error = EntryShareError.TEMP_REFUSED,
                    destination = EntryShareDestination.TASK,
                )
                return
            }
        }
        if (text.isNotEmpty()) {
            HomeDraftTransfer.update(FloeFoundation.draftStore, merged)
            homeDraftState.value = C07HomeDraftAdoption(
                revision = draftRevision.incrementAndGet(),
                text = merged,
            )
        }
        settle(
            intake,
            C07EntryJournalStatus.COMPLETED,
            clear = false,
        )
        publishShare(intake, EntrySharePhase.COMPLETE, destination = EntryShareDestination.TASK)
    }

    fun taskDestinationRefused(intakeID: String, temporary: Boolean) {
        val intake = activeState.value ?: return
        if (intake.id != intakeID) return
        publishShare(
            intake,
            EntrySharePhase.FAILED,
            error = if (temporary) EntryShareError.TEMP_REFUSED else EntryShareError.STAGING_UNAVAILABLE,
            destination = EntryShareDestination.TASK,
        )
    }

    fun chooseNotesDestination(intakeID: String) {
        val intake = activeState.value ?: return
        if (intake.id != intakeID) return
        if (activeJob?.isActive == true) {
            showNotice(EntryNoticeKind.BUSY)
            return
        }
        if (!intake.canNotes || intake.packageKind.isPackage) {
            publishShare(
                intake,
                EntrySharePhase.FAILED,
                error = EntryShareError.UNSUPPORTED,
                destination = EntryShareDestination.NOTES,
            )
            return
        }
        val service = notesService()
        if (service == null) {
            publishShare(
                intake,
                EntrySharePhase.FAILED,
                error = EntryShareError.NOTES_UNAVAILABLE,
                destination = EntryShareDestination.NOTES,
            )
            return
        }
        publishShare(intake, EntrySharePhase.WORKING, destination = EntryShareDestination.NOTES)
        val importer = C07EntryNotesImporter(appContext.contentResolver, appContext.cacheDir) {
            val app = appContext.applicationContext as? FloeApplication
                ?: throw C07EntryImportException(C07EntryRefusal.NOTES_UNAVAILABLE)
            withContext(Dispatchers.Main.immediate) { app.ensureNotesPlatform() }
            val state = withTimeoutOrNull(15_000) {
                app.notesPlatform.first {
                    it is com.floe.android.NotesPlatformLoadState.Ready ||
                        it is com.floe.android.NotesPlatformLoadState.Failed
                }
            }
            (state as? com.floe.android.NotesPlatformLoadState.Ready)?.host?.media
                ?: throw C07EntryImportException(C07EntryRefusal.NOTES_UNAVAILABLE)
        }
        activeJob = scope.launch {
            try {
                val saved = withContext(io) {
                    importer.import(
                        C07EntryImportRequest(
                            intake.id,
                            intake.subject,
                            intake.items,
                            appContext.getString(
                                com.floe.android.feature.entryflow.R.string.entry_shared_note_title,
                            ),
                        ),
                        service,
                    )
                }
                withContext(Dispatchers.Main.immediate) {
                    if (activeState.value?.id != intake.id) return@withContext
                    settle(intake, C07EntryJournalStatus.COMPLETED, clear = false)
                    publishShare(
                        intake,
                        EntrySharePhase.COMPLETE,
                        destination = EntryShareDestination.NOTES,
                        savedNotes = saved,
                        canOpenNotes = true,
                    )
                }
            } catch (cancelled: CancellationException) {
                withContext(NonCancellable + Dispatchers.Main.immediate) {
                    if (activeState.value?.id == intake.id) {
                        settle(intake, C07EntryJournalStatus.DISCARDED, clear = true)
                        showNotice(EntryNoticeKind.DISCARDED)
                    }
                }
                throw cancelled
            } catch (error: C07EntryImportException) {
                withContext(Dispatchers.Main.immediate) {
                    failShare(intake, error.refusal)
                }
            } catch (_: Throwable) {
                withContext(Dispatchers.Main.immediate) {
                    failShare(intake, C07EntryRefusal.FAILED)
                }
            }
        }
    }

    fun openNotesFromShare() {
        navigationState.value = C07EntryNavigation.OpenNotes
        shareUiState.value = null
        resumeDeferredSetup()
    }

    /**
     * The ONLY package destination. It hands the single already-admitted
     * package URI to the existing inspection/review owner. The entry flow never
     * inspects, remaps, restores or imports the archive itself, and nothing is
     * restored on arrival: the owner presents its own review first.
     */
    fun chooseReviewDestination(intakeID: String) {
        val intake = activeState.value ?: return
        val phase = shareUiState.value?.phase
        if (intake.id != intakeID ||
            (phase != EntrySharePhase.READY && phase != EntrySharePhase.FAILED)
        ) {
            return
        }
        if (activeJob?.isActive == true) {
            showNotice(EntryNoticeKind.BUSY)
            return
        }
        if (!intake.packageKind.isPackage) {
            publishShare(
                intake,
                EntrySharePhase.FAILED,
                error = EntryShareError.UNSUPPORTED,
                destination = EntryShareDestination.REVIEW,
            )
            return
        }
        when (reviewAvailability(intake)) {
            EntryReviewAvailability.AVAILABLE -> Unit
            EntryReviewAvailability.MISSING_OWNER -> {
                publishShare(
                    intake, EntrySharePhase.FAILED,
                    error = EntryShareError.REVIEW_UNAVAILABLE,
                    destination = EntryShareDestination.REVIEW,
                )
                return
            }
            EntryReviewAvailability.DIRECTORY_UNAVAILABLE -> {
                publishShare(
                    intake, EntrySharePhase.FAILED,
                    error = EntryShareError.FOLDER_UNAVAILABLE,
                    destination = EntryShareDestination.REVIEW,
                )
                return
            }
            EntryReviewAvailability.NOT_APPLICABLE -> {
                publishShare(
                    intake, EntrySharePhase.FAILED,
                    error = EntryShareError.UNSUPPORTED,
                    destination = EntryShareDestination.REVIEW,
                )
                return
            }
        }
        val owner = packageReviewOwner ?: return
        val item = intake.items.singleOrNull() ?: return
        val uri = item.uriString?.let { value -> runCatching { Uri.parse(value) }.getOrNull() }
            ?: return
        val lease = intake.leases.singleOrNull() ?: return
        publishShare(intake, EntrySharePhase.WORKING, destination = EntryShareDestination.REVIEW)
        val released = java.util.concurrent.atomic.AtomicBoolean(false)
        val releaseSource: () -> Unit = {
            if (released.compareAndSet(false, true)) runCatching { lease.release() }
        }
        val started = runCatching {
            owner.beginReview(uri, intake.packageKind, item.displayName) { releaseSource() }
        }.getOrDefault(false)
        if (!started) {
            // The owner did not take the source. Keep the intake lease so an
            // explicit retry is a real retry of the same admitted item; it is
            // released on discard, never by a timer.
            publishShare(
                intake,
                EntrySharePhase.FAILED,
                error = if (intake.packageKind == C07EntryPackageKind.CAD) {
                    EntryShareError.FOLDER_UNAVAILABLE
                } else {
                    EntryShareError.REVIEW_UNAVAILABLE
                },
                destination = EntryShareDestination.REVIEW,
            )
            return
        }
        // The review owner now owns the source reference; the entry lease is
        // transferred (removed before settle) and released by that owner.
        intake.leases.remove(lease)
        settle(intake, C07EntryJournalStatus.COMPLETED, clear = false)
        publishShare(
            intake,
            EntrySharePhase.COMPLETE,
            destination = EntryShareDestination.REVIEW,
            openReviewAvailable = packageReviewOwner?.settingsSectionKey != null,
        )
    }

    fun openReviewFromShare() {
        val key = packageReviewOwner?.settingsSectionKey ?: return
        settingsSectionState.value = key
        shareUiState.value = null
        resumeDeferredSetup()
    }

    fun dismissShare() {
        val phase = shareUiState.value?.phase
        if (phase == EntrySharePhase.COMPLETE) {
            shareUiState.value = null
            resumeDeferredSetup()
            return
        }
        discardIntake(showNotice = false)
    }

    fun discardIntake(showNotice: Boolean = true) {
        admissionGeneration.incrementAndGet()
        admissionJob?.cancel()
        admissionJob = null
        activeJob?.cancel()
        activeJob = null
        val intake = activeState.value
        if (intake != null) {
            settle(intake, C07EntryJournalStatus.DISCARDED, clear = true)
        } else {
            shareUiState.value = null
            pendingRawShare = null
        }
        if (showNotice) showNotice(EntryNoticeKind.DISCARDED)
        resumeDeferredSetup()
    }

    private fun failShare(intake: ActiveIntake, refusal: C07EntryRefusal) {
        if (refusal in terminalRefusals) {
            settle(intake, C07EntryJournalStatus.DISCARDED, clear = true)
            showNotice(noticeFor(refusal))
        } else {
            publishShare(
                intake,
                EntrySharePhase.FAILED,
                error = shareErrorFor(refusal),
                destination = shareUiState.value?.destination,
            )
        }
    }

    private fun publishShare(
        intake: ActiveIntake,
        phase: EntrySharePhase,
        destination: EntryShareDestination? = null,
        error: EntryShareError? = null,
        savedNotes: Int = 0,
        canOpenNotes: Boolean = false,
        openReviewAvailable: Boolean = false,
    ) {
        shareUiState.value = EntryShareUi(
            items = intake.items.map { item ->
                EntryShareItemUi(
                    displayName = item.displayName,
                    byteCount = item.declaredBytes.coerceAtLeast(0L),
                    isText = item.kind == C07EntryItemKind.TEXT,
                )
            },
            textPreview = intake.preview,
            phase = phase,
            destination = destination,
            error = error,
            savedNotes = savedNotes,
            canOpenNotes = canOpenNotes,
            totalCount = intake.items.size,
            intakeID = intake.id,
            canChooseTask = intake.canTask,
            canChooseNotes = intake.canNotes,
            reviewAvailability = reviewAvailability(intake),
            openReviewAvailable = openReviewAvailable,
        )
    }

    private fun reviewAvailability(intake: ActiveIntake): EntryReviewAvailability {
        val owner = packageReviewOwner
        return C07EntryDestinationGate.review(
            packageKind = intake.packageKind,
            ownerInstalled = owner != null,
            supportsDirectoryPackages = owner?.supportsDirectoryPackages == true,
        )
    }

    private fun settle(
        intake: ActiveIntake,
        status: C07EntryJournalStatus,
        clear: Boolean,
    ) {
        // Task staging acknowledges only after retaining its own source
        // references. Release this owner at the actual handoff, not a timer.
        intake.leases.forEach { runCatching { it.release() } }
        intakeStore.settle(intake.fingerprint, intake.id, status, now())
        if (activeState.value?.id == intake.id) activeState.value = null
        if (clear) shareUiState.value = null
        resumeDeferredSetup()
    }

    private fun resumeDeferredSetup() {
        if (!setupPendingOffer) return
        if (activeState.value != null || shareUiState.value != null) return
        setupPendingOffer = false
        maybeOfferInitialSetup()
    }

    /* ------------------------------ navigation ------------------------------ */

    private fun resolveTaskRoute(conversationID: String) {
        if (runtimeHost == null) {
            queueRoute(C07EntryRoute.Task(conversationID))
            return
        }
        if (linkJob?.isActive == true) {
            showNotice(EntryNoticeKind.BUSY)
            return
        }
        linkJob = scope.launch {
            val exists = withContext(io) { durableTaskExists(conversationID) }
            if (exists) {
                navigationState.value = C07EntryNavigation.OpenTask(conversationID)
            } else {
                showNotice(EntryNoticeKind.TASK_UNAVAILABLE)
            }
        }
    }

    private fun resolveScheduleRoute(scheduleID: String) {
        if (runtimeHost == null) {
            queueRoute(C07EntryRoute.Schedule(scheduleID))
            return
        }
        if (linkJob?.isActive == true) {
            showNotice(EntryNoticeKind.BUSY)
            return
        }
        linkJob = scope.launch {
            val exists = withContext(io) { durableScheduleExists(scheduleID) }
            if (exists) {
                scheduleFocusState.value = C07ScheduleFocus(
                    requestID = focusSequence.incrementAndGet(),
                    scheduleID = scheduleID,
                )
                navigationState.value = C07EntryNavigation.OpenSchedule(scheduleID)
            } else {
                showNotice(EntryNoticeKind.SCHEDULE_UNAVAILABLE)
            }
        }
    }

    private fun queueRoute(route: C07EntryRoute) {
        if (pendingRoutes.none { it == route }) pendingRoutes.addLast(route)
        while (pendingRoutes.size > 4) pendingRoutes.removeFirst()
    }

    private suspend fun durableTaskExists(conversationID: String): Boolean {
        val host = runtimeHost ?: return false
        val deferred = CompletableDeferred<Boolean>()
        host.trackOperation(
            request = HostCommandRequest(
                command = "conversation.get",
                scope = HostScope.ConversationLifecycle(conversationID),
                stateful = false,
                correlationID = host.commandClient.correlationID("entrytask"),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    val replyID = (root?.get("conversationID") as? JsonPrimitive)
                        ?.contentOrNull
                    deferred.complete(replyID?.equals(conversationID, ignoreCase = true) == true)
                }
                is HostOperationOutcome.Rejected -> deferred.complete(false)
                is HostOperationOutcome.Failed -> deferred.complete(false)
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> deferred.complete(false)
            }
        }
        return withTimeoutOrNull(12_000L) { deferred.await() } ?: false
    }

    private suspend fun durableScheduleExists(scheduleID: String): Boolean {
        val host = runtimeHost ?: return false
        val result = withTimeoutOrNull(20_000L) {
            TaskScheduleCommands(host).detail(scheduleID)
        } ?: return false
        return result is TaskScheduleResult.Ok
    }

    private fun admitQuestionTap(intent: Intent) {
        val conversationID = C07EntryIds.canonicalUuid(
            intent.getStringExtra(C07EntryNotification.EXTRA_CONVERSATION_ID),
        ) ?: return
        val requestID = C07EntryNotification.validQuestionId(
            intent.getStringExtra(C07EntryNotification.EXTRA_REQUEST_ID),
        ) ?: return
        if (!markRecent("question:$conversationID:$requestID")) return
        if (C07EntryNotification.validQuestionTextId(
                intent.getStringExtra(C07EntryNotification.EXTRA_QUESTION_ID),
            ) == null
        ) {
            return
        }
        resolveTaskRoute(conversationID)
    }

    private fun admitScheduleTap(intent: Intent) {
        val scheduleID = C07EntryIds.canonicalUuid(
            intent.getStringExtra(C07EntryNotification.EXTRA_SCHEDULE_ID),
        ) ?: return
        if (!markRecent("schedule:$scheduleID")) return
        resolveScheduleRoute(scheduleID)
    }

    /* ------------------------------ small helpers ------------------------------ */

    private class Meta(
        val displayName: String,
        val mimeType: String?,
        val byteCount: Long,
    )

    private fun cadPackageFormat(displayName: String): C07EntryFormat =
        C07SharePolicy.formatFor("application/vnd.floe.cad.package", displayName)
            ?: C07EntryFormat(
                "application/vnd.floe.cad.package",
                C07EntryContentClass.PACKAGE,
                setOf("floecad"),
                null,
                opaqueWhenUnrecognized = true,
                canTask = false,
                canNotes = false,
                packageKind = C07EntryPackageKind.CAD,
            )

    /**
     * A provider that reports no size is measured once, bounded at the same
     * per-item cap, so the intake total remains a real bound instead of an
     * unbounded promise. The destination still re-opens and re-counts bytes.
     */
    private fun measureBytes(uri: Uri): Long {
        val input = try {
            appContext.contentResolver.openInputStream(uri)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: SecurityException) {
            throw C07EntryImportException(C07EntryRefusal.GRANT_REVOKED, error)
        } catch (error: Throwable) {
            throw C07EntryImportException(C07EntryRefusal.UNREADABLE, error)
        } ?: throw C07EntryImportException(C07EntryRefusal.UNREADABLE)
        input.use { stream ->
            var total = 0L
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = try {
                    stream.read(buffer)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    throw C07EntryImportException(C07EntryRefusal.UNREADABLE, error)
                }
                if (read < 0) break
                if (read == 0) continue
                total += read
                if (total > ENTRY_MAX_ITEM_BYTES) {
                    throw C07EntryImportException(C07EntryRefusal.TOO_LARGE)
                }
            }
            if (total <= 0L) throw C07EntryImportException(C07EntryRefusal.EMPTY)
            return total
        }
    }

    private fun queryMeta(uri: Uri): Meta {
        var displayName: String? = null
        var byteCount = -1L
        try {
            appContext.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        displayName = cursor.getString(nameIndex)
                    }
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        byteCount = cursor.getLong(sizeIndex)
                    }
                }
            }
        } catch (_: SecurityException) {
            // The stream open below produces the honest grant refusal.
        } catch (_: RuntimeException) {
            // Metadata is only a hint; the stream probe is authoritative.
        }
        val mimeType = try {
            appContext.contentResolver.getType(uri)
        } catch (_: SecurityException) {
            null
        } catch (_: RuntimeException) {
            null
        }
        return Meta(
            displayName = C07SharePolicy.sanitizeDisplayName(
                displayName ?: uri.lastPathSegment,
            ),
            mimeType = mimeType,
            byteCount = byteCount,
        )
    }

    private fun notesService(): NotesService? {
        notes?.let { return it }
        val service = runCatching {
            (appContext as? FloeApplication)?.notesHost?.service
        }.getOrNull()
        notes = service
        return service
    }

    /** Bounded in-process replay guard for a cold/warm Activity redelivery.
     * Rotation must not replay a link/notification route and yank the person
     * away from a newer surface. A deliberate repeat after 30s still works. */
    private fun markRecent(key: String): Boolean =
        replayGuard.admit(key, android.os.SystemClock.elapsedRealtime())

    private fun showNotice(kind: EntryNoticeKind) {
        noticeState.value = kind
        noticeJob?.cancel()
        noticeJob = scope.launch {
            delay(5_000L)
            noticeState.compareAndSet(kind, null)
        }
    }

    private fun rawPreview(raw: C07RawShare): String? =
        raw.text?.take(4_096)
            ?.split(Regex("\\s+"))
            ?.filter { it.isNotEmpty() }
            ?.joinToString(" ")
            ?.take(200)
            ?.takeIf { it.isNotBlank() }

    private fun now(): Long = System.currentTimeMillis()

    private val terminalRefusals = setOf(
        C07EntryRefusal.EMPTY,
        C07EntryRefusal.STALE,
        C07EntryRefusal.GRANT_REVOKED,
        C07EntryRefusal.TOO_LARGE,
        C07EntryRefusal.TEXT_TOO_LARGE,
        C07EntryRefusal.ITEM_TOO_LARGE,
        C07EntryRefusal.ITEM_LIMIT,
        C07EntryRefusal.TOTAL_TOO_LARGE,
        C07EntryRefusal.UNSUPPORTED,
        C07EntryRefusal.CONTENT_MISMATCH,
        C07EntryRefusal.PACKAGE_MIXED,
        C07EntryRefusal.INVALID_URI,
    )

    private fun shareErrorFor(refusal: C07EntryRefusal): EntryShareError = when (refusal) {
        C07EntryRefusal.BUSY -> EntryShareError.BUSY
        C07EntryRefusal.STALE -> EntryShareError.STALE
        C07EntryRefusal.GRANT_REVOKED -> EntryShareError.GRANT_REVOKED
        C07EntryRefusal.TOO_LARGE,
        C07EntryRefusal.TEXT_TOO_LARGE,
        C07EntryRefusal.ITEM_TOO_LARGE,
        C07EntryRefusal.ITEM_LIMIT,
        C07EntryRefusal.TOTAL_TOO_LARGE -> EntryShareError.TOO_LARGE
        C07EntryRefusal.UNSUPPORTED,
        C07EntryRefusal.CONTENT_MISMATCH -> EntryShareError.UNSUPPORTED
        C07EntryRefusal.PACKAGE_MIXED -> EntryShareError.PACKAGE_MIXED
        C07EntryRefusal.UNREADABLE,
        C07EntryRefusal.INVALID_URI -> EntryShareError.UNREADABLE
        C07EntryRefusal.NOTES_UNAVAILABLE -> EntryShareError.NOTES_UNAVAILABLE
        C07EntryRefusal.STAGING_UNAVAILABLE -> EntryShareError.STAGING_UNAVAILABLE
        else -> EntryShareError.FAILED
    }

    private fun noticeFor(refusal: C07EntryRefusal): EntryNoticeKind = when (refusal) {
        C07EntryRefusal.BUSY -> EntryNoticeKind.BUSY
        C07EntryRefusal.STALE -> EntryNoticeKind.SHARE_UNAVAILABLE
        C07EntryRefusal.GRANT_REVOKED -> EntryNoticeKind.GRANT_REVOKED
        C07EntryRefusal.TOO_LARGE,
        C07EntryRefusal.TEXT_TOO_LARGE,
        C07EntryRefusal.ITEM_TOO_LARGE,
        C07EntryRefusal.TOTAL_TOO_LARGE -> EntryNoticeKind.TOO_LARGE
        C07EntryRefusal.ITEM_LIMIT -> EntryNoticeKind.ITEM_LIMIT
        C07EntryRefusal.UNSUPPORTED -> EntryNoticeKind.UNSUPPORTED
        C07EntryRefusal.CONTENT_MISMATCH -> EntryNoticeKind.CONTENT_MISMATCH
        C07EntryRefusal.PACKAGE_MIXED -> EntryNoticeKind.PACKAGE_MIXED
        C07EntryRefusal.UNREADABLE,
        C07EntryRefusal.INVALID_URI -> EntryNoticeKind.UNREADABLE
        C07EntryRefusal.NOTES_UNAVAILABLE -> EntryNoticeKind.NOTES_UNAVAILABLE
        C07EntryRefusal.STAGING_UNAVAILABLE -> EntryNoticeKind.STAGING_UNAVAILABLE
        C07EntryRefusal.EMPTY -> EntryNoticeKind.SHARE_UNAVAILABLE
        C07EntryRefusal.FAILED -> EntryNoticeKind.UNAVAILABLE
        C07EntryRefusal.POLICY_UNAVAILABLE -> EntryNoticeKind.UNAVAILABLE
        C07EntryRefusal.TARGET_UNAVAILABLE -> EntryNoticeKind.UNAVAILABLE
    }

    private class ActiveIntake(
        val id: String,
        val fingerprint: String,
        val rawSignature: String,
        val subject: String?,
        val items: List<C07EntryCapturedItem>,
        val preview: String?,
        /** Mutable only for the one explicit package review transfer; every
         * other destination keeps the leases until its own work settles. */
        val leases: MutableList<SafSharedGrantBroker.Lease>,
        val createdAt: Long,
        val canTask: Boolean,
        val canNotes: Boolean,
        val packageKind: C07EntryPackageKind,
    )
}
