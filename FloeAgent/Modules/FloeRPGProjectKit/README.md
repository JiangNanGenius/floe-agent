# FloeRPGProjectKit

Independent Swift 6 package for **actual RPG Maker data and project adapters**
on device: read, edit and write XP/VX/VX Ace binary data (`.rxdata` /
`.rvdata` / `.rvdata2`) and MV/MZ JSON data, over the shared GameKit
repository (CAS revisions), with adapters for the auxiliary native editors.

App/UI integration is coordinator-owned and deliberately separate. This
package contains no App wiring, no RGSS runtime and no Ruby interpreter.

## What is implemented

| Area | Behavior |
| --- | --- |
| Ruby Marshal 4.8 codec | Bounded pure-Swift reader/writer for the container used by XP/VX/VX Ace data files. Parses and re-serializes **byte-identically**: symbols/symbol links, object links and cycles, class/struct names, strings with encoding ivars (`:E`/`:encoding`), bignums, floats (text preserved), user-defined `_dump` payloads (`Table`, `Color`, `Tone`), user-marshal, regexp, extended wrappers and class/module objects |
| Bounded parsing | Version check, depth/node/byte limits, collection-size-vs-input checks, link/symbol index validation, truncated-stream errors; every malformed fixture rejects with `MarshalError` |
| Script archives | `Scripts.rxdata`/`.rvdata`/`.rvdata2` ⇄ ordered `[magic, title, zlib-source]` entries. zlib inflate/deflate with output bounds; unedited entries re-emit their original compressed bytes, so untouched archives round-trip byte-identically; order is preserved and editable |
| Binary database files | Actors/Classes/Skills/Items/Weapons/Armors/Enemies/Troops/States/Animations/Tilesets/System/CommonEvents access with unknown ivars preserved; record edits write back through the graph |
| Binary maps | `RPG::Map` tile access over the `Table` (3 layers for XP/VX/VX Ace), event positions, page command lists, unknown command payloads preserved |
| MV/MZ JSON | Standard raw-array database files (`[null, {...}]`) and object `System.json`; map `data` (4 tile layers + shadow/region channels preserved), events, pages and command lists; unknown engine/plugin fields preserved by structural edits |
| Marshal⇄JSON interchange | "floe-rpg-marshal" v1 total, lossless interchange (documented below) used for parameter editing of binary files; graph ids (`$id`), original object-table slots (`$slot`), ivar order (`$ivarOrder`) and encodings are preserved |
| Repository session | `RPGProjectSession` (actor) reads/commits through `FileGameProjectRepository` only: immutable objects, atomic HEAD, cross-instance CAS. No second original |
| Editor bridge | `RPGEditingAdapter: GameEditingAdapter` for all five engines: `assetKind`, per-file `parameterSchemas(for:in:)`, record-aware `parameterSchemas(for:json:in:)`, `parameterBinding` (binary ⇄ interchange JSON), `tileMapBinding` (`EditableTileMap`), `narrativeBinding` (`NarrativeDocument`) |
| Published-game inspection | `RPGDistributionInspector` classifies imported/downloaded distributions: readable/editable files, encrypted RGSS archives, native EXE/DLL runtime references, RTP references, missing scripts/data, MV/MZ web-playback candidates — without executing Ruby/EXE/DLL, decrypting archives or discarding files |

## Explicit limits (reported, never silently rewritten)

- RGSS (XP/VX/VX Ace) **native gameplay is not provided**. RGSS DLLs/EXEs are
  detected and never executed; `Game.exe`/`*.dll` remain untouched.
- Encrypted archives (`rgssad`, `rgss2a`, `rgss3a`) are detected and preserved;
  their contents are not readable or editable until handled separately.
- MV/MZ encrypted image headers are detected (missing PNG signature), not
  decoded. `plugins.js` is preserved as a file and not semantically parsed.
- RPG Maker RTP assets are never bundled. `Game.ini` RTP references are
  reported; missing references are not invented.
- Building a *new* event on a binary map requires an `RPG::Event` template node
  (`RPGMapDocument.upsertEvent` throws otherwise). JSON maps can create events.
- Tile edits are restricted to visible tile layers (XP/VX/VX Ace 3; MV/MZ 4).
  MV/MZ shadow/region data channels are preserved but not edited.
- `EditableTileMap.tileSets` is not synthesized from engine tileset layouts;
  tile ids map 1:1 to engine tile ids so no false image binding is created.
- Narrative DTO support is a command subset (movement/condition/text/script
  groups listed in `RPGCommandSpec`); every other command is surfaced
  read-only with its original payload and re-serialized untouched.
- The Ruby Marshal graph is an ownership-transferred container
  (`@unchecked Sendable` for that reason): safe to move between isolation
  domains, never to mutate concurrently.

## Ruby Marshal format notes (empirically verified against Ruby 2.6.10)

