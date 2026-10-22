// SPDX-License-Identifier: MPL-2.0
//
// Pure guest-resolver decision core (G03-R3 runtime facilities).
//
// No Android types on purpose: the whole state machine is JVM-unit-testable
// and the runtime-side callers feed it only explicitly read facts. This file
// never invents a resolver: there is no public/anchor IP constant anywhere,
// no caller or model supplied server list, and no decision path that leaves
// the guest on the base image's baked resolv.conf.
//
// PrivateDNS truth source (Main review, 2026-10-22): the ACTUAL effective
// per-network state comes from the PUBLIC `LinkProperties.isPrivateDnsActive`
// fact (public since API 28, where PrivateDNS itself exists). The decision
// never infers "no DoT" from non-loopback server addresses (netd can report
// them while the private path is active) and never treats an absent settings
// value as provably off.
//
// Live-safety priority (Main review, second round): when the authenticated
// system-resolver bridge is available it is the PREFERRED path for every
// session (online AND offline->online), because each forwarded query is
// resolved by android.net.DnsResolver on the CURRENT active Network — the
// real system state at query time — and the already-committed guest
// configuration never becomes stale when PrivateDNS or the network changes
// mid-session. Direct configurations exist only on devices without the
// bridge capability, where the runtime keeps a bounded live re-validation
// that REVOKES an unsafe committed configuration immediately.
package com.floe.android.linuxruntime.resolver

/** Configuration intent from the `private_dns_mode` global setting, parsed
 *  with the AOSP value chain (ConnectivitySettingsUtils.getPrivateDnsMode):
 *  real values are "off", "opportunistic", "hostname"; when the mode is
 *  empty the DEFAULT setting is consulted and, if that is empty too, the
 *  system default is "opportunistic". An absent value is therefore NEVER
 *  evidence of OFF. */
enum class PrivateDnsMode {
    /** Explicit persisted "off" value (an existing setting, not an absent one). */
    OFF,

    /** Opportunistic DoT: encrypted if the network offers it, otherwise the
     *  system's own servers. The EFFECTIVE per-network state
     *  (isPrivateDnsActive) decides; the intent alone never authorizes or
     *  forbids plaintext by itself. */
    OPPORTUNISTIC,

    /** "hostname": an explicit PrivateDNS server name is configured; the
     *  encrypted path is mandatory (formerly reported as "strict"). */
    HOSTNAME,

    /** A garbage/unsupported value: treated like a possibly-private
     *  configuration and never as provable off. */
    UNKNOWN,
}

/** Bounded reachability evidence for the system-provided loopback resolver
 *  addresses (netd's own DNS proxy listener). Computed by the runtime
 *  probe; the policy only consumes the terminal outcome. */
enum class TunnelProbe {
    /** Probe deliberately not run (no tunnel-shaped candidate to verify). */
    NOT_RUN,

    /** Some system-managed listener answered a DNS response on port 53. */
    REACHABLE,

    /** Silence within the bounded window. */
    UNREACHABLE,

    /** ICMP/ECONNREFUSED: nothing listens on the candidate address. */
    REFUSED,
}

enum class ResolverState {
    /** Preferred path when the bridge is capable: the guest NSS helper
     *  talks to the runtime's private AF_UNIX listener (per-work 0700
     *  directory bind-mounted at /run/floe-dns, FDN1+u16BE framing,
     *  accepted peer UID == runtime UID), and the handler resolves via the
     *  public android.net.DnsResolver on the active Network. System state
     *  is read at QUERY time, so PrivateDNS/network/offline transitions
     *  are live and truthful without touching the committed guest
     *  configuration (floe-guest-dns-v1). */
    BRIDGED,

    /** No bridge capability: the system reported its own loopback DNS-proxy
     *  addresses AND the runtime verified they answer guest-style UDP on
     *  port 53. netd's listener applies the current PrivateDNS state live,
     *  so this path stays correct across mid-session setting changes on the
     *  same network; the runtime re-validates the listener after a network
     *  change and revokes immediately if it cannot re-verify. */
    SYSTEM_TUNNEL,

