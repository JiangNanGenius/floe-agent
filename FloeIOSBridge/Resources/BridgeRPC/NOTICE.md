# Third-party notice — Bridge RPC

The Bridge RPC method registry, wire pairing/envelope contract and parts of the
operating-manual semantics are adapted from **OpenMinis/iCTRL**, commit
`c1e4268859ba858d1579f7b846a56cb40641b7f6` (v1.98.16), licensed under the
Apache License, Version 2.0. The full upstream license text is retained at
`LICENSE-iCTRL-Apache-2.0.txt`; the repository's existing copy is at
`FloeIOSBridge/ThirdParty/iCTRL/LICENSE`.

This package is an independent Swift implementation for Floe Bridge. It does
not import iCTRL's app, XCTest runner, private C surface, `NearbyAdvertiser`, or
its session servers. See `UPSTREAM_ADAPTATIONS.md` for the exact adapted
surfaces and the deliberately excluded parts.

The product names, icons and other Floe assets are not part of the upstream
license grant.
