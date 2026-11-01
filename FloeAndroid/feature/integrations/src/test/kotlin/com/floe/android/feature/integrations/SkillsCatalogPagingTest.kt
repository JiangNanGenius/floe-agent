// SPDX-License-Identifier: MPL-2.0
//
// Bounded catalog paging + detail-request fence regressions. Authored for
// unified qualification; this source-only stage does not run Gradle/JVM.
package com.floe.android.feature.integrations

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillsCatalogPagingTest {
    @Test
    fun `root recreation rejects an old page before another refresh starts`() {
        val fence = CatalogPageChainFence()
        val chain = fence.begin(rootEpoch = 11)
        assertTrue(fence.accepts(chain, rootEpoch = 11))
        assertFalse(fence.accepts(chain, rootEpoch = null))
        assertFalse(fence.accepts(chain, rootEpoch = 12))
        fence.invalidate()
        assertFalse(fence.accepts(chain, rootEpoch = 11))
    }

    @Test
    fun `a detail callback cannot cross roots with the same skill id`() {
        val gate = SkillDetailRequestGate()
        val request = gate.open("skill-a", rootEpoch = 11)
        assertTrue(gate.accepts(request, "skill-a", rootEpoch = 11))
        assertFalse(gate.accepts(request, "skill-a", rootEpoch = 12))
        assertFalse(gate.accepts(request, "skill-a", rootEpoch = null))
    }

    private fun card(id: String, version: String = "1.0.0") = SkillCatalogCardUi(
        skillId = id,
        name = id,
        version = version,
        summary = "",
        state = CatalogCardStateUi.NotInstalled,
    )

    @Test
    fun `page accumulation deduplicates by id and keeps first position`() {
        val merged = SkillsCatalogPaging.mergeById(
            existing = listOf(card("a"), card("b")),
            page = listOf(card("c"), card("a", version = "2.0.0")),
        )
        assertEquals(listOf("a", "b", "c"), merged.map { it.skillId })
        assertEquals("2.0.0", merged.first { it.skillId == "a" }.version)
    }

    @Test
    fun `page continuation is bounded and token-bound`() {
        assertTrue(SkillsCatalogPaging.shouldContinue(true, "next", 0))
        assertFalse(SkillsCatalogPaging.shouldContinue(false, "next", 0))
        assertFalse(SkillsCatalogPaging.shouldContinue(true, null, 0))
        assertFalse(SkillsCatalogPaging.shouldContinue(true, "", 0))
        assertFalse(SkillsCatalogPaging.shouldContinue(
            true, "next", SkillsCatalogPaging.MAX_PAGES - 1))
    }

    @Test
    fun `detail gate rejects a late callback from an older open or dismiss`() {
        val gate = SkillDetailRequestGate()
        val first = gate.open("skill-a")
        assertTrue(gate.accepts(first, "skill-a"))

        val second = gate.open("skill-b")
        assertFalse(gate.accepts(first, "skill-a"))
        assertTrue(gate.accepts(second, "skill-b"))

        assertTrue(gate.close("skill-b"))
        assertFalse(gate.accepts(second, "skill-b"))
        // A stale close for a replaced sheet must not close the new one.
        val third = gate.open("skill-c")
        assertFalse(gate.close("skill-b"))
        assertTrue(gate.accepts(third, "skill-c"))
    }

    @Test
    fun `root invalidation makes every in-flight detail callback stale`() {
        val gate = SkillDetailRequestGate()
        val generation = gate.open("skill-a")
        gate.invalidate()
        assertFalse(gate.accepts(generation, "skill-a"))
    }

    @Test
    fun `refresh mid-page makes every old snapshot or card page stale`() {
        val fence = CatalogPageChainFence()
        val first = fence.begin()
        assertTrue(fence.isCurrent(first))
        // Pull-to-refresh/root change while the first page is still in flight.
        val second = fence.begin()
        assertFalse(fence.isCurrent(first))
        assertTrue(fence.isCurrent(second))
        fence.invalidate()
        assertFalse(fence.isCurrent(second))
    }
}
