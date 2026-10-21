// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.floe.android.FloeApplication

/**
 * Composition access to the Application-owned [RuntimeHost]. Composables
 * only OBSERVE immutable projections — no JNI, disk, Keystore or network on
 * the main thread or inside composition; every command travels through the
 * host's background-dispatched client.
 */
val LocalRuntimeHost = compositionLocalOf<RuntimeHost?> { null }

@Composable
fun rememberRuntimeHost(): RuntimeHost? {
    val context = LocalContext.current
    return remember(context) {
        (context.applicationContext as? FloeApplication)?.runtimeHost
    }
}

/**
 * Installs the host into the composition and routes the host's
 * presentation side effects (navigation, inspector, permissions, attachment
 * picker) into the shell. Observing these flows here keeps them out of the
 * composables' event handlers and survives recomposition.
 */
@Composable
fun RuntimeHostProvider(
    host: RuntimeHost,
    content: @Composable () -> Unit,
) {
    CompositionLocalProvider(LocalRuntimeHost provides host) {
        content()
    }
}

/**
 * Attachment picker launcher. The host requests a pick; this launcher
 * presents the platform picker and hands the content URI back to the
 * host-owned staging pipeline (bounded copy → attachment.stage).
 *
 * Ownership (MAIN_ANDROID_PLATFORM_LAUNCH_OWNERSHIP_20261021): the
 * launcher callback carries no request identity of its own, so this effect
 * persists the exact `namespace:incarnation` launch identity it issued and
 * dispatches the result ONLY to the still-current pending request with that
 * full identity. A late callback for a superseded request, a cancel, or a
 * result restored after process death is DROPPED — never re-read blindly,
 * never broad-cancelled onto the current request, never rebound to a newer
 * request. A null uri therefore settles only the exact issued request's own
 * cancel through [AttachmentImportController.onPickerResult].
 */
