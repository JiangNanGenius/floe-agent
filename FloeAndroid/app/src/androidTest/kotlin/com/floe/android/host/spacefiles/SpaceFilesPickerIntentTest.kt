// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import android.content.Intent
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.floe.android.safgateway.PickKind
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.SafGrantFlagBits
import com.floe.android.safgateway.SafPickerIntents
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Platform plumbing for the Space → Files tree picker.
 *
 * AUTHORED, NOT RUN in this source lane. These assertions pin the two things
 * a JVM test cannot: the Intent this page launches is the system tree picker
 * with NO invented grant flags, and the returned flags are read back exactly
 * (the Uri-only wrapper would drop them).
 */
@RunWith(AndroidJUnit4::class)
class SpaceFilesPickerIntentTest {

    @Test
    fun treePickerLaunchesTheSystemTreePickerWithoutInventedGrants() {
        val spec = PickRequestSpec(
            requestKey = "space-files-tree",
            kind = PickKind.OPEN_TREE,
            mimeTypes = emptyList(),
            suggestedName = null,
            initialDirectory = null,
        )

        val intent = SafPickerIntents.from(spec)

        assertEquals(Intent.ACTION_OPEN_DOCUMENT_TREE, intent.action)
        assertNull("the user, not this page, chooses the folder", intent.data)
        assertEquals("no URI permission flags may be hard-coded", 0, intent.flags)
        assertEquals("a tree picker is not a MIME-filtered document picker", null, intent.type)
    }

    @Test
    fun returnedIntentFlagsAreReadBackExactly() {
        val returned = Intent()
            .setData(Uri.parse("content://com.floe.test.documents/tree/primary%3ASpaceFiles"))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            .addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)

        val expected = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION

        assertEquals(expected, SafPickerIntents.resultFlags(returned))
        assertEquals(
            "content://com.floe.test.documents/tree/primary%3ASpaceFiles",
            SafPickerIntents.resultUriString(returned),
        )
        assertEquals(SafGrantFlagBits.GRANT_READ or SafGrantFlagBits.GRANT_WRITE or SafGrantFlagBits.PERSISTABLE, expected)
        assertNull(SafPickerIntents.resultUriString(null))
        assertEquals(0, SafPickerIntents.resultFlags(null))
    }
}
