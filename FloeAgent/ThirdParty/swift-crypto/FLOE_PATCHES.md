# Floe Swift Crypto integration

Upstream: Apple Swift Crypto 3.15.1, revision `95ba0316a9b733e92bb6b071255ff46263bbe7dc`.
All upstream files and license notices are retained. `FLOE_UPSTREAM.json` records
the original file digests. No cryptographic implementation is modified.

The existing `Crypto` product is an explicit dynamic aggregate of the existing
`Crypto` and `_CryptoExtras` targets and their existing BoringSSL support targets.
The support targets are listed explicitly because Xcode otherwise drops their
objects from this product when CryptoKit makes the first target's support edges
conditional on non-Apple platforms. Floe's Citadel consumes this single product;
its module imports remain unchanged. Xcode 27.2 otherwise builds both an automatic
Crypto product wrapper and a separate Crypto target framework when the App and
hosted tests share dependencies. They contain duplicate Swift type metadata and
share a bundle identifier, so the Simulator refuses installation. One aggregate
preserves a single runtime identity without changing bundle identifiers or pins.

The original `_CryptoExtras` product remains available for unrelated upstream
clients. It is not a separate product in Floe's App dependency closure. The root
package and Xcode project use this maintained copy of the same pinned source.
