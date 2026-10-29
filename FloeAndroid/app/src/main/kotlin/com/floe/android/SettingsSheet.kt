// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)

package com.floe.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSelectionStyle
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeSettingsSection
import com.floe.android.design.FloeSettingsHostGeometry
import com.floe.android.design.FloeSidebarRow
import com.floe.android.design.FloeText
import com.floe.android.design.FloeThemeMode
import com.floe.android.design.FloeValueRow
import com.floe.android.design.FloeVerticalDivider
import com.floe.android.design.FloeWindowInsetsPx
import com.floe.android.design.IconGlyph
import com.floe.android.feature.integrations.FloeSkillsSettingsDestination
import com.floe.android.feature.providers.FloeProviderSettingsDestination
import com.floe.android.host.RuntimeHost
import com.floe.android.host.SettingsHostPages
import com.floe.android.host.WebSearchSettingsPage
import com.floe.android.host.GitHubCredentialEditor
import io.github.robinpcrd.cupertino.section.SectionItem

/**
 * Settings opens as a page sheet (iOS presents `SettingsRootView` from the
 * sidebar footer gear), never a top-level sidebar row.
 *
 * Wide finish-review geometry (reference 03-settings, 2026-10-18 calibration):
 * the sheet starts 76dp below the screen top so the masked home toolbar stays
 * visible; the section column is 320dp wide and owns its own title, Done and
 * column toggle; the detail pane has an independent 34sp large title and its
 * own scrolling grouped cards. Like iOS `SettingsRootView`, whose `@State
 * columnVisibility = .all` is recreated by every fresh sheet presentation,
 * each genuine hidden->visible presentation opens with BOTH panes on wide
 * (2026-10-19 two-column repair) while the selection is preserved; rotation or
 * window recreation of an already-visible sheet keeps its current columns and
 * compact pushed page instead of being treated as a reopen, and an explicit
 * deep-linked section opens selected (compact: its detail directly). Compact
 * keeps the internal push stack with a single sheet toolbar, and its drilldown
 * state is independent of the wide column collapse. No local-LLM or
 * Apple-only rows are mirrored.
 */
