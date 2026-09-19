//
//  FloeShellBridge.mm
//  Floe Agent
//
//  Objective-C bridge to ios_system. See FloeShellBridge.h for the model.
//

#import "FloeShellBridge.h"

#import <pthread.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <poll.h>
#import <os/log.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <string>
#include <algorithm>

// The production target requires the pinned engine. Missing linkage is a
// build failure, not an apparently successful shell-enabled release.
extern "C" {
#import <ios_system/ios_system.h>
}
#define FLOE_HAS_IOS_SYSTEM 1

#pragma mark - Session registry

@interface FloeShellSessionRecord : NSObject
@property (nonatomic, copy) NSString *sessionID;
@property (nonatomic, assign) int inputWriteFD;
@property (nonatomic, assign) int outputReadFD;
@property (nonatomic, assign) pthread_t commandThread;
@property (nonatomic, strong) NSThread *thread;
@property (atomic, assign) BOOL closed;
@property (atomic, assign) BOOL finished;
/// Set by the caller's output pump after open. Descriptor teardown then
/// belongs to the pump, which serializes close with its own reads/writes.
@property (atomic, assign) BOOL pumpOwnsDescriptors;
@property (atomic, assign) int32_t exitCode;
@property (nonatomic, assign) char *engineSessionKey;
@end

@implementation FloeShellSessionRecord
- (void)dealloc { if (_engineSessionKey) free(_engineSessionKey); }
@end

static NSMutableDictionary<NSString *, FloeShellSessionRecord *> *FloeShellSessions(void) {
    static NSMutableDictionary *sessions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sessions = [NSMutableDictionary dictionary]; });
    return sessions;
}

static NSCountedSet<NSString *> *FloeActiveWorkers(void) {
    static NSCountedSet *workers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ workers = [NSCountedSet new]; });
    return workers;
}
static NSMutableSet<NSString *> *FloeCancelledWorkers(void) {
    static NSMutableSet *workers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ workers = [NSMutableSet new]; });
    return workers;
}
extern "C" __attribute__((visibility("default"), used)) int floe_shell_should_cancel(void) {
    NSString *sessionID = FloeShellCurrentSessionID();
    if (!sessionID) return 0;
    @synchronized (FloeCancelledWorkers()) { return [FloeCancelledWorkers() containsObject:sessionID] ? 1 : 0; }
}
static void FloeWorkerStarted(NSString *sessionID) {
    @synchronized (FloeCancelledWorkers()) { [FloeCancelledWorkers() removeObject:sessionID]; }
    @synchronized (FloeActiveWorkers()) { [FloeActiveWorkers() addObject:sessionID]; }
}
static void FloeWorkerFinished(NSString *sessionID) {
    @synchronized (FloeActiveWorkers()) { [FloeActiveWorkers() removeObject:sessionID]; }
    @synchronized (FloeCancelledWorkers()) { [FloeCancelledWorkers() removeObject:sessionID]; }
}
BOOL FloeShellHasActiveWorker(NSString *sessionID) {
    @synchronized (FloeActiveWorkers()) { return [FloeActiveWorkers() countForObject:sessionID] > 0; }
}

static dispatch_semaphore_t FloeShellRunGate(void) {
    static dispatch_semaphore_t gate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gate = dispatch_semaphore_create(1); });
    return gate;
}

