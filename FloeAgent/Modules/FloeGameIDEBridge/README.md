# Floe game IDE extension

Floe-authored source is MPL-2.0. The game overview remains the simple outer
shell. Files, text buffers, search, terminal and source control belong to the
existing Floe IDE. This package contains only workspace binding and whole-game
Run orchestration; it contains no alternate editor or Git implementation.

The App supplies `GameIDEProjectHost` over its existing WorkspaceCenter,
WorkspaceFileService and owned game run/jobs service. Use the same live owned
workspace directory for the game shell and IDE; immutable test snapshots are
not a second editable project. Preserve `.git`, remotes, staging and unrelated
working changes. An AI/save operation does not automatically commit or push.

`IDEProjectRunExtension` receives the IDE's actual `saveAllSurfaces` closure.
A conflict aborts dispatch. After saving, the host captures the full saved game
project, with its owner, environment and selected nested game root. Git changes
and workspace switches during preparation fence the old request. Stop uses a
unique owned request ID rather than the current global run.

`MainBindingDraft` beside the package contains a reviewable adapter/patch
against the actual existing WorkspaceIDEView. Main App integration and its
compilation are separate from component qualification; the temporary closure
host text editor is a test fixture, not the product editor.
