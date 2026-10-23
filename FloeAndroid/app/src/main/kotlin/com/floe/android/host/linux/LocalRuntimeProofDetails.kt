// SPDX-License-Identifier: MPL-2.0
@file:OptIn(io.github.robinpcrd.cupertino.ExperimentalCupertinoApi::class)

package com.floe.android.host.linux

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.design.Floe
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * Explicitly-opened technical details popup for the Diagnostics & About
 * "Local task execution" row.
 *
 * Same second-level Floe sheet framing the local-environment card uses
 * (centered rounded pane on wide windows, bottom sheet on compact), so the
 * stable two-column Settings page is untouched until the user opens it.
 * Everything shown is the CURRENT actual closed projection of the
 * ORIGINAL authorities (LocalRuntimeProofProjection): opening or
 * refreshing performs NO command, install, retry, resume or DNS query —
 * only the bounded metadata observations documented there. Missing or
 * unprovable values stay honestly "Unavailable"; the page NEVER marks
 * tool qualification ready from a UI read.
 */
@Composable
fun LocalRuntimeProofDetailsSheet(app: FloeApplication, onDismiss: () -> Unit) {
    var attempt by remember { mutableIntStateOf(0) }
    var details by remember { mutableStateOf<JsonObject?>(null) }
    var loading by remember { mutableStateOf(true) }
    LaunchedEffect(attempt) {
        loading = true
        // ONE bounded owned read per open/refresh; the composition only
        // observes, and closing the sheet cancels the pending read.
        details = runCatching { app.localRuntimeProofDetails() }.getOrNull()
        loading = false
    }
    val wide = LocalConfiguration.current.screenWidthDp >= 700
    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = if (wide) 0.62f else 1f,
        heightFraction = if (wide) 0.78f else 0.84f,
        placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
        topInset = if (wide) 0.dp else FloeLayout.SettingsSheetTopInset,
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 20.dp, vertical = 12.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                FloeText(
                    stringResource(R.string.diagnostics_details_title),
                    style = Floe.typography.title,
                    color = Floe.colors.label,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.diagnostics_details_refresh),
                    onClick = { attempt++ },
                    enabled = !loading,
                )
                Spacer(Modifier.width(8.dp))
                FloeCapsuleAction(label = stringResource(R.string.done), onClick = onDismiss)
            }
            Spacer(Modifier.height(8.dp))
            Column(
                Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .verticalScroll(rememberScrollState()),
            ) {
                val data = details
                if (data == null) {
                    FloeText(
                        stringResource(if (loading) R.string.checking else R.string.unavailable),
                        style = Floe.typography.body,
                        color = Floe.colors.secondaryLabel,
                    )
                } else {
                    ResolverSection(data["resolver"] as? JsonObject)
                    FloeDivider(Modifier.fillMaxWidth().padding(vertical = 10.dp))
                    CleanupSection(data["cleanup"] as? JsonObject)
                    FloeDivider(Modifier.fillMaxWidth().padding(vertical = 10.dp))
                    OwnedSection(data["owned"] as? JsonObject)
                }
                Spacer(Modifier.height(10.dp))
                FloeText(
                    stringResource(R.string.diagnostics_details_note_targets),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                Spacer(Modifier.height(6.dp))
                FloeText(
                    stringResource(R.string.diagnostics_details_note_readonly),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                Spacer(Modifier.height(12.dp))
            }
        }
    }
}

// MARK: - section renderers (labels localized; values are closed tokens)

@Composable
private fun SectionHeader(text: String) {
    Spacer(Modifier.height(6.dp))
    FloeText(text, style = Floe.typography.bodyEmphasized, color = Floe.colors.label)
    Spacer(Modifier.height(2.dp))
}

@Composable
private fun ProofRow(label: String, value: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 1.5.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        FloeText(
            label,
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            modifier = Modifier.weight(0.42f),
        )
        FloeText(
            value,
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            modifier = Modifier.weight(0.58f),
        )
    }
}

/** Token fields render raw (they are closed opaque tokens); numeric/bool
 *  fields format honestly; ANY absent key stays the localized Unavailable —
 * never a defaulted 0, false or "ready". */
