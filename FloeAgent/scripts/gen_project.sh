#!/bin/bash
# gen_project.sh — Regenerate the Xcode project and verify the tree is clean.
# The .xcodeproj is a generated artifact: it must never diverge from
# project.yml, so CI regenerates and fails if git reports changes.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not installed (brew install xcodegen)" >&2
    exit 1
fi

xcodegen generate

if ! git diff --quiet -- . ':(exclude)Package.resolved'; then
    echo "error: working tree dirty after xcodegen; commit project.yml changes" >&2
    git status --short
    exit 1
fi

echo "xcodegen OK; working tree clean"
