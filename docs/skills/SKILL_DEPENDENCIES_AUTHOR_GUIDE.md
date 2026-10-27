# Official Skill dependency declarations — author contract (schemaVersion 1)

Audience: authors of **official, reviewed and signed Skill Hub packages**. External
(pulled/imported) skills keep model-led dependency handling through the ordinary
execution tools: `references/dependencies.json` is validated when present but a foreign
package never triggers native automatic provisioning. Ordinary `apt` / `pip` / `npm`
downloads inside `exec.shell` remain freely available to every skill; this contract is a
small reviewed convenience integration, not a new execution system and not a fetch
restriction.

The native strict decoder is the authority:
`FloeAgent/Sources/FloeSkills/SkillDependency.swift` (mirrors the frozen
`SkillRuntimeDependency` descriptor pattern). The machine-readable shape documented here
lives at [dependencies.schema.json](dependencies.schema.json); the five worked examples
live in [examples/](examples/).

## What the declaration does

When an official package installs, its declaration is verified and persisted by the
service, and the install boundary **actually prepares the shared resources it can
honestly prepare without a task environment**: each declared pure-`py3-none-any` wheel
pin is fetched and hash/size-verified host-side through the existing managed wheel
auditor path (a download-only reviewed client — no package command ever runs on the
native host) and its **verified bytes are persisted into the shared official wheel
store under their real canonical PEP 427 wheel filename** (pip's `--find-links` scan
recognizes valid wheel names only); the task's first managed install consumes those bytes through the
already-mapped `--find-links` path with no redownload (an evicted or missing file
simply falls back to the bounded index download — the store is an optimization, never
a weakened audit). A runtime-component requirement's artifact is fetched through the
existing GitHub-only transport at the pinned publication commit, verified (exact size
+ sha256 + static-ELF gate) and committed atomically into the same app-owned component
cache the first use re-reads and re-verifies. A wheel fetch that cannot persist (no
wired store) is honestly recorded as waiting, never as prepared. apt/npm/font identities resolve only against a real
guest's configured sources and architecture, so they get an explicit `awaiting target
environment` state. The durable per-resource status is shown by `skill.read` and
survives views and restarts; prefetch is **never** readiness — no cache hit is claimed
and nothing is marked `packages ready`. When the skill is exactly read (`skill.read`)
inside a task bound to a resolved Linux guest environment, the app records an immutable
plan for `(environmentID, runID)`.
At the skill's approved `exec.shell` invocation that carries `"skillID"`, Floe
automatically prepares and installs the declared resources **in that same resolved
environment**, reads every requirement back, and either proceeds (annotating optional
gaps) or refuses **that skill's invocation** with the honest reason when a required
resource is not ready. There is no target-environment picker, execution is never
rerouted to another environment, and commands run without `skillID` keep the exact
ordinary behavior (that path is how a run repairs itself).

Downloads deduplicate in the shared store (`/floe/cache`, downloads only — install state
always lives in the task environment's own write layer: the environment venv, the
`/floe/env/usr` node prefix, and per-environment dpkg shards). A shared-cache eviction
can therefore never destroy an installation, and no cross-environment deduplication is
promised.

## Frozen schema (v1)

Top-level keys are exactly `schemaVersion` and `profiles`; a profile is exactly
`id`, `target` (`os` + `architectures`) and `requirements`. Every requirement is tagged
by `kind` and carries exactly the key set of its kind. **Unknown fields fail closed**:
the schema has no URL, command, script, environment, registry, index, digest, permission
or approval field anywhere, so a declaration can never mint a shell command, redirect a
download, or widen an approval. The whole file lives inside the canonical package at
`references/dependencies.json` — the signed `contentDigest` already covers its bytes and
every referenced lock, so the review `.sig` binding covers the declaration and the locks
without external hashes, and old clients simply ignore the inert file.

```json
{
  "schemaVersion": 1,
  "profiles": [
    {
      "id": "linux-guest",
      "target": { "os": "linux", "architectures": ["any"] },
      "requirements": [
        { "kind": "pip", "name": "pypdf", "version": "5.4.0",
          "purpose": "Read and merge PDF pages.", "required": true }
      ]
    }
  ]
}
```

Kinds (exact per-kind key sets):

| kind | keys | rules |
| --- | --- | --- |
| `pip` | `kind,name,version,purpose,required[,lockfile]` | exact PyPI name; one exact PEP 440 version (no operators/ranges/URLs); optional package-local lock under `references/…​.txt` listing wheel sha256 digests. The lock is a BINDING FULL pinned closure, not review decoration: it must enumerate the declared pin AND every transitive wheel, each `name==version` with at least one `--hash=sha256:` (generate it with a hash-mode tool such as `pip-compile --generate-hashes`); operators, bare names, extra flags/URLs, missing digests or contradictory duplicates are refused — never guessed. Prefetch persists each locked wheel's verified bytes under its canonical name; the install then runs the guest's own pip over the WHOLE closure in one `--require-hashes` transaction (pip verifies every processed requirement, transitives included). Ownership scope: a conflicting pin already OWNED by the environment's venv refuses before any install, while an older inherited `--system-site-packages` (apt) version never blocks — the reviewed pin is simply shadowed inside the venv and the APT base is untouched. A lock-free pin keeps plain exact-version install behavior. Pure `py3-none-any` wheels only — the existing install-time audit and native refusal stay unchanged. |
| `apt` | `kind,name,version,purpose,required` | one Debian identity + exact Debian version (epoch, `+dfsg`, `-rev`, `+tilde` stay part of the pin). Installed through the guest's own single `apt-get install -y --no-install-recommends name=version` transaction with `dpkg` readback. |
| `npm` | `kind,name,version,purpose,required` | exact `name@version` (optionally scoped), exact semver only. Provisioning installs the pin and reads the installed tree back. A packaged `package-lock.json` is review evidence; it is **not** replayed as an install, and the schema therefore has no lock field for npm. |
| `font` | `kind,name,version,purpose,required` | exactly one Debian font package identity **plus an exact Debian version** (same pin class as `apt`; today `fonts-noto-cjk 1:20240730+repack1-1`). v1 has no unversioned exception: the identity+version are installed and read back together, and the fixed guest CJK GLYPH-RENDER probe is the readiness gate on top of the recorded version. The probe is the guest's own stdlib Python ctypes against FreeType (`FT_Init_FreeType`, `FT_New_Face` on the frozen Noto TTC paths, nonzero `FT_Get_Char_Index` for one Chinese and one Japanese codepoint, `FT_Set_Pixel_Sizes` 32 px, `FT_LOAD_RENDER` `FT_Load_Char`, then teardown): it proves a real renderer plus faces can rasterize CJK text — a missing renderer or font answers honest not-ready, and no visual quality of produced artifacts is claimed. Declare `fontconfig` (which pulls the Debian-provided FreeType library) alongside the font identity, as the CJK example does. |
| `runtimeComponent` | `kind,componentDescriptorPath,purpose,required` | `componentDescriptorPath` must be exactly `references/engine-dependency.json`. Identity, version, artifact digest and size come only from the pinned descriptor through the existing managed runtime-component allowlist (today exactly `impeccable-engine`). The allowlist, the 16 MiB component-only cap and the nonblocking component hook are **not** broadened by this contract; the requirement never carries its own name/version/digest. |

`purpose` is 1–200 bytes of short model-safe text shown through `skill.read`. `required`
is a boolean: `true` gates that skill's dependency-aware invocation; `false` proceeds
with a visible annotation.

Limits: ≤64 KiB file, 1–8 profiles, 1–32 requirements per profile, unique profile ids,
unique `(kind,name)` within a profile, `os` exactly `"linux"`, `architectures` ⊆
`{riscv64, arm64, x86_64, any}`.

`target.architectures` is a SELECTION contract, not documentation: provisioning matches
each profile against the architecture of the actual local Linux backend (the pinned guest
is `riscv64`) and only profiles that match — or declare `any` — plan, prefetch or install.
A declaration with no matching profile fails honestly with nothing installed; two matching
profiles pinning the same `(kind,name)` to different exact versions are a contradiction
that refuses before any transaction, while identical exact duplicates across matching
profiles simply reuse. If today's Floe ships only riscv64 guests, an `arm64`-only profile
is never installed by this build — declare what actually runs (`any`, or the guest's real
architecture), and add per-architecture profiles only when a backend for them exists.

## Version management (frozen distinctions)

There are exactly four version concepts. Do not invent a fifth, and do not add a second
user-visible version counter: **the existing Skill package `id`/`version` stays the
single package authority.**

1. **Skill package version** — `floe.json` `id` + `version` (semantic version). Released
   bytes are immutable: the canonical `contentDigest` covers every file inside the
   package, including `references/dependencies.json`, its locks and any component
   descriptor. Any change to scripts, dependency declarations or permissions requires a
   **new package version and a new signed digest**; bytes are never replaced under an
   already published same version. A same-id/same-version/bytes-mismatch package fails
   closed against the reviewed digest (receipt identity/conflict), not silently.
   **Publisher CI must reject** any publication that reuses an existing Skill
   `id`+`version` with a different `contentDigest`, even when the publisher could
   produce a fresh valid signature for the new bytes — the client-side receipt digest
   alone cannot prove historical publication immutability (it only validates bytes
   against the CURRENT signed receipt), so the rule must be enforced at the publishing
   boundary. As a client-side second line of defense over identities this device has
   OBSERVED, every official curated commit also records a durable publication identity
   (id + version + contentDigest + publication commit); a later curated install or
   update carrying the same id+version but a different digest fails closed
   ("publication identity conflict"). Retained identities never replace bytes and do
   not claim proof for history this client never observed — publisher CI remains
   mandatory for that.
2. **`schemaVersion` in `dependencies.json`** — parser compatibility only. This build
   accepts exactly `1`. An unknown newer value fails compatibility for the provisioning
   channel (required resources are reported not ready with the honest reason) instead of
   being guessed; it never breaks reading, staging or the rest of the skill.
3. **Exact resource/dependency versions plus locks** — the `version` pins per
   requirement (pip, apt, npm **and font**: a font requirement is an exact apt
   identity+version pin, and the readback receipt records that version verbatim)
   plus, for pip, the wheel `sha256` digests in the referenced lock, plus for a
   runtime component the pinned descriptor's own `componentVersion`/artifact digest.
   These are what gets installed and read back — never ranges, never `latest`, never
   an implicit upgrade, never a silent downgrade (a same-environment collision with a
   different installed version is refused honestly).
4. **`minimumAppVersion`** — the existing old-client gate. A curated hub entry whose
   declaration needs the new native behavior raises the entry's existing
   `minimumAppVersion` to the first capable build (candidate `1.7.60`); older clients see
   the unchanged `.incompatibleApp` offer state and can never install it. The pinned
   component descriptor keeps its own `minimumAppVersion` gate unchanged.

### What a readiness receipt binds

Every receipt binds, together and reverified on use: the **package version**, the package
**contentDigest**, the **dependencyManifestDigest** (SHA-256 of the exact
`dependencies.json` bytes), the profile id and requirement identity (kind, name, exact
version), the resolved **environment** and the guest **launch generation**. A receipt is
reusable only while every one of those facts still matches and the installed
authorization revalidates; boot rotation, disable, uninstall, edit or a revoked grant
invalidates it (reauthorize/recheck — a serialized copy is never a ready token).

### Update, rollback, and running invocations

- **Update** installs a new immutable package version with a new signed digest; plans and
  receipts are re-recorded from the new exact bytes. There is no same-version dependency
  refresh and no merge of declaration bytes.
- **Rollback** restores the previous immutable package + descriptor pair. If the current
  environment cannot satisfy the rolled-back pins (for example a newer pip wheel is
  already installed and the older pin conflicts with it), Floe reports that honestly per
  requirement — it never automatically removes apt/pip/npm packages, and environment
  package removal stays an explicit user action in the environment package UI, owned
  only where nothing else installed still needs the exact spec.
- **Running invocations pin** the package version + dependency descriptor captured when
  their run recorded the plan: an install or update landing mid-run cannot swap the
  bytes an active run already verified; the late revalidation fails closed and the run
  must re-read before continuing.
- **Uninstalling a skill removes ownership records only** — declared packages stay in the
  environment untouched (no automatic `apt`/`pip`/`npm` delete).

## Authoring rules

- Pin against the Debian release the guest image actually serves. The runtime always
  uses the author's exact pins and fails honestly when a pin cannot be served — it
  never substitutes a "close enough" version. Example pins here were checked against
  live `packages.debian.org`/`sources.debian.org` trixie metadata
  (`python3-scipy 1.15.3-1`, `python3-matplotlib 3.10.1+dfsg1-4`,
  `poppler-utils 25.03.0-5+deb13u4`, `fontconfig 2.15.0-2.3`,
  `fonts-noto-cjk 1:20240730+repack1-1`).
- Declare only what the skill actually needs; prefer reusing what the reviewed recipe or
  the environment already ships (exact pins annotated as such), and reuse pure wheels,
  Debian apt binaries and the one small optional CJK font instead of heavyweight
  preinstalled extras. No new base image, no heavyweight science stack.
- No fake hashes, no heavy binaries or wheel blobs inside the package: locks list
  digests; the wheels themselves download through the shared cache at first use (an
  official install may persist the audited bytes into the shared wheel store under
  their real canonical PEP 427 filename, so the guest's `--find-links` pip can
  actually consume them).
- Keep legacy caps intact: this contract never widens ordinary Skill package artifact
  limits (2 MiB/file, 8 MiB/package) — the only elevated cap is the existing
  explicitly-allowlisted runtime component's own bound.
- Add the file under `references/`, pin `schemaVersion: 1`, bump the **package version**,
  re-sign the digest, and let the normal reviewed publication flow carry it.

## Worked examples

**A skill with no dependencies ships no `dependencies.json` at all.** Do not
invent an empty declaration (zero profiles or an empty `requirements` array is
invalid and fails closed); guidance-only and script-only packages keep the exact
existing no-sidecar behavior for old and new clients alike.

| file | shows |
| --- | --- |
| [examples/dependencies.minimal.json](examples/dependencies.minimal.json) | minimal envelope: one required exact pip pin |
| [examples/dependencies.purepip.json](examples/dependencies.purepip.json) | several pure `py3-none-any` pins sharing one package-local wheel lock |
| [examples/dependencies.debian.json](examples/dependencies.debian.json) | Debian apt identities with exact versions installed through the guest's own single transaction |
| [examples/dependencies.npm.json](examples/dependencies.npm.json) | exact `name@version` npm pins (lock bytes are review evidence, never replayed) |
| [examples/dependencies.cjk.json](examples/dependencies.cjk.json) | Debian science stack pins (`python3-matplotlib`, `fontconfig`) plus the optional font identity+exact-version pin with the fixed CJK glyph-render probe |

A `runtimeComponent` requirement looks like:

```json
{ "kind": "runtimeComponent",
  "componentDescriptorPath": "references/engine-dependency.json",
  "purpose": "Impeccable snapshot engine.", "required": true }
```

and only works alongside the already frozen, allowlisted descriptor and its existing
managed deployment path.

## How the model invokes a skill with dependencies

`skill.read` of an installed official skill with a declaration reports the profile, each
requirement (kind, exact pin, required/optional) and the invocation contract: call
`exec.shell` with `"skillID": "<skill id>"` in the same task run. With `skillID` the run
verifies the installed record, the current run binding and the grant, automatically
prepares/installs the declared resources into the task's resolved Linux environment and
reads them back. A required resource that is not ready refuses **that skill's**
invocation with the honest reason; optional gaps appear as a visible annotation;
commands without `skillID` are unchanged, which is how ordinary repair work proceeds.

## Scope and non-promises

- Automatic provisioning applies only to official reviewed/signed Hub installs.
- No generic native execution of untrusted external install instructions.
- No new execution aliases, no package installer tools, no environment picker.
- Cross-environment physical deduplication is not promised (dpkg shards and venvs are
  per-environment by design); the shared store deduplicates downloads only.
- Installed sizes of `fonts-noto-cjk` and apt python closures are measured from real
  guest logs at qualification time; this contract claims none.
