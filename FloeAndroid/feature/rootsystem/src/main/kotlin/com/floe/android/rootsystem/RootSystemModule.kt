// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

import com.floe.android.contracts.*

/** No su execution or root daemon in G01. G08 owns authorization and revocation. */
object RootSystemModule : CapabilitySource {
    override fun capabilities() = listOf(Capability("system.root", Availability.NOT_IMPLEMENTED))
}
