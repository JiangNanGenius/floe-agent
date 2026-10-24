// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import java.util.concurrent.atomic.AtomicBoolean

/** Process-local reference ownership, never permission truth or a journal.
 * All features must retain before using a grant and release after actual IO
 * settles. Platform check/take/reference registration and final release share
 * one critical section; a reused grant is never claimed as newly acquired.
 */
class SafSharedGrantBroker(private val referenceLimit: Int = 4096) : SafReleaseBroker {
    init { require(referenceLimit > 0) }
    private data class Key(val uri: SafUriRef, val flag: SafAccessFlag)
    private class Entry {
        val references = HashSet<Long>()
        var ownedRelease: (() -> Boolean)? = null
    }
    private val lock = Any()
    private val entries = HashMap<Key, Entry>()
    private val releasing = HashSet<Key>()
    private var nextID = 0L
    private var referenceCount = 0

    enum class Release { RETAINED, RELEASED, PREEXISTING_PRESERVED, FAILED, ALREADY_CLOSED }

    class Lease internal constructor(
        private val broker: SafSharedGrantBroker,
        internal val uri: SafUriRef,
        internal val flag: SafAccessFlag,
        internal val id: Long,
        /** Observation at acquisition only. Recheck OS before later IO. */
        val persistedAtAcquisition: Boolean,
    ) : AutoCloseable {
        private val closed = AtomicBoolean()
        fun release(): Release = if (closed.compareAndSet(false, true)) broker.drop(this) else Release.ALREADY_CLOSED
        override fun close() { release() }
    }

    fun <T> withExclusiveAuthority(block: () -> T): T = synchronized(lock) { block() }

    /** Every callback is invoked while the same authority is held. A failed
     * take leaves an ordinary session reference, never a persisted permission.
     * The release callback is retained only for a proven newly taken grant.
     */
    fun acquire(
        uri: SafUriRef,
        flag: SafAccessFlag,
        isPersisted: () -> Boolean,
        take: () -> Unit,
        release: () -> Boolean,
    ): Lease = synchronized(lock) {
        val key = Key(uri, flag)
        check(key !in releasing) { "grantReleaseInProgress" }
        check(referenceCount < referenceLimit && nextID < Long.MAX_VALUE) { "grantReferenceLimit" }
        val heldBefore = isPersisted()
        var took = false
        if (!heldBefore) {
            try { take(); took = true } catch (_: SecurityException) { } catch (_: IllegalArgumentException) { }
        }
        val heldAfter = try { isPersisted() } catch (error: RuntimeException) {
            if (!heldBefore && took) runCatching { release() }
            throw error
        }
        val entry = entries.getOrPut(key) { Entry() }
        if (!heldAfter) entry.ownedRelease = null // revoked, not permission from a cache
        if (!heldBefore && took && heldAfter) entry.ownedRelease = release
        val id = ++nextID
        entry.references += id; referenceCount++
        Lease(this, uri, flag, id, heldAfter)
    }

    /** Retain an already established source under the caller's atomic picker
     * result/record-reconciliation section. This creates no OS permission and
     * does not acquire release ownership. */
    fun retain(uri: SafUriRef, flag: SafAccessFlag): Lease = synchronized(lock) {
        val key = Key(uri, flag)
        check(key !in releasing) { "grantReleaseInProgress" }
        check(referenceCount < referenceLimit && nextID < Long.MAX_VALUE) { "grantReferenceLimit" }
        val id = ++nextID
        entries.getOrPut(key) { Entry() }.references += id; referenceCount++
        Lease(this, uri, flag, id, false)
    }

    private fun drop(lease: Lease): Release = synchronized(lock) {
        val key = Key(lease.uri, lease.flag)
        val entry = entries[key] ?: return@synchronized Release.ALREADY_CLOSED
        if (!entry.references.remove(lease.id)) return@synchronized Release.ALREADY_CLOSED
        referenceCount--
        if (entry.references.isNotEmpty()) return@synchronized Release.RETAINED
        entries.remove(key)
        val release = entry.ownedRelease ?: return@synchronized Release.PREEXISTING_PRESERVED
        // No repeated automatic retry after a provider failure: OS truth may
        // subsequently belong to another explicit authorization. A caller
        // receives FAILED and can offer an explicit system-grant action.
        releasing += key
        try { if (release()) Release.RELEASED else Release.FAILED }
        catch (_: RuntimeException) { Release.FAILED }
        finally { releasing -= key }
    }

    override fun executeReleaseUnderExclusiveAuthority(
        uri: SafUriRef, flag: SafAccessFlag, release: () -> Boolean,
    ): BrokeredRelease = synchronized(lock) {
        val key = Key(uri, flag)
        if (entries[key]?.references?.isNotEmpty() == true || key in releasing) {
            return@synchronized BrokeredRelease.Retained("inUse")
        }
        releasing += key
        try { BrokeredRelease.Executed(release()) }
        catch (_: RuntimeException) { BrokeredRelease.Executed(false) }
        finally { releasing -= key }
    }
}
