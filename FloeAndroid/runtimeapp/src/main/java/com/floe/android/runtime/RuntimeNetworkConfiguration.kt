// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.content.Context
import android.database.ContentObserver
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.floe.android.linuxruntime.LinuxBind
import com.floe.android.linuxruntime.resolver.GuestResolverProbe
import com.floe.android.linuxruntime.resolver.PrivateDnsMode
import com.floe.android.linuxruntime.resolver.ResolverConfiguration
import com.floe.android.linuxruntime.resolver.ResolverDecision
import com.floe.android.linuxruntime.resolver.ResolverInputs
import com.floe.android.linuxruntime.resolver.ResolverState
import com.floe.android.linuxruntime.resolver.TunnelProbe
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

/**
 * Session-bound guest resolver configuration (G03-R3 facilities).
 *
 * Replaces the old "raw LinkProperties or null" behavior. Every launch
 * receives an OWNED explicit resolv.conf bind — there is no return path
 * that could expose the base image's baked `127.0.0.53`
 * systemd-resolved configuration, and no public/plaintext substitute is
 * ever invented.
 *
 * Facts drive everything (Main reviews): the per-network effective state
 * comes from the PUBLIC `LinkProperties.isPrivateDnsActive()` (API 28+,
 * where PrivateDNS exists) and the AOSP `private_dns_mode` ->
 * `private_dns_default_mode` -> "opportunistic" chain; non-loopback server
 * addresses NEVER authorize plaintext by themselves, and an absent
 * settings value is never OFF. When the guest bridge is capable it is the
 * PREFERRED path for every session (Main's live-safety requirement),
 * because the AF_UNIX `floe-guest-dns-v1` handler resolves on the CURRENT
 * active Network at query time: the committed guest configuration never
 * goes stale across PrivateDNS/network/offline transitions. Fact-based
 * DIRECT/TUNNEL fallbacks exist only where the bridge is not capable, and
 * the change monitor re-validates them on a bounded owned thread and
 * rewrites or REVOKES the committed resolv.conf atomically (glibc reloads
 * it when mtime/size changes).
 *
 * Owned callbacks, the private socket directory and all sockets exist only
 * for the lifetime of real work: [prepareBinds] on admission, [release]
 * when the owning session settles (including abandoned launches).
 */
internal object RuntimeNetworkConfiguration {
    /** Frozen signed-asset contract (PROTOCOL.json assetContract): Main
     *  copies verified producer output into runtimeapp assets
     *  guest-resolver/{libnss_floe.so.2, .sha256, manifest.json}; this
     *  lane stages those immutable bytes safely and verifies strictly.
     *  Missing source/manifest NEVER becomes ready. */
    private const val ASSET_DIR = "guest-resolver"
    private const val ASSET_LIBRARY = "$ASSET_DIR/libnss_floe.so.2"
    private const val ASSET_DIGEST = "$ASSET_DIR/libnss_floe.so.2.sha256"
    private const val ASSET_MANIFEST = "$ASSET_DIR/manifest.json"
    private const val HELPER_FILE = "RuntimeHelpers/libnss_floe.so.2"
    private const val HELPER_MAX_BYTES = 4_194_304 // manifest binary.bytes ceiling
    private const val MANIFEST_MAX_BYTES = 65_536
    private const val DIGEST_MAX_BYTES = 128
    private const val HELPER_SONAME = "libnss_floe.so.2"
    private val REQUIRED_EXPORTS = setOf(
        "_nss_floe_gethostbyname_r", "_nss_floe_gethostbyname2_r",
        "_nss_floe_gethostbyname3_r", "_nss_floe_gethostbyname4_r")

    private val lock = Any()
    private val bridge = BridgeHolder()
    private val generation = AtomicLong(1)
    private val revalidations = AtomicLong()
    private val revalidationQueued = AtomicBoolean()
    @Volatile private var last: Snapshot? = null
    private var monitor: ResolverMonitor? = null
    /**
     * G07.3A: one prepared resolver session per OWNED WORKLOAD. The bridge and
     * socket directory are process-wide and shared; each workload gets its own
     * scratch copy of the committed files. Releasing one workload must never
     * stop the resolver another live terminal still uses.
     */
    private val sessions = LinkedHashMap<File, Session>()