namespace {

/// Bounded diagnostics for the process-wide engine gate. Owners are recorded
/// by session id only; no command text, paths or environment ever enter here.
struct FloeRunGateCounters {
    std::mutex lock;
    int64_t waiters = 0;
    int64_t acquisitions = 0;
    int64_t busyReturns = 0;
    int64_t abandonedWorkers = 0;
    int64_t waitMsTotal = 0;
    std::string ownerSession;
    double ownerStarted = 0;
};

FloeRunGateCounters &FloeRunGateCountersRef(void) {
    static FloeRunGateCounters counters;
    return counters;
}

void FloeRecordGateAcquired(NSString *sessionID) {
    FloeRunGateCounters &counters = FloeRunGateCountersRef();
    std::lock_guard<std::mutex> guard(counters.lock);
    counters.acquisitions += 1;
    counters.ownerSession = sessionID.length > 0 ? sessionID.UTF8String : "";
    counters.ownerStarted = NSProcessInfo.processInfo.systemUptime;
}

void FloeRecordGateReleased(NSString *sessionID) {
    FloeRunGateCounters &counters = FloeRunGateCountersRef();
    std::lock_guard<std::mutex> guard(counters.lock);
    if (sessionID.length == 0 || counters.ownerSession == sessionID.UTF8String) {
        counters.ownerSession.clear();
        counters.ownerStarted = 0;
    }
}

void FloeRecordGateWait(NSTimeInterval waited) {
    FloeRunGateCounters &counters = FloeRunGateCountersRef();
    std::lock_guard<std::mutex> guard(counters.lock);
    counters.waitMsTotal += (int64_t)MAX(0.0, waited * 1000.0);
}

void FloeRecordGateBusy(void) {
    FloeRunGateCounters &counters = FloeRunGateCountersRef();
    std::lock_guard<std::mutex> guard(counters.lock);
    counters.busyReturns += 1;
}

/// A worker outlived its deadline and the cancellation grace; the gate was
/// reclaimed instead of being held until that worker happens to stop.
void FloeRecordGateAbandoned(void) {
    FloeRunGateCounters &counters = FloeRunGateCountersRef();
    std::lock_guard<std::mutex> guard(counters.lock);
    counters.abandonedWorkers += 1;
}

} // namespace

NSString *FloeShellRunGateDiagnostics(void) {
    FloeRunGateCounters &counters = FloeRunGateCountersRef();
    std::lock_guard<std::mutex> guard(counters.lock);
    NSString *owner = counters.ownerSession.empty()
        ? @"none"
        : [NSString stringWithUTF8String:counters.ownerSession.c_str()];
    int64_t heldMs = counters.ownerStarted > 0
        ? (int64_t)MAX(0.0, (NSProcessInfo.processInfo.systemUptime - counters.ownerStarted) * 1000.0)
        : 0;
    return [NSString stringWithFormat:
            @"gate owner=%@ heldMs=%lld waiters=%lld acquisitions=%lld busyReturns=%lld abandoned=%lld waitMsTotal=%lld",
            owner ?: @"none", (long long)heldMs, (long long)counters.waiters,
            (long long)counters.acquisitions, (long long)counters.busyReturns,
            (long long)counters.abandonedWorkers,
            (long long)counters.waitMsTotal];
}

static os_log_t FloeShellLogGate(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.floeagent.shell", "run-gate"); });
    return log;
}

#pragma mark - Engine bootstrap

BOOL FloeShellEngineAvailable(void) {
#if FLOE_HAS_IOS_SYSTEM
    return YES;
#else
    return NO;
#endif
}

static BOOL FloeShellEngineInitialized = NO;

static void FloeEnsureEngineInitialized(void) {
#if FLOE_HAS_IOS_SYSTEM
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        initializeEnvironment();
        joinMainThread = true;
        FloeShellSetEnvironment(@{});
        FloeShellEngineInitialized = YES;
    });
#endif
}

void FloeShellSetEnvironment(NSDictionary<NSString *, NSString *> *environment) {
    NSMutableDictionary *resolved = [FloeTLSEnvironment() mutableCopy];
    [resolved addEntriesFromDictionary:environment];
    [resolved enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        if (key.length == 0 || [key containsString:@"="]) { return; }
        ios_setenv(key.UTF8String, value.UTF8String, 1);
    }];
}

NSDictionary<NSString *, NSString *> *FloeShellCurrentEnvironment(void) {
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    for (NSString *entry in environmentAsArray()) {
        NSRange separator = [entry rangeOfString:@"="];
        if (separator.location == NSNotFound || separator.location == 0) continue;
        values[[entry substringToIndex:separator.location]] = [entry substringFromIndex:separator.location + 1];
    }
    return [values copy];
}

BOOL FloeShellSetMiniRoot(NSString *rootPath) {
    if (rootPath.length == 0) { return NO; }
    return ios_setMiniRoot(rootPath);
}

#pragma mark - One-shot execution

namespace {

struct FloeRunContext;

/// Releases the process-wide engine run gate exactly once for `context`.
/// Called by the caller when it reclaims a gate from a non-cooperative worker
/// and by the worker's own teardown, whichever happens first.
void FloeReleaseRunGate(FloeRunContext *context);

struct FloeCaptureBudget {
    std::mutex lock;
    size_t remaining;
    explicit FloeCaptureBudget(size_t limit): remaining(limit) {}
};

struct FloePipeCapture {
    std::mutex lock;
    std::string bytes;
    std::thread reader;
    std::atomic_bool stopRequested{false};
    /// Absolute uptime (seconds) when a stopping reader gives up even if bytes
    /// keep arriving. 0 = drain until EOF.
    std::atomic<double> hardDeadline{0};
    double quietWindow = 0;

