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

Cancellation patch: evaltree polls the App's `floe_shell_should_cancel` hook
and raises EXEXIT with status 130 on the interpreter thread. The bridge never
calls ios_kill, whose pinned v3.0.2 implementation may invoke a process-global
SIGINT handler on the caller thread. Native qualification covers cancellation,
timeout, subsequent execution and interactive input/close. Other blocking
native commands still require their own cooperative cancellation support.

Floe feedback repair (2026-09-14): pipeline PIDs are allocated only after command expansion resolves an external command. Missing and unsupported consumers close pending streams; unsafe builtin/function/compound consumers report exit 2. Compound-producer exception unwinding closes/restores pipe streams before joining the consumer, preventing a cancelled producer from retaining an EOF waiter. Native iOS simulator evidence is in `docs/validation/floe-156-feedback/shell-results.json` at the repository root.

Argument/environment transport repair: the pinned ios_system `ios_execv`
reconstructs a command string and only quotes arguments containing spaces.
Floe protects expanded arguments with the engine's existing 0x1e literal
delimiter before calling `ios_execve` with Dash's exported environment. Inputs
containing that reserved delimiter are rejected before allocating a PID. This
prevents already-parsed JavaScript arrows, pipes and quotes from being parsed
as shell redirections again. `floe_shell_command_alias` is an optional App hook
used to route python/python3 to the single production CPython service without
the engine's upstream PythonA/PythonB library-name rewrite. The same transport
is used for ordinary commands, pipeline consumers and the exec builtin.

The native host now contains 26 cases, including literal empty/CJK arguments,
exported variables and repeated Python-alias callback dispatch. Those callback
fixtures do not qualify actual Python/Node inference or full App integration.
