// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Full120 catalog-paging repair — JVM regressions for the bounded
 * `environment.list` reader. No Android class, JNI, device or registry is
 * touched: the native `listPage` boundary is replaced by deterministic pages
 * that pin the EXACT contract the native authority now implements.
 */
class RuntimeEnvironmentCatalogReaderTest {
    private val project = "11111111-1111-4111-8111-111111111111"
    private val owner = "a".repeat(64)
    private val revision = "debian-bookworm-test"

    // MARK: - Fixtures

    private fun row(
        id: String,
        kind: String,
        rowOwner: String? = null,
        parentID: String? = null,
        name: String? = null,
    ): JSONObject = JSONObject().put("id", id).put("kind", kind)
        .put("state", "active")
        .put("baseRevision", revision)
        .put("requiresRebuild", false)
        .put("bytes", 0)
        .put("packageCount", 0)
        .put("layerFormat", 1)
        .apply {
            put("ownerID", rowOwner ?: JSONObject.NULL)
            put("parentID", parentID ?: JSONObject.NULL)
            put("name", name ?: JSONObject.NULL)
        }

    private fun page(
        rows: List<JSONObject>,
        total: Int,
        nextCursor: String? = null,
        scope: String = "project",
        pageProject: String? = project,
        pageOwner: String? = owner,
        baseRevision: String = revision,
    ): JSONObject = JSONObject()
        .put("baseRevision", baseRevision)
        .put("environments", JSONArray(rows))
        .put("nextCursor", nextCursor ?: JSONObject.NULL)
        .put("projectID", pageProject ?: JSONObject.NULL)
        .put("workspaceOwnerID", pageOwner ?: JSONObject.NULL)
        .put("scope", scope)
        .put("total", total)

    private class Source(val pages: List<JSONObject>) : RuntimeCatalogPageSource {
        val calls = ArrayList<Triple<String?, String?, Int>>()
        override fun page(projectID: String?, cursor: String?, limit: Int): JSONObject {
            calls.add(Triple(projectID, cursor, limit))
            return pages[calls.size - 1]
        }
    }

    private fun reader(
        source: RuntimeCatalogPageSource,
        pageLimit: Int = 2,
        maximumPages: Int = 8,
        maximumRows: Int = 64,
        maximumResultBytes: Int = 65_024,
        cancelled: () -> Boolean = { false },
    ) = RuntimeEnvironmentCatalogReader(source, pageLimit, maximumPages, maximumRows,
        maximumResultBytes, cancelled)

    private fun refusalCode(block: () -> Unit): String? =
        try {
            block()
            null
        } catch (refusal: RuntimeAuthorityRefusal) {
            refusal.code
        }

    private fun ids(result: JSONObject): List<String> {
        val rows = result.getJSONArray("environments")
        return (0 until rows.length()).map { rows.getJSONObject(it).getString("id") }
    }

    private fun projectRows(vararg ids: String) = ids.map { row(it, "project", rowOwner = owner) }
    private fun sessionRows(vararg ids: String) = ids.map { row(it, "session", parentID = "project-1") }

    // MARK: - Complete reconstruction

    @Test
    fun scopedPagesReconstructTheCompleteCatalogInOrderWithNoLoss() {
        val source = Source(listOf(
            page(projectRows("project-1") + sessionRows("session-1"), total = 4, nextCursor = "v1.${"1".repeat(64)}.2"),
            page(sessionRows("session-2", "session-3"), total = 4),
        ))
        val result = reader(source).read(project)

        assertEquals(listOf("project-1", "session-1", "session-2", "session-3"), ids(result))
        assertEquals(revision, result.getString("baseRevision"))
        assertEquals(project, result.getString("projectID"))
        assertEquals(owner, result.getString("workspaceOwnerID"))
        assertEquals(
            listOf(Triple(project, null, 2), Triple(project, "v1.${"1".repeat(64)}.2", 2)),
            source.calls,
        )
    }

    @Test
    fun unscopedReadKeepsTheLegacyShapeAndDropsScopeKeys() {
        val source = Source(listOf(
            page(listOf(row("shared", "shared"), row("tpl", "template")),
                total = 2, scope = "all", pageProject = null, pageOwner = null),
        ))
        val result = reader(source).read(null)

        assertEquals(listOf("shared", "tpl"), ids(result))
        assertFalse(result.has("projectID"))
        assertFalse(result.has("workspaceOwnerID"))
        assertEquals(listOf<String?>(null), source.calls.map { it.first })
    }

    @Test
    fun genuinelyEmptyScopedCatalogIsAnEmptySuccess() {
        val source = Source(listOf(page(emptyList(), total = 0)))
        val result = reader(source).read(project)
        assertEquals(0, result.getJSONArray("environments").length())
        assertEquals(project, result.getString("projectID"))
    }