    static double uptime() { return NSProcessInfo.processInfo.systemUptime; }

    /// Stops the reader after `quietSeconds` without new output, or
    /// `hardSeconds` from now, whichever comes first. The earlier hard
    /// deadline wins so an abandoned worker cannot extend a reclaim.
    void requestStop(double quietSeconds, double hardSeconds) {
        double proposed = uptime() + MAX(0.05, hardSeconds);
        double current = hardDeadline.load(std::memory_order_relaxed);
        while (current == 0 || proposed < current) {
            if (hardDeadline.compare_exchange_weak(current, proposed, std::memory_order_relaxed)) break;
        }
        std::lock_guard<std::mutex> guard(lock);
        quietWindow = MAX(0.05, quietSeconds);
        stopRequested.store(true, std::memory_order_release);
    }

    explicit FloePipeCapture(int fd, std::shared_ptr<FloeCaptureBudget> budget) {
        reader = std::thread([this, fd, budget] {
            char chunk[16384];
            double lastDataAt = uptime();
            while (true) {
                if (stopRequested.load(std::memory_order_acquire)) {
                    double now = uptime();
                    if (now >= hardDeadline.load(std::memory_order_relaxed)) break;
                    double quiet;
                    { std::lock_guard<std::mutex> guard(lock); quiet = quietWindow; }
                    if (quiet > 0 && now - lastDataAt >= quiet) break;
                }
                struct pollfd descriptor = { fd, POLLIN, 0 };
                int ready = poll(&descriptor, 1, 50);
                if (ready > 0) {
                    if ((descriptor.revents & (POLLIN | POLLHUP | POLLERR)) == 0) continue;
                    ssize_t count = read(fd, chunk, sizeof(chunk));
                    if (count > 0) {
                        lastDataAt = uptime();
                        size_t retained;
                        { std::lock_guard<std::mutex> guard(budget->lock);
                          retained = std::min((size_t)count, budget->remaining);
                          budget->remaining -= retained; }
                        if (retained) { std::lock_guard<std::mutex> guard(lock); bytes.append(chunk, retained); }
                        continue;
                    }
                    if (count == 0) break;                       // EOF
                    if (errno == EINTR) continue;
                    if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
                    break;
                }
                if (ready < 0 && errno != EINTR) break;
            }
            close(fd);
        });
    }
    /// Bounded finalization: drain whatever already arrived (plus a short quiet
    /// window for a last flush) and never block on a write end held open by a
    /// descendant or a detached command thread.
    void finish() {
        requestStop(0.15, 2.0);
        if (reader.joinable()) reader.join();
    }
    ~FloePipeCapture() { finish(); }
    NSString *snapshot() {
        std::lock_guard<std::mutex> guard(lock);
        for (size_t trim = 0; trim <= 3 && trim <= bytes.size(); ++trim) {
            NSString *value = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size()-trim encoding:NSUTF8StringEncoding];
            if (value) return value;
        }
        return [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSISOLatin1StringEncoding] ?: @"";
    }
};

struct FloeRunContext {
    const char *command = nullptr;
    char *sessionKey = nullptr;
    __strong NSString *workingDirectory;
    __strong NSDictionary<NSString *, NSString *> *environment;
    FILE *input = nullptr;
    FILE *output = nullptr;
    FILE *error = nullptr;
    std::unique_ptr<FloePipeCapture> outputCapture;
    std::unique_ptr<FloePipeCapture> errorCapture;
    int32_t exitCode = 125;
    __strong NSString *trackedSessionID;
    __strong NSString *temporaryDirectory;
    __strong NSString *originalDirectory;
    /// Exactly-once gate ownership. A timeout/cancel caller may reclaim the
    /// gate before the worker stops; the worker's own teardown then finds the
    /// release already done instead of signalling a second time.
    std::atomic_bool gateReleased{false};
    /// The caller stopped waiting and reclaimed the gate. This worker no
    /// longer owns process-wide state: it must not restore the working
    /// directory another run may already own.
    std::atomic_bool abandoned{false};
    bool engineSessionOpened = false;
    std::atomic_bool finished{false};
    ~FloeRunContext() {
        if (command) free((void *)command);
        if (input) fclose(input);
        if (output) fclose(output);
        if (error) fclose(error);
        if (outputCapture) outputCapture->finish();
        if (errorCapture) errorCapture->finish();
        if (engineSessionOpened) ios_closeSession(sessionKey);
        if (sessionKey) free(sessionKey);
        if (!abandoned.load(std::memory_order_acquire) && originalDirectory) {
            [[NSFileManager defaultManager] changeCurrentDirectoryPath:originalDirectory];
        }
        if (temporaryDirectory) [[NSFileManager defaultManager] removeItemAtPath:temporaryDirectory error:nil];
        if (trackedSessionID) FloeWorkerFinished(trackedSessionID);
        FloeReleaseRunGate(this);
    }
};

