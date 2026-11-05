# ARM64 9P symlink protocol qualification

`SymlinkProtocolTests.c` includes the actual `virtio_9p.c` device parser and
dispatches encoded 9P2000.L packets against real temporary directories. It
does not substitute filesystem operations or boot a guest. The App wrapper
adds logging redirection only; this host qualification exercises the same
filesystem implementation without Machine/DMA/interrupt acceptance.

The regression preserves final symlink qids, `getattr`, `readlink`, node
removal and bounded content opens. It also checks that a symlink fid cannot
become a directory argument to rename/unlink, intermediate escaping paths
remain refused, contained traversal still works, and read-only/generation
boundaries remain enforced. `ELOOP` must be Linux wire value 40 on Darwin.

Run from the repository root, using the shared native build window when
working on the project development host:

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer
FLOE_NINEP_BUILD="$HOME/Library/Caches/CodexBuild/FloeAgent/main/xcode-27A9275/NineP"
mkdir -p "$FLOE_NINEP_BUILD"
xcrun clang -std=c11 -D_DARWIN_C_SOURCE -O1 -g -ffunction-sections \
  -fsanitize=address,undefined -Wl,-dead_strip \
  FloeAgent/Qualification/ARM64NineP/SymlinkProtocolTests.c \
  -o "$FLOE_NINEP_BUILD/protocol-tests"
"$FLOE_NINEP_BUILD/protocol-tests" "$FLOE_NINEP_BUILD"
```

Success prints `NINEP_PROTOCOL_OK checks=16`. The original implementation
fails the first final-link qid assertion. The initial walk repair also
exposed the existing Darwin-to-Linux `ELOOP` translation defect; its assertion
is retained. Generated `fixture-*` trees belong only to this executable and
can be removed after retaining required evidence.

App-hosted ARM64 Skill workflows must be rerun after the release owner
updates the runtime provenance and builds the integrated App. A host packet
pass does not replace that result.
