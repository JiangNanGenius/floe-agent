// SPDX-License-Identifier: MPL-2.0
//
// Coherent async operation/session gate for the C05 remote surface.
//
// The App controller launches connect/save/VNC/close work in App scope. A
// result that returns after the Root retired, the screen switched, or a newer
// request replaced this one must not write its state. Every operation carries
// a monotonic token plus the native epoch it started in; pollers additionally
// carry the live session identity. `cancelAll` is the one place root-stop uses
// to fence every outstanding callback.

package com.floe.android.host.remote

internal class C05RequestGate(
    private val currentEpoch: () -> Long?,
) {
    data class Token(val sequence: Long, val epoch: Long)

    private val lock = Any()
    private var sshRequestSequence = 0L
    private var vncRequestSequence = 0L
    private var loadSequence = 0L
    private var sshSessionSequence = 0L
    private var vncSessionSequence = 0L
    private var liveSSHSession: String? = null
    private var liveVNCSession: String? = null

    fun beginSSHRequest(): Token? = begin { sshRequestSequence += 1; sshRequestSequence }

    fun beginVNCRequest(): Token? = begin { vncRequestSequence += 1; vncRequestSequence }

    fun beginLoad(): Token? = begin { loadSequence += 1; loadSequence }

    fun isLiveSSH(token: Token): Boolean = isLive(token) { sshRequestSequence == token.sequence }

    fun isLiveVNC(token: Token): Boolean = isLive(token) { vncRequestSequence == token.sequence }

    fun isLiveLoad(token: Token): Boolean = isLive(token) { loadSequence == token.sequence }

    fun beginSSHSession(sessionID: String): Long = synchronized(lock) {
        sshSessionSequence += 1
        liveSSHSession = sessionID
        sshSessionSequence
    }

    fun beginVNCSession(sessionID: String): Long = synchronized(lock) {
        vncSessionSequence += 1
        liveVNCSession = sessionID
        vncSessionSequence
    }

    fun isLiveSSHSession(sessionID: String, sequence: Long, epoch: Long): Boolean {
        val current = currentEpoch()
        return synchronized(lock) {
            current == epoch &&
                liveSSHSession == sessionID &&
                sshSessionSequence == sequence
        }
    }

    fun isLiveVNCSession(sessionID: String, sequence: Long, epoch: Long): Boolean {
        val current = currentEpoch()
        return synchronized(lock) {
            current == epoch &&
                liveVNCSession == sessionID &&
                vncSessionSequence == sequence
        }
    }

    fun currentSSHSession(): String? = synchronized(lock) { liveSSHSession }

    fun currentVNCSession(): String? = synchronized(lock) { liveVNCSession }

    fun currentVNCSessionToken(): Long = synchronized(lock) {
        if (liveVNCSession == null) 0L else vncSessionSequence
    }

    fun finishSSHSession(sessionID: String) {
        synchronized(lock) {
            if (liveSSHSession == sessionID) {
                liveSSHSession = null
                sshSessionSequence += 1
            }
        }
    }

    fun finishVNCSession(sessionID: String) {
        synchronized(lock) {
            if (liveVNCSession == sessionID) {
                liveVNCSession = null
                vncSessionSequence += 1
            }
        }
    }

    fun cancelAll() {
        synchronized(lock) {
            sshRequestSequence += 1
            vncRequestSequence += 1
            loadSequence += 1
            sshSessionSequence += 1
            vncSessionSequence += 1
            liveSSHSession = null
            liveVNCSession = null
        }
    }

    private inline fun begin(sequence: () -> Long): Token? {
        val epoch = currentEpoch()?.takeIf { it > 0 } ?: return null
        val value = synchronized(lock) { sequence() }
        return Token(value, epoch)
    }

    private inline fun isLive(token: Token, sequenceMatches: () -> Boolean): Boolean {
        val current = currentEpoch()
        return synchronized(lock) {
            current == token.epoch && sequenceMatches()
        }
    }
}