    // Staged-helper state (install-time verification; digest re-checked at
    // each prepare so on-disk drift after install also fails closed).
    @Volatile private var stagedSha256: String? = null
    @Volatile private var helperInstallState: String = "assets_unseen"

    private class Session(val scratch: File, val socketDir: File?, var decision: ResolverDecision)

    private data class Snapshot(
        val decision: ResolverDecision,
        val privateDnsMode: PrivateDnsMode,
        val effectivePrivateDns: Boolean?,
        val serverCount: Int,
        val probe: TunnelProbe,
        val generation: Long,
        val helperPresent: Boolean,
        val helperVerified: Boolean,
        val lastTransition: String?,
    )

    private class BridgeHolder {
        var bridge: GuestDnsBridge? = null
        fun get(): GuestDnsBridge = bridge ?: GuestDnsBridge().also { bridge = it }
        fun stop() { bridge?.stop() }
    }

    /** Remove stale per-work socket directories left by a killed process
     *  (only our own 8-hex component names). Safe at operations init: the
     *  single-work-slot kernel admits nothing before the first prepare. */
    fun sweepStaleSocketDirs(context: Context) {
        val root = runCatching { File(context.applicationContext.filesDir.canonicalFile, "Resolver") }
            .getOrNull() ?: return
        if (!root.isDirectory) return
        root.listFiles()?.forEach { dir ->
            if (dir.name.matches(Regex("[0-9a-f]{8}"))) runCatching { dir.deleteRecursively() }
        }
    }

    /** Produce the owned resolver binds for one session launch. Never
     *  returns an empty list: offline/unsupported states still bind an
     *  explicit unreachable-local configuration. */
    fun prepareBinds(context: Context, scratch: File): List<LinuxBind> =
        synchronized(lock) {
            val ownerScratch = scratch.canonicalFile
            // A live configuration is process-wide truth: a second concurrent
            // session writes the SAME committed bytes into its OWN scratch
            // instead of re-deciding into a divergent resolver state.
            val existing = sessions.values.firstOrNull()
            val committed: ResolverDecision
            val socketDir: File?
            if (existing != null) {
                committed = existing.decision
                socketDir = existing.socketDir
            } else {
                val facts = readFacts(context)
                val decision = decideFor(facts)
                var selected = decision
                var started: File? = null
                if (decision.bridgeRequested) {
                    started = tryStartBridge(context, facts)
                    if (started == null) {
                        selected = ResolverConfiguration.decide(ResolverInputs(
                            android.os.Build.VERSION.SDK_INT, facts.mode, facts.effectivePrivateDns,
                            facts.activeNetwork != null, facts.rawServers, false, false,
                            probeFor(facts)))
                    }
                }
                committed = selected
                socketDir = started
            }
            val binds = bindsFor(context, ownerScratch, committed, socketDir)
            sessions[ownerScratch] = Session(ownerScratch, socketDir, committed)
            last = snapshotOf(committed, readFacts(context))
            if (monitor == null) {
                monitor = ResolverMonitor(context.applicationContext,
                    onChange = {
                        generation.incrementAndGet()
                        bridge.bridge?.networkChanged(runCatching {
                            context.applicationContext.getSystemService(ConnectivityManager::class.java)?.activeNetwork
                        }.getOrNull())
                        scheduleRevalidation(context.applicationContext)
                    }).also { it.register() }
            }
            binds.toList()
        }

    private fun bindsFor(context: Context, scratch: File, committed: ResolverDecision,
                         socketDir: File?): List<LinuxBind> {
        val plan = ResolverConfiguration.ownedFilePlan(committed)
        val binds = ArrayList<LinuxBind>()
        for (file in plan.files) {
            binds += writeFileBind(scratch, file.scratchName, file.content, file.guestPath)
        }
        if (plan.requiresHelperModule) {
            val helper = resolveHelper(context) ?: error("bridge committed without verified helper")
            binds += LinuxBind(helper, ResolverConfiguration.GUEST_NSS_MODULE_PATH)
            binds += LinuxBind(checkNotNull(socketDir), ResolverConfiguration.GUEST_SOCKET_DIR_PATH)
        }
        return binds
    }

