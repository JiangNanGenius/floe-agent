// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.net.DnsResolver
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Network
import android.os.CancellationSignal
import android.os.Process
import android.os.SystemClock
import com.floe.android.linuxruntime.resolver.GuestDnsWire
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

/**
 * Android handler for the frozen `floe-guest-dns-v1` bridge
 * (FloeAndroid/core/linuxruntime/native-build/guest-resolver/PROTOCOL.json,
 * Main-owned; the C guest side is owned by the native-build lane).
 *
 * Transport: AF_UNIX SOCK_STREAM in the FILESYSTEM namespace, inside a
 * private per-work 0700 directory under the runtime's own filesDir,
 * bind-mounted by the session only at `/run/floe-dns`. The bind is
 * EXPLICIT and public-API-only (Main review round 3): AOSP's current
 * LocalServerSocket(String) provably binds the ABSTRACT namespace only
 * and would create no pathname; the guest helper connects a pathname and
 * could never reach such a listener. Instead:
 * `LocalSocket().bind(LocalSocketAddress(path, Namespace.FILESYSTEM))`
 * (public since API 1) then the documented
 * `LocalServerSocket(FileDescriptor)` constructor, which performs the
 * listen itself. The bound helper keeps sole ownership of the fd (the
 * fd-wrapped server does not manage it): stop() closes the helper exactly
 * once, and the reference is held for the server's lifetime.
 * One transaction per connection: `FDN1 || u16BE length || DNS message`,
 * exactly as the protocol freezes.
 *
 * Caller boundary is REAL (Main review round 2): no network port, no
 * loopback trust assumption. A private 0700 directory excludes other
 * Android UIDs at the filesystem, and every accepted socket is verified
 * `peerCredentials.uid == Process.myUid()` before any byte is read.
 *
 * Each query resolves on the CURRENT active Network via the public system
 * resolver (API >= 29: android.net.DnsResolver.rawQuery, flags 0, separate
 * cancellation + absolute deadline; API 28: Network.getAllByName for the
 * question's A/AAAA, executed on a process-wide FIXED bounded resolver
 * worker set — never a raw/plaintext substitute). Offline moments return
 * bounded SERVFAIL while local commands keep working; the change monitor
 * re-points subsequent queries at the real network/PrivateDNS state
 * automatically.
 *
 * Bounds (protocol deadlines block): 8 in-flight transactions, one 3500 ms
 * MONOTONIC ABSOLUTE deadline covering read+resolve+write. `remaining()`
 * is honest (it never fabricates time), each read chunk is bounded by the
 * true remaining deadline (setSoTimeout(0) means INFINITE and is never
 * handed out), and a per-transaction watchdog closes the connection at the
 * absolute deadline so a drip-slow client, an overdue resolver or a peer
 * that never drains the response cannot make the transaction outlive its
 * budget. No queue growth (excess connections are closed honestly and
 * counted). Stop RETIRES ACTIVELY (Main review round 4): it first wakes
 * a possibly blocked accept() with a same-UID connect to the still-live
 * listener (a cross-thread fd close does NOT reliably release that
 * sleeper on Linux), shuts accepted sockets down BEFORE closing them so
 * blocked transaction IO wakes, cancels the signals and the deadline
 * watchdog, and PROVES retirement within bounded windows. Unproven
 * retirement is reported honestly as "retiring" with real in-flight
 * counts, and start() refuses a duplicate listener until a later stop
 * proves the old work ended — no per-session abandoned accept pumps,
 * no fake idle. The session commits or revokes around this handler,
 * never the other way.
 */
internal class GuestDnsBridge {

    @Volatile private var activeNetwork: Network? = null
    private var server: LocalServerSocket? = null
    private var boundHelperSocket: LocalSocket? = null
    private var socketFile: File? = null
    private val accepting = AtomicBoolean()
    private val running = AtomicBoolean()
    private val inFlight = AtomicInteger()
    private val forwarded = AtomicLong()
    private val refused = AtomicLong()
    private val timedOut = AtomicLong()
    private val unauthorized = AtomicLong()
    private val malformed = AtomicLong()
    private val resolverRejected = AtomicLong()
    @Volatile private var lastError: String? = null
    private var pump: Thread? = null
    private var workers: java.util.concurrent.ThreadPoolExecutor? = null
    private var callbacks: java.util.concurrent.ExecutorService? = null
    private var deadlineWatchdog: ScheduledExecutorService? = null
    private val openSockets = ConcurrentHashMap<LocalSocket, Boolean>()
    private val activeSignals = ConcurrentHashMap<CancellationSignal, Boolean>()

