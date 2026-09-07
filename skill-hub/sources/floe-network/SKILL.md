---
name: floe-network
display_name: Network Diagnostics
description: Ping, traceroute, DNS, LAN scan and raw HTTP with the right boundary versus web.fetch.
---

## Network diagnostics workflow
- `network.ping`, `network.traceroute`, `network.dnsLookup` diagnose reachability on the **local device** by default; pass a paired `hostID` only when the user wants the probe run from that remote host.
- `network.scanLAN` enumerates the local network — run it only when the user asked for discovery or a LAN diagnostic.
- `network.http` issues raw HTTP with method/headers/body control subject to network policy. When the goal is **reading a web page as content**, use `web.fetch` instead (returns readable markdown). Use `network.download` to save an authorized URL to a workspace file.
- Credential URLs and cloud metadata endpoints are blocked; never try to bypass those blocks or exfiltrate instance metadata.