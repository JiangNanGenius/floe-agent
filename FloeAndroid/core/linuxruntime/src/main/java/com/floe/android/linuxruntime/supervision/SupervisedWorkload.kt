// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import com.floe.android.linuxruntime.ExitResult
import com.floe.android.linuxruntime.StdinDelivery

/**
 * The common, proof-bearing surface of ONE owned Linux workload.
 *
 * Implemented by the original [SupervisedPtyJob] (interactive/one-shot PTY)
 * and by [SupervisedPipeJob] (C01 managed-service stdio: three separate
 * pipes). The supervisor's admission table, the runtime operations map and
 * the lease settlement path all speak this interface only, so a pipe service
 * has exactly the same authority/lease/quiescence lifecycle as a PTY job while
 * its stream semantics stay honest (stdout and stderr are never merged).
 *
 * The methods are the SAME contracts as the PTY job's:
 * * [pump] is called by the single drain owner and ends with a real terminal
 *   only after whole-UID (scoped) quiescence.
 * * [requestCancel] is a real transport stop; a stop request is never a
 *   proven terminal.
 * * [settleLease] answers the lease authority and never fabricates a release.
 */
interface SupervisedWorkload {
    val lease: LeaseToken
    val rootBirth: ProcessBirth
    val pid: Int
    val stateNow: JobState
    val exitResult: ExitResult?

    fun requestCancel(reason: String): CancelOutcome
    fun pump(): PumpOutcome
    fun settleLease(): LeaseSettlement

    /** Bounded retained OUTPUT page (stdout for a stdio workload). */
    fun output(cursor: Long, maxBytes: Int): OutputPage

    val stdinDelivery: StdinDelivery
    val maxStdinChunkBytes: Int
    fun stdinStatus(): StdinStatus

    fun writeStdin(data: ByteArray, offset: Int = 0, length: Int = data.size): StdinWrite
    fun requestStdinEof(): StdinEof

    /** No-op false for a no-PTY workload (there is no terminal size). */
    fun resize(rows: Int, cols: Int): Boolean
}
