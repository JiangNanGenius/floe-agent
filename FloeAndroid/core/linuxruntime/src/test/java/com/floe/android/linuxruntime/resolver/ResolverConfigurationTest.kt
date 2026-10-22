// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.resolver

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The guest resolver state machine (Main-reviewed semantics): the actual
 * effective PrivateDNS facts drive every outcome; the authenticated bridge
 * is preferred whenever capable; direct configurations exist only as
 * fact-authorized fallbacks; no invented resolvers, no base-image
 * fall-through, no address-shape inference, truthful fail-closed.
 */
class ResolverConfigurationTest {

    private fun inputs(
        sdk: Int = 33,
        mode: PrivateDnsMode = PrivateDnsMode.OFF,
        effective: Boolean? = null,
        active: Boolean = true,
        servers: List<String> = emptyList(),
        api: Boolean = false, // default: NO bridge capability, exercise fallbacks
        helper: Boolean = false,
        probe: TunnelProbe = TunnelProbe.NOT_RUN,
    ) = ResolverInputs(sdk, mode, effective, active, servers, api, helper, probe)

    private val bridge = inputs(api = true, helper = true)

    // MARK: AOSP settings chain (Main primary source)

    @Test
    fun modeParserFollowsAospValueChain() {
        assertEquals(PrivateDnsMode.OFF,
            ResolverConfiguration.parsePrivateDnsMode("off", null))
        assertEquals(PrivateDnsMode.OPPORTUNISTIC,
            ResolverConfiguration.parsePrivateDnsMode("opportunistic", "off"))
        assertEquals(PrivateDnsMode.HOSTNAME,
            ResolverConfiguration.parsePrivateDnsMode("hostname", "off"))
        // Empty mode resolves the default; empty default is "opportunistic".
        assertEquals(PrivateDnsMode.OFF,
            ResolverConfiguration.parsePrivateDnsMode("", "off"))
        assertEquals(PrivateDnsMode.OPPORTUNISTIC,
            ResolverConfiguration.parsePrivateDnsMode(null, null))
        assertEquals(PrivateDnsMode.OPPORTUNISTIC,
            ResolverConfiguration.parsePrivateDnsMode("  ", ""))
        // Garbage never means off.
        assertEquals(PrivateDnsMode.UNKNOWN,
            ResolverConfiguration.parsePrivateDnsMode("strict", null))
        assertEquals(PrivateDnsMode.UNKNOWN,
            ResolverConfiguration.parsePrivateDnsMode("opportunity", null))
    }

    // MARK: bridge preference

    @Test
    fun bridgePreferredForEverySessionWhenCapable() {
        val cases = listOf(
            bridge,
            bridge.copy(privateDnsMode = PrivateDnsMode.HOSTNAME, effectivePrivateDns = true,
                systemDnsServers = listOf("127.0.0.53"), tunnelProbe = TunnelProbe.REACHABLE),
            bridge.copy(privateDnsMode = PrivateDnsMode.OFF, effectivePrivateDns = false,
                systemDnsServers = listOf("192.168.1.1")),
            bridge.copy(privateDnsMode = PrivateDnsMode.UNKNOWN, activeNetworkPresent = false),
            bridge.copy(systemDnsServers = emptyList(), activeNetworkPresent = true),
        )
        for (case in cases) {
            val decision = ResolverConfiguration.decide(case)
            assertEquals(case.privateDnsMode.toString(), ResolverState.BRIDGED, decision.state)
            assertTrue(decision.bridgeRequested)
            assertTrue(decision.overrideNsswitch)
        }
    }

    @Test
    fun bridgedCommittedConfigIsTheDeadMarkerOnly() {
        val decision = ResolverConfiguration.decide(bridge.copy(
            privateDnsMode = PrivateDnsMode.HOSTNAME, effectivePrivateDns = true,
            systemDnsServers = listOf("1.2.3.4")))
        // The bridge path never bakes real servers into resolv.conf: the
        // NSS override has no `dns` tail, so the marker is only read by
        // direct-resolver libraries, which must fail honest.
        assertEquals(listOf("127.0.0.1"), decision.nameservers)
        assertFalse(decision.resolvConfText.contains("1.2.3.4"))
    }

    // MARK: validation & bounds