@Composable
private fun tokenValue(section: JsonObject?, key: String): String {
    val token = LocalRuntimeProofProjection.text(section?.get(key))
    return when (token) {
        null -> stringResource(R.string.unavailable)
        "true" -> stringResource(R.string.yes)
        "false" -> stringResource(R.string.no)
        else -> token
    }
}

@Composable
private fun numberValue(section: JsonObject?, key: String): String {
    val raw = LocalRuntimeProofProjection.content(section?.get(key)) ?: return stringResource(R.string.unavailable)
    return raw.toLongOrNull()?.toString() ?: stringResource(R.string.unavailable)
}

@Composable
private fun booleanValue(section: JsonObject?, key: String): String {
    val raw = LocalRuntimeProofProjection.content(section?.get(key)) ?: return stringResource(R.string.unavailable)
    return when (raw) {
        "true" -> stringResource(R.string.yes)
        "false" -> stringResource(R.string.no)
        else -> stringResource(R.string.unavailable)
    }
}

@Composable
private fun ResolverSection(resolver: JsonObject?) {
    SectionHeader(stringResource(R.string.diagnostics_details_section_resolver))
    ProofRow(stringResource(R.string.diagnostics_row_availability), tokenValue(resolver, "availability"))
    if (resolver == null) return
    ProofRow(stringResource(R.string.diagnostics_row_state), tokenValue(resolver, "state"))
    ProofRow(stringResource(R.string.diagnostics_row_mode), tokenValue(resolver, "mode"))
    ProofRow(stringResource(R.string.diagnostics_row_effective), tokenValue(resolver, "effectivePrivateDns"))
    ProofRow(stringResource(R.string.diagnostics_row_servers), numberValue(resolver, "serverCount"))
    ProofRow(stringResource(R.string.diagnostics_row_probe), tokenValue(resolver, "probe"))
    ProofRow(stringResource(R.string.diagnostics_row_generation), numberValue(resolver, "snapshotGeneration"))
    ProofRow(stringResource(R.string.diagnostics_row_revalidations), numberValue(resolver, "revalidations"))
    ProofRow(stringResource(R.string.diagnostics_row_helper_install), tokenValue(resolver, "helperInstall"))
    ProofRow(stringResource(R.string.diagnostics_row_helper_present), booleanValue(resolver, "helperPresent"))
    ProofRow(stringResource(R.string.diagnostics_row_helper_verified), booleanValue(resolver, "helperVerified"))
    if (resolver["lastTransition"] != null) {
        ProofRow(stringResource(R.string.diagnostics_row_last_transition), tokenValue(resolver, "lastTransition"))
    }
    val bridge = resolver["bridge"] as? JsonObject
    if (bridge == null) {
        ProofRow(stringResource(R.string.diagnostics_row_bridge), stringResource(R.string.diagnostics_bridge_absent))
    } else {
        ProofRow(stringResource(R.string.diagnostics_row_bridge_state), tokenValue(bridge, "state"))
        ProofRow(stringResource(R.string.diagnostics_row_bridge_forwarded), numberValue(bridge, "forwarded"))
        ProofRow(stringResource(R.string.diagnostics_row_bridge_refused), numberValue(bridge, "refused"))
        ProofRow(stringResource(R.string.diagnostics_row_bridge_timed_out), numberValue(bridge, "timedOut"))
        ProofRow(stringResource(R.string.diagnostics_row_bridge_unauthorized), numberValue(bridge, "unauthorized"))
        ProofRow(stringResource(R.string.diagnostics_row_bridge_malformed), numberValue(bridge, "malformed"))
        ProofRow(stringResource(R.string.diagnostics_row_bridge_inflight), numberValue(bridge, "inflight"))
        ProofRow(stringResource(R.string.diagnostics_row_bridge_rejected), numberValue(bridge, "resolverRejected"))
        ProofRow(stringResource(R.string.diagnostics_row_bridge_last_error), tokenValue(bridge, "lastError"))
        if (bridge["resolverErrorCode"] != null) {
            ProofRow(
                stringResource(R.string.diagnostics_row_bridge_resolver_error),
                numberValue(bridge, "resolverErrorCode"),
            )
        }
    }
    val engine = resolver["engine"] as? JsonObject
    if (engine != null) {
        ProofRow(stringResource(R.string.diagnostics_row_engine_active), booleanValue(engine, "active"))
        ProofRow(stringResource(R.string.diagnostics_row_engine_stopping), booleanValue(engine, "stopping"))
        ProofRow(stringResource(R.string.diagnostics_row_engine_foreground), booleanValue(engine, "foregroundPermit"))
        ProofRow(stringResource(R.string.diagnostics_row_engine_local_network), booleanValue(engine, "localNetworkGranted"))
    }
}