void FloeReleaseRunGate(FloeRunContext *context) {
    if (context->gateReleased.exchange(true, std::memory_order_acq_rel)) { return; }
    FloeRecordGateReleased(context->trackedSessionID);
    dispatch_semaphore_signal(FloeShellRunGate());
}

void *FloeRunThreadMain(void *rawContext) {
    std::unique_ptr<std::shared_ptr<FloeRunContext>> holder(
        static_cast<std::shared_ptr<FloeRunContext> *>(rawContext));
    auto context = *holder;
    @autoreleasepool {
        ios_switchSession(context->sessionKey);
        context->engineSessionOpened = true;
        ios_setContext(context->sessionKey);
        // ios_fork holds the engine PID mutex until the creating thread
        // publishes its ID. Complete that pair before dash can fork a pipeline.
        const pid_t processID = ios_fork();
        FloeShellSetEnvironment(context->environment);
        ios_storeThreadId(pthread_self());
        ios_setDirectoryURL([NSURL fileURLWithPath:context->workingDirectory]);
        ios_setStreams(context->input, context->output, context->error);
        thread_stdin = context->input;
        thread_stdout = context->output;
        thread_stderr = context->error;
        ios_system(context->command);
        context->exitCode = (int32_t)ios_getCommandStatus();
        ios_releaseThreadId(processID);
        fclose(context->output); context->output = nullptr;
        fclose(context->error); context->error = nullptr;
        context->outputCapture->finish();
        context->errorCapture->finish();
        context->finished.store(true, std::memory_order_release);
    }
    return NULL;
}

void FloeInterruptEngine(const char *sessionKey) {
    // ios_kill invokes a process-global SIGINT handler on its calling thread.
    // dash's handler may longjmp/exit that unrelated Swift executor thread.
    // Request cooperative interruption; dash polls on its own execution thread.
    if (!sessionKey) return;
    NSString *sessionID = [NSString stringWithUTF8String:sessionKey];
    @synchronized (FloeCancelledWorkers()) { [FloeCancelledWorkers() addObject:sessionID]; }
}


} // namespace

