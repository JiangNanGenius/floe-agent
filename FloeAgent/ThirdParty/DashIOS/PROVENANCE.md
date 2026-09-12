# dash iOS source

Upstream: https://github.com/holzschu/dash_iOS
Revision: 3da49bb7ac15458ea4f554b589dde5197816f6ba

BSD licenses are retained in COPYING and source headers. Build with scripts/build_dash_ios.sh.

Floe builds six separate framework images for the upstream interpreter slots,
with arm64 iOS and universal arm64/x86_64 simulator slices. Runtime version: dash 0.5.11.5.
Autoconf auxiliary scripts are provided by the build host Automake installation.

Floe integration patch: command lookup recognizes ios_system framework commands
through ios_executable after checking shell builtins, before searching PATH.
Without this, native commands are incorrectly treated as missing executables.
