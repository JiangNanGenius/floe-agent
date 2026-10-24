// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.feature.ide.api.IdeFileRow
import com.floe.android.feature.ide.internal.IdeDiffModel
import com.floe.android.feature.ide.internal.IdeFileTreeModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Lazy tree flattening + unified-diff classification (iOS DiffView rules). */
class IdePureModelsTest {

    private fun dir(p: String, name: String) = IdeFileRow(p, name, true)
    private fun file(p: String, name: String) = IdeFileRow(p, name, false)

    @Test
    fun rootOnlyWhenNothingExpanded() {
        val rows = IdeFileTreeModel.flatten(
            rootChildren = listOf(dir("src", "src"), file("README", "README")),
            childrenByPath = emptyMap(),
            expandedPaths = emptySet(),
            loadingPaths = emptySet(),
        )
        assertEquals(listOf("src", "README"), rows.map { it.file.relativePath })
        assertEquals(listOf(0, 0), rows.map { it.depth })
    }

    @Test
    fun expandedLoadedDirectoryShowsChildren() {
        val rows = IdeFileTreeModel.flatten(
            rootChildren = listOf(dir("src", "src")),
            childrenByPath = mapOf("src" to listOf(file("src/main.kt", "main.kt"))),
            expandedPaths = setOf("src"),
            loadingPaths = emptySet(),
        )
        assertEquals(listOf("src", "src/main.kt"), rows.map { it.file.relativePath })
        assertEquals(listOf(0, 1), rows.map { it.depth })
        assertTrue(rows[0].expanded)
    }

    @Test
    fun expandedUnloadedDirectoryRendersNoChildrenButMarksLoading() {
        val rows = IdeFileTreeModel.flatten(
            rootChildren = listOf(dir("src", "src")),
            childrenByPath = emptyMap(),
            expandedPaths = setOf("src"),
            loadingPaths = setOf("src"),
        )
        assertEquals(1, rows.size)
        assertTrue(rows[0].childrenLoading)
    }

    @Test
    fun nestedExpansionDepths() {
        val rows = IdeFileTreeModel.flatten(
            rootChildren = listOf(dir("a", "a")),
            childrenByPath = mapOf(
                "a" to listOf(dir("a/b", "b")),
                "a/b" to listOf(file("a/b/c.kt", "c.kt")),
            ),
            expandedPaths = setOf("a", "a/b"),
            loadingPaths = emptySet(),
        )
        assertEquals(listOf("a", "a/b", "a/b/c.kt"), rows.map { it.file.relativePath })
        assertEquals(listOf(0, 1, 2), rows.map { it.depth })
    }

    @Test
    fun diffClassificationMirrorsIos() {
        val diff = """
            --- a/x.kt
            +++ b/x.kt
            @@ -1,2 +1,3 @@
             val a = 1
            -val b = 2
            +val b = 3
            +// tail
            """.trimIndent()
        val classified = IdeDiffModel.classify(diff)
        assertEquals(IdeDiffLineKind.HEADER, classified.lines[0].kind)
        assertEquals(IdeDiffLineKind.HEADER, classified.lines[1].kind)
        assertEquals(IdeDiffLineKind.HUNK_HEADER, classified.lines[2].kind)
        assertEquals(IdeDiffLineKind.CONTEXT, classified.lines[3].kind)
        assertEquals(IdeDiffLineKind.REMOVAL, classified.lines[4].kind)
        assertEquals(IdeDiffLineKind.ADDITION, classified.lines[5].kind)
        assertEquals(IdeDiffLineKind.ADDITION, classified.lines[6].kind)
        assertEquals(2, classified.additions)
        assertEquals(1, classified.removals)
    }

    @Test
    fun diffDropsBlankLines() {
        val classified = IdeDiffModel.classify("line1\n\nline2\n")
        assertEquals(2, classified.lines.size)
    }
}
