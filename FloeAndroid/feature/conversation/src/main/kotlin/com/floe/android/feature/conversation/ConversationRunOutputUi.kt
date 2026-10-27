// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph

/**
 * Per-item run-output cards (D04 owned outputs). The PURE gate object holds
 * the entire availability/action decision table so JVM tests can drive the
 * real production logic (no Robolectric, no Compose in tests); the row
 * composable renders ONLY what the host projection proved — it never
 * infers a file from markdown, paths or artifact metadata, and never shows
 * an all-enabled placeholder for bytes the native owner did not verify.
 */
internal object RunOutputCardPresentation {

    const val AVAILABLE = "available"
    const val MISSING = "missing"
    const val CHANGED = "changed"
    const val OVERSIZED = "oversized"
    const val REJECTED = "rejected"
    const val LOADING = "loading"
    const val UNAVAILABLE = "unavailable"

    const val ACTION_SAVING = "saving"
    const val ACTION_SAVED = "saved"
    const val ACTION_CANCELLED = "cancelled"
    const val ACTION_FAILED = "failed"

    /** ADVISORY App-only refusal note (NEVER produced by a native run-output
     * record and never an in-flight state): the host set it when this card's
     * in-app Open was honestly refused because the single-slot Office viewer
     * admission was already owned by another operation. Unlike the save
     * terminals, it keeps the card RE-TAPPABLE — closing the live viewer and
     * tapping Open again is the honest recovery — and a later admitted
     * attempt clears it. */
    const val ACTION_OPEN_BLOCKED = "open-blocked"

    /** Long-preserving file-size label (real MiB/KiB/B units, the same
     * convention the workspace pane uses). Byte metadata is NEVER shown
     * through the token-count formatter and never narrowed to Int: a
     * sealed Long byte count stays truthful at full range. */
    fun sizeLabel(bytes: Long): String = when {
        bytes >= 1_048_576 -> "%.1f MiB".format(bytes / 1_048_576.0)
        bytes >= 1_024 -> "%.1f KiB".format(bytes / 1_024.0)
        else -> "$bytes B"
    }

    private val OFFICE_MIMES = setOf(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    )
    private val OFFICE_EXTENSIONS = setOf("docx", "xlsx", "pptx")

    /** True only for an output whose LAST native availability answer was
     * "available": the sole state that may enable Save/Open. Every type
     * keeps Save; Open appears only where the host actually has a proven
     * in-app route (OOXML via the Office viewer; PDF via the App-owned
     * isolated-renderer preview below) — never a fake promise. */
    fun isActionable(availabilityRaw: String): Boolean =
        availabilityRaw == AVAILABLE

    /** Existing in-app Office open supports exactly DOCX/XLSX/PPTX by the
     * verified sealed MIME (extension agreement is re-checked host-side). */
    fun supportsOpen(mimeType: String, displayName: String): Boolean =
        mimeType in OFFICE_MIMES ||
            displayName.substringAfterLast('.', "").lowercase() in OFFICE_EXTENSIONS ||
            supportsPdfOpen(mimeType, displayName)

    /** Lane 17: a durable PDF run output opens IN-APP (verified staged bytes
     * → the SAME isolated renderer + system Print). The affordance appears
     * ONLY under verified agreement — the sealed MIME is exactly
     * `application/pdf` AND the sealed name ends `.pdf`; either alone is
     * not a PDF for this host, and byte-level proof (magic + whole-stream
     * digest) re-runs host-side at staging. The host re-checks the SAME
     * closed rule before routing. */
    fun supportsPdfOpen(mimeType: String, displayName: String): Boolean =
        mimeType == PDF_MIME &&
            displayName.substringAfterLast('.', "").lowercase() == "pdf"

    private const val PDF_MIME = "application/pdf"

    fun showsBusy(actionStateRaw: String?): Boolean =
        actionStateRaw == ACTION_SAVING

    /** Label resource for a transient action state (null = idle). */
    fun actionStateLabelRes(actionStateRaw: String?): Int? = when (actionStateRaw) {
        ACTION_SAVING -> R.string.run_output_saving
        ACTION_SAVED -> R.string.run_output_saved
        ACTION_CANCELLED -> R.string.run_output_save_cancelled
        ACTION_FAILED -> R.string.run_output_save_failed
        ACTION_OPEN_BLOCKED -> R.string.run_output_open_blocked
        else -> null
    }

    /** Label resource for a non-available availability state; null when the
     * card is actionable and needs no status caption. "loading"/"unavailable"
     * are honest transient/absent-lane states, never success fakes. */
    fun availabilityLabelRes(availabilityRaw: String): Int? = when (availabilityRaw) {
        AVAILABLE -> null
        MISSING -> R.string.run_output_missing
        CHANGED -> R.string.run_output_changed
        OVERSIZED -> R.string.run_output_oversized
        REJECTED -> R.string.run_output_rejected
        LOADING -> R.string.run_output_loading
        else -> R.string.run_output_unavailable
    }

    fun iconFor(mimeType: String) = when {
        mimeType.startsWith("image/") -> FloeIcons.Photo
        mimeType.startsWith("video/") -> FloeIcons.VideoPlus
        else -> FloeIcons.Chip
    }

