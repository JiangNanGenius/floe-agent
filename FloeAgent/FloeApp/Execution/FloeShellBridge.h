//
//  FloeShellBridge.h
//  Floe Agent
//
//  Thin Objective-C bridge to the ios_system command bus. Only the app
//  target links ios_system, so all C-level access stays here; Swift sees a
//  narrow, testable API.
//
//  Notes from the a-Shell/ios_system integration model (BSD-3):
//  - ios_system runs commands on pthreads; per-command stdio lives in
//    thread-local FILE* variables (thread_stdin / thread_stdout /
//    thread_stderr). The bridge sets these on the calling thread before
//    dispatching, and the dispatcher passes them to child commands.
//  - There is no fork/exec: "sudo", native ELF and long-running daemons are
//    impossible on iOS. ios_setMiniRoot limits directory navigation; it is not a filesystem sandbox.
//  - Cancellation is cooperative: dash observes an owned-session flag on its
//    execution thread. Other native commands may outlive the caller; worker
//    state and resources remain retained until they actually finish.

#import <Foundation/Foundation.h>
#import "FloeTLSConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, FloeShellBridgeStatus) {
    FloeShellBridgeStatusOK = 0,
    FloeShellBridgeStatusEngineUnavailable = 1,
    FloeShellBridgeStatusTimedOut = 2,
    FloeShellBridgeStatusCancelled = 3,
    /// The engine's serial run gate was still owned when `gateTimeout`
    /// elapsed. The command never started: this is NOT an execution timeout.
    FloeShellBridgeStatusBusy = 4,
};

/// One-shot command execution with captured stdout/stderr.
///
/// `gateTimeout` bounds only the wait for the process-wide engine gate. A
/// command that cannot start inside that window returns `Busy` with its
/// output untouched; `timeout` bounds the execution itself once the gate is
/// owned. The gate serializes every use of the process-wide ios_system engine:
/// after a timeout or cancellation the bridge requests cooperative
/// interruption and waits a bounded grace for the worker to actually stop.
/// A cooperative worker finishes inside that window and its own teardown
/// releases the gate, so the next command starts immediately. A worker that
/// ignores cancellation is quarantined instead of being released into
/// concurrency: the bridge detaches it, stops its output readers at a bounded
/// deadline and returns the timeout/cancel outcome with the bytes already
/// captured, but it deliberately keeps the gate held, because that worker may
/// still be executing inside ios_system and may still mutate process-global
/// state (working directory, environment, mini root, session registries).
/// The gate is released exactly once by the quarantined worker's own teardown
/// after ios_system has returned — a later command only enters the engine
/// after the old worker is proven stopped; until then new commands report
/// `Busy`/not-started with quarantine diagnostics, never a fabricated timeout.
FloeShellBridgeStatus FloeShellRunCommand(
    NSString *command,
    NSString *rootPath,
    NSString *workingDirectory,
    NSString *sessionID,
    NSDictionary<NSString *, NSString *> *environment,
    NSData * _Nullable stdinData,
    NSTimeInterval timeout,
    NSTimeInterval gateTimeout,
    NSUInteger maxOutputBytes,
    BOOL (^ _Nullable shouldCancel)(void),
    NSString * _Nullable * _Nullable outStdout,
    NSString * _Nullable * _Nullable outStderr,
    int32_t *outExitCode
);

/// One-line, bounded diagnostics for the engine run gate (owner, held time,
/// waiters, busy returns). Safe to log; contains no command or user content.
NSString *FloeShellRunGateDiagnostics(void);

/// Opens a persistent interactive session. On success, `outInputFD` is the
/// write end of the session's stdin pipe and `outOutputFD` is the read end of
/// its stdout/stderr pipe; both are owned by the bridge registry and closed
/// by FloeShellCloseSession.
BOOL FloeShellOpenSession(
    NSString *command,
    NSString *rootPath,
    NSString *workingDirectory,
    NSString *sessionID,
    NSDictionary<NSString *, NSString *> *environment,
    NSInteger columns,
    NSInteger rows,
    int *outInputFD,
    int *outOutputFD,
    NSString * _Nullable * _Nullable outInitialOutput
);

/// Requests engine interruption. INT/TERM/KILL never become process signals.
void FloeShellSignalSession(NSString *sessionID, int signalNumber);

/// Transfers descriptor ownership for an interactive session to the caller's
/// output pump. After a successful claim the bridge never closes the session's
/// pipe descriptors: the pump reads/writes and closes them after its loop ends.
/// Returns NO when the session record no longer exists (closed or expired while
/// the caller was still between open and claim); in that case the descriptors
/// are already closed and the caller must not touch them.
BOOL FloeShellClaimSessionDescriptors(NSString *sessionID);

/// Closes all descriptors for a session and forgets it. For a session whose
/// descriptors are pump-owned this only requests cooperative interruption;
/// the pump performs teardown and calls FloeShellEndSession.
void FloeShellCloseSession(NSString *sessionID);

/// Forgets a session after its owning pump has drained and closed its own
/// descriptors. Never closes descriptors and never signals.
void FloeShellEndSession(NSString *sessionID);

void FloeShellResizeSession(NSString *sessionID, NSInteger columns, NSInteger rows);
/// True until native work has actually unwound, including after timeout/close.
BOOL FloeShellHasActiveWorker(NSString *sessionID);
/// True while the interactive session record exists and its command thread
/// has not finished. Distinguishes a ready prompt from an immediately-exited
/// program at open time.
BOOL FloeShellSessionAlive(NSString *sessionID);
BOOL FloeShellSessionExitCode(NSString *sessionID, int32_t *code);

/// Sets the mini-root confinement for a session's future resolves.
BOOL FloeShellSetMiniRoot(NSString *rootPath);

/// Applies environment overrides for future commands (PATH, HOME, TMPDIR…).
void FloeShellSetEnvironment(NSDictionary<NSString *, NSString *> *environment);
/// Snapshot of the calling shell command's exported environment.
NSDictionary<NSString *, NSString *> *FloeShellCurrentEnvironment(void);

/// YES when the ios_system command bus is linked and initialized.
BOOL FloeShellEngineAvailable(void);

/// Registers a Floe Swift command implementation (`floe_shell_command_main`)
/// under `name`, replacing the ios_system entry when one exists. Safe to call
/// for names the command dictionary does not contain.
void FloeShellRegisterCommand(NSString *name);
BOOL FloeShellCurrentCommandCancelled(void);

/// Thread-local stdio accessors for command handlers that run on a Swift
/// executor while the command invocation lives on an ios_system pthread.
NSString * _Nullable FloeShellCurrentSessionID(void);
NSString * _Nullable FloeShellCurrentWorkingDirectory(void);
FILE * _Nullable FloeShellCurrentStdin(void);
FILE * _Nullable FloeShellCurrentStdout(void);
FILE * _Nullable FloeShellCurrentStderr(void);
void FloeShellWrite(FILE * _Nullable stream, const char *text);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
