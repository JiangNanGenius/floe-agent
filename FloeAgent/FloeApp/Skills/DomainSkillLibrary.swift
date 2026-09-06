#if canImport(UIKit)
import Foundation

/// Bundled domain skills shipped inside the app. Content updates ONLY with
/// app releases (the seeder re-installs them on version bump); there is no
/// runtime or remote update channel for built-in skills.
///
/// Two classes: `exposed` skills are visible in the skill hub (users can
/// enable/disable them and see version upgrades); hidden built-ins stay out
/// of the hub but remain readable on demand via `skill.read`.
enum DomainSkillLibrary {
    struct Definition: Sendable {
        let id: String
        let name: String
        let description: String
        let version: String
        /// true = visible in the skill hub; false = hidden built-in.
        let exposed: Bool
        let markdown: String
    }

    static let builtinSourceScheme = "floe-builtin://"

    static func sourceURL(for id: String) -> String { builtinSourceScheme + id }

    static let all: [Definition] = [
        // MARK: Exposed to the hub (office / pdf / network)
        Definition(
            id: "floe.pdf",
            name: "PDF Workbench",
            description: "Closed-loop PDF workflow: inspect, render, merge, split, edit, fill forms, verify.",
            version: "1.0.0",
            exposed: true,
            markdown: """
            ## PDF workbench
            Follow this closed loop for PDF tasks:
            1. **Inspect first**: `document.pdf.inspect` for page count, metadata, text, and query matches before planning any edit.
            2. **Render only relevant pages** with `document.pdf.render` (single page or a spec like "1-3,5") when visual evidence is needed.
            3. **Compose**: `document.pdf.merge` (2-10 PDFs in order), `document.pdf.split` (extract pages "1-3,5,8-10"), `document.pdf.fromImages` (one image per page).
            4. **Edit** with `document.pdf.edit`: page removal, per-page 90-degree rotations (`rotations`), positioned watermarks (`watermarkPosition`/`watermarkPages`), page numbers, and `userPassword`/`ownerPassword` encryption. Its `replaceText` is an **annotation-layer cover-and-replace**: the original content stream is visually covered, never rewritten — covered text is not selectable/searchable and fonts may differ. True content-stream rewriting is not available (PDFKit boundary); never claim it.
            5. **Forms**: `document.pdf.fillForm` lists AcroForm fields (name + type) and fills text/checkbox/dropdown/radio/option-list fields with per-type validation. Unknown fields and invalid options are reported, never silently applied.
            6. **Save to a new output** unless the user explicitly asked for overwrite, then reopen the saved file with `document.pdf.inspect` and render the changed pages to verify.
            """
        ),
        Definition(
            id: "floe.office",
            name: "Office Documents",
            description: "Word, workbook and Markdown creation/inspection/editing with the right tool for each job.",
            version: "1.0.0",
            exposed: true,
            markdown: """
            ## Office document workflow
            - **Word (.docx)**: `document.createWord` generates a real OOXML document; `document.office.inspect` returns stable field IDs; `document.updateText` edits those fields (creates only with explicit IDs from inspect; never guess).
            - **Workbook (.xlsx)**: `document.createWorkbook` builds a spreadsheet from sheet JSON. To **read** cell values quickly use `document.readSheet` (read-only TSV). To **edit** use `document.office.inspect` first — it returns the editable field/formula IDs that `document.updateText` consumes. Do not treat readSheet output as editable IDs.
            - **Markdown**: `document.createMarkdown` writes .md/.markdown/.txt only (for .docx use createWord).
            - **Fonts**: before `font.remove`, call `font.list` and reuse the exact digest id — never derive it from a filename.
            - Always reopen/inspect the saved artifact to verify, and save to a new file unless overwrite was explicitly requested.
            """
        ),
        Definition(
            id: "floe.network",
            name: "Network Diagnostics",
            description: "Ping, traceroute, DNS, LAN scan and raw HTTP with the right boundary versus web.fetch.",
            version: "1.0.0",
            exposed: true,
            markdown: """
            ## Network diagnostics workflow
            - `network.ping`, `network.traceroute`, `network.dnsLookup` diagnose reachability on the **local device** by default; pass a paired `hostID` only when the user wants the probe run from that remote host.
            - `network.lanScan` enumerates the local network — run it only when the user asked for discovery or a LAN diagnostic.
            - `network.http` issues raw HTTP with full method/headers/body control for APIs, status checks and non-browser HTTP. When the goal is **reading a web page as content**, use `web.fetch` instead (returns readable markdown; web.search/web.fetch/web.download are basic capabilities and need no guide).
            - Credential URLs and cloud metadata endpoints are blocked; never try to bypass those blocks or exfiltrate instance metadata.
            """
        ),
        // MARK: Hidden built-ins
        Definition(
            id: "floe.python",
            name: "Local Python Runtime",
            description: "The bundled CPython substrate: usage rules, bundled libraries, and the contract every script-carrying skill executes under.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Local Python (exec.localPython)
            ### Using the runtime
            - Bundled CPython 3.13 stdlib extensions: asyncio, json, csv, sqlite3, zipfile, tarfile, gzip, bz2, lzma, hashlib, hmac, secrets, ctypes, xml.etree, mmap, zoneinfo, statistics and more. Desktop shell modules (curses, readline, grp, pwd, syslog, multiprocessing) do not exist on iOS.
            - **numpy (2.5.2) and Pillow (11.0, import as PIL) ARE bundled natively** — import and use them directly; never claim they are unavailable and never route them to WebAssembly.
            - pandas, scipy and matplotlib have no compatible iOS build upstream: use the browser-based **Pyodide WebAssembly** route (workspace HTML + public-HTTPS Pyodide, JSON in/out). Never claim a native install when code ran in WebAssembly.
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
            id: "floe.apple",
            name: "Apple Capabilities",
            description: "Mail, calendar, photos, home, reminders, shortcuts, clipboard and camera rules in one place.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Apple capability rules
            - **Stable IDs**: list before update/delete and reuse the exact returned id (calendar events, reminders, automations, home accessoryID+characteristicID). Create actions need no prior id.
            - **Mail**: `apple.mail.compose` only opens the compose UI — it never sends. `mail.send` sends through the configured SMTP account with approval. Read/search/download via `mail.*` connector tools.
            - **Photos**: library reads may trigger iCloud downloads; save new captures to the workspace through `apple.camera.capture` (bounded, user-visible) or `apple.photos.save` with approval.
            - **Home**: control only writable characteristics with both exact IDs from `apple.home.list`.
            - **Reminders/Calendar**: create with clear titles/times; edits always go list-first.
            - **Shortcuts**: `apple.shortcuts.run` executes an installed shortcut by exact name with bounded input/output.
            - **Clipboard**: reads/writes are approval-gated and one-shot; never stash clipboard content into memory or files unless the user asked.
            - **Permissions**: if a capability reports missing authorization, name the exact Settings path instead of retrying blindly.
            """
        ),
        Definition(
            id: "floe.data-code",
            name: "Data & Code Execution",
            description: "On-device JavaScript, the compatibility evaluator, canvas mutations, and generate-tool boundaries.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Data & code execution (on-device)
            - `exec.javascript` runs bounded JavaScriptCore with pre-installed pure-JS packages (lodash, dayjs, marked, uuid, zod, pdf-lib) — no network, no Node APIs, no timers beyond a microtask shim.
            - `exec.compatEvaluator` is Floe's own R/Stata-**compatible** evaluator — it is NOT GNU R, Stata, Octave or MATLAB; for the full runtimes use an approved configured remote host. (Local Python lives in floe.python.)
            - **Canvas**: `canvas.getState` returns canvasID/documentID/revision/node IDs. Reuse the latest exact revision for patches/generation; mutation results return the new revision and a delta — apply it and continue without re-inspecting unless a revision conflict occurs.
            - **Generation split**: `image.generate` is AI text-to-image for a standalone image; `canvas.generate` produces media inside the canvas document/generation graph with source-node ancestry. Choose by where the result must live.
            - Remote daemon execution (ssh.execute/cloudWorkspace) is a different environment — see the Terminal toolkit guidance, not this skill.
            """
        ),
        Definition(
            id: "floe.browser",
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
            id: "floe.files-vcs",
            name: "Files & Version Control",
            description: "Workspace file discipline, safe-write checks, archive formats and the minimal Git sequence.",
            version: "1.0.0",
            exposed: false,
            markdown: """
            ## Files & version control
            - **Safe writes**: `workspace.write`/`applyPatch` validate `expectedSHA256`/`expectedMtime` when the file existed; read before overwrite and never bypass a mismatch — re-read and recompute instead.
            - **Read→modify→verify**: after writes, reopen with `workspace.read` or `searchFiles` to confirm; keep paths workspace-relative (no absolute, no `..`).
            - **Archives** (`workspace.archive`): zip/tar/7z natively; tgz/tbz2/txz and single-file gz/bz2/xz through the bundled CPython bridge. Extract of zip/tar/7z/tar.* outputs a **directory**; gz/bz2/xz outputs a **single file** (a trailing "/" destination places it inside). 7z is extract/list only; **rar is unavailable** (decoder licensing) — ask for zip/7z instead.
            - **Git** (workspace): ordered minimal sequence status → diff → stage → commit → (pull/push with explicit approval). No stash/tag/rebase/cherry-pick — do not fabricate them through other tools.
            """
        ),
        Definition(
            id: "floe.crypto",
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
#endif
