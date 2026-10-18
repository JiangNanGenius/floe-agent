package com.floe.android

import com.floe.android.contracts.*

object DistributionModules {
    val distribution = Distribution.PLAY
    val sources: List<CapabilitySource> = emptyList()
    fun availableTools() = emptyList<Capability>()
}
