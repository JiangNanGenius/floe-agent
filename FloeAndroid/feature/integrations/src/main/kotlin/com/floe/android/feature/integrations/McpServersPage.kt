// SPDX-License-Identifier: MPL-2.0
//
// MCP server list (⇄ SkillsView.swift MCPServersView), row-for-row:
//  - empty: ContentUnavailableView("no MCP server added yet", description)
//    ⇄ FloeUnavailableView;
//  - rows: leading state glyph (checkmark.circle.fill /
//    arrow.triangle.2.circlepath / exclamationmark.triangle.fill / circle),
//    name, endpoint, state text ("Not connected" / "Reading tools…" /
//    "n tools available" / "Connection failed: …"), trailing enable switch,
//    tap → editor, long-press → delete (⇄ swipeActions destructive);
//  - footer: ⇄ "supports standard Streamable HTTP…" security note;
//  - toolbar add ⇄ portforward.add.
//
// Tool counts and connection success ONLY ever come from a host Ready(n)
// projection (McpDisplayLogic); a connecting row never shows a count.

package com.floe.android.feature.integrations

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeInlineSwitch
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import io.github.robinpcrd.cupertino.section.SectionScope

@Composable
fun McpServersPage(
    mcp: McpServersUiState,
    holder: IntegrationsFlowHolder,
    onBack: () -> Unit,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var deleteCandidate by remember { mutableStateOf<McpServerRowUi?>(null) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .testTag("mcp.servers")
            .verticalScroll(rememberScrollState())
            .padding(vertical = 8.dp),
    ) {
        McpListHeader(
            title = stringResource(R.string.connectors_mcp_title),
            onBack = onBack,
            onAdd = onAdd,
        )

        if (mcp.isLoading && mcp.isEmpty) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                FloeActivityIndicator(description = stringResource(R.string.loading_cd))
            }
            return@Column
        }

        if (mcp.isEmpty) {
            FloeUnavailableView(
                icon = FloeIcons.Antenna,
                title = stringResource(R.string.mcp_empty_title),
                description = stringResource(R.string.mcp_empty_hint),
                modifier = Modifier.padding(vertical = 24.dp),
                action = {
                    CardActionLink(
                        label = stringResource(R.string.mcp_add),
                        tag = "mcp.emptyAdd",
                        onClick = onAdd,
                    )
                },
            )
        } else {
            FloeSettingsSectionCard(title = null) {
                mcp.servers.forEach { row ->
                    McpServerRow(
                        row = row,
                        holder = holder,
                        onOpen = { holder.openMcpEditor(row.serverId) },
                        onLongPress = { deleteCandidate = row },
                    )
                }
            }
        }
        IntegrationSectionFooter(stringResource(R.string.mcp_footer))

        mcp.errorMessage?.let {
            IntegrationIssueLine(it, modifier = Modifier.testTag("mcp.errorMessage"))
        }
        Spacer(Modifier.height(16.dp))
    }

    val candidate = deleteCandidate
    if (candidate != null) {
        FloeConfirmDialog(
            title = stringResource(R.string.mcp_delete_title),
            message = stringResource(R.string.mcp_delete_message),
            confirmLabel = stringResource(R.string.action_delete),
            dismissLabel = stringResource(R.string.action_cancel),
            onConfirm = {
                deleteCandidate = null
                holder.deleteMcpServer(candidate.serverId, confirmed = true)
            },
            onDismiss = { deleteCandidate = null },
        )
    }
}

/** Back + large title leading, circular Add trailing (⇄ toolbar placement). */
@Composable
private fun McpListHeader(title: String, onBack: () -> Unit, onAdd: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 8.dp, end = 12.dp, top = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(Modifier.weight(1f)) {
            IntegrationPushedPaneHeader(title = title, onBack = onBack)
        }
        IntegrationCircleAction(
            icon = FloeIcons.Plus,
            contentDescription = stringResource(R.string.mcp_add),
            onClick = onAdd,
        )
    }
}

