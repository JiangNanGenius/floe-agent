// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import android.content.Context
import android.content.pm.PackageManager
import android.os.Binder
import android.os.Process

/** Both ends require an exact package UID AND matching signing identity. */
class RuntimePeerVerifier(private val context: Context) {
    fun verifyPeer(packageName: String): Int {
        val packages = context.packageManager
        val own = context.packageName
        val pair = runCatching { RuntimePackages.forCore(own) }
            .getOrElse { RuntimePackages.forRuntime(own) }
        val expected = if (own == pair.core) pair.runtime else pair.core
        if (packageName != expected) throw SecurityException("Wrong runtime channel")
        val peerUid = try { packages.getPackageUid(packageName, 0) }
        catch (failure: PackageManager.NameNotFoundException) {
            throw SecurityException("Runtime peer unavailable", failure)
        }
        if (!acceptsUid(peerUid, Process.myUid(), peerUid,
                packages.checkSignatures(own, packageName) == PackageManager.SIGNATURE_MATCH)) {
            throw SecurityException("Runtime must use a separate UID and matching signature")
        }
        // Do not accept another package admitted through a shared user ID.
        if (packages.getPackagesForUid(peerUid)?.toSet() != setOf(packageName)) {
            throw SecurityException("Runtime peer must have a dedicated UID")
        }
        return peerUid
    }

    /** Call on the Binder thread, before clearCallingIdentity or async dispatch. */
    fun requireCallingPeer(packageName: String) {
        val callingUid = Binder.getCallingUid()
        val peerUid = verifyPeer(packageName)
        if (callingUid != peerUid || callingUid == Process.myUid()) {
            throw SecurityException("Runtime caller denied")
        }
    }

    companion object {
        internal fun acceptsUid(callerUid: Int, ownUid: Int, expectedUid: Int, signatureMatches: Boolean): Boolean =
            callerUid == expectedUid && callerUid != ownUid && signatureMatches
    }
}
