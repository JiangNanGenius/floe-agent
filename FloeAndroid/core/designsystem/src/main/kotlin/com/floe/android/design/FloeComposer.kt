// SPDX-License-Identifier: MPL-2.0
@file:OptIn(ExperimentalCupertinoApi::class)

package com.floe.android.design

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import io.github.robinpcrd.cupertino.CupertinoDropdownMenu
import io.github.robinpcrd.cupertino.CupertinoMenuScope
import io.github.robinpcrd.cupertino.CupertinoTextField
import io.github.robinpcrd.cupertino.CupertinoTextFieldDefaults
import io.github.robinpcrd.cupertino.ExperimentalCupertinoApi
import io.github.robinpcrd.cupertino.MenuPickerAction

/* ----------------------------- pure state model ----------------------------- */

/** Backend availability gates surfaced honestly in G01. */
@Immutable
data class ComposerAvailability(
    val providerConfigured: Boolean,
    val attachmentsProcessing: Boolean = false,
    val voiceAvailable: Boolean = false,
    val temporaryChatAvailable: Boolean = false,
)

/**
 * Send gating mirroring iOS ThreadComposerView semantics:
 * - IME composed (marked) text must never send;
 * - blank drafts never send;
 * - the primary action is disabled while no provider is available.
 * Hardware Return inserts a newline on Android (no IME send action exists).
 */
object ComposerSendPolicy {
    fun canSend(draftBlank: Boolean, compositionActive: Boolean, availability: ComposerAvailability): Boolean =
        !compositionActive && !draftBlank && availability.providerConfigured && !availability.attachmentsProcessing

    /** An IME is still composing when a non-empty marked range is active. */
    fun compositionActive(value: TextFieldValue): Boolean {
        val composition = value.composition ?: return false
        return composition.length > 0
    }
}

/**
 * RAM-only draft store keyed by a stable slot id (iOS ComposerDraftStore
 * analogue for the foundation). Survives recomposition, navigation and
 * rotation while the process lives; nothing is promised across process death
 * and nothing is persisted before G02 storage.
 */
class FloeDraftStore {
    private val drafts = kotlin.collections.mutableMapOf<String, String>()

    fun draft(id: String): String = drafts[id].orEmpty()
    fun update(id: String, text: String) {
        drafts[id] = text
    }

    /** Called only by a confirmed send; G02 wires the failure restore path. */
    fun consume(id: String) {
        drafts.remove(id)
    }

    companion object {
        const val HOME_DRAFT = "floe.home.draft"
    }
}

/* --------------------------------- widget ----------------------------------- */

/**
 * Bottom composer: rounded chrome bar (r22 continuous, 0.5 hairline stroke,
 * h12/v8 inner padding), paperclip / growing field / mic / send, and a
 * horizontally scrolling context-chip row. Geometry mirrors
 * `ThreadComposerView.swift`; the field grows 1→6 lines (compact) or →8
 * (regular), capped at one third of the page height, then scrolls.
 *
 * Finish-review calibration (2026-10-18):
 * - the SHARED G01 default centres the chrome at a maximum of 720dp, like the
 *   iPad capture, so a 1280dp tablet does not stretch the composer across the
 *   detail column. A conversation host that knows its ACTUAL detail pane opts
 *   in through [layout] and fills the pane instead (the native
 *   `ThreadComposerView` has no 720pt cap);
 * - the whole composer sits above the bottom system inset (gesture/navigation
 *   bar) and the IME. `safeDrawing` resolves both without double-padding,
 *   unless the host already consumed those insets before measuring its pane;
 * - every leading/trailing control owns a 48dp clickable + semantics box and
 *   only the inner 34dp circle is visual. CupertinoTextField's own 280dp
 *   default minimum width is isolated inside a weighted slot so the trailing
 *   controls can never be pushed outside the chrome.
 *
 * [onInlineFieldWidthChanged] is an optional measurement uplink: the host uses
 * the real field slot width for its inline-overflow/expand rule instead of
 * reconstructing it from the window size. It is not used by G01 Home.
 */