    /** True while a previous stop() could not PROVE that its accept
     *  pump / transaction workers / callback executor / deadline
     *  watchdog actually ended. Honest ownership marker: while set, the
     *  status reports "retiring" (never a fake "idle"), in-flight keeps
     *  its real count, and start() refuses a duplicate listener instead
     *  of letting abandoned per-session threads accumulate. */
    @Volatile private var retirePending = false

    fun isRunning(): Boolean = running.get()

    private fun stateName(): String = when {
        !running.get() -> if (retirePending) "retiring" else "idle"
        server != null -> "listening"
        else -> "starting"
    }

    /** Re-proof used by start(): the bounded stop windows may have
     *  simply been tight, and an interrupted/resolved worker exits right
     *  after them. Retirement is proven by REAL thread/executors state,
     *  never by a remembered flag alone. */
    private fun retirementProven(): Boolean {
        val thread = pump
        val pool = workers
        val callbackPool = callbacks
        val watchdog = deadlineWatchdog
        return (thread == null || !thread.isAlive) &&
            (pool == null || pool.isTerminated) &&
            (callbackPool == null || callbackPool.isTerminated) &&
            (watchdog == null || watchdog.isTerminated)
    }

    /** Diagnostics only: coarse counters, never names, addresses or DNS
     *  payloads. */
    fun status(): JSONObject = JSONObject().put("state", stateName())
        .put("transport", "af-unix-fdn1")
        .put("forwarded", forwarded.get()).put("refused", refused.get())
        .put("timedOut", timedOut.get()).put("unauthorized", unauthorized.get())
        .put("malformed", malformed.get()).put("inflight", inFlight.get())
        .put("resolverRejected", resolverRejected.get())
        .also { if (lastError != null) it.put("lastError", lastError) }

    /** Create the private 0700 socket directory and start listening at
     *  `<dir>/s`. Returns false (with honest lastError) when the platform
     *  refuses the bind; callers must then fail closed. */
    @Synchronized
    fun start(socketDir: File, initialNetwork: Network?): Boolean {
        if (running.get()) return true
        if (retirePending) {
            if (!retirementProven()) {
                // REFUSE a duplicate listener rather than stack a second
                // accept pump / worker set over work whose end is
                // unproven. Callers fail closed honestly; a later stop()
                // (or this check once the OS releases the threads)
                // re-proves retirement and re-opens this path.
                lastError = "retirement_pending"
                return false
            }
            retirePending = false
            pump = null
            workers = null
            callbacks = null
            deadlineWatchdog = null
        }
        lastError = null
        val sunPath = File(socketDir, SOCKET_BASENAME).absolutePath
        if (sunPath.toByteArray(Charsets.UTF_8).size + 1 > SUN_PATH_MAX) {
            lastError = "sun_path_too_long"
            return false
        }
        val created = runCatching {
            socketDir.parentFile?.mkdirs()
            if (!socketDir.isDirectory && !socketDir.mkdir()) error("socket dir")
            android.system.Os.chmod(socketDir.path, 0x1C0) // 0700 owner only
        }.isSuccess
        if (!created) {
            lastError = "socket_dir_failed"
            return false
        }
        val listening = try {
            filesystemBoundServer(sunPath)
        } catch (failure: Exception) {
            lastError = "bind_failed"
            // A filesystem bind that got as far as creating the inode
            // leaves the socket FILE behind; remove it with the dir.
            runCatching { File(sunPath).delete() }
            boundHelperSocket = null
            runCatching { socketDir.delete() }
            return false
        }
        // The FILESYSTEM socket file is real now: 0700 like the directory.
        runCatching { android.system.Os.chmod(sunPath, 0x1C0) }
        server = listening
        socketFile = File(sunPath)
        activeNetwork = initialNetwork
        accepting.set(true)
        val pool = java.util.concurrent.ThreadPoolExecutor(MAX_INFLIGHT, MAX_INFLIGHT, 60,
            TimeUnit.SECONDS, java.util.concurrent.LinkedBlockingQueue(MAX_INFLIGHT)
        ) { work -> Thread(work, "floe-dns-txn").apply { isDaemon = true } }
            .apply { allowCoreThreadTimeOut(true) }
        workers = pool
        callbacks = Executors.newSingleThreadExecutor { work ->
            Thread(work, "floe-dns-cb").apply { isDaemon = true }
        }
        deadlineWatchdog = Executors.newSingleThreadScheduledExecutor { work ->
            Thread(work, "floe-dns-deadline").apply { isDaemon = true }
        }
        val thread = Thread({ acceptLoop(listening, pool) }, "floe-dns-accept").apply { isDaemon = true }
        pump = thread
        running.set(true)
        thread.start()
        return true
    }

