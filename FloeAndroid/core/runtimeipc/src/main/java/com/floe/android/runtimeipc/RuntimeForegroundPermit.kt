// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import android.content.Context
import android.os.IBinder
import android.os.Parcel

/**
 * Opaque Core service-owned work permit, sent as a Binder object, never JSON.
 * Its Core implementation checks the exact runtime UID/signature and answers
 * true only while this owned operation and the REAL Core FGS are both active.
 * Model/tool arguments cannot mint or deserialize a permit.
 */
object RuntimeForegroundPermit {
    const val DESCRIPTOR = "com.floe.android.runtime.ForegroundPermit.v1"
    const val IS_ACTIVE = IBinder.FIRST_CALL_TRANSACTION

    /** Runtime-side only; callers must not hold a lock needed by the Core callback. */
    fun isActive(context: Context, permit: IBinder?): Boolean {
        if (permit == null || !permit.isBinderAlive) return false
        val pair = RuntimePackages.forRuntime(context.packageName)
        RuntimePeerVerifier(context).verifyPeer(pair.core)
        val request = Parcel.obtain()
        val response = Parcel.obtain()
        return try {
            request.writeInterfaceToken(DESCRIPTOR)
            if (!permit.transact(IS_ACTIVE, request, response, 0)) return false
            require(response.dataSize() <= 1024)
            response.readException()
            val active = response.readInt() == 1
            require(response.dataAvail() == 0)
            active
        } catch (_: android.os.RemoteException) { false }
        catch (_: SecurityException) { false }
        catch (_: IllegalArgumentException) { false }
        catch (_: IllegalStateException) { false }
        finally { request.recycle(); response.recycle() }
    }
}