@Composable
fun SettingsSheet(
    visible: Boolean,
    initialSection: String,
    themeMode: FloeThemeMode,
    onThemeModeChange: (FloeThemeMode) -> Unit,
    onDismiss: () -> Unit,
    onOpenPreview: () -> Unit,
    /** G02 App host; null keeps the honest G01 placeholders. */
    runtimeHost: RuntimeHost? = null,
    /**
     * Provider detail content slot (the measured host geometry is supplied
     * through it, mirroring the settings host presentation contract). Null
     * keeps the G01 provider summary placeholder.
     */
    providerContent: (@Composable (FloeSettingsHostGeometry, Modifier) -> Unit)? = null,
) {
    var section by rememberSaveable { mutableStateOf(initialSection.ifEmpty { FloeSettingsSection.GENERAL.name }) }
    // Wide mode only: the sheet's own column toggle hid the category list
    // (mirrors SettingsRootView collapsing NavigationSplitView column
    // visibility to .detailOnly). Never shared with compact semantics.
    var wideListCollapsed by rememberSaveable { mutableStateOf(false) }
    // Compact mode only: a section was pushed onto the sheet's own stack
    // (mirrors SettingsRootView's iPhone NavigationStack path), fully
    // independent of the wide column collapse.
    var compactDetailOpen by rememberSaveable { mutableStateOf(false) }
    // Presentation-transition capture. SettingsSheet itself stays composed
    // while hidden and its saveable state survives rotation/recreation, so a
    // keyed effect could not tell "new presentation" from "recreation of an
    // already-visible sheet". Only a real hidden->visible flip carries the
    // fresh iOS sheet identity (SettingsRootView @State columnVisibility
    // starts at .all every presentation); rotation of a visible sheet keeps
    // the compact pushed page, the wide collapse and the current selection.
    var lastPresented by rememberSaveable { mutableStateOf(false) }
    if (visible != lastPresented) {
        lastPresented = visible
        if (visible) {
            val entrySection = FloeSettingsSection.entries
                .firstOrNull { it.name == initialSection }
            if (entrySection != null) {
                // Explicit deep link: select the target; compact opens its
                // detail directly, wide shows both panes with it selected.
                section = entrySection.name
                wideListCollapsed = false
                compactDetailOpen = true
            } else {
                // A newly presented native SettingsRootView selects General.
                // Preserve selection only across recreation while visible.
                section = FloeSettingsSection.GENERAL.name
                wideListCollapsed = false
                compactDetailOpen = false
            }
        }
    }
    FloePageSheet(
        visible = visible,
        onDismiss = onDismiss,
        topInset = FloeLayout.SettingsSheetTopInset,
    ) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            // Measured inside the actual page-sheet window so boundsInWindow()
            // and the provider Popup share one window-pixel coordinate space.
            val density = LocalDensity.current
            val layoutDirection = LocalLayoutDirection.current
            val windowInfo = LocalWindowInfo.current
            var categoryPaneBounds by remember { mutableStateOf<Rect?>(null) }
            var detailPaneBounds by remember { mutableStateOf<Rect?>(null) }
            var selectedCategoryRowBounds by remember { mutableStateOf<Rect?>(null) }
            val safeDrawing = WindowInsets.safeDrawing
            val safeBottom = safeDrawing.getBottom(density)
            val imeBottom = WindowInsets.ime.getBottom(density)
            val hostInsets = FloeWindowInsetsPx(
                leftPx = safeDrawing.getLeft(density, layoutDirection),
                topPx = safeDrawing.getTop(density),
                rightPx = safeDrawing.getRight(density, layoutDirection),
                bottomPx = safeBottom,
            )
            val hostImeBottom = (imeBottom - safeBottom).coerceAtLeast(0)
            val windowWidth = windowInfo.containerSize.width.coerceAtLeast(1)
            val windowHeight = windowInfo.containerSize.height.coerceAtLeast(1)

            val wide = maxWidth >= FloeLayout.PersistentTwoColumnMinWidth
            val active = runCatching { FloeSettingsSection.valueOf(section) }.getOrDefault(FloeSettingsSection.GENERAL)
            val categoryVisible = wide && !wideListCollapsed
            val hostGeometry = FloeSettingsHostGeometry(
                windowBoundsPx = Rect(0f, 0f, windowWidth.toFloat(), windowHeight.toFloat()),
                categoryPaneBoundsPx = if (categoryVisible) categoryPaneBounds else null,
                detailPaneBoundsPx = detailPaneBounds,
                selectedCategoryRowBoundsPx = if (categoryVisible) selectedCategoryRowBounds else null,
                triggerBoundsPx = null,
                safeInsetsPx = hostInsets,
                imeBottomInsetPx = hostImeBottom,
                wideLayout = wide,
                categoryPaneVisible = categoryVisible,
                density = density.density,
                fontScale = density.fontScale,
            )
            Column(
                Modifier
                    .fillMaxSize()
                    .background(Floe.colors.readingSurface)
                    .navigationBarsPadding(),
            ) {
                if (wide) {
                    Row(Modifier.fillMaxSize()) {
                        if (!wideListCollapsed) {
                            Column(
                                Modifier
                                    .widthIn(FloeLayout.SettingsSidebarMinWidth, FloeLayout.SettingsSidebarMaxWidth)
                                    .width(FloeLayout.SettingsSidebarWidth)
                                    .fillMaxHeight()
                                    .background(Floe.colors.sidebarSurface)
                                    .onGloballyPositioned { coordinates ->
                                        val bounds = coordinates.boundsInWindow()
                                        if (categoryPaneBounds != bounds) categoryPaneBounds = bounds
                                    },
                            ) {
                                SettingsSidebarHeader(
                                    onToggleColumns = { wideListCollapsed = true },
                                    onDone = onDismiss,
                                )
                                FloeDivider()
                                Column(
                                    Modifier
                                        .fillMaxSize()
                                        .verticalScroll(rememberScrollState())
                                        .padding(vertical = 8.dp),
                                ) {
                                    FloeSettingsSection.entries.forEach { entry ->
                                        FloeSidebarRow(
                                            icon = settingsIcon(entry),
                                            label = settingsTitle(entry),
                                            selected = entry == active,
                                            onClick = { section = entry.name },
                                            selectionStyle = FloeSelectionStyle.GRAY,
                                            modifier = Modifier
                                                .padding(horizontal = 12.dp)
                                                .then(
                                                    if (entry == active) {
                                                        Modifier.onGloballyPositioned { coordinates ->
                                                            val bounds = coordinates.boundsInWindow()
                                                            if (selectedCategoryRowBounds != bounds) {
                                                                selectedCategoryRowBounds = bounds
                                                            }
                                                        }
                                                    } else {
                                                        Modifier
                                                    },
                                                ),
                                        )
                                    }
                                }
                            }
                            FloeVerticalDivider()
                        }
                        Column(
                            Modifier
                                .weight(1f)
                                .fillMaxHeight()
                                .background(Floe.colors.groupedSurface)
                                .onGloballyPositioned { coordinates ->
                                    val bounds = coordinates.boundsInWindow()
                                    if (detailPaneBounds != bounds) detailPaneBounds = bounds
                                },
                        ) {
                            SettingsDetailHeader(
                                title = settingsTitle(active),
                                topPadding = 68.dp,
                                showColumnToggle = wideListCollapsed,
                                onToggleColumns = { wideListCollapsed = false },
                            )
                            val slot = providerContent
                            if (active == FloeSettingsSection.PROVIDERS && slot != null) {
                                // The provider destination owns its list
                                // scroll; the host supplies a finite slot with
                                // no outer scrolling parent.
                                Box(Modifier.fillMaxWidth().weight(1f)) {
                                    slot(hostGeometry, Modifier.fillMaxSize())
                                }
                            } else if (active == FloeSettingsSection.SKILLS) {
                                // The integrations destination owns its own
                                // bounded scrolling list; a pane-level scroll
                                // here would nest inside it (infinite height).
                                Box(Modifier.fillMaxWidth().weight(1f)) {
                                    SkillsSettingsPage(runtimeHost)
                                }
                            } else {
                                // ONE bounded scroll owner for this pane; the
                                // host pages below are plain content.
                                Column(
                                    Modifier
                                        .fillMaxWidth()
                                        .weight(1f)
                                        .verticalScroll(rememberScrollState()),
                                ) {
                                    SettingsSectionContent(
                                        active, themeMode, onThemeModeChange, onOpenPreview,
                                        runtimeHost = runtimeHost,
                                    )
                                }
                            }
                        }
                    }
                } else {
                    Column(Modifier.fillMaxSize()) {
                        SheetToolbar(
                            title = if (compactDetailOpen) {
                                settingsTitle(active)
                            } else {
                                stringResource(R.string.settings)
                            },
                            compactDetail = compactDetailOpen,
                            onDone = onDismiss,
                            onBack = { compactDetailOpen = false },
                        )
                        if (compactDetailOpen) {
                            val slot = providerContent
                            if (active == FloeSettingsSection.PROVIDERS && slot != null) {
                                Column(
                                    Modifier
                                        .fillMaxSize()
                                        .background(Floe.colors.groupedSurface),
                                ) {
                                    Spacer(Modifier.height(8.dp))
                                    Box(Modifier.fillMaxWidth().weight(1f)) {
                                        slot(hostGeometry, Modifier.fillMaxSize())
                                    }
                                }
                            } else if (active == FloeSettingsSection.SKILLS) {
                                Column(
                                    Modifier
                                        .fillMaxSize()
                                        .background(Floe.colors.groupedSurface),
                                ) {
                                    Spacer(Modifier.height(8.dp))
                                    Box(Modifier.fillMaxWidth().weight(1f)) {
                                        SkillsSettingsPage(runtimeHost)
                                    }
                                }
                            } else {
                                Column(
                                    Modifier
                                        .fillMaxSize()
                                        .background(Floe.colors.groupedSurface),
                                ) {
                                    Spacer(Modifier.height(8.dp))
                                    Column(
                                        Modifier
                                            .fillMaxWidth()
                                            .weight(1f)
                                            .verticalScroll(rememberScrollState()),
                                    ) {
                                        SettingsSectionContent(
                                            active, themeMode, onThemeModeChange, onOpenPreview,
                                            runtimeHost = runtimeHost,
                                        )
                                    }
                                }
                            }
                            BackHandler { compactDetailOpen = false }
                        } else {
                            Column(
                                Modifier
                                    .fillMaxSize()
                                    .verticalScroll(rememberScrollState())
                                    .padding(vertical = 8.dp),
                            ) {
                                FloeSettingsSection.entries.forEach { entry ->
                                    FloeSidebarRow(
                                        icon = settingsIcon(entry),
                                        label = settingsTitle(entry),
                                        selected = false,
                                        onClick = { section = entry.name; compactDetailOpen = true },
                                        selectionStyle = FloeSelectionStyle.NONE,
                                        modifier = Modifier.padding(horizontal = 12.dp),
                                        trailing = { IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 14.dp) },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Wide sidebar chrome: section-list title, Done and the column toggle. */
@Composable
private fun SettingsSidebarHeader(onToggleColumns: () -> Unit, onDone: () -> Unit) {
    val colors = Floe.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(
            stringResource(R.string.settings),
            style = Floe.typography.title,
            color = colors.label,
            modifier = Modifier.weight(1f),
        )
        FloeDoneButton(onDone)
        FloeCircleButton(
            icon = FloeIcons.SidebarToggle,
            contentDescription = stringResource(R.string.toggle_sheet_columns),
            onClick = onToggleColumns,
            visualSize = 38.dp,
            iconSize = 20.dp,
            modifier = Modifier.padding(start = 8.dp),
        )
    }
}

/** Detail header: independent iOS .largeTitle, optionally restoring the list. */
@Composable
private fun SettingsDetailHeader(
    title: String,
    topPadding: Dp = 14.dp,
    showColumnToggle: Boolean = false,
    onToggleColumns: () -> Unit = {},
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 16.dp, top = topPadding, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeText(
            title,
            style = Floe.typography.navLargeTitle,
            color = Floe.colors.label,
            modifier = Modifier.weight(1f),
        )
        if (showColumnToggle) {
            FloeCircleButton(
                icon = FloeIcons.SidebarToggle,
                contentDescription = stringResource(R.string.toggle_sheet_columns),
                onClick = onToggleColumns,
                visualSize = 38.dp,
                iconSize = 20.dp,
            )
        }
    }
}

@Composable
private fun SheetToolbar(
    title: String,
    compactDetail: Boolean,
    onDone: () -> Unit,
    onBack: () -> Unit,
) {
    val colors = Floe.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(FloeLayout.ToolbarHeight + 6.dp)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (compactDetail) {
            FloeCircleButton(
                icon = FloeIcons.ChevronBack,
                contentDescription = stringResource(R.string.back),
                onClick = onBack,
                visualSize = 38.dp,
                iconSize = 18.dp,
                background = Color.Transparent,
                hairline = false,
                modifier = Modifier.padding(end = 2.dp),
            )
        }
        FloeText(
            // iOS compact uses the pushed section's navigation title; the
            // category name must not be duplicated as a second large title
            // inside the form.
            title,
            style = Floe.typography.title,
            color = colors.label,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).padding(start = if (compactDetail) 0.dp else 8.dp),
        )
        FloeDoneButton(onDone)
    }
    FloeDivider()
}

@Composable
private fun FloeDoneButton(onClick: () -> Unit) {
    val colors = Floe.colors
    val shape = RoundedCornerShape(percent = 50)
    val doneLabel = stringResource(R.string.done)
    Box(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(shape)
            .background(colors.chromeSurface)
            .border(0.5.dp, colors.chromeHairline, shape)
            .clickable { onClick() }
            .padding(horizontal = 18.dp, vertical = 8.dp)
            .semantics { contentDescription = doneLabel },
        contentAlignment = Alignment.Center,
    ) {
        FloeText(doneLabel, style = Floe.typography.bodyEmphasized, color = colors.accent)
    }
}

@Composable
private fun SettingsSectionContent(
    section: FloeSettingsSection,
    themeMode: FloeThemeMode,
    onThemeModeChange: (FloeThemeMode) -> Unit,
    onOpenPreview: () -> Unit,
    runtimeHost: RuntimeHost? = null,
) {
    when (section) {
        FloeSettingsSection.GENERAL -> {
            GeneralSettingsPage(themeMode, onThemeModeChange)
            com.floe.android.host.linux.LocalRuntimeSettingsCard()
            if (runtimeHost != null) {
                SettingsHostPages.DefaultsPage(runtimeHost.settings)
            }
        }
        FloeSettingsSection.PROVIDERS -> ProvidersSettingsPage()
        FloeSettingsSection.SKILLS -> SkillsSettingsPage(runtimeHost)
        FloeSettingsSection.MEMORY -> {
            if (runtimeHost != null) {
                SettingsHostPages.MemoryPage(runtimeHost.settings)
                SettingsHostPages.PersonalizationPage(runtimeHost.settings)
            } else {
                HostPendingPage(R.string.settings_skills_pending)
            }
        }
        FloeSettingsSection.USAGE -> {
            if (runtimeHost != null) {
                SettingsHostPages.UsagePage(runtimeHost.settings)
            } else {
                HostPendingPage(R.string.settings_skills_pending)
            }
        }
        FloeSettingsSection.PRIVACY -> {
            if (runtimeHost != null) {
                SettingsHostPages.PrivacyPage(runtimeHost.settings)
            } else {
                HostPendingPage(R.string.settings_skills_pending)
            }
        }
        FloeSettingsSection.WEB_SEARCH -> {
            if (runtimeHost != null) {
                WebSearchSettingsPage(runtimeHost.webSearch)
            } else {
                HostPendingPage(R.string.settings_skills_pending)
            }
        }
        FloeSettingsSection.DIAGNOSTICS -> DiagnosticsSettingsPage(onOpenPreview)
    }
}

/** Honest placeholder for G02 surfaces before the runtime host is ready. */
@Composable
private fun HostPendingPage(messageRes: Int) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeSettingsSectionCard(title = stringResource(R.string.settings)) {
            SectionItem(
                title = {
                    FloeText(
                        stringResource(messageRes),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        modifier = Modifier.padding(vertical = 10.dp),
                    )
                },
            )
        }
    }
}

/**
 * Skills & connectors detail body: mounts the real integrations destination
 * with its immutable destination state and the caller-retained flow holder.
 * The destination owns its nested page/sheet stack and its own scrolling;
 * this body stays a finite non-scrolling host.
 */
@Composable
private fun SkillsSettingsPage(runtimeHost: RuntimeHost?) {
    if (runtimeHost == null) {
        HostPendingPage(R.string.settings_skills_pending)
        return
    }
    val state by runtimeHost.integrations.destination.collectAsState()
    Box(Modifier.fillMaxSize()) {
        FloeSkillsSettingsDestination(
            state = state,
            holder = runtimeHost.integrations.flowHolder,
            modifier = Modifier.fillMaxSize(),
        )
        GitHubCredentialEditor(runtimeHost.gitCredentials)
    }
}

@Composable
private fun GeneralSettingsPage(themeMode: FloeThemeMode, onThemeModeChange: (FloeThemeMode) -> Unit) {
    val colors = Floe.colors
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeSettingsSectionCard(title = stringResource(R.string.day_night_theme)) {
            SectionItem(
                title = {
                    Column(Modifier.fillMaxWidth().padding(top = 6.dp, bottom = 12.dp)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            val modes = listOf(FloeThemeMode.AUTO, FloeThemeMode.LIGHT, FloeThemeMode.DARK)
                            modes.forEach { mode ->
                                ThemePreviewThumb(
                                    mode = mode,
                                    selected = themeMode == mode,
                                    onClick = { onThemeModeChange(mode) },
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        }
                        Spacer(Modifier.height(14.dp))
                        FloeSegmented(
                            options = listOf(
                                stringResource(R.string.theme_auto),
                                stringResource(R.string.theme_light),
                                stringResource(R.string.theme_dark),
                            ),
                            selectedIndex = when (themeMode) {
                                FloeThemeMode.AUTO -> 0
                                FloeThemeMode.LIGHT -> 1
                                FloeThemeMode.DARK -> 2
                            },
                            onSelect = { index ->
                                onThemeModeChange(listOf(FloeThemeMode.AUTO, FloeThemeMode.LIGHT, FloeThemeMode.DARK)[index])
                            },
                        )
                        Spacer(Modifier.height(12.dp))
                        FloeText(
                            stringResource(R.string.theme_auto_caption),
                            style = Floe.typography.metadata,
                            color = colors.secondaryLabel,
                        )
                    }
                },
            )
        }
        FloeSettingsSectionCard(title = stringResource(R.string.language_section)) {
            SectionItem(
                title = {
                    Column(Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 4.dp)) {
                        FloeText(stringResource(R.string.language), style = Floe.typography.body, color = colors.label)
                    }
                },
                trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        FloeText(stringResource(R.string.follow_system), style = Floe.typography.metadata, color = colors.secondaryLabel)
                    }
                },
            )
            SectionItem(
                title = {
                    FloeText(
                        stringResource(R.string.language_caption),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                },
            )
        }
    }
}

