// SPDX-License-Identifier: MPL-2.0
//
// In-app user-question sheet (⇄ UserQuestionPanel/UserQuestionCardView).
//
// A question is ordinary conversation data, never an approval. The sheet
// works with notifications disabled; it displays the native snapshot, a
// free-text field/options, an honest deadline line and the explicit cancel.
// Settlement only ever comes back from the native receipt/store; this file
// never marks a question answered locally.
package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeCheckboxRow
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloePrimaryAction
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph

@Composable
fun UserQuestionSheet(holder: ConversationFlowHolder) {
    val question = holder.currentUserQuestion
    val draft = holder.userQuestionDraft
    FloePageSheet(
        visible = holder.showingUserQuestion && question != null,
        onDismiss = holder::dismissUserQuestionSheet,
    ) {
        if (question == null || draft == null) return@FloePageSheet
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(Floe.colors.readingSurface)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                IconGlyph(FloeIcons.Bubble, Floe.colors.accent, 22.dp)
                FloeText(
                    stringResource(R.string.user_question_title),
                    style = Floe.typography.title,
                    color = Floe.colors.label,
                    modifier = Modifier.weight(1f),
                )
            }
            FloeText(
                question.text,
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            if (question.waitPolicy == UserQuestionWaitPolicyUi.OPTIONAL_CONTINUE) {
                FloeText(
                    stringResource(R.string.user_question_optional),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            question.deadlineLabel?.let { deadline ->
                FloeText(
                    stringResource(R.string.user_question_expires, deadline),
                    style = Floe.typography.metadata,
                    color = Floe.colors.pending,
                )
            }
            if (question.options.isNotEmpty()) {
                FloeText(
                    stringResource(
                        if (question.selectionMode == UserQuestionSelectionModeUi.MULTIPLE) {
                            R.string.user_question_multiple
                        } else {
                            R.string.user_question_single
                        }
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Floe.colors.groupedSurface),
                ) {
                    question.options.forEachIndexed { index, option ->
                        FloeCheckboxRow(
                            label = option.label,
                            checked = option.id in draft.selectedOptionIds,
                            onCheckedChange = { holder.selectUserQuestionOption(option.id) },
                        )
                        option.detail?.takeIf { it.isNotBlank() }?.let { detail ->
                            FloeText(
                                detail,
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                                modifier = Modifier.padding(start = 42.dp, end = 12.dp, bottom = 8.dp),
                            )
                        }
                        if (index < question.options.lastIndex) FloeDivider()
                    }
                }
            }
            if (question.canAcceptFreeText) {
                FloePlainFormField(
                    label = stringResource(R.string.user_question_free_text_hint),
                    value = draft.freeText.text,
                    onValueChange = holder::setUserQuestionFreeText,
                    singleLine = false,
                    minLines = 1,
                    maxLines = 4,
                )
            }
            holder.userQuestionError?.let {
                FloeText(
                    stringResource(R.string.user_question_error),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
            }
            FloeText(
                stringResource(R.string.user_question_privacy),
                style = Floe.typography.metadata,
                color = Floe.colors.tertiaryLabel,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val cancelLabel = stringResource(R.string.user_question_cancel)
                Box(
                    modifier = Modifier
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(enabled = !holder.userQuestionSubmitting) {
                            holder.cancelUserQuestion()
                        }
                        .padding(horizontal = 4.dp)
                        .semantics { contentDescription = cancelLabel },
                    contentAlignment = Alignment.Center,
                ) {
                    FloeText(cancelLabel, style = Floe.typography.body, color = Floe.colors.destructive)
                }
                androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                FloePrimaryAction(
                    label = stringResource(R.string.user_question_send),
                    onClick = { holder.submitUserQuestion() },
                    enabled = holder.canSubmitUserQuestion() && !holder.userQuestionSubmitting,
                )
            }
        }
    }
}

/** Compact reminder while the sheet is dismissed and the question is still
 * pending. Required questions keep the run genuinely blocked; the bar never
 * pretends independent work can continue. */
@Composable
fun UserQuestionWaitingBar(holder: ConversationFlowHolder) {
    val question = holder.currentUserQuestion ?: return
    if (holder.showingUserQuestion) return
    val waiting = stringResource(R.string.user_question_waiting)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Floe.colors.pending.copy(alpha = 0.10f))
            .clickable { holder.openUserQuestionSheet() }
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .semantics { contentDescription = waiting },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        IconGlyph(FloeIcons.Bubble, Floe.colors.pending, 18.dp)
        FloeText(waiting, style = Floe.typography.metadata, color = Floe.colors.label, modifier = Modifier.weight(1f))
        FloeText(
            stringResource(R.string.user_question_send),
            style = Floe.typography.bodyEmphasized,
            color = Floe.colors.accent,
            modifier = Modifier.widthIn(min = 48.dp),
        )
    }
}
