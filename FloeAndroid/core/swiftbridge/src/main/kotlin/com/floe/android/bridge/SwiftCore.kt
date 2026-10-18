// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import com.floe.android.contracts.BridgeProtocol

object SwiftCore {
    init { System.loadLibrary("floe_jni") }
    external fun exchange(request: String): String
    fun handshake(): String = exchange("""{"version":${BridgeProtocol.VERSION},"operation":"handshake","requestID":"bootstrap"}""")
}
