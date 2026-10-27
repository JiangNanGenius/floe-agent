// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import java.io.IOException
import java.security.MessageDigest

/**
 * Read side of ONE pinned, kernel-owned read-only file descriptor.
 *
 * The print adapter implements this over `ParcelFileDescriptor.dup()` +
 * `android.system.Os.lseek/read` of its OWNED descriptor — there is NO path
 * re-open anywhere in this contract, which is exactly the point
 * (Main repair 2026-10-27): a descriptor-based reader keeps reading the
 * inode it pinned even after somebody replaces the path, so the pinned
 * identity cannot be swapped between writes. The interface is pure-JVM so
 * the real copier below is unit-testable with descriptor-shaped fakes.
 */
interface OfficePdfPinnedRead {
    /** `lseek` the pinned descriptor back to offset 0. False on failure (descriptor lost/closed). */
    fun seekToStart(): Boolean

    /**
     * Reads up to [len] bytes into [buf] at [off]; returns the byte count,
     * `-1` at EOF (mirrors POSIX `read`). May throw [IOException] for a real
     * descriptor error — the copier converts that into [CopiedOutcome.DescriptorLost].
     */
    @Throws(IOException::class)
    fun read(buf: ByteArray, off: Int, len: Int): Int
}

/** Write side of the framework-provided print destination (stream + flush; throws on failure). */
interface OfficePdfPinnedWrite {
    @Throws(IOException::class)
    fun write(buf: ByteArray, off: Int, len: Int)

    /** Flush (NOT close) the destination; closing the destination stream stays with the adapter. */
    @Throws(IOException::class)
    fun finish()
}

/**
 * Pure verification core used by [OfficePdfPrintAdapter] for EVERY
 * `onWrite`/`onLayout` source identity.
 *
 * Rules this encodes (the concrete gaps Main found in the delivered slice):
 *  - one [OfficePdfPinnedRead] over the SAME owned descriptor serves every
 *    pass; each pass re-seeks to offset 0, so repeated `onWrite` calls can
 *    never continue each other's offsets or read through a fresh path open;
 *  - the destination receives ONLY a bounded, counted copy: the loop reads
 *    exactly [expectedBytes] (64 KiB chunks), then PROBES ONE more byte —
 *    a readable byte means the inode grew (append) and fails the identity;
 *    EOF before the expected count means truncation and fails it;
 *  - SHA-256 is digested over the EXACT bytes written to the destination and
 *    compared to the frozen identity BEFORE any success is reported, so a
 *    same-length in-place rewrite of the pinned inode can never be printed
 *    under the old verified identity ("native void/copy-length alone is
 *    never verified success");
 *  - cancellation is checked between chunks and before the probe/flush, and
 *    resolves through the adapter's exactly-one-terminal gate with the
 *    CORRECT terminal (see [terminalFor]);
 *  - memory stays bounded regardless of file size (the module shape guard
 *    already caps the source at 256 MiB; nothing here reads more than
 *    expectedBytes + 1 probe byte per pass).
 */
object OfficePdfPinnedSourceCopier {

    /** Copy chunk bound. */
    const val CHUNK_BYTES: Int = 64 * 1024

    /** Guard against a stuck zero-read (regular-file POSIX read never returns 0 for len > 0). */
    const val MAX_ZERO_READS: Int = 1024

    /** What one verified copy pass produced. `Verified` is the ONLY success identity. */
    sealed class CopiedOutcome {
        /** Exact count copied, destination flushed, whole-stream SHA equals the frozen identity and EOF is clean. */
        data class Verified(val bytesCopied: Long, val sha256Hex: String) : CopiedOutcome()

        /** The request's cancellation signal stopped the pass (adapter must settle CANCELLED, never FAILED). */
        object Cancelled : CopiedOutcome()

        /** EOF hit before the expected byte count (truncated/replaced inode). */
        data class Truncated(val bytesCopied: Long) : CopiedOutcome()

        /** The pinned inode grew beyond the verified length — a byte is readable after the expected EOF. */
        object GrewPastVerifiedBytes : CopiedOutcome()

        /** Full length copied but SHA differs: same-length in-place tamper under the pinned identity. */
        data class DigestMismatch(val bytesCopied: Long, val computedSha256Hex: String) : CopiedOutcome()

        /** The pinned descriptor could not be seeked/read (lost, closed underneath, or EIO). */
        object DescriptorLost : CopiedOutcome()

        /** The destination stream rejected a write or the flush. */
        object DestinationWriteFailed : CopiedOutcome()
    }

    /** Which terminal method a settled print callback must invoke — exactly one of these three, ever. */
    enum class PrintTerminalKind { FINISH, CANCEL, FAIL }

    /** Pure mapping used by the REAL adapter settle code, so the cancel-vs-fail rule is unit-tested, not grepped. */
    fun terminalFor(outcome: CopiedOutcome): PrintTerminalKind = when (outcome) {
        is CopiedOutcome.Verified -> PrintTerminalKind.FINISH
        is CopiedOutcome.Cancelled -> PrintTerminalKind.CANCEL
        else -> PrintTerminalKind.FAIL
    }