- Fixnum wire form is used only for `-2^30 … 2^30-1` (Ruby's tagged-value
  rule); larger integers use the Bignum form even when they fit in 64 bits.
- Bignums: `'l'`, sign byte, fixnum word count (16-bit words), little-endian
  magnitude words.
- Floats are `'f'` + length-prefixed `%.16g` text; the original text is stored
  verbatim for byte-exact re-emission.
- Strings with a non-binary encoding carry an `I` wrapper. `:E true` = UTF-8,
  `:E false` = US-ASCII, `:encoding "Name"` = named encoding. Named-encoding
  name strings are numbered objects and are interned per dump (repeats become
  object links).
- `_dump` user-defined objects are numbered **after** their payload; every
  other registered kind is numbered before its contents. The writer reproduces
  this and additionally reuses each parsed node's original object-table slot
  (`RubyNode.originalMarshalIndex`), so link numbering matches the source even
  where Ruby's dump/load numbering conventions differ.
- `Table` payload: `[dim, xsize, ysize, zsize, count]` little-endian `uint32`
  followed by `count` little-endian `int16` values (`Color`/`Tone` use
  little-endian doubles).

## Marshal⇄JSON interchange (`floe-rpg-marshal` v1)

```
{"format":"floe-rpg-marshal","formatVersion":1,"root": <node>}
```
Node forms: `null`/bool/number scalars; `{"$bigint":"-123…"}`;
`{"$float":"3.14"}`; `{"$string":"…","$encoding":"utf-8|us-ascii|binary|<Name>"}`
(or `$bytes` for non-UTF-8 payloads; `$encodingIvars` for exotic forms);
`{"$symbol":"name"}`; bare arrays; `{"$pairs":[{"$key":…,"$value":…}],"$default":…}`;
`{"$class":"RPG::Actor","$ivars":{…},"$ivarOrder":[…]}` (structs add
`"$struct":true`); `{"$class":"Table","$userdata":"<base64>"}`;
`{"$class":"X","$marshal":…}`; `{"$options":0,"$regexp":"…"}`;
`{"$extended":[…],"$value":…}`; `{"$classObject":"String"}`.
Registered nodes carry `"$id"` (document table id) and, when parsed from a
stream, `"$slot"` (original Marshal slot); repeats are `{"$ref":n}`.
The root array of a record file is therefore `{"$id":0,"$value":[…]}` under
`"root"`; parameter schema paths address that layout.

## Dependencies and licensing

- FloeGameKit (`FloeGameCore`) and FloeGameEditingKit (`FloeGameEditingCore`),
  local path dependencies, MPL-2.0 (see `LICENSE`).
- System `zlib` only. No third-party SwiftPM packages.
- Upstream review (no code bundled): the pinned
  `RPG-Maker-Translation-Tools/rvpacker-txt-rs-lib@1feec3d6579b9770944379245600e99d446a4eaf`
  (WTFPL v2) and `marshal-rs@4.0.1` (WTFPL v2) were reviewed as format
  cross-references. Neither is vendored or linked: a Rust→iOS static build is
  a heavy native dependency for this component, and `marshal-rs` documents
  that its JSON round-trip does **not** preserve object links/cycles, which
  this package requires. Retained upstream licenses live in the delivery
  artifacts, not in the module (no upstream code is present).
- No RTP data, Enterbrain scripts or proprietary DLLs are bundled. Test
  fixtures are original content generated by the developer tool
  `Tests/FloeRPGCoreTests/Fixtures/generate.rb` (real Ruby Marshal 4.8 + zlib
  output; `Table`/`Color`/`Tone` stubs mirror the engine payload formats).

## Verification (local, Xcode 27.2 / Swift 6.4.2)

- `swift test` (host): **65 tests, 0 failures** — byte-exact Marshal round
  trips for every generated binary fixture (XP/VX/VX Ace databases, maps,
  common events, script archives), malformed/limit rejection, script archive
  edit/order/bounds, table/color/tone codecs, binary + MV/MZ document edits,
  unknown-field/command preservation, interchange losslessness (including
  cycles), adapter schemas (per-file + record-aware), distribution
  inspection, repository CAS/history/export, and session-level DTO paths
  (`parameterDocument`/`editParameterDocument`, `editTileMapDocument`,
  `editNarrativeDocument`) with engine-codec readback.
- `swift build --target FloeRPGCore --triple arm64-apple-ios26.0`
  (iPhoneOS27.2 SDK): **Build complete**, 41 object files including this
  module's sources. No Simulator was booted; this is compilation/object
  evidence only, not device/UI acceptance.

## Regenerating fixtures

```
cd Tests/FloeRPGCoreTests/Fixtures
/usr/bin/ruby generate.rb "$(pwd)/generated"
```
The generator refuses to run when pointed at its own directory.
