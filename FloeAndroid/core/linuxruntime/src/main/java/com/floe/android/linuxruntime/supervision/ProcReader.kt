// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import java.io.File

/**
 * Result of listing process ids. A failed listing is a distinct state: an
 * incomplete inventory can never be read as "no processes", because an empty
 * list would otherwise let the supervisor claim quiescence it did not observe.
 */
sealed class ProcListOutcome {
    data class Available(val pids: List<Int>) : ProcListOutcome()
    data class Failed(val reason: String) : ProcListOutcome()
}

/**
 * Read seam over `/proc`. Only top-level process directories are listed, so a
 * thread never appears as an independent process; the census still re-checks
 * `Tgid` because a device-side reader may be swapped by Main.
 */
interface ProcReader {
    fun procPids(): ProcListOutcome
    fun statusLines(pid: Int): List<String>?
    fun statFields(pid: Int): String?
    /** Positive foreign owners help classify unreadable entries; root/unknown is never proof. */
    fun directoryOwnerUid(pid: Int): Int? = null
}

/** Production reader: plain `/proc` reads of this (runtime) UID's own processes. */
object LinuxProcReader : ProcReader {

    private val procRoot = File("/proc")
    override fun directoryOwnerUid(pid: Int): Int? = try {
        android.system.Os.stat(File(procRoot, pid.toString()).path).st_uid
    } catch (_: Exception) { null }

    override fun procPids(): ProcListOutcome {
        val names = try {
            procRoot.list() ?: return ProcListOutcome.Failed("proc-listing-null")
        } catch (e: Exception) {
            return ProcListOutcome.Failed("proc-listing-${e.javaClass.simpleName}")
        }
        val pids = ArrayList<Int>(names.size)
        for (name in names) {
            if (name.isEmpty() || name[0] < '0' || name[0] > '9') continue
            name.toIntOrNull()?.let { if (it > 0) pids += it }
        }
        // A numeric-prefixed directory that will not parse is a reader/parser
        // disagreement, not an absence of processes: fail closed.
        if (pids.isEmpty() && names.any { it.isNotEmpty() && it[0] in '0'..'9' }) {
            return ProcListOutcome.Failed("proc-listing-unparsable")
        }
        return ProcListOutcome.Available(pids)
    }

    override fun statusLines(pid: Int): List<String>? = try {
        val file = File(procRoot, "$pid/status")
        if (!file.isFile) null else file.readLines()
    } catch (_: Exception) {
        null
    }

    override fun statFields(pid: Int): String? = try {
        val file = File(procRoot, "$pid/stat")
        if (!file.isFile) null else file.readText()
    } catch (_: Exception) {
        null
    }
}

/** Parsed `/proc/<pid>/status` facts the census depends on. */
data class ParsedStatus(
    val tgid: Int,
    val ppid: Int,
    val uidReal: Int,
    val state: Char,
    val name: String,
)

/** Parsed `/proc/<pid>/stat` facts (after the parenthesised comm field). */
data class ParsedStat(
    val state: Char,
    val ppid: Int,
    val processGroupId: Int,
    val sessionId: Int,
    val startTimeTicks: Long,
)

/**
 * Pure `/proc` parsers. They are deliberately separate from the reader so the
 * census logic can be checked with hand-written fixtures, including the
 * awkward-but-real comm values (`"(weird) name"`).
 */
object ProcParsing {

    fun parseStatus(lines: List<String>): ParsedStatus? {
        var tgid = -1
        var ppid = -1
        var uid = -1
        var state = '?'
        var name = ""
        for (line in lines) {
            val key = line.substringBefore(':', "").trim()
            val value = line.substringAfter(':', "").trim()
            when (key) {
                "Name" -> name = value.substringBeforeLast(" (").trim()
                "State" -> if (value.isNotEmpty()) state = value[0]
                "Tgid" -> tgid = value.toIntOrNull() ?: -1
                "PPid" -> ppid = value.toIntOrNull() ?: -1
                // Uid: real effective saved fs — the FIRST field is the real UID.
                "Uid" -> uid = value.whitespaceTokens().getOrNull(0)?.toIntOrNull() ?: -1
            }
        }
        return if (tgid > 0 && ppid >= 0 && uid >= 0) ParsedStatus(tgid, ppid, uid, state, name) else null
    }

    /**
     * `/proc/<pid>/stat` is `pid (comm) state ppid pgrp session ...`, where comm
     * may itself contain spaces and parentheses, so fields are taken after the
     * LAST ')'. starttime is the 22nd overall field, i.e. index 19 after comm.
     */
    fun parseStat(line: String): ParsedStat? {
        val close = line.lastIndexOf(')')
        if (close < 0 || close + 2 > line.length) return null
        val tail = line.substring(close + 2).trim()
        val fields = tail.whitespaceTokens()
        if (fields.size < 20) return null
        val state = fields[0].firstOrNull() ?: return null
        val ppid = fields[1].toIntOrNull() ?: return null
        val pgid = fields[2].toIntOrNull() ?: return null
        val sid = fields[3].toIntOrNull() ?: return null
        val start = fields[19].toLongOrNull() ?: return null
        return ParsedStat(state, ppid, pgid, sid, start)
    }

    private fun String.whitespaceTokens(): List<String> =
        split(' ', '\t', '\n', '\r').filter { it.isNotEmpty() }
}
