// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.systemservices

/**
 * App-owned C ABI for the C06 system-services platform mailbox.
 *
 * Swift owns the bounded ticket table and validates every request; this App
 * lane alone executes the real location/contacts/NFC/Health Connect call and
 * completes the ticket once. No model text, Intent, provider URI, raw path or
 * health record identifier crosses this ABI.
 *
 * The JNI class name is load-bearing: the additive translation unit
 * `floe_system_host_jni.cpp` exports
 * `Java_com_floe_android_host_systemservices_SystemServicesHostNative_*`.
 */
internal object SystemServicesHostNative {
    init {
        System.loadLibrary("floe_jni")
    }

    external fun bind(epoch: Long): Int
    external fun laneReady(epoch: Long): Int
    external fun next(timeoutMillis: Int): Long
    external fun describe(claim: Long): ByteArray?
    external fun complete(claim: Long, status: Int, data: ByteArray?): Int
    external fun shouldStop(claim: Long): Boolean
    external fun closeAll(timeoutMillis: Int): Int
    external fun laneClosed(epoch: Long): Int
    external fun stats(): ByteArray?
}

internal interface SystemHostBridge {
    fun bind(epoch: Long): Int
    fun laneReady(epoch: Long): Int
    fun next(timeoutMillis: Int): Long
    fun describe(claim: Long): ByteArray?
    fun complete(claim: Long, status: Int, data: ByteArray?): Int
    fun shouldStop(claim: Long): Boolean
    fun closeAll(timeoutMillis: Int): Int
    fun laneClosed(epoch: Long): Int
    fun stats(): ByteArray?
}

internal object PlatformSystemHostBridge : SystemHostBridge {
    override fun bind(epoch: Long): Int = SystemServicesHostNative.bind(epoch)
    override fun laneReady(epoch: Long): Int = SystemServicesHostNative.laneReady(epoch)
    override fun next(timeoutMillis: Int): Long = SystemServicesHostNative.next(timeoutMillis)
    override fun describe(claim: Long): ByteArray? = SystemServicesHostNative.describe(claim)
    override fun complete(claim: Long, status: Int, data: ByteArray?): Int =
        SystemServicesHostNative.complete(claim, status, data)
    override fun shouldStop(claim: Long): Boolean = SystemServicesHostNative.shouldStop(claim)
    override fun closeAll(timeoutMillis: Int): Int = SystemServicesHostNative.closeAll(timeoutMillis)
    override fun laneClosed(epoch: Long): Int = SystemServicesHostNative.laneClosed(epoch)
    override fun stats(): ByteArray? = SystemServicesHostNative.stats()
}
