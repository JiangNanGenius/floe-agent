// SPDX-License-Identifier: MPL-2.0
//
// Inline approval presentation (⇄ FloeApp/Chat/ApprovalCardView.swift).
// Renders inline in the thread — never a full-screen modal. Every field on
// the card is a HOST projection of the real effect: the tool name, the
// normalized scope target, the deterministic risk labels and the policy
// reason. Approve/Deny dispatch ONLY the exact run+call identity through the
// holder (APR-CALL-BOUND); imported documents, web responses and tool output
// can never produce or widen a grant (APR-UNTRUSTED-NO-GRANT) — the only way
// a decision leaves this card is a human tap on these two controls.
// The catastrophic-gate `.stopped` presentation is destructive red and is
// NEVER weakened by the chosen tier (the runtime's second-auth release is
// the host's authority, not this UI's).

package com.floe.android.feature.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph

@Composable
fun ConversationApprovalRow(
    card: ApprovalCardUi,
    holder: ConversationFlowHolder,
    modifier: Modifier = Modifier,
    onResolve: ((ApprovalCardUi, Boolean) -> Unit)? = null,
) {
    val colors = Floe.colors
    val gateStopped = ApprovalGrantMapping.isGateStopped(card.reason)
    val headerTitle = stringResource(R.string.approval_required)
    val actionLabel = stringResource(R.string.approval_action)
    val scopeLabel = stringResource(R.string.approval_scope_label)
    val evidenceLabel = stringResource(R.string.approval_evidence)
    val chooseScopeLabel = stringResource(R.string.approval_scope_choose)
    val denyLabel = stringResource(R.string.action_deny)
    val approveLabel = stringResource(R.string.action_approve)
    val skillNote = stringResource(R.string.approval_skill_create_note)
    val tierLabels = listOf(
        stringResource(R.string.approval_scope_once),
        stringResource(R.string.approval_scope_task),
        stringResource(R.string.approval_scope_project),
        stringResource(R.string.approval_scope_host),
    )
    val headerTint = if (gateStopped) colors.destructive else colors.pending
    // One stable resolution lambda: the card NEVER fabricates a decision
    // without a human tap on these two controls.
    val resolve: (ApprovalCardUi, Boolean) -> Unit =
        onResolve ?: { c, allow -> holder.resolveApproval(c, allow) }
    val borderTint = headerTint.copy(alpha = 0.6f)
    val shape = RoundedCornerShape(FloeLayout.BubbleCorner)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .border(1.dp, borderTint, shape)
            .background(colors.groupedSurface)
            .padding(12.dp)
            .semantics { contentDescription = headerTitle },
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconGlyph(
                if (gateStopped) FloeIcons.ShieldAlert else FloeIcons.ShieldAlert,
                headerTint,
                20.dp,
            )
            FloeText(headerTitle, style = Floe.typography.section, color = colors.label)
            Spacer(Modifier.weight(1f))
            FloeText(card.requestedAtLabel, style = Floe.typography.metadata, color = colors.secondaryLabel)
        }

        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(actionLabel, style = Floe.typography.metadata, color = colors.secondaryLabel)
                FloeText(card.toolName, style = Floe.typography.evidence, color = colors.label)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(scopeLabel, style = Floe.typography.metadata, color = colors.secondaryLabel)
                FloeText(card.scopeDescription, style = Floe.typography.evidence, color = colors.label)
            }
            if (card.reason.isNotEmpty()) {
                FloeText(
                    card.reason,
                    style = Floe.typography.metadata,
                    color = if (gateStopped) colors.destructive else colors.secondaryLabel,
                )
            }
            if (ApprovalGrantMapping.isSkillCreation(card.toolName)) {
                FloeText(skillNote, style = Floe.typography.metadata, color = colors.pending)
            }
        }

        if (card.riskLabels.isNotEmpty()) {
            val riskGroupLabel = stringResource(R.string.approval_risks)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .semantics { contentDescription = riskGroupLabel },
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                card.riskLabels.sorted().forEach { raw ->
                    val localized = riskLabelText(raw)
                    FloeBadgePill(text = localized, tone = FloeBadgeTone.PENDING)
                }
            }
        }

        if (ApprovalGrantMapping.requiresEvidence(card.isSideEffecting, card.riskLabels)) {
            val expanded = card.key in holder.expandedApprovalEvidence.value
            Column {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable { holder.toggleApprovalEvidence(card.key) },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    IconGlyph(FloeIcons.ChevronUpDown, colors.accent, 14.dp)
                    FloeText(evidenceLabel, style = Floe.typography.metadata, color = colors.accent)
                    Spacer(Modifier.weight(1f))
                    IconGlyph(
                        if (expanded) FloeIcons.ChevronUp else FloeIcons.ChevronDown,
                        colors.secondaryLabel,
                        14.dp,
                    )
                }
                if (expanded) {
                    Spacer(Modifier.height(6.dp))
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(colors.readingSurface)
                            .padding(8.dp),
                    ) {
                        card.evidenceLines.forEach { line ->
                            FloeText(line, style = Floe.typography.evidence, color = colors.secondaryLabel)
                        }
                    }
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeText(chooseScopeLabel, style = Floe.typography.metadata, color = colors.secondaryLabel)
            val choice = holder.approvalScopeChoices.value[card.key] ?: ApprovalScopeChoiceUi.ONCE
            FloeSegmented(
                options = tierLabels,
                selectedIndex = ApprovalScopeChoiceUi.entries.indexOf(choice),
                onSelect = { index ->
                    holder.setApprovalScope(card.key, ApprovalScopeChoiceUi.entries[index])
                },
            )
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(FloeLayout.CircleToolbarCorner))
                    .border(0.5.dp, colors.chromeHairline, RoundedCornerShape(FloeLayout.CircleToolbarCorner))
                    .clickable { resolve(card, false) }
                    .semantics { contentDescription = denyLabel }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                FloeText(denyLabel, style = Floe.typography.bodyEmphasized, color = colors.label)
            }
            val allowTint = if (card.isSideEffecting) colors.destructive else colors.accent
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = FloeLayout.MinimumTarget)
                    .clip(RoundedCornerShape(FloeLayout.CircleToolbarCorner))
                    .background(allowTint)
                    .clickable { resolve(card, true) }
                    .semantics { contentDescription = approveLabel }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                FloeText(approveLabel, style = Floe.typography.bodyEmphasized, color = colors.readingSurface)
            }
        }
        if (gateStopped) {
            FloeDivider()
            // Honest statement of the host rule: the tier only narrows what
            // an ALLOW may remember; the catastrophic stop still needs the
            // runtime's second local authentication before anything runs.
            FloeText(
                stringResource(R.string.approval_gate_stopped_note),
                style = Floe.typography.metadata,
                color = colors.destructive,
            )
        }
    }
}

@Composable
private fun riskLabelText(raw: String): String {
    val key = ApprovalGrantMapping.riskLabelKey(raw)
    return when (key) {
        "risk_reads_files" -> stringResource(R.string.risk_reads_files)
        "risk_writes_files" -> stringResource(R.string.risk_writes_files)
        "risk_deletes_files" -> stringResource(R.string.risk_deletes_files)
        "risk_executes_local_code" -> stringResource(R.string.risk_executes_local_code)
        "risk_executes_remote_command" -> stringResource(R.string.risk_executes_remote_command)
        "risk_modifies_remote_system" -> stringResource(R.string.risk_modifies_remote_system)
        "risk_network_access" -> stringResource(R.string.risk_network_access)
        "risk_sends_data_to_provider" -> stringResource(R.string.risk_sends_data_to_provider)
        "risk_controls_gui" -> stringResource(R.string.risk_controls_gui)
        "risk_accesses_credentials" -> stringResource(R.string.risk_accesses_credentials)
        // Unknown catalog labels render their raw value (still non-secret),
        // exactly like the Swift fallback.
        else -> raw
    }
}
