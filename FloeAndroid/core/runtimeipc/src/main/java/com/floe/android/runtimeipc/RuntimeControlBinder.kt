// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import android.content.Context
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import org.json.JSONObject

/** Handlers only admit work or read bounded state; never run commands on a Binder thread. */
class RuntimeControlBinder(
    context: Context,
    private val handle: (RuntimeWire.Request, IBinder?, IBinder?) -> JSONObject,
) : Binder() {
    private val verifier = RuntimePeerVerifier(context)
    private val peer = RuntimePackages.forRuntime(context.packageName).core

    init { attachInterface(null, RuntimeWire.DESCRIPTOR) }

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
        if (code == IBinder.INTERFACE_TRANSACTION) {
            verifier.requireCallingPeer(peer)
            reply?.writeString(RuntimeWire.DESCRIPTOR)
            return true
        }
        if (code != RuntimeWire.EXCHANGE) return super.onTransact(code, data, reply, flags)
        verifier.requireCallingPeer(peer)
        require(reply != null && flags and IBinder.FLAG_ONEWAY == 0)
        require(data.dataSize() <= RuntimeWire.MAX_PARCEL_BYTES)
        data.enforceInterface(RuntimeWire.DESCRIPTOR)
        val request = try { RuntimeWire.decode(requireNotNull(data.readString())) }
        catch (failure: org.json.JSONException) { throw IllegalArgumentException("Invalid runtime wire", failure) }
        val foregroundPermit = data.readStrongBinder()
        val workspaceGrant = data.readStrongBinder()
        require(data.dataAvail() == 0)
        // Identity was checked above, before any handler can start async work.
        // A native completion/lease-release operation is intentionally absent.
        val response = try {
            RuntimeWire.reply(request, handle(request, foregroundPermit, workspaceGrant))
        } catch (_: IllegalStateException) {
            RuntimeWire.failure(request, "runtime_not_ready")
        } catch (_: IllegalArgumentException) {
            RuntimeWire.failure(request, "invalid_request")
        } catch (_: org.json.JSONException) {
            RuntimeWire.failure(request, "invalid_request")
        }
        reply.writeNoException()
        reply.writeString(response)
        return true
    }
}
