// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfPageCacheTest {

    @Test
    fun evictsLeastRecentlyUsedWhenOverBudget() {
        val evicted = ArrayList<ByteArray>()
        val cache = ByteBudgetCache<String, ByteArray>(
            maxBytes = 100,
            sizeOf = { it.size.toLong() },
            onEvict = { evicted.add(it) },
        )
        assertTrue(cache.put("a", ByteArray(40)))
        assertTrue(cache.put("b", ByteArray(40)))
        assertNotNull(cache.get("a")) // touch a -> b is now oldest
        assertTrue(cache.put("c", ByteArray(40)))
        assertNull(cache.get("b"))
        assertNotNull(cache.get("a"))
        assertNotNull(cache.get("c"))
        assertEquals(1, evicted.size)
        assertEquals(2, cache.count)
        assertTrue(cache.sizeBytes <= 100)
    }

    @Test
    fun valueLargerThanBudgetIsRefusedWithoutEvicting() {
        val cache = ByteBudgetCache<String, ByteArray>(maxBytes = 64, sizeOf = { it.size.toLong() })
        assertTrue(cache.put("small", ByteArray(32)))
        assertFalse(cache.put("huge", ByteArray(65)))
        assertNotNull(cache.get("small"))
        assertEquals(1, cache.count)
    }

    @Test
    fun replacingAKeyAccountsForTheOldBytes() {
        val cache = ByteBudgetCache<String, ByteArray>(maxBytes = 100, sizeOf = { it.size.toLong() })
        cache.put("a", ByteArray(50))
        cache.put("a", ByteArray(10))
        assertEquals(10L, cache.sizeBytes)
    }

    @Test
    fun retainOnlyDropsForeignEntries() {
        val evicted = ArrayList<ByteArray>()
        val cache = ByteBudgetCache<String, ByteArray>(100, { it.size.toLong() }, { evicted.add(it) })
        cache.put("r:1", ByteArray(10))
        cache.put("t:1", ByteArray(10))
        cache.retainOnly { it.startsWith("r:") }
        assertEquals(listOf("r:1"), cache.keys())
        assertEquals(1, evicted.size)
    }

    @Test
    fun clearReportsEveryEvictionExactlyOnce() {
        var evictions = 0
        val cache = ByteBudgetCache<Int, ByteArray>(100, { it.size.toLong() }) { evictions++ }
        cache.put(1, ByteArray(10))
        cache.put(2, ByteArray(10))
        cache.clear()
        assertEquals(2, evictions)
        assertEquals(0L, cache.sizeBytes)
        assertEquals(0, cache.count)
    }

    @Test
    fun thumbnailPlanIsDeterministicAndBounded() {
        val box = PdfPageBox.of(612f, 792f, 0f)!!
        val page = PdfPageId(3)
        val first = PdfThumbnailPlanner.plan(page, box, 256) as PdfThumbnailPlanResult.Ready
        val second = PdfThumbnailPlanner.plan(page, box, 256) as PdfThumbnailPlanResult.Ready
        assertEquals(first.plan, second.plan)
        assertTrue(first.plan.widthPx <= 256 + 2)
        assertEquals("t:3:256", first.plan.cacheKey)
    }
}
