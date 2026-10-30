// SPDX-License-Identifier: MPL-2.0
//
// Root presentation destination for one conversation thread (⇄
// ThreadDetailView.body + stateToolbar + sheet hosts). The host embeds this
// inside the EXISTING stable split-view detail column (the module returns
// feature content with stable chrome/hit targets; it never owns the
// app-level scaffold, nav rail, navigation routes, inspector visibility or
// any backend). Wide (regular) vs compact (phone) adaptation follows the
// iOS idiom: the timeline fills the detail pane exactly like
// ThreadDetailView.threadScroll (LazyVStack leading + padding, NO per-row
// reading cap — Main's 2026-10-19 source-proven correction); chips/attachments
// scroll horizontally; the composer keeps its own separately reviewed centred
// chrome and stays pinned above the IME/safe area via the design-system
// composer insets.
//
// Visual honesty: layout is SOURCE-DERIVED (current Swift composition +
// G01 iPad captures). There are NO conversation-feature iPad captures in
// the ios-reference manifest yet (it is provider-flow evidence); exact
// missing captures are listed in the lane handoff for the next UI
// qualification. This stage therefore does not claim finished visual parity.

package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeChipMenu
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.CupertinoMenuEntry
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePopoverCard
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph

/**
 * The canonical thread destination. The host supplies and retains the
 * [holder] in RAM across configuration changes and publishes immutable
 * [ThreadUiState] projections into it; this composable reads only holder
 * state and calls holder actions (which translate to host effects).
 *
 * [paneGeometry] is the explicit G02 opt-in for a real split-view detail
 * pane. The default `null` keeps the G01/window-based behaviour for component
 * previews and any host that has not measured a pane yet;
 * [FloeConversationPaneHost] supplies the real measured values.
 */
@Composable
fun FloeConversationDestination(
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    paneGeometry: ConversationPaneGeometry? = null,
) {
    val state = holder.snapshot.value
    // Timeline density follows the ACTUAL pane when the host measured one;
    // a narrow split column inside a wide window must not keep tablet layout
    // just because the window is wide. The window fallback is only evaluated
    // for G01/component hosts that have not measured a pane.
    val isWide = paneGeometry?.let { it.width >= FloeLayout.PersistentTwoColumnMinWidth }
        ?: (LocalConfiguration.current.screenWidthDp.dp >= FloeLayout.PersistentTwoColumnMinWidth)

    Column(modifier = modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        ThreadTopBar(holder, onBack)
        FloeDivider()
        if (holder.threadSearchVisible) {
            ThreadSearchBar(holder)
        }

        if (state == null) {
            // Honest first-frame loading state (⇄ ProgressView while the
            // view model's load has not produced anything yet).
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                FloeActivityIndicator(description = stringResource(R.string.loading_cd))
            }
        } else {
            // ⇄ body order: checklist, intelligence strip, divider,
            // important-files strip, divider, timeline, compaction, error
            // banner, continuation bar, composer.
            state.checklist?.let { ThreadChecklistSection(holder) }
            if (state.plan != null || state.goal != null) ThreadIntelligenceSection(holder)
            FloeDivider()
            if (state.importantFiles.isNotEmpty()) {
                ImportantFilesStrip(
                    files = state.importantFiles,
                    // EXACTLY ONE effect per tap: the host's guarded
                    // workspace-file preview, carrying the actual projected
                    // path under the current session identity (never a dummy
                    // message/attachment id, never a placeholder open).
                    onOpenFile = { file -> holder.openImportantFile(file) },
                    onOpenAll = { holder.requestWorkspaceFilesInspector() },
                )
                FloeDivider()
            }
            ThreadTimeline(holder, isWide = isWide, modifier = Modifier.weight(1f))
            ThreadCompactionStatus(holder)
            ThreadErrorBanner(holder)
            ThreadContinuationBar(holder)
            UserQuestionWaitingBar(holder)
            if (state.isConversationMissing) {
                ConversationMissingPlaceholder()
            } else {
                ConversationComposerSection(
                    holder = holder,
                    onSend = { holder.send() },
                    onStop = { holder.cancel() },
                    paneGeometry = paneGeometry,
                )
            }
        }
    }

    // Sheet hosts (same surfaces the iOS view presents over the thread):
    GoalBuilderSheet(holder)
    PendingInputEditorSheet(holder)
    TemporaryChatAboutSheet(holder)
    ChildRunDetailSheet(holder)
    UsageDetailsPopover(holder)
    UserQuestionSheet(holder)
    // ⇄ ThreadComposerView `.sheet(isPresented: $isFullEditorPresented)`:
    // the expand destination over the SAME retained draft. Back/Done dismiss
    // only; the guarded send runs the holder's canonical send and closes the
    // sheet when the send actually started.
    ComposerFullEditorSheet(holder)
}