/** Mini window preview thumbnail: sidebar strip, text lines, composer pill. */
@Composable
private fun ThemePreviewThumb(
    mode: FloeThemeMode,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val dark = mode == FloeThemeMode.DARK
    val bg = if (dark) Color(0xFF000000) else Color(0xFFFFFFFF)
    val side = if (dark) Color(0xFF1C1C1E) else Color(0xFFE6EAEE)
    val line = if (dark) Color(0xFF3A3A3C) else Color(0xFFD9D9DE)
    val accent = if (dark) Color(0xFF0A84FF) else Color(0xFF0081F6)
    val shape = RoundedCornerShape(10.dp)
    val description = modeDescription(mode)
    Column(
        modifier = modifier
            .height(84.dp)
            .clip(shape)
            .background(bg)
            .border(if (selected) 2.dp else 0.5.dp, if (selected) accent else line, shape)
            .clickable(onClick = onClick)
            .semantics { this.selected = selected; contentDescription = description },
    ) {
        Row(Modifier.fillMaxWidth().weight(1f)) {
            Box(Modifier.width(26.dp).fillMaxHeight().background(side)) {
                Column(Modifier.padding(6.dp)) {
                    Box(Modifier.height(6.dp).width(14.dp).clip(CircleShape).background(if (selected) accent else line))
                    Spacer(Modifier.height(5.dp))
                    Box(Modifier.height(6.dp).width(14.dp).clip(CircleShape).background(line))
                }
            }
            Column(Modifier.weight(1f).padding(8.dp)) {
                Box(Modifier.height(6.dp).fillMaxWidth().clip(CircleShape).background(line))
                Spacer(Modifier.height(5.dp))
                Box(Modifier.height(6.dp).fillMaxWidth(0.7f).clip(CircleShape).background(line))
            }
        }
        Box(Modifier.fillMaxWidth().padding(8.dp).height(18.dp).clip(CircleShape).background(if (dark) Color(0xFF1C1C1E) else Color(0xFFF2F2F7)))
    }
}