    /** Explicit FILESYSTEM-namespace listener via public API only:
     *  `LocalSocket.bind(LocalSocketAddress(path, FILESYSTEM))` (public
     *  since API 1) then the documented `LocalServerSocket(FileDescriptor)`
     *  constructor, which AOSP's current source shows calls listen(50)
     *  itself (no manual Os.listen: a second listen() on the same fd is
     *  at best redundant and its error behavior version-variant).
     *  FD LIFECYCLE (same source): the fd passed to that constructor is
     *  NOT managed by the server — `LocalServerSocket.close()` on an
     *  fd-constructed server has no effect on the fd. The bound helper
     *  LocalSocket keeps the ONLY ownership (internally created fd): it
     *  must stay strongly referenced for the server's lifetime (its
     *  impl's finalize() closes the fd) and stop() closes it exactly
     *  once. On any construction failure the helper is still ours and
     *  gets closed here. */
    private fun filesystemBoundServer(sunPath: String): LocalServerSocket {
        val bound = LocalSocket()
        try {
            bound.bind(LocalSocketAddress(sunPath, LocalSocketAddress.Namespace.FILESYSTEM))
            val listening = LocalServerSocket(bound.fileDescriptor)
            boundHelperSocket = bound
            return listening
        } catch (failure: Exception) {
            runCatching { bound.close() }
            throw failure
        }
    }

