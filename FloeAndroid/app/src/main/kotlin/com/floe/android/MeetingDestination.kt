// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.app.Activity
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeToolbarIconButton
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.FloeVerticalDivider
import com.floe.android.design.IconGlyph
import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingError
import com.floe.android.host.meeting.MeetingErrorCode
import com.floe.android.host.meeting.MeetingException
import com.floe.android.host.meeting.MeetingManager
import com.floe.android.host.meeting.MeetingMaterial
import com.floe.android.host.meeting.MeetingMaterialKind
import com.floe.android.host.meeting.MeetingMaterialStatus
import com.floe.android.host.meeting.MeetingPermissionState
import com.floe.android.host.meeting.MeetingPlayer
import com.floe.android.host.meeting.MeetingPlayerState
import com.floe.android.host.meeting.MeetingPlayerStatus
import com.floe.android.host.meeting.MeetingRecordingPhase
import com.floe.android.host.meeting.MeetingRecordingState
import com.floe.android.host.meeting.MeetingSummary
import com.floe.android.host.meeting.MeetingTranscriptionLastAttempt
import com.floe.android.host.meeting.MeetingTranscriptionLastAttemptPhase
import com.floe.android.host.meetingexchange.MeetingDocumentDestinationResult
import com.floe.android.host.meetingexchange.MeetingDocumentRequest
import com.floe.android.host.meetingexchange.MeetingDocumentWriteResult
import com.floe.android.host.meetingexchange.MeetingExchange
import com.floe.android.host.meetingexchange.MeetingExportFormat
import com.floe.android.host.meetingexchange.MeetingExportPreparationResult
import com.floe.android.host.meetingexchange.MeetingShareResult
import com.floe.android.host.meetingtranscription.MeetingTranscriptionCancelResult
import com.floe.android.host.meetingassistant.MeetingAssistantAction
import com.floe.android.host.meetingassistant.MeetingAssistantAvailability
import com.floe.android.host.meetingassistant.MeetingAssistantEntry
import com.floe.android.host.meetingassistant.MeetingAssistantEntryStatus
import com.floe.android.host.meetingassistant.MeetingAssistantFailure
import com.floe.android.host.meetingassistant.MeetingAssistantFailureCode
import com.floe.android.host.meetingassistant.MeetingAssistantHost
import com.floe.android.host.meetingassistant.MeetingAssistantState
import com.floe.android.host.meetingassistant.MeetingAssistantStore
import com.floe.android.host.meetingassistant.MeetingAssistantTurnPhase
import com.floe.android.host.meetingassistant.MeetingAssistantTurnView
import com.floe.android.host.meetingtranscription.MeetingTranscriptionCleanupFailure
import com.floe.android.host.meetingtranscription.MeetingTranscriptionFailure
import com.floe.android.host.meetingtranscription.MeetingTranscriptionFailureCode
import com.floe.android.host.meetingtranscription.MeetingTranscriptionManager
import com.floe.android.host.meetingtranscription.MeetingTranscriptionPhase
import com.floe.android.host.meetingtranscription.MeetingTranscriptionReadiness
import com.floe.android.host.meetingtranscription.MeetingTranscriptionStart
import com.floe.android.host.meetingtranscription.MeetingTranscriptionState
import com.floe.android.host.meetingtranscription.MeetingTranscriptionText
import io.github.robinpcrd.cupertino.CupertinoAlertDialog
import io.github.robinpcrd.cupertino.cancel
import io.github.robinpcrd.cupertino.default
import io.github.robinpcrd.cupertino.destructive
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.text.DateFormat
import java.util.Date
import kotlin.math.roundToInt

/**
 * Standalone Android meeting workspace for the Space entry.
 *
 * ```kotlin
 * MeetingDestination(
 *     manager = remember { MeetingManager(context) },
 *     compact = compact,
 *     showSidebarToggle = showSidebarToggle,
 *     onExpandSidebar = onExpandSidebar,
 *     onOpenDrawer = onOpenDrawer,
 *     onExit = onExit,
 * )
 *
 * The onExit callback returns from the Space meeting surface.
 * ```
 *
 * The page reads [MeetingManager.meetings]/[MeetingManager.ready] and the
 * process-wide [MeetingManager.recorder] state. Every mutation calls the
 * manager's suspend API; failures remain visible instead of being converted
 * into local success. Recording is owned by the foreground service, so this
 * composable never stops capture on disposal. Transcription is owned by a
 * process-scoped coordinator: page disposal, rotation or backgrounding never
 * cancels it, and only the explicit Cancel action asks the provider to stop.
 * Playback is owned by this page and is released when the page or material
 * changes.
 *
 * Phone windows show one pane (list or detail); tablet windows use a list /
 * detail split. [onExit] is the shell-owned return path and runs only after
 * the unsaved-notes and active-recording guards.
 */
