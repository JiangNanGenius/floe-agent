// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)

package com.floe.android.feature.entryflow

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeText
import io.github.robinpcrd.cupertino.CupertinoTextField
import io.github.robinpcrd.cupertino.CupertinoTextFieldDefaults

public const val ENTRY_FEEDBACK_MAX_CHARACTERS: Int = 8_000

/**
 * User-authored feedback plus an explicit local export. The App host owns the
 * redaction and SAF write; this composable never performs IO, never sends
 * anything and never presents a technical code as ordinary copy.
 */
@Composable
public fun EntryFeedbackSection(
    state: EntryFeedbackUi,
    onProblemChange: (String) -> Unit,
    onIncludeDiagnostics: (Boolean) -> Unit,
    onExport: () -> Unit,
    onCancel: () -> Unit,
    onDismissReceipt: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Floe.colors
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        FloeText(
            stringResource(R.string.entry_feedback_problem_title),
            style = Floe.typography.section,
        )
        Spacer(Modifier.height(6.dp))
        CupertinoTextField(
            value = state.problem,
            onValueChange = { next ->
                if (next.length <= ENTRY_FEEDBACK_MAX_CHARACTERS) onProblemChange(next)
            },
            modifier = Modifier.fillMaxWidth(),
            textStyle = Floe.typography.body.copy(color = colors.label),
            placeholder = {
                FloeText(
                    stringResource(R.string.entry_feedback_problem_hint),
                    style = Floe.typography.body,
                    color = colors.placeholderText,
                )
            },
            singleLine = false,
            minLines = 6,
            maxLines = 10,
            colors = CupertinoTextFieldDefaults.colors(),
        )
        Row(
            Modifier.fillMaxWidth().padding(top = 4.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            FloeText(
                "${state.problem.length}/$ENTRY_FEEDBACK_MAX_CHARACTERS",
                style = Floe.typography.metadata,
                color = if (state.problem.length >= ENTRY_FEEDBACK_MAX_CHARACTERS) {
                    colors.destructive
                } else {
                    colors.secondaryLabel
                },
            )
        }
        FloeCheckboxRow(
            label = stringResource(R.string.entry_feedback_include),
            checked = state.includeDiagnostics,
            onCheckedChange = onIncludeDiagnostics,
        )
        FloeText(
            stringResource(R.string.entry_feedback_include_body),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 2.dp),
        )
        Spacer(Modifier.height(10.dp))
        if (state.busy) {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloeActivityIndicator(description = stringResource(R.string.entry_feedback_working))
                FloeText(
                    stringResource(R.string.entry_feedback_working),
                    style = Floe.typography.metadata,
                    color = colors.secondaryLabel,
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.entry_feedback_cancel),
                    onClick = onCancel,
                )
            }
        } else {
            FloePrimaryAction(
                label = stringResource(R.string.entry_feedback_export),
                onClick = onExport,
                modifier = Modifier.fillMaxWidth(),
                enabled = state.problem.isNotBlank(),
            )
        }
        state.error?.let { error ->
            Spacer(Modifier.height(8.dp))
            FloeText(
                stringResource(feedbackErrorText(error)),
                style = Floe.typography.metadata,
                color = colors.destructive,
            )
        }
        state.receipt?.let { receipt ->
            Spacer(Modifier.height(8.dp))
            FloeText(
                stringResource(
                    R.string.entry_feedback_saved,
                    receipt.byteCount,
                    receipt.sha256Prefix,
                ),
                style = Floe.typography.metadata,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.entry_action_done),
                onClick = onDismissReceipt,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        Spacer(Modifier.height(6.dp))
        FloeText(
            stringResource(R.string.entry_feedback_retention),
            style = Floe.typography.metadata,
            color = colors.secondaryLabel,
            modifier = Modifier.widthIn(max = 620.dp),
        )
    }
}

private fun feedbackErrorText(error: EntryFeedbackError): Int = when (error) {
    EntryFeedbackError.EMPTY_PROBLEM -> R.string.entry_feedback_empty_problem
    EntryFeedbackError.TOO_LONG -> R.string.entry_feedback_too_long
    EntryFeedbackError.CANCELLED -> R.string.entry_feedback_cancelled
    EntryFeedbackError.UNAVAILABLE, EntryFeedbackError.WRITE_FAILED -> R.string.entry_feedback_failed
}