    // MARK: - Continuity / completeness refusals

    @Test
    fun terminalPageMustExposeTheAdvertisedCompleteTotal() {
        val source = Source(listOf(page(projectRows("project-1"), total = 3)))
        assertEquals("invalidWire", refusalCode { reader(source).read(project) })
    }

    @Test
    fun repeatedOrEmptyContinuationsFailClosed() {
        val repeated = Source(listOf(
            page(projectRows("project-1"), total = 2, nextCursor = "v1.${"2".repeat(64)}.1"),
            page(sessionRows("session-1"), total = 2, nextCursor = "v1.${"2".repeat(64)}.1"),
        ))
        assertEquals("invalidWire", refusalCode { reader(repeated).read(project) })

        val empty = Source(listOf(
            page(projectRows("project-1"), total = 2, nextCursor = "v1.${"3".repeat(64)}.1"),
            page(emptyList(), total = 2, nextCursor = "v1.${"3".repeat(64)}.1"),
        ))
        assertEquals("invalidWire", refusalCode { reader(empty).read(project) })
    }

    @Test
    fun duplicateRowAcrossPagesFailsClosed() {
        val source = Source(listOf(
            page(projectRows("project-1"), total = 2, nextCursor = "v1.${"4".repeat(64)}.1"),
            page(projectRows("project-1"), total = 2),
        ))
        assertEquals("invalidWire", refusalCode { reader(source).read(project) })

        val unscoped = Source(listOf(
            page(listOf(row("shared", "shared")), total = 2, scope = "all",
                pageProject = null, pageOwner = null, nextCursor = "v1.${"a".repeat(64)}.1"),
            page(listOf(row("shared", "shared")), total = 2, scope = "all",
                pageProject = null, pageOwner = null),
        ))
        assertEquals("invalidWire", refusalCode { reader(unscoped).read(null) })
    }

    @Test
    fun unstableTotalOrBaseRevisionFailsClosed() {
        val total = Source(listOf(
            page(projectRows("project-1"), total = 2, nextCursor = "v1.${"5".repeat(64)}.1"),
            page(sessionRows("session-1"), total = 3),
        ))
        assertEquals("invalidWire", refusalCode { reader(total).read(project) })

        val revisionChange = Source(listOf(
            page(projectRows("project-1"), total = 2, nextCursor = "v1.${"6".repeat(64)}.1"),
            page(sessionRows("session-1"), total = 2, baseRevision = "other-revision"),
        ))
        assertEquals("invalidWire", refusalCode { reader(revisionChange).read(project) })
    }

    @Test
    fun pageAndRowBudgetsAreEnforced() {
        val endless = object : RuntimeCatalogPageSource {
            var index = 0
            override fun page(projectID: String?, cursor: String?, limit: Int): JSONObject {
                index++
                return page(listOf(row("project-$index", "project", rowOwner = owner)),
                    total = 99,
                    nextCursor = "v1." + index.toString().repeat(64).take(64) + ".$index")
            }
        }
        assertEquals("invalidWire", refusalCode { reader(endless).read(project) })

        val tooManyRows = Source(listOf(
            page(projectRows("project-1") + sessionRows("session-1"), total = 3,
                nextCursor = "v1.${"7".repeat(64)}.2"),
            page(sessionRows("session-2", "session-3"), total = 3),
        ))
        assertEquals("invalidWire", refusalCode {
            reader(tooManyRows, maximumRows = 3).read(project)
        })
    }

    // MARK: - Scope / ownership refusals

    @Test
    fun scopeAndOwnerEchoesMustMatchTheRequestedProject() {
        for (mismatch in listOf(
            page(projectRows("project-1"), total = 1, scope = "all"),
            page(projectRows("project-1"), total = 1,
                pageProject = "22222222-2222-4222-8222-222222222222"),
            page(projectRows("project-1"), total = 1, pageOwner = "A".repeat(64)),
            page(projectRows("project-1"), total = 1, pageOwner = "abc"),
        )) {
            assertEquals("invalidWire", refusalCode { reader(Source(listOf(mismatch))).read(project) })
        }
        val unscopedWithEcho = page(listOf(row("shared", "shared")), total = 1,
            scope = "all", pageProject = project, pageOwner = owner)
        assertEquals("invalidWire", refusalCode { reader(Source(listOf(unscopedWithEcho))).read(null) })
    }

