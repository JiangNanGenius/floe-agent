// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.content.Context
import android.content.pm.PackageManager
import android.os.Process
import com.floe.android.rootsystem.ipc.BinderProtocol
import com.floe.android.rootsystem.policy.AccessPolicy
import com.floe.android.rootsystem.policy.FloePackageFamily
import com.floe.android.rootsystem.policy.SigningDigest
import java.security.MessageDigest

/**
 * Verified Floe process identity. The server refuses to start if the installed
 * package UID, version code or signing digest differs from the values the App
 * used to launch it, so an old server can never serve a new/re-signed build.
 */
internal class ServerIdentity(
    val packageName: String,
    val appUid: Int,
    val signingSha256: String,
    val appVersionCode: Long,
    val mode: String,
    val serverUid: Int,
    val serverPid: Int,
) {
    val appId: Int get() = appUid % 100_000
    val userId: Int get() = appUid / 100_000

    /**
     * The verified host package plus the stable Floe parent. The runtime
     * component is a sibling applicationId, so protecting the host package
     * alone would leave its data and process manageable.
     */
    val protectedPackages: Set<String> = FloePackageFamily.protectedPackages(setOf(packageName))

    fun callerAllowed(callerUid: Int, callerPid: Int): Boolean =
        AccessPolicy.callerAllowed(callerUid, callerPid, appUid)

    fun describe(generation: Long, capabilities: List<String>): android.os.Bundle =
        android.os.Bundle().apply {
            putInt(BinderProtocol.KEY_PROTOCOL, BinderProtocol.VERSION)
            putInt(BinderProtocol.KEY_SERVER_UID, serverUid)
            putInt(BinderProtocol.KEY_SERVER_PID, serverPid)
            putString(BinderProtocol.KEY_SERVER_MODE, mode)
            putString(BinderProtocol.KEY_PACKAGE, packageName)
            putLong(BinderProtocol.KEY_APP_VERSION, appVersionCode)
            putString(BinderProtocol.KEY_SIGNING_SHA256, signingSha256)
            putLong(BinderProtocol.KEY_GENERATION, generation)
            putStringArray(BinderProtocol.KEY_CAPABILITIES, capabilities.toTypedArray())
        }

    companion object {
        fun resolve(context: Context, arguments: ServerArguments): ServerIdentity? {
            val packageManager = context.packageManager
            val info = try {
                packageManager.getPackageInfo(
                    arguments.packageName,
                    PackageManager.GET_SIGNING_CERTIFICATES,
                )
            } catch (_: PackageManager.NameNotFoundException) {
                return null
            }
            val appUid = info.applicationInfo?.uid ?: return null
            if (appUid != arguments.callerUid) return null
            if (info.longVersionCode != arguments.appVersionCode) return null
            val signatures = info.signingInfo?.apkContentsSigners ?: return null
            if (signatures.isEmpty()) return null
            val certificates = try {
                signatures.map {
                    java.security.cert.CertificateFactory.getInstance("X.509")
                        .generateCertificate(it.toByteArray().inputStream())
                            as java.security.cert.X509Certificate
                }.toTypedArray()
            } catch (_: Throwable) {
                return null
            }
            val actualSigning = SigningDigest.of(certificates)
            if (!MessageDigest.isEqual(
                    actualSigning.toByteArray(Charsets.UTF_8),
                    arguments.signingSha256.toByteArray(Charsets.UTF_8),
                )
            ) {
                return null
            }
            val packages = try {
                packageManager.getPackagesForUid(appUid)?.toList() ?: emptyList()
            } catch (_: Throwable) {
                emptyList()
            }
            if (arguments.packageName !in packages) return null
            return ServerIdentity(
                packageName = arguments.packageName,
                appUid = appUid,
                signingSha256 = actualSigning,
                appVersionCode = info.longVersionCode,
                mode = arguments.mode,
                serverUid = Process.myUid(),
                serverPid = Process.myPid(),
            )
        }
    }
}