FloeShellBridgeStatus FloeShellRunCommand(
    NSString *command,
    NSString *rootPath,
    NSString *workingDirectory,
    NSString *sessionID,
    NSDictionary<NSString *, NSString *> *environment,
    NSData *stdinData,
    NSTimeInterval timeout,
    NSTimeInterval gateTimeout,
    NSUInteger maxOutputBytes,
    BOOL (^shouldCancel)(void),
    NSString **outStdout,
    NSString **outStderr,
    int32_t *outExitCode
) {
    if (!FloeShellEngineAvailable()) {
        return FloeShellBridgeStatusEngineUnavailable;
    }
    FloeEnsureEngineInitialized();
    const NSTimeInterval requestedAt = NSProcessInfo.processInfo.systemUptime;
    const NSTimeInterval gateWindow = MAX(0.05, MIN(gateTimeout, 120.0));
    // Distinguish gate queue time from execution time. A command that never
    // acquired the gate must not be reported as an execution timeout: the
    // worker that owns the gate keeps global runtime state (cwd, mini root,
    // environment, engine session) until it has actually stopped.
    BOOL acquiredGate = NO;
    {
        FloeRunGateCounters &counters = FloeRunGateCountersRef();
        { std::lock_guard<std::mutex> guard(counters.lock); counters.waiters += 1; }
        while (true) {
            long waited = dispatch_semaphore_wait(FloeShellRunGate(), dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC));
            if (waited == 0) { acquiredGate = YES; break; }
            if (shouldCancel && shouldCancel()) { break; }
            if (NSProcessInfo.processInfo.systemUptime - requestedAt >= gateWindow) { break; }
        }
        { std::lock_guard<std::mutex> guard(counters.lock); counters.waiters -= 1; }
    }
    FloeRecordGateWait(NSProcessInfo.processInfo.systemUptime - requestedAt);
    if (!acquiredGate) {
        if (shouldCancel && shouldCancel()) { return FloeShellBridgeStatusCancelled; }
        FloeRecordGateBusy();
        os_log_error(FloeShellLogGate(), "floeShellRunGateBusy %{public}@", FloeShellRunGateDiagnostics());
        return FloeShellBridgeStatusBusy;
    }
    const NSTimeInterval executionStarted = NSProcessInfo.processInfo.systemUptime;
    // The worker starts as the gate owner. Ownership is released exactly once:
    // by this caller when the deadline plus the cancellation grace expire, or
    // by the worker's teardown, whichever comes first.
    auto context = std::make_shared<FloeRunContext>();
    context->trackedSessionID = sessionID;
    FloeRecordGateAcquired(sessionID);
    if (shouldCancel && shouldCancel()) { return FloeShellBridgeStatusCancelled; }
    {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *tempRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"floe-shell-%@", NSUUID.UUID.UUIDString]];
        context->temporaryDirectory = tempRoot;
        [fileManager createDirectoryAtPath:tempRoot withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *stdinPath = [tempRoot stringByAppendingPathComponent:@"stdin"];
        [fileManager createFileAtPath:stdinPath contents:(stdinData ?: [NSData data]) attributes:nil];

        if (rootPath.length > 0) { ios_setMiniRoot(rootPath); }
        context->originalDirectory = [fileManager currentDirectoryPath];
        if (rootPath.length > 0) { [fileManager changeCurrentDirectoryPath:rootPath]; }

        NSString *fullCommand = command;
        if (sessionID.length > 0) {
            // Session switching is optional for one-shot runs; the command bus
            // keeps session state only for interactive use.
        }

        context->command = strdup(fullCommand.UTF8String);
        context->sessionKey = strdup(sessionID.UTF8String);
        context->workingDirectory = workingDirectory;
        context->environment = environment;
        context->input = fopen(stdinPath.fileSystemRepresentation, "rb");
        int outPipe[2] = {-1, -1}, errPipe[2] = {-1, -1};
        if (pipe(outPipe) != 0 || pipe(errPipe) != 0) {
            for (int fd : outPipe) if (fd >= 0) close(fd);
            for (int fd : errPipe) if (fd >= 0) close(fd);
            return FloeShellBridgeStatusEngineUnavailable;
        }
        auto budget = std::make_shared<FloeCaptureBudget>(maxOutputBytes);
        context->outputCapture = std::make_unique<FloePipeCapture>(outPipe[0], budget);
        context->errorCapture = std::make_unique<FloePipeCapture>(errPipe[0], budget);
        context->output = fdopen(outPipe[1], "w");
        context->error = fdopen(errPipe[1], "w");
        if (!context->output) close(outPipe[1]);
        if (!context->error) close(errPipe[1]);
        if (!context->input || !context->output || !context->error) {
            return FloeShellBridgeStatusEngineUnavailable;
        }

        pthread_t thread;
        context->trackedSessionID = sessionID;
        FloeWorkerStarted(sessionID);
        auto holder = new std::shared_ptr<FloeRunContext>(context);
        if (pthread_create(&thread, NULL, FloeRunThreadMain, holder) != 0) {
            delete holder;
            return FloeShellBridgeStatusEngineUnavailable;
        }

        BOOL timedOut = NO;
        BOOL cancelled = NO;
        while (!context->finished.load(std::memory_order_acquire)) {
            cancelled = shouldCancel && shouldCancel();
            if (cancelled || NSProcessInfo.processInfo.systemUptime - executionStarted > timeout) {
                timedOut = !cancelled;
                FloeInterruptEngine(context->sessionKey);
                break;
            }
            [NSThread sleepForTimeInterval:0.02];
        }
        if (timedOut || cancelled) {
            // Give cooperative cancellation (dash polls an owned-session flag
            // on its own execution thread) a bounded window to flush output
            // and stop. A native command that ignores its token must not keep
            // the process-wide gate beyond this window.
            NSTimeInterval graceStarted = NSProcessInfo.processInfo.systemUptime;
            while (!context->finished.load(std::memory_order_acquire) && NSProcessInfo.processInfo.systemUptime - graceStarted < 0.5) {
                [NSThread sleepForTimeInterval:0.02];
            }
        }
        if (context->finished.load(std::memory_order_acquire)) {
            pthread_join(thread, NULL);
        } else {
            // Hard reclaim: the worker outlived its caller's deadline and the
            // cancellation grace. Future commands must not report Busy for an
            // unbounded time. The abandoned worker keeps its own engine
            // session, thread-local streams and pipes (so it cannot corrupt a
            // later run's stdio) but no longer owns the gate; its teardown
            // releases nothing and never restores the working directory.
            context->abandoned.store(true, std::memory_order_release);
            if (context->outputCapture) context->outputCapture->requestStop(0.15, 0.4);
            if (context->errorCapture) context->errorCapture->requestStop(0.15, 0.4);
            FloeReleaseRunGate(context.get());
            pthread_detach(thread);
            FloeRecordGateAbandoned();
            os_log_error(FloeShellLogGate(), "floeShellWorkerAbandoned session=%{public}@ waitedMs=%lld %{public}@",
                         sessionID, (long long)((NSProcessInfo.processInfo.systemUptime - requestedAt) * 1000.0),
                         FloeShellRunGateDiagnostics());
        }


        if (outStdout) { *outStdout = context->outputCapture->snapshot(); }
        if (outStderr) { *outStderr = context->errorCapture->snapshot(); }
        if (outExitCode) { *outExitCode = context->finished.load(std::memory_order_acquire) ? context->exitCode : 124; }
        // A completed worker has already drained and closed its pipes. An
        // abandoned worker keeps its streams until it stops; its readers stop
        // at the reclaim deadline so a descendant holding a pipe open cannot
        // leak descriptors or block later runs.

        if (cancelled) { return FloeShellBridgeStatusCancelled; }
        if (timedOut) { return FloeShellBridgeStatusTimedOut; }
        return FloeShellBridgeStatusOK;
    }
}