/* ---------------------------------- top bar ---------------------------------- */

@Composable
private fun ThreadTopBar(holder: ConversationFlowHolder, onBack: (() -> Unit)?) {
    val state = holder.snapshot.value
    val title = state?.taskTitle?.takeIf { it.isNotEmpty() } ?: stringResource(R.string.thread_title_default)
    var menuExpanded by remember(state?.session) { mutableStateOf(false) }
    FloeToolbar(
        title = title,
        navigation = onBack?.let { back ->
            {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.action_back),
                    onClick = back,
                    hairline = false,
                )
            }
        },
        actions = {
            if (state?.isTemporary == true) {
                TemporaryChatBadgeMenu(holder)
            }
            if (state != null) {
                val searchLabel = stringResource(R.string.thread_search_placeholder)
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .widthIn(min = FloeLayout.MinimumTarget)
                        .clickable { holder.beginThreadSearch() }
                        .semantics { contentDescription = searchLabel },
                    contentAlignment = Alignment.Center,
                ) {
                    IconGlyph(FloeIcons.Magnifier, Floe.colors.label, 18.dp)
                }
            }
            // Context usage ring (only when the window is known — never an
            // invented token count).
            val context = state?.contextUsage
            if (context != null && context.contextWindowTokens > 0) {
                val ringCd = stringResource(R.string.usage_view_context)
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable { holder.openUsageDetails(context) }
                        .semantics { contentDescription = ringCd },
                    contentAlignment = Alignment.Center,
                ) { ContextUsageRing(fraction = context.contextFraction) }
            }
            // Run state text.
            state?.let { s ->
                when {
                    s.selectedRunWaitingForJobs -> FloeText(
                        stringResource(R.string.state_waiting_background_work),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                    )
                    s.liveStateName != null -> FloeText(
                        runStateTitle(s.liveStateName),
                        style = Floe.typography.metadata,
                        color = floeStatusColor(FloeRunStateLocalizer.colorRole(s.liveStateName)),
                    )
                }
            }
            // Stop / Continue toolbar controls (⇄ stateToolbar).
            state?.let { s ->
                if (s.isRunning) {
                    val stopCd = stringResource(R.string.action_stop)
                    Box(
                        modifier = Modifier
                            .heightIn(min = FloeLayout.MinimumTarget)
                            .clickable { holder.cancel() }
                            .padding(horizontal = 8.dp)
                            .semantics { contentDescription = stopCd },
                        contentAlignment = Alignment.Center,
                    ) {
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                            IconGlyph(FloeIcons.StopSquare, Floe.colors.destructive, 15.dp)
                            FloeText(stopCd, style = Floe.typography.metadata, color = Floe.colors.destructive)
                        }
                    }
                } else if (s.canContinue) {
                    val continueCd = stringResource(R.string.action_continue)
                    Box(
                        modifier = Modifier
                            .heightIn(min = FloeLayout.MinimumTarget)
                            .clickable { holder.retry() }
                            .padding(horizontal = 8.dp)
                            .semantics { contentDescription = continueCd },
                        contentAlignment = Alignment.Center,
                    ) {
                        FloeText(continueCd, style = Floe.typography.metadata, color = Floe.colors.accent)
                    }
                }
            }
            // Overflow menu (⇄ inspectorButton set; temporary sessions only
            // get Progress — they bind no workspace/browser/terminal/change
            // resources, and the UI never shows bindings it never made).
            Box {
                val menuCd = stringResource(R.string.thread_inspector_menu)
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        // Icon-only toolbar targets need BOTH dimensions at the
                        // 48dp floor: the bare 20dp glyph measured a 40px hitbox
                        // (e.g. [2504,52][2544,148]) next to "Round ended"
                        // (device evidence 2026-10-25). The CenterEnd actions
                        // row grows leftward, so widening this target cannot
                        // push it offscreen; the title ellipsises instead.
                        .widthIn(min = FloeLayout.MinimumTarget)
                        .clickable { menuExpanded = true }
                        .semantics { contentDescription = menuCd },
                    contentAlignment = Alignment.Center,
                ) {
                    // ⇄ inspectorButton: iOS chart.bar (temporary Progress)
                    // and sidebar.right (ordinary inspector menu).
                    IconGlyph(
                        if (state?.isTemporary == true) FloeIcons.ChartBar else FloeIcons.SidebarTrailing,
                        Floe.colors.label,
                        20.dp,
                    )
                }
                FloeChipMenu(expanded = menuExpanded, onDismiss = { menuExpanded = false }) {
                    if (state != null && !state.isTemporary) {
                        CupertinoMenuEntry(
                            title = stringResource(if (holder.mediaRefreshInFlight) R.string.menu_refreshing_media else R.string.menu_refresh_media),
                            selected = false,
                            onClick = { menuExpanded = false; holder.refreshMediaJobs() },
                        )
                        CupertinoMenuEntry(
                            title = stringResource(R.string.menu_set_goal),
                            selected = false,
                            onClick = { menuExpanded = false; holder.openGoalBuilder() },
                        )
                        // The approved manual compaction control: ONE
                        // explicit human gesture over `conversation.compact`
                        // with the ACTUAL selected usable model (absent key
                        // = native persisted default). The real status line
                        // below the composer carries progress; the in-flight
                        // latch refuses a second request.
                        CupertinoMenuEntry(
                            title = stringResource(
                                if (holder.isCompacting) R.string.menu_compacting else R.string.menu_compact_now
                            ),
                            selected = false,
                            onClick = { menuExpanded = false; holder.requestManualCompaction() },
                        )
                        CupertinoMenuEntry(
                            title = stringResource(if (holder.exportInFlight) R.string.menu_exporting else R.string.menu_export_structured),
                            selected = false,
                            onClick = { menuExpanded = false; holder.exportStructured() },
                        )
                        CupertinoMenuEntry(
                            title = stringResource(R.string.menu_export_text),
                            selected = false,
                            onClick = { menuExpanded = false; holder.shareText(asMarkdown = false) },
                        )
                        CupertinoMenuEntry(
                            title = stringResource(R.string.menu_export_markdown),
                            selected = false,
                            onClick = { menuExpanded = false; holder.shareText(asMarkdown = true) },
                        )
                        CupertinoMenuEntry(
                            title = stringResource(R.string.inspector_changes),
                            selected = false,
                            onClick = { menuExpanded = false; holder.snapshot.value?.let { holder.requestInspector(InspectorRouteUi.CHANGES) } },
                        )
                        CupertinoMenuEntry(
                            title = stringResource(R.string.inspector_files),
                            selected = false,
                            onClick = { menuExpanded = false; holder.requestWorkspaceFilesInspector() },
                        )
                        CupertinoMenuEntry(
                            title = stringResource(R.string.inspector_browser),
                            selected = false,
                            onClick = { menuExpanded = false; holder.requestInspector(InspectorRouteUi.BROWSER) },
                        )
                        CupertinoMenuEntry(
                            title = stringResource(R.string.inspector_terminal),
                            selected = false,
                            onClick = { menuExpanded = false; holder.requestInspector(InspectorRouteUi.TERMINAL) },
                        )
                        CupertinoMenuEntry(
                            title = stringResource(R.string.inspector_subagents),
                            selected = false,
                            onClick = { menuExpanded = false; holder.requestChildAgentsList() },
                        )
                    }
                    CupertinoMenuEntry(
                        title = stringResource(R.string.inspector_progress),
                        selected = false,
                        onClick = { menuExpanded = false; holder.requestInspector(InspectorRouteUi.PROGRESS) },
                    )
                }
            }
        },
    )
}

