// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Guest-only prerequisite commands, executed by the original owned exec.shell
/// jobs. No host process, global Node replacement, floating release or local model.
public enum C02MCPNodePrerequisites {
    public static let version = "v24.22.2"
    public static let source = "https://nodejs.org/dist/v24.22.2/SHASUMS256.txt"
    public static let arm64SHA256 = "95c264150aceb7f3437a29fd6984924f5f8d1511ea3cbd6c508b83f6c555dae2"
    public static let x64SHA256 = "361718c444e49af2ca5a110c83ba6a8901143f23ab285ebbef0341f391f482a9"

    /// This file is sourced, never executed as a separate process: PATH must
    /// reach npm and its child node invocations, as well as the managed server.
    public static let environment = #"""
    [ "$(uname -s)" = Linux ] || { echo 'A Linux environment is required.' >&2; return 65; }
    case "$(uname -m)" in
      aarch64|arm64) FLOE_NODE_ARCH=arm64 ;;
      x86_64|amd64) FLOE_NODE_ARCH=x64 ;;
      *) echo 'This Linux architecture has no pinned Node runtime.' >&2; return 65 ;;
    esac
    FLOE_NODE_HOME="/opt/floe/node/v24.22.2-linux-$FLOE_NODE_ARCH"
    if [ -x "$FLOE_NODE_HOME/bin/node" ] && [ -x "$FLOE_NODE_HOME/bin/npm" ]; then
      PATH="$FLOE_NODE_HOME/bin:$PATH"
      export PATH
    fi
    floe_node_usable() {
      command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 &&
        node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>20||(a===20&&b>=19)?0:1)' >/dev/null 2>&1
    }
    """#

    /// Installs only into the selected project's Linux write layer. Existing
    /// compatible Node is retained, and /usr/bin or /usr/local/bin is untouched.
    public static let prepare = #"""
    set -eu
    . ./floe-node-env.sh
    if ! floe_node_usable; then
      if [ -e "$FLOE_NODE_HOME" ] || [ -L "$FLOE_NODE_HOME" ]; then
        echo 'The Floe Node cache is incomplete. Repair it in this Linux environment before retrying.' >&2
        exit 65
      fi
      if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        command -v apt-get >/dev/null 2>&1 || { echo 'curl, tar and sha256sum are required.' >&2; exit 69; }
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl tar gzip coreutils
      fi
      case "$FLOE_NODE_ARCH" in
        arm64) floe_node_sha=95c264150aceb7f3437a29fd6984924f5f8d1511ea3cbd6c508b83f6c555dae2 ;;
        x64) floe_node_sha=361718c444e49af2ca5a110c83ba6a8901143f23ab285ebbef0341f391f482a9 ;;
      esac
      mkdir -p /opt/floe/node
      floe_node_stage=$(mktemp -d /opt/floe/node/.prepare.XXXXXXXX)
      trap 'rm -rf -- "$floe_node_stage"' EXIT
      trap 'exit 130' INT
      trap 'exit 143' HUP TERM
      floe_node_archive="$floe_node_stage/runtime.tar.gz"
      curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --max-time 240 --max-filesize 100000000 \
        --output "$floe_node_archive" \
        "https://nodejs.org/dist/v24.22.2/node-v24.22.2-linux-$FLOE_NODE_ARCH.tar.gz"
      printf '%s  %s\n' "$floe_node_sha" "$floe_node_archive" | sha256sum -c -
      mkdir "$floe_node_stage/runtime"
      tar -xzf "$floe_node_archive" --strip-components=1 -C "$floe_node_stage/runtime"
      [ "$("$floe_node_stage/runtime/bin/node" --version)" = v24.22.2 ]
      # Rename the complete verified installation; a failed download or extract
      # never replaces an existing runtime or publishes a partial final path.
      [ ! -e "$FLOE_NODE_HOME" ] && [ ! -L "$FLOE_NODE_HOME" ]
      mv -T -- "$floe_node_stage/runtime" "$FLOE_NODE_HOME"
      . ./floe-node-env.sh
    fi
    floe_node_usable
    printf 'FLOE_OS=%s\n' "$(uname -s)"
    printf 'FLOE_ARCH=%s\n' "$(uname -m)"
    printf 'FLOE_NODE=%s\n' "$(node --version)"
    printf 'FLOE_NPM=%s\n' "$(npm --version)"
    """#

    public static let launcher = #"""
    #!/bin/sh
    set -eu
    floe_service_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
    . "$floe_service_directory/floe-node-env.sh"
    floe_node_usable || { echo 'Prepare this MCP service before starting it.' >&2; exit 69; }
    exec node "$floe_service_directory/floe-start.mjs"
    """#
}
