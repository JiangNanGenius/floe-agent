// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.content.Context
import com.floe.android.contracts.Availability
import com.floe.android.contracts.Capability
import com.floe.android.contracts.CapabilitySource
import kotlinx.coroutines.flow.StateFlow

/**
 * Public entry point for the Full-only phone-control module.
 *
 * This object is intentionally thin: it owns no grant state, never enables the
 * accessibility service, and never pretends the service is available before
 * Android has actually bound it. `device.control` is AVAILABLE only when the
 * service is connected and the process fence is open; screenshot support is
 * separately UNSUPPORTED below API 30.
 *
 * Integration (Main/App host):
 *  - construct one client with the current task/run/grant authority callback;
 *  - use [PhoneControlJson] for the Agent-facing observation/action payload;
 *  - return screenshot bytes through the host's bounded artifact path, never as
 *    inline JSON or a log.
 */
object PhoneControlModule : CapabilitySource {
    val status: StateFlow<PhoneControlStatus> get() = PhoneControlRuntime.status

    fun statusSnapshot(): PhoneControlStatus = PhoneControlRuntime.snapshot()

    fun client(context: Context, authority: PhoneControlAuthority): PhoneControlClient =
        PhoneControlClient(context.applicationContext, authority)

    fun activation(context: Context): PhoneControlActivation =
        PhoneControlActivation(context.applicationContext)

    /** Context-aware form distinguishes "not enabled" from "enabled but not bound". */
    fun capabilities(context: Context): List<Capability> =
        buildCapabilities(PhoneControlActivation(context.applicationContext).isEnabled())

    override fun capabilities(): List<Capability> = buildCapabilities(null)

    private fun buildCapabilities(enabledFromContext: Boolean?): List<Capability> {
        val snapshot = PhoneControlRuntime.snapshot()
        val enabled = enabledFromContext ?: snapshot.enabled
        val base = when {
            !enabled -> Availability.NEEDS_PERMISSION
            !snapshot.connected -> Availability.NEEDS_CONFIGURATION
            snapshot.blocker != null -> Availability.NEEDS_CONFIGURATION
            else -> Availability.AVAILABLE
        }
        val screenshot = when {
            snapshot.screenshotSupport == PhoneControlScreenshotSupport.NONE ->
                Availability.UNSUPPORTED
            !enabled -> Availability.NEEDS_PERMISSION
            !snapshot.connected -> Availability.NEEDS_CONFIGURATION
            snapshot.blocker != null -> Availability.NEEDS_CONFIGURATION
            else -> Availability.AVAILABLE
        }
        return listOf(
            Capability("device.control", base),
            Capability("device.control.screenshot", screenshot),
        )
    }
}
