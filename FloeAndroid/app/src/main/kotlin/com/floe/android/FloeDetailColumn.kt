// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.InspectorRoute
import com.floe.android.design.MoreDestination
import com.floe.android.design.SidebarSelection
import com.floe.android.design.WorkbenchSelection
import com.floe.android.designintegration.ChatDesignIdentity
import com.floe.android.designintegration.ChatDesignSession
import com.floe.android.designintegration.PrivateChatDesignEntry
import com.floe.android.feature.canvas.ui.design.DesignWorkflowSheet
import com.floe.android.feature.conversation.AttachmentDesignRequest
import com.floe.android.feature.conversation.FloeConversationHistoryDestination
import com.floe.android.feature.conversation.FloeConversationPaneHost
import com.floe.android.feature.executiontarget.ExecutionTargetSheet
import com.floe.android.feature.toolresults.LocalToolResultDetailSource
import com.floe.android.feature.taskcontinuity.TaskContinuityBanner
import com.floe.android.feature.taskcontinuity.TaskContinuityPresentation
import com.floe.android.feature.taskcontinuity.TaskContinuitySheet
import com.floe.android.host.RuntimeHost

/**
 * Column 2 of the split: renders the selected workbench/more destination.
 * Like iOS `contentColumn`, the detail plane owns its toolbar; the temporary
 * third pane (inspector) lives INSIDE the detail row so the declared two
 * columns stay stable (iOS hit-test rationale, mirrored as structure).
 */
