// SPDX-License-Identifier: MPL-2.0
//
// Connectors pane (⇄ SkillsView.swift ConnectorsView): "External services"
// (Mail accounts, GitHub) and "Tool sources" (Standard MCP) as navigation
// rows with honest captions. Account screens themselves belong to their own
// destinations/modules — this module only routes to them through the host
// and NEVER renders another module's UI or claims its state.
//
// Channel boundary: physically absent modules (GitHub updater / ADB / phone
// control on Play) are simply not projected as rows by the host; the module
// adds nothing on its own, so absence cannot be faked here.

package com.floe.android.feature.integrations

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeSectionRow
import com.floe.android.design.FloeSettingsSectionCard
import com.floe.android.design.FloeText

@Composable
fun ConnectorsPage(
    connectors: ConnectorsUiState,
    mcpEnabledCount: Int,
    onBack: () -> Unit,
    onOpenMcp: () -> Unit,
    onOpenDestination: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .testTag("connectors.page")
            .verticalScroll(rememberScrollState())
            .padding(vertical = 8.dp),
    ) {
        IntegrationPushedPaneHeader(title = stringResource(R.string.connectors_title), onBack = onBack)

        if (connectors.services.isNotEmpty()) {
            FloeSettingsSectionCard(title = stringResource(R.string.connectors_services)) {
                connectors.services.forEach { row ->
                    FloeSectionRow(
                        onClick = if (row.availability is ConnectorAvailabilityUi.Available) {
                            { onOpenDestination(row.destinationId) }
                        } else {
                            null
                        },
                        enabled = row.availability is ConnectorAvailabilityUi.Available,
                        title = {
                            Column {
                                FloeText(row.title, style = Floe.typography.body, color = Floe.colors.label)
                                row.subtitle?.let {
                                    FloeText(
                                        it,
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.secondaryLabel,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                                (row.availability as? ConnectorAvailabilityUi.Unavailable)?.let {
                                    FloeText(
                                        it.remediation,
                                        style = Floe.typography.metadata,
                                        color = Floe.colors.pending,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        },
                    )
                }
            }
        }

        FloeSettingsSectionCard(title = stringResource(R.string.connectors_tool_sources)) {
            FloeSectionRow(
                onClick = onOpenMcp,
                title = {
                    Column {
                        FloeText(stringResource(R.string.connectors_mcp_title), style = Floe.typography.body, color = Floe.colors.label)
                        FloeText(
                            stringResource(R.string.connectors_mcp_enabled_count, mcpEnabledCount),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                },
            )
            connectors.toolSources.forEach { row ->
                FloeSectionRow(
                    onClick = if (row.availability is ConnectorAvailabilityUi.Available) {
                        { onOpenDestination(row.destinationId) }
                    } else {
                        null
                    },
                    enabled = row.availability is ConnectorAvailabilityUi.Available,
                    title = {
                        Column {
                            FloeText(row.title, style = Floe.typography.body, color = Floe.colors.label)
                            (row.availability as? ConnectorAvailabilityUi.Unavailable)?.let {
                                FloeText(
                                    it.remediation,
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.pending,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    },
                )
            }
        }
        IntegrationSectionFooter(stringResource(R.string.connectors_footer))
        Spacer(Modifier.height(16.dp))
    }
}
