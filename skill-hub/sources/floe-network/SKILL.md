---
name: floe-network
display_name: Network Diagnostics
description: Device DNS, TCP, ICMP ping and traceroute diagnostics, LAN discovery, HTTP and downloads.
---

## Network diagnostics workflow
- `network.ping`, `network.traceroute`, `network.dnsLookup` and `network.tcpProbe` run from this device only; they never require an SSH host. Use TCP directly for a specific service port; ping is not a prerequisite and TCP is not ICMP.
- `network.ping` runs a genuine bounded ICMP echo (datagram ICMP socket, 1-10 probes at a 1s interval, per-reply RTT with min/avg/max and loss summary). `network.traceroute` runs a genuine ICMP traceroute (increasing IP TTL, two probes per hop, numeric per-hop addresses and RTTs). Both are IPv4. Do not retry unchanged calls or report a simulated success.
- `network.scanLAN` enumerates the local network — run it only when the user asked for discovery or a LAN diagnostic.
- `network.http` issues raw HTTP with method/headers/body control subject to network policy. When the goal is **reading a web page as content**, use `web.fetch` instead (returns readable markdown). Use `network.download` to save an authorized URL to a workspace file.
- Credential URLs and cloud metadata endpoints are blocked; never try to bypass those blocks or exfiltrate instance metadata.
