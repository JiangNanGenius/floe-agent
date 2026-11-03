# Android managed fonts and restore integrity — source checkpoint

This batch connects the existing managed font library to C07 backup and restore. It does not add a local model, install fonts into Linux automatically, or change operating-system fonts.

- Backups capture the active font catalog and exactly referenced immutable font payloads. Removed/recovery-only payloads, device secrets, and live databases are excluded.
- Restore checks the catalog, reference scope, payload hashes and sizes, parsed metadata, and actual Android Typeface admission before native project/note writes begin. Existing libraries are merged within the established capacity limits.
- The C07 journal records resource intent before preparation. Font adoption and rollback use durable before/after identities; a concurrent library edit is preserved rather than overwritten. Completed restores remove temporary hard links while retaining their small recovery receipt.
- Model preference rollback now records actual writer-transaction state atomically in the existing settings table. It refuses a later user edit, survives repeated recovery, and does not introduce a second migration or copy credentials.
- Export, inspection, restore, upload handles and bridge recovery retain the existing Root work tokens until physical completion. Cancel/close acknowledgements do not claim that a running writer stopped. Root retirement drains C07 before the font mailbox; stale epochs and progress callbacks cannot target a newer stage.
- Rooted writes/copies now verify the written byte count instead of comparing it with the empty destination's initial size. Settings export accepts safe JSON scalar values while excluding nested credential keys.

## Qualification boundary

The actual-source host qualification passed 45 tests: rooted file operations, backup/restore contracts, managed-font artifact roles, and real SQLite rollback transactions. Earlier failure logs remain retained privately. ARM64 Swift object compilation and Full/Play Kotlin compilation are recorded separately from this host result.

No new APK, real device font/Office/media check, backup round trip on Android, or cloud model call is claimed by this source checkpoint. Final native product/JNI linkage, 16 KiB packaging, installation/update and end-to-end task acceptance remain part of the unified delivery.
