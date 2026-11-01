// SPDX-License-Identifier: MPL-2.0
//
// Pure paging/fencing helpers for the Skills hub.
//
// The full schemaVersion-3 catalog is delivered in separately bounded pages
// (`skills.list operation=curated.cards`), never embedded whole in the
// snapshot frame. These helpers keep the accumulation bound and the detail
// sheet's request identity honest without any Compose or host dependency, so
// they are unit-testable without a device.

package com.floe.android.feature.integrations

/** Bounded accumulation rules shared by the host loader and its tests. */
object SkillsCatalogPaging {
    /** Per-request automatic page budget. A real continuation remains
     * available to the user; this is not a ceiling on catalog reachability. */
    const val MAX_PAGES = 32

    /** The wire contract's maximum cards per page. */
    const val MAX_CARDS_PER_PAGE = 50

    /** True only while another real page exists AND the caller may follow it. */
    fun shouldContinue(
        hasMore: Boolean,
        nextToken: String?,
        pagesRead: Int,
        maxPages: Int = MAX_PAGES,
    ): Boolean = hasMore && !nextToken.isNullOrBlank() && pagesRead + 1 < maxPages

    /**
     * Merge one page into the accumulated list by skill id. Existing entries
     * keep their first position (stable Discover order); a later page may
     * replace an entry's fields, but the id is never duplicated.
     */
    fun mergeById(
        existing: List<SkillCatalogCardUi>,
        page: List<SkillCatalogCardUi>,
    ): List<SkillCatalogCardUi> {
        if (page.isEmpty()) return existing
        val order = LinkedHashSet<String>()
        val byId = LinkedHashMap<String, SkillCatalogCardUi>()
        for (card in existing) {
            if (order.add(card.skillId)) byId[card.skillId] = card
        }
        for (card in page) {
            if (order.add(card.skillId)) {
                byId[card.skillId] = card
            } else {
                byId[card.skillId] = card
            }
        }
        return order.mapNotNull { byId[it] }
    }
}

/**
 * Generation fence for one snapshot/card page chain. A pull-to-refresh (or
 * root close) advances the generation; every late page from the old chain is
 * rejected before it can mutate the projection.
 */
class CatalogPageChainFence {
    private val lock = Any()
    private var generation = 0L
    private var rootEpoch: Long? = null

    fun begin(rootEpoch: Long? = null): Long = synchronized(lock) {
        generation += 1
        this.rootEpoch = rootEpoch
        generation
    }

    fun invalidate() = synchronized(lock) {
        generation += 1
        rootEpoch = null
    }

    fun isCurrent(generation: Long): Boolean = synchronized(lock) {
        this.generation == generation
    }

    fun accepts(generation: Long, rootEpoch: Long?): Boolean = synchronized(lock) {
        this.generation == generation && rootEpoch != null && this.rootEpoch == rootEpoch
    }
}

/**
 * Identity fence for one detail-sheet read. A newer open, a dismiss or a root
 * invalidation makes every older callback stale, so a late response can never
 * populate a newly opened sheet with another entry's data.
 */
class SkillDetailRequestGate {
    private val lock = Any()
    private var generation = 0L
    private var openSkillId: String? = null
    private var rootEpoch: Long? = null

    /** Start a new read and return its generation. */
    fun open(skillId: String, rootEpoch: Long? = null): Long = synchronized(lock) {
        generation += 1
        openSkillId = skillId
        this.rootEpoch = rootEpoch
        generation
    }

    /** True only for the CURRENT open skill and its exact generation. */
    fun accepts(generation: Long, skillId: String, rootEpoch: Long? = null): Boolean = synchronized(lock) {
        this.generation == generation && openSkillId == skillId && this.rootEpoch == rootEpoch
    }

    /** Close the sheet for exactly this id. A stale close is a no-op. */
    fun close(skillId: String): Boolean = synchronized(lock) {
        if (openSkillId != skillId) return false
        generation += 1
        openSkillId = null
        rootEpoch = null
        true
    }

    /** Root/epoch invalidation: no in-flight read may publish afterward. */
    fun invalidate() = synchronized(lock) {
        generation += 1
        openSkillId = null
        rootEpoch = null
    }
}
