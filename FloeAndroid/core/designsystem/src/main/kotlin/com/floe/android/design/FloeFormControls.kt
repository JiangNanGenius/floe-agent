// SPDX-License-Identifier: MPL-2.0
//
// Reusable grouped-form / secure-field / chooser / menu / search wrappers the
// provider & model configuration pages need (G02 provider presentation flow).
// Pages consume ONLY these wrappers — never the raw Cupertino field APIs —
// so the substrate seam stays in this module. Existing wrappers keep their
// behavior; everything here is additive.
@file:OptIn(ExperimentalCupertinoApi::class, androidx.compose.foundation.ExperimentalFoundationApi::class)

package com.floe.android.design

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import io.github.robinpcrd.cupertino.CupertinoActivityIndicator
import io.github.robinpcrd.cupertino.CupertinoAlertDialog
import io.github.robinpcrd.cupertino.CupertinoSearchTextField
import io.github.robinpcrd.cupertino.CupertinoSwitch
import io.github.robinpcrd.cupertino.CupertinoTextField
import io.github.robinpcrd.cupertino.CupertinoTextFieldDefaults
import io.github.robinpcrd.cupertino.ExperimentalCupertinoApi
import io.github.robinpcrd.cupertino.cancel
import io.github.robinpcrd.cupertino.destructive
import io.github.robinpcrd.cupertino.section.SectionItem
import io.github.robinpcrd.cupertino.section.SectionScope

/* ------------------------------ grouped rows ------------------------------ */

/**
 * Generic row inside a grouped card: caller draws the title body and
 * optionally a trailing control that owns its own hit target (provider/model
 * rows: name + status lines beside a switch). The title area is clickable
 * when [onClick] is provided; trailing slots stay independent so the 48dp
 * floor of embedded controls is never swallowed by the row's click.
 */
@Composable
fun SectionScope.FloeSectionRow(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    enabled: Boolean = true,
    description: String? = null,
    leading: (@Composable () -> Unit)? = null,
    title: @Composable () -> Unit,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    SectionItem(
        modifier = modifier
            .then(
                when {
                    onClick != null && onLongClick != null -> Modifier.combinedClickable(
                        enabled = enabled,
                        role = Role.Button,
                        onClick = onClick,
                        onLongClick = onLongClick,
                    )
                    onClick != null -> Modifier.clickable(enabled = enabled, role = Role.Button) { onClick() }
                    else -> Modifier
                }
            )
            .then(
                description?.let { label -> Modifier.semantics { contentDescription = label } }
                    ?: Modifier
            ),
        title = {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (leading != null) leading()
                Box(Modifier.weight(1f)) { title() }
                if (trailing != null) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        content = trailing,
                    )
                }
            }
        },
    )
}

/* ------------------------------ text fields ------------------------------ */

/**
 * Label-as-placeholder grouped form field (iOS `TextField("providers.base_url",
 * text:)` inside a Form section). The 48dp floor wraps the Cupertino field;
 * [isError] marks the row that carries the last preflight finding while the
 * rejected text stays visible for correction (no silent reset).
 *
 * Local adaptation note: Android IMEs do not expose iOS's
 * `textInputAutocapitalization`; [keyboardOptions] selects the closest input
 * surface (Uri/Number/Password keyboards suppress auto-capital behaviour in
 * practice).
 */
@Composable
fun SectionScope.FloeFormTextField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    readOnly: Boolean = false,
    singleLine: Boolean = true,
    maxLines: Int = 1,
    minLines: Int = 1,
    isError: Boolean = false,
    monospaced: Boolean = false,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
) {
    SectionItem(
        modifier = modifier,
        title = {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget),
                contentAlignment = Alignment.CenterStart,
            ) {
                CupertinoTextField(
                    value = value,
                    onValueChange = onValueChange,
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = label },
                    enabled = enabled,
                    readOnly = readOnly,
                    textStyle = (if (monospaced) Floe.typography.evidence else Floe.typography.body)
                        .copy(color = Floe.colors.label),
                    placeholder = {
                        FloeText(
                            label,
                            style = Floe.typography.body,
                            color = Floe.colors.placeholderText,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    isError = isError,
                    singleLine = singleLine,
                    maxLines = maxLines,
                    minLines = minLines,
                    keyboardOptions = keyboardOptions,
                    colors = CupertinoTextFieldDefaults.colors(),
                )
            }
        },
    )
}

/**
 * Secure credential field: the value stays RAM-only in the caller's editor
 * holder; it renders through [PasswordVisualTransformation] unless the caller
 * flips [revealed]. The eye toggle is an independent 48dp target that only
 * changes the local reveal state — revealing shows what the user typed in
 * this session and never fetches a stored secret (honesty invariant of the
 * provider UI contract).
 */
