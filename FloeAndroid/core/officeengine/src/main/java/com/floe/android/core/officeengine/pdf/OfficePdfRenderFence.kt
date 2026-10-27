// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import java.util.concurrent.atomic.AtomicLong

/**
 * Monotonic late-callback fence for one PDF surface (preview screen, or the
 * print-prep of one viewer session). Every NEW verification/zoom cycle
 * [bump]s the generation; a callback carries the generation it started with
 * and is applied ONLY while [isCurrent] still holds — the exact rule that
 * makes "stale/foreign/late/duplicate receipt cannot open another session"
 * and "a slow render for a page you already left never paints" testable
 * without any Android types.
 */
class OfficePdfRenderFence {

    private val generation = AtomicLong(0L)

    /** Starts a new cycle and returns its token (callbacks capture this). */
    fun bump(): Long = generation.incrementAndGet()

    /** Token of the CURRENT cycle without starting one. */
    fun current(): Long = generation.get()

    /** True only for the newest cycle; superseded/late/foreign results fail. */
    fun isCurrent(token: Long): Boolean = token != 0L && generation.get() == token
}