#pragma mark - Interactive sessions

namespace {

struct FloeSessionThreadContext {
    const char *command;
    int inputReadFD;
    int outputWriteFD;
    char *rootPath;
    char *sessionKey;
    __strong NSDictionary<NSString *, NSString *> *environment;
    __strong FloeShellSessionRecord *record;
};

void *FloeSessionThreadMain(void *rawContext) {
    FloeSessionThreadContext *context = (FloeSessionThreadContext *)rawContext;
    @autoreleasepool {
        FILE *input = fdopen(context->inputReadFD, "r");
        FILE *output = fdopen(context->outputWriteFD, "w");
        // Interactive prompts and command echo must reach the caller as they
        // are written. stdio picks full buffering for a pipe, so `dash -i`'s
        // prompt would sit in the FILE* until flush/exit and the terminal
        // would appear to produce no output at all.
        if (output) { setvbuf(output, NULL, _IONBF, 0); }
        ios_switchSession(context->sessionKey);
        ios_setContext(context->sessionKey);
        // ios_fork holds the engine PID mutex until the creating thread
        // publishes its ID. Complete that pair before dash can fork a pipeline.
        const pid_t processID = ios_fork();
        FloeShellSetEnvironment(context->environment);
        ios_storeThreadId(pthread_self());
        ios_setStreams(input ?: stdin, output ?: stdout, output ?: stderr);
        thread_stdin = input ?: stdin;
        thread_stdout = output ?: stdout;
        thread_stderr = output ?: stderr;
        if (context->rootPath) {
            ios_setDirectoryURL([NSURL fileURLWithPath:[NSString stringWithUTF8String:context->rootPath]]);
        }
        ios_system(context->command);
        context->record.exitCode = ios_getCommandStatus();
        ios_releaseThreadId(processID);
        context->record.finished = YES;
        if (output) { fflush(output); }
        if (input) fclose(input);
        if (output) fclose(output);
    }
    return NULL;
}

} // namespace

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
    NSString **outInitialOutput
) {
    if (!FloeShellEngineAvailable()) { return NO; }
    FloeEnsureEngineInitialized();
    int inputPipe[2] = {-1, -1};
    int outputPipe[2] = {-1, -1};
    if (pipe(inputPipe) != 0) { return NO; }
    if (pipe(outputPipe) != 0) {
        close(inputPipe[0]); close(inputPipe[1]);
        return NO;
    }
    fcntl(inputPipe[1], F_SETNOSIGPIPE, 1);
    fcntl(outputPipe[1], F_SETNOSIGPIPE, 1);
    if (rootPath.length > 0) { ios_setMiniRoot(rootPath); }

    FloeSessionThreadContext *context = new FloeSessionThreadContext();
    context->command = strdup((command.length > 0 ? command : @"dash -i").UTF8String);
    context->inputReadFD = inputPipe[0];
    context->outputWriteFD = outputPipe[1];
    context->rootPath = workingDirectory.length > 0 ? strdup(workingDirectory.UTF8String) : NULL;
    context->sessionKey = strdup(sessionID.UTF8String);
    context->environment = environment;

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        pthread_t pthread = pthread_self();
        @synchronized (FloeShellSessions()) {
            FloeShellSessions()[sessionID].commandThread = pthread;
        }
        FloeSessionThreadMain(context);
        @synchronized (FloeShellSessions()) {
            context->record.finished = YES;
        }
        free((void *)context->command);
        if (context->rootPath) { free(context->rootPath); }
        delete context;
        FloeWorkerFinished(sessionID);
    }];
    thread.name = [@"floe.shell." stringByAppendingString:sessionID];
    thread.qualityOfService = NSQualityOfServiceUserInitiated;

    FloeShellSessionRecord *record = [[FloeShellSessionRecord alloc] init];
    record.sessionID = sessionID;
    record.inputWriteFD = inputPipe[1];
    record.outputReadFD = outputPipe[0];
    record.thread = thread;
    record.engineSessionKey = context->sessionKey;
    context->record = record;
    @synchronized (FloeShellSessions()) {
        FloeShellSessions()[sessionID] = record;
    }
    FloeWorkerStarted(sessionID);
    [thread start];

    // Bounded readiness wait: drain the banner until the program has gone
    // quiet after its first output, exited, or the budget expires. `dash -i`
    // on a pipe may print no prompt at all; that must still return a live
    // session instead of waiting forever for output that will never come.
    const NSTimeInterval readinessStarted = NSProcessInfo.processInfo.systemUptime;
    const NSTimeInterval readinessBudget = 3.0;
    int flags = fcntl(outputPipe[0], F_GETFL, 0);
    fcntl(outputPipe[0], F_SETFL, flags | O_NONBLOCK);
    NSMutableData *banner = [NSMutableData data];
    NSTimeInterval lastOutputAt = 0;
    NSTimeInterval finishedDrainDeadline = 0;
    uint8_t buffer[4096];
    while (YES) {
        ssize_t count = read(outputPipe[0], buffer, sizeof(buffer));
        if (count > 0) {
            if (banner.length < 64 * 1024) {
                [banner appendBytes:buffer length:MIN((NSUInteger)count, (NSUInteger)(64 * 1024) - banner.length)];
            }
            lastOutputAt = NSProcessInfo.processInfo.systemUptime;
            continue;
        }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (count == 0) {
            // EOF: every write end of the program's output stream is closed,
            // so no further byte can arrive.
            break;
        }
        if (record.finished) {
            // The command thread has finished but may still be flushing the
            // program's FILE* before fclose. Keep draining for a short bounded
            // grace so a fast command's final output is not dropped.
            if (finishedDrainDeadline == 0) { finishedDrainDeadline = now + 0.25; }
            if (now >= finishedDrainDeadline) { break; }
            [NSThread sleepForTimeInterval:0.01];
            continue;
        }
        if (lastOutputAt > 0 && now - lastOutputAt >= 0.12) { break; }
        if (lastOutputAt == 0 && now - readinessStarted >= 0.5) { break; }
        if (now - readinessStarted >= readinessBudget) { break; }
        [NSThread sleepForTimeInterval:0.02];
    }
    if (outInitialOutput) {
        *outInitialOutput = [[NSString alloc] initWithData:banner encoding:NSUTF8StringEncoding] ?: @"";
    }
    if (outInputFD) { *outInputFD = inputPipe[1]; }
    if (outOutputFD) { *outOutputFD = outputPipe[0]; }
    return YES;
}