@Composable
internal fun MeetingDestination(
    manager: MeetingManager,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val meetings by manager.meetings.collectAsState()
    val ready by manager.ready.collectAsState()
    val recorderState by manager.recorder.state.collectAsState()
    val permission by manager.permission.collectAsState()
    val scope = rememberCoroutineScope()
    val lifecycleOwner = LocalLifecycleOwner.current
    val applicationContext = LocalContext.current.applicationContext
    // Process-owned transcription. Constructing a second instance (page
    // recreation, rotation) reuses the same process coordinator and therefore
    // the same running attempt; this page never owns or cancels that job.
    val transcriptionManager = remember(applicationContext) {
        MeetingTranscriptionManager(
            context = applicationContext,
            currentEpoch = {
                (applicationContext as? FloeApplication)?.runtimeHost?.nativeRootEpoch()
            },
        )
    }
    val transcriptionState by transcriptionManager.state.collectAsState()
    val transcriptionCleanupFailure by transcriptionManager.cleanupFailure.collectAsState()
    val recordingPreferences = remember(applicationContext) {
        applicationContext.getSharedPreferences("meeting-recording", android.content.Context.MODE_PRIVATE)
    }
    var autoTranscribe by remember { mutableStateOf(recordingPreferences.getBoolean("auto-transcribe", false)) }
    val setAutoTranscription: (Boolean) -> Unit = { enabled ->
        autoTranscribe = enabled
        recordingPreferences.edit().putBoolean("auto-transcribe", enabled).apply()
        if (!enabled) transcriptionManager.clearRecordingFollowups()
    }
    // The meeting assistant is ONE process-owned adapter over the existing
    // text-only task/run surface. It never creates a provider client or a
    // second conversation store; a missing runtime simply hides the section
    // instead of rendering an unusable button.
    val assistantApplication = applicationContext as? FloeApplication
    val assistantRuntime = assistantApplication?.runtimeHost
    val assistantHost = remember(assistantApplication, assistantRuntime, manager) {
        val runtime = assistantRuntime
        val store = assistantApplication?.let {
            MeetingAssistantStore.instance(File(it.filesDir, "meeting-assistant"))
        }
        if (runtime != null && store != null) {
            MeetingAssistantHost(runtime, store, runtime.scope, runtime.ioDispatcher)
        } else {
            null
        }
    }
    DisposableEffect(assistantHost) { onDispose { assistantHost?.close() } }
    val assistantStateFlow = remember(assistantHost) {
        assistantHost?.state ?: MutableStateFlow(MeetingAssistantState())
    }
    val assistantRawState by assistantStateFlow.collectAsState()
    val assistantState = if (assistantHost != null) assistantRawState else null

    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var assistantDrainPending by remember(selectedId) { mutableStateOf(false) }
    var transcriptionMaterialId by rememberSaveable(selectedId) { mutableStateOf<String?>(null) }
    var assistantQuestion by rememberSaveable(selectedId) { mutableStateOf("") }
    var assistantAskOpen by rememberSaveable(selectedId) { mutableStateOf(false) }
    var listError by remember { mutableStateOf<MeetingError?>(null) }
    var listNoticeRes by remember { mutableStateOf<Int?>(null) }
    var refreshing by remember { mutableStateOf(false) }

    var createVisible by rememberSaveable { mutableStateOf(false) }
    var createTitle by rememberSaveable { mutableStateOf("") }
    var createBusy by remember { mutableStateOf(false) }
    var createError by remember { mutableStateOf<MeetingError?>(null) }

    var detail by remember(selectedId) { mutableStateOf<MeetingDetail?>(null) }
    var detailLoading by remember(selectedId) { mutableStateOf(selectedId != null) }
    var detailError by remember(selectedId) { mutableStateOf<MeetingError?>(null) }
    var detailNoticeRes by remember(selectedId) { mutableStateOf<Int?>(null) }
    var notesState by rememberSaveable(
        selectedId,
        stateSaver = MeetingNotesUiStateSaver,
    ) {
        mutableStateOf(MeetingNotesUiState())
    }
    var notesBusy by remember(selectedId) { mutableStateOf(false) }
    var notesError by remember(selectedId) { mutableStateOf<MeetingError?>(null) }
    var notesNoticeRes by remember(selectedId) { mutableStateOf<Int?>(null) }

    var recordBusy by remember(selectedId) { mutableStateOf(false) }
    var recordBusyLabelRes by remember(selectedId) { mutableStateOf<Int?>(null) }
    var recordError by remember(selectedId) { mutableStateOf<MeetingError?>(null) }
    var recordNoticeRes by remember(selectedId) { mutableStateOf<Int?>(null) }
    var recordRetainedTake by remember(selectedId) { mutableStateOf<MeetingMaterial?>(null) }
    var listRetainedTake by remember { mutableStateOf<MeetingMaterial?>(null) }

    var importBusy by remember(selectedId) { mutableStateOf(false) }
    var importError by remember(selectedId) { mutableStateOf<MeetingError?>(null) }
    var importNotice by remember(selectedId) { mutableStateOf<String?>(null) }

    var renameVisible by remember(selectedId) { mutableStateOf(false) }
    var renameTitle by remember(selectedId) { mutableStateOf("") }
    var renameBusy by remember(selectedId) { mutableStateOf(false) }
    var renameError by remember(selectedId) { mutableStateOf<MeetingError?>(null) }

    var deleteVisible by remember(selectedId) { mutableStateOf(false) }
    var deleteBusy by remember(selectedId) { mutableStateOf(false) }
    var deleteError by remember(selectedId) { mutableStateOf<MeetingError?>(null) }

    val pageContext = LocalContext.current
    // Export/share host over the SAME MeetingManager. It reads exactly one
    // explicit meeting on demand and writes only to the document the user
    // chose in the system picker; it owns no meeting storage of its own.
    val exchange = remember(applicationContext, manager) {
        MeetingExchange(applicationContext, manager)
    }
    DisposableEffect(exchange) { onDispose { exchange.close() } }
    var exportUi by remember(selectedId) { mutableStateOf(MeetingExportUiState()) }
    // Kept outside the meeting-keyed state until the picker returns: a late
    // result must still be rejected visibly instead of adopting the newly
    // selected meeting. The host checks identity again before any write.
    var exportRequest by remember { mutableStateOf<MeetingDocumentRequest?>(null) }
    val currentSelectedMeetingId by rememberUpdatedState(selectedId)

    // The raw system result Intent is passed through untouched so result.data
    // still carries the provider's returned flags; the host verifies the write
    // grant and destination itself. A cancelled result never becomes success.
    val documentLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val request = exportRequest
        exportRequest = null
        if (request == null) {
            // A configuration/process recreation can drop the prepared
            // snapshot while the system picker is open. Never invent one from
            // whatever meeting is selected now.
            if (result.resultCode == Activity.RESULT_OK && result.data?.dataString != null) {
                exportUi = MeetingExportUiState(
                    error = pageContext.getString(R.string.meeting_ui_export_request_lost),
                )
            }
            return@rememberLauncherForActivityResult
        }
        when (
            val accepted = exchange.acceptDocumentActivityResult(
                request = request,
                resultOk = result.resultCode == Activity.RESULT_OK,
                resultIntent = result.data,
                selectedMeetingId = currentSelectedMeetingId,
            )
        ) {
            is MeetingDocumentDestinationResult.Ready -> {
                val target = accepted.target
                exportUi = MeetingExportUiState(busy = true)
                scope.launch {
                    try {
                        val written = exchange.writeDocument(target, currentSelectedMeetingId)
                        if (
                            meetingExportBelongsToCurrentMeeting(
                                currentSelectedMeetingId,
                                target.meetingId,
                            )
                        ) {
                            exportUi = when (written) {
                                is MeetingDocumentWriteResult.Written -> MeetingExportUiState(
                                    notice = exchange.savedMessage(),
                                )
                                is MeetingDocumentWriteResult.Failed -> MeetingExportUiState(
                                    error = exchange.failureMessage(written.failure),
                                )
                            }
                        }
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                        if (
                            meetingExportBelongsToCurrentMeeting(
                                currentSelectedMeetingId,
                                target.meetingId,
                            )
                        ) {
                            exportUi = MeetingExportUiState(
                                error = pageContext.getString(R.string.meeting_ui_export_action_failed),
                            )
                        }
                    }
                }
            }
            MeetingDocumentDestinationResult.Cancelled -> {
                // The user backed out of the picker: no notice, never success.
                exportUi = MeetingExportUiState()
            }
            is MeetingDocumentDestinationResult.Rejected -> {
                exportUi = MeetingExportUiState(
                    error = exchange.failureMessage(accepted.failure),
                )
            }
        }
    }

    fun applyExportOutcome(meetingId: String, outcome: MeetingExportUiState) {
        exportUi = if (meetingExportBelongsToCurrentMeeting(currentSelectedMeetingId, meetingId)) {
            outcome
        } else {
            MeetingExportUiState()
        }
    }

    fun startDocumentExport(format: MeetingExportFormat) {
        val id = selectedId ?: return
        if (!meetingExportCanStart(exportUi.busy, id)) return
        exportUi = MeetingExportUiState(busy = true)
        exportRequest = null
        scope.launch {
            try {
                when (val prepared = exchange.prepare(id, format)) {
                    is MeetingExportPreparationResult.Ready -> {
                        if (!meetingExportBelongsToCurrentMeeting(currentSelectedMeetingId, id)) {
                            exportUi = MeetingExportUiState()
                            return@launch
                        }
                        val request = exchange.documentRequest(prepared.document)
                        exportRequest = request
                        try {
                            documentLauncher.launch(exchange.createDocumentIntent(request))
                        } catch (_: Exception) {
                            // No picker activity, or the launch was refused.
                            exportRequest = null
                            applyExportOutcome(
                                id,
                                MeetingExportUiState(
                                    error = pageContext.getString(
                                        R.string.meeting_ui_export_picker_unavailable,
                                    ),
                                ),
                            )
                        }
                    }
                    is MeetingExportPreparationResult.Failed -> {
                        applyExportOutcome(
                            id,
                            MeetingExportUiState(
                                error = exchange.failureMessage(prepared.failure),
                            ),
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                applyExportOutcome(
                    id,
                    MeetingExportUiState(
                        error = pageContext.getString(R.string.meeting_ui_export_action_failed),
                    ),
                )
            }
        }
    }

    fun shareCurrentMeetingText() {
        val id = selectedId ?: return
        if (!meetingExportCanStart(exportUi.busy, id)) return
        exportUi = MeetingExportUiState(busy = true)
        exportRequest = null
        scope.launch {
            try {
                when (val prepared = exchange.prepare(id, MeetingExportFormat.TXT)) {
                    is MeetingExportPreparationResult.Ready -> {
                        if (!meetingExportBelongsToCurrentMeeting(currentSelectedMeetingId, id)) {
                            exportUi = MeetingExportUiState()
                            return@launch
                        }
                        when (val shared = exchange.shareText(prepared.document, pageContext)) {
                            MeetingShareResult.ChooserOpened -> applyExportOutcome(
                                id,
                                MeetingExportUiState(notice = exchange.shareOpenedMessage()),
                            )
                            is MeetingShareResult.Failed -> applyExportOutcome(
                                id,
                                MeetingExportUiState(
                                    error = exchange.failureMessage(shared.failure),
                                ),
                            )
                        }
                    }
                    is MeetingExportPreparationResult.Failed -> {
                        applyExportOutcome(
                            id,
                            MeetingExportUiState(
                                error = exchange.failureMessage(prepared.failure),
                            ),
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                applyExportOutcome(
                    id,
                    MeetingExportUiState(
                        error = pageContext.getString(
                            R.string.meeting_ui_export_share_action_failed,
                        ),
                    ),
                )
            }
        }
    }

    LaunchedEffect(assistantHost, selectedId) {
        assistantHost?.selectMeeting(selectedId)
    }
    var pendingNotesLeave by remember { mutableStateOf<MeetingLeaveTarget?>(null) }
    var pendingRecordingLeave by remember { mutableStateOf<MeetingLeaveTarget?>(null) }
    var stoppingToLeave by remember { mutableStateOf(false) }
    var permissionStartMeetingId by remember { mutableStateOf<String?>(null) }

    val selectedSummary = meetings.firstOrNull { it.id == selectedId }
    val recordingMeetingTitle = recorderState.meetingId?.let { activeId ->
        meetings.firstOrNull { it.id == activeId }?.title
    }
    val transcriptionMeetingTitle = transcriptionState.session?.meetingId?.let { activeId ->
        meetings.firstOrNull { it.id == activeId }?.title
    }

    suspend fun loadDetail(id: String) {
        try {
            val loaded = manager.meeting(id)
            if (selectedId != id) return
            detail = loaded
            detailError = null
            notesState = notesState.afterLoad(loaded.notes, loaded.notesRevision)
        } catch (error: MeetingException) {
            if (selectedId == id) detailError = error.error
        }
    }

    suspend fun refreshCatalogQuietly() {
        try {
            manager.refresh()
        } catch (_: MeetingException) {
            // The durable state is authoritative; a failed catalog rescan
            // must not turn a completed mutation into a fake failure.
        }
    }

    fun commitNotes(
        draft: String,
        successNoticeRes: Int,
        conflictNoticeRes: Int? = null,
        onSaved: (() -> Unit)? = null,
    ) {
        val id = selectedId ?: return
        if (notesBusy) return
        // Capture the EXACT meeting revision at the action boundary. A later
        // meeting switch must never pair this meeting id with another
        // meeting's editor revision.
        val expectedRevision = notesState.revision
        notesBusy = true
        notesError = null
        notesNoticeRes = null
        scope.launch {
            try {
                val saved = manager.updateNotes(id, draft, expectedRevision)
                if (selectedId != id) return@launch
                detail = saved
                notesState = notesState.afterSave(saved.notes, saved.notesRevision)
                notesNoticeRes = successNoticeRes
                refreshCatalogQuietly()
                onSaved?.invoke()
            } catch (error: MeetingException) {
                if (selectedId != id) return@launch
                if (error.code == MeetingErrorCode.CONFLICT) {
                    // The proposed text stays recoverable in BOTH paths: the
                    // normal save restores the user's draft, and an assistant
                    // insert restores the exact would-be notes so nothing is
                    // silently lost when another editor won the revision.
                    notesState = notesState.copy(
                        conflict = true,
                        recovery = notesState.recovery ?: draft,
                    )
                    try {
                        val latest = manager.meeting(id)
                        if (selectedId != id) return@launch
                        detail = latest
                        notesState = notesState.afterConflict(latest.notes, latest.notesRevision)
                        if (conflictNoticeRes != null) notesNoticeRes = conflictNoticeRes
                    } catch (fetchError: MeetingException) {
                        if (selectedId == id) notesError = fetchError.error
                    }
                } else {
                    notesError = error.error
                }
            } catch (error: CancellationException) {
                throw error
            } finally {
                if (selectedId == id) notesBusy = false
            }
        }
    }

    fun saveNotes(onSaved: (() -> Unit)? = null) {
        if (notesBusy || !notesState.canSave) return
        commitNotes(
            draft = notesState.draft,
            successNoticeRes = R.string.meeting_ui_notes_saved_notice,
            onSaved = onSaved,
        )
    }

    /**
     * Explicit user action: append one complete assistant answer to the real
     * notes with the existing notes-revision CAS. A dirty/conflicted editor is
     * never overwritten; it must be saved or resolved first.
     */
    fun insertAssistantAnswer(text: String, heading: String) {
        val id = selectedId ?: return
        if (!meetingAssistantCanInsertNotes(
                notesDirty = notesState.dirty,
                notesConflict = notesState.conflict,
                notesBusy = notesBusy,
            )
        ) {
            return
        }
        val current = detail ?: return
        if (current.id != id) return
        val combined = meetingAssistantAppendText(current.notes, heading, text)
        if (combined == current.notes) return
        commitNotes(
            draft = combined,
            successNoticeRes = R.string.meeting_ui_assistant_inserted,
            conflictNoticeRes = R.string.meeting_ui_assistant_insert_conflict,
        )
    }

    fun reloadLatestNotes() {
        val id = selectedId ?: return
        if (notesBusy) return
        notesBusy = true
        notesError = null
        notesNoticeRes = null
        scope.launch {
            try {
                val latest = manager.meeting(id)
                if (selectedId != id) return@launch
                detail = latest
                notesState = notesState.reloadLatest(latest.notes, latest.notesRevision)
                notesNoticeRes = R.string.meeting_ui_notes_reloaded
                refreshCatalogQuietly()
            } catch (error: MeetingException) {
                if (selectedId == id) notesError = error.error
            } catch (error: CancellationException) {
                throw error
            } finally {
                if (selectedId == id) notesBusy = false
            }
        }
    }

    fun restoreMyNotes() {
        val id = selectedId ?: return
        if (notesBusy) return
        notesBusy = true
        notesError = null
        notesNoticeRes = null
        scope.launch {
            try {
                val latest = manager.meeting(id)
                if (selectedId != id) return@launch
                detail = latest
                notesState = notesState.restore(latest.notes, latest.notesRevision)
                notesNoticeRes = R.string.meeting_ui_notes_restored
                refreshCatalogQuietly()
            } catch (error: MeetingException) {
                if (selectedId == id) notesError = error.error
            } catch (error: CancellationException) {
                throw error
            } finally {
                if (selectedId == id) notesBusy = false
            }
        }
    }

    fun performRecordAction(
        id: String,
        busyLabelRes: Int,
        successRes: Int,
        action: suspend () -> Unit,
    ) {
        if (recordBusy) return
        recordBusy = true
        recordBusyLabelRes = busyLabelRes
        recordError = null
        recordNoticeRes = null
        recordRetainedTake = null
        listRetainedTake = null
        scope.launch {
            try {
                action()
                if (selectedId == id) {
                    recordNoticeRes = successRes
                    loadDetail(id)
                }
                refreshCatalogQuietly()
            } catch (error: MeetingException) {
                if (selectedId == id) recordError = error.error
            } catch (error: CancellationException) {
                throw error
            } finally {
                if (selectedId == id) {
                    recordBusy = false
                    recordBusyLabelRes = null
                }
            }
        }
    }

    fun performStopRecording(id: String) {
        if (recordBusy) return
        recordBusy = true
        recordBusyLabelRes = R.string.meeting_ui_record_stopping
        recordError = null
        recordNoticeRes = null
        recordRetainedTake = null
        listRetainedTake = null
        scope.launch {
            try {
                val material = manager.recorder.stop()
                if (autoTranscribe) transcriptionManager.recordingStopped(material)
                if (selectedId == id) {
                    if (meetingStopSucceeded(material.status, material.isPlayable)) {
                        recordNoticeRes = R.string.meeting_ui_record_stopped
                    } else {
                        recordRetainedTake = material
                    }
                    loadDetail(id)
                } else if (selectedId == null && !meetingStopSucceeded(material.status, material.isPlayable)) {
                    listRetainedTake = material
                }
                refreshCatalogQuietly()
            } catch (error: MeetingException) {
                if (selectedId == id) {
                    recordError = error.error
                } else if (selectedId == null) {
                    listError = error.error
                }
            } catch (error: CancellationException) {
                throw error
            } finally {
                if (selectedId == id) {
                    recordBusy = false
                    recordBusyLabelRes = null
                }
            }
        }
    }

    fun performStartRecording(id: String) {
        performRecordAction(
            id = id,
            busyLabelRes = R.string.meeting_ui_record_starting,
            successRes = R.string.meeting_ui_record_started,
        ) {
            manager.recorder.start(id)
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { _ ->
        manager.refreshPermissionState()
        val pendingId = permissionStartMeetingId
        permissionStartMeetingId = null
        if (pendingId != null) {
            if (manager.permission.value.microphoneGranted) {
                performStartRecording(pendingId)
            } else if (selectedId == pendingId) {
                recordError = MeetingError(
                    code = MeetingErrorCode.PERMISSION_REQUIRED,
                    message = "Microphone permission is required.",
                    retryable = true,
                )
            }
        }
    }

    fun startRecording(id: String) {
        if (manager.permission.value.microphoneGranted) {
            performStartRecording(id)
        } else {
            permissionStartMeetingId = id
            permissionLauncher.launch(manager.requiredPermissions().toTypedArray())
        }
    }

    fun grantMicrophone() {
        permissionStartMeetingId = null
        permissionLauncher.launch(manager.requiredPermissions().toTypedArray())
    }

    /**
     * Runs one assistant action for the selected meeting. Minutes and to-dos
     * are final material: while this meeting's transcription is still running
     * they wait for the terminal receipt and then read the refreshed detail,
     * so a late transcript is folded into the next minutes instead of being
     * suppressed by an earlier interim summary.
     */
    fun sendAssistantAction(action: MeetingAssistantAction, question: String) {
        val id = selectedId ?: return
        val host = assistantHost ?: return
        if (action == MeetingAssistantAction.ASK ||
            !transcriptionManager.awaitingFinalTranscript(id)
        ) {
            host.send(id, action, question) { meetingId -> manager.meeting(meetingId) }
            return
        }
        if (assistantDrainPending) return
        assistantDrainPending = true
        val initialRevision = detail?.transcription?.revision ?: 0L
        scope.launch {
            try {
                transcriptionManager.awaitFinalTranscript(id)
                if (selectedId != id) return@launch
                loadDetail(id)
                if ((detail?.transcription?.revision ?: 0L) <= initialRevision) return@launch
                host.send(id, action, question) { meetingId -> manager.meeting(meetingId) }
            } catch (error: CancellationException) {
                throw error
            } finally {
                if (selectedId == id) assistantDrainPending = false
            }
        }
    }

    fun importMedia(id: String, uri: Uri) {
        if (importBusy) return
        importBusy = true
        importError = null
        importNotice = null
        scope.launch {
            try {
                val material = manager.importMedia(id, uri)
                if (selectedId == id) {
                    importNotice = material.displayName
                    loadDetail(id)
                }
                refreshCatalogQuietly()
            } catch (error: MeetingException) {
                if (selectedId == id) importError = error.error
            } catch (error: CancellationException) {
                throw error
            } finally {
                if (selectedId == id) importBusy = false
            }
        }
    }

    fun openRenameDialog() {
        renameTitle = detail?.title.orEmpty()
        renameError = null
        renameVisible = true
    }

    fun submitRename() {
        val id = selectedId ?: return
        if (renameBusy || renameTitle.isBlank()) return
        renameBusy = true
        renameError = null
        scope.launch {
            try {
                val updated = manager.renameMeeting(id, renameTitle)
                if (selectedId == id) {
                    detail = updated
                    renameVisible = false
                    detailNoticeRes = R.string.meeting_ui_renamed
                }
                refreshCatalogQuietly()
            } catch (error: MeetingException) {
                if (selectedId == id) renameError = error.error
            } catch (error: CancellationException) {
                throw error
            } finally {
                if (selectedId == id) renameBusy = false
            }
        }
    }

    fun submitDelete() {
        val id = selectedId ?: return
        if (deleteBusy) return
        deleteVisible = false
        deleteBusy = true
        deleteError = null
        scope.launch {
            try {
                manager.deleteMeeting(id)
                // The meeting is really gone. Clean up exactly this meeting's
                // assistant binding/history and detach its in-flight
                // callbacks so a late one can never rebuild it. The native
                // conversation/task stays an ordinary independent task and
                // is never touched here.
                val assistantCleared = runCatching {
                    assistantHost?.onMeetingDeleted(id) ?: true
                }.getOrDefault(false)
                // A deleted meeting can never be rebuilt by a late follow-up.
                transcriptionManager.dropRecordingFollowup(id)
                if (selectedId == id) selectedId = null
                listRetainedTake = null
                // A failed assistant cleanup is reported instead of a plain
                // success notice; the history is preserved on the device.
                listNoticeRes = if (assistantCleared) {
                    R.string.meeting_ui_deleted
                } else {
                    R.string.meeting_ui_deleted_assistant_cleanup_failed
                }
                refreshCatalogQuietly()
            } catch (error: MeetingException) {
                if (selectedId == id) deleteError = error.error else listError = error.error
            } catch (error: CancellationException) {
                throw error
            } finally {
                if (selectedId == id) deleteBusy = false
            }
        }
    }

    fun finishNavigation(target: MeetingLeaveTarget) {
        pendingNotesLeave = null
        pendingRecordingLeave = null
        listNoticeRes = null
        listRetainedTake = null
        when (target) {
            MeetingLeaveTarget.Page -> onExit()
            MeetingLeaveTarget.ClearSelection -> selectedId = null
            is MeetingLeaveTarget.Select -> selectedId = target.id
        }
    }

    fun continueNavigation(target: MeetingLeaveTarget) {
        val leavingMeetingId = when (target) {
            MeetingLeaveTarget.Page -> null
            MeetingLeaveTarget.ClearSelection -> selectedId
            is MeetingLeaveTarget.Select -> if (target.id == selectedId) null else selectedId
        }
        val needsRecordingPrompt = meetingLeaveNeedsRecordingPrompt(
            phase = recorderState.phase,
            activeMeetingId = recorderState.meetingId,
            leavingMeetingId = leavingMeetingId,
            leavingPage = target is MeetingLeaveTarget.Page,
        )
        if (needsRecordingPrompt) {
            pendingRecordingLeave = target
        } else {
            finishNavigation(target)
        }
    }

    fun requestNavigation(target: MeetingLeaveTarget) {
        if (notesState.dirty || notesState.conflict) {
            pendingNotesLeave = target
        } else {
            continueNavigation(target)
        }
    }

    fun submitCreateMeeting() {
        if (createBusy) return
        createBusy = true
        createError = null
        scope.launch {
            try {
                val created = manager.createMeeting(createTitle)
                createVisible = false
                createTitle = ""
                refreshCatalogQuietly()
                requestNavigation(MeetingLeaveTarget.Select(created.id))
            } catch (error: MeetingException) {
                createError = error.error
            } catch (error: CancellationException) {
                throw error
            } finally {
                createBusy = false
            }
        }
    }

    fun stopRecordingAndLeave() {
        val target = pendingRecordingLeave ?: return
        if (stoppingToLeave) return
        stoppingToLeave = true
        recordError = null
        recordNoticeRes = null
        recordRetainedTake = null
        listRetainedTake = null
        scope.launch {
            try {
                val material = manager.recorder.stop()
                pendingRecordingLeave = null
                stoppingToLeave = false
                refreshCatalogQuietly()
                if (meetingStopSucceeded(material.status, material.isPlayable)) {
                    if (autoTranscribe) transcriptionManager.recordingStopped(material)
                    finishNavigation(target)
                } else if (selectedId == null) {
                    // The stop left retained bytes. Stay on the list so the
                    // user sees the outcome and decides when to leave.
                    listRetainedTake = material
                } else {
                    // Stay on the meeting detail for the same reason.
                    recordRetainedTake = material
                }
            } catch (error: MeetingException) {
                stoppingToLeave = false
                pendingRecordingLeave = null
                if (selectedId == null) {
                    listError = error.error
                } else {
                    recordError = error.error
                }
            } catch (error: CancellationException) {
                throw error
            }
        }
    }

    LaunchedEffect(manager) {
        manager.refreshPermissionState()
        try {
            manager.refresh()
            listError = null
        } catch (error: MeetingException) {
            listError = error.error
        }
    }

    DisposableEffect(lifecycleOwner, manager) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) manager.refreshPermissionState()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(selectedId, selectedSummary?.revision) {
        val id = selectedId ?: return@LaunchedEffect
        if (detail == null) detailLoading = true
        detailError = null
        try {
            loadDetail(id)
        } finally {
            if (selectedId == id) detailLoading = false
        }
    }

    LaunchedEffect(selectedId, detail?.revision, detail?.transcription?.materialId) {
        val loaded = detail ?: return@LaunchedEffect
        if (selectedId != loaded.id) return@LaunchedEffect
        val resolved = meetingTranscriptionDefaultMaterial(loaded, transcriptionMaterialId)
        if (resolved != transcriptionMaterialId) transcriptionMaterialId = resolved
    }

    // The process-owned attempt may finish while this page is open, or while
    // the user is elsewhere. On re-entry this reads the same durable meeting
    // record again; it never displays a synthetic transcript from state alone.
    LaunchedEffect(
        selectedId,
        transcriptionState.phase,
        transcriptionState.receipt?.transcriptionRevision,
        transcriptionState.session?.meetingId,
        transcriptionState.session?.materialId,
    ) {
        val id = selectedId ?: return@LaunchedEffect
        val session = transcriptionState.session ?: return@LaunchedEffect
        if (session.meetingId != id) return@LaunchedEffect
        if (transcriptionState.phase != MeetingTranscriptionPhase.COMPLETED) return@LaunchedEffect
        if (transcriptionState.receipt == null) return@LaunchedEffect
        transcriptionMaterialId = session.materialId
        loadDetail(id)
        refreshCatalogQuietly()
    }

    ImeFirstBackHandler {
        if (selectedId != null) {
            requestNavigation(MeetingLeaveTarget.ClearSelection)
        } else {
            requestNavigation(MeetingLeaveTarget.Page)
        }
    }

    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface),
    ) {
        val twoPane = !compact && maxWidth >= 600.dp
        if (twoPane) {
            val listWidth = (maxWidth.value * 0.32f).coerceIn(280f, 380f).dp
            Row(Modifier.fillMaxSize()) {
                Box(Modifier.width(listWidth).fillMaxHeight()) {
                    MeetingListPane(
                        meetings = meetings,
                        ready = ready,
                        selectedId = selectedId,
                        recorderState = recorderState,
                        listError = listError,
                        listNoticeRes = listNoticeRes,
                        listRetainedTake = listRetainedTake,
                        refreshing = refreshing,
                        compact = compact,
                        showSidebarToggle = showSidebarToggle,
                        onExpandSidebar = onExpandSidebar,
                        onOpenDrawer = onOpenDrawer,
                        onExitPage = { requestNavigation(MeetingLeaveTarget.Page) },
                        onSelect = { requestNavigation(MeetingLeaveTarget.Select(it)) },
                        onCreate = {
                            createTitle = ""
                            createError = null
                            createVisible = true
                        },
                        onRefresh = {
                            if (!refreshing) {
                                refreshing = true
                                scope.launch {
                                    try {
                                        manager.refresh()
                                        listError = null
                                    } catch (error: MeetingException) {
                                        listError = error.error
                                    } finally {
                                        refreshing = false
                                    }
                                }
                            }
                        },
                        onOpenRecordingMeeting = { id ->
                            requestNavigation(MeetingLeaveTarget.Select(id))
                        },
                    )
                }
                FloeVerticalDivider()
                Box(Modifier.weight(1f).fillMaxHeight()) {
                    if (selectedId == null) {
                        MeetingSelectPlaceholder()
                    } else {
                        MeetingDetailHost(
                            manager = manager,
                            meetingId = selectedId.orEmpty(),
                            summary = selectedSummary,
                            detail = detail,
                            loading = detailLoading,
                            loadError = detailError,
                            notesState = notesState,
                            notesBusy = notesBusy,
                            notesError = notesError,
                            notesNoticeRes = notesNoticeRes,
                            detailNoticeRes = detailNoticeRes,
                            exportState = exportUi,
                            onExportFormat = { startDocumentExport(it) },
                            onExportShareText = { shareCurrentMeetingText() },
                            recorderState = recorderState,
                            recordingMeetingTitle = recordingMeetingTitle,
                            permission = permission,
                            recordBusy = recordBusy,
                            recordBusyLabelRes = recordBusyLabelRes,
                            recordError = recordError,
                            recordNoticeRes = recordNoticeRes,
                            recordRetainedTake = recordRetainedTake,
                            autoTranscribe = autoTranscribe,
                            onAutoTranscribeChange = setAutoTranscription,
                            importBusy = importBusy,
                            importError = importError,
                            importNotice = importNotice,
                            deleteBusy = deleteBusy,
                            deleteError = deleteError,
                            transcriptionManager = transcriptionManager,
                            transcriptionState = transcriptionState,
                            transcriptionCleanupFailure = transcriptionCleanupFailure,
                            transcriptionMaterialId = transcriptionMaterialId,
                            transcriptionMeetingTitle = transcriptionMeetingTitle,
                            onTranscriptionMaterialSelected = { transcriptionMaterialId = it },
                            assistantState = assistantState,
                            assistantQuestion = assistantQuestion,
                            assistantAskOpen = assistantAskOpen,
                            assistantCanInsertNotes = meetingAssistantCanInsertNotes(
                                notesDirty = notesState.dirty,
                                notesConflict = notesState.conflict,
                                notesBusy = notesBusy,
                            ),
                            assistantNotesUnsaved = notesState.dirty,
                            assistantAwaitingTranscription = assistantDrainPending,
                            onAssistantQuestionChange = { assistantQuestion = it },
                            onAssistantAskOpenChange = { assistantAskOpen = it },
                            onAssistantSend = { action, question ->
                                sendAssistantAction(action, question)
                            },
                            onAssistantCancel = { selectedId?.let { assistantHost?.cancel(it) } },
                            onAssistantCheckActive = {
                                selectedId?.let { assistantHost?.checkActive(it) }
                            },
                            onAssistantCheckAgain = { entryId ->
                                selectedId?.let { assistantHost?.checkAgain(it, entryId) }
                            },
                            onAssistantSelectModel = { modelId ->
                                selectedId?.let { assistantHost?.selectModel(modelId) }
                            },
                            onAssistantRefresh = { assistantHost?.refresh() },
                            onAssistantInsert = { text, heading ->
                                insertAssistantAnswer(text, heading)
                            },
                            twoPane = true,
                            onBack = { requestNavigation(MeetingLeaveTarget.ClearSelection) },
                            onRefresh = {
                                scope.launch {
                                    if (selectedId != null) {
                                        detailLoading = true
                                        loadDetail(selectedId.orEmpty())
                                        detailLoading = false
                                    }
                                }
                            },
                            onNotesChange = { value ->
                                notesState = notesState.edited(value)
                                notesNoticeRes = null
                            },
                            onSaveNotes = { saveNotes() },
                            onReloadNotes = { reloadLatestNotes() },
                            onRestoreNotes = { restoreMyNotes() },
                            onStartRecording = {
                                if (selectedId != null) startRecording(selectedId.orEmpty())
                            },
                            onPauseRecording = {
                                if (selectedId != null) {
                                    performRecordAction(
                                        id = selectedId.orEmpty(),
                                        busyLabelRes = R.string.meeting_ui_record_pausing,
                                        successRes = R.string.meeting_ui_record_paused,
                                    ) { manager.recorder.pause() }
                                }
                            },
                            onResumeRecording = {
                                if (selectedId != null) {
                                    performRecordAction(
                                        id = selectedId.orEmpty(),
                                        busyLabelRes = R.string.meeting_ui_record_resuming,
                                        successRes = R.string.meeting_ui_record_resumed,
                                    ) { manager.recorder.resume() }
                                }
                            },
                            onStopRecording = {
                                if (selectedId != null) {
                                    performStopRecording(selectedId.orEmpty())
                                }
                            },
                            onGrantMicrophone = { grantMicrophone() },
                            onImport = { uri ->
                                if (selectedId != null) importMedia(selectedId.orEmpty(), uri)
                            },
                            onRename = { openRenameDialog() },
                            onDelete = {
                                deleteError = null
                                deleteVisible = true
                            },
                            onOpenOtherMeeting = { id ->
                                requestNavigation(MeetingLeaveTarget.Select(id))
                            },
                        )
                    }
                }
            }
        } else if (selectedId == null) {
            MeetingListPane(
                meetings = meetings,
                ready = ready,
                selectedId = selectedId,
                recorderState = recorderState,
                listError = listError,
                listNoticeRes = listNoticeRes,
                listRetainedTake = listRetainedTake,
                refreshing = refreshing,
                compact = compact,
                showSidebarToggle = showSidebarToggle,
                onExpandSidebar = onExpandSidebar,
                onOpenDrawer = onOpenDrawer,
                onExitPage = { requestNavigation(MeetingLeaveTarget.Page) },
                onSelect = { requestNavigation(MeetingLeaveTarget.Select(it)) },
                onCreate = {
                    createTitle = ""
                    createError = null
                    createVisible = true
                },
                onRefresh = {
                    if (!refreshing) {
                        refreshing = true
                        scope.launch {
                            try {
                                manager.refresh()
                                listError = null
                            } catch (error: MeetingException) {
                                listError = error.error
                            } finally {
                                refreshing = false
                            }
                        }
                    }
                },
                onOpenRecordingMeeting = { id ->
                    requestNavigation(MeetingLeaveTarget.Select(id))
                },
            )
        } else {
            MeetingDetailHost(
                manager = manager,
                meetingId = selectedId.orEmpty(),
                summary = selectedSummary,
                detail = detail,
                loading = detailLoading,
                loadError = detailError,
                notesState = notesState,
                notesBusy = notesBusy,
                notesError = notesError,
                notesNoticeRes = notesNoticeRes,
                detailNoticeRes = detailNoticeRes,
                exportState = exportUi,
                onExportFormat = { startDocumentExport(it) },
                onExportShareText = { shareCurrentMeetingText() },
                recorderState = recorderState,
                recordingMeetingTitle = recordingMeetingTitle,
                permission = permission,
                recordBusy = recordBusy,
                recordBusyLabelRes = recordBusyLabelRes,
                recordError = recordError,
                recordNoticeRes = recordNoticeRes,
                recordRetainedTake = recordRetainedTake,
                autoTranscribe = autoTranscribe,
                onAutoTranscribeChange = setAutoTranscription,
                importBusy = importBusy,
                importError = importError,
                importNotice = importNotice,
                deleteBusy = deleteBusy,
                deleteError = deleteError,
                transcriptionManager = transcriptionManager,
                transcriptionState = transcriptionState,
                transcriptionCleanupFailure = transcriptionCleanupFailure,
                transcriptionMaterialId = transcriptionMaterialId,
                transcriptionMeetingTitle = transcriptionMeetingTitle,
                onTranscriptionMaterialSelected = { transcriptionMaterialId = it },
                assistantState = assistantState,
                assistantQuestion = assistantQuestion,
                assistantAskOpen = assistantAskOpen,
                assistantCanInsertNotes = meetingAssistantCanInsertNotes(
                    notesDirty = notesState.dirty,
                    notesConflict = notesState.conflict,
                    notesBusy = notesBusy,
                ),
                assistantNotesUnsaved = notesState.dirty,
                assistantAwaitingTranscription = assistantDrainPending,
                onAssistantQuestionChange = { assistantQuestion = it },
                onAssistantAskOpenChange = { assistantAskOpen = it },
                onAssistantSend = { action, question ->
                    sendAssistantAction(action, question)
                },
                onAssistantCancel = { selectedId?.let { assistantHost?.cancel(it) } },
                onAssistantCheckActive = {
                    selectedId?.let { assistantHost?.checkActive(it) }
                },
                onAssistantCheckAgain = { entryId ->
                    selectedId?.let { assistantHost?.checkAgain(it, entryId) }
                },
                onAssistantSelectModel = { modelId ->
                    selectedId?.let { assistantHost?.selectModel(modelId) }
                },
                onAssistantRefresh = { assistantHost?.refresh() },
                onAssistantInsert = { text, heading ->
                    insertAssistantAnswer(text, heading)
                },
                twoPane = false,
                onBack = { requestNavigation(MeetingLeaveTarget.ClearSelection) },
                onRefresh = {
                    scope.launch {
                        if (selectedId != null) {
                            detailLoading = true
                            loadDetail(selectedId.orEmpty())
                            detailLoading = false
                        }
                    }
                },
                onNotesChange = { value ->
                    notesState = notesState.edited(value)
                    notesNoticeRes = null
                },
                onSaveNotes = { saveNotes() },
                onReloadNotes = { reloadLatestNotes() },
                onRestoreNotes = { restoreMyNotes() },
                onStartRecording = {
                    if (selectedId != null) startRecording(selectedId.orEmpty())
                },
                onPauseRecording = {
                    if (selectedId != null) {
                        performRecordAction(
                            id = selectedId.orEmpty(),
                            busyLabelRes = R.string.meeting_ui_record_pausing,
                            successRes = R.string.meeting_ui_record_paused,
                        ) { manager.recorder.pause() }
                    }
                },
                onResumeRecording = {
                    if (selectedId != null) {
                        performRecordAction(
                            id = selectedId.orEmpty(),
                            busyLabelRes = R.string.meeting_ui_record_resuming,
                            successRes = R.string.meeting_ui_record_resumed,
                        ) { manager.recorder.resume() }
                    }
                },
                onStopRecording = {
                    if (selectedId != null) {
                        performStopRecording(selectedId.orEmpty())
                    }
                },
                onGrantMicrophone = { grantMicrophone() },
                onImport = { uri ->
                    if (selectedId != null) importMedia(selectedId.orEmpty(), uri)
                },
                onRename = { openRenameDialog() },
                onDelete = {
                    deleteError = null
                    deleteVisible = true
                },
                onOpenOtherMeeting = { id ->
                    requestNavigation(MeetingLeaveTarget.Select(id))
                },
            )
        }
    }

    if (createVisible) {
        MeetingTitleDialog(
            title = stringResource(R.string.meeting_ui_new),
            fieldLabel = stringResource(R.string.meeting_ui_new_hint),
            confirmLabel = stringResource(R.string.meeting_ui_create),
            busyLabelRes = R.string.meeting_ui_creating,
            value = createTitle,
            onValueChange = { createTitle = it },
            busy = createBusy,
            error = createError,
            confirmEnabled = true,
            onConfirm = { submitCreateMeeting() },
            onDismiss = {
                if (!createBusy) {
                    createVisible = false
                    createError = null
                }
            },
        )
    }

    if (renameVisible) {
        MeetingTitleDialog(
            title = stringResource(R.string.meeting_ui_rename),
            fieldLabel = stringResource(R.string.meeting_ui_rename_hint),
            confirmLabel = stringResource(R.string.meeting_ui_rename_save),
            busyLabelRes = R.string.meeting_ui_saving_title,
            value = renameTitle,
            onValueChange = { renameTitle = it },
            busy = renameBusy,
            error = renameError,
            confirmEnabled = renameTitle.isNotBlank(),
            onConfirm = { submitRename() },
            onDismiss = {
                if (!renameBusy) {
                    renameVisible = false
                    renameError = null
                }
            },
        )
    }

    if (deleteVisible) {
        val title = detail?.title ?: selectedSummary?.title ?: stringResource(R.string.meeting_ui_detail_title)
        FloeConfirmDialog(
            title = stringResource(R.string.meeting_ui_delete_title),
            message = stringResource(R.string.meeting_ui_delete_body, title),
            confirmLabel = stringResource(R.string.meeting_ui_delete_confirm),
            dismissLabel = stringResource(R.string.meeting_ui_cancel),
            onConfirm = { submitDelete() },
            onDismiss = { deleteVisible = false },
        )
    }

    pendingNotesLeave?.let { target ->
        MeetingLeaveNotesDialog(
            canSave = notesState.canSave && !notesBusy,
            saving = notesBusy,
            onSave = {
                pendingNotesLeave = null
                saveNotes(onSaved = { continueNavigation(target) })
            },
            onDiscard = {
                notesState = notesState.discarded()
                pendingNotesLeave = null
                continueNavigation(target)
            },
            onStay = { pendingNotesLeave = null },
        )
    }

    pendingRecordingLeave?.let { target ->
        MeetingLeaveRecordingDialog(
            meetingTitle = recordingMeetingTitle,
            stopping = stoppingToLeave,
            onContinueBackground = {
                pendingRecordingLeave = null
                finishNavigation(target)
            },
            onStay = {
                if (!stoppingToLeave) pendingRecordingLeave = null
            },
            onStop = { stopRecordingAndLeave() },
        )
    }
}

/**
 * Convenience overload for the Space integration point. The explicit
 * [MeetingManager] overload remains the testable seam; this one only creates
 * the cheap process-wide facade.
 */
@Composable
internal fun MeetingDestination(
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val applicationContext = LocalContext.current.applicationContext
    val manager = remember(applicationContext) { MeetingManager(applicationContext) }
    DisposableEffect(manager) { onDispose { manager.close() } }
    MeetingDestination(
        manager = manager,
        compact = compact,
        showSidebarToggle = showSidebarToggle,
        onExpandSidebar = onExpandSidebar,
        onOpenDrawer = onOpenDrawer,
        onExit = onExit,
        modifier = modifier,
    )
}

@Composable
private fun MeetingListPane(
    meetings: List<MeetingSummary>,
    ready: Boolean,
    selectedId: String?,
    recorderState: MeetingRecordingState,
    listError: MeetingError?,
    listNoticeRes: Int?,
    listRetainedTake: MeetingMaterial?,
    refreshing: Boolean,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    onExitPage: () -> Unit,
    onSelect: (String) -> Unit,
    onCreate: () -> Unit,
    onRefresh: () -> Unit,
    onOpenRecordingMeeting: (String) -> Unit,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = stringResource(R.string.meeting_ui_title),
            background = Floe.colors.readingSurface,
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.meeting_ui_back),
                    onClick = onExitPage,
                )
            },
            actions = {
                if (refreshing) {
                    FloeActivityIndicator(
                        modifier = Modifier.padding(horizontal = 6.dp),
                        description = stringResource(R.string.meeting_ui_refreshing),
                    )
                } else {
                    FloeToolbarIconButton(
                        icon = FloeIcons.Refresh,
                        contentDescription = stringResource(R.string.meeting_ui_refresh),
                        onClick = onRefresh,
                    )
                }
                FloeToolbarIconButton(
                    icon = FloeIcons.Plus,
                    contentDescription = stringResource(R.string.meeting_ui_new),
                    onClick = onCreate,
                )
            },
        )
        FloeDivider()

        val activeId = recorderState.meetingId
        if (meetingRecordingActive(recorderState.phase) && activeId != null) {
            val title = meetings.firstOrNull { it.id == activeId }?.title
                ?: stringResource(R.string.meeting_ui_detail_title)
            MeetingActiveRecordingBanner(
                title = title,
                status = stringResource(meetingRecordingStatusResource(recorderState.phase)),
                elapsed = meetingDurationLabel(recorderState.elapsedMillis),
                onClick = { activeId?.let(onOpenRecordingMeeting) },
            )
        }

        if (meetings.isNotEmpty()) {
            listError?.let { error ->
                MeetingErrorBanner(
                    text = meetingErrorText(error),
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    actionLabel = stringResource(R.string.meeting_ui_retry),
                    onAction = onRefresh,
                )
            }
        }

        listNoticeRes?.let { noticeRes ->
            MeetingNoticeBanner(
                text = stringResource(noticeRes),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }

        listRetainedTake?.let { retained ->
            MeetingRetainedTakeBanner(
                material = retained,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }

        Box(Modifier.weight(1f).fillMaxWidth()) {
            when {
                !ready && meetings.isEmpty() -> MeetingLoadingView(
                    text = stringResource(R.string.meeting_ui_loading),
                )
                meetings.isEmpty() && listError != null -> FloeUnavailableView(
                    icon = FloeIcons.Bubble,
                    title = stringResource(R.string.meeting_ui_load_failed),
                    description = meetingErrorText(listError),
                    action = {
                        FloePrimaryAction(
                            label = stringResource(R.string.meeting_ui_retry),
                            onClick = onRefresh,
                        )
                    },
                )
                meetings.isEmpty() -> FloeUnavailableView(
                    icon = FloeIcons.Bubble,
                    title = stringResource(R.string.meeting_ui_empty_title),
                    description = stringResource(R.string.meeting_ui_empty_body),
                    action = {
                        FloePrimaryAction(
                            label = stringResource(R.string.meeting_ui_new),
                            onClick = onCreate,
                        )
                    },
                )
                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(meetings, key = { it.id }) { summary ->
                        MeetingListRow(
                            summary = summary,
                            selected = summary.id == selectedId,
                            recordingElapsed = recorderState
                                .takeIf { it.meetingId == summary.id && meetingRecordingActive(it.phase) }
                                ?.elapsedMillis,
                            onClick = { onSelect(summary.id) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MeetingListRow(
    summary: MeetingSummary,
    selected: Boolean,
    recordingElapsed: Long?,
    onClick: () -> Unit,
) {
    val title = if (summary.metadataCorrupt) {
        stringResource(R.string.meeting_ui_unreadable_title)
    } else {
        summary.title
    }
    val preview = if (summary.metadataCorrupt) {
        stringResource(R.string.meeting_ui_metadata_corrupt_note)
    } else {
        summary.notesPreview.lineSequence().firstOrNull { it.isNotBlank() }?.trim()
            ?: stringResource(R.string.meeting_ui_no_notes)
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) Floe.colors.accentFillFaint else Color.Transparent)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(
                    if (summary.metadataCorrupt) {
                        Floe.colors.destructive.copy(alpha = 0.12f)
                    } else {
                        Floe.colors.accentFillFaint
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(
                icon = if (summary.metadataCorrupt) FloeIcons.WarningTriangle else FloeIcons.Bubble,
                tint = if (summary.metadataCorrupt) Floe.colors.destructive else Floe.colors.accent,
                size = 20.dp,
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeText(
                    text = title,
                    style = Floe.typography.bodyEmphasized,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (recordingElapsed != null) {
                    FloeBadgePill(
                        text = stringResource(
                            R.string.meeting_ui_active_recording_badge,
                            meetingDurationLabel(recordingElapsed),
                        ),
                        tone = FloeBadgeTone.ACCENT,
                    )
                }
                if (summary.metadataCorrupt) {
                    FloeBadgePill(
                        text = stringResource(R.string.meeting_ui_metadata_corrupt),
                        tone = FloeBadgeTone.DESTRUCTIVE,
                    )
                }
            }
            FloeText(
                text = stringResource(
                    R.string.meeting_ui_summary_meta,
                    meetingDateLabel(summary.updatedAtMillis),
                    summary.materialCount,
                    summary.recordingCount,
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FloeText(
                text = preview,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun MeetingActiveRecordingBanner(
    title: String,
    status: String,
    elapsed: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.accentFillFaint)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(FloeIcons.Mic, Floe.colors.accent, 18.dp)
        Column(Modifier.weight(1f)) {
            FloeText(title, style = Floe.typography.bodyEmphasized, maxLines = 1, overflow = TextOverflow.Ellipsis)
            FloeText(
                "$status · $elapsed",
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        IconGlyph(FloeIcons.ChevronForward, Floe.colors.secondaryLabel, 16.dp)
    }
}

@Composable
private fun MeetingSelectPlaceholder() {
    FloeUnavailableView(
        icon = FloeIcons.Bubble,
        title = stringResource(R.string.meeting_ui_select_title),
        description = stringResource(R.string.meeting_ui_select_body),
    )
}

@Composable
private fun MeetingLoadingView(text: String) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        FloeActivityIndicator(description = text)
        Spacer(Modifier.height(10.dp))
        FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    }
}

@Composable
private fun MeetingDetailHost(
    manager: MeetingManager,
    meetingId: String,
    summary: MeetingSummary?,
    detail: MeetingDetail?,
    loading: Boolean,
    loadError: MeetingError?,
    notesState: MeetingNotesUiState,
    notesBusy: Boolean,
    notesError: MeetingError?,
    notesNoticeRes: Int?,
    detailNoticeRes: Int?,
    exportState: MeetingExportUiState,
    onExportFormat: (MeetingExportFormat) -> Unit,
    onExportShareText: () -> Unit,
    recorderState: MeetingRecordingState,
    recordingMeetingTitle: String?,
    permission: MeetingPermissionState,
    recordBusy: Boolean,
    recordBusyLabelRes: Int?,
    recordError: MeetingError?,
    recordNoticeRes: Int?,
    recordRetainedTake: MeetingMaterial?,
    autoTranscribe: Boolean,
    onAutoTranscribeChange: (Boolean) -> Unit,
    importBusy: Boolean,
    importError: MeetingError?,
    importNotice: String?,
    deleteBusy: Boolean,
    deleteError: MeetingError?,
    transcriptionManager: MeetingTranscriptionManager,
    transcriptionState: MeetingTranscriptionState,
    transcriptionCleanupFailure: MeetingTranscriptionCleanupFailure?,
    transcriptionMaterialId: String?,
    transcriptionMeetingTitle: String?,
    onTranscriptionMaterialSelected: (String) -> Unit,
    assistantState: MeetingAssistantState?,
    assistantQuestion: String,
    assistantAskOpen: Boolean,
    assistantCanInsertNotes: Boolean,
    assistantNotesUnsaved: Boolean,
    assistantAwaitingTranscription: Boolean,
    onAssistantQuestionChange: (String) -> Unit,
    onAssistantAskOpenChange: (Boolean) -> Unit,
    onAssistantSend: (MeetingAssistantAction, String) -> Unit,
    onAssistantCancel: () -> Unit,
    onAssistantCheckActive: () -> Unit,
    onAssistantCheckAgain: (String) -> Unit,
    onAssistantSelectModel: (String) -> Unit,
    onAssistantRefresh: () -> Unit,
    onAssistantInsert: (String, String) -> Unit,
    twoPane: Boolean,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onNotesChange: (String) -> Unit,
    onSaveNotes: () -> Unit,
    onReloadNotes: () -> Unit,
    onRestoreNotes: () -> Unit,
    onStartRecording: () -> Unit,
    onPauseRecording: () -> Unit,
    onResumeRecording: () -> Unit,
    onStopRecording: () -> Unit,
    onGrantMicrophone: () -> Unit,
    onImport: (Uri) -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onOpenOtherMeeting: (String) -> Unit,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = detail?.title ?: summary?.title ?: stringResource(R.string.meeting_ui_detail_title),
            background = Floe.colors.readingSurface,
            navigation = if (twoPane) {
                null
            } else {
                {
                    FloeCircleButton(
                        icon = FloeIcons.ChevronBack,
                        contentDescription = stringResource(R.string.meeting_ui_back),
                        onClick = onBack,
                    )
                }
            },
            actions = {
                FloeToolbarIconButton(
                    icon = FloeIcons.Refresh,
                    contentDescription = stringResource(R.string.meeting_ui_refresh),
                    onClick = onRefresh,
                )
            },
        )
        FloeDivider()

        when {
            loading && detail == null -> MeetingLoadingView(
                text = stringResource(R.string.meeting_ui_detail_loading),
            )
            detail == null && loadError != null -> FloeUnavailableView(
                icon = FloeIcons.WarningTriangle,
                title = stringResource(R.string.meeting_ui_detail_load_failed),
                description = meetingErrorText(loadError),
                action = {
                    FloePrimaryAction(
                        label = stringResource(R.string.meeting_ui_retry),
                        onClick = onRefresh,
                    )
                },
            )
            detail == null -> MeetingSelectPlaceholder()
            else -> Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.TopCenter,
            ) {
                LazyColumn(
                    modifier = Modifier
                        .widthIn(max = 900.dp)
                        .fillMaxWidth()
                        .fillMaxHeight()
                        .imePadding()
                        .navigationBarsPadding(),
                    contentPadding = PaddingValues(start = 14.dp, end = 14.dp, top = 14.dp, bottom = 32.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    loadError?.let { error ->
                        item(key = "load-error") {
                            MeetingErrorBanner(
                                text = meetingErrorText(error),
                                actionLabel = stringResource(R.string.meeting_ui_retry),
                                onAction = onRefresh,
                            )
                        }
                    }
                    item(key = "header") {
                        MeetingHeader(
                            detail = detail,
                            noticeRes = detailNoticeRes,
                            onRename = onRename,
                        )
                    }
                    item(key = "export") {
                        MeetingExportSection(
                            state = exportState,
                            notesUnsaved = notesState.dirty,
                            onExportFormat = onExportFormat,
                            onShareText = onExportShareText,
                        )
                    }
                    item(key = "notes") {
                        MeetingNotesSection(
                            state = notesState,
                            busy = notesBusy,
                            error = notesError,
                            noticeRes = notesNoticeRes,
                            onNotesChange = onNotesChange,
                            onSave = onSaveNotes,
                            onReload = onReloadNotes,
                            onRestore = onRestoreNotes,
                        )
                    }
                    assistantState?.let { assistant ->
                        item(key = "assistant") {
                            MeetingAssistantSection(
                                state = assistant,
                                detail = detail,
                                question = assistantQuestion,
                                askOpen = assistantAskOpen,
                                canInsertNotes = assistantCanInsertNotes,
                                notesUnsaved = assistantNotesUnsaved,
                                awaitingTranscription = assistantAwaitingTranscription,
                                onQuestionChange = onAssistantQuestionChange,
                                onAskOpenChange = onAssistantAskOpenChange,
                                onSend = onAssistantSend,
                                onCancel = onAssistantCancel,
                                onCheckActive = onAssistantCheckActive,
                                onCheckAgain = onAssistantCheckAgain,
                                onSelectModel = onAssistantSelectModel,
                                onRefresh = onAssistantRefresh,
                                onInsert = onAssistantInsert,
                            )
                        }
                    }
                    item(key = "recording") {
                        MeetingRecordingSection(
                            meetingId = meetingId,
                            recorderState = recorderState,
                            recordingMeetingTitle = recordingMeetingTitle,
                            permission = permission,
                            busy = recordBusy,
                            busyLabelRes = recordBusyLabelRes,
                            error = recordError,
                            noticeRes = recordNoticeRes,
                            retainedTake = recordRetainedTake,
                            autoTranscribe = autoTranscribe,
                            onAutoTranscribeChange = onAutoTranscribeChange,
                            onStart = onStartRecording,
                            onPause = onPauseRecording,
                            onResume = onResumeRecording,
                            onStop = onStopRecording,
                            onGrantMicrophone = onGrantMicrophone,
                            onOpenOtherMeeting = onOpenOtherMeeting,
                        )
                    }
                    item(key = "media") {
                        MeetingMediaSection(
                            manager = manager,
                            meetingId = meetingId,
                            materials = detail.materials,
                            importBusy = importBusy,
                            importError = importError,
                            importNotice = importNotice,
                            onImport = onImport,
                        )
                    }
                    item(key = "transcription") {
                        MeetingTranscriptionSection(
                            manager = transcriptionManager,
                            state = transcriptionState,
                            cleanupFailure = transcriptionCleanupFailure,
                            meetingId = meetingId,
                            detail = detail,
                            selectedMaterialId = transcriptionMaterialId,
                            transcriptionMeetingTitle = transcriptionMeetingTitle,
                            onSelectMaterial = onTranscriptionMaterialSelected,
                            onReloadMeeting = onRefresh,
                            onAcknowledgeCleanupFailure = {
                                transcriptionManager.acknowledgeCleanupFailure()
                            },
                            onOpenOtherMeeting = onOpenOtherMeeting,
                        )
                    }
                    item(key = "delete") {
                        MeetingDeleteSection(
                            busy = deleteBusy,
                            error = deleteError,
                            onDelete = onDelete,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MeetingHeader(
    detail: MeetingDetail,
    noticeRes: Int?,
    onRename: () -> Unit,
) {
    FloeSettingsSectionCard(title = null) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(
                    text = detail.title,
                    style = Floe.typography.title,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.meeting_ui_rename),
                    onClick = onRename,
                )
            }
            FloeText(
                text = stringResource(
                    R.string.meeting_ui_summary_meta,
                    meetingDateLabel(detail.updatedAtMillis),
                    detail.materials.size,
                    detail.recordings.size,
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            noticeRes?.let { MeetingNoticeBanner(text = stringResource(it)) }
        }
    }
}

@Composable
private fun MeetingExportSection(
    state: MeetingExportUiState,
    notesUnsaved: Boolean,
    onExportFormat: (MeetingExportFormat) -> Unit,
    onShareText: () -> Unit,
) {
    FloeSettingsSectionCard(title = stringResource(R.string.meeting_ui_export_title)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            FloeText(
                text = stringResource(R.string.meeting_ui_export_body),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            if (notesUnsaved) {
                FloeStatusLine(
                    icon = FloeIcons.InfoCircle,
                    text = stringResource(R.string.meeting_ui_export_unsaved_notes),
                    color = Floe.colors.pending,
                )
            }
            if (state.busy) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeActivityIndicator(
                        description = stringResource(R.string.meeting_ui_export_working),
                    )
                    FloeText(
                        stringResource(R.string.meeting_ui_export_working),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            } else {
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_export_save_txt),
                        onClick = { onExportFormat(MeetingExportFormat.TXT) },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_export_save_markdown),
                        onClick = { onExportFormat(MeetingExportFormat.MARKDOWN) },
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_export_save_docx),
                        onClick = { onExportFormat(MeetingExportFormat.DOCX) },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_export_save_pdf),
                        onClick = { onExportFormat(MeetingExportFormat.PDF) },
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_export_share),
                        onClick = onShareText,
                    )
                }
            }
            state.error?.let { MeetingErrorBanner(text = it) }
            state.notice?.let { MeetingNoticeBanner(text = it) }
        }
    }
}

/** Page-owned export attempt state; reset whenever the selected meeting changes. */
private data class MeetingExportUiState(
    val busy: Boolean = false,
    val error: String? = null,
    val notice: String? = null,
)

@Composable
private fun MeetingNotesSection(
    state: MeetingNotesUiState,
    busy: Boolean,
    error: MeetingError?,
    noticeRes: Int?,
    onNotesChange: (String) -> Unit,
    onSave: () -> Unit,
    onReload: () -> Unit,
    onRestore: () -> Unit,
) {
    FloeSettingsSectionCard(title = stringResource(R.string.meeting_ui_notes)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (busy) {
                    FloeActivityIndicator(description = stringResource(R.string.meeting_ui_notes_saving))
                    FloeText(
                        stringResource(R.string.meeting_ui_notes_saving),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                } else if (state.conflict) {
                    FloeStatusLine(
                        icon = FloeIcons.WarningTriangle,
                        text = stringResource(R.string.meeting_ui_notes_conflict_title),
                        color = Floe.colors.pending,
                    )
                } else if (state.dirty) {
                    FloeStatusLine(
                        icon = FloeIcons.Clock,
                        text = stringResource(R.string.meeting_ui_notes_unsaved),
                        color = Floe.colors.pending,
                    )
                } else {
                    FloeStatusLine(
                        icon = FloeIcons.CheckCircle,
                        text = stringResource(R.string.meeting_ui_notes_saved),
                        color = Floe.colors.success,
                    )
                }
            }

            if (state.conflict) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Floe.colors.pending.copy(alpha = 0.10f))
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeText(
                        stringResource(R.string.meeting_ui_notes_conflict_body),
                        style = Floe.typography.metadata,
                        color = Floe.colors.label,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.meeting_ui_notes_reload),
                            onClick = onReload,
                            enabled = !busy,
                        )
                        if (state.recovery != null) {
                            FloeCapsuleAction(
                                label = stringResource(R.string.meeting_ui_notes_restore),
                                onClick = onRestore,
                                enabled = !busy,
                            )
                        }
                    }
                }
            } else if (state.canRestore) {
                FloeStatusLine(
                    icon = FloeIcons.InfoCircle,
                    text = stringResource(R.string.meeting_ui_notes_restore_available),
                    color = Floe.colors.secondaryLabel,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.meeting_ui_notes_restore),
                    onClick = onRestore,
                    enabled = !busy,
                )
            }

            FloePlainFormField(
                label = stringResource(R.string.meeting_ui_notes_hint),
                value = state.draft,
                onValueChange = onNotesChange,
                modifier = Modifier.fillMaxWidth().heightIn(min = 180.dp),
                enabled = !busy,
                singleLine = false,
                maxLines = 18,
                minLines = 8,
                isError = state.conflict,
            )

            error?.let { MeetingErrorBanner(text = meetingErrorText(it)) }
            noticeRes?.let { MeetingNoticeBanner(text = stringResource(it)) }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.meeting_ui_notes_save),
                    onClick = onSave,
                    enabled = state.canSave && !busy,
                )
            }
        }
    }
}

