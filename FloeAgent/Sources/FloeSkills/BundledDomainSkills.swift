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
            let allowedRoots = ["document", "presentation", "font", "network", "web", "exec", "shell", "apt", "ssh", "canvas", "image", "apple", "mail", "browser", "workspace", "crypto", "credential", "vnc", "remote", "remoteHosting", "cloudWorkspace", "bluetooth"]
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
            version: "1.0.1",
            exposed: false,
            markdown: """
            ## Data & code execution (on-device)
            - `exec.javascript` runs bounded JavaScriptCore with pre-installed pure-JS packages (lodash, dayjs, marked, uuid, zod, pdf-lib) — no network, no Node APIs, no timers beyond a microtask shim.
            - `exec.compatEvaluator` is Floe's own R/Stata-**compatible** evaluator — it is NOT GNU R, Stata, Octave or MATLAB; for the full runtimes use an approved configured remote host. (Local Python lives in floe-python.)
            - **Canvas**: `canvas.getState` returns canvasID/documentID/revision/node IDs. Reuse the latest exact revision for patches/generation; mutation results return the new revision and a delta — apply it and continue without re-inspecting unless a revision conflict occurs.
            - **Image configuration**: inspect `image.models` before generation for configured suppliers, exact model IDs, priority/fallback order and supported parameters. When autonomous selection is enabled choose a suitable model and parameters; otherwise keep the preferred model. Unknown parameter metadata is not permission to invent values. Do not automatically repeat an unresolved or timed-out generation.
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
            - **Inspection**: `image.inspect` answers visual questions about workspace images (provider-backed when configured); `image.ocr` extracts text regions on-device; `image.barcode.scan` reads QR/barcodes, `image.qr.generate` creates them locally.
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
            - File and text hashing: use `sha256sum FILE...` in `exec.shell` for workspace files (Linux-compatible output), or `hashlib` inside `exec.localPython` for inline text and derived digests. SHA-256/384/512 and MD5/SHA-1 are available there.
            - `crypto.cipher`: named keys held in the device Keychain (raw key material is **never returned**). `generateKey` (aes256 default, or ed25519) refuses to silently rotate an existing name; `encrypt`/`decrypt` use AES-256-GCM (base64 text or workspace-file output); `sign`/`verify` use Ed25519 with a 128-hex signature. `listKeys` shows names+kinds only.
            - `credential.manage`: independent credential cards — `list` returns metadata only, `create` stores label+kind+one-time secret and returns the stable `⟨credential:id⟩` reference, `update` relabels or replaces the secret in place (references stay valid), `delete` removes both metadata and Keychain bytes. Secrets are write-only: never ask the tool to reveal one, and pass the ⟨credential:id⟩ reference wherever a credentialInput is accepted.
            """
        ),
        Definition(
            id: "floe-shell",
            name: "Local Shell & Packages",
            description: "The on-device POSIX shell: exec, background jobs, interactive sessions, Linux-compatibility boundaries and the apt/pkg capability catalog.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Local shell substrate
            This guide covers the on-device shell. It is independent of the bundled Python runtime (floe-python), the remote Executor (`ssh.execute`) and the remote interactive Terminal (`ssh.shell*`).
            ### Choosing the mode
            - One-shot command: `exec.shell` with a single `command` (pipelines, redirections, globs, variables, `&&`/`||`).
            - Long command: `jobs.submit` targeting `exec.shell` (up to 600s, survives turn boundaries, results via `jobs.result`).
            - Interactive program or prompt-driven script: `shell.open` → `shell.exchange` (send input, read output, `\\u0003` for Ctrl-C) → `shell.close`; `shell.signal` sends INT/TERM/KILL. At most 4 sessions, 30 idle minutes.
            - Packages: `apt` (search/list/show/install/remove/download) and `pkg`/`apt-get`/`dpkg -l` inside the shell. Installation always runs through the reviewed apt tool; the shell commands only query. Bundled pure-Python capabilities are installed already; managed ones return after review.
            ### Linux fidelity and honest limits
            - The shell is POSIX `sh`. Command output and exit codes follow shell conventions; `sudo`, native ELF binaries and daemons are unavailable on iOS (no fork/exec, no root).
            - Most file/text tools come from the BSD userland: `sed -i` requires a backup suffix, `ls`/`grep`/`date` flags may differ from GNU. Prefer the agent's workspace tools when exact GNU behavior matters, or run Python for precise text handling.
            - `python3` runs the bundled CPython (no pip inside the shell; use apt). Network diagnostics (`ping`, `traceroute`, `dig`, `nc`, `sha256sum`) are device-backed Floe commands and never use a remote host.
            - WASM command packages installed from the signed catalog run sandboxed with no sockets. Data-only `.deb` payloads extract with `dpkg -x` after native contents are rejected.
            ### File rules
            All paths are workspace-relative; the shell is confined to the current task workspace. Never write outside it and never treat shell output as verified until a follow-up read confirms it.
            """
        ),
        Definition(
            id: "floe-image-edit",
            name: "Image Editing Recipes",
            description: "Deterministic Pillow-based image edits that replaced image.process: resize, rotate, crop, convert and thumbnails.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Image editing without image.process
            `image.process` was retired in favor of standard tooling. Run the exact source below with `exec.localPython`, passing task data in `inputJSON`; do not rewrite the source or vary parameter names. Output paths are workspace-relative and never overwrite by accident: the recipe refuses an existing output unless `"overwrite": true`.
            ### Parameters
            `operation` ∈ resize | rotate | crop | convert | thumbnail | grayscale; `path` (input); `outputPath`; then per-operation: resize `width`/`height` (one may be null to preserve aspect) ; rotate `degrees` + `expand`; crop `left`,`top`,`right`,`bottom`; convert `format` (`png`|`jpeg`|`webp`|`bmp`|`gif`|`tiff`) + `quality`; thumbnail `maxSize`.
            ### exact source
            ```python
            import io, json, os
            from PIL import Image
            data = input
            root = data.get("root")  # the runtime resolves paths relative to the task workspace via cwd
            def resolve(p):
                if os.path.isabs(p) or ".." in p.split("/"):
                    raise ValueError("workspace-relative paths only")
                return p
            src = resolve(data["path"])
            dst = resolve(data["outputPath"])
            if os.path.exists(dst) and not data.get("overwrite"):
                raise FileExistsError(f"output exists: {dst}")
            image = Image.open(src)
            op = data["operation"]
            if op == "resize":
                image = image.resize((data.get("width") or image.width, data.get("height") or image.height))
            elif op == "rotate":
                image = image.rotate(float(data["degrees"]), expand=bool(data.get("expand", True)))
            elif op == "crop":
                image = image.crop((int(data["left"]), int(data["top"]), int(data["right"]), int(data["bottom"])))
            elif op == "thumbnail":
                image.thumbnail((int(data["maxSize"]), int(data["maxSize"])))
            elif op == "grayscale":
                image = image.convert("L")
            fmt = (data.get("format") or Image.open(src).format or "PNG").upper()
            save_kwargs = {}
            if fmt in ("JPEG", "WEBP") and data.get("quality"):
                save_kwargs["quality"] = int(data["quality"])
            image.save(dst, format=fmt, **save_kwargs)
            print(json.dumps({"path": dst, "format": fmt, "size": list(image.size)}))
            ```
            """
        ),
        Definition(
            id: "floe-svg",
            name: "SVG Documents",
            description: "Inspect and edit SVG documents with the standard library after image.svgDocument was retired.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## SVG inspect / edit
            `image.svgDocument` was retired. Use `exec.localPython` with the standard library for inspection and bounded edits.
            ### Inspect source (exact)
            ```python
            import json, xml.etree.ElementTree as ET
            tree = ET.parse(input["path"]); root = tree.getroot()
            counts = {}
            for node in root.iter():
                tag = node.tag.split("}")[-1]
                counts[tag] = counts.get(tag, 0) + 1
            print(json.dumps({"root": root.tag, "viewBox": root.get("viewBox"), "elements": counts}))
            ```
            ### Edit source (exact)
            Replaces the text content of every element whose `id` matches `targetID`, or sets attributes from `attributes`, then writes `outputPath` (workspace-relative, refuses to overwrite without `overwrite: true`).
            ```python
            import json, os, xml.etree.ElementTree as ET
            data = input
            dst = data["outputPath"]
            if os.path.exists(dst) and not data.get("overwrite"):
                raise FileExistsError(f"output exists: {dst}")
            tree = ET.parse(data["path"]); root = tree.getroot()
            changed = 0
            for node in root.iter():
                if data.get("targetID") and node.get("id") == data["targetID"]:
                    if "text" in data:
                        node.text = data["text"]; changed += 1
                    for key, value in (data.get("attributes") or {}).items():
                        node.set(key, str(value)); changed += 1
            if changed == 0:
                raise ValueError("no element matched targetID")
            tree.write(dst, encoding="utf-8", xml_declaration=True)
            print(json.dumps({"path": dst, "changes": changed}))
            ```
            Do not attempt filters, masks or rasterization here; use the image tools or a remote host for those.
            """
        ),
        Definition(
            id: "floe-text-edit",
            name: "Text Edit Recipes",
            description: "Append and exact-replace recipes that replaced workspace.appendFile and workspace.replaceText.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Deterministic text edits
            `workspace.appendFile` and `workspace.replaceText` were retired in favor of `workspace.applyPatch`/`workspace.writeFile` plus these two exact recipes. Run them with `exec.localPython` and task data in `inputJSON`; every write is concurrency-checked against `expectedSHA256`.
            ### Append (exact source)
            ```python
            import hashlib, json, os
            data = input
            path = data["path"]
            if os.path.isabs(path) or ".." in path.split("/"):
                raise ValueError("workspace-relative paths only")
            raw = open(path, "rb").read()
            if b"\\x00" in raw:
                raise ValueError("binary file")
            text = raw.decode("utf-8")
            if data.get("expectedSHA256") and hashlib.sha256(raw).hexdigest() != data["expectedSHA256"]:
                raise RuntimeError("stale expectedSHA256; re-read the file")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text + data["content"])
            print(json.dumps({"path": path, "bytes": len((text + data["content"]).encode())}))
            ```
            ### Replace (exact source)
            `oldText` must match exactly `expectedOccurrences` times (default 1); otherwise nothing is written.
            ```python
            import hashlib, json, os
            data = input
            path = data["path"]
            if os.path.isabs(path) or ".." in path.split("/"):
                raise ValueError("workspace-relative paths only")
            raw = open(path, "rb").read()
            if b"\\x00" in raw:
                raise ValueError("binary file")
            text = raw.decode("utf-8")
            if data.get("expectedSHA256") and hashlib.sha256(raw).hexdigest() != data["expectedSHA256"]:
                raise RuntimeError("stale expectedSHA256; re-read the file")
            occurrences = text.count(data["oldText"])
            expected = int(data.get("expectedOccurrences", 1))
            if occurrences != expected:
                raise ValueError(f"expected {expected} matches, found {occurrences}")
            updated = text.replace(data["oldText"], data["newText"])
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(updated)
            print(json.dumps({"path": path, "occurrences": occurrences}))
            ```
            """
        ),
    ]
}