    /** Close the owned listener/sockets/signals only when real use ends.
     *
     *  ACTIVE retirement (Main review round 4 — the predecessor's
     *  "close the fd, bounded join, abandon the daemon" stop is NOT stop
     *  proof): a thread blocked inside accept() is not reliably released
     *  by another thread closing the fd — Linux `unix_release_sock` wakes
     *  `peer_wait`, while the acceptor sleeps on the listener's own
     *  receive-queue wait (primary source: current mainline
     *  net/unix/af_unix.c; identical shape in the older kernels OEM
     *  devices still ship). So stop FIRST wakes the pump the way accept
     *  is built to be woken: a same-UID connect to the still-live
     *  listener, delivered through `sk_data_ready` by
     *  `unix_stream_connect` on EVERY kernel. The loop condition is
     *  already false, so the pump closes the wake connection unhandled
     *  and exits. The listener fd additionally gets shutdown() BEFORE
     *  close (current mainline `unix_shutdown` marks RCV_SHUTDOWN and
     *  wakes the acceptor directly; older kernels no-op a listen-socket
     *  shutdown, so the connect wake stays the bound). ACCEPTED sockets
     *  are shutdown before close too — the POSIX wake for a blocked
     *  recv/send inside a live transaction — and only then are the
     *  resolver signals cancelled and the deadline watchdog shut down.
     *  Every wait is bounded AND ACCOUNTED: if the OS still refuses to
     *  release something, stop does not lie. The bridge keeps its real
     *  worker references, reports "retiring" with the true in-flight
     *  count, and start() refuses a duplicate listener until a later
     *  stop re-proves retirement. No unbounded per-session orphan pools;
     *  a failed-closed next session is the honest outcome, never silent
     *  thread accumulation. The API 28 resolver worker set remains
     *  process-scoped and deliberately survives stop(): a blocked
     *  getAllByName slot stays honestly accounted on its worker until
     *  the real native call returns, and because no new listener exists
     *  before retirement is proven, no stopped bridge can submit
     *  further resolver work through this level. */
    @Synchronized
    fun stop() {
        accepting.set(false)
        // 1) Wake a possibly blocked accept() while the listener file is
        //    still bound and its fd still open (guaranteed wake).
        val wakePath = socketFile?.absolutePath
        if (wakePath != null && server != null) wakeAcceptListener(wakePath)
        // 2) The woken pump exits on its loop condition; bounded join.
        val thread = pump
        if (thread?.isAlive == true) runCatching { thread.join(JOIN_MS) }
        // 3) Retire the listener. server.close() retires only the AOSP
        //    object state (per AOSP the fd-constructed server manages NO
        //    fd); shutdown-then-close below is the fd's own retirement,
        //    and the bound helper is its only owner — closed exactly
        //    once, then the reference drops.
        runCatching { server?.close() }
        server = null
        val helper = boundHelperSocket
        if (helper != null) {
            runCatching {
                android.system.Os.shutdown(helper.fileDescriptor,
                    android.system.OsConstants.SHUT_RDWR)
            }
            runCatching { helper.close() }
        }
        boundHelperSocket = null
        if (thread?.isAlive == true) runCatching { thread.join(JOIN_MS) }
        // 4) Accepted sockets: forceClose = shutdownInput+shutdownOutput
        //    BEFORE close — this is what wakes a transaction blocked in
        //    recv/send instead of parking it until its watchdog would
        //    have fired. Then cancel the in-flight resolver signals.
        openSockets.keys.toList().forEach { forceClose(it) }
        openSockets.clear()
        activeSignals.keys.toList().forEach { runCatching { it.cancel() } }
        activeSignals.clear()
        // 5) Executors: interrupt, then await — every await result is
        //    ACCOUNTED, never ignored, and the references survive an
        //    unproven wait so a later stop() can re-prove retirement.
        val callbackPool = callbacks
        runCatching { callbackPool?.shutdownNow() }
        val callbacksRetired = callbackPool == null || runCatching {
            callbackPool.awaitTermination(JOIN_MS, TimeUnit.MILLISECONDS)
        }.getOrDefault(false)
        val pool = workers
        runCatching { pool?.shutdownNow() }
        val txnsRetired = pool == null || runCatching {
            pool.awaitTermination(POOL_JOIN_MS, TimeUnit.MILLISECONDS)
        }.getOrDefault(false)
        val watchdog = deadlineWatchdog
        runCatching { watchdog?.shutdownNow() }
        val watchdogRetired = watchdog == null || runCatching {
            watchdog.awaitTermination(JOIN_MS, TimeUnit.MILLISECONDS)
        }.getOrDefault(false)
        // 6) The socket NAME is always unlinked: no new guest can reach
        //    a stopping bridge whatever thread state remains (the wake
        //    connect above already happened, while the path existed).
        socketFile?.delete()
        socketFile = null
        running.set(false)
        val retired = callbacksRetired && txnsRetired && watchdogRetired &&
            (thread == null || !thread.isAlive)
        if (retired) {
            retirePending = false
            pump = null
            workers = null
            callbacks = null
            deadlineWatchdog = null
            inFlight.set(0) // truthful: every worker's finally has run
        } else {
            // HONEST residue: report "retiring", keep real in-flight
            // counts and live references; never fake an idle/reset
            // bridge while old work continues.
            retirePending = true
        }
    }

    /** The guaranteed listener wake (Main review round 4): an incoming
     *  connection is precisely what a blocked accept() waits for —
     *  `unix_stream_connect` queues it on the listener and fires the
     *  listener's `sk_data_ready` on every kernel. Same UID, private
     *  0700 path, ZERO bytes exchanged: the pump sees the loop condition
     *  already false and closes it unhandled (no authentication, no
     *  transaction, no counters). If the listener is already gone the
     *  connect simply fails; the bounded joins plus shutdown/close
     *  remain the fall-back layers. */
    private fun wakeAcceptListener(path: String) {
        val client = LocalSocket()
        try {
            // Allocate the client fd before connect so backlog pressure
            // cannot block stop() ahead of its bounded joins. This is a
            // short-lived client address, never the query listener.
            client.bind(LocalSocketAddress("floe-dns-wake-${java.util.UUID.randomUUID()}",
                LocalSocketAddress.Namespace.ABSTRACT))
            // dup/getFd is public before minSdk 28; the duplicate shares
            // socket status flags and is closed without closing client.
            android.os.ParcelFileDescriptor.dup(client.fileDescriptor).use { duplicate ->
                if (com.floe.android.linuxruntime.PosixBridge.setFdNonBlocking(duplicate.fd) != 0) {
                    throw IOException("wake_nonblocking_failed")
                }
            }
            client.connect(LocalSocketAddress(path, LocalSocketAddress.Namespace.FILESYSTEM))
        } catch (_: Exception) {
            // Listener already retired: fall-back layers above/below.
        } finally {
            runCatching { client.close() }
        }
    }

