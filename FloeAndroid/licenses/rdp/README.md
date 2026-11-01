# C05 RDP native licences and pins

This directory records the exact upstream licences and release pins for the
real Android RDP backend. The dependency build recipe and its preflight
verifier live in `scripts/rdp/`.

| Component | Release | License | Pin |
| --- | --- | --- | --- |
| FreeRDP (includes WinPR) | 3.31.1 | Apache-2.0 | `runtime.lock.json`; SHA-256 `4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991` |
| OpenSSL | 4.0.1 | Apache-2.0 | `runtime.lock.json`; SHA-256 `2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09` |

* `FreeRDP-LICENSE` is the upstream `LICENSE` from the exact 3.31.1 release
  tarball. WinPR is part of that release and carries the same licence.
* `OpenSSL-LICENSE` is the upstream `LICENSE.txt` at tag `openssl-4.0.1`.
* The Floe bridge (`shared/Sources/FloeRDPNative`) is MPL-2.0 and is the only
  authored native code in the RDP path.

The source pin matches the fixed iOS donor (`FloeAgent/ThirdParty/FreeRDP` at
`a59b4d4005f616c611df67fab7620e9853c525b9`). Android consumes only the
independently built ARM64 static archives; no Apple binary or framework is
copied or relinked.

The prefix and its manifest are build products and are not committed. A
missing prefix is a build error, never a reason to substitute a different
protocol implementation.