@Composable
private fun CleanupSection(cleanup: JsonObject?) {
    SectionHeader(stringResource(R.string.diagnostics_details_section_cleanup))
    ProofRow(stringResource(R.string.diagnostics_row_availability), tokenValue(cleanup, "availability"))
    if (cleanup == null) return
    val aggregate = cleanup["aggregate"] as? JsonObject
    if (aggregate != null) {
        ProofRow(stringResource(R.string.diagnostics_row_cleanup_queued), numberValue(aggregate, "queued"))
        ProofRow(stringResource(R.string.diagnostics_row_cleanup_claimed), numberValue(aggregate, "claimed"))
        ProofRow(stringResource(R.string.diagnostics_row_cleanup_settled), numberValue(aggregate, "settled"))
        ProofRow(stringResource(R.string.diagnostics_row_cleanup_retained), numberValue(aggregate, "runtimeRefusalsRetained"))
    }
    val host = cleanup["host"] as? JsonObject
    if (host != null) {
        ProofRow(stringResource(R.string.diagnostics_row_cleanup_host_settled), numberValue(host, "settledCleared"))
        ProofRow(stringResource(R.string.diagnostics_row_cleanup_host_retained), numberValue(host, "retained"))
        ProofRow(stringResource(R.string.diagnostics_row_cleanup_last_reason), tokenValue(host, "lastReason"))
    }
    val targets = cleanup["targets"] as? JsonArray
    if (targets == null || targets.isEmpty()) {
        ProofRow(
            stringResource(R.string.diagnostics_cleanup_targets_title),
            stringResource(R.string.diagnostics_cleanup_targets_empty),
        )
    } else {
        targets.forEachIndexed { index, element ->
            val target = element as? JsonObject ?: return@forEachIndexed
            SectionHeader(
                stringResource(R.string.diagnostics_cleanup_targets_title) + " " + (index + 1),
            )
            ProofRow(stringResource(R.string.diagnostics_row_target_conversation), tokenValue(target, "conversation"))
            ProofRow(stringResource(R.string.diagnostics_row_target_ticket), tokenValue(target, "ticket"))
            ProofRow(stringResource(R.string.diagnostics_row_target_epoch), numberValue(target, "targetEpoch"))
            ProofRow(stringResource(R.string.diagnostics_row_target_state), tokenValue(target, "laneState"))
            ProofRow(stringResource(R.string.diagnostics_row_target_proof), tokenValue(target, "proof"))
            if (target["reason"] != null) {
                ProofRow(stringResource(R.string.diagnostics_row_target_reason), tokenValue(target, "reason"))
            }
            if (target["receiptDigest"] != null) {
                ProofRow(stringResource(R.string.diagnostics_row_target_digest), tokenValue(target, "receiptDigest"))
            }
        }
    }
}

@Composable
private fun OwnedSection(owned: JsonObject?) {
    SectionHeader(stringResource(R.string.diagnostics_details_section_owned))
    ProofRow(stringResource(R.string.diagnostics_row_availability), tokenValue(owned, "availability"))
    if (owned == null) return
    ProofRow(stringResource(R.string.diagnostics_owned_count), numberValue(owned, "operationCount"))
    val kinds = (owned["kinds"] as? JsonArray)
        ?.mapNotNull { LocalRuntimeProofProjection.text(it) }
        ?.sorted()
        ?.ifEmpty { null }
        ?.joinToString(", ")
    ProofRow(
        stringResource(R.string.diagnostics_owned_kinds),
        kinds ?: stringResource(R.string.diagnostics_owned_none),
    )
    ProofRow(stringResource(R.string.diagnostics_owned_foreground), booleanValue(owned, "foregroundConfirmed"))
    ProofRow(stringResource(R.string.diagnostics_owned_wake), booleanValue(owned, "cpuWakeHeld"))
}
