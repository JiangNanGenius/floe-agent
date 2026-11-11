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
            BackendOwnershipPolicy.PublishedVerdict.Refused("pid"),
            classify(helper(describedPid = 4243)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("pid"),
            classify(helper(recordPid = 1, describedPid = 1)),
        )
    }

    @Test
    fun anOlderWireProtocolOnAVerifiedHelperIsStoppedAndReplaced() {
        // The identity checks pass and only the wire version lags — exactly
        // the stale-service case after a same-versionCode reinstall that
        // shipped new AIDL transactions. The old service must be replaced,
        // never adopted: its parcel shape cannot serve the new transactions.
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Replace(4242),
            classify(helper(describedProtocol = 0)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Replace(4242),
            classify(helper(describedProtocol = 2)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Replace(4242),
            classify(helper(recordVersion = 20, describedVersion = 20, describedProtocol = 2)),
        )
    }

    @Test
    fun protocolMismatchWithANewerVersionClaimIsRefusedNotKilled() {
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("protocol"),
            classify(helper(recordVersion = 25, describedVersion = 25, describedProtocol = 2)),
        )
    }

    @Test
    fun identityFailureDominatesAProtocolMismatch() {
        // A foreign or re-signed process that also fakes an old protocol is
        // refused on identity and is never stopped.
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("signing"),
            classify(helper(describedSigning = oldSigning, describedProtocol = 2)),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("package"),
            classify(helper(describedPackage = "moe.shizuku.privileged.api", describedProtocol = 2)),
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

    // --------------------------------------- stale legacy-wire quarantine

    @Test
    fun knownLegacyWireMarkersAreQuarantinableForTypedRetirement() {
        // Only markers this build knows to be older Floe wires may enter the
        // stale-retirement quarantine.
        assertTrue(BackendOwnershipPolicy.isKnownLegacyWire(1, 3))
        assertTrue(BackendOwnershipPolicy.isKnownLegacyWire(2, 3))
    }

    @Test
    fun junkUnknownAndFutureWireMarkersAreNeverQuarantined() {
        assertFalse(BackendOwnershipPolicy.isKnownLegacyWire(-1, 3))
        assertFalse(BackendOwnershipPolicy.isKnownLegacyWire(0, 3))
        assertFalse(BackendOwnershipPolicy.isKnownLegacyWire(3, 3))
        assertFalse(BackendOwnershipPolicy.isKnownLegacyWire(4, 3))
        assertFalse(BackendOwnershipPolicy.isKnownLegacyWire(99, 3))
    }

    @Test
    fun aKnownLegacyWireOnAVerifiedSameVersionHelperIsRetiredThroughReplace() {
        // The verified device scenario: an older build with the same version
        // code as the installed update still runs the old wire (protocol 2
        // against the installed wire 3). Identity is fully proven, so the
        // helper is replaced through its verified PID — never adopted, never
        // treated as the healthy service.
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Replace(30630),
            classify(
                helper(recordPid = 30630, describedPid = 30630, describedProtocol = 2),
                expectedWire = 3,
            ),
        )
    }

    @Test
    fun aKnownLegacyWireWithAMismatchedPeerIsRefusedNeverRetired() {
        // Unknown or mismatched peers stay refused even when they claim an
        // older wire: identity failure dominates the wire decision and the
        // peer is never stopped.
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("signing"),
            classify(
                helper(describedSigning = oldSigning, describedProtocol = 2),
                expectedWire = 3,
            ),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("package"),
            classify(
                helper(describedPackage = "moe.shizuku.privileged.api", describedProtocol = 2),
                expectedWire = 3,
            ),
        )
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Refused("uid"),
            classify(helper(describedUid = 0, describedProtocol = 2), expectedWire = 3),
        )
    }

    @Test
    fun aHealthyCurrentWirePeerIsPreservedNotRetired() {
        // The live protocol-3 service must never be re-classified as stale:
        // expected wire plus matching version stays adoptable, and a stale
        // publication can never displace it.
        assertEquals(
            BackendOwnershipPolicy.PublishedVerdict.Current,
            classify(helper(recordPid = 25207, describedPid = 25207, describedProtocol = 3), expectedWire = 3),
        )
    }

    private fun classify(
        helper: BackendOwnershipPolicy.PublishedHelper,
        expectedMode: String = "adb",
        expectedWire: Int = 1,
    ): BackendOwnershipPolicy.PublishedVerdict =
        BackendOwnershipPolicy.classifyPublishedHelper(
            helper = helper,
            expectedMode = expectedMode,
            expectedProtocol = expectedWire,
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
