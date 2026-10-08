#!/usr/bin/env bash
# One-shot application of the localization migration onto a clean tree.
# Assumes: FloeL10n.swift, FloeL10nTests.swift, widget catalog, scripts/l10n
# and the task-owned l10n binaries already exist. Idempotent-ish: run on a
# tree with no prior migration edits.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${FLOE_L10N_BIN:-$HOME/Library/Caches/CodexBuild/Floe/promo-english/l10n-bin}"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

# 1. Core wiring (manual, must not clobber file contents).
python3 scripts/l10n/apply_core_wiring.py

# 2. Extract, plan, emit offset maps. Stale maps must never be re-applied
#    (their offsets refer to earlier file states), so clear the map dir.
find FloeApp Sources FloeShare FloeScreenShare FloeWidgets -name '*.swift' > /tmp/l10n-files.txt
rm -rf /tmp/l10n-out/maps
"$BIN/l10n-extract" $(cat /tmp/l10n-files.txt) > /tmp/l10n-occ.json
python3 scripts/l10n/plan.py
python3 scripts/l10n/migrate.py --out /tmp/l10n-out --apply

# 3. AST rewrite sources.
n=0
for map in /tmp/l10n-out/maps/*.json; do
  f=$(basename "$map" .json | sed 's/__/\//g')
  [ -f "$f" ] || { echo "MISSING $f" >&2; continue; }
  "$BIN/l10n-rewrite" "$map" "$f"
  n=$((n+1))
done
echo "rewrote $n files"

# 4. Add `import FloeCore` where needed.
python3 scripts/l10n/add_imports.py

# 5. Hand-maintained special surfaces.
python3 scripts/l10n/apply_special.py

# 6. Install merged catalog + app-intent/ink keys.
cp /tmp/l10n-out/Localizable.xcstrings FloeApp/Resources/Localizable.xcstrings
python3 scripts/l10n/add_manual_keys.py
python3 scripts/validate_localization_catalog.py

# 7. Regenerate project.
xcodegen generate
echo "migration applied"