    /** No bridge capability and the FACTS authorize plaintext: the active
     *  network reports `isPrivateDnsActive == false`, or the setting is an
     *  explicit "off". The guest uses exactly the system-configured
     *  servers. NEVER an inference from address shape. A live change to a
     *  private path revokes this configuration mid-session. */
    SYSTEM_DIRECT,

    /** Offline or no usable resolver info without bridge capability: an
     *  explicit, owned, unreachable-local resolv.conf. Offline local
     *  commands stay runnable and DNS fails truthfully. */
    UNAVAILABLE_OFFLINE,

    /** PrivateDNS is effective/unknown with no direct or bridged path on
     *  this platform state. Explicitly fail closed — never plaintext, never
     *  a public resolver, never the base image's baked configuration. */
    UNAVAILABLE_UNSUPPORTED,
}

data class ResolverInputs(
    val sdkInt: Int,
    val privateDnsMode: PrivateDnsMode,

    /** `LinkProperties.isPrivateDnsActive()` for the CURRENT active network
     *  as read; null means the read failed or no network object carried it.
     *  This effective fact outranks the settings intent in both directions. */
    val effectivePrivateDns: Boolean?,

    val activeNetworkPresent: Boolean,

    /** Raw `LinkProperties.dnsServers` host addresses for the active
     *  network, exactly as read; validated and bounded here. */
    val systemDnsServers: List<String>,

    /** True when the android.net.DnsResolver system bridge is usable on
     *  this device for this app (public since API 29; caller checks SDK). */
    val dnsResolverApiAvailable: Boolean,

    /** True when the owned guest NSS helper is staged from the signed-APK
     *  assets and digest-verified against the frozen manifest + sidecar
     *  (re-verified against on-disk bytes at each prepare), bind-mountable
     *  into this rootfs revision. */
    val guestBridgeHelperAvailable: Boolean,

    /** Terminal tunnel probe outcome for loopback-shaped system servers. */
    val tunnelProbe: TunnelProbe,
) {
    val bridgeCapable: Boolean get() = dnsResolverApiAvailable && guestBridgeHelperAvailable
}

/** One decision per launch generation. `resolvConfText` is ALWAYS produced:
 *  the runtime always bind-mounts an owned resolv.conf, so returning "no
 *  configuration" can never fall through to the base image's baked file. */
data class ResolverDecision(
    val state: ResolverState,
    val resolvConfText: String,
    val nameservers: List<String>,
    val overrideNsswitch: Boolean,
    val bridgeRequested: Boolean,
    val diagnostic: String,
)

/** One owned per-session resolver file to write into fresh scratch and
 *  bind-mount at [guestPath]. Pure data only; the runtime materializes. */
data class OwnedResolverFile(
    val scratchName: String,
    val content: String,
    val guestPath: String,
)

/** The complete owned resolver file plan for one session. Always contains
 *  exactly one resolv.conf; bridged sessions additionally carry the
 *  deliberate no-`dns`-fallback nsswitch and require the runtime to bind
 *  the private per-work socket directory at [socketGuestPath] plus the
 *  verified helper .so at [helperGuestPath]. */
data class OwnedResolverPlan(
    val files: List<OwnedResolverFile>,
    val requiresHelperModule: Boolean,
    val helperGuestPath: String?,
    val socketGuestPath: String?,
)

object ResolverConfiguration {
    /** glibc MAXNS: only the first three nameserver lines are ever used. */
    const val MAX_NAMESERVERS = 3

    /** Hard cap for generated resolv.conf content (bounded buffers). */
    const val MAX_RESOLV_BYTES = 512