/* --------------------------------- timeline --------------------------------- */

@Composable
private fun ThreadTimeline(holder: ConversationFlowHolder, isWide: Boolean, modifier: Modifier = Modifier) {
    val state = holder.snapshot.value ?: return
    val search = holder.threadSearch
    val listState = rememberLazyListState()
    // ⇄ latest-follow: scroll to the bottom when the user follows latest and
    // content/length ticks changed; an intentional scroll-away is respected
    // (content growth is not a user scroll).
    val contentTick = remember(state.rows.map { it.id }, state.liveAssistantText.length, state.liveReasoningText.length, state.isRunning) {
        state.rows.size.toString() + ":" + state.liveAssistantText.length + ":" + state.liveReasoningText.length + ":" + state.isRunning
    }
    LaunchedEffect(contentTick, state.hasLoaded, search.focusedMessageId) {
        if (state.hasLoaded && holder.followState.followsLatest &&
            search.focusedMessageId == null && state.rows.isNotEmpty()
        ) {
            listState.scrollToItem(state.rows.lastIndex)
        }
    }
    // Search reveal: scroll ONLY to the selected hit. The token changes on a
    // deliberate prev/next or after a bounded older-window load, so new rows
    // arriving for other reasons never move the reader.
    LaunchedEffect(
        search.focusRowToken,
        search.focusedMessageId,
        state.rows,
    ) {
        val messageId = search.focusedMessageId ?: return@LaunchedEffect
        val index = state.rows.indexOfFirst { row ->
            when (row) {
                is TimelineRowUi.UserMessage -> row.message.id == messageId
                is TimelineRowUi.AssistantMessage -> row.attachedMessageId == messageId
                else -> false
            }
        }
        if (index >= 0) listState.scrollToItem(index)
    }
    // Feed the follow-state machine from the ACTUAL lazy-list geometry:
    // (cumulative offset, distance-to-bottom estimate, user drag flag). The
    // source-stage metric is item-based (offset = index*10k + pixel offset;
    // bottomDistance = 0 while the last row is visible, else 100) — a faithful
    // approximation of the iOS >48pt rule that the binder/UI stage refines
    // with exact pixels; presentation logic itself (ConversationFollowState)
    // is pure and already JVM-tested.
    LaunchedEffect(listState) {
        androidx.compose.runtime.snapshotFlow {
            val info = listState.layoutInfo
            val atBottom = info.visibleItemsInfo.lastOrNull()?.index == info.totalItemsCount - 1
            Triple(
                info.visibleItemsInfo.firstOrNull()?.let { (it.index * 10_000f + it.offset).toDouble() } ?: 0.0,
                if (atBottom) 0.0 else 100.0,
                listState.isScrollInProgress,
            )
        }.collect { (offset, bottomDistance, scrolling) ->
            holder.observeScroll(offset = offset, bottomDistance = bottomDistance, userScrolling = scrolling)
        }
    }

    // One weighted child owns the whole timeline region. The previous code
    // passed the caller's weight modifier to BOTH the LazyColumn and the
    // return-to-latest Box, so Compose split the remaining height between
    // them and left a blank half-pane below the list (Samsung c02-model-*
    // evidence: viewport 0..1115 with a blank gap after the keyboard closed).
    Box(modifier = modifier.fillMaxWidth()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                horizontal = if (isWide) 24.dp else 12.dp,
                vertical = 12.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(state.rows, key = { it.id }) { row ->
                // ⇄ ThreadDetailView.threadScroll (385-435): the LazyVStack fills
                // the ENTIRE detail pane (alignment .leading + .padding()) with
                // NO per-row reading cap — user bubbles align trailing and the
                // assistant reads leading inside their own rows. The composer's
                // centred 720dp chrome is a separate, separately reviewed G01
                // geometry; no captured-iPad justification exists for capping
                // timeline rows, so none is applied here.
                val messageId = when (row) {
                    is TimelineRowUi.UserMessage -> row.message.id
                    is TimelineRowUi.AssistantMessage -> row.attachedMessageId
                    else -> null
                }
                val searchQuery = search.takeIf {
                    messageId != null && it.focusedMessageId == messageId
                }?.query
                Box(modifier = Modifier.fillMaxWidth()) {
                    ConversationTimelineRow(
                        row = row, holder = holder, searchHighlightQuery = searchQuery,
                    )
                }
            }
            if (state.usage != null) {
                item(key = "usage-footer") { ThreadUsageFooter(state.usage) }
            }
            if (!state.isConversationMissing && state.rows.isEmpty() && state.hasLoaded) {
                // ⇄ ContentUnavailableView(thread.empty): honest empty surface,
                // never a fabricated history.
                item(key = "thread-empty") {
                    FloeUnavailableView(
                        icon = FloeIcons.Bubble,
                        title = stringResource(R.string.thread_empty_title),
                        description = stringResource(R.string.thread_empty_hint),
                    )
                }
            }
        }

        // ⇄ return-to-latest floating button. It is an OVERLAY inside the one
        // weighted timeline slot (iOS ZStack alignment .bottomTrailing), not a
        // second weighted column child.
        if (holder.showsReturnToLatest) {
            val jumpCd = stringResource(R.string.jump_to_latest)
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 14.dp, bottom = 12.dp)
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clickable {
                        holder.returnToLatest()
                    }
                    .semantics { contentDescription = jumpCd },
                contentAlignment = Alignment.Center,
            ) {
                IconGlyph(FloeIcons.ChevronDown, Floe.colors.accent, 18.dp)
            }
        }
    }
}



