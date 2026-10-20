// SPDX-License-Identifier: MPL-2.0
//
// DEBUG-ONLY synthetic preview for the provider presentation flow.
//
// This is NOT a working backend and is NOT reachable from release navigation:
// it renders labelled sample rows (never saved providers, never live history)
// so the binder/debug component preview can inspect the list composition
// before the shared Swift bridge is wired. Every value here is synthetic.
// The notice bar is mandatory and localized; a later binder must keep the
// label if it reuses this preview. Real entry stays
// [FloeProviderSettingsDestination] once the host binding is complete.

package com.floe.android.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeText

/** Labelled synthetic list preview (debug only). */
@Composable
fun ProviderUiSyntheticPreview(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Floe.colors.groupedSurface),
    ) {
        FloeText(
            text = stringResource(R.string.preview_synthetic_notice),
            style = Floe.typography.metadata,
            color = Floe.colors.pending,
            modifier = Modifier
                .fillMaxWidth()
                .background(Floe.colors.pending.copy(alpha = 0.10f))
                .padding(horizontal = 16.dp, vertical = 10.dp),
        )
        ProviderListPage(
            state = syntheticListState(),
            onAdd = {},
            onOpen = { _, _ -> },
            onToggleEnabled = { _, _ -> },
            onDeleteConfirmed = {},
        )
    }
}

/** Clearly synthetic fixtures: names carry no claim of a real provider. */
private fun syntheticListState(): ProviderListUiState = ProviderListUiState(
    isLoading = false,
    conversationProviders = listOf(
        ProviderListRowUi(
            providerId = "synthetic-provider-1",
            displayName = "Synthetic Chat Provider",
            endpointSummary = "https://synthetic.invalid/v1",
            modelCount = 2,
            enabled = true,
            credentialState = ProviderCredentialStateUi.AWAITING_CONFIGURATION,
        ),
    ),
    imageProviders = listOf(
        ProviderListRowUi(
            providerId = "synthetic-provider-2",
            displayName = "Synthetic Image Provider",
            endpointSummary = "https://synthetic.invalid/images",
            modelCount = 1,
            enabled = false,
            credentialState = ProviderCredentialStateUi.CONFIGURED,
        ),
    ),
)
