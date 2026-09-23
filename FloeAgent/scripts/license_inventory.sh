#!/bin/bash
# license_inventory.sh — generate the Floe third-party declaration.
#
# Writes, from the resolved lock and the real upstream license files:
#   LICENSES-THIRD-PARTY.md
#   FloeApp/Resources/Licenses/third-party-inventory.json  (packaged manifest)
#   FloeApp/Resources/Licenses/libgit2-COPYING.txt         (linked libgit2 text)
#   scripts/license-evidence.json                          (detection evidence)
#
# Usage:
#   scripts/license_inventory.sh            write the artifacts and validate
#   scripts/license_inventory.sh --check    read-only drift/consistency check
#
# The generator fails the build for GPL/LGPL/AGPL components that are not one of
# the explicitly recorded exceptions, for a notice that project.yml does not
# copy into the app bundle, and for a localization key the catalog is missing.
set -euo pipefail

cd "$(dirname "$0")/.."

exec python3 scripts/license_inventory.py "$@"