    /** AOSP value chain for the private DNS intent (Main primary source:
     *  frameworks/libs/net ConnectivitySettingsUtils.getPrivateDnsMode).
     *  Pure so the parsing is unit-tested; callers only ever read two
     *  Settings.Global strings. */
    fun parsePrivateDnsMode(configured: String?, defaultMode: String?): PrivateDnsMode {
        fun clean(value: String?): String? = value?.trim()?.lowercase(java.util.Locale.ROOT)?.takeIf { it.isNotEmpty() }
        val resolved = clean(configured) ?: clean(defaultMode) ?: "opportunistic"
        return when (resolved) {
            "off" -> PrivateDnsMode.OFF
            "opportunistic" -> PrivateDnsMode.OPPORTUNISTIC
            "hostname" -> PrivateDnsMode.HOSTNAME
            else -> PrivateDnsMode.UNKNOWN // a garbage value is never evidence of off
        }
    }

    /** Guest path where the pinned Debian multiarch NSS modules live. */
    const val GUEST_NSS_MODULE_PATH = "/usr/lib/aarch64-linux-gnu/libnss_floe.so.2"

    /** Frozen protocol value: the private per-work socket directory is
     *  bind-mounted here; the listener socket is `<dir>/s`
     *  (PROTOCOL.json guestSocketPath "/run/floe-dns/s"). */
    const val GUEST_SOCKET_DIR_PATH = "/run/floe-dns"

    /** Always replaced with an owned file: the guest must never see the
     *  base image's baked systemd-resolved stub configuration. */
    const val GUEST_RESOLV_PATH = "/etc/resolv.conf"

    /** Bridged NSS override: `files floe` with NO `dns` fallback (Main
     *  review). If the helper or bridge fails, resolution stops truthfully;
     *  there is deliberately no plaintext res_query tail that a stale or
     *  third-party loopback listener could answer. Ordinary libc
     *  getaddrinfo traffic is covered (Python, Node `dns.lookup`/default
     *  resolution, curl/openssl SNI path, apt/pip/npm install). Libraries
     *  that bypass NSS with their own resolvers (Node `dns.resolve*`,
     *  dnspython, dig, unbound tools) then hit only the explicit dead
     *  marker below and fail honest — never a plaintext real-server path. */
    fun nsswitchOverrideText(): String =
        "# floe-runtime nsswitch override (bridged system resolver)\n" +
        "passwd:         files\n" +
        "group:          files\n" +
        "shadow:         files\n" +
        "gshadow:        files\n" +
        "\n" +
        "hosts:          files floe\n" +
        "networks:       files\n" +
        "\n" +
        "protocols:      db files\n" +
        "services:       db files\n" +
        "ethers:         db files\n" +
        "rpc:            db files\n" +
        "\n" +
        "netgroup:       nis\n"