@Composable
fun SectionScope.FloeSecureFormField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    revealed: Boolean,
    onRevealedChange: (Boolean) -> Unit,
    revealOnLabel: String,
    revealOffLabel: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    isError: Boolean = false,
) {
    val colors = Floe.colors
    SectionItem(
        modifier = modifier,
        title = {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = FloeLayout.MinimumTarget),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    CupertinoTextField(
                        value = value,
                        onValueChange = onValueChange,
                        modifier = Modifier
                            .fillMaxWidth()
                            .semantics { contentDescription = label },
                        enabled = enabled,
                        textStyle = Floe.typography.body.copy(color = colors.label),
                        placeholder = {
                            FloeText(
                                label,
                                style = Floe.typography.body,
                                color = colors.placeholderText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        isError = isError,
                        singleLine = true,
                        visualTransformation = if (revealed) {
                            VisualTransformation.None
                        } else {
                            PasswordVisualTransformation()
                        },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        colors = CupertinoTextFieldDefaults.colors(),
                    )
                }
                val description = if (revealed) revealOffLabel else revealOnLabel
                Box(
                    modifier = Modifier
                        .size(FloeLayout.MinimumTarget)
                        .clickable(role = Role.Button) { onRevealedChange(!revealed) }
                        .semantics { contentDescription = description },
                    contentAlignment = Alignment.Center,
                ) {
                    IconGlyph(
                        if (revealed) FloeIcons.EyeSlash else FloeIcons.Eye,
                        colors.secondaryLabel,
                        20.dp,
                    )
                }
            }
        },
    )
}

/* ------------------------------- choosers -------------------------------- */

/**
 * Value chooser row (iOS `providers.supplier_field`): label leading, the
 * current selection as a secondary one-line value, double chevron trailing.
 * Tapping opens the caller's chooser surface; selection is a pure UI action
 * and never performs network I/O (contract).
 */
@Composable
fun SectionScope.FloeFormChooserRow(
    label: String,
    valueSummary: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = Floe.colors
    SectionItem(
        modifier = modifier.clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        title = {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .semantics { contentDescription = "$label: $valueSummary" },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeText(label, style = Floe.typography.body, color = colors.label)
                Spacer(Modifier.weight(1f))
                FloeText(
                    valueSummary,
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.widthIn(max = 280.dp),
                )
                IconGlyph(FloeIcons.ChevronUpDown, colors.tertiaryLabel, 16.dp)
            }
        },
    )
}

/** One entry of a [FloeChoiceMenu]. [key] is stable and caller-owned. */
data class FloeChoiceOption(val key: String, val label: String)

/**
 * Local choice menu (iOS `Picker` inside the provider form: OpenAI Responses /
 * OpenAI Chat Completions / Anthropic Messages). Rendering reuses the opaque
 * card + hairline + checkmark language of the design system. Opening a menu
 * sends nothing (contract); every entry owns the 48dp floor. The popup is a
 * separate window with zero layout footprint, so it can sit beside a
 * [SectionScope] row inside the same Box.
 */
@Composable
fun FloeChoiceMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    options: List<FloeChoiceOption>,
    selectedKey: String?,
    onSelect: (String) -> Unit,
) {
    if (!expanded) return
    val colors = Floe.colors
    val shape: Shape = RoundedCornerShape(FloeLayout.BubbleCorner)
    // Source capture 07: the protocol menu hangs from the row's trailing
    // edge, not from its leading edge. The Popup alignment anchor is the row
    // bounds passed by the Box in FloeFormChoiceField; TopEnd keeps the menu
    // beside the double-chevron without inventing viewport coordinates.
    Popup(
        alignment = Alignment.TopEnd,
        onDismissRequest = onDismissRequest,
        properties = PopupProperties(focusable = true),
    ) {
        Column(
            modifier = Modifier
                .widthIn(min = 220.dp, max = 340.dp)
                .clip(shape)
                .background(colors.sectionCardSurface)
                .border(0.5.dp, colors.chromeHairline, shape)
                .padding(vertical = 4.dp),
        ) {
            options.forEach { option ->
                val selected = option.key == selectedKey
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(role = Role.Button) { onSelect(option.key) }
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                        .semantics { contentDescription = option.label },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    FloeText(
                        option.label,
                        style = Floe.typography.body,
                        color = colors.label,
                        modifier = Modifier.weight(1f),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (selected) {
                        IconGlyph(FloeIcons.Checkmark, colors.accent, 18.dp)
                    }
                }
            }
        }
    }
}

