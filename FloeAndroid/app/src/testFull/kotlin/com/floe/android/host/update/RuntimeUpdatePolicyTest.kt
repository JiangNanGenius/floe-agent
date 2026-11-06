// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import org.junit.Assert.*
import org.junit.Test

class RuntimeUpdatePolicyTest {
    private val signer = setOf("a".repeat(64))
    private val main = ApkIdentity("com.floe.agent.full", 49, signer, 28, true, false)
    private val target = main.copy(packageName = "com.floe.agent.runtime.full")
    private val installed = target.copy(longVersionCode = 48)
    private val proof = RuntimeInstallProof(target.packageName, 49, signer, "c".repeat(64))
    private fun accepts(runtime: ApkIdentity = target, prior: ApkIdentity = installed) =
        RuntimeUpdatePolicy.accepts(main, runtime, prior, target.packageName, 33)

    @Test fun candidateMustComeFromSameBuildChannelAndSigningIdentity() {
        assertTrue(accepts())
        assertFalse(accepts(target.copy(packageName = "com.floe.agent.runtime.dev")))
        assertFalse(accepts(target.copy(longVersionCode = 48)))
        assertFalse(accepts(target.copy(signerSha256 = setOf("b".repeat(64)))))
        assertFalse(accepts(prior = installed.copy(signerSha256 = emptySet())))
        assertFalse(accepts(prior = installed.copy(longVersionCode = 50)))
    }

    @Test fun runtimeRequiresCompatibleNativeArchiveAndInstalledReadback() {
        assertFalse(accepts(target.copy(hasArm64Libraries = false)))
        assertFalse(accepts(target.copy(hasForeignAbiLibraries = true)))
        assertFalse(accepts(target.copy(minSdk = 34)))
        assertTrue(RuntimeUpdatePolicy.installedMatches(target, proof))
        assertFalse(RuntimeUpdatePolicy.installedMatches(installed, proof))
        assertFalse(RuntimeUpdatePolicy.installedMatches(null, proof))
        assertFalse(RuntimeUpdatePolicy.installedMatches(target.copy(signerSha256 = emptySet()), proof))
    }

    @Test fun durableParentRecordKeepsBothChildrenAndRuntimeProof() {
        val record = PendingInstall("0.1.0-alpha.30", 49, "d".repeat(64), "app.apk", 101,
            main.packageName, signer, proof, listOf(102, 103))
        assertEquals(record, PendingInstall.fromJson(record.toJson()))
        assertNull(PendingInstall.fromJson(record.copy(childSessionIDs = listOf(102, 102)).toJson()))
        assertNull(PendingInstall.fromJson(record.copy(childSessionIDs = listOf(101, 102)).toJson()))
        assertNull(PendingInstall.fromJson(record.copy(runtime = proof.copy(versionCode = 48)).toJson()))
        assertNull(PendingInstall.fromJson(record.copy(runtimeUpdateRequired = true).toJson()))
    }

    @Test fun legacyMainOnlyRecordsRemainReadableWithoutInventingChildren() {
        val old = """{"versionName":"old","versionCode":48,"sha256":"${"d".repeat(64)}","fileName":"old.apk","sessionID":100}"""
        val record = checkNotNull(PendingInstall.fromJson(old))
        assertNull(record.runtime)
        assertTrue(record.childSessionIDs.isEmpty())
        assertFalse(record.runtimeUpdateRequired)
        val fallback = record.copy(packageName = main.packageName, signerSha256 = signer, runtimeUpdateRequired = true)
        assertEquals(fallback, PendingInstall.fromJson(fallback.toJson()))
    }
}