    @Test
    fun foreignOrMisOwnedRowsInAScopedAggregateFailClosed() {
        // Project row owned by another workspace.
        val foreignProject = page(listOf(row("project-1", "project", rowOwner = "b".repeat(64))), total = 1)
        assertEquals("invalidWire", refusalCode { reader(Source(listOf(foreignProject))).read(project) })

        // Session whose parent is not part of this scoped aggregate.
        val foreignSession = Source(listOf(
            page(projectRows("project-1"), total = 2, nextCursor = "v1.${"8".repeat(64)}.1"),
            page(listOf(row("session-1", "session", parentID = "another-project")), total = 2),
        ))
        assertEquals("invalidWire", refusalCode { reader(foreignSession).read(project) })

        // Non project/session kind in a scoped page.
        val foreignKind = page(projectRows("project-1") + listOf(row("tpl", "template")), total = 2)
        assertEquals("invalidWire", refusalCode { reader(Source(listOf(foreignKind))).read(project) })

        // Sessions only, without their project row.
        val orphan = page(sessionRows("session-1"), total = 1)
        assertEquals("invalidWire", refusalCode { reader(Source(listOf(orphan))).read(project) })
    }

    @Test
    fun malformedPageShapesFailClosed() {
        fun malformed(block: (JSONObject) -> Unit): JSONObject =
            page(projectRows("project-1"), total = 1).also(block)
        val cases = listOf(
            malformed { it.remove("environments") },
            malformed { it.put("environments", "rows") },
            malformed { it.put("environments", JSONArray(listOf("not-an-object", 5))) },
            malformed { it.remove("total") },
            malformed { it.put("total", "1") },
            malformed { it.put("total", -1) },
            malformed { it.put("total", 5_000) },
            malformed { it.put("baseRevision", "") },
            malformed { it.put("baseRevision", "r".repeat(65)) },
            malformed { it.put("baseRevision", 1) },
            malformed { it.put("projectID", 5) },
            malformed { it.put("nextCursor", "bad cursor") },
            malformed { it.put("nextCursor", "v".repeat(97)) },
            JSONObject()
                .put("baseRevision", revision).put("scope", "project")
                .put("projectID", project).put("workspaceOwnerID", owner)
                .put("total", 1).put("nextCursor", JSONObject.NULL)
                .put("environments", JSONArray(listOf(JSONObject().put("kind", "project")))),
            JSONObject()
                .put("baseRevision", revision).put("scope", "project")
                .put("projectID", project).put("workspaceOwnerID", owner)
                .put("total", 1).put("nextCursor", JSONObject.NULL)
                .put("environments", JSONArray(listOf(JSONObject()
                    .put("id", 5).put("kind", "project").put("ownerID", owner)))),
            JSONObject()
                .put("baseRevision", revision).put("scope", "project")
                .put("projectID", project).put("workspaceOwnerID", owner)
                .put("total", 1).put("nextCursor", JSONObject.NULL)
                .put("environments", JSONArray(listOf(JSONObject()
                    .put("id", "bad id with spaces").put("kind", "project").put("ownerID", owner)))),
        )
        for (case in cases) {
            assertEquals("invalidWire", refusalCode { reader(Source(listOf(case))).read(project) })
        }
    }

    // MARK: - Bounded runtime envelope

    @Test
    fun aCompleteCatalogThatCannotFitTheRuntimeEnvelopeFailsExplicitly() {
        val rows = (0 until 12).map { index ->
            row("project-$index", "project", rowOwner = owner, name = "n".repeat(2_000))
        }
        val source = Source(listOf(page(rows, total = rows.size)))
        assertEquals("replyTooLarge",
            refusalCode { reader(source, pageLimit = rows.size, maximumResultBytes = 8_192).read(project) })

        val fits = reader(Source(listOf(page(rows, total = rows.size))), pageLimit = rows.size)
        assertEquals(rows.size, ids(fits.read(project)).size)
    }

    // MARK: - Cancellation

    @Test
    fun callerCancellationStopsBeforeReadingAnotherPage() {
        val source = Source(listOf(
            page(projectRows("project-1"), total = 2, nextCursor = "v1.${"9".repeat(64)}.1"),
            page(sessionRows("session-1"), total = 2),
        ))
        var calls = 0
        val code = refusalCode {
            reader(source, cancelled = { calls++ >= 1 }).read(project)
        }
        assertEquals("cancelled", code)
        assertEquals("no page may be fetched after cancellation", 1, source.calls.size)
    }

    // MARK: - Page source budget passed to the native layer

    @Test
    fun nativePageLimitIsTheBoundedDefault() {
        val source = Source(listOf(page(projectRows("project-1"), total = 1)))
        reader(source, pageLimit = 200).read(project)
        assertEquals(200, source.calls.single().third)
        assertNull(source.calls.single().second)
        assertEquals(project, source.calls.single().first)
    }
}
