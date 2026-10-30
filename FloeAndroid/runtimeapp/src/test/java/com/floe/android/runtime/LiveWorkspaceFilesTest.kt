// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64

/**
 * G07.3A AUTHORED-NOT-RUN regression for the bounded READ-ONLY live guest file
 * snapshot (`LiveWorkspaceFiles`).
 *
 * This is the real implementation over a real temp directory, not a mirror of
 * its conditions: it pins root containment, component-wise no-follow, the
 * closed refusal vocabulary, deterministic bounded listing and the exact
 * metadata/content page contract. The runtime-process generation is injected,
 * so the JVM test never depends on Android's Process stub. The live race
 * (`changedDuringRead`) is exercised by a file that is truncated between the
 * pre-stat and the post-stat using the same fd/path primitives the method
 * uses; a flaky-by-timing variant is deliberately NOT authored.
 */
class LiveWorkspaceFilesTest {
    private val generation = "test-generation-1"
    private val files = LiveWorkspaceFiles(generation = { generation })

    private fun workspace(): java.io.File =
        Files.createTempDirectory("floe-live-files").toFile().also { root ->
            java.io.File(root, "a.txt").writeText("hello live guest")
            val directory = java.io.File(root, "dir").apply { mkdirs() }
            java.io.File(directory, "b.txt").writeText("nested")
            Files.createSymbolicLink(java.io.File(root, "link").toPath(),
                java.io.File(root, "a.txt").toPath())
            Files.createSymbolicLink(java.io.File(root, "linkdir").toPath(),
                directory.toPath())
        }

    private fun tree(root: java.io.File, path: String = "", maxEntries: Int = 200,
                     maxDepth: Int = 3): org.json.JSONObject {
        val payload = org.json.JSONObject().put("relativePath", path)
            .put("maxEntries", maxEntries).put("maxDepth", maxDepth).put("recursive", true)
        return files.tree(root, payload)
    }

    private fun read(root: java.io.File, path: String, offset: Long = 0,
                     maxBytes: Int = 16 * 1024): org.json.JSONObject {
        val payload = org.json.JSONObject().put("relativePath", path)
            .put("offset", offset).put("maxBytes", maxBytes)
        return files.read(root, payload)
    }

    private fun entries(objectValue: org.json.JSONObject): List<org.json.JSONObject> {
        val array = objectValue.getJSONArray("entries")
        return (0 until array.length()).map { array.getJSONObject(it) }
    }

