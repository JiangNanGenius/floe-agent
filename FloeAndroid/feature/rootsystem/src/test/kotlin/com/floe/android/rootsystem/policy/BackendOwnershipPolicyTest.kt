// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.policy

import com.floe.android.rootsystem.AdbStatus
import com.floe.android.rootsystem.RootStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackendOwnershipPolicyTest {

    private val hostPackage = "com.floe.agent.full"
    private val hostSigning = "a".repeat(64)
    private val oldSigning = "b".repeat(64)
    private val currentVersion = 24L

    // ------------------------------------------------------------ refresh

    @Test
    fun aVerifiedLiveRootOwnerIsPreservedEvenWhenAdbIsPublished() {
        assertEquals(
            BackendOwnershipPolicy.RefreshAction.KEEP_CURRENT,
            BackendOwnershipPolicy.decideRefresh(
                currentOwner = BackendOwnershipPolicy.Owner.ROOT,
                currentAlive = true,
                adbPublished = true,
            ),
        )
    }

    @Test
    fun aLiveAdbOwnerIsAlsoPreserved() {
        assertEquals(
            BackendOwnershipPolicy.RefreshAction.KEEP_CURRENT,
            BackendOwnershipPolicy.decideRefresh(
                currentOwner = BackendOwnershipPolicy.Owner.ADB,
                currentAlive = true,
                adbPublished = true,
            ),
        )
    }

    @Test
    fun refreshAdoptsOnlyPublishedAdbWhenNoOwnerIsLive() {
        assertEquals(
            BackendOwnershipPolicy.RefreshAction.ADOPT_ADB,
            BackendOwnershipPolicy.decideRefresh(
                currentOwner = BackendOwnershipPolicy.Owner.NONE,
                currentAlive = false,
                adbPublished = true,
            ),
        )
    }

    @Test
    fun refreshNeverAdoptsARootBinderWithNoLiveOwner() {
        // There is no ADOPT_ROOT action: a Root binder left by an earlier App
        // process is not authority and Root remains default-off.
        assertEquals(
            BackendOwnershipPolicy.RefreshAction.NO_SERVICE,
            BackendOwnershipPolicy.decideRefresh(
                currentOwner = BackendOwnershipPolicy.Owner.NONE,
                currentAlive = false,
                adbPublished = false,
            ),
        )
        assertTrue(
            BackendOwnershipPolicy.RefreshAction.entries.none { it.name.contains("ROOT") },
        )
    }

    @Test
    fun aDeadRootOwnerMayFallBackOnlyToPublishedAdb() {
        assertEquals(
            BackendOwnershipPolicy.RefreshAction.ADOPT_ADB,
            BackendOwnershipPolicy.decideRefresh(
                currentOwner = BackendOwnershipPolicy.Owner.ROOT,
                currentAlive = false,
                adbPublished = true,
            ),
        )
        assertEquals(
            BackendOwnershipPolicy.RefreshAction.NO_SERVICE,
            BackendOwnershipPolicy.decideRefresh(
                currentOwner = BackendOwnershipPolicy.Owner.ROOT,
                currentAlive = false,
                adbPublished = false,
            ),
        )
    }

    // -------------------------------------------------------- mode changes

    @Test
    fun explicitAdbStopsAndFencesALiveRootOwner() {
        val plan = BackendOwnershipPolicy.planExplicitAdb(BackendOwnershipPolicy.Owner.ROOT)
        assertTrue(plan.stopLiveRoot)
        assertTrue(plan.fenceCurrentGrants)
    }

    @Test
    fun explicitAdbDoesNotFenceWhenNoBackendIsActive() {
        val plan = BackendOwnershipPolicy.planExplicitAdb(BackendOwnershipPolicy.Owner.NONE)
        assertFalse(plan.stopLiveRoot)
        assertFalse(plan.fenceCurrentGrants)
    }

    @Test
    fun onlyALiveRootOwnerIsStoppedForAnExplicitAdbStart() {
        assertTrue(
            BackendOwnershipPolicy.mustStopLiveRoot(BackendOwnershipPolicy.Owner.ROOT),
        )
        assertFalse(
            BackendOwnershipPolicy.mustStopLiveRoot(BackendOwnershipPolicy.Owner.ADB),
        )
        assertFalse(
            BackendOwnershipPolicy.mustStopLiveRoot(BackendOwnershipPolicy.Owner.NONE),
        )
    }

    // ------------------------------------------------------------ statuses

    @Test
    fun aFormerLiveAdbServiceBecomesPairedStandbyWhileRootOwnsTheTransport() {
        assertEquals(
            AdbStatus.Paired(5555),
            BackendOwnershipPolicy.standbyAdbStatus(
                current = AdbStatus.ServiceAlive(2000, "adb"),
                pairingSupported = true,
                connectPort = 5555,
            ),
        )
        assertEquals(
            AdbStatus.Paired(5555),
            BackendOwnershipPolicy.standbyAdbStatus(
                current = AdbStatus.ServiceDied("binder_died"),
                pairingSupported = true,
                connectPort = 5555,
            ),
        )
    }

    @Test
    fun standbyAdbNeverReportsServiceAlive() {
        val mapped = BackendOwnershipPolicy.standbyAdbStatus(
            current = AdbStatus.ServiceAlive(2000, "adb"),
            pairingSupported = true,
            connectPort = 1234,
        )
        assertTrue(mapped is AdbStatus.Paired)
        assertFalse(mapped is AdbStatus.ServiceAlive)

        val unsupported = BackendOwnershipPolicy.standbyAdbStatus(
            current = AdbStatus.ServiceAlive(2000, "adb"),
            pairingSupported = false,
            connectPort = null,
        )
        assertEquals(AdbStatus.Disabled, unsupported)
    }

    @Test
    fun standbyAdbPreservesHonestNonLiveStates() {
        assertEquals(
            AdbStatus.PairRequired,
            BackendOwnershipPolicy.standbyAdbStatus(
                current = AdbStatus.Pairing,
                pairingSupported = true,
                connectPort = null,
            ),
        )
        assertEquals(
            AdbStatus.Paired(9),
            BackendOwnershipPolicy.standbyAdbStatus(
                current = AdbStatus.Paired(9),
                pairingSupported = true,
                connectPort = 7,
            ),
        )
        val error = AdbStatus.Error("identity", "signing")
        assertEquals(
            error,
            BackendOwnershipPolicy.standbyAdbStatus(
                current = error,
                pairingSupported = true,
                connectPort = 7,
            ),
        )
    }

    @Test
    fun inactiveRootDistinguishesAnAvailableGrantFromDefaultOff() {
        assertEquals(
            RootStatus.GrantFound,
            BackendOwnershipPolicy.inactiveRootStatus(hadVerifiedGrant = true),
        )
        assertEquals(
            RootStatus.Off,
            BackendOwnershipPolicy.inactiveRootStatus(hadVerifiedGrant = false),
        )
    }

    // ------------------------------------------------------ stale helpers

    @Test
    fun aCurrentVersionSamePackageHelperIsAdoptableNotStoppable() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Current,
            classify(helper()),
        )
    }

    @Test
    fun anOlderSamePackageHelperIsReplaceableThroughItsVerifiedPid() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Replace(4242),
            classify(helper(recordVersion = 20, describedVersion = 20)),
        )
    }

    @Test
    fun aNewerVersionClaimIsRefusedRatherThanKilled() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("version"),
            classify(helper(recordVersion = 25, describedVersion = 25)),
        )
    }

    @Test
    fun theSiblingRuntimePackageIsNeverMistakenForTheHostPackage() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("package"),
            classify(helper(describedPackage = "com.floe.agent.runtime.full")),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("package"),
            classify(helper(describedPackage = "moe.shizuku.privileged.api")),
        )
    }

    @Test
    fun signingMustMatchOnBothTheRecordAndDescribe() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("signing"),
            classify(helper(describedSigning = oldSigning)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("signing"),
            classify(helper(recordSigning = oldSigning)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("signing"),
            classify(helper(describedSigning = null)),
        )
    }

    @Test
    fun modeUidProtocolAndPidMustAllAgree() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("mode"),
            classify(helper(recordMode = "root")),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("mode"),
            classify(helper(describedMode = "root")),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("uid"),
            classify(helper(recordUid = 0)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("uid"),
            classify(helper(describedUid = 0)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("protocol"),
            classify(helper(describedProtocol = 2)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("pid"),
            classify(helper(describedPid = 4243)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("pid"),
            classify(helper(recordPid = 1, describedPid = 1)),
        )
    }

    @Test
    fun aFailedDescribeIsNeverTreatedAsOwned() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("describe"),
            classify(helper(describedOk = false)),
        )
    }

    @Test
    fun recordAndDescribeVersionsMustAgree() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("version"),
            classify(helper(recordVersion = 22, describedVersion = 23)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("version"),
            classify(helper(recordVersion = 0, describedVersion = 0)),
        )
    }

    @Test
    fun aVerifiedOldRootHelperIsAlsoReplaceable() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Replace(9001),
            classify(
                helper(
                    recordMode = "root",
                    recordUid = 0,
                    recordPid = 9001,
                    recordVersion = 21,
                    describedMode = "root",
                    describedUid = 0,
                    describedPid = 9001,
                    describedVersion = 21,
                ),
                expectedMode = "root",
            ),
        )
    }

    @Test
    fun aRootRecordDescribedAsAdbIsRefused() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("mode"),
            classify(
                helper(
                    recordMode = "root",
                    recordUid = 0,
                    describedMode = "adb",
                    describedUid = 2000,
                ),
                expectedMode = "root",
            ),
        )
    }

    private fun classify(
        helper: BackendOwnershipPolicy.PublishedHelper,
        expectedMode: String = "adb",
    ): BackendOwnershipPolicy.PublishedVerdict =
        BackendOwnershipPolicy.classifyPublishedHelper(
            helper = helper,
            expectedMode = expectedMode,
            expectedProtocol = 1,
            hostPackage = hostPackage,
            hostSigning = hostSigning,
            currentVersion = currentVersion,
        )

    private fun helper(
        recordMode: String = "adb",
        recordUid: Int = 2000,
        recordPid: Int = 4242,
        recordVersion: Long = currentVersion,
        recordSigning: String? = hostSigning,
        describedOk: Boolean = true,
        describedProtocol: Int = 1,
        describedMode: String? = "adb",
        describedUid: Int = 2000,
        describedPid: Int = recordPid,
        describedPackage: String? = hostPackage,
        describedVersion: Long = recordVersion,
        describedSigning: String? = hostSigning,
    ): BackendOwnershipPolicy.PublishedHelper = BackendOwnershipPolicy.PublishedHelper(
        recordMode = recordMode,
        recordUid = recordUid,
        recordPid = recordPid,
        recordVersion = recordVersion,
        recordSigning = recordSigning,
        describedOk = describedOk,
        describedProtocol = describedProtocol,
        describedMode = describedMode,
        describedUid = describedUid,
        describedPid = describedPid,
        describedPackage = describedPackage,
        describedVersion = describedVersion,
        describedSigning = describedSigning,
    )
}
