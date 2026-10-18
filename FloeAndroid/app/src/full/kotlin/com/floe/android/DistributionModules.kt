package com.floe.android

import com.floe.android.contracts.*
import com.floe.android.phonecontrol.PhoneControlModule
import com.floe.android.rootsystem.RootSystemModule

object DistributionModules {
    val distribution = Distribution.FULL
    val sources: List<CapabilitySource> = listOf(PhoneControlModule, RootSystemModule)
    fun availableTools() = sources.flatMap { it.capabilities() }.filter { it.availability == Availability.AVAILABLE }
}
