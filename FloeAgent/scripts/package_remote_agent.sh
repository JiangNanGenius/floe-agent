#!/bin/sh
set -eu

OUTPUT_DIRECTORY="${1:-release-assets}"
VERSION="${2:-1.3.0}"
SOURCE_DIRECTORY="Sources/FloeExecution/Resources/RemoteAgent"
ARCHIVE_NAME="floe-remote-agent-${VERSION}.tar.gz"

test -f "$SOURCE_DIRECTORY/floe_remote_agent.py"
test -f "$SOURCE_DIRECTORY/floe_agent_update.py"
mkdir -p "$OUTPUT_DIRECTORY"

STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/floe-remote-agent.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT HUP INT TERM

cp "$SOURCE_DIRECTORY/floe_remote_agent.py" "$STAGING_DIRECTORY/floe_remote_agent.py"
cp "$SOURCE_DIRECTORY/floe_agent_update.py" "$STAGING_DIRECTORY/floe_agent_update.py"
chmod 755 "$STAGING_DIRECTORY/floe_remote_agent.py" "$STAGING_DIRECTORY/floe_agent_update.py"

printf '%s\n' \
  "{\"agent_version\":\"$VERSION\",\"repository\":\"JiangNanGenius/floe-agent\",\"loopback_port\":43187,\"mutual_tls_port\":43188}" \
  > "$STAGING_DIRECTORY/REMOTE-AGENT-MANIFEST.json"

ARCHIVE_PATH="$OUTPUT_DIRECTORY/$ARCHIVE_NAME"
COPYFILE_DISABLE=1 tar -C "$STAGING_DIRECTORY" -czf "$ARCHIVE_PATH" \
  floe_remote_agent.py \
  floe_agent_update.py \
  REMOTE-AGENT-MANIFEST.json

(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

tar -tzf "$ARCHIVE_PATH" | sort
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 -c "$ARCHIVE_NAME.sha256"
)
