// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkartifact

/**
 * JNI surface for the artifact mailbox. The Swift `NetworkArtifactHostMailbox`
 * owns every ticket and all semantic decisions; these methods only carry
 * bounded bytes for the App host. The C++ translation unit is Main-owned
 * (`core/swiftbridge/src/main/cpp/floe_network_artifact_jni.cpp`), so this
 * Kotlin class never links or decides anything by itself.
 */
internal object NetworkArtifactNative {
    init { System.loadLibrary("floe_jni") }

    external fun bindEpoch(epoch: Long): Int
    external fun next(timeoutMillis: Int): Long
    external fun describe(claim: Long): ByteArray?
    external fun payload(claim: Long): ByteArray?
    external fun isLive(claim: Long): Int
    external fun shouldStop(claim: Long): Int
    external fun complete(claim: Long, status: Int, value: ByteArray): Int
    external fun close(epoch: Long): Int
    external fun stats(): ByteArray?
    external fun readiness(): ByteArray?
}
