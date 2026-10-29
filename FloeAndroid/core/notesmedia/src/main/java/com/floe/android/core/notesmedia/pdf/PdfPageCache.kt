// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

/**
 * Byte-budgeted LRU cache used for rendered pages/tiles and thumbnails.
 *
 * Why a byte budget and not an entry count: a single 400% page render is
 * ~8 MB, so an entry-count bound either wastes memory or overflows. Every
 * inserted value must report its own byte size; eviction invokes
 * [onEvict] so Android bitmaps are recycled exactly once (the caller must
 * never recycle a bitmap it handed to this cache while it is cached).
 *
 * Pure Kotlin (no Android types) so the accounting/eviction rules are
 * JVM-testable; the Android wrapper only supplies `sizeOf`/`onEvict`.
 * Thread-safe: sessions touch it from a render worker and from the UI.
 */
class ByteBudgetCache<K : Any, V : Any>(
    private val maxBytes: Long,
    private val sizeOf: (V) -> Long,
    private val onEvict: (V) -> Unit = {},
) {
    init {
        require(maxBytes > 0) { "Cache budget must be positive" }
    }

    private val entries = object : LinkedHashMap<K, V>(16, 0.75f, true) {}

    var sizeBytes: Long = 0L
        private set

    val count: Int get() = synchronized(entries) { entries.size }

    /** Returns the cached value and marks it most-recently used. */
    fun get(key: K): V? = synchronized(entries) { entries[key] }

    fun peek(key: K): V? = synchronized(entries) { entries[key] }

    /**
     * Inserts/replaces one value. A value larger than the whole budget is
     * refused (evicts nothing, returns false) so one huge render can never
     * wipe the cache and then also fail to fit.
     */
    fun put(key: K, value: V): Boolean {
        val bytes = sizeOf(value)
        if (bytes <= 0L) return false
        val evicted = ArrayList<V>()
        synchronized(entries) {
            if (bytes > maxBytes) return false
            entries.remove(key)?.let { old ->
                sizeBytes -= sizeOf(old).coerceAtLeast(0L)
                evicted.add(old)
            }
            entries[key] = value
            sizeBytes += bytes
            while (sizeBytes > maxBytes && entries.isNotEmpty()) {
                val it = entries.entries.iterator()
                val eldest = it.next()
                if (eldest.key == key && entries.size == 1) break
                it.remove()
                sizeBytes -= sizeOf(eldest.value).coerceAtLeast(0L)
                evicted.add(eldest.value)
            }
        }
        evicted.forEach { runCatching { onEvict(it) } }
        return true
    }

    fun remove(key: K): V? {
        val removed = synchronized(entries) {
            entries.remove(key)?.also { sizeBytes -= sizeOf(it).coerceAtLeast(0L) }
        }
        if (removed != null) runCatching { onEvict(removed) }
        return removed
    }

    fun clear() {
        val all = synchronized(entries) {
            val copy = entries.values.toList()
            entries.clear()
            sizeBytes = 0L
            copy
        }
        all.forEach { runCatching { onEvict(it) } }
    }

    /** Evicts everything whose key is not accepted by [keep] (e.g. after page change). */
    fun retainOnly(keep: (K) -> Boolean) {
        val evicted = ArrayList<V>()
        synchronized(entries) {
            val it = entries.entries.iterator()
            while (it.hasNext()) {
                val e = it.next()
                if (!keep(e.key)) {
                    it.remove()
                    sizeBytes -= sizeOf(e.value).coerceAtLeast(0L)
                    evicted.add(e.value)
                }
            }
        }
        evicted.forEach { runCatching { onEvict(it) } }
    }

    fun keys(): List<K> = synchronized(entries) { entries.keys.toList() }
}

/** Deterministic cache keys; zoom and page are the full render identity. */
object PdfCacheKeys {
    fun render(pageIndex: Int, zoomPercent: Int): String = "r:$pageIndex:$zoomPercent"
    fun thumbnail(pageIndex: Int, maxEdgePx: Int): String = "t:$pageIndex:$maxEdgePx"
    fun tile(pageIndex: Int, column: Int, row: Int, zoomPercent: Int): String = "g:$pageIndex:$column:$row:$zoomPercent"
}

/**
 * A thumbnail request the session can actually execute against the shared
 * renderer. [widthPx]×[heightPx] is the EXACT bitmap the renderer will
 * produce (same clamp rules), so the UI can size its placeholder without a
 * second guess.
 */
data class PdfThumbnailPlan(
    val page: PdfPageId,
    val zoomPercent: Int,
    val widthPx: Int,
    val heightPx: Int,
    val cacheKey: String,
)

sealed class PdfThumbnailPlanResult {
    data class Ready(val plan: PdfThumbnailPlan) : PdfThumbnailPlanResult()
    data class Refused(val reason: PdfThumbnailRefusal) : PdfThumbnailPlanResult()
}

enum class PdfThumbnailRefusal {
    INVALID_PAGE,
    INVALID_PAGE_BOX,
    RENDERER_REFUSED_SIZE,
}

object PdfThumbnailPlanner {

    /**
     * Plans one thumbnail. The page box must come from [PdfPageBoxReader]; the
     * plan is computed with the renderer's own clamp authority and refused
     * (never guessed) when that authority rejects the page.
     */
    fun plan(page: PdfPageId, box: PdfPageBox, maxEdgePx: Int): PdfThumbnailPlanResult {
        if (!box.displayedWidthPt.isFinite() || !box.displayedHeightPt.isFinite() ||
            box.displayedWidthPt <= 0f || box.displayedHeightPt <= 0f
        ) {
            return PdfThumbnailPlanResult.Refused(PdfThumbnailRefusal.INVALID_PAGE_BOX)
        }
        val zoom = PdfRenderPlanner.thumbnailZoomPercent(box, maxEdgePx)
        val size = PdfRenderPlanner.expectedBitmap(box, zoom)
            ?: return PdfThumbnailPlanResult.Refused(PdfThumbnailRefusal.RENDERER_REFUSED_SIZE)
        return PdfThumbnailPlanResult.Ready(
            PdfThumbnailPlan(
                page = page,
                zoomPercent = zoom,
                widthPx = size.first,
                heightPx = size.second,
                cacheKey = PdfCacheKeys.thumbnail(page.pageIndex, maxEdgePx),
            ),
        )
    }
}
