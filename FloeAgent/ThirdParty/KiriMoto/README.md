# Selected Kiri:Moto slicing sources

Pinned upstream: GridSpace/grid-apps 4.7.3, commit `ff7692241c48c3495da0bb8eb7455f906f3abb2d`. `PROVENANCE.json` records each selected source hash, its origin, runtime package versions and local patches. `UPSTREAM-LICENSE.md` and `LICENSES/` retain the applicable notices. Floe modifications use MPL-2.0 while preserving upstream MIT terms and notices.

The selected pipeline uses upstream FDM slice/prepare/export and CTB v3 raster/encoding. It includes MIT Three.js/three-mesh-bvh/QuickJS, ISC Earcut and Boost/JSBN geometry dependencies. `planegcs` (LGPL), manifold, fonts, whole application UI, PNGJS/JSZip prebundles and other resin encoders are not in this runtime closure. BuildInputs contains the original locked build environment; unused build dependencies in that lock are not runtime dependencies.

Local patches decouple UI-only preferences/snapshots, forward asynchronous slice failures, restrict the resin export route to CTB v3, remove the unused RSLA archive converter, and reserve raster memory above the pinned WASM's C stack/static region. The original low-memory raster writes overlapped the C `readoff` global at address 1024; independent layer decoding detected three stray pixels before the fix. Patches are retained in `Patches/`.

The internal QuickJS VM belongs to the upstream calculation pipeline. Public requests accept owned preset IDs and a small numeric override set; external project scripts, postprocessing templates and arbitrary G-code macros are rejected. No general interpreter tool is exposed.

Read-only verification, from repository root:

```sh
node --experimental-vm-modules FloeAgent/Qualification/Printing/Validation/audit-closure.mjs FloeAgent/ThirdParty/KiriMoto
```

Generated ESM bundles are already committed as source inputs for collection. To reproduce them, copy BuildInputs to a disposable directory, run `npm ci` there, retain the original `bin/` layout for its webpack input/config files and the `src/ext` output layout, then invoke the locked webpack with each configuration. Never rebuild or rewrite a lock in a read-only verification command. No npm install is required for the real slicing qualification runner.