@Composable
private fun MeetingAssistantSection(
    state: MeetingAssistantState,
    detail: MeetingDetail,
    question: String,
    askOpen: Boolean,
    canInsertNotes: Boolean,
    notesUnsaved: Boolean,
    awaitingTranscription: Boolean,
    onQuestionChange: (String) -> Unit,
    onAskOpenChange: (Boolean) -> Unit,
    onSend: (MeetingAssistantAction, String) -> Unit,
    onCancel: () -> Unit,
    onCheckActive: () -> Unit,
    onCheckAgain: (String) -> Unit,
    onSelectModel: (String) -> Unit,
    onRefresh: () -> Unit,
    onInsert: (String, String) -> Unit,
) {
    val contextReady = meetingAssistantContextReady(detail)
    val availability = state.availability
    val active = state.active
    val canStartTurn = meetingAssistantCanSend(availability, active, contextReady)
    val answerHeading = stringResource(R.string.meeting_ui_assistant_answer_heading)
    val minutesHeading = stringResource(R.string.meeting_ui_assistant_minutes_heading)
    val todosHeading = stringResource(R.string.meeting_ui_assistant_todos_heading)
    val hasAnswer = state.entries.any { it.answer != null }

    FloeSettingsSectionCard(title = stringResource(R.string.meeting_ui_assistant_section)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            when (availability) {
                MeetingAssistantAvailability.Checking -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        val checking = stringResource(R.string.meeting_ui_assistant_checking)
                        FloeActivityIndicator(description = checking)
                        FloeText(
                            text = checking,
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }

                is MeetingAssistantAvailability.NotConfigured -> {
                    FloeStatusLine(
                        icon = FloeIcons.WarningTriangle,
                        text = stringResource(meetingAssistantFailureResource(availability.reason)),
                        color = Floe.colors.pending,
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_assistant_check_again),
                        onClick = onRefresh,
                    )
                }

                is MeetingAssistantAvailability.Unavailable -> {
                    FloeStatusLine(
                        icon = FloeIcons.WarningTriangle,
                        text = stringResource(meetingAssistantFailureResource(availability.reason)),
                        color = Floe.colors.pending,
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_assistant_check_again),
                        onClick = onRefresh,
                    )
                }

                is MeetingAssistantAvailability.Ready -> {
                    FloeText(
                        text = stringResource(
                            R.string.meeting_ui_assistant_model,
                            availability.modelLabel,
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    if (availability.models.size > 1) {
                        Row(
                            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            availability.models.forEach { model ->
                                FloeCapsuleAction(
                                    label = model.label,
                                    onClick = { onSelectModel(model.modelId) },
                                    tint = if (model.modelId == availability.modelId) {
                                        Floe.colors.accent
                                    } else {
                                        Floe.colors.secondaryLabel
                                    },
                                    showHairline = model.modelId == availability.modelId,
                                )
                            }
                        }
                    }
                    FloeText(
                        text = stringResource(R.string.meeting_ui_assistant_privacy),
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                    )
                }
            }

            if (!contextReady) {
                MeetingInlineEmpty(
                    icon = FloeIcons.Wand,
                    title = stringResource(R.string.meeting_ui_assistant_context_empty_title),
                    body = stringResource(R.string.meeting_ui_assistant_context_empty_body),
                )
            } else if (awaitingTranscription && active == null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    val waiting = stringResource(R.string.meeting_ui_assistant_awaiting_transcription)
                    FloeActivityIndicator(description = waiting)
                    FloeText(
                        text = waiting,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.weight(1f),
                    )
                }
            } else if (canStartTurn) {
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_assistant_ask),
                        onClick = { onAskOpenChange(true) },
                        enabled = !askOpen,
                        tint = if (askOpen) Floe.colors.accent else null,
                        showHairline = askOpen,
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_assistant_minutes),
                        onClick = { onSend(MeetingAssistantAction.MINUTES, "") },
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_assistant_todos),
                        onClick = { onSend(MeetingAssistantAction.TODOS, "") },
                    )
                }
                if (askOpen) {
                    FloePlainFormField(
                        label = stringResource(R.string.meeting_ui_assistant_question_hint),
                        value = question,
                        onValueChange = onQuestionChange,
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = false,
                        minLines = 2,
                        maxLines = 6,
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_assistant_send),
                        onClick = { onSend(MeetingAssistantAction.ASK, question) },
                        enabled = question.isNotBlank(),
                    )
                }
            }

            active?.let { turn ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    val label = when (turn.phase) {
                        MeetingAssistantTurnPhase.PREPARING ->
                            stringResource(R.string.meeting_ui_assistant_preparing)
                        MeetingAssistantTurnPhase.RUNNING ->
                            stringResource(R.string.meeting_ui_assistant_working)
                        MeetingAssistantTurnPhase.CANCELLING ->
                            stringResource(R.string.meeting_ui_assistant_cancelling)
                    }
                    if (turn.phase != MeetingAssistantTurnPhase.CANCELLING) {
                        FloeActivityIndicator(description = label)
                    }
                    FloeText(
                        text = label,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.weight(1f),
                    )
                    if (turn.phase == MeetingAssistantTurnPhase.RUNNING) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.meeting_ui_assistant_cancel),
                            onClick = onCancel,
                            tint = Floe.colors.destructive,
                        )
                    }
                    if (state.error?.code == MeetingAssistantFailureCode.STREAM_LOST) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.meeting_ui_assistant_check_status),
                            onClick = onCheckActive,
                        )
                    }
                }
            }

            state.error?.let { failure ->
                MeetingErrorBanner(text = meetingAssistantFailureText(failure))
            }
            if (state.historyUnreadable) {
                FloeStatusLine(
                    icon = FloeIcons.WarningTriangle,
                    text = stringResource(R.string.meeting_ui_assistant_history_unreadable),
                    color = Floe.colors.pending,
                )
            }
            if (notesUnsaved) {
                FloeStatusLine(
                    icon = FloeIcons.InfoCircle,
                    text = stringResource(R.string.meeting_ui_assistant_unsaved_notes),
                    color = Floe.colors.pending,
                )
            }
            if (hasAnswer && !canInsertNotes) {
                FloeText(
                    text = stringResource(R.string.meeting_ui_assistant_insert_requires_saved_notes),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
            }
            if (state.entries.isEmpty() && contextReady && canStartTurn) {
                MeetingInlineEmpty(
                    icon = FloeIcons.Wand,
                    title = stringResource(R.string.meeting_ui_assistant_empty_title),
                    body = stringResource(R.string.meeting_ui_assistant_empty_body),
                )
            }

            state.entries.forEachIndexed { index, entry ->
                val heading = when (entry.action) {
                    MeetingAssistantAction.ASK -> answerHeading
                    MeetingAssistantAction.MINUTES -> minutesHeading
                    MeetingAssistantAction.TODOS -> todosHeading
                }
                MeetingAssistantEntryRow(
                    entry = entry,
                    checking = entry.id in state.checkingEntryIds,
                    active = active,
                    canInsertNotes = canInsertNotes,
                    onCheckAgain = { onCheckAgain(entry.id) },
                    onInsert = {
                        entry.answer?.let { answer ->
                            val text = if (
                                entry.action == MeetingAssistantAction.ASK &&
                                entry.question.isNotBlank()
                            ) {
                                "${entry.question}\n\n$answer"
                            } else {
                                answer
                            }
                            onInsert(text, heading)
                        }
                    },
                )
                if (index != state.entries.lastIndex) FloeDivider()
            }
        }
    }
}