    @Test
    fun `root tree is deterministic and lists a symlink without following it`() {
        val root = workspace()
        try {
            val tree = tree(root)
            assertEquals("ok", tree.getString("state"))
            assertEquals(generation, tree.getString("generation"))
            assertEquals(64, tree.getString("listingToken").length)
            assertEquals("a stable listing yields a stable token",
                tree.getString("listingToken"), tree(root).getString("listingToken"))
            assertFalse(tree.getBoolean("truncated"))
            val paths = entries(tree).map { it.getString("path") }
            assertEquals(listOf("a.txt", "dir", "dir/b.txt", "link", "linkdir"), paths.sorted())
            val link = entries(tree).first { it.getString("path") == "link" }
            assertEquals("symlink", link.getString("kind"))
            val directory = entries(tree).first { it.getString("path") == "dir" }
            assertEquals("directory", directory.getString("kind"))
            assertTrue(entries(tree).any { it.getString("path") == "dir/b.txt" })
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `listing is bounded by entries and depth`() {
        val root = workspace()
        try {
            val capped = tree(root, maxEntries = 1)
            assertTrue(capped.getBoolean("truncated"))
            assertEquals(1, entries(capped).size)

            val shallow = tree(root, maxDepth = 0)
            assertFalse(entries(shallow).any { it.getString("path") == "dir/b.txt" })

            val deep = tree(root, path = "dir", maxDepth = 2)
            assertEquals(listOf("dir/b.txt"), entries(deep).map { it.getString("path") })
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `path grammar and containment refuse traversal absolute and nuling paths`() {
        val root = workspace()
        try {
            for (path in listOf("../a.txt", "dir/../../a.txt", "/etc/passwd", "dir\\a.txt",
                                 "dir//b.txt", "dir/./b.txt", "a.txt\u0000")) {
                val result = tree(root, path)
                assertEquals("path=$path", "refused", result.getString("state"))
                assertEquals("pathOutOfScope", result.getString("code"))
            }
            assertEquals("refused", read(root, "../a.txt").getString("state"))
            assertEquals("refused", read(root, "/etc/passwd").getString("state"))
            assertEquals("refused", read(root, "link").getString("state"))
            assertEquals("refused", read(root, "linkdir/b.txt").getString("state"))
            assertEquals("refused", read(root, "").getString("state"))
            assertEquals("refused", read(root, "dir").getString("state"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `many-entry directory enumeration is bounded to the remaining budget`() {
        val root = java.nio.file.Files.createTempDirectory("floe-many-entries").toFile()
        try {
            for (index in 0 until 5_000) {
                java.io.File(root, "f%05d".format(index)).writeText("x")
            }
            val page = tree(root, maxEntries = 16, maxDepth = 0)
            assertTrue("the listing must be marked truncated", page.getBoolean("truncated"))
            val paths = entries(page).map { it.getString("path") }
            assertEquals("at most the requested budget", 16, paths.size)
            assertEquals("deterministic lexicographic prefix",
                (0 until 16).map { "f%05d".format(it) }, paths)
            assertEquals(64, page.getString("listingToken").length)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `read page content digest size mtime and truncation are exact`() {
        val root = workspace()
        try {
            val whole = read(root, "a.txt")
            assertEquals("ok", whole.getString("state"))
            assertEquals(generation, whole.getString("generation"))
            assertEquals("a.txt", whole.getString("path"))
            assertEquals(0L, whole.getLong("offset"))
            assertEquals(16L, whole.getLong("size"))
            assertEquals(16, whole.getInt("bytes"))
            assertFalse(whole.getBoolean("truncated"))
            val bytes = Base64.getDecoder().decode(whole.getString("contentBase64"))
            assertEquals("hello live guest", String(bytes, Charsets.UTF_8))
            val expected = MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }
            assertEquals(expected, whole.getString("digest"))
            assertEquals(64, whole.getString("consistencyToken").length)
            assertEquals("the same page/version yields the same consistency token",
                whole.getString("consistencyToken"),
                read(root, "a.txt").getString("consistencyToken"))
            assertTrue(whole.getLong("mtimeMillis") > 0)

            val page = read(root, "a.txt", offset = 6, maxBytes = 4)
            assertEquals(6L, page.getLong("offset"))
            assertEquals(4, page.getInt("bytes"))
            assertTrue(page.getBoolean("truncated"))
            assertEquals("live", String(Base64.getDecoder().decode(page.getString("contentBase64"))))

            val offsetPastEnd = read(root, "a.txt", offset = 99)
            assertEquals("refused", offsetPastEnd.getString("state"))
            assertEquals("offsetPastEnd", offsetPastEnd.getString("code"))

            val zeroLength = read(root, "a.txt", offset = 16)
            assertEquals("ok", zeroLength.getString("state"))
            assertEquals(0, zeroLength.getInt("bytes"))
            assertEquals(64, zeroLength.getString("digest").length)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `read caps the requested page at the native bound and refuses empty paths`() {
        val root = workspace()
        try {
            java.io.File(root, "big.txt").writeText("x".repeat(64 * 1024))
            val page = read(root, "big.txt", maxBytes = 4 * 1024 * 1024)
            assertEquals(LiveWorkspaceFiles.MAX_READ_BYTES, page.getInt("bytes"))
            assertTrue(page.getBoolean("truncated"))
            val empty = read(root, "   ")
            // A whitespace name is a legal component only if it exists; here it
            // must be an honest path-not-found refusal, never a root escape.
            assertTrue(setOf("pathOutOfScope", "offsetPastEnd").contains(empty.optString("code")) ||
                "refused" == empty.optString("state"))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `a workspace root that is itself a symlink is refused`() {
        val real = workspace()
        val link = Files.createTempDirectory("floe-live-link").toFile()
        try {
            Files.createSymbolicLink(java.io.File(link, "root").toPath(), real.toPath())
            val result = tree(java.io.File(link, "root"))
            assertEquals("refused", result.getString("state"))
            assertEquals("pathOutOfScope", result.getString("code"))
        } finally {
            link.deleteRecursively()
            real.deleteRecursively()
        }
    }

    @Test
    fun `read retries when the file changes during the read`() {
        val root = workspace()
        try {
            val target = java.io.File(root, "race.txt")
            target.writeText("0123456789")
            val originalMtime = target.lastModified()
            var fired = false
            // Deterministic seam: the file is rewritten AFTER the bytes were
            // read and BEFORE the post-read identity check. The production
            // path must answer the typed retry, never a complete page.
            val racing = LiveWorkspaceFiles(generation = { generation }) {
                if (!fired) {
                    fired = true
                    target.writeText("abcdefghij")
                    target.setLastModified(originalMtime + 5_000)
                }
            }
            val page = racing.read(root, java.io.File(root, "race.txt").let {
                org.json.JSONObject().put("relativePath", "race.txt")
                    .put("offset", 0L).put("maxBytes", 4)
            })
            assertEquals("retry", page.optString("state"))
            assertEquals("changedDuringRead", page.optString("code"))
        } finally {
            root.deleteRecursively()
        }
    }

}
