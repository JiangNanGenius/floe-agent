# idevice and selected transitive notices

Upstream idevice v0.1.68 remains pinned at `d32c8189c51c2789496b0768039419c3705498c3` under MIT. Floe's local bounded-DDI patch is maintained under the same license. `DEPENDENCIES.json` records the actual arm64 iOS normal dependency graph for the used features, package checksums and notice hashes. `dependencies/` retains the notices shipped by those crates; `rust-standard-library/` retains this Rust toolchain's standard-library notice set.

Two upstream crates, `plist-macro 0.1.6` and `plist_ffi 0.1.6`, declare MIT and Jackson Coxson as author in their published manifests but ship no separate notice file, including at the recorded upstream commit. Their `DECLARED-MIT.txt` explicitly records that source limitation and reproduces standard MIT permission text without inventing a year. Package and source commit hashes remain in the index for review.

The source recipe uses Rust 1.98.1, ring for TLS, and no aws-lc/OpenSSL backend. No downloaded DDI image, pairing record or signing identity is included. The App release owner must include this notice set in the distributable acknowledgements; source availability alone is not evidence of packaged notices.