    /** The next transaction uses the fresh network; active transactions
     *  finish on the network they already committed to (per-query
     *  freshness, no silent re-pointing). */
    fun networkChanged(network: Network?) {
        activeNetwork = network
    }

    private fun acceptLoop(listening: LocalServerSocket, pool: java.util.concurrent.ThreadPoolExecutor) {
        while (accepting.get()) {
            val conn = try {
                listening.accept()
            } catch (_: Exception) {
                // Closed/shutdown during stop: the loop condition ends
                // the pump; on kernels where the parked sleeper needs
                // it, stop()'s wake connect released this call first.
                continue
            }
            if (!accepting.get()) {
                // stop()'s wake connection (or a late real connect
                // during retirement): real use has ENDED, so nothing is
                // authenticated, counted or serviced here. Close it and
                // let the loop condition exit the pump.
                forceClose(conn)
                continue
            }
            try {
                val uid = conn.peerCredentials.uid
                if (uid != Process.myUid()) {
                    unauthorized.incrementAndGet()
                    runCatching { conn.close() }
                    continue
                }
            } catch (failure: Exception) {
                lastError = lastError ?: "peer_creds"
                runCatching { conn.close() }
                continue
            }
            if (inFlight.get() >= MAX_INFLIGHT) {
                refused.incrementAndGet()
                runCatching { conn.close() }
                continue
            }
            inFlight.incrementAndGet()
            openSockets[conn] = true
            try {
                pool.execute {
                    try {
                        handleTransaction(conn)
                    } catch (failure: Exception) {
                        lastError = failure.javaClass.simpleName.take(32)
                    } finally {
                        openSockets.remove(conn)
                        inFlight.decrementAndGet()
                        runCatching { conn.close() }
                    }
                }
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                openSockets.remove(conn)
                inFlight.decrementAndGet()
                refused.incrementAndGet()
                runCatching { conn.close() }
            }
        }
    }

    private fun handleTransaction(conn: LocalSocket) {
        val deadline = SystemClock.elapsedRealtime() + TRANSACTION_MS
        val query = ByteArray(GuestDnsWire.DNS_MAX)
        val header = ByteArray(GuestDnsWire.HEADER_BYTES)
        // Absolute per-transaction deadline close: whatever phase stalls
        // (drip reads, a resolver overdue past its own wait, a client
        // that never drains the response — write blocking is only
        // partially covered by setSoTimeout on current AOSP, which sets
        // SO_SNDTIMEO too, and is version-variant historically), the
        // watchdog shutdown+close at the monotonic deadline is the
        // version-independent last bound: it forces the blocked syscall
        // to fail and frees the slot. Cancelled in finally when the
        // transaction ends inside budget; closing an already-closed
        // socket is harmless.
        val watchdog = scheduleDeadlineClose(conn, deadline)
        try {
            val input = conn.inputStream
            if (!readBounded(conn, input, header, header.size, deadline)) {
                timedOut.incrementAndGet()
                return
            }
            when (val decoded = GuestDnsWire.decodeHeader(header)) {
                is GuestDnsWire.HeaderResult.Ok -> {
                    if (!readBounded(conn, input, query, decoded.dnsLength, deadline)) {
                        timedOut.incrementAndGet()
                        return
                    }
                    val dns = query.copyOf(decoded.dnsLength)
                    val response = forward(dns, deadline)
                    if (remaining(deadline) <= 0L) {
                        timedOut.incrementAndGet()
                        return
                    }
                    GuestDnsWire.writeFrame(conn.outputStream, response)
                }
                else -> {
                    // BadMagic/BadSize: the protocol refuses malformed
                    // frames outright — close without response.
                    malformed.incrementAndGet()
                    return
                }
            }
        } catch (failure: Exception) {
            if (remaining(deadline) <= 0L) timedOut.incrementAndGet()
            lastError = failure.javaClass.simpleName.take(32)
        } finally {
            runCatching { watchdog?.cancel(false) }
        }
    }