    private fun tryStartBridge(context: Context, facts: Facts): File? {
        val appContext = context.applicationContext
        val root = File(appContext.filesDir.canonicalFile, "Resolver")
        if (!root.mkdirs() && !root.isDirectory) { bridge.stop(); return null }
        val randomBytes = ByteArray(4)
        java.security.SecureRandom().nextBytes(randomBytes)
        val name = randomBytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        val dir = File(root, name)
        if (!bridge.get().start(dir, facts.activeNetwork)) {
            bridge.stop()
            runCatching { dir.delete() }
            return null
        }
        return dir
    }

    /** End the session's real resolver use: stop the owned listener,
     *  remove the owned socket directory and unregister the owned
     *  callbacks. Idempotent; safe from the owned IO thread and stop paths. */
    fun release(scratch: File? = null) {
        synchronized(lock) {
            val released = if (scratch == null) sessions.values.toList()
                else listOfNotNull(sessions.remove(scratch.canonicalFile))
            if (sessions.isEmpty()) sessions.clear()
            if (sessions.isNotEmpty()) return
            bridge.stop()
            released.mapNotNull { it.socketDir }.distinct().forEach { dir ->
                runCatching { dir.deleteRecursively() }
            }
            monitor?.unregister()
            monitor = null
        }
    }

    /** Additive diagnostics for the status wire: actual applied state only,
     *  never raw server addresses, names, or DNS payloads. */
    fun statusSnapshot(): JSONObject {
        val snapshot = last
        val bridgeStatus = bridge.bridge?.status()
        return JSONObject().also { value ->
            if (snapshot == null) {
                value.put("state", "not_prepared")
            } else {
                value.put("state", snapshot.decision.state.name.lowercase())
                    .put("configuredMode", snapshot.privateDnsMode.name.lowercase())
                    .put("effectivePrivateDns", snapshot.effectivePrivateDns?.toString() ?: "unreadable")
                    .put("serverCount", snapshot.serverCount)
                    .put("probe", snapshot.probe.name.lowercase())
                    .put("generation", snapshot.generation)
                    .put("revalidations", revalidations.get())
                    .put("helper", JSONObject()
                        .put("install", helperInstallState)
                        .put("present", snapshot.helperPresent)
                        .put("verified", snapshot.helperVerified))
                    .put("diagnostic", snapshot.decision.diagnostic)
                snapshot.lastTransition?.let { value.put("lastTransition", it) }
            }
            if (bridgeStatus != null) value.put("bridge", bridgeStatus)
        }
    }

    // MARK: facts + decision

    private data class Facts(
        val activeNetwork: Network?,
        val rawServers: List<String>,
        val mode: PrivateDnsMode,
        val effectivePrivateDns: Boolean?,
        val helperVerified: Boolean,
        val apiAvailable: Boolean,
    )

    private fun readFacts(context: Context): Facts {
        val appContext = context.applicationContext
        val connectivity = appContext.getSystemService(ConnectivityManager::class.java)
        val active = runCatching { connectivity?.activeNetwork }.getOrNull()
        val link = active?.let { runCatching { connectivity?.getLinkProperties(it) }.getOrNull() }
        val rawServers = link?.dnsServers?.mapNotNull { it.hostAddress } ?: emptyList()
        val effective = runCatching { link?.isPrivateDnsActive }.getOrNull()
        return Facts(active, rawServers, readPrivateDnsMode(appContext), effective,
            resolveHelper(appContext) != null, android.os.Build.VERSION.SDK_INT >= 29)
    }

    private fun probeFor(facts: Facts): TunnelProbe {
        val normalized = ResolverConfiguration.normalizeServers(facts.rawServers)
        val loopbackShape = normalized.isNotEmpty() &&
            normalized.all { ResolverConfiguration.isLoopbackLiteral(it) }
        return if (loopbackShape && ResolverConfiguration.decide(inputsOf(facts)).state != ResolverState.BRIDGED)
            GuestResolverProbe.probeTunnel(normalized)
        else TunnelProbe.NOT_RUN
    }

    private fun inputsOf(facts: Facts) = ResolverInputs(
        android.os.Build.VERSION.SDK_INT, facts.mode, facts.effectivePrivateDns,
        facts.activeNetwork != null, facts.rawServers, facts.apiAvailable,
        facts.helperVerified, TunnelProbe.NOT_RUN)

