// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The typed background document VIEW is the only PhoneControl path that can
 * carry a document URI. These are the real gates: an exact App-owned
 * FileProvider URI, one concrete MIME, an exact selected package/class, and
 * only the live effective package scope. No Intent, flags, extras or
 * resolver/self package is accepted.
 */
class PhoneControlDocumentViewPolicyTest {
    private val ownPackage = "com.floe.agent.full"
    private val authority = "$ownPackage.externaledits"
    private val gallery = "com.sec.android.gallery3d"
    private val calendar = "com.samsung.android.calendar"
    private val id = UUID.randomUUID().toString()

    private fun request(
        uri: String = "content://$authority/working/views/$id/poster.png",
        mime: String = "image/png",
        packageName: String = gallery,
        className: String = "com.sec.android.gallery3d.app.ViewActivity",
        displayName: String = "poster.png",
    ) = PhoneControlDocumentViewRequest(uri, mime, packageName, className, displayName)

    private fun denied(
        request: PhoneControlDocumentViewRequest,
        effective: Set<String> = setOf(gallery, calendar),
        expectedAuthority: String = authority,
    ): PhoneControlDenial? =
        PhoneControlPolicy.documentViewDenial(request, expectedAuthority, effective)

    @Test
    fun exactOwnedContentUriForASelectedViewerIsAccepted() {
        assertNull(denied(request()))
        assertNull(denied(request(
            uri = "content://$authority/working/views/$id/event.ics",
            mime = "text/calendar", packageName = calendar,
            className = "com.samsung.android.calendar.ImportActivity",
            displayName = "event.ics")))
        // A CJK display name is still inert and the decoded session check is
        // the authority for the exact final path segment.
        assertNull(denied(request(
            uri = "content://$authority/working/views/$id/%E6%B5%B7%E6%8A%A5.png",
            displayName = "海报.png")))
    }

    @Test
    fun onlyTheAppsOwnFileProviderAuthorityIsAccepted() {
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(
            uri = "content://evil.example/working/views/$id/poster.png")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(
            uri = "file://$authority/working/views/$id/poster.png")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(
            uri = "content://$authority/versions/$id/poster.png")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(
            uri = "content://$authority/working/views/not-a-uuid/poster.png")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(
            uri = "content://$authority/working/views/$id/poster.png?x=1")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(
            uri = "content://$authority/working/views/$id/poster.png#frag")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(
            uri = "content://$authority/working/views/../$id/poster.png")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT,
            denied(request(), expectedAuthority = "$ownPackage.other"))
    }

    @Test
    fun wildcardOrMalformedMimeIsRefused() {
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(mime = "image/*")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(mime = "image")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(mime = "text/calendar;charset=utf-8")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(mime = "image/png\r\n")))
    }

    @Test
    fun classAndDisplayNameStayInert() {
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(className = "com.other/ViewActivity")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(className = "com.sec.android.gallery3d ViewActivity")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(displayName = "../poster.png")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(displayName = ".hidden.png")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(displayName = "poster\t.png")))
    }

    @Test
    fun targetMustStillBeInTheLiveEffectiveScope() {
        assertEquals(PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
            denied(request(), effective = setOf(calendar)))
        // The user removing the viewer from Settings > Device is a real
        // revocation, not a reason to fall back to another package/chooser.
        assertEquals(PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
            denied(request(), effective = emptySet()))
    }

    @Test
    fun resolverSelfAndInstallerIdentitiesAreProtectedWindows() {
        for (packageName in listOf(
            "android",
            "com.android.intentresolver",
            "com.android.internal.app",
            ownPackage,
            "com.floe.agent.runtime",
            "com.android.systemui",
            "com.android.packageinstaller",
            "com.google.android.permissioncontroller",
        )) {
            assertEquals("$packageName must be protected", PhoneControlDenial.PROTECTED_WINDOW,
                denied(request(packageName = packageName),
                    effective = setOf(packageName, gallery)))
        }
    }

    @Test
    fun malformedPackageOrOversizedRequestIsRefusedBeforeDispatch() {
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(request(packageName = "")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(packageName = "bad/package")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(packageName = "bad package")))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(displayName = "x".repeat(161))))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(className = "x".repeat(513))))
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT, denied(
            request(uri = "content://$authority/working/views/$id/" + "x".repeat(2100))))
    }

    @Test
    fun shapeGateMatchesTheFullGateForInertFields() {
        val malformed = request(displayName = "../poster.png")
        assertEquals(PhoneControlDenial.INVALID_ARGUMENT,
            PhoneControlPolicy.documentViewShapeDenial(malformed))
        assertNull(PhoneControlPolicy.documentViewShapeDenial(request()))
    }
}
