// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import android.content.Context
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.RemoteException
import com.floe.android.runtimeipc.RuntimeForegroundPermit
import com.floe.android.runtimeipc.RuntimePeerVerifier

/**
 * The Core-side implementation of the Main-authored opaque permit protocol
 * (`com.floe.android.runtime.ForegroundPermit.v1`, transaction IS_ACTIVE).
 * One token exists per live lease registration and is handed to Main's
 * integration ONLY as a Binder object over the existing RuntimeConnection
 * exchange — never serialized into model JSON, never deserialized, never
 * minted from a payload.
 *
 * Every transaction, BEFORE any clearCallingIdentity and before any async
 * dispatch (there is none), must prove the EXACT runtime channel: the
 * dedicated runtime package UID from the recognized Core channel pair, its
 * matching signing identity, and Binder.getCallingUid() equality. The
 * verifier reads these on the binder thread itself. Own-UID and signature
 * alone are insufficient by construction.
 *
 * IS_ACTIVE answers 1 only while BOTH hold: this exact operation
 * registration (this owner generation) is still owned AND the real Core
 * foreground service is confirmed running. The answer is computed from a
 * concurrent-map read and one volatile flag — no native call, no disk, no
 * UI hop, no long lock, so the callback cannot deadlock a nested binder
 * transaction from the runtime process.
 *
 * A token whose operation ended stays valid as an object (the runtime may
 * still hold it to observe the transition), but it answers 0 forever; the
 * runtime treats 0 / binder death as its signal to request a REAL process
 * stop. Binder death never equals lease release on either side.
 */
internal class RunForegroundPermitBinder(
    private val coreContext: Context,
    private val operationID: String,
    private val ownerGeneration: Long,
    private val runtimePackageName: String,
) : Binder() {

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
        if (code != RuntimeForegroundPermit.IS_ACTIVE) {
            // Unknown / framework codes: super enforces the interface token
            // for real transaction codes and handles ping/dump. Nothing here
            // exposes another operation, and there is deliberately NO other
            // accepted business code.
            return super.onTransact(code, data, reply, flags)
        }
        // Main-authored wire discipline, enforced exactly:
        if (flags and IBinder.FLAG_ONEWAY != 0) {
            throw RemoteException("Permit IS_ACTIVE requires a reply")
        }
        data.enforceInterface(RuntimeForegroundPermit.DESCRIPTOR)
        if (data.dataAvail() != 0) {
            throw SecurityException("Permit transactions carry no arguments")
        }
        if (reply == null) {
            throw RemoteException("Permit IS_ACTIVE requires a reply parcel")
        }
        // Prove the exact runtime peer BEFORE any identity mutation or work.
        RuntimePeerVerifier(coreContext).requireCallingPeer(runtimePackageName)
        val active = RunForegroundState.permitActive(operationID, ownerGeneration)
        reply.writeNoException()
        reply.writeInt(if (active) 1 else 0)
        return true
    }
}
