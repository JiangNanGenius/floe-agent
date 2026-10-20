// SPDX-License-Identifier: MPL-2.0
package com.floe.android.attachments

import android.content.ContentResolver
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * RB-7 attachment staging — device/API-33 instrumented SOURCE tests against
 * a REAL ContentResolver and a synthetic read-only document provider.
 *
 * AUTHORED ONLY: not executed by the authoring package; no device, emulator
 * or Gradle run is claimed. The native staging lane is not yet published, so
 * the two native-boundary cases assert the truthful pre-qualification
 * outcomes (typed not-installed OR a missing symbol) instead of pretending
 * a working staging lane; the wire-level end-to-end cases are marked
 * precondition-gated and will be enabled by Main's serialized integration
 * once the lane is installed.
 */
@RunWith(AndroidJUnit4::class)
class AttachmentStagingInstrumentedTest {

    private lateinit var resolver: ContentResolver

    @Before
    fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        resolver = context.contentResolver
        SyntheticDocumentProvider.resetCounters()
    }

    /**
     * The synthetic provider lives in THIS instrumentation package (androidTest
     * APK) and is `exported=false`; the product-UID resolver can therefore only
     * read it through an EXPLICIT scoped URI grant — exactly the SAF handoff
     * the real import path receives. This is a test-fixture grant only: no
     * production export, no manifest permission, no trust change. The grant is
     * transient (no takePersistableUriPermission), matching
     * [persistenceIsNotTakenByDefault].
     */
    private fun grantFixtureRead(uri: Uri) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.context.grantUriPermission(
            instrumentation.targetContext.packageName,
            uri,
            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION,
        )
    }

    /** PACKAGING identity proof (job-ce1f235117e64a4a): the fixture URI
     *  authority and the MERGED MANIFEST provider authority are the same
     *  value derived from this variant's actual test package. The former
     *  fixed authority `com.floe.android.test.staging` made the full and
     *  play androidTest APKs mutually uninstallable
     *  (INSTALL_FAILED_CONFLICTING_PROVIDER); asserting component identity
     *  here means a future AGP/placeholder regression fails this test
     *  instead of silently re-introducing the collision. */
    @Test
    fun stagingProviderAuthorityIsDerivedFromMergedManifestIdentity() {
        val instrumentationPackage =
            InstrumentationRegistry.getInstrumentation().context.packageName
        assertTrue("fixture must run in the variant test package",
            instrumentationPackage.endsWith(".test"))
        val expected = instrumentationPackage +
            SyntheticDocumentProvider.STAGING_AUTHORITY_SUFFIX
        assertEquals("URI helper authority must match the actual test identity",
            expected, SyntheticDocumentProvider.AUTHORITY)
        val resolved = InstrumentationRegistry.getInstrumentation().context
            .packageManager.getProviderInfo(
                android.content.ComponentName(
                    instrumentationPackage,
                    SyntheticDocumentProvider::class.java.name),
                0,
            )
        assertEquals("merged manifest authority must equal the derived identity",
            expected, resolved.authority)
        assertEquals("the merged provider component must be this variant's",
            SyntheticDocumentProvider::class.java.name, resolved.name)
    }

    /** Real provider → real ContentResolver → real bounded pump, WITHOUT
     *  the native lane: [AndroidContentResolverSource] is exercised through
     *  the same read contract the pump uses. */
    @Test
    fun realContentResolverStreamsExpectedBytesAndMetadata() {
        val name = "sample-${UUID.randomUUID()}.bin"
        val uri = SyntheticDocumentProvider.docUri(name)
        grantFixtureRead(uri)
        val source = AndroidContentResolverSource(uri, resolver)
        assertEquals(name, source.displayNameHint)
        assertEquals("application/octet-stream", source.mimeTypeHint)
        assertEquals(150_000L, source.declaredByteCount())
        val stream = source.openRead()
        val buffer = ByteArray(65_536)
        var total = 0
        while (true) {
            val n = stream.read(buffer, 0, buffer.size)
            if (n < 0) break
            assertTrue("short reads supported", n <= buffer.size)
            total += n
        }
        stream.close()
        assertEquals(150_000, total)
        // The original was NOT mutated or deleted by reading it.
        val again = resolver.openInputStream(uri)
        assertNotNull(again)
        again?.close()
    }

    @Test
    fun unknownSizePipeReportsNullSizeHonestly() {
        val uri = SyntheticDocumentProvider.pipeUri(12_345)
        grantFixtureRead(uri)
        val source = AndroidContentResolverSource(uri, resolver)
        assertNull("providers that cannot report SIZE must yield null",
                   source.declaredByteCount())
        val stream = source.openRead()
        val buffer = ByteArray(4_096)
        var total = 0
        while (true) {
            val n = stream.read(buffer, 0, buffer.size)
            if (n < 0) break
            total += n
        }
        stream.close()
        assertEquals(12_345, total)
    }

    @Test
    fun unavailableUriFailsTypedWithoutLeakingUri() {
        val goneUri = SyntheticDocumentProvider.goneUri("missing.bin")
        grantFixtureRead(goneUri)
        val source = AndroidContentResolverSource(goneUri, resolver)
        try {
            source.openRead()
            fail("an unavailable provider URI must be refused")
        } catch (expected: StagingSourceUnavailable) {
            assertTrue(expected.message?.contains("content://") != true)
        }
    }

    @Test
    fun persistenceIsNotTakenByDefault() {
        val uri = SyntheticDocumentProvider.docUri("persist-${UUID.randomUUID()}.bin")
        grantFixtureRead(uri)
        val source = AndroidContentResolverSource(uri, resolver)
        val stream = source.openRead()
        stream.close()
        // Default: transient scoped read only; nothing persisted.
        val persisted = resolver.persistedUriPermissions.any { it.uri == uri }
        assertTrue("no persistable grant without explicit proof of need",
                   !persisted)
    }

    @Test
    fun temporarySessionRefusedBeforeAnyProviderOpenOrNativeCall() {
        val service = AttachmentStagingService(ProductionStagingNative,
                                               ProductionStagingExchange)
        val source = AndroidContentResolverSource(
            SyntheticDocumentProvider.docUri("temp.bin"), resolver)
        try {
            service.openRoute(conversationId = null, incarnation = 1,
                              draftRevision = 0, isTemporarySession = true)
            fail("temporary sessions must never open a staging route")
        } catch (expected: AttachmentStagingService.StagingFailure) {
            assertEquals("temporaryRefused", expected.code)
        }
        assertEquals("no source touch before the gate", 0,
                     SyntheticDocumentProvider.openAttemptCount())
    }

    @Test
    fun nativeLaneBeforeQualificationIsTypedOrMissingNeverFakeSuccess() {
        val outcome = runCatching {
            com.floe.android.bridge.AttachmentStagingNative.stagingRouteOpen(
                null, 1L, 0L, false)
        }
        outcome.fold(
            onSuccess = { receipt ->
                // A real lane must mint the documented opaque shape.
                assertTrue(receipt.startsWith("route:v1:"))
                com.floe.android.bridge.AttachmentStagingNative.stagingRouteClose(receipt)
            },
            onFailure = { error ->
                val truthful = error is UnsatisfiedLinkError
                    || (error is com.floe.android.bridge.AttachmentStagingNativeException
                        && error.status in listOf(-301, -302, -303, -310))
                assertTrue("pre-qualification failure must be typed or a missing " +
                           "symbol, never silent: $error", truthful)
            },
        )
    }

    @Test
    fun stagingReadRejectsForgedHandleWithTypedStatus() {
        val forged = "stag:v1:" + "0".repeat(32)
        val buffer = ByteArray(16)
        val result = runCatching {
            com.floe.android.bridge.AttachmentStagingNative.stagingRead(forged, 0, buffer)
        }
        result.fold(
            onSuccess = { copied ->
                fail("a forged handle must never return bytes (copied=$copied)")
            },
            onFailure = { error ->
                val truthful = error is UnsatisfiedLinkError
                    || (error is com.floe.android.bridge.AttachmentStagingNativeException
                        && error.status in listOf(-313, -305, -301))
                assertTrue("forged handles must fail typed: $error", truthful)
            },
        )
    }
}