@Composable
private fun MeetingAssistantEntryRow(
    entry: MeetingAssistantEntry,
    checking: Boolean,
    active: MeetingAssistantTurnView?,
    canInsertNotes: Boolean,
    onCheckAgain: () -> Unit,
    onInsert: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FloeText(
                text = stringResource(meetingAssistantKindResource(entry.action)),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            val time = meetingAssistantTimeLabel(entry.createdAtMillis)
            if (time.isNotEmpty()) {
                FloeText(
                    text = time,
                    style = Floe.typography.evidence,
                    color = Floe.colors.tertiaryLabel,
                )
            }
        }
        if (entry.action == MeetingAssistantAction.ASK && entry.question.isNotBlank()) {
            FloeText(entry.question, style = Floe.typography.bodyEmphasized)
        }
        val answer = entry.answer
        if (!answer.isNullOrBlank()) {
            FloeText(answer, style = Floe.typography.body)
            if (entry.answerTruncated) {
                FloeText(
                    text = stringResource(R.string.meeting_ui_assistant_truncated),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
            }
            if (entry.status == MeetingAssistantEntryStatus.PARTIAL) {
                FloeStatusLine(
                    icon = FloeIcons.InfoCircle,
                    text = stringResource(R.string.meeting_ui_assistant_partial),
                    color = Floe.colors.pending,
                )
            }
        } else if (entry.status == MeetingAssistantEntryStatus.PENDING) {
            if (active != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    val pending = stringResource(R.string.meeting_ui_assistant_pending)
                    FloeActivityIndicator(description = pending)
                    FloeText(
                        text = pending,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            } else {
                FloeStatusLine(
                    icon = FloeIcons.Clock,
                    text = stringResource(R.string.meeting_ui_assistant_unfinished),
                    color = Floe.colors.secondaryLabel,
                )
            }
        } else {
            FloeStatusLine(
                icon = FloeIcons.WarningTriangle,
                text = meetingAssistantFailureText(
                    MeetingAssistantFailure(
                        entry.failure ?: MeetingAssistantFailureCode.RESULT_UNREADABLE,
                    ),
                ),
                color = Floe.colors.secondaryLabel,
            )
        }
        FloeText(
            text = stringResource(
                R.string.meeting_ui_assistant_provenance,
                entry.notesRevision,
                entry.transcriptRevision,
            ),
            style = Floe.typography.evidence,
            color = Floe.colors.tertiaryLabel,
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (!answer.isNullOrBlank() && canInsertNotes) {
                FloeCapsuleAction(
                    label = stringResource(R.string.meeting_ui_assistant_insert),
                    onClick = onInsert,
                )
            }
            val canCheckAgain = entry.status == MeetingAssistantEntryStatus.UNRESOLVED ||
                (entry.status == MeetingAssistantEntryStatus.PENDING && active == null)
            if (canCheckAgain) {
                if (checking) {
                    val label = stringResource(R.string.meeting_ui_assistant_check_again)
                    FloeActivityIndicator(description = label)
                    FloeText(
                        text = label,
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                } else {
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_assistant_check_again),
                        onClick = onCheckAgain,
                    )
                }
            }
        }
    }
}

