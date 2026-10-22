// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import java.lang.reflect.Modifier
import org.junit.Test

/**
 * The trusted boundary contract: a supervision instance can only be unlocked by
 * real package metadata, exact signatures, a distinct dedicated runtime UID and a
 * self UID that is not the credential-bearing App's.
 */
class RuntimeUidBoundaryTest {

    private val reader = FakePackageReader(
        packages = mapOf(
            CORE_PKG to PackageMetadata(CORE_PKG, CORE_UID, listOf(CORE_SIG)),
            RUNTIME_PKG to PackageMetadata(RUNTIME_PKG, RUNTIME_UID, listOf(RUNTIME_SIG)),
        ),
        uidOwners = mapOf(
            CORE_UID to listOf(CORE_PKG),
            RUNTIME_UID to listOf(RUNTIME_PKG),
        ),
    )

    private fun validate(
        selfUid: Int = RUNTIME_UID,
        selfPid: Int = SERVICE_PID,
        runtimePkg: String = RUNTIME_PKG,
        runtimeSig: String = RUNTIME_SIG,
        corePkg: String = CORE_PKG,
        reader: PackageMetadataReader = this.reader,
    ) = RuntimeUidBoundary.validate(
        corePackageName = corePkg,
        coreSignatureSha256 = CORE_SIG,
        runtimePackageName = runtimePkg,
        runtimeSignatureSha256 = runtimeSig,
        selfUid = selfUid,
        selfPid = selfPid,
        reader = reader,
        clock = FakeClock(),
    )

    @Test
    fun exactDistinctDedicatedRuntimeUidIsAccepted() {
        val check = validate()
        assertTrue(check is BoundaryCheck.Accepted)
        val boundary = (check as BoundaryCheck.Accepted).boundary
        assertEquals(RUNTIME_UID, boundary.runtimeUid)
        assertEquals(CORE_UID, boundary.coreUid)
        assertEquals(SERVICE_PID, boundary.selfPid)
    }

    @Test
    fun runningInsideTheCredentialBearingUidIsRefused() {
        val check = validate(selfUid = CORE_UID)
        assertTrue(check is BoundaryCheck.Rejected)
        val reasons = (check as BoundaryCheck.Rejected).reasons
        assertTrue(reasons.any { it.contains("credential-bearing core App UID") })
        assertTrue(reasons.any { it.contains("not the allowlisted runtime UID") })
    }

    @Test
    fun unlistedOrMismatchedRuntimeSignatureIsRefused() {
        val check = validate(runtimeSig = "ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00")
        assertTrue((check as BoundaryCheck.Rejected).reasons.any {
            it.contains("runtime package signature does not match")
        })
    }

    @Test
    fun missingPackageMetadataIsRefusedRatherThanAssumed() {
        val check = validate(runtimePkg = "com.floe.agent.runtime.unknown")
        assertTrue((check as BoundaryCheck.Rejected).reasons.contains("runtime package metadata unavailable"))
    }

    @Test
    fun readerFailureIsRefusedFailClosed() {
        val throwing = FakePackageReader(
            packages = mapOf(CORE_PKG to PackageMetadata(CORE_PKG, CORE_UID, listOf(CORE_SIG))),
            uidOwners = mapOf(CORE_UID to listOf(CORE_PKG)),
            throwOn = setOf(RUNTIME_PKG),
        )
        val check = validate(reader = throwing)
        assertTrue((check as BoundaryCheck.Rejected).reasons.any { it.contains("metadata threw") })
    }

    @Test
    fun sharedRuntimeUidWithAnotherPackageIsRefused() {
        val shared = FakePackageReader(
            packages = mapOf(
                CORE_PKG to PackageMetadata(CORE_PKG, CORE_UID, listOf(CORE_SIG)),
                RUNTIME_PKG to PackageMetadata(RUNTIME_PKG, RUNTIME_UID, listOf(RUNTIME_SIG)),
            ),
            uidOwners = mapOf(
                CORE_UID to listOf(CORE_PKG),
                // Main's dedicated-UID rule: a second package on the runtime UID is denied.
                RUNTIME_UID to listOf(RUNTIME_PKG, "com.other.app"),
            ),
        )
        val check = validate(reader = shared)
        assertTrue((check as BoundaryCheck.Rejected).reasons.any { it.contains("not dedicated to") })
    }

