// SPDX-License-Identifier: MPL-2.0
@file:OptIn(ExperimentalCupertinoApi::class)

package com.floe.android.design

import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.Composable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.robinpcrd.cupertino.CupertinoAlertDialog
import io.github.robinpcrd.cupertino.CupertinoButton
import io.github.robinpcrd.cupertino.CupertinoCheckBox
import io.github.robinpcrd.cupertino.CupertinoSegmentedControl
import io.github.robinpcrd.cupertino.CupertinoSegmentedControlTab
import io.github.robinpcrd.cupertino.CupertinoSwitch
import io.github.robinpcrd.cupertino.ExperimentalCupertinoApi
import io.github.robinpcrd.cupertino.cancel
import io.github.robinpcrd.cupertino.default
import io.github.robinpcrd.cupertino.CupertinoButtonDefaults
import io.github.robinpcrd.cupertino.section.SectionItem
import io.github.robinpcrd.cupertino.section.SectionStyle
import io.github.robinpcrd.cupertino.section.rememberSectionState
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.material3.Text
import androidx.compose.foundation.border

/** iOS List capsule-selection styles observed in the reference captures. */
enum class FloeSelectionStyle { BLUE, GRAY, NONE }

@Composable
fun FloeText(
    text: String,
    modifier: Modifier = Modifier,
    style: TextStyle = Floe.typography.body,
    color: Color = Floe.colors.label,
    maxLines: Int = Int.MAX_VALUE,
    overflow: TextOverflow = TextOverflow.Clip,
) = Text(text = text, modifier = modifier, style = style, color = color, maxLines = maxLines, overflow = overflow)

/** Hairline separator (iOS .separator semantics). */
@Composable
fun FloeDivider(modifier: Modifier = Modifier, color: Color = Floe.colors.separator, thickness: Dp = 0.5.dp) {
    HorizontalDivider(modifier = modifier, thickness = thickness, color = color)
}

@Composable
fun FloeVerticalDivider(modifier: Modifier = Modifier, color: Color = Floe.colors.separator) {
    Box(modifier.fillMaxHeight().width(0.5.dp).background(color))
}

/**
 * Round chrome control button (toolbar circles, composer send/mic): 44dp
 * visual circle inside an explicit ≥48dp clickable and semantics box.
 * The whole box is the actual target; the inner circle only draws (finish
 * review F05). Disabled buttons keep their semantics but no click handler.
 */
@Composable
fun FloeCircleButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    visualSize: Dp = FloeLayout.ToolbarButtonSize,
    iconSize: Dp = 22.dp,
    background: Color = Floe.colors.chromeSurface,
    tint: Color = if (enabled) Floe.colors.label else Floe.colors.tertiaryLabel,
    hairline: Boolean = true,
) {
    Box(
        modifier = modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .widthIn(min = FloeLayout.MinimumTarget)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics {
                this.contentDescription = contentDescription
                if (!enabled) disabled()
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(visualSize)
                .clip(CircleShape)
                .background(if (enabled) background else background.copy(alpha = 0.6f))
                .then(if (hairline) Modifier.border(0.5.dp, Floe.colors.chromeHairline, CircleShape) else Modifier),
            contentAlignment = Alignment.Center,
        ) {
            IconGlyph(icon, tint, iconSize)
        }
    }
}

@Composable
fun IconGlyph(
    icon: ImageVector,
    tint: Color,
    size: Dp = FloeLayout.SidebarRowIconSize,
) {
    androidx.compose.foundation.Image(
        imageVector = icon,
        contentDescription = null,
        colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(tint),
        modifier = Modifier.size(size),
    )
}

/** Centered inline toolbar (iOS navigation bar): title in the middle, slots both sides. */
@Composable
fun FloeToolbar(
    title: String,
    modifier: Modifier = Modifier,
    navigation: (@Composable RowScope.() -> Unit)? = null,
    actions: (@Composable RowScope.() -> Unit)? = null,
    background: Color = Color.Transparent,
    showHairline: Boolean = false,
) {
    Column(modifier.background(background)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(FloeLayout.ToolbarHeight),
            contentAlignment = Alignment.Center,
        ) {
            if (navigation != null) {
                Row(
                    modifier = Modifier.align(Alignment.CenterStart).padding(start = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    content = navigation,
                )
            }
            FloeText(
                text = title,
                style = Floe.typography.toolbarTitle,
                color = Floe.colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 96.dp),
            )
            if (actions != null) {
                Row(
                    modifier = Modifier.align(Alignment.CenterEnd).padding(end = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    content = actions,
                )
            }
        }
        if (showHairline) FloeDivider()
    }
}

/**
 * Sidebar navigation row with iOS capsule selection:
 * blue capsule (accent) or gray focus capsule, 24dp outline glyph, one-line title.
 */
