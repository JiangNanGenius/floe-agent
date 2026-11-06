# Floe Citadel library slice

Upstream `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`, MIT license retained byte-for-byte. Package.swift and all selected upstream Sources/Tests are unmodified and checked against Git blob IDs at the exact pin. Root examples/docs/CI/docker and upstream lock are omitted; no executable binary or downloaded driver is included.

The only runtime addition is Sources/Citadel/FloeFileChannels.swift: dedicated no-PTY SFTP/SCP children on the existing authenticated client, deadline/cancellation and child-only close. It does not replace encryption, credentials, host-key checking or reconnect ownership. Source pin/archive/tree and complete upstream hashes are in PROVENANCE.json/UPSTREAM_SHA256SUMS. `python3 floe_vendor_check.py` is read-only.

Root Floe Package.resolved removes the obsolete remote Citadel row only; all other pins remain byte-identical. Do not patch any .build/SourcePackages/shared checkout.