@Composable
private fun MeetingRecordingSection(
    meetingId: String,
    recorderState: MeetingRecordingState,
    recordingMeetingTitle: String?,
    permission: MeetingPermissionState,
    busy: Boolean,
    busyLabelRes: Int?,
    error: MeetingError?,
    noticeRes: Int?,
    retainedTake: MeetingMaterial?,
    autoTranscribe: Boolean,
    onAutoTranscribeChange: (Boolean) -> Unit,
    onStart: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onStop: () -> Unit,
    onGrantMicrophone: () -> Unit,
    onOpenOtherMeeting: (String) -> Unit,
) {
    val phase = recorderState.phase
    val active = meetingRecordingActive(phase)
    val ownedByThisMeeting = active && recorderState.meetingId == meetingId
    val ownedByOtherMeeting = active && recorderState.meetingId != null && recorderState.meetingId != meetingId
    val liveError = recordLiveError(error, recorderState, meetingId)

    FloeSettingsSectionCard(title = stringResource(R.string.meeting_ui_recording_section)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Floe.colors.accentFillFaint),
                    contentAlignment = Alignment.Center,
                ) {
                    IconGlyph(FloeIcons.Mic, Floe.colors.accent, 20.dp)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    FloeText(
                        text = stringResource(meetingRecordingStatusResource(phase)),
                        style = Floe.typography.bodyEmphasized,
                    )
                    if (ownedByThisMeeting) {
                        FloeText(
                            text = stringResource(
                                R.string.meeting_ui_record_elapsed,
                                meetingDurationLabel(recorderState.elapsedMillis),
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    } else if (ownedByOtherMeeting) {
                        FloeText(
                            text = recordingMeetingTitle?.let {
                                stringResource(R.string.meeting_ui_record_other, it)
                            } ?: stringResource(R.string.meeting_ui_record_other_unknown),
                            style = Floe.typography.metadata,
                            color = Floe.colors.pending,
                        )
                    }
                }
                if (busy) {
                    FloeActivityIndicator(
                        description = busyLabelRes?.let { stringResource(it) },
                    )
                }
            }

            if (busyLabelRes != null) {
                FloeText(
                    text = stringResource(busyLabelRes),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }

            if (ownedByOtherMeeting) {
                recorderState.meetingId?.let { activeMeetingId ->
                    FloeCapsuleAction(
                        label = stringResource(R.string.meeting_ui_record_open_other),
                        onClick = { onOpenOtherMeeting(activeMeetingId) },
                    )
                }
            }

            if (!permission.microphoneGranted && !ownedByOtherMeeting) {
                FloeText(
                    text = stringResource(R.string.meeting_ui_record_permission_needed),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
                FloePrimaryAction(
                    label = stringResource(R.string.meeting_ui_record_grant),
                    onClick = onGrantMicrophone,
                )
            } else if (permission.notificationsRuntimeRequired && !permission.notificationsGranted) {
                FloeStatusLine(
                    icon = FloeIcons.WarningTriangle,
                    text = stringResource(R.string.meeting_ui_notifications_off),
                    color = Floe.colors.pending,
                )
            }

            if (retainedTake == null) {
                liveError?.let { MeetingErrorBanner(text = meetingErrorText(it)) }
            }
            retainedTake?.let { MeetingRetainedTakeBanner(material = it) }
            noticeRes?.let { MeetingNoticeBanner(text = stringResource(it)) }

            if (!ownedByOtherMeeting) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    when {
                        phase == MeetingRecordingPhase.RECORDING -> {
                            FloeCapsuleAction(
                                label = stringResource(R.string.meeting_ui_record_pause),
                                onClick = onPause,
                                enabled = !busy,
                            )
                            FloeCapsuleAction(
                                label = stringResource(R.string.meeting_ui_record_stop),
                                onClick = onStop,
                                enabled = !busy,
                                tint = Floe.colors.destructive,
                            )
                        }
                        phase == MeetingRecordingPhase.PAUSED -> {
                            FloeCapsuleAction(
                                label = stringResource(R.string.meeting_ui_record_resume),
                                onClick = onResume,
                                enabled = !busy,
                            )
                            FloeCapsuleAction(
                                label = stringResource(R.string.meeting_ui_record_stop),
                                onClick = onStop,
                                enabled = !busy,
                                tint = Floe.colors.destructive,
                            )
                        }
                        phase == MeetingRecordingPhase.STARTING ||
                            phase == MeetingRecordingPhase.STOPPING -> {
                            FloeCapsuleAction(
                                label = stringResource(R.string.meeting_ui_record_stop),
                                onClick = onStop,
                                enabled = !busy && phase != MeetingRecordingPhase.STOPPING,
                                tint = Floe.colors.destructive,
                            )
                        }
                        else -> {
                            FloeCapsuleAction(
                                label = stringResource(R.string.meeting_ui_record_start),
                                onClick = onStart,
                                enabled = !busy &&
                                    meetingCanStartRecording(phase, permission.microphoneGranted),
                            )
                        }
                    }
                }
            }

            if (!ownedByOtherMeeting) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FloeText(
                        text = stringResource(R.string.meeting_ui_record_auto_transcribe),
                        style = Floe.typography.metadata,
                        color = Floe.colors.label,
                        modifier = Modifier.weight(1f),
                    )
                    FloeInlineSwitch(
                        checked = autoTranscribe,
                        onCheckedChange = onAutoTranscribeChange,
                        description = stringResource(R.string.meeting_ui_record_auto_transcribe),
                        enabled = !busy,
                    )
                }
                if (autoTranscribe) {
                    FloeText(
                        text = stringResource(R.string.meeting_ui_record_auto_transcribe_note),
                        style = Floe.typography.metadata,
                        color = Floe.colors.tertiaryLabel,
                    )
                }
            }

            FloeText(
                text = stringResource(R.string.meeting_ui_record_service_note),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
    }
}

