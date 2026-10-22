// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import android.os.Parcel
import android.os.ParcelFileDescriptor
import org.json.JSONObject

/**
 * Bounded transport helpers shared by the grant and the runtime session.
 * Every request/reply is: interface token, ONE standard-JSON control string
 * (UTF-8 <= WorkspaceBridgeWire.MAX_CONTROL_BYTES), optionally ONE
 * ParcelFileDescriptor (via the framework's own fd-binder encoding). No
 * payload bytes ever enter Parcel strings; no whole file ever sits in RAM.
 */
internal object WorkspaceParcelIO {
    /** Headroom for the interface token + fd binder object; the JSON itself
     *  is the bounded unit. */
    private const val PARCEL_HEADROOM = 4096

    fun readControl(data: Parcel): String {
        data.enforceInterface(WorkspaceBridgeWire.DESCRIPTOR)
        require(data.dataSize() <= WorkspaceBridgeWire.MAX_CONTROL_BYTES + PARCEL_HEADROOM) { "control parcel too large" }
        val text = requireNotNull(data.readString()) { "missing control" }
        require(WorkspaceBridgeWire.fitsBound(text)) { "control over bound" }
        return text
    }

    /** Reads the optional PFD AFTER the control string; asserts nothing else
     *  remains in the parcel (strict schema, no smuggled buffers). A read
     *  failure on a malformed layout must throw (fail closed). */
    fun readOptionalDescriptor(data: Parcel): ParcelFileDescriptor? {
        if (data.dataAvail() == 0) return null
        val descriptor = data.readFileDescriptor()
            ?: throw IllegalArgumentException("declared descriptor missing")
        require(data.dataAvail() == 0) { "trailing parcel data after descriptor" }
        return descriptor
    }

    fun writeReply(reply: Parcel, json: JSONObject, descriptor: ParcelFileDescriptor? = null) {
        val text = json.toString()
        require(WorkspaceBridgeWire.fitsBound(text)) { "reply over bound" }
        reply.writeNoException()
        reply.writeString(text)
        if (descriptor != null) {
            reply.writeFileDescriptor(descriptor.fileDescriptor)
        }
    }

    fun readReply(response: Parcel): Pair<JSONObject, ParcelFileDescriptor?> {
        response.readException()
        require(response.dataSize() <= WorkspaceBridgeWire.MAX_CONTROL_BYTES + PARCEL_HEADROOM) { "reply parcel too large" }
        val text = requireNotNull(response.readString()) { "missing reply" }
        require(WorkspaceBridgeWire.fitsBound(text)) { "reply over bound" }
        val objectValue = JSONObject(text)
        val descriptor = if (response.dataAvail() > 0) {
            val value = response.readFileDescriptor()
                ?: throw IllegalArgumentException("declared reply descriptor missing")
            require(response.dataAvail() == 0) { "trailing reply data" }
            value
        } else null
        return objectValue to descriptor
    }
}
