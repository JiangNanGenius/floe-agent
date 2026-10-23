// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * The RAM holder keeps EXACTLY ONE bounded already-projected outcome,
 * newest-wins, clearable, with no Android/JNI/DB/IO dependency. It stores
 * only what LocalRuntimeProofProjection.projectTypedDeletion already
 * closed-bounded — this test pins the single-slot lifecycle, not any claim.
 */
class LinuxTypedDeletionRecordTest {

    private fun projected(tag: String): JsonObject =
        Json.parseToJsonElement(
            """{"availability":"observed","conversation":"$tag"}""",
        ) as JsonObject

    @Test fun observeStoresOneBoundedEntryAndClearRemovesIt() {
        try {
            LinuxTypedDeletionRecord.clear()
            assertNull(LinuxTypedDeletionRecord.snapshot())
            val first = LinuxTypedDeletionRecord.Entry(7L, projected("FIRST"))
            LinuxTypedDeletionRecord.observe(first)
            assertSame(first, LinuxTypedDeletionRecord.snapshot())
            val second = LinuxTypedDeletionRecord.Entry(null, projected("SECOND"))
            LinuxTypedDeletionRecord.observe(second)
            assertSame(second, LinuxTypedDeletionRecord.snapshot())
            assertEquals(0L, LinuxTypedDeletionRecord.snapshot()?.epoch ?: 0L)
            LinuxTypedDeletionRecord.clear()
            assertNull(LinuxTypedDeletionRecord.snapshot())
        } finally {
            LinuxTypedDeletionRecord.clear()
        }
    }

    @Test fun unboundEpochEntryIsRepresentableHonestly() {
        try {
            LinuxTypedDeletionRecord.clear()
            val entry = LinuxTypedDeletionRecord.Entry(epoch = null, projected = projected("ANY"))
            LinuxTypedDeletionRecord.observe(entry)
            val read = LinuxTypedDeletionRecord.snapshot()
            assertEquals(true, read?.epoch == null)
        } finally {
            LinuxTypedDeletionRecord.clear()
        }
    }
}
