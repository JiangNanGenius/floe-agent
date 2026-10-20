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
import androidx.compose.runtime.remember
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
 */
@Composable
fun AttachmentPickerEffect(host: RuntimeHost) {
    val picker by host.attachments.pickerRequest.collectAsState()
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.GetContent(),
    ) { uri: Uri? ->
        val request = host.attachments.pickerRequest.value
        if (uri != null && request != null) {
            host.attachments.onPickerResult(request.session, uri)
        } else {
            host.attachments.cancelPicker()
        }
    }
    LaunchedEffect(picker) {
        picker?.let { launcher.launch("*/*") }
    }
}