    private fun decideFor(facts: Facts): ResolverDecision {
        val base = ResolverConfiguration.decide(inputsOf(facts))
        if (base.state == ResolverState.BRIDGED || base.bridgeRequested) return base
        // Fallbacks need the bounded listener-reachability evidence.
        return ResolverConfiguration.decide(inputsOf(facts).copy(tunnelProbe =
            if (ResolverConfiguration.normalizeServers(facts.rawServers)
                    .isNotEmpty() && ResolverConfiguration.normalizeServers(facts.rawServers)
                    .all { ResolverConfiguration.isLoopbackLiteral(it) })
                GuestResolverProbe.probeTunnel(
                    ResolverConfiguration.normalizeServers(facts.rawServers))
            else TunnelProbe.NOT_RUN))
    }

    // MARK: live revalidation

    private val revalidationExecutor = java.util.concurrent.ThreadPoolExecutor(
        1, 1, 30, java.util.concurrent.TimeUnit.SECONDS, java.util.concurrent.ArrayBlockingQueue(1)
    ) { work -> Thread(work, "floe-resolver-revalidate").apply { isDaemon = true } }
        .apply { allowCoreThreadTimeOut(true) }

    private fun scheduleRevalidation(appContext: Context) {
        if (sessions.isEmpty() || revalidationQueued.get()) return
        if (!revalidationQueued.compareAndSet(false, true)) return
        try {
            revalidationExecutor.execute {
                revalidationQueued.set(false)
                runCatching { revalidateNow(appContext) }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            revalidationQueued.set(false)
        }
    }

    private fun revalidateNow(appContext: Context) {
        synchronized(lock) {
            if (sessions.isEmpty()) return
            val facts = readFacts(appContext)
            val fresh = decideFor(facts)
            // A bridged session is live-correct by construction; a session
            // can never be UPGRADED into a bridge mid-launch (PRoot binds
            // are fixed), so the honest live actions are: keep, rewrite
            // with a still-safe configuration, or revoke to the dead
            // marker. There is never a raw/plaintext substitution.
            val previous = sessions.values.first().decision
            if (previous.state == ResolverState.BRIDGED) { updateSnapshot(previous, facts); return }
            val replacement: ResolverDecision = when {
                fresh.state == ResolverState.BRIDGED ->
                    if (previousSafe(facts)) previous else revokedMarker()
                fresh.state == previous.state && fresh.resolvConfText == previous.resolvConfText -> {
                    updateSnapshot(previous, facts); return
                }
                fresh.state == ResolverState.SYSTEM_DIRECT || fresh.state == ResolverState.SYSTEM_TUNNEL -> fresh
                else -> revokedMarker()
            }
            if (replacement.resolvConfText != previous.resolvConfText) {
                for (owned in sessions.values) {
                    runCatching {
                        val target = File(owned.scratch, "resolv.conf")
                        if (target.isFile) { // scratch may be gone with a settled session
                            val tmp = File(owned.scratch, "resolv.conf.tmp-$processTag")
                            Files.write(tmp.toPath(), replacement.resolvConfText.toByteArray(Charsets.US_ASCII),
                                StandardOpenOption.CREATE, StandardOpenOption.WRITE,
                                StandardOpenOption.TRUNCATE_EXISTING)
                            android.system.Os.chmod(tmp.path, 0x180)
                            Files.move(tmp.toPath(), target.toPath(),
                                StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
                        }
                    }.onFailure {
                        lastError = "rewrite_failed"
                    }
                }
            }
            revalidations.incrementAndGet()
            for (owned in sessions.values) owned.decision = replacement
            last = snapshotOf(replacement, facts).copy(
                lastTransition = previous.state.name.lowercase() + "->" + replacement.state.name.lowercase())
        }
    }

    @Volatile private var lastError: String? = null

    private fun previousSafe(facts: Facts): Boolean {
        val withoutBridge = ResolverConfiguration.decide(
            inputsOf(facts).copy(dnsResolverApiAvailable = false, guestBridgeHelperAvailable = false,
                tunnelProbe = probeFor(facts)))
        return withoutBridge.state == ResolverState.SYSTEM_DIRECT ||
            withoutBridge.state == ResolverState.SYSTEM_TUNNEL
    }

    private fun revokedMarker(): ResolverDecision =
        ResolverConfiguration.decide(ResolverInputs(android.os.Build.VERSION.SDK_INT,
            PrivateDnsMode.UNKNOWN, null, false, emptyList(), false, false, TunnelProbe.NOT_RUN))
            .copy(diagnostic = "revoked mid-session: private DNS/network change left no safe committed path")

    private fun updateSnapshot(decision: ResolverDecision, facts: Facts) {
        last = snapshotOf(decision, facts)
    }

    private fun snapshotOf(decision: ResolverDecision, facts: Facts): Snapshot {
        val normalized = ResolverConfiguration.normalizeServers(facts.rawServers)
        val loopback = normalized.isNotEmpty() && normalized.all { ResolverConfiguration.isLoopbackLiteral(it) }
        return Snapshot(decision, facts.mode, facts.effectivePrivateDns, normalized.size,
            if (loopback && decision.state != ResolverState.BRIDGED)
                GuestResolverProbe.probeTunnel(normalized)
            else TunnelProbe.NOT_RUN,
            generation.get(), facts.helperVerified, facts.helperVerified,
            last?.lastTransition)
    }

    // MARK: files

    private fun writeFileBind(scratch: File, name: String, text: String, guestPath: String): LinuxBind {
        require(text.toByteArray(Charsets.US_ASCII).size <= ResolverConfiguration.MAX_RESOLV_BYTES) {
            "resolver file unbounded"
        }
        val file = File(scratch, name)
        Files.write(file.toPath(), text.toByteArray(Charsets.US_ASCII),
            StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
        android.system.Os.chmod(file.path, 0x180) // owner read/write; no credential data
        return LinuxBind(file, guestPath)
    }

    private val processTag = java.util.UUID.randomUUID().toString().take(8)

    // MARK: signed-asset staging + verification

    /** Verify the three immutable signed-APK assets against the frozen
     *  manifestSchema/manifestRules, then stage the helper bytes atomically
     *  under filesDir. Every failure path fails closed: no staged file, an
     *  honest state class, and the bridge stays unavailable. Never called
     *  on a Binder/main thread (operations init owns it). */
    fun installGuestResolverAssets(context: Context) {
        val appContext = context.applicationContext
        try {
            val manifestText = readAsset(appContext, ASSET_MANIFEST, MANIFEST_MAX_BYTES)
                ?: run { helperInstallState = "assets_absent"; stagedSha256 = null; return }
            val manifest = runCatching { JSONObject(manifestText) }.getOrElse {
                helperInstallState = "manifest_unparseable"; stagedSha256 = null; return }
            val expectedSha = validateManifest(manifest) ?: run {
                helperInstallState = "manifest_invalid"; stagedSha256 = null; return }
            val digestText = readAsset(appContext, ASSET_DIGEST, DIGEST_MAX_BYTES) ?: run {
                helperInstallState = "digest_absent"; stagedSha256 = null; return }
            // Accept bare hex or sha256sum "<hex>  <name>" sidecar formats.
            val sidecar = digestText.trim().lowercase(java.util.Locale.ROOT)
                .split(Regex("\\s+")).firstOrNull() ?: ""
            if (sidecar != expectedSha) {
                helperInstallState = "digest_mismatch"; stagedSha256 = null; return
            }
            val bytes = readAssetBytes(appContext, ASSET_LIBRARY, HELPER_MAX_BYTES) ?: run {
                helperInstallState = "library_absent"; stagedSha256 = null; return }
            if (bytes.size > HELPER_MAX_BYTES) { helperInstallState = "library_oversized"; stagedSha256 = null; return }
            val declared = manifest.getJSONObject("binary").optInt("bytes", -1)
            if (declared != bytes.size) { helperInstallState = "size_mismatch"; stagedSha256 = null; return }
            if (!isElfAarch64Shared(bytes)) { helperInstallState = "elf_invalid"; stagedSha256 = null; return }
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it.toInt() and 0xFF) }
            if (digest != expectedSha) { helperInstallState = "sha_mismatch"; stagedSha256 = null; return }
            val filesRoot = appContext.filesDir.canonicalFile
            val dir = File(filesRoot, "RuntimeHelpers")
            if (!dir.mkdirs() && !dir.isDirectory) { helperInstallState = "dir_failed"; stagedSha256 = null; return }
            val target = File(dir, HELPER_SONAME)
            val tmp = File(dir, "$HELPER_SONAME.tmp-$processTag")
            Files.write(tmp.toPath(), bytes, StandardOpenOption.CREATE,
                StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING)
            android.system.Os.chmod(tmp.path, 0x1A4) // 0644
            Files.move(tmp.toPath(), target.toPath(),
                StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            stagedSha256 = expectedSha
            helperInstallState = "staged"
        } catch (failure: Exception) {
            stagedSha256 = null
            helperInstallState = "install_${failure.javaClass.simpleName.lowercase()}"
        }
    }

    /** Manifest validation per the frozen manifestRules: schema fields,
     *  bounds, sorted safe source paths, required exports, alignment and
     *  lowercase-hex digests. Returns binary.sha256 or null. Source-tree
     *  rehashing is producer+CCS validation (the source set is not shipped
     *  in the APK); runtime enforces the shipped consistency facts. */
    private fun validateManifest(manifest: JSONObject): String? {
        if (manifest.optInt("schemaVersion") != 1) return null
        if (manifest.optString("protocol") != "floe-guest-dns-v1") return null
        if (manifest.optString("library") != HELPER_SONAME) return null
        if (manifest.optString("soname") != HELPER_SONAME) return null
        if (manifest.optString("target") != "aarch64-linux-gnu") return null
        if (manifest.optLong("minimumLoadAlignment") != 16384L) return null
        val toolchain = manifest.optJSONObject("toolchain") ?: return null
        if (toolchain.optString("name") != "zig") return null
        if (toolchain.optString("version").isEmpty() || !isHex64(toolchain.optString("archiveSha256"))) return null
        if (!isHex64(manifest.optString("sourceTreeSha256"))) return null
        val binary = manifest.optJSONObject("binary") ?: return null
        if (binary.optString("name") != HELPER_SONAME) return null
        val sha = binary.optString("sha256")
        if (!isHex64(sha)) return null
        val size = binary.optInt("bytes", -1)
        if (size !in 1..HELPER_MAX_BYTES) return null
        val exports = manifest.optJSONArray("exports") ?: return null
        val exportSet = (0 until exports.length()).map { exports.optString(it) }.toSet()
        if (!exportSet.containsAll(REQUIRED_EXPORTS)) return null
        val sources = manifest.optJSONArray("sources") ?: return null
        if (sources.length() > 64) return null
        var previousPath: String? = null
        for (index in 0 until sources.length()) {
            val source = sources.optJSONObject(index) ?: return null
            val path = source.optString("path")
            if (path.isEmpty() || path.length > 256) return null
            if (path.startsWith("/") || path.contains("../") || path.contains("/..") ||
                path.contains('\u0000') || !path.matches(Regex("[\\x20-\\x7E]+"))) return null
            if (!isHex64(source.optString("sha256"))) return null
            if (source.optLong("bytes") < 0) return null
            if (previousPath != null && previousPath >= path) return null // UTF-8/ASCII order match
            previousPath = path
        }
        return sha
    }

    private fun isHex64(value: String): Boolean = value.matches(Regex("[0-9a-f]{64}"))

    private fun isElfAarch64Shared(bytes: ByteArray): Boolean {
        if (bytes.size < 20) return false
        if (bytes[0] != 0x7F.toByte() || bytes[1] != 'E'.code.toByte() ||
            bytes[2] != 'L'.code.toByte() || bytes[3] != 'F'.code.toByte()) return false
        val type = (bytes[16].toInt() and 0xFF) or ((bytes[17].toInt() and 0xFF) shl 8)
        val machine = (bytes[18].toInt() and 0xFF) or ((bytes[19].toInt() and 0xFF) shl 8)
        return type == 3 && machine == 183 // ET_DYN + EM_AARCH64
    }

    private fun readAsset(context: Context, path: String, cap: Int): String? = runCatching {
        context.assets.open(path).use { stream ->
            val buffer = ByteArray(8 * 1024)
            val out = java.io.ByteArrayOutputStream()
            var total = 0
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                total += read
                if (total > cap) return null
                out.write(buffer, 0, read)
            }
            out.toByteArray().toString(Charsets.UTF_8)
        }
    }.getOrNull()

    private fun readAssetBytes(context: Context, path: String, cap: Int): ByteArray? = runCatching {
        context.assets.open(path).use { stream ->
            val buffer = ByteArray(8 * 1024)
            val out = java.io.ByteArrayOutputStream()
            var total = 0
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                total += read
                if (total > cap) return null
                out.write(buffer, 0, read)
            }
            out.toByteArray()
        }
    }.getOrNull()