    @Test
    fun numericLiteralsOnlyAndBoundedToGlibcThreeServers() {
        val normalized = ResolverConfiguration.normalizeServers(
            listOf("10.0.0.1", "10.0.0.1", "dns.google", "10.0.0.2", "10.0.0.3", "10.0.0.4"))
        assertEquals(listOf("10.0.0.1", "10.0.0.2", "10.0.0.3"), normalized)
    }

    @Test
    fun zoneAndLinkLocalAndGarbageAreDropped() {
        assertEquals(emptyList<String>(), ResolverConfiguration.normalizeServers(
            listOf("fe80::1%wlan0", "8.8.8.8:5353", " 1.2.3.4.5 ", "01.2.3.4", "-1.0.0.0")))
        assertEquals(listOf("2001:db8::192.168.1.1"), ResolverConfiguration.normalizeServers(
            listOf("2001:db8::192.168.1.1")))
    }

    @Test
    fun ipv6LiteralGrammar() {
        for (ok in listOf("::", "::1", "fe80::", "2001:db8::1", "0:0:0:0:0:0:0:1",
            "::ffff:127.0.0.1", "2001:0db8:85a3:0000:0000:8a2e:0370:7334", "1:2:3:4:5:6:7:8")) {
            assertTrue("accept $ok", ResolverConfiguration.isIPv6Literal(ok))
        }
        for (bad in listOf("12345::1", "1:2:3:4:5:6:7", "1::2::3", ":::", "1.2.3.4",
            "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:1.2.3", "2001:db8::192.168.1.1%eth0",
            " 2001:db8::1", "")) {
            assertFalse("reject $bad", ResolverConfiguration.isIPv6Literal(bad))
        }
    }

    @Test
    fun loopbackShapesCoverNetdProxyRanges() {
        assertTrue(ResolverConfiguration.isLoopbackLiteral("127.0.0.53"))
        assertTrue(ResolverConfiguration.isLoopbackLiteral("127.5.6.7"))
        assertTrue(ResolverConfiguration.isLoopbackLiteral("::1"))
        assertTrue(ResolverConfiguration.isLoopbackLiteral("0:0:0:0:0:0:0:1"))
        assertFalse(ResolverConfiguration.isLoopbackLiteral("192.168.1.1"))
    }

    // MARK: offline / empty states are explicit, never null

    @Test
    fun offlineWithoutBridgeStillProducesOwnedExplicitConfiguration() {
        val decision = ResolverConfiguration.decide(inputs(active = false,
            mode = PrivateDnsMode.HOSTNAME, effective = true, servers = listOf("127.0.0.53")))
        assertEquals(ResolverState.UNAVAILABLE_OFFLINE, decision.state)
        assertTrue(decision.resolvConfText.contains("nameserver 127.0.0.1"))
        assertFalse(decision.bridgeRequested)
        assertFalse(decision.resolvConfText.contains("127.0.0.53"))
    }

    @Test
    fun activeNetworkWithoutUsableServersIsFailClosed() {
        val decision = ResolverConfiguration.decide(inputs(mode = PrivateDnsMode.OFF,
            effective = false, servers = listOf("dns.example.com")))
        assertEquals(ResolverState.UNAVAILABLE_OFFLINE, decision.state)
        assertTrue(decision.resolvConfText.isNotEmpty())
    }

    // MARK: plaintext only by FACTS, never by address shape (Main review)

    @Test
    fun explicitOffOrVerifiedInactiveAuthorizeDirectSystemServers() {
        val off = ResolverConfiguration.decide(inputs(mode = PrivateDnsMode.OFF,
            servers = listOf("192.168.1.1", "fd00::dead")))
        assertEquals(ResolverState.SYSTEM_DIRECT, off.state)
        assertEquals(listOf("192.168.1.1", "fd00::dead"), off.nameservers)
        val verifiedInactive = ResolverConfiguration.decide(inputs(
            mode = PrivateDnsMode.OPPORTUNISTIC, effective = false, servers = listOf("10.0.0.53")))
        assertEquals(ResolverState.SYSTEM_DIRECT, verifiedInactive.state)
        val unknownButReadFalse = ResolverConfiguration.decide(inputs(
            mode = PrivateDnsMode.UNKNOWN, effective = false, servers = listOf("172.16.0.1")))
        assertEquals(ResolverState.SYSTEM_DIRECT, unknownButReadFalse.state)
    }