@Composable
private fun SectionScope.McpServerRow(
    row: McpServerRowUi,
    holder: IntegrationsFlowHolder,
    onOpen: () -> Unit,
    onLongPress: () -> Unit,
) {
    val cancelling = holder.isMcpRefreshCancelling(row)
    val badge = McpDisplayLogic.connectionBadge(state = row.state, cancelling = cancelling)
    FloeSectionRow(
        onClick = onOpen,
        onLongClick = onLongPress,
        description = stringResource(R.string.mcp_row_cd, row.displayName),
        leading = {
            Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) {
                if (badge is McpConnectionBadge.ReadingTools || badge is McpConnectionBadge.Cancelling) {
                    FloeActivityIndicator(description = null)
                } else {
                    IconGlyph(
                        icon = stateGlyph(badge),
                        tint = stateColor(badge),
                        size = 20.dp,
                    )
                }
            }
        },
        title = {
            Column {
                FloeText(
                    row.displayName,
                    style = Floe.typography.body,
                    color = Floe.colors.label,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeText(
                    row.endpointDisplay,
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                FloeText(
                    text = badgeLabel(badge),
                    style = Floe.typography.metadata,
                    color = when (badge) {
                        is McpConnectionBadge.Failed -> Floe.colors.destructive
                        else -> Floe.colors.secondaryLabel
                    },
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                // A connecting row can REQUEST a real cancellation; the
                // "Cancelling…" text only appears once the host accepts it.
                if (badge is McpConnectionBadge.ReadingTools) {
                    CardActionLink(
                        label = stringResource(R.string.mcp_cancel_refresh),
                        tag = "mcp.cancelRefresh",
                        onClick = { holder.cancelMcpRefresh(row) },
                    )
                }
            }
        },
        trailing = {
            FloeInlineSwitch(
                checked = row.enabled,
                onCheckedChange = { holder.setMcpServerEnabled(row.serverId, it) },
                description = stringResource(R.string.mcp_enable_cd),
            )
        },
    )
}

private fun stateGlyph(badge: McpConnectionBadge): ImageVector = when (badge) {
    is McpConnectionBadge.Ready -> FloeIcons.CheckCircle
    is McpConnectionBadge.Failed -> FloeIcons.WarningTriangle
    McpConnectionBadge.NotConnected -> FloeIcons.Xmark
    McpConnectionBadge.ReadingTools,
    McpConnectionBadge.Cancelling,
    -> FloeIcons.Refresh
}

@Composable
private fun stateColor(badge: McpConnectionBadge): androidx.compose.ui.graphics.Color = when (badge) {
    is McpConnectionBadge.Ready -> Floe.colors.success
    is McpConnectionBadge.Failed -> Floe.colors.pending
    else -> Floe.colors.secondaryLabel
}

@Composable
private fun badgeLabel(badge: McpConnectionBadge): String = when (badge) {
    McpConnectionBadge.NotConnected -> stringResource(R.string.mcp_state_not_connected)
    McpConnectionBadge.ReadingTools -> stringResource(R.string.mcp_state_reading_tools)
    McpConnectionBadge.Cancelling -> stringResource(R.string.mcp_state_cancelling)
    is McpConnectionBadge.Ready -> stringResource(R.string.mcp_state_tools_available, badge.count)
    is McpConnectionBadge.Failed -> stringResource(R.string.mcp_state_failed, badge.message)
}

/** Accent text action with an explicit 48dp-friendly padded target. */
@Composable
internal fun CardActionLink(label: String, tag: String, onClick: () -> Unit) {
    FloeText(
        label,
        style = Floe.typography.bodyEmphasized,
        color = Floe.colors.accent,
        modifier = Modifier
            .testTag(tag)
            .padding(vertical = 6.dp, horizontal = 2.dp)
            .clickable(onClick = onClick),
    )
}