    fun typeShortLabel(mimeType: String): String = when (mimeType) {
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "DOCX"
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> "XLSX"
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "PPTX"
        "application/pdf" -> "PDF"
        else -> mimeType.substringAfterLast('/', mimeType).uppercase().take(8)
    }
}

/** Does the CURRENT projection still carry this exact actionable card? A
 * card replaced by a refresh (or projected away) can never be tapped, and an
 * in-flight save or terminal save state stays fenced exactly as before. The
 * ONLY tolerated state is the advisory ACTION_OPEN_BLOCKED refusal note: it
 * captions a past busy refusal without disabling recovery — the card must
 * stay re-tappable so closing the live viewer and tapping Open again works. */
internal fun List<TimelineRowUi>.runOutputIsActionable(card: RunOutputCardUi): Boolean =
    filterIsInstance<TimelineRowUi.RunOutputGroup>()
        .firstOrNull { it.runId == card.runId }
        ?.outputs
        ?.any { it.outputId == card.outputId && RunOutputCardPresentation.isActionable(it.availabilityRaw) &&
            (it.actionStateRaw == null ||
                it.actionStateRaw == RunOutputCardPresentation.ACTION_OPEN_BLOCKED) } == true

/* --------------------------- timeline rows ---------------------------- */

/** One run's per-item sealed outputs: a compact hairline card per file with
 * native icon/typography, real availability states and only the actions the
 * host actually proved. */
@Composable
internal fun RunOutputGroupRow(
    row: TimelineRowUi.RunOutputGroup,
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        row.outputs.forEach { card -> RunOutputCardRow(card = card, holder = holder) }
        if (row.scanTruncated) {
            FloeText(
                text = stringResource(R.string.run_output_truncated),
                style = Floe.typography.evidence,
                color = Floe.colors.tertiaryLabel,
            )
        }
    }
}

@Composable
private fun RunOutputCardRow(card: RunOutputCardUi, holder: ConversationFlowHolder) {
    val colors = Floe.colors
    val actionable = RunOutputCardPresentation.isActionable(card.availabilityRaw)
    val busy = RunOutputCardPresentation.showsBusy(card.actionStateRaw)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(FloeLayout.BubbleCorner))
            .background(colors.sectionCardSurface)
            .border(0.5.dp, colors.chromeHairline, RoundedCornerShape(FloeLayout.BubbleCorner))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(RunOutputCardPresentation.iconFor(card.mimeType), colors.secondaryLabel, 16.dp)
        Column(modifier = Modifier.weight(1f)) {
            FloeText(
                text = card.displayName,
                style = Floe.typography.metadata,
                color = colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val availabilityLabel = RunOutputCardPresentation.availabilityLabelRes(card.availabilityRaw)
            val stateLabel = RunOutputCardPresentation.actionStateLabelRes(card.actionStateRaw)
            when {
                busy -> Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    FloeActivityIndicator()
                    FloeText(stringResource(stateLabel!!), style = Floe.typography.evidence,
                        color = colors.secondaryLabel)
                }
                stateLabel != null -> FloeText(
                    stringResource(stateLabel), style = Floe.typography.evidence,
                    color = if (card.actionStateRaw == RunOutputCardPresentation.ACTION_SAVED)
                        colors.success else colors.pending,
                )
                availabilityLabel != null -> FloeText(
                    stringResource(availabilityLabel), style = Floe.typography.evidence,
                    color = colors.pending,
                )
                else -> FloeText(
                    text = "${RunOutputCardPresentation.sizeLabel(card.byteCount)} · " +
                        RunOutputCardPresentation.typeShortLabel(card.mimeType),
                    style = Floe.typography.evidence,
                    color = colors.secondaryLabel,
                )
            }
        }
        if (actionable) {
            if (busy) {
                RunOutputActionButton(
                    label = stringResource(R.string.action_cancel),
                    enabled = true,
                    onClick = { holder.cancelRunOutputSave(card) },
                )
            } else {
                if (RunOutputCardPresentation.supportsOpen(card.mimeType, card.displayName)) {
                    RunOutputActionButton(
                        label = stringResource(R.string.run_output_open),
                        enabled = true,
                        onClick = { holder.openRunOutput(card) },
                    )
                }
                RunOutputActionButton(
                    label = stringResource(R.string.run_output_save),
                    enabled = true,
                    onClick = { holder.saveRunOutput(card) },
                )
            }
        } else if (card.availabilityRaw == RunOutputCardPresentation.MISSING ||
            card.availabilityRaw == RunOutputCardPresentation.CHANGED ||
            card.availabilityRaw == RunOutputCardPresentation.UNAVAILABLE ||
            card.availabilityRaw == RunOutputCardPresentation.REJECTED
        ) {
            // Visible + actionable: re-checking is the honest recovery step.
            RunOutputActionButton(
                label = stringResource(R.string.run_output_refresh),
                enabled = true,
                onClick = { holder.refreshRunOutputs(card.runId) },
            )
        }
    }
}

@Composable
private fun RunOutputActionButton(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = Floe.colors
    Box(
        modifier = Modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clip(RoundedCornerShape(8.dp))
            .border(0.5.dp, colors.chromeHairline, RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(label, style = Floe.typography.metadata, color = colors.accent)
    }
}