    /** True when the failure is about the SOURCE identity (gone/changed), false for destination write faults. */
    fun isSourceIdentityFailure(outcome: CopiedOutcome): Boolean = when (outcome) {
        is CopiedOutcome.DestinationWriteFailed -> false
        else -> true
    }

    /**
     * Runs one bounded, digest-verified copy pass. NEVER throws: every
     * descriptor/stream fault maps to an honest outcome, and the caller
     * settles it through its exactly-one-terminal gate.
     */
    fun copyVerify(
        read: OfficePdfPinnedRead,
        write: OfficePdfPinnedWrite,
        expectedBytes: Long,
        expectedSha256Hex: String,
        isCancelled: () -> Boolean,
    ): CopiedOutcome {
        if (expectedBytes < 1L || expectedBytes > OfficePdfVerifiedSourceContract.MAX_SOURCE_BYTES) {
            return CopiedOutcome.Truncated(0L)
        }
        if (!read.seekToStart()) return CopiedOutcome.DescriptorLost
        val digest = try {
            MessageDigest.getInstance("SHA-256")
        } catch (e: Exception) {
            return CopiedOutcome.DescriptorLost
        }
        val buffer = ByteArray(minOf(CHUNK_BYTES, expectedBytes.toInt()))
        var copied = 0L
        var zeroReads = 0
        try {
            while (copied < expectedBytes) {
                if (isCancelled()) return CopiedOutcome.Cancelled
                val want = minOf(buffer.size.toLong(), expectedBytes - copied).toInt()
                var filled = 0
                var eof = false
                while (filled < want) {
                    val r = read.read(buffer, filled, want - filled)
                    if (r < 0) {
                        eof = true
                        break
                    }
                    if (r == 0) {
                        // A POSIX read never returns 0 for len>0 on a regular
                        // file; a stuck zero must not spin a print worker.
                        if (++zeroReads > MAX_ZERO_READS) return CopiedOutcome.DescriptorLost
                        continue
                    }
                    zeroReads = 0
                    filled += r
                }
                if (filled > 0) {
                    digest.update(buffer, 0, filled)
                    write.write(buffer, 0, filled)
                    copied += filled.toLong()
                }
                if (eof) {
                    return if (isCancelled()) CopiedOutcome.Cancelled else CopiedOutcome.Truncated(copied)
                }
            }
            if (isCancelled()) return CopiedOutcome.Cancelled
            // EOF probe: the verified identity ENDS at expectedBytes. One
            // readable extra byte means the inode grew (append/grow under
            // the pinned descriptor) — never print under the old identity.
            val extra = read.read(buffer, 0, 1)
            if (extra > 0) return CopiedOutcome.GrewPastVerifiedBytes
            write.finish()
        } catch (e: IOException) {
            // Distinguish destination faults from descriptor faults honestly
            // by the wrapper each side of the REAL adapter throws
            // ([DestinationWriteFault] / [DescriptorReadFault]); an untagged
            // IOException can only come from the read side.
            return if (e is DestinationWriteFault) {
                CopiedOutcome.DestinationWriteFailed
            } else if (e is DescriptorReadFault) {
                CopiedOutcome.DescriptorLost
            } else {
                CopiedOutcome.DescriptorLost
            }
        } catch (e: RuntimeException) {
            return CopiedOutcome.DescriptorLost
        }
        val computed = toHex(digest.digest())
        return if (computed.equals(expectedSha256Hex, ignoreCase = false)) {
            CopiedOutcome.Verified(copied, computed)
        } else {
            CopiedOutcome.DigestMismatch(copied, computed)
        }
    }

    /**
     * Adapter-side destination wrapper tag: the REAL print adapter throws
     * [DestinationWriteFault] from its write/finish implementation so the
     * copier can honestly report [CopiedOutcome.DestinationWriteFailed]
     * instead of blaming the source.
     */
    class DestinationWriteFault(message: String, cause: Throwable? = null) : IOException(message, cause)

    /** Adapter-side source wrapper tag: descriptor read faults map to [CopiedOutcome.DescriptorLost]. */
    class DescriptorReadFault(message: String, cause: Throwable? = null) : IOException(message, cause)

    /** `%PDF-` magic check on the first five bytes of the pinned descriptor (pure). */
    fun headMagicOk(first5: ByteArray): Boolean {
        if (first5.size < 5) return false
        return first5[0] == '%'.code.toByte() && first5[1] == 'P'.code.toByte() &&
            first5[2] == 'D'.code.toByte() && first5[3] == 'F'.code.toByte() &&
            first5[4] == '-'.code.toByte()
    }

    /** Whole-byte-array SHA-256, 64 lowercase hex (used to digest fixtures + by owner verifiers). */
    fun sha256Hex(bytes: ByteArray): String = toHex(MessageDigest.getInstance("SHA-256").digest(bytes))

    private fun toHex(digest: ByteArray): String {
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) {
            val v = b.toInt() and 0xFF
            sb.append(Character.forDigit(v ushr 4, 16))
            sb.append(Character.forDigit(v and 0x0F, 16))
        }
        return sb.toString()
    }
}
