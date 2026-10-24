// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser.internal

import com.floe.android.feature.browser.api.BrowserPreviewAuthority
import com.floe.android.feature.browser.api.PreviewAdjudication
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.io.OutputStream
import java.util.UUID

/**
 * Pure loopback request/response pump for one preview connection. Everything
 * authoritative (token, path, resource identity, MIME, range, Host, size)
 * comes back from [BrowserPreviewAuthority] — the Swift `LocalPreviewServer`
 * behind Main's JNI. This class only:
 *  - accumulates the header block with the 64 KiB ceiling and the
 *    `\r\n\r\n` terminator rule (EOF before the terminator answers 400, an
 *    oversized block answers 431 — the iOS original's rules, mirrored),
 *  - serializes the adjudicated verdict onto the wire and streams ONLY the
 *    admitted bytes through bounded chunked pulls,
 *  - never parses the path for trust, never touches disk, never holds an
 *    unbounded buffer, and never decides a permission.
 *
 * The 408/431/400 answers for MALFORMED or stalled requests are
 * transport-local (no resource is named or read); every request that reaches
 * a path decision goes to the authority. Streams are injected so the whole
 * pump is unit-testable on the JVM.
 */
public class PreviewConnectionPump(
    private val authority: BrowserPreviewAuthority,
    private val serverId: String,
    private val maximumHeaderBytes: Int = DEFAULT_MAXIMUM_HEADER_BYTES,
    private val chunkCapacity: Int = DEFAULT_CHUNK_CAPACITY,
    private val newRequestId: () -> String = { UUID.randomUUID().toString() },
) {
    public companion object {
        public const val DEFAULT_MAXIMUM_HEADER_BYTES: Int = 64 * 1024
        public const val DEFAULT_CHUNK_CAPACITY: Int = 64 * 1024

        /** Sentinel when the accumulated header block crosses the ceiling. */
        public val OVER_LIMIT: ByteArray = ByteArray(1)

        public data class HeaderRead(
            val block: ByteArray?,
            val terminated: Boolean,
            /** True when the peer sent at least one byte before the block
             * ended/stalled (distinguishes a stalled 408 from a clean 400). */
            val sawAnyBytes: Boolean,
        )

        /** Read one bounded header block, byte-accurate to the iOS original:
         * parse only after the terminator actually arrived; a stalled or
         * oversized block is answered, never parsed as if complete.
         * `onSocketTimeout` distinguishes the 5s header deadline (408) from
         * an ordinary EOF (400): a null return with terminated=false means
         * "no complete request" and the CALLER answers honestly. */
        public fun readHeaderBlock(input: InputStream, maximumBytes: Int): HeaderRead {
            val buffer = ByteArrayOutputStream(2048)
            val terminator = byteArrayOf('\r'.code.toByte(), '\n'.code.toByte(), '\r'.code.toByte(), '\n'.code.toByte())
            var match = 0
            while (true) {
                val b = try {
                    input.read()
                } catch (_: IOException) {
                    return HeaderRead(block = null, terminated = false, sawAnyBytes = buffer.size() > 0)
                } catch (_: InterruptedIOException) {
                    return HeaderRead(block = null, terminated = false, sawAnyBytes = buffer.size() > 0)
                }
                if (b == -1) {
                    // EOF before the full terminator: never parse partial bytes.
                    return HeaderRead(block = null, terminated = false, sawAnyBytes = buffer.size() > 0)
                }
                buffer.write(b)
                match = when {
                    b.toByte() == terminator[match] -> match + 1
                    match > 0 && b.toByte() == terminator[0] -> 1
                    else -> 0
                }
                if (match == terminator.size) {
                    return HeaderRead(block = buffer.toByteArray(), terminated = true, sawAnyBytes = true)
                }
                if (buffer.size() > maximumBytes) {
                    return HeaderRead(block = OVER_LIMIT, terminated = false, sawAnyBytes = true)
                }
            }
        }

        /** Serialize the status line + headers only; the body follows as
         * already-admitted bytes. */
        public fun serializeHead(verdict: PreviewAdjudication, out: OutputStream) {
            val head = StringBuilder()
            head.append("HTTP/1.1 ").append(verdict.statusLine).append("\r\n")
            for ((name, value) in verdict.headers) {
                head.append(name).append(": ").append(value).append("\r\n")
            }
            head.append("\r\n")
            out.write(head.toString().toByteArray(Charsets.US_ASCII))
        }

        public fun localError(statusLine: String, out: OutputStream) {
            serializeHead(
                PreviewAdjudication(
                    statusLine = statusLine,
                    headers = listOf(
                        "Content-Type" to "text/plain; charset=utf-8",
                        "Content-Length" to "0",
                        "Cache-Control" to "no-store",
                        "X-Content-Type-Options" to "nosniff",
                        "Connection" to "close",
                    ),
                    bodyLength = 0,
                    bodyStart = 0,
                    chunk = ByteArray(0),
                ),
                out,
            )
            runCatching { out.flush() }
        }
    }

    /** Process exactly one request on one connection, then end the
     * connection (every verdict carries Connection: close). Never throws for
     * protocol reasons; IO failures simply end the connection. */
    public fun handle(input: InputStream, output: OutputStream) {
        val read = readHeaderBlock(input, maximumHeaderBytes)
        if (read.block === OVER_LIMIT) {
            localError("431 Request Header Fields Too Large", output)
            return
        }
        if (read.block == null || !read.terminated) {
            // EOF/timeout before a complete header block. The transport sets
            // a 5s soTimeout, so this branch is the original's 408/400 pair:
            // a stalled peer gets 408 when bytes HAD begun, 400 otherwise.
            localError(if (read.sawAnyBytes) "408 Request Timeout" else "400 Bad Request", output)
            return
        }
        val requestId = newRequestId()
        val verdict = try {
            authority.adjudicate(serverId, requestId, read.block)
        } catch (_: Exception) {
            // The authority (Swift) is unreachable or timed out mid-call. A
            // transport-local 503 never names a resource and never grants
            // anything: honest unavailability.
            localError("503 Service Unavailable", output)
            return
        }
        try {
            serializeHead(verdict, output)
            var written = 0
            if (verdict.chunk.isNotEmpty()) {
                output.write(verdict.chunk)
                written = verdict.chunk.size
            }
            while (written < verdict.bodyLength) {
                val next = authority.readChunk(serverId, requestId, written, chunkCapacity)
                if (next.isEmpty()) break // retired/failed: stop honestly
                output.write(next)
                written += next.size
            }
            output.flush()
        } catch (_: IOException) {
            // peer gone
        } catch (_: InterruptedIOException) {
        } catch (_: Exception) {
            // A chunk pull blew past the bridge: the connection ends without
            // inventing a body. The Swift side already retired the request.
        }
    }

}