@Composable
fun FloeComposer(
    value: TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit,
    availability: ComposerAvailability,
    placeholder: String,
    attachDescription: String,
    voiceDescription: String,
    sendDescription: String,
    onAttach: () -> Unit,
    onVoice: () -> Unit,
    onSend: () -> Unit,
    chips: @Composable RowScope.() -> Unit,
    modifier: Modifier = Modifier,
    isRunning: Boolean = false,
    onStop: () -> Unit = {},
    maxLines: Int = FloeLayout.ComposerMaxLinesRegular,
    layout: FloeComposerLayout = FloeComposerLayout.Default,
    onInlineFieldWidthChanged: ((Dp) -> Unit)? = null,
) {
    val colors = Floe.colors
    val shape = RoundedCornerShape(FloeLayout.ComposerCorner)
    // G01 default: screen-height third. Conversation opt-in: the ACTUAL
    // hosting page height (native `composerHeightBudget` proxy), so a split
    // pane, rotation or keyboard-shrunk pane changes the cap without reading
    // the global screen height again.
    val paneWidth = layout.paneWidth
    // The LocalConfiguration read is only evaluated by the G01 fallback; an
    // opted-in host never asks the composer to look at the window height.
    val heightCapDp = layout.pageHeight?.let(FloeComposerGeometry::fieldHeightCapFor)
        ?: (LocalConfiguration.current.screenHeightDp.dp / 3f)
    val density = LocalDensity.current
    val inlineFieldWidthReporter = onInlineFieldWidthChanged
    val canSend = ComposerSendPolicy.canSend(
        draftBlank = value.text.isBlank(),
        compositionActive = ComposerSendPolicy.compositionActive(value),
        availability = availability,
    )
    Box(
        modifier = modifier
            .fillMaxWidth()
            .then(
                if (layout.bottomInsetHandledByHost) {
                    // The host measured the pane AFTER consuming the bottom
                    // system/IME inset; adding it again would double-pad.
                    Modifier
                } else {
                    Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom))
                }
            )
            .padding(
                horizontal = FloeLayout.ComposerOuterHPadding,
                vertical = FloeLayout.ComposerOuterVPadding,
            ),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .wrapContentWidth(Alignment.CenterHorizontally)
                .then(
                    if (paneWidth != null) {
                        // The native composer fills the full detail pane; no
                        // 720dp reading cap and no phantom side gutter. The
                        // explicit pane width is the upper bound even if the
                        // composer is hosted in a slightly wider slot.
                        Modifier.widthIn(max = FloeComposerGeometry.chromeWidthFor(paneWidth))
                    } else {
                        Modifier.widthIn(max = FloeLayout.ComposerMaxWidth)
                    }
                )
                .clip(shape)
                .background(colors.chromeSurface)
                .border(FloeLayout.ComposerStrokeWidth, colors.separator, shape),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        PaddingValues(
                            start = FloeLayout.ComposerInnerHPadding,
                            end = FloeLayout.ComposerInnerHPadding,
                            top = FloeLayout.ComposerInnerVPadding,
                            bottom = 0.dp,
                        )
                    ),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(FloeLayout.ComposerRowSpacing),
            ) {
                ComposerControlSlot(
                    description = attachDescription,
                    onClick = onAttach,
                ) { IconGlyph(FloeIcons.Paperclip, colors.accent, 20.dp) }
                // The weighted slot absorbs CupertinoTextField's intrinsic
                // minimum width; the field then fills only that slot.
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .then(
                            inlineFieldWidthReporter?.let { reporter ->
                                // Real measured slot width for the conversation
                                // overflow/expand decision. onSizeChanged only
                                // fires when the integer size changes, so a
                                // stable pane cannot form a measurement loop.
                                Modifier.onSizeChanged { size ->
                                    reporter(with(density) { size.width.toDp() })
                                }
                            } ?: Modifier
                        ),
                ) {
                    CupertinoTextField(
                        value = value,
                        onValueChange = onValueChange,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = FloeLayout.MinimumTarget, max = heightCapDp)
                            .semantics { contentDescription = placeholder },
                        placeholder = {
                            FloeText(placeholder, style = Floe.typography.composerField, color = colors.placeholderText)
                        },
                        textStyle = Floe.typography.composerField.copy(color = colors.label),
                        minLines = FloeLayout.ComposerMinLines,
                        maxLines = maxLines,
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Text,
                            imeAction = ImeAction.Default,
                        ),
                        colors = CupertinoTextFieldDefaults.colors(),
                    )
                }
                // Voice: honest affordance in G01 (no permission is requested;
                // the component itself is real and reusable once the runtime lands).
                ComposerControlSlot(
                    description = voiceDescription,
                    onClick = onVoice,
                    background = colors.accentFillFaint,
                ) { IconGlyph(FloeIcons.Mic, colors.accent, 16.dp) }
                if (isRunning) {
                    StopControl(onStop)
                }
                // Send circle: disabled unless the policy allows it (G01: no
                // provider configured — send stays honestly disabled).
                ComposerControlSlot(
                    description = sendDescription,
                    enabled = canSend,
                    onClick = onSend,
                    background = if (canSend) colors.accent else colors.fillTertiary,
                ) {
                    IconGlyph(
                        FloeIcons.ArrowUp,
                        if (canSend) Color.White else colors.secondaryLabel,
                        16.dp,
                    )
                }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = FloeLayout.ComposerInnerHPadding),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
                content = chips,
            )
        }
    }
}