/**
 * Stateful chooser row plus its [FloeChoiceMenu]: [expanded]/[onExpandedChange]
 * belong to the caller's RAM-only presentation state. A single-option choice
 * stays locked ([enabled] false) with the host-provided value, mirroring the
 * iOS `Picker.disabled(availableProtocols.count == 1)` behavior.
 */
@Composable
fun SectionScope.FloeFormChoiceField(
    label: String,
    options: List<FloeChoiceOption>,
    selectedKey: String?,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val selectedLabel = options.firstOrNull { it.key == selectedKey }?.label.orEmpty()
    Box {
        FloeFormChooserRow(
            label = label,
            valueSummary = selectedLabel,
            onClick = { onExpandedChange(true) },
            enabled = enabled,
            // Tag/layout live on the clickable row so semantics-driven tests
            // reach the real action, not an inert wrapper.
            modifier = modifier,
        )
        FloeChoiceMenu(
            expanded = expanded,
            onDismissRequest = { onExpandedChange(false) },
            options = options,
            selectedKey = selectedKey,
            onSelect = { key ->
                onExpandedChange(false)
                onSelect(key)
            },
        )
    }
}

/* --------------------------- action / status rows -------------------------- */

/**
 * Tappable section row with a leading title and a caller-drawn trailing
 * status slot (Test connection's spinner / "Connected (n)" / failed badge,
 * Manage Models, Refresh model list). [enabled] gates both the click and the
 * semantics-disabled state; a disabled row still reads its status text.
 */
@Composable
fun SectionScope.FloeActionRow(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    trailing: (@Composable RowScope.() -> Unit)? = null,
    testTag: String? = null,
) {
    val colors = Floe.colors
    SectionItem(
        modifier = modifier,
        title = {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .then(testTag?.let { Modifier.testTag(it) } ?: Modifier)
                    .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                    .semantics { if (!enabled) disabled() },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FloeText(
                    label,
                    style = Floe.typography.body,
                    color = if (enabled) colors.label else colors.secondaryLabel,
                    modifier = Modifier.weight(1f),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (trailing != null) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        content = trailing,
                    )
                }
            }
        },
    )
}

/** iOS ProgressView analog: explicit in-flight spinner (Save, Test, Refresh). */
@Composable
fun FloeActivityIndicator(
    modifier: Modifier = Modifier,
    description: String? = null,
) {
    CupertinoActivityIndicator(
        modifier = modifier
            .size(20.dp)
            .then(
                description?.let { label ->
                    Modifier.semantics { contentDescription = label }
                } ?: Modifier
            ),
        color = Floe.colors.secondaryLabel,
    )
}

enum class FloeBadgeTone { ACCENT, SECONDARY, PENDING, SUCCESS, DESTRUCTIVE }

/**
 * Capsule badge on a tinted fill (catalog "Configured" / "Unsupported",
 * model default / verified vision). Tone colors come from Floe roles only.
 */
@Composable
fun FloeBadgePill(
    text: String,
    tone: FloeBadgeTone = FloeBadgeTone.ACCENT,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    val tint = when (tone) {
        FloeBadgeTone.ACCENT -> colors.accent
        FloeBadgeTone.SECONDARY -> colors.secondaryLabel
        FloeBadgeTone.PENDING -> colors.pending
        FloeBadgeTone.SUCCESS -> colors.success
        FloeBadgeTone.DESTRUCTIVE -> colors.destructive
    }
    Box(
        modifier = modifier
            .clip(FloeLayout.SidebarSelectionShape)
            .background(tint.copy(alpha = 0.12f))
            .padding(horizontal = 6.dp, vertical = 2.dp)
            .semantics { contentDescription = text },
    ) {
        FloeText(
            text,
            style = Floe.typography.metadata,
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Metadata-status line with a leading glyph (waiting-for-secret, warnings,
 * inline save/test findings). Status stays readable through text+icon, not
 * color alone. */
@Composable
fun FloeStatusLine(
    icon: ImageVector,
    text: String,
    color: Color,
    modifier: Modifier = Modifier,
    style: TextStyle = Floe.typography.metadata,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        IconGlyph(icon, color, 14.dp)
        FloeText(text, style = style, color = color)
    }
}

/* ------------------------- switch / confirm dialogs ------------------------ */

/**
 * Raw enable switch for rows that draw their own title (provider and model
 * list rows): the Cupertino switch inside an explicit ≥48dp target box that
 * owns the toggle semantics.
 */
@Composable
fun FloeInlineSwitch(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    description: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    Box(
        modifier = modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .widthIn(min = FloeLayout.MinimumTarget)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        CupertinoSwitch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            modifier = Modifier
                .heightIn(min = FloeLayout.MinimumTarget)
                .widthIn(min = 64.dp),
            enabled = enabled,
        )
    }
}

/**
 * Destructive confirmation (provider delete). The confirm action runs only
 * after an explicit tap; dismissal performs nothing. Buttons follow the iOS
 * alert language through [CupertinoAlertDialog] helpers.
 */
@Composable
fun FloeConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    dismissLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    CupertinoAlertDialog(
        onDismissRequest = onDismiss,
        title = { FloeText(title, style = Floe.typography.section) },
        message = { FloeText(message, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) },
        buttons = {
            cancel(onClick = onDismiss) {
                FloeText(dismissLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.accent)
            }
            destructive(onClick = onConfirm) {
                FloeText(confirmLabel, style = Floe.typography.bodyEmphasized, color = Floe.colors.destructive)
            }
        },
    )
}