    @Test
    fun realServersNeverAuthorizeDirectWhenPrivateStateIsUnverified() {
        // Main's correction: OPPORTUNISTIC/UNKNOWN with a null effective
        // read must NOT fall through SYSTEM_DIRECT.
        for (mode in listOf(PrivateDnsMode.OPPORTUNISTIC, PrivateDnsMode.UNKNOWN)) {
            val decision = ResolverConfiguration.decide(inputs(mode = mode,
                effective = null, servers = listOf("1.2.3.4")))
            assertEquals("$mode", ResolverState.UNAVAILABLE_UNSUPPORTED, decision.state)
            assertFalse(decision.resolvConfText.contains("1.2.3.4"))
        }
    }

    @Test
    fun effectiveFactsOutrankSettingsIntent() {
        // Network reports the private path IS active even though the
        // settings string says off: never plaintext.
        val leaked = ResolverConfiguration.decide(inputs(mode = PrivateDnsMode.OFF,
            effective = true, servers = listOf("1.2.3.4")))
        assertEquals(ResolverState.UNAVAILABLE_UNSUPPORTED, leaked.state)
        // "hostname" intent outranks a fallback report of inactive.
        val hostname = ResolverConfiguration.decide(inputs(mode = PrivateDnsMode.HOSTNAME,
            effective = false, servers = listOf("1.2.3.4")))
        assertEquals(ResolverState.UNAVAILABLE_UNSUPPORTED, hostname.state)
    }

    @Test
    fun systemTunnelRequiresVerifiedReachableListener() {
        val reachable = ResolverConfiguration.decide(inputs(mode = PrivateDnsMode.HOSTNAME,
            effective = true, servers = listOf("127.0.0.53", "::1"),
            probe = TunnelProbe.REACHABLE))
        assertEquals(ResolverState.SYSTEM_TUNNEL, reachable.state)
        assertEquals(listOf("127.0.0.53", "::1"), reachable.nameservers)
        for (probe in listOf(TunnelProbe.UNREACHABLE, TunnelProbe.REFUSED, TunnelProbe.NOT_RUN)) {
            val decision = ResolverConfiguration.decide(inputs(mode = PrivateDnsMode.HOSTNAME,
                effective = true, servers = listOf("127.0.0.53"), probe = probe))
            assertEquals(probe.toString(), ResolverState.UNAVAILABLE_UNSUPPORTED, decision.state)
        }
        val offPlainUnverified = ResolverConfiguration.decide(inputs(mode = PrivateDnsMode.OFF,
            effective = false, servers = listOf("127.0.0.53"), probe = TunnelProbe.UNREACHABLE))
        assertEquals(ResolverState.UNAVAILABLE_OFFLINE, offPlainUnverified.state)
    }

    @Test
    fun emptyServersAreExplicitMarkers() {
        val private = ResolverConfiguration.decide(inputs(mode = PrivateDnsMode.HOSTNAME,
            effective = true, servers = emptyList()))
        assertEquals(ResolverState.UNAVAILABLE_UNSUPPORTED, private.state)
        val off = ResolverConfiguration.decide(inputs(mode = PrivateDnsMode.OFF,
            effective = false, servers = emptyList()))
        assertEquals(ResolverState.UNAVAILABLE_OFFLINE, off.state)
    }

    // MARK: generation never invents public resolvers

    @Test
    fun noPublicAnchorResolverEverAppears() {
        val forbidden = listOf("8.8.8.8", "8.8.4.4", "1.1.1.1", "9.9.9.9", "google",
            "cloudflare", "quad9")
        val cases = listOf(
            inputs(active = false),
            inputs(servers = listOf("10.0.0.1"), effective = false),
            bridge.copy(systemDnsServers = listOf("10.0.0.1"), effectivePrivateDns = false),
            inputs(mode = PrivateDnsMode.HOSTNAME, effective = true, servers = listOf("127.0.0.53")),
            inputs(mode = PrivateDnsMode.HOSTNAME, effective = true, servers = emptyList()),
            inputs(mode = PrivateDnsMode.UNKNOWN, servers = emptyList()),
        )
        for (case in cases) {
            val decision = ResolverConfiguration.decide(case)
            val text = decision.resolvConfText + "\n" + decision.diagnostic
            for (needle in forbidden) {
                assertFalse("case ${case.privateDnsMode} leaks $needle", text.contains(needle))
            }
        }
    }

