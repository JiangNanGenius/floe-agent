// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

/** Read the real grant again when a system settings/consent screen returns. */
@Composable
internal fun rememberBackgroundPowerStatus(): BackgroundExecutionSettings.PowerStatus {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var status by remember(context) {
        mutableStateOf(BackgroundExecutionSettings.powerStatus(context))
    }
    DisposableEffect(context, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                status = BackgroundExecutionSettings.powerStatus(context)
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    return status
}

/**
 * Shared, honest route to the PUBLIC Android background/power settings plus a
 * REAL power-status read for this package. Opening a settings screen changes
 * nothing by itself and never asserts a grant; the only authoritative
 * exemption state is what [PowerStatus.ignoresBatteryOptimizations] reads
 * back afterwards (an OEM "Unrestricted" radio does NOT imply it).
 *
 * The two routes stay DISTINCT on purpose:
 *  * [openAppBatterySettings] — the exact-package App info screen, where
 *    OEMs expose their per-app battery controls (e.g. Samsung's
 *    Unrestricted/Optimized/Restricted radio).
 *  * [openOptimizationList] — the public battery-optimization list, where
 *    the user can allow Floe; this is the real Doze-exemption route.
 *
 * Neither route is presented as a guaranteed exemption, neither requests a
 * permission, and no automatic grant exists anywhere here: both are explicit
 * user actions.
 */
object BackgroundExecutionSettings {

    /**
     * Real power state for THIS package. A null field means the framework
     * answer was unavailable; nothing here is inferred or asserted.
     */
    data class PowerStatus(
        /** Authoritative Doze-exemption read (PowerManager
         *  isIgnoringBatteryOptimizations for our package). null = the
         *  framework answer was unavailable; never a guessed value. */
        val ignoresBatteryOptimizations: Boolean?,
        /** App standby bucket (API 28+); null when unreadable. */
        val standbyBucket: Int?,
    )

    /** Framework read of the CURRENT power state. Re-read after returning
     *  from any settings screen; a settings visit proves nothing by itself. */
    fun powerStatus(context: Context): PowerStatus {
        val ignores = runCatching {
            context.applicationContext
                .getSystemService(PowerManager::class.java)
                ?.isIgnoringBatteryOptimizations(context.packageName)
        }.getOrNull()
        val bucket = if (Build.VERSION.SDK_INT >= 28) {
            runCatching {
                context.applicationContext
                    .getSystemService(UsageStatsManager::class.java)
                    ?.appStandbyBucket
            }.getOrNull()
        } else {
            null
        }
        return PowerStatus(
            ignoresBatteryOptimizations = ignores,
            standbyBucket = bucket,
        )
    }

    /** The exact-package App info route. False when no handler accepted the
     *  intent (the caller then falls back or stays honest). */
    fun openAppBatterySettings(context: Context): Boolean = startSettings(
        context,
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:${context.packageName}")),
    )

    /** The public battery-optimization list (the real Doze-exemption
     *  route). The user finds Floe there and allows it explicitly. */
    fun openOptimizationList(context: Context): Boolean = startSettings(
        context,
        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
    )

    /**
     * Explicit user-triggered direct exemption request (Full channel only;
     * the Play stub returns false). true means the system consent dialog was
     * OPENED, never that a grant happened — the authoritative state remains
     * the PowerManager read after the user returns. Invoked only from an
     * explicit button; callers fall back to the ordinary settings routes on
     * false.
     */
    fun requestExemption(context: Context): Boolean =
        BackgroundExemptionRequest.launch(context)

    /**
     * [requestExemption] first (own-package consent dialog); on false falls
     * back to the exact-package App info route and then the optimization
     * list. Returns true when any route opened.
     */
    fun requestExemptionOrSettings(context: Context): Boolean =
        requestExemption(context) ||
            openAppBatterySettings(context) ||
            openOptimizationList(context)

    /**
     * Android-12+ background FGS launch restrictions. The Android-12-style
     * exemption/settings guidance must NOT be presented on API 28-30, where
     * that restriction (and its exemption surface) does not exist.
     */
    fun startRestrictionApplies(sdkInt: Int): Boolean = sdkInt >= 31

    private fun startSettings(context: Context, intent: Intent): Boolean =
        runCatching {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        }.getOrDefault(false)
}
