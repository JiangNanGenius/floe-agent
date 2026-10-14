# Floe bundled Linux boot pair (generated)

This directory is a generated, gitignored-binary resource wired into the
App by `project.yml` (`type: folder`). It is populated by
`../stage-boot-pair.sh` from the retained controlled artifacts, and every
byte is pinned by the tracked `../boot-pair-v2.manifest.json` (sha256 +
size + license/source references). No binaries are committed to Git; a
clean clone must run `stage-boot-pair.sh` (or the project pre-build check)
before the App target builds, or the build fails closed.

Read-only verification (used by the project pre-build script):

    stage-boot-pair.sh --check [source_dir]

`--check` never writes, copies, downloads, or modifies anything: it
compares the staged files against the tracked manifest (and, when a source
directory is given, the source bytes as well) and exits non-zero with a
clear message when the resource is missing or corrupted. Without `--check`
the script stages (copies) verified bytes from an EXPLICIT `source_dir`
argument or the `FLOE_BOOT_PAIR_SRC` environment variable; there is no
implicit default path, so a missing source is a clear error instead of a
silent stage from a stale machine-specific location.
