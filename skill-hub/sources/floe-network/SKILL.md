---
name: floe-network
display_name: Network Diagnostics
description: Device DNS and TCP diagnostics, host ICMP and traceroute, LAN discovery, HTTP and downloads.
---

## Network diagnostics workflow
- `network.dnsLookup` and `network.tcpProbe` run on the local device by default. Use TCP directly for a specific service port; ping is not a prerequisite and TCP is not ICMP.
- This build has no device ICMP or device traceroute implementation. `network.ping` returns deviceICMPUnavailable and `network.traceroute` returns deviceTracerouteUnavailable for device execution. Do not retry unchanged calls or report a simulated success. For a genuine remote probe, select executionTarget=host with a paired hostID only when the user wants that host as the source. A host probe does not measure the phone's network path.
- `network.scanLAN` enumerates the local network — run it only when the user asked for discovery or a LAN diagnostic.
- `network.http` issues raw HTTP with method/headers/body control subject to network policy. When the goal is **reading a web page as content**, use `web.fetch` instead (returns readable markdown). Use `network.download` to save an authorized URL to a workspace file.
- Credential URLs and cloud metadata endpoints are blocked; never try to bypass those blocks or exfiltrate instance metadata.