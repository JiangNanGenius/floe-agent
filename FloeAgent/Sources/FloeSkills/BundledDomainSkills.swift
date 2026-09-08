import Foundation

/// Bundled guides. Hidden system guides update only with the app; visible
/// guides may bind to an explicitly reviewed GitHub source. The seeder never
/// overwrites a GitHub-managed or locally modified package.
///
/// Two classes: `exposed` skills are visible in the skill hub (users can
/// enable/disable them and see version upgrades); hidden built-ins stay out
/// of the hub but remain readable on demand via `skill.read`.
public enum BundledDomainSkills {
    public struct Definition: Sendable {
        public let id: String
        public let name: String
        public let description: String
        public let version: String
        /// true = visible in the skill hub; false = hidden built-in.
        public let exposed: Bool
        public let markdown: String

        /// Broad remote workflows discover subgroups, rather than loading the
        /// whole remote catalog merely by reading this guide.
        public var automaticallyLoadedToolNames: [String] {
            id == "floe-remote" ? [] : toolNames
        }

        /// Exact tool references are checked against the executable catalog.
        public var toolNames: [String] {
            let pattern = #"(?<![A-Za-z0-9_.-])[a-z][A-Za-z0-9]*(?:\.[a-zA-Z][A-Za-z0-9]*)+(?![A-Za-z0-9_.-])"#
            let regex = try! NSRegularExpression(pattern: pattern)
            let ns = markdown as NSString
            let allowedRoots = ["document", "presentation", "font", "network", "web", "exec", "ssh", "canvas", "image", "apple", "mail", "browser", "workspace", "crypto", "credential", "vnc", "remote", "remoteHosting", "cloudWorkspace", "bluetooth"]
            return Set(regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }.filter { allowedRoots.contains(String($0.split(separator: ".")[0])) }).sorted()
        }
    }

    public static let builtinSourceScheme = "floe-builtin://"

    public static func sourceURL(for id: String) -> String { builtinSourceScheme + id }

    public static let all: [Definition] = officialDefinitions + [
        // MARK: Exposed to the hub (office / pdf / network)
        // MARK: Hidden built-ins
        Definition(
            id: "floe-remote",
            name: "Remote Operations",
            description: "VNC, Executor, interactive Terminal, host configuration and remote workspace lifecycle. Load only the subgroup needed for the current task.",
            version: "1.0.1",
            exposed: false,
            markdown: """
            ## Remote operations
            This is a workflow guide, not an execution runtime or permission grant.
            Discover the relevant subgroup with tools.search; do not activate all remote tools at once.
            ### Host configuration
            Resolve a host once with `ssh.listHosts` and reuse its exact hostID. `ssh.inspectTarget` probes; `ssh.updateHost` stores configuration and secure credential references. Bootstrap/deploy requires explicit authority, not a routine prerequisite.
            ### Executor substrate
            `ssh.execute` runs remotely and may return a durable taskID. Reuse it with `ssh.taskStatus` or `ssh.cancelTask`; never rerun a command to recover its result. Executor is independent of this guide, Terminal sessions and on-device Python.
            ### Interactive Terminal
            `ssh.shellOpen` → `ssh.shellExchange` → `ssh.shellClose` uses a run-scoped sessionID, never a taskID. `remote.connection.open`, `remote.connection.exchange`, `remote.connection.close` and BLE serial sessions likewise reuse their exact session IDs. Use Executor for durable one-shot commands.
            ### VNC
            Reuse a confirmed connection. Use `vnc.status` when state is unknown, `vnc.connect` when disconnected, then `vnc.observe` for fresh evidence. `vnc.click`, `vnc.drag`, `vnc.typeText`, `vnc.typeCredential`, `vnc.keyPress` and `vnc.scroll` require a connected session and current evidence; verify one input with its post-action evidence. `vnc.disconnect` closes it.
            Honor the user's prerequisite route first, including authorized SSH repair when requested. Never repeat an unchanged failed call. partialSuccess/inputDispatched means input may already have executed: inspect evidence, never replay the input merely because screenshot capture failed. Reuse credential references; do not request or expose secret values.
            ### Cloud workspaces and sharing
            Reuse the exact hostID/workspaceID in Workspace links; `cloudWorkspace.catalog` or `cloudWorkspace.create` resolves missing IDs. A local Cloud marker is not remote file content.
            `remoteHosting.inspect` and `remoteHosting.manage` reuse shareIDs. Publishing requires explicit sharing authority; list before changing/stopping an existing share.
            """
        ),
        Definition(
            id: "floe-python",
            name: "Local Python Runtime",
            description: "The bundled CPython substrate: usage rules, bundled libraries, and the contract every script-carrying skill executes under.",
            version: "1.2.0",
            exposed: false,
            markdown: """
            ## Local Python (exec.localPython)
            ### Using the runtime
            - The appended runtime probe is authoritative for this build's Python and native library versions. Standard-library extensions include asyncio, json, csv, sqlite3, zipfile, tarfile, gzip, bz2, lzma, hashlib, hmac, secrets, xml.etree, mmap, zoneinfo and statistics. Desktop shell modules (curses, readline, grp, pwd, syslog, multiprocessing) do not exist on iOS.
            - numpy, Pillow (import as PIL), and pandas are bundled natively in supported builds. Use the runtime probe to confirm availability; do not infer installed versions from old memory or route working native libraries to WebAssembly. Native pandas supports CSV/JSON, filtering, grouping, joins, missing values and timezone processing offline; optional file-format dependencies must still be checked separately.
            - For scipy and matplotlib, consult the runtime probe: if a package is not bundled in this build, use the explicitly identified **Pyodide WebAssembly** route (workspace HTML + public-HTTPS Pyodide, JSON in/out) or an authorized remote host. Never claim a native install when code ran in WebAssembly; a build pipeline or downloaded wheel is not proof of runtime availability.
            - Extra pure-Python packages install through the managed review path (`packages`/`pipCommand` + `packagePurpose`, exact `name==version`, py3-none-any wheels only). Never invoke pip/ensurepip/subprocess inside `script`.
            ### The substrate contract for script-carrying skills
            Skills may ship `scripts/*.py` executed through this runtime. The contract:
            - Manifest: `scriptRuntime: .localPython` + capability `python.local` + tool `exec.localPython`; scripts are static-audited at install (no subprocess, pip, ctypes, os.system; ≤192 KiB).
            - At runtime the **exact audited source** is embedded in the skill's injected instructions and its SHA256 is pre-approved: run it verbatim with task data in `inputJSON`. Any source or package-spec change returns to the normal approval flow.
            - `pythonPackages` entries are exact `name==version` plus purpose and capabilities; they were inspected at install.
            - Remote execution through the paired host's daemon (ssh.execute / cloudWorkspace) is a **different environment** — do not document or treat it as this local runtime.
            """
        ),
        Definition(
            id: "floe-apple",
            name: "Apple Capabilities",
            description: "Mail, calendar, photos, home, reminders, shortcuts, clipboard and camera rules in one place.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Apple capability rules
            - **Stable IDs**: list before update/delete and reuse the exact returned id (calendar events, reminders, automations, home accessoryID+characteristicID). Create actions need no prior id.
            - **Mail**: `apple.mail.compose` only opens the compose UI — it never sends. `mail.send` sends through the configured SMTP account with approval. Read/search/download via `mail.*` connector tools.
            - **Photos**: capture new images to the workspace through `apple.camera.capture` (bounded, user-visible). Do not claim a Photos-library save tool exists; use the app's explicit export UI when needed.
            - **Home**: control only writable characteristics with both exact IDs from `apple.home.list`.
            - **Reminders/Calendar**: create with clear titles/times; edits always go list-first.
            - **Shortcuts**: `apple.shortcuts.run` executes an installed shortcut by exact name with bounded input/output.
            - **Clipboard**: reads/writes are approval-gated and one-shot; never stash clipboard content into memory or files unless the user asked.
            - **Permissions**: if a capability reports missing authorization, name the exact Settings path instead of retrying blindly.
            """
        ),
        Definition(
            id: "floe-data-code",
            name: "Data & Code Execution",
            description: "On-device JavaScript, the compatibility evaluator, canvas mutations, and generate-tool boundaries.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Data & code execution (on-device)
            - `exec.javascript` runs bounded JavaScriptCore with pre-installed pure-JS packages (lodash, dayjs, marked, uuid, zod, pdf-lib) — no network, no Node APIs, no timers beyond a microtask shim.
            - `exec.compatEvaluator` is Floe's own R/Stata-**compatible** evaluator — it is NOT GNU R, Stata, Octave or MATLAB; for the full runtimes use an approved configured remote host. (Local Python lives in floe-python.)
            - **Canvas**: `canvas.getState` returns canvasID/documentID/revision/node IDs. Reuse the latest exact revision for patches/generation; mutation results return the new revision and a delta — apply it and continue without re-inspecting unless a revision conflict occurs.
            - **Generation split**: `image.generate` is AI text-to-image for a standalone image; `canvas.generate` produces media inside the canvas document/generation graph with source-node ancestry. Choose by where the result must live.
            - Remote daemon execution (ssh.execute/cloudWorkspace) is a different environment — use the Executor substrate. Interactive sessions belong to the separate Terminal toolkit.
            """
        ),
        Definition(
            id: "floe-browser",
            name: "Browser & Vision",
            description: "DOM-first browser automation with screenshot/OCR fallback and visual verification.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Browser & vision workflow
            - **DOM first**: `browser.navigate` returns tabID/documentID; `browser.observe` refreshes stable element refs for that document. Act on DOM refs for one action, then observe again.
            - **Visual fallback**: when DOM structure is insufficient, use `browser.screenshot` and prefer its on-device OCR `visualTextRegions` with `browser.clickVisualText`. Use `browser.clickPoint` only when neither DOM refs nor OCR anchors identify the target — always with fresh evidence from the current page, and verify the returned post-action screenshot.
            - **Inspection**: `image.inspect` answers visual questions about workspace images (provider-backed when configured); `image.ocr` extracts text regions on-device; `image.scanBarcode` reads QR/barcodes, `image.qrGenerate` creates them locally.
            - **Web content**: reading pages is `web.fetch` (basic capability); this skill governs interactive browser sessions only. Never invent refs, tabIDs or documentIDs; if evidence is stale, observe again instead of guessing.
            """
        ),
        Definition(
            id: "floe-files-vcs",
            name: "Files & Version Control",
            description: "Workspace file discipline, safe-write checks, archive formats and the minimal Git sequence.",
            version: "1.1.0",
            exposed: false,
            markdown: """
            ## Files & version control
            - **Safe writes**: `workspace.writeFile`/`workspace.applyPatch` validate `expectedSHA256`/`expectedMtime` when the file existed; read before overwrite and never bypass a mismatch — re-read and recompute instead.
            - **Read→modify→verify**: after writes, reopen with `workspace.readFile` or `workspace.searchFiles` to confirm; keep paths workspace-relative (no absolute, no `..`).
            - **Archives** (`workspace.archive`): native ZIP/TAR/7z, plus the app's native RAR/RAR5 reader. Compressed TAR and gz/bz2/xz use CPython. Use `destinationDir` for container extraction, `destinationFile` for archive creation or single-file decompression, neither for listing. RAR/7z are read-only; encrypted/multipart/unsupported RAR variants fail explicitly. Old ambiguous destination calls must be replanned. Existing outputs are never overwritten.
            - **Git** (workspace): ordered minimal sequence status → diff → stage → commit → (pull/push with explicit approval). No stash/tag/rebase/cherry-pick — do not fabricate them through other tools.
            """
        ),
        Definition(
            id: "floe-crypto",
            name: "Crypto & Credentials",
            description: "Hashing, AES-GCM encryption, Ed25519 signing and credential-card management with secrets never returned.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Crypto & credentials
            - `crypto.hash`: SHA-256/384/512, SHA-1 or MD5 over inline text or a workspace file — use for integrity and audit fingerprints.
            - `crypto.cipher`: named keys held in the device Keychain (raw key material is **never returned**). `generateKey` (aes256 default, or ed25519) refuses to silently rotate an existing name; `encrypt`/`decrypt` use AES-256-GCM (base64 text or workspace-file output); `sign`/`verify` use Ed25519 with a 128-hex signature. `listKeys` shows names+kinds only.
            - `credential.manage`: independent credential cards — `list` returns metadata only, `create` stores label+kind+one-time secret and returns the stable `⟨credential:id⟩` reference, `update` relabels or replaces the secret in place (references stay valid), `delete` removes both metadata and Keychain bytes. Secrets are write-only: never ask the tool to reveal one, and pass the ⟨credential:id⟩ reference wherever a credentialInput is accepted.
            """
        ),
    ]
}
