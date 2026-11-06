// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class OfficePendingPreviewStoreTest {
    private fun fixture(body: (File, File, File, OfficePendingPreviewStore) -> Unit) {
        val root = Files.createTempDirectory("floe-office-pending-").toFile()
        try {
            val snapshots = File(root, "provider").apply { mkdirs() }
            val metadata = File(root, "pending")
            val file = File(snapshots, "${UUID.randomUUID()}/document.docx").apply { parentFile.mkdirs(); writeText("DOCX") }
            body(snapshots, metadata, file, OfficePendingPreviewStore(snapshots, metadata))
        } finally { root.deleteRecursively() }
    }
    private fun snapshot(file: File) = OfficePendingPreviewStore.Snapshot(file.canonicalPath,
        MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) },
        file.length(), "Example.docx")

    @Test fun componentProcessRestartReusesExactPrivateSnapshot() = fixture { provider, metadata, file, store ->
        val expected = snapshot(file)
        store.save(expected)
        assertEquals(expected, OfficePendingPreviewStore(provider, metadata).load())
        assertEquals("DOCX", file.readText())
    }

    @Test fun equalSizeReplacementCannotBeRestored() = fixture { _, _, file, store ->
        store.save(snapshot(file)); file.writeText("SWAP")
        assertThrows(IllegalStateException::class.java) { store.load() }
        assertEquals("SWAP", file.readText())
    }

    @Test fun oldLaunchCannotRetireNewOpenAndClearingNeverDeletesContent() = fixture { _, _, file, store ->
        val old = snapshot(file); store.save(old)
        val next = old.copy(displayName = "Another.docx")
        // Different immutable bytes identify a different pending open.
        file.writeText("NEXT"); val fresh = snapshot(file).copy(displayName = next.displayName); store.save(fresh)
        store.clearMatching(old.path, old.sha256, old.bytes)
        assertEquals(fresh, store.load())
        store.clearMatching(fresh.path, fresh.sha256, fresh.bytes)
        assertNull(store.load()); assertEquals("NEXT", file.readText())
    }

    @Test fun linksAndOutsidePathsAreNeverRestorationAuthority() = fixture { provider, _, file, store ->
        val external = File(provider.parentFile, "outside.docx").apply { writeText("SAFE") }
        assertThrows(IllegalStateException::class.java) { store.save(snapshot(external)) }
        file.delete(); Files.createSymbolicLink(file.toPath(), external.toPath())
        assertThrows(IllegalStateException::class.java) { store.save(snapshot(file)) }
        assertEquals("SAFE", external.readText())
    }

    @Test fun oversizedRecordIsNotDecodedOrTreatedAsAnEmptySuccess() = fixture { _, metadata, _, store ->
        metadata.mkdirs(); File(metadata, "pending.json").writeText("x".repeat(32 * 1024 + 1))
        assertThrows(IllegalStateException::class.java) { store.load() }
    }
}