@Composable
fun FloeSidebarRow(
    icon: ImageVector,
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selectionStyle: FloeSelectionStyle = FloeSelectionStyle.BLUE,
    trailing: (@Composable RowScope.() -> Unit)? = null,
    leadingTintUnselected: Color = Floe.colors.accent,
) {
    val style = if (selected) selectionStyle else FloeSelectionStyle.NONE
    val capsule = FloeLayout.SidebarSelectionShape
    val container: Color = when (style) {
        FloeSelectionStyle.BLUE -> Floe.colors.accent
        FloeSelectionStyle.GRAY -> Floe.colors.fillTertiary
        FloeSelectionStyle.NONE -> Color.Transparent
    }
    val iconTint = if (style == FloeSelectionStyle.BLUE) Color.White else leadingTintUnselected
    val labelColor = if (style == FloeSelectionStyle.BLUE) Color.White else Floe.colors.label
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.SidebarRowHeight)
            .padding(horizontal = 8.dp, vertical = 3.dp)
            .clip(capsule)
            .background(container)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        IconGlyph(icon, iconTint)
        FloeText(
            text = label,
            style = Floe.typography.body,
            color = labelColor,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        trailing?.invoke(this)
    }
}

/** Section header on the sidebar plane (工作区 / 聊天). */
@Composable
fun FloeSectionHeader(title: String, modifier: Modifier = Modifier) {
    FloeText(
        text = title,
        modifier = modifier.padding(start = 20.dp, end = 16.dp, top = 18.dp, bottom = FloeLayout.SectionHeaderVPadding),
        style = Floe.typography.groupHeader,
        color = Floe.colors.secondaryLabel,
    )
}

/** Workspace disclosure row component (filled data arrives with the runtime; preview uses labelled fixtures). */
@Composable
fun FloeWorkspaceRow(
    name: String,
    expanded: Boolean,
    selected: Boolean,
    onOpen: () -> Unit,
    onToggleExpanded: () -> Unit,
    onAdd: () -> Unit,
    addContentDescription: String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.SidebarRowHeight)
            .padding(horizontal = 8.dp, vertical = 3.dp)
            .clip(FloeLayout.SidebarSelectionShape)
            .background(if (selected) Floe.colors.fillTertiary else Color.Transparent)
            .clickable(onClick = onOpen)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        IconGlyph(FloeIcons.Folder, Floe.colors.accent)
        FloeText(name, style = Floe.typography.body, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Box(
            modifier = Modifier
                .size(FloeLayout.MinimumTarget)
                .clickable(onClick = onAdd)
                .semantics { contentDescription = addContentDescription },
            contentAlignment = Alignment.Center,
        ) { IconGlyph(FloeIcons.Plus, Floe.colors.accent, 20.dp) }
        Box(
            modifier = Modifier
                .size(FloeLayout.MinimumTarget)
                .clickable(onClick = onToggleExpanded)
                .semantics { contentDescription = if (expanded) "Collapse" else "Expand" },
            contentAlignment = Alignment.Center,
        ) { IconGlyph(if (expanded) FloeIcons.ChevronDown else FloeIcons.ChevronForward, Floe.colors.secondaryLabel, 16.dp) }
    }
}

/** Conversation row component (sidebar; selection capsule mirrors iOS List). */
@Composable
fun FloeConversationRow(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    activityBadge: (@Composable () -> Unit)? = null,
    selectionStyle: FloeSelectionStyle = FloeSelectionStyle.GRAY,
) {
    FloeSidebarRow(
        icon = FloeIcons.Bubble,
        label = title,
        selected = selected,
        onClick = onClick,
        modifier = modifier,
        selectionStyle = selectionStyle,
        trailing = activityBadge?.let { badge -> { androidx.compose.foundation.layout.Box(contentAlignment = Alignment.Center) { badge() } } },
    )
}

/** ContentUnavailableView analog: honest empty/unavailable surface. */
@Composable
fun FloeUnavailableView(
    icon: ImageVector,
    title: String,
    description: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier = Modifier
                .size(64.dp)
                .clip(CircleShape)
                .background(Floe.colors.fillTertiary),
            contentAlignment = Alignment.Center,
        ) { IconGlyph(icon, Floe.colors.secondaryLabel, 30.dp) }
        Spacer(Modifier.height(14.dp))
        FloeText(title, style = Floe.typography.section, color = Floe.colors.label)
        Spacer(Modifier.height(6.dp))
        FloeText(
            description,
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.widthIn(max = 340.dp),
        )
        if (action != null) {
            Spacer(Modifier.height(18.dp))
            action()
        }
    }
}

/** Grouped white card section on the settings plane (Cupertino inset-grouped). */
@Composable
fun FloeSettingsSectionCard(
    title: String?,
    modifier: Modifier = Modifier,
    content: @Composable io.github.robinpcrd.cupertino.section.SectionScope.() -> Unit,
) {
    io.github.robinpcrd.cupertino.section.CupertinoSection(
        modifier = modifier.fillMaxWidth(),
        style = SectionStyle.InsetGrouped,
        state = rememberSectionState(canCollapse = false),
        title = title?.let { t -> { FloeText(t, style = Floe.typography.groupHeader, color = Floe.colors.secondaryLabel) } },
        content = content,
    )
}