    @Test
    fun resolvTextIsGlibcCompatibleAndBounded() {
        for (case in listOf(
            inputs(active = false),
            inputs(servers = (1..8).map { "10.0.0.$it" }, effective = false),
            inputs(mode = PrivateDnsMode.HOSTNAME, effective = true, servers = listOf("2001:db8::1")),
            bridge.copy(systemDnsServers = listOf("127.0.0.53")),
        )) {
            val decision = ResolverConfiguration.decide(case)
            assertTrue(decision.resolvConfText.toByteArray(Charsets.UTF_8).size <=
                ResolverConfiguration.MAX_RESOLV_BYTES)
            for (line in decision.resolvConfText.lines().filter { it.isNotBlank() }) {
                assertTrue("bad line: $line",
                    line.startsWith("#") || line.startsWith("nameserver ") ||
                        line.startsWith("options "))
                // glibc <= 2.36: nameserver takes exactly one numeric
                // token, options only uses the verified timeout/attempts
                // pair; no port-bearing syntax exists that could be
                // silently assumed (Main's port-53 bind floor evidence).
                if (line.startsWith("nameserver ")) {
                    val address = line.removePrefix("nameserver ")
                    assertFalse(address, address.contains(' '))
                    assertTrue(address, ResolverConfiguration.isIPv4Literal(address) ||
                        ResolverConfiguration.isIPv6Literal(address))
                    assertFalse(address, address.contains('%'))
                }
                if (line.startsWith("options ")) {
                    for (token in line.removePrefix("options ").split(' ')) {
                        assertTrue("options token $token",
                            token in setOf("timeout:1", "timeout:2", "attempts:1", "attempts:2"))
                    }
                }
            }
        }
    }

    @Test
    fun nsswitchOverrideIsDeliberateAndNonLeaking() {
        val text = ResolverConfiguration.nsswitchOverrideText()
        // No `dns` tail: helper/bridge failure stops resolution truthfully
        // instead of falling through to a raw res_query an unknown loopback
        // listener could answer (Main review).
        assertTrue(text.contains("hosts:          files floe\n"))
        assertFalse(Regex("hosts:.*\\bdns\\b").containsMatchIn(text))
        assertTrue(text.contains("passwd:         files"))
    }

    // MARK: owned file plan

    @Test
    fun planShapeMatchesState() {
        val bridged = ResolverConfiguration.decide(bridge.copy(systemDnsServers = listOf("1.2.3.4")))
        val plan = ResolverConfiguration.ownedFilePlan(bridged)
        assertEquals(2, plan.files.size)
        assertTrue(plan.requiresHelperModule)
        assertEquals(ResolverConfiguration.GUEST_NSS_MODULE_PATH, plan.helperGuestPath)
        assertEquals(ResolverConfiguration.GUEST_SOCKET_DIR_PATH, plan.socketGuestPath)
        assertTrue(plan.files.any { it.scratchName == "nsswitch.conf" })
        assertTrue(plan.files.any { it.scratchName == "resolv.conf" })

        val direct = ResolverConfiguration.decide(inputs(servers = listOf("10.0.0.1"),
            mode = PrivateDnsMode.OFF, effective = false))
        val directPlan = ResolverConfiguration.ownedFilePlan(direct)
        assertEquals(1, directPlan.files.size)
        assertEquals("resolv.conf", directPlan.files.single().scratchName)
        assertFalse(directPlan.requiresHelperModule)
        assertEquals(null, directPlan.socketGuestPath)
    }

    @Test
    fun failClosedMarkersStillProduceSingleOwnedResolvFile() {
        for (case in listOf(
            inputs(active = false),
            inputs(mode = PrivateDnsMode.HOSTNAME, effective = true, servers = listOf("1.2.3.4")),
            inputs(mode = PrivateDnsMode.UNKNOWN, servers = emptyList()),
        )) {
            val plan = ResolverConfiguration.ownedFilePlan(ResolverConfiguration.decide(case))
            assertEquals(1, plan.files.size)
            assertFalse(plan.requiresHelperModule)
        }
    }
}
