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
//  - A one-shot run that exceeds its deadline cannot be forcibly reaped on
//    another thread; the bridge sends SIGINT and reports a timeout while the
//    worker thread finishes (same documented boundary as the JS engine).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, FloeShellBridgeStatus) {
    FloeShellBridgeStatusOK = 0,
    FloeShellBridgeStatusEngineUnavailable = 1,
    FloeShellBridgeStatusTimedOut = 2,
    FloeShellBridgeStatusCancelled = 3,
};

/// One-shot command execution with captured stdout/stderr.
FloeShellBridgeStatus FloeShellRunCommand(
    NSString *command,
    NSString *rootPath,
    NSString *workingDirectory,
    NSString *sessionID,
    NSDictionary<NSString *, NSString *> *environment,
    NSData * _Nullable stdinData,
    NSTimeInterval timeout,
    NSUInteger maxOutputBytes,
    BOOL (^ _Nullable shouldCancel)(void),
    NSString * _Nullable * _Nullable outStdout,
    NSString * _Nullable * _Nullable outStderr,
    int32_t *outExitCode
);

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

/// Closes all descriptors for a session and forgets it.
void FloeShellCloseSession(NSString *sessionID);
void FloeShellResizeSession(NSString *sessionID, NSInteger columns, NSInteger rows);
BOOL FloeShellSessionExitCode(NSString *sessionID, int32_t *code);

/// Sets the mini-root confinement for a session's future resolves.
BOOL FloeShellSetMiniRoot(NSString *rootPath);

/// Applies environment overrides for future commands (PATH, HOME, TMPDIR…).
void FloeShellSetEnvironment(NSDictionary<NSString *, NSString *> *environment);

/// YES when the ios_system command bus is linked and initialized.
BOOL FloeShellEngineAvailable(void);

/// Registers a Floe Swift command implementation (`floe_shell_command_main`)
/// under `name`, replacing the ios_system entry when one exists. Safe to call
/// for names the command dictionary does not contain.
void FloeShellRegisterCommand(NSString *name);

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