    // MARK: helper presence

    /** The staged file only when the install-time digest is still true for
     *  the bytes on disk (re-verified fail-closed per prepare). */
    private fun resolveHelper(context: Context): File? {
        val expected = stagedSha256 ?: return null
        val file = helperFileFor(context) ?: return null
        if (!file.isFile || file.length() !in 1..HELPER_MAX_BYTES.toLong() || !file.canRead()) return null
        val digest = runCatching {
            MessageDigest.getInstance("SHA-256").digest(file.readBytes())
                .joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        }.getOrNull() ?: return null
        return if (digest == expected) file else null
    }

    private fun helperFileFor(context: Context): File? = runCatching {
        val filesRoot = context.applicationContext.filesDir.canonicalFile
        val expected = File(filesRoot, HELPER_FILE)
        if (expected.canonicalFile != expected || !expected.toPath().startsWith(filesRoot.toPath())) null
        else expected
    }.getOrNull()

    private fun readPrivateDnsMode(context: Context): PrivateDnsMode {
        val configured = runCatching {
            Settings.Global.getString(context.contentResolver, PRIVATE_DNS_MODE_KEY)
        }.getOrNull()
        val fallback = runCatching {
            Settings.Global.getString(context.contentResolver, PRIVATE_DNS_DEFAULT_MODE_KEY)
        }.getOrNull()
        return ResolverConfiguration.parsePrivateDnsMode(configured, fallback)
    }