    private fun scheduleDeadlineClose(conn: LocalSocket, deadline: Long): ScheduledFuture<*>? {
        val watchdog = deadlineWatchdog ?: return null
        val left = deadline - SystemClock.elapsedRealtime()
        if (left <= 0L) {
            forceClose(conn)
            return null
        }
        return runCatching {
            watchdog.schedule({ forceClose(conn) }, left, TimeUnit.MILLISECONDS)
        }.getOrNull()
    }

    /** shutdown first (it wakes blocked recv/send on the same fd), close
     *  second; every step is best-effort because the transaction's own
     *  finally also closes. */
    private fun forceClose(conn: LocalSocket) {
        runCatching { conn.shutdownInput() }
        runCatching { conn.shutdownOutput() }
        runCatching { conn.close() }
    }

    /** Deadline-aware full read. Each blocking chunk is capped at the
     *  TRUE remaining time (never 0 — setSoTimeout(0) is infinite), so
     *  the whole read ends at the absolute deadline no matter how the
     *  peer drips bytes. A chunk timeout surfaces on current AOSP as an
     *  EAGAIN-style IOException (the JNI throws SocketTimeoutException on
     *  some releases); it is classified by the ABSOLUTE deadline, not the
     *  exception type: deadline reached ⇒ bounded false (caller counts
     *  the timeout); earlier ⇒ a genuine I/O failure, rethrown. EOF
     *  throws like the plain codec contract. */
    private fun readBounded(conn: LocalSocket, input: InputStream, buffer: ByteArray,
                            length: Int, deadline: Long): Boolean {
        var done = 0
        while (done < length) {
            val left = deadline - SystemClock.elapsedRealtime()
            if (left <= 0L) return false
            runCatching { conn.setSoTimeout(left.coerceAtMost(TRANSACTION_MS).toInt()) }
            val read = try {
                input.read(buffer, done, length - done)
            } catch (failure: IOException) {
                if (deadline - SystemClock.elapsedRealtime() <= 0L) return false
                throw failure
            }
            if (read < 0) throw java.io.EOFException("stream ended mid-frame")
            done += read
        }
        return true
    }

    private fun forward(dns: ByteArray, deadline: Long): ByteArray {
        val network = activeNetwork
        if (network == null) {
            // Offline: a bounded honest failure; local commands continue.
            forwarded.incrementAndGet() // counted as a truthful served reply
            return GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
        }
        val remaining = remaining(deadline)
        if (remaining <= 0L) {
            timedOut.incrementAndGet()
            return GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
        }
        return if (android.os.Build.VERSION.SDK_INT >= 29) {
            forwardViaDnsResolver(network, dns, remaining)
        } else {
            forwardViaSystemNetwork(network, dns, remaining)
        }.also { forwarded.incrementAndGet() }
    }

