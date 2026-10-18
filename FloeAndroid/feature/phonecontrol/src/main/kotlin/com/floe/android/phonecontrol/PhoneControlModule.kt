// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import com.floe.android.contracts.*

/** G01 distribution boundary only; no service/permission is registered until G08. */
object PhoneControlModule : CapabilitySource {
    override fun capabilities() = listOf(Capability("device.control", Availability.NOT_IMPLEMENTED))
}