BOOL FloeShellClaimSessionDescriptors(NSString *sessionID) {
    @synchronized (FloeShellSessions()) {
        FloeShellSessionRecord *record = FloeShellSessions()[sessionID];
        if (record == nil) {
            // A concurrent close already removed the record and closed the
            // descriptors. The caller must not fcntl/read/close those numbers
            // again: they may already have been recycled by another pipe.
            return NO;
        }
        record.pumpOwnsDescriptors = YES;
        return YES;
    }
}

void FloeShellEndSession(NSString *sessionID) {
    @synchronized (FloeShellSessions()) {
        [FloeShellSessions() removeObjectForKey:sessionID];
    }
}

void FloeShellSignalSession(NSString *sessionID, int signalNumber) {
    FloeShellSessionRecord *record = nil;
    @synchronized (FloeShellSessions()) {
        record = FloeShellSessions()[sessionID];
    }
    if (record == nil || record.commandThread == 0) { return; }
    if (!record.finished) FloeInterruptEngine(record.engineSessionKey);
}

void FloeShellCloseSession(NSString *sessionID) {
    FloeShellSessionRecord *record = nil;
    @synchronized (FloeShellSessions()) {
        record = FloeShellSessions()[sessionID];
        if (record == nil || !record.pumpOwnsDescriptors) {
            [FloeShellSessions() removeObjectForKey:sessionID];
        }
    }
    if (record == nil) { return; }
    if (record.commandThread != 0 && !record.finished) {
        FloeInterruptEngine(record.engineSessionKey);
    }
    // A pump-owned session keeps its descriptors: the pump closes them only
    // after its read/write loop has stopped, so no file descriptor is closed
    // underneath a concurrent read or a recycled descriptor is reused.
    if (record.pumpOwnsDescriptors) { return; }
    if (record.inputWriteFD >= 0) { close(record.inputWriteFD); }
    if (record.outputReadFD >= 0) { close(record.outputReadFD); }
}