@Composable
private fun MeetingMediaSection(
    manager: MeetingManager,
    meetingId: String,
    materials: List<MeetingMaterial>,
    importBusy: Boolean,
    importError: MeetingError?,
    importNotice: String?,
    onImport: (Uri) -> Unit,
) {
    val importPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        if (uri != null) onImport(uri)
    }

    var playbackMaterialId by rememberSaveable(meetingId) { mutableStateOf<String?>(null) }
    var resumePosition by rememberSaveable(meetingId) { mutableStateOf(0L) }
    var playbackRequested by remember(meetingId) { mutableStateOf(false) }
    var openNonce by remember(meetingId) { mutableStateOf(0) }
    var playbackSession by remember(meetingId) { mutableStateOf<MeetingPlaybackSession?>(null) }
    var playbackState by remember(meetingId) { mutableStateOf<MeetingPlayerState?>(null) }
    var playbackError by remember(meetingId) { mutableStateOf<MeetingError?>(null) }
    var playbackLoading by remember(meetingId) { mutableStateOf(false) }
    val lifecycleOwner = LocalLifecycleOwner.current
    val latestPlaybackState by rememberUpdatedState(playbackState)
    val latestPlaybackSession by rememberUpdatedState(playbackSession)

    LaunchedEffect(playbackMaterialId, openNonce, meetingId) {
        val requestedId = playbackMaterialId ?: return@LaunchedEffect
        val material = materials.firstOrNull { it.id == requestedId }
        if (material == null || !material.isPlayable) {
            playbackMaterialId = null
            return@LaunchedEffect
        }
        playbackLoading = true
        playbackError = null
        try {
            val player = manager.playerFor(meetingId, requestedId)
            if (playbackMaterialId != requestedId) {
                player.release()
                return@LaunchedEffect
            }
            if (resumePosition > 0L) player.seekTo(resumePosition)
            playbackSession = MeetingPlaybackSession(requestedId, player)
            if (playbackRequested) {
                playbackRequested = false
                player.play()
            }
        } catch (error: MeetingException) {
            if (playbackMaterialId == requestedId) {
                playbackError = error.error
                playbackSession = null
            }
        } catch (error: CancellationException) {
            throw error
        } finally {
            playbackLoading = false
        }
    }

    LaunchedEffect(playbackSession) {
        val session = playbackSession ?: return@LaunchedEffect
        session.player.state.collect { state ->
            if (playbackSession?.materialId != session.materialId) return@collect
            playbackState = state
            if (state.status == MeetingPlayerStatus.PLAYING ||
                state.status == MeetingPlayerStatus.PAUSED
            ) {
                resumePosition = state.positionMillis
            }
            if (state.status == MeetingPlayerStatus.ERROR) {
                playbackError = state.error ?: MeetingError(
                    code = MeetingErrorCode.PLAYBACK_FAILED,
                    message = "Playback failed.",
                    retryable = false,
                )
            }
        }
    }

    DisposableEffect(playbackSession) {
        val session = playbackSession
        onDispose {
            latestPlaybackState?.let { state ->
                if (state.status == MeetingPlayerStatus.PLAYING ||
                    state.status == MeetingPlayerStatus.PAUSED
                ) {
                    resumePosition = state.positionMillis
                }
            }
            session?.player?.release()
        }
    }

    fun closePlayback() {
        playbackSession?.player?.release()
        playbackSession = null
        playbackState = null
        playbackError = null
        playbackLoading = false
        playbackRequested = false
        playbackMaterialId = null
        resumePosition = 0L
    }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                latestPlaybackState?.let { state ->
                    if (state.status == MeetingPlayerStatus.PLAYING ||
                        state.status == MeetingPlayerStatus.PAUSED
                    ) {
                        resumePosition = state.positionMillis
                    }
                }
                latestPlaybackSession?.player?.pause()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(materials) {
        val selected = playbackMaterialId ?: return@LaunchedEffect
        if (materials.none { it.id == selected }) {
            closePlayback()
        }
    }

    fun togglePlayback(material: MeetingMaterial) {
        if (!material.isPlayable || playbackLoading) return
        val session = playbackSession
        if (playbackMaterialId == material.id && session != null) {
            when (playbackState?.status) {
                MeetingPlayerStatus.PLAYING -> {
                    resumePosition = playbackState?.positionMillis ?: resumePosition
                    session.player.pause()
                }
                MeetingPlayerStatus.PAUSED -> session.player.play()
                MeetingPlayerStatus.ENDED -> {
                    session.player.seekTo(0L)
                    session.player.play()
                }
                MeetingPlayerStatus.ERROR -> {
                    closePlayback()
                    playbackMaterialId = material.id
                    playbackRequested = true
                    openNonce += 1
                }
                MeetingPlayerStatus.PREPARING -> Unit
                else -> session.player.play()
            }
        } else {
            resumePosition = playbackState?.positionMillis ?: resumePosition
            session?.player?.release()
            playbackSession = null
            playbackState = null
            playbackError = null
            playbackMaterialId = material.id
            resumePosition = 0L
            playbackRequested = true
            openNonce += 1
        }
    }

    val currentMaterial = materials.firstOrNull { it.id == playbackMaterialId }
    val playbackVisible = currentMaterial != null &&
        (playbackSession != null || playbackLoading || playbackError != null)

    FloeSettingsSectionCard(title = stringResource(R.string.meeting_ui_media_section)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeText(
                    text = stringResource(
                        R.string.meeting_ui_media_counts,
                        materials.size,
                        materials.count { it.kind == MeetingMaterialKind.RECORDING },
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.meeting_ui_import),
                    onClick = {
                        importPicker.launch(arrayOf("audio/*", "video/*"))
                    },
                    enabled = !importBusy,
                )
            }

            if (importBusy) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeActivityIndicator(description = stringResource(R.string.meeting_ui_importing))
                    FloeText(
                        stringResource(R.string.meeting_ui_importing),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
            importError?.let { MeetingErrorBanner(text = meetingErrorText(it)) }
            importNotice?.let {
                MeetingNoticeBanner(text = stringResource(R.string.meeting_ui_imported, it))
            }

            if (materials.isEmpty()) {
                MeetingInlineEmpty(
                    icon = FloeIcons.Film,
                    title = stringResource(R.string.meeting_ui_no_media),
                )
            } else {
                materials.forEach { material ->
                    MeetingMaterialRow(
                        material = material,
                        playing = material.id == playbackMaterialId &&
                            playbackState?.status == MeetingPlayerStatus.PLAYING,
                        loading = material.id == playbackMaterialId && playbackLoading,
                        onToggle = { togglePlayback(material) },
                    )
                    FloeDivider()
                }
            }

            if (playbackVisible && currentMaterial != null) {
                MeetingPlaybackCard(
                    material = currentMaterial,
                    state = playbackState,
                    loading = playbackLoading,
                    error = playbackError,
                    onToggle = { togglePlayback(currentMaterial) },
                    onStop = { closePlayback() },
                )
            }
        }
    }
}