    // MARK: monitor

    private class ResolverMonitor(
        context: Context,
        private val onChange: () -> Unit,
    ) {
        private val appContext = context.applicationContext
        private val connectivity = appContext.getSystemService(ConnectivityManager::class.java)
        private val handler = Handler(Looper.getMainLooper())
        private var callback: android.net.ConnectivityManager.NetworkCallback? = null
        private var observer: ContentObserver? = null

        fun register() {
            try {
                val request = NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build()
                val networkCallback = object : android.net.ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) = onChange()
                    override fun onLost(network: Network) = onChange()
                    override fun onLinkPropertiesChanged(network: Network,
                                                          linkProperties: LinkProperties) = onChange()
                }
                connectivity?.registerNetworkCallback(request, networkCallback)
                callback = networkCallback
            } catch (_: Exception) {
                callback = null // truthful: change observation is absent
            }
            try {
                val contentObserver = object : ContentObserver(handler) {
                    override fun onChange(selfChange: Boolean) = onChange()
                }
                appContext.contentResolver.registerContentObserver(
                    Settings.Global.getUriFor(PRIVATE_DNS_MODE_KEY), false, contentObserver)
                appContext.contentResolver.registerContentObserver(
                    Settings.Global.getUriFor(PRIVATE_DNS_DEFAULT_MODE_KEY), false, contentObserver)
                appContext.contentResolver.registerContentObserver(
                    Settings.Global.getUriFor(PRIVATE_DNS_HOSTNAME_KEY), false, contentObserver)
                observer = contentObserver
            } catch (_: Exception) {
                observer = null
            }
        }

        fun unregister() {
            try {
                callback?.let { connectivity?.unregisterNetworkCallback(it) }
            } catch (_: Exception) {
                // best-effort close of the owned callback
            }
            callback = null
            observer?.let { runCatching { appContext.contentResolver.unregisterContentObserver(it) } }
            observer = null
        }
    }

    private const val PRIVATE_DNS_MODE_KEY = "private_dns_mode"
    private const val PRIVATE_DNS_DEFAULT_MODE_KEY = "private_dns_default_mode"
    private const val PRIVATE_DNS_HOSTNAME_KEY = "private_dns_hostname"
}