private fun modeDescription(mode: FloeThemeMode): String = when (mode) {
    FloeThemeMode.AUTO -> "Auto"
    FloeThemeMode.LIGHT -> "Day"
    FloeThemeMode.DARK -> "Night"
}

@Composable
private fun ProvidersSettingsPage() {
    val colors = Floe.colors
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeSettingsSectionCard(title = stringResource(R.string.cloud_model)) {
            FloeValueRow(stringResource(R.string.model_status), stringResource(R.string.model_unconfigured))
            SectionItem(
                title = {
                    FloeText(
                        stringResource(R.string.providers_caption),
                        style = Floe.typography.metadata,
                        color = colors.secondaryLabel,
                        modifier = Modifier.padding(bottom = 10.dp),
                    )
                },
            )
        }
    }
}

private fun settingsIcon(section: FloeSettingsSection) = when (section) {
    FloeSettingsSection.GENERAL -> FloeIcons.Gearshape
    FloeSettingsSection.PROVIDERS -> FloeIcons.Antenna
    FloeSettingsSection.SKILLS -> FloeIcons.Puzzle
    FloeSettingsSection.MEMORY -> FloeIcons.PersonCircleCheck
    FloeSettingsSection.USAGE -> FloeIcons.ChartBar
    FloeSettingsSection.PRIVACY -> FloeIcons.HandRaised
    FloeSettingsSection.WEB_SEARCH -> FloeIcons.Magnifier
    FloeSettingsSection.DIAGNOSTICS -> FloeIcons.Stethoscope
}

@Composable
private fun settingsTitle(section: FloeSettingsSection): String = when (section) {
    FloeSettingsSection.GENERAL -> stringResource(R.string.settings_general)
    FloeSettingsSection.PROVIDERS -> stringResource(R.string.settings_providers)
    FloeSettingsSection.SKILLS -> stringResource(R.string.settings_skills)
    FloeSettingsSection.MEMORY -> stringResource(R.string.settings_memory)
    FloeSettingsSection.USAGE -> stringResource(R.string.settings_usage)
    FloeSettingsSection.PRIVACY -> stringResource(R.string.settings_privacy)
    FloeSettingsSection.WEB_SEARCH -> stringResource(R.string.settings_web_search)
    FloeSettingsSection.DIAGNOSTICS -> stringResource(R.string.settings_diagnostics)
}