    fun decide(inputs: ResolverInputs): ResolverDecision {
        // 1. Preferred: the authenticated bridge whenever it is capable.
        //    This includes offline moments: DnsResolver forwards fail
        //    truthfully with no network and recover automatically when the
        //    change monitor observes the next real network.
        if (inputs.bridgeCapable) {
            val reason = when {
                !inputs.activeNetworkPresent ->
                    "bridged via system DnsResolver; offline now, live transitions need no rewrite"
                inputs.privateDnsMode == PrivateDnsMode.HOSTNAME || inputs.effectivePrivateDns == true ->
                    "bridged via system DnsResolver; private DNS path in effect"
                inputs.effectivePrivateDns == false ->
                    "bridged via system DnsResolver; live-correct preferred path"
                else -> "bridged via system DnsResolver; private DNS state not verifiable directly"
            }
            return bridged(reason)
        }

        val servers = normalizeServers(inputs.systemDnsServers)
        if (!inputs.activeNetworkPresent) {
            return marker(
                ResolverState.UNAVAILABLE_OFFLINE,
                "offline with no bridge capability; local commands remain runnable",
            )
        }

        // 2. Non-bridgeable fallbacks below (API 28 devices, or a device
        //    where the signed helper is not yet installed/verified).
        val hostnameIntent = inputs.privateDnsMode == PrivateDnsMode.HOSTNAME
        val effectivePrivate = hostnameIntent || inputs.effectivePrivateDns == true
        // Plaintext is authorized ONLY by facts: the network itself reports
        // it is not on the private path, or the setting is an explicit off.
        val plaintextAuthorized = !effectivePrivate &&
            (inputs.effectivePrivateDns == false || inputs.privateDnsMode == PrivateDnsMode.OFF)

        if (servers.all { isLoopbackLiteral(it) } && servers.isNotEmpty()) {
            // netd's own DNS-proxy listener shape. It applies the current
            // PrivateDNS state live; verify it answers glibc-style UDP from
            // our UID before committing it (some variants do not).
            return when {
                inputs.tunnelProbe == TunnelProbe.REACHABLE ->
                    direct(ResolverState.SYSTEM_TUNNEL, servers,
                        "system DNS proxy listener verified reachable for guest traffic")
                effectivePrivate || !plaintextAuthorized -> marker(ResolverState.UNAVAILABLE_UNSUPPORTED,
                    "private DNS listener not reachable/verifiable from guest and no bridge capability")
                else -> marker(ResolverState.UNAVAILABLE_OFFLINE,
                    "system reported only unverifiable DNS-proxy listener addresses with no bridge capability")
            }
        }

        if (servers.isEmpty()) {
            return if (effectivePrivate || !plaintextAuthorized) {
                marker(ResolverState.UNAVAILABLE_UNSUPPORTED,
                    "private DNS effective/unknown with no server literals and no bridge capability")
            } else {
                marker(ResolverState.UNAVAILABLE_OFFLINE,
                    "network reported no usable resolver addresses")
            }
        }

        // 3. Real (non-loopback) servers. Their presence says NOTHING about
        //    the private path (Main review): trust only the effective facts.
        return when {
            plaintextAuthorized -> direct(ResolverState.SYSTEM_DIRECT, servers,
                when {
                    inputs.effectivePrivateDns == false ->
                        "active network reports isPrivateDnsActive=false; using its configured servers"
                    else -> "private_dns_mode explicitly off; using system-configured servers"
                })
            else -> marker(ResolverState.UNAVAILABLE_UNSUPPORTED,
                "private DNS effective/unknown with no bridge-capable guest path")
        }
    }

    /** Owned file plan for one session. [bridgeSocketDir] is the private
     *  per-work 0700 host directory the runtime binds (only for BRIDGED;
     *  the guest sees `<socketGuestPath>/s`). */
    fun ownedFilePlan(decision: ResolverDecision): OwnedResolverPlan {
        val files = mutableListOf(
            OwnedResolverFile("resolv.conf", decision.resolvConfText, GUEST_RESOLV_PATH),
        )
        if (decision.state == ResolverState.BRIDGED) {
            files += OwnedResolverFile("nsswitch.conf", nsswitchOverrideText(), "/etc/nsswitch.conf")
            return OwnedResolverPlan(files, requiresHelperModule = true,
                helperGuestPath = GUEST_NSS_MODULE_PATH, socketGuestPath = GUEST_SOCKET_DIR_PATH)
        }
        return OwnedResolverPlan(files, requiresHelperModule = false,
            helperGuestPath = null, socketGuestPath = null)
    }

    /** Strict IPv4/IPv6 numeric literals only (glibc resolv.conf has no
     *  hostname and no zone-ID support). Drops zones/link-scoped forms,
     *  duplicates, and anything past the first [MAX_NAMESERVERS]. */
    fun normalizeServers(raw: List<String>): List<String> =
        raw.asSequence().mapNotNull { literalWithoutZone(it) }
            .filter { isIPv4Literal(it) || isIPv6Literal(it) }
            .distinct().take(MAX_NAMESERVERS).toList()

    private fun literalWithoutZone(value: String): String? {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return null
        val withoutZone = trimmed.substringBefore('%') // fe80::1%wlan0 is unusable in resolv.conf
        if (withoutZone.startsWith("fe80:") || withoutZone.startsWith("FE80:")) {
            return null // link-local without a zone can never be answered
        }
        if (withoutZone.length > 128) return null
        return withoutZone
    }

    fun isLoopbackLiteral(address: String): Boolean =
        (isIPv4Literal(address) && address.startsWith("127.")) ||
            address == "::1" || address.equals("0:0:0:0:0:0:0:1", ignoreCase = true)