/* --------------------------------- sheets ----------------------------------- */

/** ⇄ GoalBuilderSheet: objective + one-per-line criteria/blockers/stops. */
@Composable
private fun GoalBuilderSheet(holder: ConversationFlowHolder) {
    var objective by remember { mutableStateOf(TextFieldValue("")) }
    var criteria by remember { mutableStateOf(TextFieldValue("")) }
    var blockers by remember { mutableStateOf(TextFieldValue("")) }
    var stops by remember { mutableStateOf(TextFieldValue("")) }
    FloePageSheet(visible = holder.showingGoalBuilder, onDismiss = holder::dismissGoalBuilder) {
        Column(modifier = Modifier.fillMaxWidth()) {
            val cancelLabel = stringResource(R.string.action_cancel)
            val createLabel = stringResource(R.string.goal_create_start)
            val titleText = stringResource(R.string.goal_set_title)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(onClick = holder::dismissGoalBuilder)
                        .semantics { contentDescription = cancelLabel },
                    contentAlignment = Alignment.CenterStart,
                ) { FloeText(cancelLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.label) }
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(enabled = objective.text.isNotBlank()) {
                            holder.createGoal(
                                objective = objective.text,
                                criteria = splitGoalLines(criteria.text),
                                blockers = splitGoalLines(blockers.text),
                                stops = splitGoalLines(stops.text),
                            )
                            objective = TextFieldValue("")
                            criteria = TextFieldValue("")
                            blockers = TextFieldValue("")
                            stops = TextFieldValue("")
                        }
                        .semantics { contentDescription = createLabel },
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    FloeText(
                        createLabel,
                        style = Floe.typography.bodyEmphasized,
                        color = if (objective.text.isBlank()) Floe.colors.tertiaryLabel else Floe.colors.accent,
                    )
                }
            }
            Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                FloeText(titleText, style = Floe.typography.title, color = Floe.colors.label)
                FloePlainFormField(
                    label = stringResource(R.string.goal_objective_field),
                    value = objective.text,
                    onValueChange = { objective = TextFieldValue(it) },
                    singleLine = false,
                    maxLines = 4,
                )
                FloePlainFormField(
                    label = stringResource(R.string.goal_criteria_field),
                    value = criteria.text,
                    onValueChange = { criteria = TextFieldValue(it) },
                    singleLine = false,
                    maxLines = 4,
                )
                FloePlainFormField(
                    label = stringResource(R.string.goal_blockers_field),
                    value = blockers.text,
                    onValueChange = { blockers = TextFieldValue(it) },
                    singleLine = false,
                    maxLines = 3,
                )
                FloePlainFormField(
                    label = stringResource(R.string.goal_stops_field),
                    value = stops.text,
                    onValueChange = { stops = TextFieldValue(it) },
                    singleLine = false,
                    maxLines = 3,
                )
                Spacer(Modifier.height(16.dp))
            }
        }
    }
}