@Composable
fun io.github.robinpcrd.cupertino.section.SectionScope.FloeSwitchRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    caption: String? = null,
) {
    SectionItem(
        // Native settings semantics: the whole row toggles (Android
        // SwitchPreference / iOS cell parity). Before this, only the switch
        // itself responded and tapping the title silently did nothing — the
        // G04-R2 provider HTTP opt-in trap. The switch keeps its own hit
        // target; the row modifier does not add a second state change per
        // tap because child pointer input consumes the event first.
        modifier = Modifier.toggleable(
            value = checked,
            role = Role.Switch,
            onValueChange = onCheckedChange,
        ),
        title = {
            Column {
                FloeText(title, style = Floe.typography.body)
                if (caption != null) FloeText(caption, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
        },
        trailingContent = {
            CupertinoSwitch(
                checked = checked,
                onCheckedChange = onCheckedChange,
                modifier = Modifier
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .widthIn(min = 64.dp),
            )
        },
    )
}

@Composable
fun io.github.robinpcrd.cupertino.section.SectionScope.FloeValueRow(title: String, value: String, onClick: (() -> Unit)? = null) {
    SectionItem(
        modifier = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier,
        title = { FloeText(title, style = Floe.typography.body) },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeText(value, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                if (onClick != null) IconGlyph(FloeIcons.ChevronForward, Floe.colors.tertiaryLabel, 14.dp)
            }
        },
    )
}

/** Cupertino segmented control with the Floe 48dp floor. */
@Composable
fun FloeSegmented(
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    CupertinoSegmentedControl(
        selectedTabIndex = selectedIndex,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp),
        tabs = {
            options.forEachIndexed { index, title ->
                CupertinoSegmentedControlTab(
                    onClick = { onSelect(index) },
                    isSelected = index == selectedIndex,
                ) {
                    FloeText(
                        title,
                        style = Floe.typography.metadata,
                        color = if (index == selectedIndex) Floe.colors.label else Floe.colors.secondaryLabel,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 10.dp),
                    )
                }
            }
        },
    )
}

/**
 * Independent 48dp selection slot (finish review F06). The wrapper owns the
 * full toggleable target; the Cupertino checkbox only draws its 24dp glyph
 * centred and inert inside it, so a tool card can place the slot as a sibling
 * of — never inside — the expander row. No row padding or label is forced into
 * the target.
 */
@Composable
fun FloeSelectionSlot(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    description: String? = null,
) {
    // CupertinoCheckBox pads 4dp inside its toggleable, so its own footprint is
    // 40dp even when given 48dp. The wrapper owns the 48dp toggleable target;
    // the Cupertino box is rendered non-interactive at its centred glyph size.
    Box(
        modifier = modifier
            .size(FloeLayout.MinimumTarget)
            .toggleable(
                value = checked,
                role = Role.Checkbox,
                onValueChange = onCheckedChange,
            )
            .then(
                description?.let { label ->
                    Modifier.semantics { contentDescription = label }
                } ?: Modifier
            ),
        contentAlignment = Alignment.Center,
    ) {
        CupertinoCheckBox(checked = checked, onCheckedChange = null)
    }
}

/** Explicit Cupertino checkbox wrapper for the sample selection controls. */
@Composable
fun FloeCheckboxRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable { onCheckedChange(!checked) }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        CupertinoCheckBox(checked = checked, onCheckedChange = onCheckedChange)
        FloeText(label, style = Floe.typography.body)
    }
}

/** borderedProminent-style action (unauthenticated retry / setup affordances). */
@Composable
fun FloePrimaryAction(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    CupertinoButton(
        onClick = onClick,
        modifier = modifier.heightIn(min = FloeLayout.MinimumTarget),
        enabled = enabled,
        colors = CupertinoButtonDefaults.filledButtonColors(
            contentColor = Color.White,
            containerColor = Floe.colors.accent,
            disabledContentColor = Color.White.copy(alpha = 0.6f),
            disabledContainerColor = Floe.colors.accent.copy(alpha = 0.45f),
        ),
        shape = RoundedCornerShape(12.dp),
    ) {
        FloeText(label, style = Floe.typography.bodyEmphasized, color = Color.White)
    }
}

/** Cupertino alert with Floe copy for honest availability explanations. */
@Composable
fun FloeInfoDialog(
    title: String,
    message: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
) {
    CupertinoAlertDialog(
        onDismissRequest = onDismiss,
        title = { FloeText(title, style = Floe.typography.section) },
        message = { FloeText(message, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) },
        buttons = {
            default(onClick = onDismiss) { FloeText(confirmLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.accent) }
        },
    )
}

@Composable
fun FloeColumnScroll(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier = modifier.verticalScroll(rememberScrollState()), content = content)
}
