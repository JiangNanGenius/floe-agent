# FloeBuildingRecords

Project-owned building records for a Floe building/interior project: archived
source files, room information, observations versus adopted values, and a
source-backed smart-home BOM intake/apply workflow.

The target depends only on Foundation, CryptoKit and the package's pinned
`GRDB 7.8.0`. It does not import the native CAD runtime; the records database is
not yet transactionally coupled to a native CAD save.

## Container layout

```text
<project container>/
  Building/Records.sqlite
  Building/Sources/blobs/<sha-prefix>/<sha256>
  Building/Sources/.staging/<uuid>.part
```

The project root is supplied only when a store is created or opened. After
that, all source content is addressed by SHA-256 and all paths are checked
against the project root. There is no public API that accepts SQL, a source
path, or an arbitrary table name.

## Open and mutate

```swift
import FloeBuildingRecords

let store = try ProjectRecordsStore.createProject(
    at: projectContainerURL,
    name: "湖畔住宅"
)
// Later, from the same container:
// let store = try ProjectRecordsStore.openProject(at: projectContainerURL)

var revision = try store.currentRevision()
let room = try store.createRoom(
    RoomDraft(name: "厨房", storey: "1F", kind: .kitchen, aliases: ["中厨"]),
    expectedRevision: revision
)
revision = room.receipt.revision
```

Every mutation checks an explicit project revision. A stale revision throws
`BuildingRecordsError.revisionConflict(expected:actual:)` and makes no change.
A batch observation or BOM operation commits once and returns one receipt.
Idempotent replays (same import key, same draft fingerprint, same apply) report
`didChange == false` and the current revision without adding quantities twice.

## Sources and observations

```swift
let imported = try store.importSource(
    SourceImportRequest(
        kind: .table,
        title: "智能家居料单",
        originalName: "bom.csv",
        mediaType: "text/csv",
        data: csvData,
        roomIDs: [room.value.id],
        idempotencyKey: "bom-import-1"
    ),
    expectedRevision: revision
)
let sourceVersionID = imported.value.version.id

let observation = try store.recordObservation(
    ObservationDraft(
        roomID: room.value.id,
        propertyKey: "room.length_m",
        rawValue: "厨房长度 3.6 m",
        normalizedValue: try RecordedValue(number: 3.6, unit: "m"),
        origin: .user,
        sourceVersionID: sourceVersionID,
        locator: .spreadsheet(sheetName: nil, row: 2, cell: nil)
    ),
    expectedRevision: imported.receipt.revision
)

let adopted = try store.adoptObservation(
    observation.value.id,
    expectedRevision: observation.receipt.revision
)
```

Source versions are immutable. Appending new bytes creates the next version;
retrying the exact latest bytes/name/media type/note returns the existing
version. A source can be associated with multiple rooms; room rename preserves
the IDs and links.

`observations` are candidates and carry origin, source locator, raw text and an
optional typed normalized value. `adoptedValues` are a separate history; a new
adoption supersedes the current value for that room/property without rewriting
the old observation.

## CSV and BOM

```swift
let target = try store.createBOMTarget(name: "智能家居料单", expectedRevision: revision)
let draft = try store.importBOMDraft(
    csv: csvData,
    sourceVersionID: sourceVersionID,
    targetID: target.value.id,
    expectedRevision: target.receipt.revision
)
let applied = try store.applyBOMDraft(
    draft.value.id,
    to: target.value.id,
    expectedRevision: draft.receipt.revision
)
```

The bounded CSV reader handles UTF-8 BOM, BOM-marked UTF-16, CRLF/LF/CR, quoted
commas/newlines, doubled quotes, selected or detected delimiters and hard row,
column, field, record and byte limits. Malformed quoting is an error, not a
silent repair. Chinese and English header aliases map brand/model/order code/
name/series/quantity/unit/room/storey/system/role/channels/spare/notes. Raw
fields and raw record text are retained on every draft row.

`BOMExtractionTable` is the JSON/Codable contract for future XLSX, PDF-table and
OCR adapters. The reader currently implements CSV only. It does not claim
Office or OCR support.

Draft rows retain unresolved issues instead of inventing values:

- negative/zero quantity, missing or invalid quantity, and unknown roles block
  an allocation;
- missing model or unknown unit remains a source-backed, uncounted line;
- an ambiguous room stays unplaced instead of choosing the first room;
- device, channel, set, package and metre totals are separate; they are never
  added into a synthetic total;
- all model matches are `sourceBackedCustom` or `identityUnresolved`. Capability
  state is `unknown`; no protocol, gateway, power or point capability is
  fabricated.

Applying the same source row/identity/target again updates the same allocation
key; it does not double quantities. The same model in different rooms has
different allocation identities. New source versions are compared as added,
changed and absent draft rows. Absence never deletes an adopted manual addition
or an existing allocation automatically.

## Lookup and diagnostics

```swift
let hits = try store.search("厨房", limit: 20)
let report = try store.integrityReport(deepVerify: true)
try store.discardStagedImports() // only when no other importer is active
```

Search is a bounded substring search over room names/aliases, source titles and
latest original names, observations and BOM items. It does not use FTS or claim
Chinese word segmentation.

`integrityReport` checks `PRAGMA quick_check`, source blob existence/size and
(optionally) every digest. Missing/corrupt blobs are reported, not rewritten.
Leftover `.part` staging files can be discarded; import failure leaves no
committed record. Content-addressed orphan blobs are safe to retain and can be
counted with `deepVerify: true`.

## Sample

`BuildingRecordsSamples.sampleBOMCSV` is synthetic bilingual demo data.
`BuildingRecordsSamples.makeSampleProject(at:)` creates an empty project and
returns the store plus stable IDs for the UI. It refuses to populate a project
that already has rooms.

## Current boundaries

- No native CAD revision coupling or atomic cross-file save yet.
- No XLSX/PDF/OCR parser; only the extraction-table contract plus CSV.
- No equipment catalog, point/circuit/address domain, protocol capability,
  cost/quotation calculation or manufacturer matching.
- No AI SQL/path/tool adapter in this target. A future adapter must call these
  typed project APIs under the existing project/task permission chain.
- Source versions and adopted-value history are retained; there is no destructive
  source deletion API.
- A single store is safe to call concurrently because GRDB serializes database
  work; callers still own UI-level ordering and should use `expectedRevision`.