/** ⇄ PendingInputEditor sheet.
 *
 * Safe complete-content editing (G04R2): the editable field binds ONLY a
 * PROVEN body — the published full text from the bounded pending-input
 * detail read, or a row the native snapshot proved to travel complete.
 * While the full body is not yet proven the sheet keeps the original
 * read-only (an explicitly labelled preview when one exists, otherwise a
 * loading/typed-failure notice) and Save is disabled: a blank or bounded
 * preview can NEVER replace the unread original. Cancel always preserves
 * the row (unchanged existing behaviour). */
@Composable
private fun PendingInputEditorSheet(holder: ConversationFlowHolder) {
    val inputId = holder.editingPendingInputId.value
    val input = remember(inputId) { holder.snapshot.value?.pendingInputs?.firstOrNull { it.id == inputId } }
    val body = inputId?.let { holder.snapshot.value?.pendingInputBodies?.get(it) }
    // The editor text is the proven body ONLY: Ready (detail read) or a
    // COMPLETE projection slot. PREVIEW/NOT_READ never seed the field.
    val provenText = when {
        body is PendingInputBodyUi.Ready -> body.text
        input?.bodyState == PendingInputBodyStateUi.COMPLETE -> input.content
        else -> null
    }
    var text by remember(inputId) { mutableStateOf(TextFieldValue(provenText ?: "")) }
    // Re-seed exactly once when the read publishes while the sheet is open
    // (an already-typed edit is never clobbered by a late hydration).
    LaunchedEffect(inputId, provenText) {
        if (provenText != null && text.text.isEmpty()) text = TextFieldValue(provenText)
    }
    val bodyPending = provenText == null
    val previewText = if (bodyPending && input?.bodyState == PendingInputBodyStateUi.PREVIEW) {
        input.content + stringResource(R.string.queue_content_preview_suffix)
    } else {
        null
    }
    val phone = FloeLayout.usesCompactNavigation(
        LocalConfiguration.current.screenWidthDp.toFloat(),
        LocalConfiguration.current.smallestScreenWidthDp.toFloat(),
    )
    FloePageSheet(
        visible = inputId != null,
        onDismiss = holder::closePendingInputEditor,
        heightFraction = 0.5f,
        widthFraction = if (phone) 1f else 0.9f,
        placement = if (phone) com.floe.android.design.FloeSheetPlacement.BOTTOM else null,
    ) {
        Column(modifier = Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            val cancelLabel = stringResource(R.string.action_cancel)
            val saveLabel = stringResource(R.string.action_save)
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(onClick = holder::closePendingInputEditor)
                        .semantics { contentDescription = cancelLabel },
                ) { FloeText(cancelLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.label) }
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(enabled = !bodyPending && text.text.isNotBlank() && input != null) {
                            input?.let { holder.editPendingInput(it.id, text.text) }
                        }
                        .semantics { contentDescription = saveLabel },
                ) { FloeText(saveLabel, style = Floe.typography.bodyEmphasized, color = if (!bodyPending && text.text.isNotBlank()) Floe.colors.accent else Floe.colors.tertiaryLabel) }
            }
            FloeText(stringResource(R.string.queue_edit_title), style = Floe.typography.section, color = Floe.colors.label)
            if (bodyPending) {
                // Honest non-editable state while the full body is unread.
                // The loading promise renders ONLY for an actually owned
                // in-flight read (C04 cold-load repair): a null slot — the
                // host refused to dispatch and no typed state exists — and a
                // typed Failed both show the honest unread marker, never an
                // endless spinner with no read behind it. A labelled preview
                // still wins while the full body is unproven.
                val notice = when (
                    PendingInputQueueLogic.editorNoticeKey(body, previewText != null)
                ) {
                    PendingInputQueueLogic.EditorNoticeKey.PREVIEW -> previewText!!
                    PendingInputQueueLogic.EditorNoticeKey.LOADING ->
                        stringResource(R.string.queue_body_loading)
                    PendingInputQueueLogic.EditorNoticeKey.UNREAD ->
                        stringResource(R.string.queue_body_unread)
                }
                FloeText(
                    notice,
                    style = Floe.typography.body,
                    color = Floe.colors.secondaryLabel,
                    maxLines = 6,
                    overflow = TextOverflow.Ellipsis,
                )
            } else {
                FloePlainFormField(
                    label = stringResource(R.string.queue_message_field),
                    value = text.text,
                    onValueChange = { text = TextFieldValue(it) },
                    singleLine = false,
                    maxLines = 10,
                )
            }
        }
    }
}

