# Impeccable A2 native producer — provenance and licenses

Frozen contract: `floe.impeccable.snapshot` v1 (`schemaStatus: frozen-v1`).
Contract authority: Floe Skill Hub `engines/impeccable/contract/` at hub commit
`156214d364baa8b575e1755a74d223d7b4ce34a7` (32-file SHA list in
`evidence/contract-SHA256SUMS.txt`; `tools/validate_fixtures.py` 61/61 checks, exit 0).
Early handoff: `floe.impeccable.snapshot` decision "implement now"; engine goldens,
the riscv64 binary and the launcher remain **pending** in the H3 engine lane and are
not claimed by anything in this directory.

## Upstream pin (single deliberate pin, no mixed bytes)

| Field | Value |
| --- | --- |
| Upstream project | `pbakaus/impeccable` |
| Pinned commit | `4fc2f83e1c8710dba772bfd4523d0efab57737b6` |
| Pinned tree | `1363fadfb2141db1cf22b4ba171d6fc4dbf5cd72` |
| Engine version | `0.1.17` (upstream package/skill version `4.7.1`, distinct) |
| Pin authority | hub `docs/UPSTREAM-PINS.json`, review baseline 2026-10-26 |
| License | Apache-2.0 — text in `UPSTREAM-LICENSE.txt` (retained unmodified) |

The checkpoint clone HEAD `936867543ac2576920d663cc9803597f6044f3ac` is a verified
ancestor with the same engine version and is **not** the build pin.

## Files

- `impeccable-producer.v1.js` — the fixed native measurement producer.
  - The first **40,591 bytes** (indices `0…40590` inclusive) are the
    **complete, verbatim** upstream `browser-bundle/15-snapshot.js`: the pinned
    upstream file is itself exactly 40,591 bytes, so the embedded prefix and the
    full upstream file are byte-identical, and sha256
    `b97e055fa25eaba1186cee5174899be13efcfc82ab6c133e9306ed5791d3aef0` is the
    full-file digest of both (equal to the contract
    `provenance.pinnedSourceDigests` entry). The loader
    `pinnedUpstreamPrefixBytes = 40_591` and `producer-manifest.v1.json`
    (`upstreamPrefix.bytes: 40591`) use the same count; the loader re-hashes
    these bytes on every load.
  - The appended Floe adapter — the remaining 14,974 bytes (sha256 of the
    adapter part
     `4ce19da85104ee82820d624db562799f41ecfb9d9362779276bb4873dedfa791`) — adds: the
     frozen-v1 redaction policy executed **inside the isolated content world before
     any bytes leave it** (password inputs, form control values, credential-bearing
     attribute names, token-bearing URL values; per-category counts), the optional
     `floe{}` binding block, capture-scoped Needs `answer()` with an atomic
     scroll/viewport recheck (fence-or-refuse; never answers a moved page), a
     read-only `probe()` that reports the current CSS viewport/scroll and whether
     the world still holds the capture (measures no DOM, mutates nothing, used by
     native to refuse late results), the 138/23/31 column-parity self-check, and
     the Floe element/byte caps.
  - It removes nothing from the upstream bytes and never calls
    `__impeccableSnapshot.visualIO`: v1 has no pixel source, so `pixel-contrast`
    stays uncovered and can never be claimed covered.
  - Combined file sha256: `5bfbcee7edd70d40ee562eeefabe416c62d2f4ab8b9a48de5be7afebceb8a89f`
    (55,565 bytes).
- Native dispatch: the Swift loader appends exactly one fixed line
  `return globalThis.__floeImpeccable.dispatch(floeOp, floeArgs);` where `floeOp`
  and `floeArgs` are `callAsyncJavaScript` **argument values** (never code).
  `identity.producer.scriptDigest` binds the sha256 of the executed bytes:
  `34b245bc46bb50047dfe3f7a3b420137498a099a7b82b2734fca8e088176e5f9`.
  The runtime recomputes this from the actual loaded bytes and fails closed on any
  difference; the all-zero synthetic fixture digest is always rejected at real
  ingress.
- `contract-snapshot-contract.v1.json`, `snapshot.schema.v1.json`,
  `facts.schema.v1.json`, `identity.schema.v1.json`, `result.schema.v1.json`,
  `style-props.v1.json`, `pseudo-props.v1.json`, `state-pseudos.v1.json`,
  `capture-limits.v1.json` — copied verbatim from the frozen hub contract (no large
  source checkout is carried). Their sha256 values are recorded in
  `producer-manifest.v1.json` and revalidated at load time.
- `producer-manifest.v1.json` — machine-readable provenance for everything above.

## Privacy and capability guarantees

- `producerTrust` is the constant `native-fixed-script`; model- or page-declared
  trust is rejected by the identity schema and by native ingress validation.
- No arbitrary JS, no evaluation surface, no CDP endpoint, no network from the
  producer. Raw DOM/snapshot bodies are never logged; they exist only inside the
  task-owned bridge directory and are deleted with `cleanup(captureID:)` after the
  scan (fencing also refuses any later use).
- v1 coverage: six required passes are uncovered upstream, so the engine never
  certifies a page clean; native surfaces `inconclusive` with
  `coverage.uncoveredRequired` instead of a clean verdict. `style-parity` is only
  ever reported from the engine's own diagnostic — not claimed here.

Floe adapter code: MPL-2.0 unless stated (per contract §1); upstream Apache-2.0 text
retained alongside the combined producer.
