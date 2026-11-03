# Pinned NetBare forwarding subset

This module contains only the reviewed IPv4 TCP/UDP forwarding core from
`MegatronKing/NetBare-Android`, revision
`df5b417ea663763932cabf1ef52f15b09ddc2e16` (2020-03-02).

`UPSTREAM.json` records the exact upstream and vendored paths, byte counts,
SHA-256 hashes and the local patch list. `LICENSE` is the upstream MIT license.
The upstream source file headers still contain GPLv3 text; both notices are
retained and the exact source is kept in this repository. That conflict is
flagged to Main and is not silently reinterpreted.

The HTTP/SSL injection, UID dumper, sample app, service/base classes, support
library, Guava, BouncyCastle and prebuilt JNI are absent. The App host owns the
VpnService lifecycle, notification, state machine, PCAP sink and capture
artifacts. No other NetBare code is loaded from Maven, JCenter or a binary.
