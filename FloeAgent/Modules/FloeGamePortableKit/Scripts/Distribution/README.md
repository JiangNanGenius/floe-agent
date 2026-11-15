# Distribution profile

`distribution-lock.json` is the machine-readable exact-source receipt for the
LÖVE/love.js, Ren'Py Web and RPG Maker MV prepared resources. It records:

- pin revisions, artifact/npm/official-zip hashes and prepared-manifest hashes;
- every runtime file hash and every notice hash;
- exact-source packages, LGPL components, linking mode and relink documents;
- eligibility, conditions, the Apple/WebKit assessment and source-offer rules.

`check_distribution.py` is the read-only preflight. It verifies the receipt,
pins, prepared manifests, every runtime file, every notice, every source
package, the LGPL source/relink records and MPL-2.0 hygiene. It never writes,
downloads or executes downloaded code.

Run it from the kit root:

```sh
python3 Scripts/Distribution/check_distribution.py \
  --kit . --resources ../resources --notices ../notices \
  --source-root <exact-source-depot>
```

The source depot is not embedded in the kit. The default is
`<kit>/../source-packages`; use `--source-root` for the external depot. The
checker rejects absolute paths, `..` traversal, empty components, backslashes,
NUL/control characters and symlink components under every declared root.

`patches/love/` contains the persistence provenance: Root's authoritative
`Module.floePrepareToStop` generated-loader patch record is referenced in the
lock; `EmscriptenPersistence.js.patch` is an alternative source-level
reference, and `floe-persist.js` is an optional stopgap overlay. The unpatched
upstream loader is not durable across a new player; Root's patched candidate
passed actual native WebKit cross-player save with unchanged
`love.wasm`/`game.data`.

Apple/WebKit summary: bundling is not automatic approval and an unbundled
Web/WASM runtime is not automatic prohibition. The release owner must classify
the actual Floe IDE/developer flow and ensure the final delivery satisfies the
applicable guideline conditions. This package is not legal advice and does not
claim App Store approval.