    fun isIPv4Literal(address: String): Boolean {
        val parts = address.split('.')
        if (parts.size != 4) return false
        return parts.all { part ->
            part.isNotEmpty() && part.length <= 3 && part.all { it.isDigit() } &&
                part.toInt() in 0..255 && (part == "0" || !part.startsWith("0"))
        }
    }

    /** Full-form or single `::`-compressed IPv6 with an optional trailing
     *  embedded IPv4 tail. No zone IDs, no brackets, no partial forms. */
    fun isIPv6Literal(address: String): Boolean {
        if (address.isEmpty() || address.length > 45 || '%' in address) return false
        val lastColon = address.lastIndexOf(':')
        if (lastColon == -1) return false
        val tail = address.substring(lastColon + 1)
        val normalized: String = if (tail.contains('.')) {
            if (!isIPv4Literal(tail)) return false
            val octets = tail.split('.').map { it.toInt() }
            val hi = (octets[0] shl 8) or octets[1]
            val lo = (octets[2] shl 8) or octets[3]
            address.substring(0, lastColon + 1) +
                Integer.toHexString(hi) + ':' + Integer.toHexString(lo)
        } else address
        val parts = normalized.split("::")
        if (parts.size > 2) return false
        val groups: List<String>
        if (parts.size == 2) {
            val left = if (parts[0].isEmpty()) emptyList() else parts[0].split(':')
            val right = if (parts[1].isEmpty()) emptyList() else parts[1].split(':')
            if (left.any { it.isEmpty() } || right.any { it.isEmpty() }) return false
            if (left.size + right.size > 7) return false // "::" must replace >= one group
            groups = left + right
        } else {
            groups = normalized.split(':')
            if (groups.size != 8) return false
            if (groups.any { it.isEmpty() }) return false
        }
        return groups.all { it.length in 1..4 && it.all(::isHexDigit) }
    }

    private fun isHexDigit(c: Char): Boolean =
        c.isDigit() || c in 'a'..'f' || c in 'A'..'F'

    private fun direct(state: ResolverState, servers: List<String>, note: String): ResolverDecision {
        val text = buildString {
            append("# floe-runtime resolver: ").append(state.name.lowercase()).append('\n')
            for (server in servers) append("nameserver ").append(server).append('\n')
            append("options timeout:2 attempts:1\n")
        }
        require(text.toByteArray(Charsets.US_ASCII).size <= MAX_RESOLV_BYTES) { "resolver text unbounded" }
        return ResolverDecision(state, text, servers, overrideNsswitch = false,
            bridgeRequested = false, diagnostic = note)
    }

    private fun bridged(note: String): ResolverDecision {
        val text = buildString {
            append("# floe-runtime resolver: bridged via owned system-resolver bridge\n")
            append("nameserver 127.0.0.1\n") // dead marker: the NSS override has no `dns` tail;
            append("options timeout:1 attempts:1\n") // direct-resolver libraries fail honest here
        }
        require(text.toByteArray(Charsets.US_ASCII).size <= MAX_RESOLV_BYTES) { "resolver text unbounded" }
        return ResolverDecision(ResolverState.BRIDGED, text,
            nameservers = listOf("127.0.0.1"), overrideNsswitch = true,
            bridgeRequested = true, diagnostic = note)
    }

    private fun marker(state: ResolverState, note: String): ResolverDecision {
        val text = buildString {
            append("# floe-runtime resolver: ").append(state.name.lowercase())
                .append(" - no resolver available; local commands remain runnable\n")
            append("nameserver 127.0.0.1\n") // nothing binds loopback:53; queries fail fast and truthfully
            append("options timeout:1 attempts:1\n")
        }
        require(text.toByteArray(Charsets.US_ASCII).size <= MAX_RESOLV_BYTES) { "resolver text unbounded" }
        return ResolverDecision(state, text, nameservers = emptyList(), overrideNsswitch = false,
            bridgeRequested = false, diagnostic = note)
    }
}