@Composable
private fun MeetingMaterialRow(
    material: MeetingMaterial,
    playing: Boolean,
    loading: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(Floe.colors.fillTertiary),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(
                icon = when (material.kind) {
                    MeetingMaterialKind.RECORDING -> FloeIcons.Mic
                    MeetingMaterialKind.AUDIO_IMPORT -> FloeIcons.Paperclip
                    MeetingMaterialKind.VIDEO_IMPORT -> FloeIcons.Film
                },
                tint = Floe.colors.secondaryLabel,
                size = 18.dp,
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            FloeText(
                text = material.displayName,
                style = Floe.typography.body,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    text = stringResource(
                        R.string.meeting_ui_material_meta,
                        stringResource(meetingMaterialKindResource(material.kind)),
                        meetingDurationLabel(material.durationMillis),
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeBadgePill(
                    text = stringResource(meetingMaterialStatusResource(material.status)),
                    tone = meetingMaterialTone(material.status),
                )
            }
            if (!material.isPlayable) {
                FloeText(
                    text = stringResource(
                        when (material.status) {
                            MeetingMaterialStatus.RECORDING,
                            MeetingMaterialStatus.PAUSED,
                            MeetingMaterialStatus.FINALIZING,
                            -> R.string.meeting_ui_material_not_ready
                            else -> R.string.meeting_ui_material_not_playable
                        },
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (material.isPlayable) {
            if (loading) {
                FloeActivityIndicator(description = stringResource(R.string.meeting_ui_playback_preparing))
            } else {
                FloeCapsuleAction(
                    label = stringResource(
                        if (playing) R.string.meeting_ui_pause_playback else R.string.meeting_ui_play,
                    ),
                    onClick = onToggle,
                )
            }
        }
    }
}

@Composable
private fun MeetingPlaybackCard(
    material: MeetingMaterial,
    state: MeetingPlayerState?,
    loading: Boolean,
    error: MeetingError?,
    onToggle: () -> Unit,
    onStop: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Floe.colors.groupedSurface)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            IconGlyph(FloeIcons.PlayRuns, Floe.colors.accent, 18.dp)
            FloeText(
                text = stringResource(R.string.meeting_ui_playback_now, material.displayName),
                style = Floe.typography.bodyEmphasized,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            FloeText(
                text = stringResource(
                    R.string.meeting_ui_playback_position,
                    meetingDurationLabel(state?.positionMillis ?: 0L),
                    meetingDurationLabel(state?.durationMillis ?: material.durationMillis),
                ),
                style = Floe.typography.evidence,
                color = Floe.colors.secondaryLabel,
            )
        }
        if (loading || state == null || state.status == MeetingPlayerStatus.PREPARING) {
            FloeStatusLine(
                icon = FloeIcons.Clock,
                text = stringResource(R.string.meeting_ui_playback_preparing),
                color = Floe.colors.secondaryLabel,
            )
        }
        error?.let { MeetingErrorBanner(text = meetingErrorText(it)) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FloeCapsuleAction(
                label = stringResource(
                    if (state?.status == MeetingPlayerStatus.PLAYING) {
                        R.string.meeting_ui_pause_playback
                    } else {
                        R.string.meeting_ui_play
                    },
                ),
                onClick = onToggle,
                enabled = !loading && error == null,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.meeting_ui_stop_playback),
                onClick = onStop,
                tint = Floe.colors.destructive,
            )
        }
    }
}

@Composable
private fun MeetingTranscriptionSection(
    manager: MeetingTranscriptionManager,
    state: MeetingTranscriptionState,
    cleanupFailure: MeetingTranscriptionCleanupFailure?,
    meetingId: String,
    detail: MeetingDetail,
    selectedMaterialId: String?,
    transcriptionMeetingTitle: String?,
    onSelectMaterial: (String) -> Unit,
    onReloadMeeting: () -> Unit,
    onAcknowledgeCleanupFailure: () -> Unit,
    onOpenOtherMeeting: (String) -> Unit,
) {
    val transcription = detail.transcription
    val playableMaterials = remember(detail.materials) {
        meetingTranscriptionPlayableMaterials(detail)
    }
    val anyRunning = meetingTranscriptionIsRunning(state.phase)
    val session = state.session
    val sameMeetingRunning = anyRunning && session?.meetingId == meetingId
    val otherMeetingRunning = anyRunning && session != null && session.meetingId != meetingId
    val transcriptBoundElsewhere = transcription.segments.isNotEmpty() &&
        transcription.materialId != null &&
        transcription.materialId != selectedMaterialId

    var readiness by remember(meetingId, selectedMaterialId) {
        mutableStateOf<MeetingTranscriptionReadiness?>(null)
    }
    var checking by remember(meetingId, selectedMaterialId) { mutableStateOf(false) }
    var checkNonce by remember(meetingId) { mutableStateOf(0) }
    var startFailure by remember(meetingId) { mutableStateOf<MeetingTranscriptionFailure?>(null) }
    var cancelVisible by remember(meetingId) { mutableStateOf(false) }
    var cancelTooLate by remember(meetingId) { mutableStateOf(false) }

    LaunchedEffect(anyRunning) {
        if (!anyRunning) {
            startFailure = null
            cancelTooLate = false
        }
    }

    LaunchedEffect(
        meetingId,
        selectedMaterialId,
        transcription.revision,
        checkNonce,
        anyRunning,
    ) {
        val materialId = selectedMaterialId
        if (materialId == null || anyRunning) {
            readiness = null
            checking = false
            return@LaunchedEffect
        }
        checking = true
        readiness = null
        try {
            readiness = manager.readiness(meetingId, materialId)
        } finally {
            checking = false
        }
    }

    FloeSettingsSectionCard(title = stringResource(R.string.meeting_ui_transcription_section)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (transcription.segments.isEmpty() && playableMaterials.isEmpty()) {
                MeetingInlineEmpty(
                    icon = FloeIcons.Document,
                    title = stringResource(R.string.meeting_ui_transcription_empty_title),
                    body = stringResource(R.string.meeting_ui_transcription_no_playable),
                )
            } else {
                if (transcription.segments.isNotEmpty()) {
                    val sourceName = transcription.materialId?.let { id ->
                        detail.materials.firstOrNull { it.id == id }?.displayName
                    }
                    FloeText(
                        text = stringResource(
                            R.string.meeting_ui_transcription_meta,
                            transcription.segments.size,
                            transcription.revision,
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    sourceName?.let {
                        FloeText(
                            text = stringResource(R.string.meeting_ui_transcription_source, it),
                            style = Floe.typography.metadata,
                            color = Floe.colors.tertiaryLabel,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    transcription.segments.forEachIndexed { index, segment ->
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                FloeText(
                                    text = segment.speaker?.let {
                                        stringResource(R.string.meeting_ui_transcription_speaker, it)
                                    } ?: stringResource(R.string.meeting_ui_transcription_unknown_speaker),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                                FloeText(
                                    text = stringResource(
                                        R.string.meeting_ui_transcription_time,
                                        meetingDurationLabel(segment.startMillis),
                                        meetingDurationLabel(segment.endMillis),
                                    ),
                                    style = Floe.typography.evidence,
                                    color = Floe.colors.tertiaryLabel,
                                )
                            }
                            FloeText(segment.text, style = Floe.typography.body)
                        }
                        if (index != transcription.segments.lastIndex) FloeDivider()
                    }
                } else if (playableMaterials.isNotEmpty()) {
                    MeetingInlineEmpty(
                        icon = FloeIcons.Document,
                        title = stringResource(R.string.meeting_ui_transcription_empty_title),
                        body = stringResource(R.string.meeting_ui_transcription_empty_body),
                    )
                }

                if (playableMaterials.isNotEmpty()) {
                    FloeText(
                        text = stringResource(R.string.meeting_ui_transcription_choose),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        playableMaterials.forEach { material ->
                            FloeCapsuleAction(
                                label = if (material.id == selectedMaterialId) {
                                    "✓ ${material.displayName}"
                                } else {
                                    material.displayName
                                },
                                onClick = {
                                    startFailure = null
                                    cancelTooLate = false
                                    onSelectMaterial(material.id)
                                },
                                enabled = !anyRunning && !checking,
                                tint = if (material.id == selectedMaterialId) {
                                    Floe.colors.accent
                                } else {
                                    Floe.colors.secondaryLabel
                                },
                                showHairline = material.id == selectedMaterialId,
                            )
                        }
                    }
                }

                when {
                    otherMeetingRunning -> {
                        val title = transcriptionMeetingTitle
                        FloeStatusLine(
                            icon = FloeIcons.Clock,
                            text = title?.let {
                                stringResource(R.string.meeting_ui_transcription_other_meeting, it)
                            } ?: stringResource(R.string.meeting_ui_transcription_other_meeting_unknown),
                            color = Floe.colors.pending,
                        )
                        session?.meetingId?.let { otherId ->
                            FloeCapsuleAction(
                                label = stringResource(R.string.meeting_ui_transcription_open_other),
                                onClick = { onOpenOtherMeeting(otherId) },
                            )
                        }
                    }

                    sameMeetingRunning -> {
                        val runningMaterialName = playableMaterials
                            .firstOrNull { it.id == session?.materialId }
                            ?.displayName
                        val progressText = when (state.phase) {
                            MeetingTranscriptionPhase.PREPARING ->
                                stringResource(R.string.meeting_ui_transcription_preparing)
                            MeetingTranscriptionPhase.FINALIZING ->
                                stringResource(R.string.meeting_ui_transcription_finalizing)
                            MeetingTranscriptionPhase.CANCELLING ->
                                stringResource(R.string.meeting_ui_transcription_cancelling)
                            MeetingTranscriptionPhase.TRANSCRIBING -> {
                                val running = state.session
                                if (running != null && running.totalChunks > 0) {
                                    stringResource(
                                        R.string.meeting_ui_transcription_running,
                                        (running.progress * 100.0).roundToInt(),
                                    )
                                } else {
                                    stringResource(R.string.meeting_ui_transcription_running_unknown)
                                }
                            }
                            else -> stringResource(R.string.meeting_ui_transcription_running_unknown)
                        }
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            FloeActivityIndicator(description = progressText)
                            FloeText(
                                text = progressText,
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                                modifier = Modifier.weight(1f),
                            )
                        }
                        runningMaterialName?.let {
                            FloeText(
                                text = stringResource(R.string.meeting_ui_transcription_source, it),
                                style = Floe.typography.metadata,
                                color = Floe.colors.tertiaryLabel,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        if (cancelTooLate) {
                            FloeStatusLine(
                                icon = FloeIcons.InfoCircle,
                                text = stringResource(R.string.meeting_ui_transcription_cancel_too_late),
                                color = Floe.colors.secondaryLabel,
                            )
                        }
                        FloeCapsuleAction(
                            label = stringResource(R.string.meeting_ui_transcription_cancel),
                            onClick = { cancelVisible = true },
                            enabled = state.phase != MeetingTranscriptionPhase.CANCELLING,
                            tint = Floe.colors.destructive,
                        )
                    }

                    else -> {
                        when (val ready = readiness) {
                            null -> if (checking) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    val checkingText =
                                        stringResource(R.string.meeting_ui_transcription_checking)
                                    FloeActivityIndicator(description = checkingText)
                                    FloeText(
                                        text = checkingText,
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                    )
                                }
                            }

                            is MeetingTranscriptionReadiness.Unavailable -> {
                                MeetingErrorBanner(
                                    text = stringResource(
                                        if (transcriptBoundElsewhere) {
                                            R.string.meeting_ui_transcription_other_source
                                        } else {
                                            meetingTranscriptionFailureTextRes(ready.failure)
                                        },
                                    ),
                                )
                                FloeCapsuleAction(
                                    label = stringResource(R.string.meeting_ui_transcription_retry),
                                    onClick = {
                                        startFailure = null
                                        checkNonce += 1
                                    },
                                    enabled = !checking,
                                )
                            }

                            is MeetingTranscriptionReadiness.Ready -> {
                                FloeText(
                                    text = stringResource(
                                        R.string.meeting_ui_transcription_provider,
                                        ready.providerName,
                                    ),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                                if (transcriptBoundElsewhere) {
                                    FloeStatusLine(
                                        icon = FloeIcons.WarningTriangle,
                                        text = stringResource(
                                            R.string.meeting_ui_transcription_other_source,
                                        ),
                                        color = Floe.colors.pending,
                                    )
                                }
                                FloeCapsuleAction(
                                    label = stringResource(R.string.meeting_ui_transcription_start),
                                    onClick = {
                                        startFailure = null
                                        cancelTooLate = false
                                        when (
                                            val result = manager.start(
                                                meetingId = meetingId,
                                                materialId = ready.materialId,
                                                expectedTranscriptionRevision =
                                                    ready.transcriptionRevision,
                                            )
                                        ) {
                                            is MeetingTranscriptionStart.Started -> Unit
                                            is MeetingTranscriptionStart.Busy ->
                                                startFailure = result.failure
                                            is MeetingTranscriptionStart.Rejected ->
                                                startFailure = result.failure
                                        }
                                    },
                                    enabled = meetingTranscriptionCanStart(
                                        detail = detail,
                                        selectedMaterialId = selectedMaterialId,
                                        readiness = readiness,
                                        state = state,
                                    ),
                                )
                            }
                        }

                        startFailure?.let { failure ->
                            MeetingErrorBanner(
                                text = stringResource(meetingTranscriptionFailureTextRes(failure)),
                            )
                        }
                    }
                }

                if (!anyRunning) {
                    when (state.phase) {
                        MeetingTranscriptionPhase.COMPLETED -> {
                            if (state.session?.meetingId == meetingId) {
                                MeetingNoticeBanner(
                                    text = stringResource(R.string.meeting_ui_transcription_completed),
                                )
                            }
                        }
                        MeetingTranscriptionPhase.CANCELLED -> {
                            if (state.session?.meetingId == meetingId) {
                                val failure = state.failure
                                when {
                                    failure?.reason == "cancelUnconfirmed" -> {
                                        MeetingErrorBanner(
                                            text = stringResource(
                                                R.string.meeting_ui_transcription_cancel_unconfirmed,
                                            ),
                                        )
                                    }
                                    failure != null -> {
                                        MeetingErrorBanner(
                                            text = stringResource(
                                                meetingTranscriptionFailureTextRes(failure),
                                            ),
                                        )
                                    }
                                    else -> {
                                        FloeStatusLine(
                                            icon = FloeIcons.InfoCircle,
                                            text = stringResource(
                                                R.string.meeting_ui_transcription_cancelled,
                                            ),
                                            color = Floe.colors.secondaryLabel,
                                        )
                                    }
                                }
                            }
                        }
                        MeetingTranscriptionPhase.FAILED -> {
                            if (state.session?.meetingId == meetingId) {
                                state.failure?.let { failure ->
                                    val stale = failure.code ==
                                        MeetingTranscriptionFailureCode.STALE_REVISION
                                    MeetingErrorBanner(
                                        text = stringResource(
                                            meetingTranscriptionFailureTextRes(failure),
                                        ),
                                        actionLabel = if (stale) {
                                            stringResource(R.string.meeting_ui_transcription_reload)
                                        } else {
                                            null
                                        },
                                        onAction = if (stale) onReloadMeeting else null,
                                    )
                                }
                            }
                        }
                        else -> Unit
                    }

                    // Durable recovery for attempts that never produced a
                    // transcript (interruption, failure or cancellation —
                    // including across a process restart). The retry carries
                    // the exact meeting/material/checkpoint the attempt
                    // started with; it never resumes a provider operation.
                    meetingTranscriptionRetryTarget(detail, state)?.let { attempt ->
                        FloeStatusLine(
                            icon = FloeIcons.WarningTriangle,
                            text = stringResource(
                                when (attempt.phase) {
                                    MeetingTranscriptionLastAttemptPhase.RUNNING ->
                                        R.string.meeting_ui_transcription_interrupted
                                    MeetingTranscriptionLastAttemptPhase.CANCELLED ->
                                        R.string.meeting_ui_transcription_attempt_cancelled
                                    MeetingTranscriptionLastAttemptPhase.FAILED ->
                                        R.string.meeting_ui_transcription_attempt_failed
                                },
                            ),
                            color = Floe.colors.pending,
                        )
                        FloeText(
                            text = stringResource(R.string.meeting_ui_transcription_retry_note),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                        FloeCapsuleAction(
                            label = stringResource(R.string.meeting_ui_transcription_retry_start),
                            onClick = {
                                startFailure = null
                                cancelTooLate = false
                                when (
                                    val result = manager.start(
                                        meetingId = meetingId,
                                        materialId = attempt.materialId,
                                        expectedTranscriptionRevision =
                                            attempt.expectedTranscriptionRevision,
                                    )
                                ) {
                                    is MeetingTranscriptionStart.Started -> Unit
                                    is MeetingTranscriptionStart.Busy ->
                                        startFailure = result.failure
                                    is MeetingTranscriptionStart.Rejected ->
                                        startFailure = result.failure
                                }
                            },
                            enabled = !checking,
                        )
                    }
                }
            }

            cleanupFailure?.takeIf { it.meetingId == meetingId }?.let {
                MeetingErrorBanner(
                    text = stringResource(R.string.meeting_ui_transcription_cleanup_failed),
                    actionLabel = stringResource(R.string.meeting_ui_transcription_dismiss),
                    onAction = onAcknowledgeCleanupFailure,
                )
            }

            FloeText(
                text = stringResource(R.string.meeting_ui_transcription_service_note),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
        }
    }

    if (cancelVisible) {
        FloeConfirmDialog(
            title = stringResource(R.string.meeting_ui_transcription_cancel_title),
            message = stringResource(R.string.meeting_ui_transcription_cancel_body),
            confirmLabel = stringResource(R.string.meeting_ui_transcription_cancel_confirm),
            dismissLabel = stringResource(R.string.meeting_ui_transcription_keep_running),
            onConfirm = {
                cancelVisible = false
                if (manager.cancel() == MeetingTranscriptionCancelResult.TOO_LATE) {
                    cancelTooLate = true
                }
            },
            onDismiss = { cancelVisible = false },
        )
    }
}

@Composable
private fun MeetingDeleteSection(
    busy: Boolean,
    error: MeetingError?,
    onDelete: () -> Unit,
) {
    FloeSettingsSectionCard(title = null) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (busy) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeActivityIndicator(description = stringResource(R.string.meeting_ui_deleting))
                    FloeText(
                        stringResource(R.string.meeting_ui_deleting),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
            error?.let { MeetingErrorBanner(text = meetingErrorText(it)) }
            FloeCapsuleAction(
                label = stringResource(R.string.meeting_ui_delete),
                onClick = onDelete,
                enabled = !busy,
                tint = Floe.colors.destructive,
            )
        }
    }
}

@Composable
private fun MeetingInlineEmpty(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    body: String? = null,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        IconGlyph(icon, Floe.colors.tertiaryLabel, 26.dp)
        FloeText(title, style = Floe.typography.bodyEmphasized, color = Floe.colors.secondaryLabel)
        body?.let {
            FloeText(
                text = it,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.widthIn(max = 360.dp),
            )
        }
    }
}

@Composable
private fun MeetingErrorBanner(
    text: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.destructive.copy(alpha = 0.10f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(FloeIcons.WarningTriangle, Floe.colors.destructive, 18.dp)
        FloeText(
            text = text,
            style = Floe.typography.metadata,
            color = Floe.colors.destructive,
            modifier = Modifier.weight(1f),
        )
        if (actionLabel != null && onAction != null) {
            FloeCapsuleAction(
                label = actionLabel,
                onClick = onAction,
                tint = Floe.colors.destructive,
            )
        }
    }
}

@Composable
private fun MeetingRetainedTakeBanner(
    material: MeetingMaterial,
    modifier: Modifier = Modifier,
) {
    val explanation = stringResource(
        if (material.status == MeetingMaterialStatus.MISSING) {
            R.string.meeting_ui_record_retained_missing
        } else {
            R.string.meeting_ui_record_retained_incomplete
        },
    )
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.pending.copy(alpha = 0.10f))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(FloeIcons.WarningTriangle, Floe.colors.pending, 18.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            FloeText(
                text = material.displayName,
                style = Floe.typography.bodyEmphasized,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            FloeText(
                text = explanation,
                style = Floe.typography.metadata,
                color = Floe.colors.label,
            )
        }
    }
}

@Composable
private fun MeetingNoticeBanner(
    text: String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.success.copy(alpha = 0.10f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconGlyph(FloeIcons.CheckCircle, Floe.colors.success, 18.dp)
        FloeText(
            text = text,
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun MeetingTitleDialog(
    title: String,
    fieldLabel: String,
    confirmLabel: String,
    busyLabelRes: Int,
    value: String,
    onValueChange: (String) -> Unit,
    busy: Boolean,
    error: MeetingError?,
    confirmEnabled: Boolean,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    CupertinoAlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { FloeText(title, style = Floe.typography.section) },
        message = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloePlainFormField(
                    label = fieldLabel,
                    value = value,
                    onValueChange = onValueChange,
                    enabled = !busy,
                    singleLine = true,
                )
                if (busy) {
                    val busyLabel = stringResource(busyLabelRes)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FloeActivityIndicator(description = busyLabel)
                        FloeText(
                            busyLabel,
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
                error?.let {
                    FloeStatusLine(
                        icon = FloeIcons.WarningTriangle,
                        text = meetingErrorText(it),
                        color = Floe.colors.destructive,
                    )
                }
            }
        },
        buttons = {
            cancel(onClick = { if (!busy) onDismiss() }) {
                FloeText(
                    stringResource(R.string.meeting_ui_cancel),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.accent,
                )
            }
            default(onClick = { if (!busy && confirmEnabled) onConfirm() }) {
                FloeText(
                    confirmLabel,
                    style = Floe.typography.bodyEmphasized,
                    color = if (!busy && confirmEnabled) Floe.colors.accent else Floe.colors.tertiaryLabel,
                )
            }
        },
    )
}

@Composable
private fun MeetingLeaveNotesDialog(
    canSave: Boolean,
    saving: Boolean,
    onSave: () -> Unit,
    onDiscard: () -> Unit,
    onStay: () -> Unit,
) {
    CupertinoAlertDialog(
        onDismissRequest = { if (!saving) onStay() },
        title = { FloeText(stringResource(R.string.meeting_ui_unsaved_leave_title), style = Floe.typography.section) },
        message = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(
                    stringResource(R.string.meeting_ui_unsaved_leave_body),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                if (saving) {
                    FloeActivityIndicator(description = stringResource(R.string.meeting_ui_notes_saving))
                }
            }
        },
        buttons = {
            cancel(onClick = { if (!saving) onStay() }) {
                FloeText(
                    stringResource(R.string.meeting_ui_leave_stay),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.accent,
                )
            }
            if (canSave) {
                default(onClick = { if (!saving) onSave() }) {
                    FloeText(
                        stringResource(R.string.meeting_ui_leave_save),
                        style = Floe.typography.bodyEmphasized,
                        color = Floe.colors.accent,
                    )
                }
            }
            destructive(onClick = { if (!saving) onDiscard() }) {
                FloeText(
                    stringResource(R.string.meeting_ui_leave_discard),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.destructive,
                )
            }
        },
    )
}

@Composable
private fun MeetingLeaveRecordingDialog(
    meetingTitle: String?,
    stopping: Boolean,
    onContinueBackground: () -> Unit,
    onStay: () -> Unit,
    onStop: () -> Unit,
) {
    CupertinoAlertDialog(
        onDismissRequest = { if (!stopping) onStay() },
        title = { FloeText(stringResource(R.string.meeting_ui_leave_recording_title), style = Floe.typography.section) },
        message = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(
                    text = meetingTitle?.let {
                        stringResource(R.string.meeting_ui_leave_recording_body, it)
                    } ?: stringResource(R.string.meeting_ui_leave_recording_body_unknown),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                if (stopping) {
                    FloeActivityIndicator(description = stringResource(R.string.meeting_ui_record_stopping))
                }
            }
        },
        buttons = {
            cancel(onClick = { if (!stopping) onStay() }) {
                FloeText(
                    stringResource(R.string.meeting_ui_leave_stay_page),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.accent,
                )
            }
            default(onClick = { if (!stopping) onContinueBackground() }) {
                FloeText(
                    stringResource(R.string.meeting_ui_leave_background),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.accent,
                )
            }
            destructive(onClick = { if (!stopping) onStop() }) {
                FloeText(
                    stringResource(R.string.meeting_ui_leave_stop_recording),
                    style = Floe.typography.bodyEmphasized,
                    color = Floe.colors.destructive,
                )
            }
        },
    )
}

@Composable
private fun meetingErrorText(error: MeetingError): String =
    stringResource(meetingErrorResource(error.code))

private fun meetingDateLabel(millis: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(millis))

private fun recordLiveError(
    explicit: MeetingError?,
    state: MeetingRecordingState,
    meetingId: String,
): MeetingError? {
    if (explicit != null) return explicit
    val error = state.error ?: return null
    if (state.meetingId == null || state.meetingId == meetingId) return error
    return null
}

/* ------------------------------------------------------------------------- */
/* Pure logic helpers (unit tested in MeetingDestinationLogicTest)            */
/* ------------------------------------------------------------------------- */

/**
 * Notes editor state with optimistic revision checks.
 *
 * [draft] is always the user's current text. [base] is the last server text
 * this editor knows; [revision] is the expected `notesRevision`. A conflict
 * never replaces [draft]: it records [recovery] and the newest server values
 * so the user can explicitly reload or restore.
 */
internal data class MeetingNotesUiState(
    val draft: String = "",
    val base: String = "",
    val revision: Long = 0L,
    val conflict: Boolean = false,
    val recovery: String? = null,
    val latestNotes: String? = null,
    val latestRevision: Long? = null,
) {
    val dirty: Boolean get() = draft != base
    val canSave: Boolean get() = dirty && !conflict
    val canRestore: Boolean get() = recovery != null && recovery != draft

    fun edited(value: String): MeetingNotesUiState = if (conflict) {
        copy(draft = value, recovery = value)
    } else {
        copy(draft = value)
    }

    fun afterLoad(serverNotes: String, serverRevision: Long): MeetingNotesUiState {
        if (serverRevision == revision) {
            return if (!dirty && !conflict) {
                copy(draft = serverNotes, base = serverNotes)
            } else {
                this
            }
        }
        return if (!dirty && !conflict) {
            copy(
                draft = serverNotes,
                base = serverNotes,
                revision = serverRevision,
                latestNotes = null,
                latestRevision = null,
            )
        } else {
            copy(
                conflict = true,
                recovery = recovery ?: draft,
                latestNotes = serverNotes,
                latestRevision = serverRevision,
            )
        }
    }

    fun afterConflict(serverNotes: String, serverRevision: Long): MeetingNotesUiState = copy(
        conflict = true,
        recovery = recovery ?: draft,
        latestNotes = serverNotes,
        latestRevision = serverRevision,
    )

    fun reloadLatest(serverNotes: String, serverRevision: Long): MeetingNotesUiState = copy(
        draft = serverNotes,
        base = serverNotes,
        revision = serverRevision,
        conflict = false,
        latestNotes = null,
        latestRevision = null,
    )

    fun restore(serverNotes: String, serverRevision: Long): MeetingNotesUiState = copy(
        draft = recovery ?: draft,
        base = serverNotes,
        revision = serverRevision,
        conflict = false,
        latestNotes = null,
        latestRevision = null,
    )

    fun afterSave(savedNotes: String, savedRevision: Long): MeetingNotesUiState = copy(
        draft = savedNotes,
        base = savedNotes,
        revision = savedRevision,
        conflict = false,
        recovery = null,
        latestNotes = null,
        latestRevision = null,
    )

    fun discarded(): MeetingNotesUiState = copy(
        draft = base,
        conflict = false,
        recovery = null,
        latestNotes = null,
        latestRevision = null,
    )
}

internal fun meetingRecordingActive(phase: MeetingRecordingPhase): Boolean =
    phase == MeetingRecordingPhase.STARTING ||
        phase == MeetingRecordingPhase.RECORDING ||
        phase == MeetingRecordingPhase.PAUSED ||
        phase == MeetingRecordingPhase.STOPPING

internal fun meetingCanStartRecording(
    phase: MeetingRecordingPhase,
    microphoneGranted: Boolean,
): Boolean = microphoneGranted && !meetingRecordingActive(phase)

/**
 * Stop is successful only when the backend returned a finalized, playable
 * material. INCOMPLETE and MISSING are retained originals, not success, and
 * must keep the user on the page until they choose to leave.
 */
internal fun meetingStopSucceeded(
    status: MeetingMaterialStatus,
    isPlayable: Boolean,
): Boolean = status == MeetingMaterialStatus.COMPLETED && isPlayable

internal fun meetingLeaveNeedsRecordingPrompt(
    phase: MeetingRecordingPhase,
    activeMeetingId: String?,
    leavingMeetingId: String?,
    leavingPage: Boolean,
): Boolean {
    if (!meetingRecordingActive(phase)) return false
    if (leavingPage) return true
    return leavingMeetingId != null && activeMeetingId == leavingMeetingId
}

internal fun meetingDurationLabel(durationMillis: Long): String {
    val totalSeconds = durationMillis.coerceAtLeast(0L) / 1_000L
    val hours = totalSeconds / 3_600L
    val minutes = (totalSeconds % 3_600L) / 60L
    val seconds = totalSeconds % 60L
    return if (hours > 0L) {
        "$hours:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}"
    } else {
        "$minutes:${seconds.toString().padStart(2, '0')}"
    }
}

/** One export/share attempt at a time, and only for an explicitly selected meeting. */
internal fun meetingExportCanStart(busy: Boolean, meetingId: String?): Boolean =
    !busy && !meetingId.isNullOrBlank()

/**
 * A write/share outcome belongs to the page only while the meeting it was
 * prepared for is still the selected one. A late result for another meeting
 * is dropped rather than presented as success for the new selection.
 */
internal fun meetingExportBelongsToCurrentMeeting(
    currentMeetingId: String?,
    requestedMeetingId: String,
): Boolean = currentMeetingId != null && currentMeetingId == requestedMeetingId

/**
 * The assistant may start only when the real model projection is usable, this
 * meeting has notes or a transcript, and no turn is already active.
 */
internal fun meetingAssistantContextReady(detail: MeetingDetail): Boolean =
    detail.notes.isNotBlank() ||
        detail.transcription.segments.any { it.text.isNotBlank() }

internal fun meetingAssistantCanSend(
    availability: MeetingAssistantAvailability,
    active: MeetingAssistantTurnView?,
    contextReady: Boolean,
): Boolean = contextReady &&
    active == null &&
    availability is MeetingAssistantAvailability.Ready

/** Never overwrite an unsaved or conflicted notes editor with an AI answer. */
internal fun meetingAssistantCanInsertNotes(
    notesDirty: Boolean,
    notesConflict: Boolean,
    notesBusy: Boolean,
): Boolean = !notesDirty && !notesConflict && !notesBusy

/** Deterministic append used by the explicit "Add to notes" action. */
internal fun meetingAssistantAppendText(
    existingNotes: String,
    heading: String,
    text: String,
): String {
    val body = text.trim()
    if (body.isEmpty()) return existingNotes
    val block = heading.trim().let { if (it.isEmpty()) body else "$it\n$body" }
    val base = existingNotes.trimEnd()
    return if (base.isEmpty()) block else "$base\n\n$block"
}

internal fun meetingAssistantKindResource(action: MeetingAssistantAction): Int = when (action) {
    MeetingAssistantAction.ASK -> R.string.meeting_ui_assistant_kind_ask
    MeetingAssistantAction.MINUTES -> R.string.meeting_ui_assistant_kind_minutes
    MeetingAssistantAction.TODOS -> R.string.meeting_ui_assistant_kind_todos
}

internal fun meetingAssistantFailureResource(code: MeetingAssistantFailureCode): Int = when (code) {
    MeetingAssistantFailureCode.RUNTIME_UNAVAILABLE ->
        R.string.meeting_ui_assistant_runtime_unavailable
    MeetingAssistantFailureCode.PROVIDERS_NOT_READY ->
        R.string.meeting_ui_assistant_providers_not_ready
    MeetingAssistantFailureCode.NO_TEXT_MODEL -> R.string.meeting_ui_assistant_no_model
    MeetingAssistantFailureCode.MODEL_UNAVAILABLE ->
        R.string.meeting_ui_assistant_model_unavailable
    MeetingAssistantFailureCode.NO_CONTEXT ->
        R.string.meeting_ui_assistant_context_empty_body
    MeetingAssistantFailureCode.INVALID_QUESTION ->
        R.string.meeting_ui_assistant_invalid_question
    MeetingAssistantFailureCode.PROMPT_TOO_LARGE -> R.string.meeting_ui_assistant_too_long
    MeetingAssistantFailureCode.BUSY -> R.string.meeting_ui_assistant_busy
    MeetingAssistantFailureCode.CONTEXT_UNAVAILABLE ->
        R.string.meeting_ui_assistant_context_error
    MeetingAssistantFailureCode.LAUNCH_REFUSED ->
        R.string.meeting_ui_assistant_launch_refused
    MeetingAssistantFailureCode.LAUNCH_FAILED -> R.string.meeting_ui_assistant_launch_failed
    MeetingAssistantFailureCode.STREAM_LOST -> R.string.meeting_ui_assistant_stream_lost
    MeetingAssistantFailureCode.RESULT_UNREADABLE ->
        R.string.meeting_ui_assistant_result_unreadable
    MeetingAssistantFailureCode.RUN_FAILED -> R.string.meeting_ui_assistant_run_failed
    MeetingAssistantFailureCode.RUN_CANCELLED ->
        R.string.meeting_ui_assistant_run_cancelled
    MeetingAssistantFailureCode.NO_ANSWER -> R.string.meeting_ui_assistant_no_answer
    MeetingAssistantFailureCode.STILL_RUNNING -> R.string.meeting_ui_assistant_still_running
    MeetingAssistantFailureCode.CANCEL_REFUSED ->
        R.string.meeting_ui_assistant_cancel_refused
    MeetingAssistantFailureCode.HISTORY_UNAVAILABLE ->
        R.string.meeting_ui_assistant_history_unreadable
    MeetingAssistantFailureCode.STORE_FAILED -> R.string.meeting_ui_assistant_store_failed
}

@Composable
private fun meetingAssistantFailureText(failure: MeetingAssistantFailure): String =
    stringResource(meetingAssistantFailureResource(failure.code))

private fun meetingAssistantTimeLabel(millis: Long): String =
    if (millis <= 0L) {
        ""
    } else {
        DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(millis))
    }

internal fun meetingErrorResource(code: MeetingErrorCode): Int = when (code) {
    MeetingErrorCode.PERMISSION_REQUIRED -> R.string.meeting_ui_error_permission
    MeetingErrorCode.NOT_FOUND -> R.string.meeting_ui_error_not_found
    MeetingErrorCode.INVALID_IDENTIFIER -> R.string.meeting_ui_error_invalid_identifier
    MeetingErrorCode.INVALID_INPUT -> R.string.meeting_ui_error_invalid_input
    MeetingErrorCode.CONFLICT -> R.string.meeting_ui_error_conflict
    MeetingErrorCode.SOURCE_UNAVAILABLE -> R.string.meeting_ui_error_source_unavailable
    MeetingErrorCode.UNSUPPORTED_MEDIA -> R.string.meeting_ui_error_unsupported_media
    MeetingErrorCode.CORRUPT_MEDIA -> R.string.meeting_ui_error_corrupt_media
    MeetingErrorCode.TOO_LARGE -> R.string.meeting_ui_error_too_large
    MeetingErrorCode.STORAGE_FAILURE -> R.string.meeting_ui_error_storage
    MeetingErrorCode.RECORDING_BUSY -> R.string.meeting_ui_error_recording_busy
    MeetingErrorCode.RECORDING_NOT_ACTIVE -> R.string.meeting_ui_error_recording_not_active
    MeetingErrorCode.RECORDING_START_DENIED -> R.string.meeting_ui_error_recording_start_denied
    MeetingErrorCode.RECORDING_FAILED -> R.string.meeting_ui_error_recording_failed
    MeetingErrorCode.INTERRUPTED -> R.string.meeting_ui_error_interrupted
    MeetingErrorCode.PLAYBACK_FAILED -> R.string.meeting_ui_error_playback
    MeetingErrorCode.MISSING_MEDIA -> R.string.meeting_ui_error_missing_media
}

internal fun meetingRecordingStatusResource(phase: MeetingRecordingPhase): Int = when (phase) {
    MeetingRecordingPhase.IDLE -> R.string.meeting_ui_record_status_idle
    MeetingRecordingPhase.STARTING -> R.string.meeting_ui_record_status_starting
    MeetingRecordingPhase.RECORDING -> R.string.meeting_ui_record_status_recording
    MeetingRecordingPhase.PAUSED -> R.string.meeting_ui_record_status_paused
    MeetingRecordingPhase.STOPPING -> R.string.meeting_ui_record_status_stopping
    MeetingRecordingPhase.COMPLETED -> R.string.meeting_ui_record_status_completed
    MeetingRecordingPhase.FAILED -> R.string.meeting_ui_record_status_failed
}

internal fun meetingMaterialKindResource(kind: MeetingMaterialKind): Int = when (kind) {
    MeetingMaterialKind.RECORDING -> R.string.meeting_ui_kind_recording
    MeetingMaterialKind.AUDIO_IMPORT -> R.string.meeting_ui_kind_audio
    MeetingMaterialKind.VIDEO_IMPORT -> R.string.meeting_ui_kind_video
}

internal fun meetingMaterialStatusResource(status: MeetingMaterialStatus): Int = when (status) {
    MeetingMaterialStatus.RECORDING -> R.string.meeting_ui_material_status_recording
    MeetingMaterialStatus.PAUSED -> R.string.meeting_ui_material_status_paused
    MeetingMaterialStatus.FINALIZING -> R.string.meeting_ui_material_status_finalizing
    MeetingMaterialStatus.COMPLETED -> R.string.meeting_ui_material_status_completed
    MeetingMaterialStatus.INCOMPLETE -> R.string.meeting_ui_material_status_incomplete
    MeetingMaterialStatus.MISSING -> R.string.meeting_ui_material_status_missing
}

internal fun meetingMaterialTone(status: MeetingMaterialStatus): FloeBadgeTone = when (status) {
    MeetingMaterialStatus.COMPLETED -> FloeBadgeTone.SUCCESS
    MeetingMaterialStatus.RECORDING,
    MeetingMaterialStatus.PAUSED,
    MeetingMaterialStatus.FINALIZING,
    -> FloeBadgeTone.ACCENT
    MeetingMaterialStatus.INCOMPLETE,
    MeetingMaterialStatus.MISSING,
    -> FloeBadgeTone.DESTRUCTIVE
}

/**
 * Transcription is intentionally process-owned: page composition, rotation,
 * backgrounding and re-entry do not cancel it. Only the explicit Cancel action
 * does.
 */
internal fun meetingTranscriptionIsRunning(phase: MeetingTranscriptionPhase): Boolean =
    phase == MeetingTranscriptionPhase.PREPARING ||
        phase == MeetingTranscriptionPhase.TRANSCRIBING ||
        phase == MeetingTranscriptionPhase.FINALIZING ||
        phase == MeetingTranscriptionPhase.CANCELLING

/** Existing playable app-owned materials are the only transcription sources. */
internal fun meetingTranscriptionPlayableMaterials(detail: MeetingDetail): List<MeetingMaterial> =
    detail.materials.filter { it.isPlayable }

/**
 * Keeps an explicit choice while it is still playable; otherwise prefers the
 * material the durable transcript belongs to, then the newest playable file.
 */
internal fun meetingTranscriptionDefaultMaterial(
    detail: MeetingDetail,
    current: String?,
): String? {
    val playable = meetingTranscriptionPlayableMaterials(detail)
    if (current != null && playable.any { it.id == current }) return current
    val bound = detail.transcription.materialId
    if (bound != null && playable.any { it.id == bound }) return bound
    return playable.lastOrNull()?.id
}

/**
 * Start requires a ready cloud selection, a playable selected material and no
 * other attempt. A transcript bound to another material cannot be silently
 * replaced from this page.
 */
internal fun meetingTranscriptionCanStart(
    detail: MeetingDetail,
    selectedMaterialId: String?,
    readiness: MeetingTranscriptionReadiness?,
    state: MeetingTranscriptionState,
): Boolean {
    if (meetingTranscriptionIsRunning(state.phase)) return false
    val selected = selectedMaterialId ?: return false
    if (meetingTranscriptionPlayableMaterials(detail).none { it.id == selected }) return false
    val ready = readiness as? MeetingTranscriptionReadiness.Ready ?: return false
    if (ready.meetingId != detail.id || ready.materialId != selected) return false
    val bound = detail.transcription.materialId
    if (detail.transcription.segments.isNotEmpty() && bound != null && bound != selected) {
        return false
    }
    return ready.transcriptionRevision >= 0L
}

/**
 * The durable retry target for this meeting, if one is actionable.
 *
 * A recorded attempt is offered again only while it produced no transcript:
 * the moment a transcript is committed for its exact material the record is
 * cleared by the repository, and a transcript bound to another material is
 * protected from replacement rather than "retried". The attempt's material
 * must also still exist and be playable, and no attempt may be running.
 * A RUNNING phase here always means "live when last persisted", i.e. an
 * interruption such as process death — the provider operation behind it is
 * gone and the retry is a fresh full transcription.
 */
internal fun meetingTranscriptionRetryTarget(
    detail: MeetingDetail,
    state: MeetingTranscriptionState,
): MeetingTranscriptionLastAttempt? {
    if (meetingTranscriptionIsRunning(state.phase)) return null
    val transcription = detail.transcription
    val attempt = transcription.lastAttempt ?: return null
    if (transcription.revision != attempt.expectedTranscriptionRevision) return null
    if (transcription.segments.isNotEmpty()) return null
    if (detail.materials.none { it.id == attempt.materialId && it.isPlayable }) return null
    return attempt
}

/**
 * Page copy for typed failures. Pagination-shape failures share the bounded
 * [MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT] code with a precise
 * lane reason; they must say that nothing was saved, not that no speech was
 * found.
 */
internal fun meetingTranscriptionFailureTextRes(failure: MeetingTranscriptionFailure): Int = when {
    failure.code == MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT &&
        failure.reason == "transcriptTooLong" ->
        R.string.meeting_ui_transcription_too_long
    failure.code == MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT &&
        (failure.reason?.startsWith("transcriptPage") == true ||
            failure.reason == "transcriptCountMismatch") ->
        R.string.meeting_ui_transcription_incomplete
    failure.code == MeetingTranscriptionFailureCode.CANCELLED &&
        failure.reason == "cancelUnconfirmed" ->
        R.string.meeting_ui_transcription_cancel_unconfirmed
    else -> MeetingTranscriptionText.messageRes(failure)
}

private sealed interface MeetingLeaveTarget {
    data object Page : MeetingLeaveTarget
    data object ClearSelection : MeetingLeaveTarget
    data class Select(val id: String) : MeetingLeaveTarget
}

private class MeetingPlaybackSession(
    val materialId: String,
    val player: MeetingPlayer,
)

private val MeetingNotesUiStateSaver = listSaver<MeetingNotesUiState, Any>(
    save = { state ->
        listOf(
            state.draft,
            state.base,
            state.revision,
            state.conflict,
            state.recovery ?: "",
            state.recovery != null,
            state.latestNotes ?: "",
            state.latestNotes != null,
            state.latestRevision ?: -1L,
        )
    },
    restore = { values ->
        if (values.size < 9) {
            MeetingNotesUiState()
        } else {
            MeetingNotesUiState(
                draft = values[0] as? String ?: "",
                base = values[1] as? String ?: "",
                revision = values[2] as? Long ?: 0L,
                conflict = values[3] as? Boolean ?: false,
                recovery = if (values[5] as? Boolean == true) values[4] as? String else null,
                latestNotes = if (values[7] as? Boolean == true) values[6] as? String else null,
                latestRevision = (values[8] as? Long)?.takeIf { it >= 0L },
            )
        }
    },
)