/** ⇄ presentedChild sheet: the SAME durable transcript view over the
 * lifecycle owner's store (one source of truth, no second registry). */
@Composable
private fun ChildRunDetailSheet(holder: ConversationFlowHolder) {
    val childRunId = holder.openChildRunId.value
    val state = holder.snapshot.value
    val detail = childRunId?.let { state?.childDetails?.get(it) }
    FloePageSheet(
        visible = childRunId != null,
        onDismiss = holder::closeChildRun,
        widthFraction = if (FloeLayout.usesCompactNavigation(
                LocalConfiguration.current.screenWidthDp.toFloat(),
                LocalConfiguration.current.smallestScreenWidthDp.toFloat(),
            )
        ) 1f else 0.7f,
        heightFraction = 0.86f,
        placement = if (FloeLayout.usesCompactNavigation(
                LocalConfiguration.current.screenWidthDp.toFloat(),
                LocalConfiguration.current.smallestScreenWidthDp.toFloat(),
            )
        ) com.floe.android.design.FloeSheetPlacement.BOTTOM else null,
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            val doneLabel = stringResource(R.string.action_done)
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                IconGlyph(FloeIcons.Puzzle, Floe.colors.label, 16.dp)
                FloeText(
                    detail?.title ?: stringResource(R.string.subagents_title),
                    style = Floe.typography.toolbarTitle,
                    color = Floe.colors.label,
                    modifier = Modifier.weight(1f),
                )
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(onClick = holder::closeChildRun)
                        .semantics { contentDescription = doneLabel },
                    contentAlignment = Alignment.Center,
                ) { FloeText(doneLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.accent) }
            }
            FloeDivider()
            if (detail == null) {
                Box(modifier = Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) {
                    FloeActivityIndicator(description = stringResource(R.string.loading_cd))
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(detail.rows, key = { it.id }) { row ->
                        ConversationTimelineRow(row = row, holder = holder)
                    }
                }
            }
        }
    }
}

/** ⇄ usage popover host: the last-captured snapshot is retained while the
 * presentation transition is in flight, and availability loss closes it. */
@Composable
private fun UsageDetailsPopover(holder: ConversationFlowHolder) {
    val usage = holder.presentedUsage ?: return
    FloePopoverCard(visible = true, onDismiss = holder::closeUsageDetails, widthDp = 300.dp, heightDp = 260.dp) {
        ContextUsageDetails(usage)
    }
}