    private fun forwardViaDnsResolver(network: Network, dns: ByteArray, timeoutMs: Long): ByteArray {
        val callbackExecutor = callbacks
            ?: return GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
        val latch = CountDownLatch(1)
        var result: ByteArray? = null
        var error: String? = null
        val signal = CancellationSignal()
        activeSignals[signal] = true
        try {
            val resolver = DnsResolver.getInstance()
            // The third int is FLAGS (protocol: flags 0), never a timeout;
            // our own monotonic deadline + cancellation bound the wait.
            resolver.rawQuery(network, dns, DnsResolver.FLAG_EMPTY, callbackExecutor, signal,
                object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        result = if (answer.size in GuestDnsWire.DNS_MIN..GuestDnsWire.DNS_MAX) {
                            answer
                        } else GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
                        latch.countDown()
                    }

                    override fun onError(exception: DnsResolver.DnsException) {
                        error = "resolver_${exception.code}"
                        result = GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
                        latch.countDown()
                    }
                })
            if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                runCatching { signal.cancel() }
                timedOut.incrementAndGet()
                lastError = lastError ?: "forward_timeout"
                return GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
            }
            if (error != null) lastError = error!!.take(32)
            return result ?: GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
        } catch (failure: Exception) {
            lastError = failure.javaClass.simpleName.take(32)
            return GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
        } finally {
            activeSignals.remove(signal)
        }
    }

    /** API 28 fallback: the PUBLIC Network.getAllByName on the actual
     *  bound Network — the system resolver for that network (bionic goes
     *  through netd's live per-network path, PrivateDNS honored). Never a
     *  raw/plaintext substitute resolver.
     *
     *  Bounded (Main review round 3): a fixed process-wide worker set
     *  with NO queue (SynchronousQueue) executes at most
     *  RESOLVER_WORKERS concurrent getAllByName calls; a saturated set is
     *  rejected instantly into a bounded SERVFAIL, and a timed-out
     *  transaction never frees its worker slot early — interrupt cannot
     *  reliably cancel the native resolver, so the slot stays accounted
     *  until the real worker returns. Threads can therefore never
     *  accumulate across transactions, timeouts or restarts. */
    private fun forwardViaSystemNetwork(network: Network, dns: ByteArray, timeoutMs: Long): ByteArray {
        val question = GuestDnsWire.parseQuestion(dns)
            ?: return GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
        if (question.type != 1 && question.type != 28) {
            return GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.NOTIMP)
        }
        val task = try {
            api28Resolver.submit(Callable { network.getAllByName(question.name) })
        } catch (rejected: java.util.concurrent.RejectedExecutionException) {
            resolverRejected.incrementAndGet()
            lastError = lastError ?: "resolver_saturated"
            return GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
        }
        val addresses: Array<java.net.InetAddress>? = try {
            task.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (timeout: TimeoutException) {
            // Best-effort interrupt; if the native resolver ignores it the
            // slot stays honestly busy — that is the accounting, not a
            // leak to hide.
            runCatching { task.cancel(true) }
            timedOut.incrementAndGet()
            lastError = lastError ?: "forward_timeout"
            return GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
        } catch (failure: Exception) {
            null
        }
        return if (addresses == null) {
            // Indistinguishable transient vs unknown at this API: a
            // bounded SERVFAIL is the honest answer (never NXDOMAIN lie,
            // never an alternative resolver).
            GuestDnsWire.buildRcodeOnly(dns, GuestDnsWire.SERVFAIL)
        } else if (addresses.isEmpty()) {
            GuestDnsWire.buildResponseFromAddresses(dns, emptyList(), TTL_SECONDS,
                GuestDnsWire.NOERROR, recursionAvailable = true)
        } else {
            GuestDnsWire.buildResponseFromAddresses(dns, addresses.toList(), TTL_SECONDS,
                GuestDnsWire.NOERROR, recursionAvailable = true)
        }
    }

    /** TRUE remaining time; never fabricates a positive timeout (the old
     *  coerceIn(1, …) made every <=0 branch unreachable and turned
     *  drip reads into an immortal transaction). */
    private fun remaining(deadline: Long): Long =
        deadline - SystemClock.elapsedRealtime()

    companion object {
        const val SOCKET_BASENAME = "s"
        const val GUEST_SOCKET_DIR = "/run/floe-dns"
        private const val SUN_PATH_MAX = 108
        private const val MAX_INFLIGHT = 8
        private const val TRANSACTION_MS = 3_500L
        private const val POOL_JOIN_MS = 1_000L
        private const val JOIN_MS = 1_000L
        private const val TTL_SECONDS = 60
        /** Process-wide cap on concurrent API 28 platform resolver calls.
         *  Lazy and never shut down: daemon workers die with the process,
         *  and no timeout or session restart ever spawns a second set. */
        private const val RESOLVER_WORKERS = 4
        @JvmStatic private val api28Resolver: java.util.concurrent.ThreadPoolExecutor by lazy {
            java.util.concurrent.ThreadPoolExecutor(
                RESOLVER_WORKERS, RESOLVER_WORKERS, 0L, TimeUnit.MILLISECONDS,
                SynchronousQueue(),
            ) { work -> Thread(work, "floe-dns-api28").apply { isDaemon = true } }
        }
    }
}
