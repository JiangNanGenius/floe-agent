# C07 data exchange — licence boundary

No new third-party dependency or vendored source is introduced by
`shared/Sources/FloeAndroidDataExchange`, `C07DataExchangeDomain.swift` or
`C07DataExchangeBindings.swift`.

The module reuses the already-reviewed, already-linked package targets:

- `ZIPFoundation` (MIT; manifest mirror vendored under `shared/Sources/ZIPFoundation`, licence in `licenses/` provenance records)
- `swift-crypto` (Apache-2.0; pinned in `shared/Package.swift`)
- `FloeNotes` (the shared project source family; MPL-2.0 headers)
- `GRDB`/SQLite (MIT/public domain; existing persistence authority)

The Android App host uses only the platform `ContentResolver`, `java.util.Base64`
and `java.security.MessageDigest` APIs. No provider SDK, cloud client or
credential-store code is added.

Restore accepts only the documented `floe.appbackup` format and the established
iOS-compatible `.floenote` layout produced by the shared `NotesArchive` writer.
It does not claim arbitrary ZIP files are cross-platform Floe documents.