/**
 * 48dp actual click + semantics target with a smaller centred visual circle.
 * The whole target is clickable; the inner circle never owns hit testing.
 */
@Composable
private fun ComposerControlSlot(
    description: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    background: Color? = null,
    icon: @Composable () -> Unit,
) {
    Box(
        // No clip on the outer node: the full 48x48 square (including the
        // corners outside the visual circle) must accept the click/edge test.
        modifier = Modifier
            .size(FloeLayout.MinimumTarget)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = description
                if (!enabled) disabled()
            },
        contentAlignment = Alignment.Center,
    ) {
        if (background != null) {
            Box(
                modifier = Modifier
                    .size(FloeLayout.ComposerControlSize)
                    .clip(CircleShape)
                    .background(background),
                contentAlignment = Alignment.Center,
            ) { icon() }
        } else {
            icon()
        }
    }
}

@Composable
private fun StopControl(onStop: () -> Unit) {
    val colors = Floe.colors
    ComposerControlSlot(
        description = "Stop",
        onClick = onStop,
        background = colors.destructive,
    ) { IconGlyph(FloeIcons.StopSquare, Color.White, 15.dp) }
}

/** Context chip (model / reasoning / project / target / mode). */
@Immutable
enum class FloeChipTone { ACCENT, SECONDARY, PENDING }

/**
 * Context chip: a 48dp actual target holding the 32dp compact iOS pill.
 * Keeping the pill body compact preserves the captured density while Android
 * still gets a full-height hit area between neighbouring chips.
 */
@Composable
fun RowScope.FloeComposerChip(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    text: String,
    onClick: () -> Unit,
    tone: FloeChipTone = FloeChipTone.SECONDARY,
    description: String? = null,
) {
    val colors = Floe.colors
    val contentColor = when (tone) {
        FloeChipTone.ACCENT -> colors.accent
        FloeChipTone.SECONDARY -> colors.secondaryLabel
        FloeChipTone.PENDING -> colors.pending
    }
    Box(
        modifier = Modifier
            .height(FloeLayout.ComposerChipHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .then(description?.let { d -> Modifier.semantics { contentDescription = d } } ?: Modifier)
            .padding(vertical = (FloeLayout.ComposerChipHeight - FloeLayout.ComposerChipVisualHeight) / 2)
            .clip(RoundedCornerShape(percent = 50))
            .background(colors.groupedSurface)
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            IconGlyph(icon, contentColor, 14.dp)
            FloeText(
                text,
                style = Floe.typography.metadata,
                color = contentColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthAtMost(),
            )
        }
    }
}

@Composable
private fun Modifier.widthAtMost(): Modifier = this.then(Modifier.widthIn(max = 280.dp))

/** Picker row inside a [FloeChipMenu] (checkmark when selected). */
@Composable
fun CupertinoMenuScope.CupertinoMenuEntry(
    title: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    MenuPickerAction(
        isSelected = selected,
        onClick = onClick,
        onClickLabel = title,
        title = { FloeText(title, style = Floe.typography.body) },
    )
}

/**
 * iOS-style context menu over the composer chips (Cupertino dropdown menu).
 * Items render via the caller inside [CupertinoMenuScope].
 */
@Composable
fun FloeChipMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    content: @Composable CupertinoMenuScope.() -> Unit,
) {
    if (expanded) {
        CupertinoDropdownMenu(expanded = true, onDismissRequest = onDismiss, content = content)
    }
}