@Composable
fun AttachmentPickerEffect(host: RuntimeHost) {
    val picker by host.attachments.pickerRequest.collectAsState()
    val namespace = host.attachments.launchNamespace
    var issuedKey by rememberSaveable(host) { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.GetContent(),
    ) { uri: Uri? ->
        val saved = PlatformLaunchOwnership.LaunchKey.decode(issuedKey)
        issuedKey = null
        when (val decision = PlatformLaunchOwnership.evaluateCallback(
            saved,
            host.attachments.pickerRequest.value?.incarnation,
            namespace,
        )) {
            is PlatformLaunchOwnership.CallbackDecision.Dispatch ->
                host.attachments.pickerRequest.value
                    ?.takeIf { it.incarnation == decision.incarnation }
                    ?.let { issued -> host.attachments.onPickerResult(issued, uri) }
            PlatformLaunchOwnership.CallbackDecision.Drop -> Unit
        }
    }
    LaunchedEffect(picker, issuedKey) {
        val request = picker ?: return@LaunchedEffect
        when (val decision = PlatformLaunchOwnership.evaluatePending(
            PlatformLaunchOwnership.LaunchKey.decode(issuedKey),
            request.incarnation,
            namespace,
        )) {
            is PlatformLaunchOwnership.PendingDecision.Launch -> {
                issuedKey = decision.savedKey.encode()
                launcher.launch("*/*")
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }
}

/**
 * S11: the Skills folder-picker launcher — a SEPARATELY owned lane from
 * the attachment picker above. The integrations host presents the SAF
 * OpenDocumentTree per captured request; THIS composable hands the result
 * back with the exact request it LAUNCHED for (never a re-read of a
 * replacement request in the late callback): a newer presentation
 * supersedes the owner and an older callback is fenced host-side.
 */
@Composable
fun SkillsFolderPickerEffect(host: RuntimeHost) {
    val staging = host.integrations.folderStaging
    val picker by staging.pickerRequest.collectAsState()
    // Preserve the exact issued launch identity across Activity recreation,
    // and never replace it while an older system picker still owns its
    // callback. The persisted key is the opaque per-host-generation
    // namespace plus the issued incarnation, so a counter reset after
    // process death can never rebind a restored pre-death callback to a
    // newer request (full rule: PlatformLaunchOwnership).
    val namespace = staging.launchNamespace
    var issuedKey by rememberSaveable(host) { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree(),
    ) { treeUri: Uri? ->
        val saved = PlatformLaunchOwnership.LaunchKey.decode(issuedKey)
        issuedKey = null
        when (val decision = PlatformLaunchOwnership.evaluateCallback(
            saved,
            staging.pickerRequest.value?.incarnation,
            namespace,
        )) {
            is PlatformLaunchOwnership.CallbackDecision.Dispatch ->
                staging.pickerRequest.value
                    ?.takeIf { it.incarnation == decision.incarnation }
                    ?.let { owner -> staging.onTreeResult(owner, treeUri) }
            PlatformLaunchOwnership.CallbackDecision.Drop -> Unit
        }
    }
    LaunchedEffect(picker, issuedKey) {
        val request = picker ?: return@LaunchedEffect
        when (val decision = PlatformLaunchOwnership.evaluatePending(
            PlatformLaunchOwnership.LaunchKey.decode(issuedKey),
            request.incarnation,
            namespace,
        )) {
            is PlatformLaunchOwnership.PendingDecision.Launch -> {
                issuedKey = decision.savedKey.encode()
                launcher.launch(null)
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }
}

/**
 * MAIN_ANDROID37_LAN_PERMISSION_DECISION_20261021: the local-network
 * permission lane. It mounts no automatic anything — it only (1) re-reads
 * the CURRENT platform state when the surface mounts (a plain cheap
 * checkSelfPermission read via the broker, never a request), (2) shows the
 * platform dialog when — and ONLY when — the broker's state flipped for a
 * captured EXPLICIT user action, and (3) echoes the real dialog result
 * back to the exact captured request. The broker re-reads the platform
 * after the result; a late callback for a replaced request is fenced
 * host-side. Public cloud never traverses this lane; API < 37 never sees
 * a request.
 */
@Composable
fun LocalNetworkPermissionEffect(host: RuntimeHost) {
    val broker = host.integrations.localNetwork
    val pending by broker.permissionRequest.collectAsState()
    val context = LocalContext.current
    // Same launch-ownership rule as the two picker lanes above: the
    // persisted launch identity is the broker's per-host-generation
    // namespace plus the issued incarnation, so a restored post-process-
    // death dialog result can never bind to a newer request even though
    // the broker's incarnation counter restarted at 1.
    val namespace = broker.launchNamespace
    var issuedKey by rememberSaveable(host) { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted: Boolean ->
        val saved = PlatformLaunchOwnership.LaunchKey.decode(issuedKey)
        issuedKey = null
        when (val decision = PlatformLaunchOwnership.evaluateCallback(
            saved,
            broker.permissionRequest.value?.incarnation,
            namespace,
        )) {
            is PlatformLaunchOwnership.CallbackDecision.Dispatch ->
                broker.permissionRequest.value
                    ?.takeIf { it.incarnation == decision.incarnation }
                    ?.let { owner ->
                        val activity = context as? android.app.Activity
                        val rationale = activity?.shouldShowRequestPermissionRationale(
                            LocalNetworkAccessBroker.PERMISSION_NAME,
                        ) ?: true
                        broker.onPermissionResult(owner, granted, rationale)
                    }
            PlatformLaunchOwnership.CallbackDecision.Drop -> Unit
        }
    }
    LaunchedEffect(broker) { broker.refreshCheck() }
    LaunchedEffect(pending, issuedKey) {
        val request = pending ?: return@LaunchedEffect
        when (val decision = PlatformLaunchOwnership.evaluatePending(
            PlatformLaunchOwnership.LaunchKey.decode(issuedKey),
            request.incarnation,
            namespace,
        )) {
            is PlatformLaunchOwnership.PendingDecision.Launch -> {
                issuedKey = decision.savedKey.encode()
                launcher.launch(LocalNetworkAccessBroker.PERMISSION_NAME)
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }
}