void FloeShellResizeSession(NSString *sessionID, NSInteger columns, NSInteger rows) {
    @synchronized (FloeShellSessions()) {
        FloeShellSessionRecord *record = FloeShellSessions()[sessionID];
        if (record && !record.finished) ios_setWindowSize((int)columns, (int)rows, record.engineSessionKey);
    }
}

BOOL FloeShellSessionAlive(NSString *sessionID) {
    @synchronized (FloeShellSessions()) {
        FloeShellSessionRecord *record = FloeShellSessions()[sessionID];
        return record != nil && !record.finished;
    }
}
BOOL FloeShellSessionExitCode(NSString *sessionID, int32_t *code) {
    @synchronized (FloeShellSessions()) {
        FloeShellSessionRecord *record = FloeShellSessions()[sessionID];
        if (!record || !record.finished) return NO;
        *code = record.exitCode;
        return YES;
    }
}

#pragma mark - Replacement commands


BOOL FloeShellCurrentCommandCancelled(void) { return floe_shell_should_cancel() != 0; }

void FloeShellRegisterCommand(NSString *name) {
#if FLOE_HAS_IOS_SYSTEM
    FloeEnsureEngineInitialized();
    replaceCommand(name, @"floe_shell_command_main", true);
    // The pinned engine rewrites every command beginning with python into
    // pythonA/pythonB framework names, even after replaceCommand. Dispatch
    // Floe's single CPython service through an internal non-Python alias.
    if ([name isEqualToString:@"python3"] || [name isEqualToString:@"python"]) {
        replaceCommand([@"floe_runtime_" stringByAppendingString:name], @"floe_shell_command_main", true);
    }
#endif
}

extern "C" __attribute__((visibility("default"), used)) const char *floe_shell_command_alias(const char *name) {
    if (strcmp(name, "python3") == 0) return "floe_runtime_python3";
    if (strcmp(name, "python") == 0) return "floe_runtime_python";
    return name;
}

NSString *FloeShellCurrentWorkingDirectory(void) {
    return thread_context ? ios_getLogicalPWD(thread_context) : nil;
}

NSString *FloeShellCurrentSessionID(void) {
    return thread_context ? [NSString stringWithUTF8String:(const char *)thread_context] : nil;
}

FILE *FloeShellCurrentStdin(void) { return thread_stdin; }

FILE *FloeShellCurrentStdout(void) {
    return thread_stdout;
}

FILE *FloeShellCurrentStderr(void) {
    return thread_stderr;
}

void FloeShellWrite(FILE *stream, const char *text) {
    if (stream == NULL || text == NULL) { return; }
    fputs(text, stream);
    fflush(stream);
}