    @Test
    fun unresolvedUidOwnershipIsRefused() {
        val unknown = FakePackageReader(
            packages = mapOf(
                CORE_PKG to PackageMetadata(CORE_PKG, CORE_UID, listOf(CORE_SIG)),
                RUNTIME_PKG to PackageMetadata(RUNTIME_PKG, RUNTIME_UID, listOf(RUNTIME_SIG)),
            ),
            uidOwners = mapOf(CORE_UID to listOf(CORE_PKG)), // runtime UID owners missing
        )
        assertTrue((validate(reader = unknown) as BoundaryCheck.Rejected).reasons
            .contains("runtime UID owners unresolved"))
    }

    @Test
    fun coreAndRuntimeMustBeDifferentPackages() {
        val check = validate(corePkg = RUNTIME_PKG, runtimePkg = RUNTIME_PKG)
        assertTrue((check as BoundaryCheck.Rejected).reasons
            .any { it.contains("different package from the credential core App") })
    }

    @Test
    fun noOrdinarySourceConstructionPathExists() {
        val ctors = RuntimeUidBoundary::class.java.declaredConstructors
        assertTrue(ctors.isNotEmpty())
        // Any public-looking constructor must be the compiler's synthetic marker
        // form: it needs a kotlin.jvm.internal.DefaultConstructorMarker argument,
        // which no Kotlin or Java source call can supply.
        ctors.forEach { ctor ->
            if (Modifier.isPublic(ctor.modifiers)) {
                assertTrue(
                    "public constructor form must be synthetic-marker only",
                    ctor.parameterTypes.last().name == "kotlin.jvm.internal.DefaultConstructorMarker",
                )
            }
        }
        // No copy/value-of/deserialization form of a boundary exists.
        assertFalse(RuntimeUidBoundary::class.java.methods.any { it.name == "copy" })
        assertFalse(RuntimeUidBoundary::class.java.declaredMethods.any { it.name == "valueOf" })
    }

    @Test
    fun inconsistentBoundaryValuesAreRefusedByTheBoundaryItself() {
        val synthetic = RuntimeUidBoundary::class.java.declaredConstructors
            .first { it.parameterTypes.last().name == "kotlin.jvm.internal.DefaultConstructorMarker" }
        // A hand-assembled instance with contradictory facts must still be refused:
        // same-UID and short-digest forgeries throw from the class's own checks.
        assertInstanceOf(
            IllegalArgumentException::class.java,
            refusal { synthetic.newInstance(10456, 10456, "a", "b", CORE_SIG, RUNTIME_SIG, 4000, 0L, null) },
        )
        assertInstanceOf(
            IllegalArgumentException::class.java,
            refusal { synthetic.newInstance(10456, 10123, "a", "a", "short", RUNTIME_SIG, 4000, 0L, null) },
        )
        assertInstanceOf(
            IllegalArgumentException::class.java,
            refusal { synthetic.newInstance(10456, 10123, "a", "a", CORE_SIG, RUNTIME_SIG, 0, 0L, null) },
        )
    }

    private fun refusal(block: () -> Any?): Throwable =
        try {
            block()
            AssertionError("expected refusal")
        } catch (e: java.lang.reflect.InvocationTargetException) {
            e.cause ?: e
        }

    private fun assertInstanceOf(expected: Class<*>, actual: Throwable) {
        assertTrue("expected ${expected.simpleName} but was ${actual.javaClass.name}: ${actual.message}",
            expected.isInstance(actual))
    }

    @Test
    fun digestOfIsStableHexSha256() {
        val digest = RuntimeUidBoundary.digestOf(byteArrayOf(1, 2, 3))
        assertEquals(64, digest.length)
        assertEquals(digest, RuntimeUidBoundary.digestOf(byteArrayOf(1, 2, 3)))
        assertTrue(digest.all { it in '0'..'9' || it in 'a'..'f' })
    }
}
