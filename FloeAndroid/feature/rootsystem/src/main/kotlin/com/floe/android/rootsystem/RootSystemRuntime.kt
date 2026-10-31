// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Single live status registry for the Full-only embedded system module. It does
 * not own grants or service state; the controller publishes only observed
 * lifecycle transitions. There is at most one attached controller so an old
 * App composition cannot keep publishing over a newer one.
 */
internal class RootSystemRuntime {

    private val mutableAdb = MutableStateFlow<AdbStatus>(AdbStatus.PairRequired)
    private val mutableRoot = MutableStateFlow<RootStatus>(RootStatus.Off)
    val adbStatus: StateFlow<AdbStatus> = mutableAdb.asStateFlow()
    val rootStatus: StateFlow<RootStatus> = mutableRoot.asStateFlow()

    private val gate = Any()
    private var controller: RootSystemController? = null
    private var pairingSupported = false

    fun attach(newController: RootSystemController) {
        val previous = synchronized(gate) {
            val old = controller
            controller = newController
            old
        }
        previous?.close()
    }

    fun detach(target: RootSystemController) {
        synchronized(gate) {
            if (controller === target) controller = null
        }
    }

    fun publish(adb: AdbStatus, root: RootStatus) {
        mutableAdb.value = adb
        mutableRoot.value = root
    }

    fun notePairingSupported(value: Boolean) {
        pairingSupported = value
        if (!value && mutableAdb.value is AdbStatus.PairRequired) {
            mutableAdb.value = AdbStatus.Disabled
        }
    }

    fun snapshot(): RootSystemSnapshot = RootSystemSnapshot(
        adb = mutableAdb.value,
        root = mutableRoot.value,
        pairingSupported = pairingSupported,
        pairingCodeRequired = mutableAdb.value is AdbStatus.PairRequired ||
            mutableAdb.value is AdbStatus.Pairing,
    )
}