/**
 * Plain (non-section) grouped form field for embedding inside a custom row
 * body (numeric token-limit editors keep the preset chips and the exact input
 * in one row). Same text/placeholder/error language as
 * [FloeFormTextField]; it just has no SectionItem wrapper.
 */
@Composable
fun FloePlainFormField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    singleLine: Boolean = true,
    maxLines: Int = 1,
    minLines: Int = 1,
    isError: Boolean = false,
    monospaced: Boolean = false,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget),
        contentAlignment = Alignment.CenterStart,
    ) {
        CupertinoTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = label },
            enabled = enabled,
            textStyle = (if (monospaced) Floe.typography.evidence else Floe.typography.body)
                .copy(color = Floe.colors.label),
            placeholder = {
                FloeText(
                    label,
                    style = if (monospaced) Floe.typography.evidence else Floe.typography.body,
                    color = Floe.colors.placeholderText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            },
            isError = isError,
            singleLine = singleLine,
            maxLines = maxLines,
            minLines = minLines,
            keyboardOptions = keyboardOptions,
            colors = CupertinoTextFieldDefaults.colors(),
        )
    }
}

/* ------------------------------ sheet actions ----------------------------- */

/**
 * Capsule text action used in sheet chrome (Cancel leading, Save trailing in
 * the provider editor; Done in the model manager): white capsule, hairline,
 * ≥48dp target, accent or label text. Matches the reference sheet chips.
 */
@Composable
fun FloeCapsuleAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    tint: Color? = null,
    showHairline: Boolean = true,
) {
    val colors = Floe.colors
    val shape = FloeLayout.SidebarSelectionShape
    val textColor = when {
        !enabled -> colors.tertiaryLabel
        tint != null -> tint
        else -> colors.accent
    }
    Box(
        modifier = modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(shape)
            .background(colors.chromeSurface)
            .then(if (showHairline) Modifier.border(0.5.dp, colors.chromeHairline, shape) else Modifier)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = label
                if (!enabled) disabled()
            }
            .padding(horizontal = 18.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(label, style = Floe.typography.bodyEmphasized, color = textColor)
    }
}

/**
 * Full-width capsule choice button used by compact choosers (add-purpose
 * selection, prompt actions): 48dp target, iOS capsule shape, neutral gray
 * fill with label-colored text (⇄ the reference purpose chooser rows).
 */
@Composable
fun FloeCapsuleButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    prominent: Boolean = false,
    // Defaults preserve every existing capsule caller (one line + ellipsis).
    // The wide purpose popover opts into wrapping so translated/large-font
    // role labels are never clipped; its 52dp minimum grows with the text.
    maxLines: Int = 1,
) {
    val colors = Floe.colors
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(FloeLayout.SidebarSelectionShape)
            .background(if (prominent) colors.accent else colors.fillTertiary)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = label
                if (!enabled) disabled()
            }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.body,
            color = if (prominent) Color.White else colors.label,
            maxLines = maxLines.coerceAtLeast(1),
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/* ------------------------------ search field ------------------------------ */

/**
 * Persistent search field (iOS `.searchable` bar above the supplier/model
 * lists). Search here is a pure local computation over the immutable host
 * projection; typing never performs network I/O (contract).
 */
@Composable
fun FloeSearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
) {
    CupertinoSearchTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = FloeLayout.MinimumTarget)
            .semantics { contentDescription = placeholder },
        placeholder = {
            FloeText(
                placeholder,
                style = Floe.typography.body,
                color = Floe.colors.placeholderText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
    )
}
