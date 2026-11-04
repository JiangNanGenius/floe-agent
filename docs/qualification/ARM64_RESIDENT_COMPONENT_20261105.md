# ARM64 resident Linux component checkpoint — 2026-11-05

This records component evidence, not App installation, Simulator browser use,
physical iPad performance, Mac pairing or publication acceptance.

- Engine: interpreted ARM64, 23-operation ABI; native C object/link checks passed
  for macOS, iOS device and iOS Simulator. No JIT.
- Actual Swift6 adapter: 17 runtime checks passed, including bounded output,
  partial writes, cancellation, console renewal and 200 waiters racing stop.
- Actual resident owner and Linux: two projects, independent roots, shared
  read-only binary cache, real guest loopback HTTP and host forwarding passed.
- Three-core/reset fixture: 12 checks passed, including three online CPUs,
  task CPU/memory inheriting the shared physical budget, close/reopen dependency
  persistence, keeping a peer alive, and atomic initial-state restore retaining
  project files and the cached ARM64 Impeccable executable.
- Host environment registry: 10 checks passed for durable reset fences,
  dependency removal, file/Skill-record preservation, interrupted reset retry
  and refusing a dependency layer containing a registered project folder.
- Actual migrated SQLite: reset binding/checkpoint transaction passed, including
  rollback on malformed checkpoint and unchanged completed-run identities.
- Full App: Xcode 27.1 / Swift6 / arm64 iOS Simulator compilation passed for the
  initial App cutover batch. Later shared-stop/catalog changes require the final
  compile. This is not App behavior acceptance.

The earlier path-walk timeout was retained and fixed: URL directory hints made
identical filesystem paths compare unequal. The walk now compares paths and
requires parent progress. The original private-disk permission failure was
also retained; only the managed writable clone is chmod 0600, never its base.

## Fixed bytes

Clean 16 GiB logical ext4 base (sparse; actual allocation 969,113,600 bytes):

- SHA-256: e52882895da16b8f59f518058adba8f675d5ae59b5eea9fcdb3c82018dd88184
- Initrd SHA-256: 9cf99d7cd255dec7f03a92bfac9f9560b2dbf79df7a07c534fd6db1c9ca15022
- Public initrd builder reproduced those qualified bytes exactly from the
  pinned official packages and actual compiled runner/supervisor.
- Image ZIP: 328,678,715 bytes. Its full SHA-512 is pinned in the App catalog.

The image/source artifacts must be published and read back before download
acceptance. Remaining App checks are shared settings/status, project reuse,
Skill Hub install in one task and use in another, real built-in browser HTTP,
and reset/re-download behavior. Legacy TinyEMU code and local artifacts remain
scheduled for removal after the ARM cutover and recovery artifacts are safe.