@Composable
fun FloeDetailColumn(
    selection: SidebarSelection,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
    inspectorRoute: InspectorRoute?,
    onInspectorDismiss: () -> Unit,
    onOpenSettingsSection: (String) -> Unit,
    onConversationBack: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    runtimeHost: RuntimeHost? = null,
    onConversationHolderBound: (String, com.floe.android.feature.conversation.ConversationFlowHolder) -> Unit = { _, _ -> },
    /** Home's Scheduled Tasks card opens the REAL Task Center route through
     * the shell's existing navigation/fence callback. Null hides the card
     * (fixtures/previews) instead of inventing a local route. */
    onOpenSchedules: (() -> Unit)? = null,
    /** One-shot signal produced ONLY by an admitted Home→TaskCenter commit;
     * opens the schedules sub-view without bypassing the outer route. */
    taskCenterSchedulesToken: Int = 0,
    /** Clears the one-shot signal after the Task Center really consumed it,
     * so re-entering Task Center later does not reopen schedules. */
    onTaskCenterSchedulesHandled: () -> Unit = {},
) {
    androidx.compose.runtime.LaunchedEffect(selection, runtimeHost) {
        if (selection == SidebarSelection.More(MoreDestination.NETWORK)) runtimeHost?.networkWorkbench?.enter()
        else runtimeHost?.networkWorkbench?.leave()
    }
    Box(modifier.fillMaxSize()) {
        when (selection) {
            is SidebarSelection.Workbench -> when (selection.selection) {
                WorkbenchSelection.NEW_TASK -> HomeLaunchpadPage(
                    compact = compact,
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                    onOpenSettingsSection = onOpenSettingsSection,
                    runtimeHost = runtimeHost,
                    onOpenSchedules = onOpenSchedules,
                )
                WorkbenchSelection.OVERVIEW -> TaskCenterDestination(
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                    compact = compact,
                    runtimeHost = runtimeHost,
                    openSchedulesToken = taskCenterSchedulesToken,
                    onSchedulesTokenHandled = onTaskCenterSchedulesHandled,
                )
                WorkbenchSelection.CONVERSATION -> FloePlaceholderPage(
                    title = stringResource(R.string.new_task),
                    icon = FloeIcons.Bubble,
                    message = stringResource(R.string.conversation_runtime_pending),
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                    compact = compact,
                )
            }
            is SidebarSelection.More -> when (selection.destination) {
                MoreDestination.NETWORK -> NetworkWorkbenchDestination(
                    host = runtimeHost, compact = compact,
                    showSidebarToggle = showSidebarToggle,
                    onNavigate = { if (compact) onOpenDrawer() else onExpandSidebar() },
                )
                MoreDestination.NOTES -> NotesDestination(showSidebarToggle, onExpandSidebar, onOpenDrawer, compact, onOpenSettingsSection)
                MoreDestination.CREATIVE -> CreativeDestination(
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                    compact = compact,
                )
                MoreDestination.REMOTE -> com.floe.android.host.remote.C05RemoteDestination(
                    host = runtimeHost,
                    compact = compact,
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                )
                MoreDestination.RDP -> com.floe.android.host.rdp.C05RDPDestination(
                    host = runtimeHost,
                    compact = compact,
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                )
                MoreDestination.MAIL -> com.floe.android.host.mail.C06MailDestination(
                    host = runtimeHost,
                    compact = compact,
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                )
                MoreDestination.CALENDAR -> com.floe.android.host.calendar.C06CalendarDestination(
                    host = runtimeHost,
                    compact = compact,
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                )
                MoreDestination.DEVICES -> com.floe.android.host.devicecommunication.C05DeviceCommunicationDestination(
                        host = runtimeHost,
                        compact = compact,
                        showSidebarToggle = showSidebarToggle,
                        onExpandSidebar = onExpandSidebar,
                        onOpenDrawer = onOpenDrawer,
                    )
                MoreDestination.SYSTEM_SERVICES -> com.floe.android.host.systemservices.C06SystemServicesDestination(
                    host = runtimeHost,
                    compact = compact,
                    showSidebarToggle = showSidebarToggle,
                    onExpandSidebar = onExpandSidebar,
                    onOpenDrawer = onOpenDrawer,
                )
                // Skills opens the Settings sheet at the Skills section
                // (handled in the shell's select); a direct route here shows
                // the same honest pending surface as other later goals.
                MoreDestination.SKILLS -> FloeTaskCenterPage(showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
                else -> FloePlaceholderPage(stringResource(R.string.app_name), FloeIcons.InfoCircle, stringResource(R.string.workspace_later_update), showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
            }
            is SidebarSelection.Workspace -> ProjectDetailPage(
                projectId = selection.workspaceId,
                showSidebarToggle = showSidebarToggle,
                onExpandSidebar = onExpandSidebar,
                onOpenDrawer = onOpenDrawer,
                compact = compact,
                runtimeHost = runtimeHost,
            )
            is SidebarSelection.Conversation -> ConversationDestination(
                conversationId = selection.conversationId,
                showSidebarToggle = showSidebarToggle,
                onExpandSidebar = onExpandSidebar,
                onOpenDrawer = onOpenDrawer,
                compact = compact,
                runtimeHost = runtimeHost,
                onHolderBound = onConversationHolderBound,
                onBackToOrigin = onConversationBack,
            )
        }
    }
}

/**
 * The real conversation surface. Resolves the caller-retained holder from
 * the host registry (never fabricates an id or an empty thread) and hosts
 * the measured-pane geometry wrapper owned by the app-pane geometry lane;
 * the host supplies the real holder and session, the wrapper measures the
 * actual slot and consumes insets exactly once.
 */
@Composable
private fun ConversationDestination(
    conversationId: String,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
    runtimeHost: RuntimeHost?,
    onHolderBound: (String, com.floe.android.feature.conversation.ConversationFlowHolder) -> Unit,
    onBackToOrigin: (() -> Unit)? = null,
) {
    val temporary = runtimeHost?.conversations?.activeTemporarySession()
        ?.takeIf { it.conversationId == conversationId }
    val holder = runtimeHost?.conversations?.holderFor(
        conversationId,
        isTemporary = temporary != null,
        incarnationId = temporary?.incarnationId,
        temporaryNativeRootEpoch = temporary?.nativeRootEpoch ?: -1L,
    )
    if (runtimeHost == null || holder == null) {
        FloePlaceholderPage(
            title = stringResource(R.string.chat),
            icon = FloeIcons.Bubble,
            message = stringResource(R.string.conversation_runtime_pending),
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            compact = compact,
        )
        return
    }
    // Load the durable thread once per holder binding; recomposition and
    // rotation reuse the same holder and never restart the load.
    androidx.compose.runtime.LaunchedEffect(holder.session) {
        runtimeHost.conversations.loadThread(holder.session)
    }
    // Report the EXACT holder instance this surface bound so the shell can
    // prove visible ownership for the privacy-clear invalidation (a
    // re-created same-id holder is a different instance and must never be
    // retired by a stale signal). The registry itself stays unobservable:
    // re-resolving through holderFor would silently re-create a deleted id
    // as an empty thread.
    androidx.compose.runtime.LaunchedEffect(holder) {
        onHolderBound(conversationId, holder)
    }
    val context = LocalContext.current
    val application = context.applicationContext as? FloeApplication
    val chatKindLabel = stringResource(R.string.design_app_target_chat)
    // App-owned private design session for THIS holder. It is created only
    // from the REAL persisted attachment identity the feature projected; the
    // binding keeps a fresh editor token and the native owner re-verifies the
    // attachment storage/bytes. The identity is saveable so a rotation reuses
    // the SAME retained controller instead of minting a second session.
    var designIdentity by rememberSaveable(
        conversationId,
        stateSaver = ChatDesignIdentitySaver,
    ) {
        mutableStateOf<ChatDesignIdentity?>(null)
    }
    // Key the retained-session resolution on the real temporary posture so a
    // rotation/first snapshot that arrives just AFTER composition can still
    // re-acquire the exact saved session (never a second token for the same
    // attachment).
    val holderTemporary = holder.snapshot.value?.isTemporary
    val designIsCurrent: (com.floe.android.feature.conversation.AttachmentDesignRequest) -> Boolean =
        { request ->
            val live = holder.snapshot.value
            PrivateChatDesignEntry.isEligible(
                request = request,
                holderConversationId = holder.conversationId,
                holderIsTemporary = live?.isTemporary,
                holderRetired = holder.retired,
            )
        }
    val onAttachmentDesign: ((AttachmentDesignRequest) -> Unit)? =
        if (application == null || temporary != null) {
            null
        } else {
            { request ->
                if (designIsCurrent(request)) {
                    val existing = designIdentity
                    val sameAttachment = existing != null &&
                        existing.conversationId == request.conversationId &&
                        existing.messageId == request.messageId &&
                        existing.attachmentId == request.attachmentId
                    if (!sameAttachment) {
                        designIdentity = PrivateChatDesignEntry.identity(request)
                    }
                }
            }
        }
    val designSession = remember(designIdentity, holder, holderTemporary) {
        val identity = designIdentity
        val app = application
        if (identity == null || app == null) {
            null
        } else {
            PrivateChatDesignEntry.reopen(
                sessions = app.designUi,
                identity = identity,
                title = identity.displayName,
                kindLabel = chatKindLabel,
                isCurrent = { designIsCurrent(identity.request()) },
            )
        }
    }
    var targetSheetVisible by rememberSaveable(conversationId) { mutableStateOf(false) }
    var continuitySheetVisible by rememberSaveable(conversationId) { mutableStateOf(false) }
    val targetState by runtimeHost.executionTargets.state.collectAsState()
    val continuityState by runtimeHost.taskContinuity.state.collectAsState()
    LaunchedEffect(conversationId, temporary) {
        if (temporary == null) runtimeHost.executionTargets.load(conversationId)
    }
    LaunchedEffect(conversationId, temporary) {
        if (temporary == null) runtimeHost.taskContinuity.load(conversationId)
    }
    Box(Modifier.fillMaxSize()) {
        // C02: the existing tool card's retained-result reader resolves its
        // source from the App-owned trusted client. No feature module opens
        // the bridge, a file or a tool executor.
        CompositionLocalProvider(
            LocalToolResultDetailSource provides runtimeHost.toolResults,
        ) {
            FloeConversationPaneHost(
                holder = holder,
                modifier = Modifier.fillMaxSize(),
                onBack = if (compact) (onBackToOrigin ?: onOpenDrawer) else null,
                onAttachmentDesign = onAttachmentDesign,
                onOpenExecutionTarget = if (temporary == null) ({
                    runtimeHost.executionTargets.load(conversationId)
                    targetSheetVisible = true
                }) else null,
                statusContent = {
                    if (temporary == null && TaskContinuityPresentation.shouldShowBanner(continuityState)) {
                        TaskContinuityBanner(
                            state = continuityState,
                            onClick = { continuitySheetVisible = true },
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                        )
                    }
                },
            )
        }
    }
    ExecutionTargetSheet(
        visible = targetSheetVisible && temporary == null,
        state = targetState,
        compact = compact,
        onDismiss = { targetSheetVisible = false },
        onInitialize = { kind, environmentID, hostID ->
            runtimeHost.executionTargets.initialize(kind, environmentID, hostID)
        },
        onCheckMigration = { kind, environmentID, hostID ->
            runtimeHost.executionTargets.checkMigration(kind, environmentID, hostID)
        },
        onBeginMigration = { kind, environmentID, hostID ->
            runtimeHost.executionTargets.beginMigration(kind, environmentID, hostID)
        },
        onCancelMigration = { runtimeHost.executionTargets.cancelMigration() },
        onApproveHostKey = { challengeID, accept, replaceChanged, expected ->
            runtimeHost.executionTargets.approveHostKey(
                challengeID, accept, replaceChanged, expected)
        },
        onDismissError = { runtimeHost.executionTargets.dismissError() },
        onDismissNotice = { runtimeHost.executionTargets.dismissNotice() },
        onDestinationChanged = { runtimeHost.executionTargets.clearPreview() },
        onRefresh = { runtimeHost.executionTargets.refresh() },
    )
    TaskContinuitySheet(
        visible = continuitySheetVisible && temporary == null,
        state = continuityState,
        compact = compact,
        onDismiss = { continuitySheetVisible = false },
        onResumePause = { runtimeHost.taskContinuity.resume() },
        // A durable wait without a live owner is resumed by the ORIGINAL
        // Continue path (run.retry): it re-parks the question/approval under
        // the real runtime instead of inventing a second answer route.
        onResumeTask = { runID ->
            // Resume the EXACT run that owns the durable wait; a task-level
            // snapshot can surface waits from more than one recent run.
            if (holder.snapshot.value?.selectedRunId != runID) {
                holder.selectRun(runID)
            }
            if (holder.retry(runID) == com.floe.android.feature.conversation.ConversationFlowResult.Accepted) {
                // Show the restored question or actual refusal on the task
                // surface instead of leaving it behind this stale overlay.
                continuitySheetVisible = false
            }
        },
        onReviewQuestion = { requestID ->
            // Re-read the ORIGINAL question through the existing host
            // command; its snapshot callback opens the existing question
            // sheet. A late answer still goes through question.answer only.
            runtimeHost.conversations.requestPendingQuestion(
                holder.session, requestID)
            continuitySheetVisible = false
        },
        onRefresh = { runtimeHost.taskContinuity.load(conversationId) },
    )
    designSession?.let { session ->
        DesignWorkflowSheet(
            controller = session.controller,
            onClosed = {
                application?.designUi?.release(session.controller)
                designIdentity = null
            },
        )
    }
    // A real leave/B replaces this holder; release the retained design
    // controller so a late native callback cannot act as conversation B.
    // A rotation only recreates composition and keeps the same holder/session.
    androidx.compose.runtime.DisposableEffect(holder) {
        onDispose {
            val changing = (context as? android.app.Activity)?.isChangingConfigurations == true
            if (!changing) {
                designSession?.let { session ->
                    application?.designUi?.release(session.controller)
                }
            }
        }
    }
}

/** Saveable exact identity of a private-chat design session. */
private val ChatDesignIdentitySaver =
    androidx.compose.runtime.saveable.listSaver<ChatDesignIdentity?, String>(
    save = { value ->
        value?.let {
            listOf(
                it.conversationId,
                it.messageId,
                it.attachmentId,
                it.displayName,
                it.isImage.toString(),
                it.sessionToken,
            )
        } ?: emptyList()
    },
    restore = { values ->
        if (values.size == 6) {
            ChatDesignIdentity(
                conversationId = values[0],
                messageId = values[1],
                attachmentId = values[2],
                displayName = values[3],
                isImage = values[4] == "true",
                sessionToken = values[5],
            )
        } else {
            null
        }
    },
)

/**
 * Task Center: the real conversation history surface (list/search/archive/
 * management) hosted by the history holder; loading and honest empty states
 * stay component-owned.
 */
@Composable
private fun TaskCenterDestination(
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
    runtimeHost: RuntimeHost?,
    openSchedulesToken: Int = 0,
    onSchedulesTokenHandled: () -> Unit = {},
) {
    if (runtimeHost == null) {
        FloeTaskCenterPage(showSidebarToggle, onExpandSidebar, onOpenDrawer, compact)
        return
    }
    // A background scheduled launch has no UI holder/event pump, so the
    // one-time shell-bind refresh cannot see its new conversation. Re-read
    // the durable history whenever Task Center is entered.
    LaunchedEffect(runtimeHost) {
        runtimeHost.conversations.reloadHistory()
    }
    // The Task Center surface owns its REAL sub-view switch: the default
    // list, the schedule destination, the archive sheet and the management
    // (selection/bulk) view all render the SAME produced history wire through
    // the destination component; back returns to the list. No phantom
    // destination, no empty callback.
    var historyMode by remember {
        mutableStateOf(com.floe.android.feature.conversation.HistoryDestinationMode.LIST)
    }
    // Local sub-view ONLY inside the already-committed Task Center route: the
    // outer sidebar selection, split view and temporary-chat fence stay
    // shell-owned. The token is produced only by an admitted Home→TaskCenter
    // navigation commit, so opening schedules can never bypass the fence.
    var showSchedules by rememberSaveable { mutableStateOf(false) }
    var handledSchedulesToken by rememberSaveable { mutableIntStateOf(0) }
    LaunchedEffect(openSchedulesToken) {
        if (openSchedulesToken > handledSchedulesToken) {
            handledSchedulesToken = openSchedulesToken
            showSchedules = true
            // Consume the shell-owned one-shot so a later visit to Task
            // Center does not open this sub-view again.
            onSchedulesTokenHandled()
        }
    }
    if (showSchedules) {
        com.floe.android.schedule.TaskScheduleDestination(
            host = runtimeHost,
            compact = compact,
            showSidebarToggle = showSidebarToggle,
            onBack = {
                showSchedules = false
                runtimeHost.conversations.reloadHistory()
            },
        )
    } else {
        Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
            FloeDetailToolbar(
                title = stringResource(R.string.task_center),
                showSidebarToggle = showSidebarToggle,
                onExpandSidebar = onExpandSidebar,
                onOpenDrawer = onOpenDrawer,
                compact = compact,
            )
            com.floe.android.schedule.ScheduledTasksSummaryCard(
                host = runtimeHost,
                onOpen = { showSchedules = true },
                modifier = Modifier.padding(
                    start = if (compact) 16.dp else 28.dp,
                    end = if (compact) 16.dp else 28.dp,
                    top = 8.dp,
                ),
            )
            FloeConversationHistoryDestination(
                holder = runtimeHost.conversations.historyHolder,
                mode = historyMode,
                modifier = Modifier.weight(1f),
                onBack = if (historyMode ==
                    com.floe.android.feature.conversation.HistoryDestinationMode.LIST
                ) null else { { historyMode =
                    com.floe.android.feature.conversation.HistoryDestinationMode.LIST } },
                onOpenArchive = {
                    historyMode = com.floe.android.feature.conversation.HistoryDestinationMode.ARCHIVE
                },
                onOpenManagement = {
                    historyMode = com.floe.android.feature.conversation.HistoryDestinationMode.MANAGE
                },
            )
        }
    }
}

@Composable
fun FloeTaskCenterPage(
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeDetailToolbar(
            title = stringResource(R.string.task_center),
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            compact = compact,
        )
        FloeUnavailableView(
            icon = FloeIcons.Checklist,
            title = stringResource(R.string.no_tasks_yet),
            description = stringResource(R.string.task_center_empty_note),
        )
    }
}

@Composable
fun FloePlaceholderPage(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    message: String,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
) {
    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeDetailToolbar(
            title = title,
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            compact = compact,
        )
        FloeUnavailableView(icon = icon, title = title, description = message)
    }
}

/**
 * Detail toolbar: centered title, sidebar affordance leading, actions slot.
 * `compact` is explicit: every compact detail surface (including placeholder
 * and Task Center routes) must pass it so the drawer opener is never omitted
 * (finish review F02).
 */
@Composable
fun FloeDetailToolbar(
    title: String,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    compact: Boolean,
    actions: (@Composable androidx.compose.foundation.layout.RowScope.() -> Unit)? = null,
) {
    val hasLeading = showSidebarToggle || compact
    FloeToolbar(
        title = title,
        background = Floe.colors.readingSurface,
        navigation = if (hasLeading) {
            {
                if (showSidebarToggle) {
                    FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.expand_task_list),
                        onClick = onExpandSidebar,
                    )
                } else {
                    FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.open_sidebar),
                        onClick = onOpenDrawer,
                    )
                }
            }
        } else null,
        actions = actions,
    )
}
