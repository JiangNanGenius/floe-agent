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

static NSLock *FloeShellRunLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
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
    [environment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        if (key.length == 0 || [key containsString:@"="]) { return; }
        ios_setenv(key.UTF8String, value.UTF8String, 1);
    }];
}

BOOL FloeShellSetMiniRoot(NSString *rootPath) {
    if (rootPath.length == 0) { return NO; }
    return ios_setMiniRoot(rootPath);
}

#pragma mark - One-shot execution

namespace {

struct FloeCaptureBudget {
    std::mutex lock;
    size_t remaining;
    explicit FloeCaptureBudget(size_t limit): remaining(limit) {}
};

struct FloePipeCapture {
    std::mutex lock;
    std::string bytes;
    std::thread reader;
    explicit FloePipeCapture(int fd, std::shared_ptr<FloeCaptureBudget> budget) {
        reader = std::thread([this, fd, budget] {
            char chunk[16384];
            while (true) {
                ssize_t count = read(fd, chunk, sizeof(chunk));
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                size_t retained;
                { std::lock_guard<std::mutex> guard(budget->lock);
                  retained = std::min((size_t)count, budget->remaining);
                  budget->remaining -= retained; }
                if (retained) { std::lock_guard<std::mutex> guard(lock); bytes.append(chunk, retained); }
            }
            close(fd);
        });
    }
    void finish() { if (reader.joinable()) reader.join(); }
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
    std::atomic_bool finished{false};
    ~FloeRunContext() {
        if (command) free((void *)command);
        if (sessionKey) free(sessionKey);
        if (input) fclose(input);
        if (output) fclose(output);
        if (error) fclose(error);
    }
};

void *FloeRunThreadMain(void *rawContext) {
    std::unique_ptr<std::shared_ptr<FloeRunContext>> holder(
        static_cast<std::shared_ptr<FloeRunContext> *>(rawContext));
    auto context = *holder;
    @autoreleasepool {
        ios_switchSession(context->sessionKey);
        ios_setContext(context->sessionKey);
        ios_fork();
        FloeShellSetEnvironment(context->environment);
        ios_setDirectoryURL([NSURL fileURLWithPath:context->workingDirectory]);
        ios_setStreams(context->input, context->output, context->error);
        thread_stdin = context->input;
        thread_stdout = context->output;
        thread_stderr = context->error;
        ios_system(context->command);
        context->exitCode = (int32_t)ios_getCommandStatus();
        fclose(context->output); context->output = nullptr;
        fclose(context->error); context->error = nullptr;
        context->outputCapture->finish();
        context->errorCapture->finish();
        context->finished.store(true, std::memory_order_release);
    }
    return NULL;
}

void FloeInterruptEngine(const char *sessionKey) {
    // ios_kill controls the engine's command; a POSIX terminating signal
    // directed at a pthread can terminate the entire hosting app.
    ios_switchSession(sessionKey);
    ios_kill();
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
    [FloeShellRunLock() lock];
    @try {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *tempRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"floe-shell-%@", NSUUID.UUID.UUIDString]];
        [fileManager createDirectoryAtPath:tempRoot withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *stdinPath = [tempRoot stringByAppendingPathComponent:@"stdin"];
        [fileManager createFileAtPath:stdinPath contents:(stdinData ?: [NSData data]) attributes:nil];

        if (rootPath.length > 0) { ios_setMiniRoot(rootPath); }
        NSString *originalDirectory = [fileManager currentDirectoryPath];
        if (rootPath.length > 0) { [fileManager changeCurrentDirectoryPath:rootPath]; }

        NSString *fullCommand = command;
        if (sessionID.length > 0) {
            // Session switching is optional for one-shot runs; the command bus
            // keeps session state only for interactive use.
        }

        auto context = std::make_shared<FloeRunContext>();
        context->command = strdup(fullCommand.UTF8String);
        context->sessionKey = strdup(sessionID.UTF8String);
        context->workingDirectory = workingDirectory;
        context->environment = environment;
        context->input = fopen(stdinPath.fileSystemRepresentation, "rb");
        int outPipe[2] = {-1, -1}, errPipe[2] = {-1, -1};
        if (pipe(outPipe) != 0 || pipe(errPipe) != 0) {
            for (int fd : outPipe) if (fd >= 0) close(fd);
            for (int fd : errPipe) if (fd >= 0) close(fd);
            [fileManager changeCurrentDirectoryPath:originalDirectory];
            [fileManager removeItemAtPath:tempRoot error:nil];
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
            [fileManager changeCurrentDirectoryPath:originalDirectory];
            [fileManager removeItemAtPath:tempRoot error:nil];
            return FloeShellBridgeStatusEngineUnavailable;
        }

        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        pthread_t thread;
        auto holder = new std::shared_ptr<FloeRunContext>(context);
        if (pthread_create(&thread, NULL, FloeRunThreadMain, holder) != 0) {
            delete holder;
            [fileManager changeCurrentDirectoryPath:originalDirectory];
            [fileManager removeItemAtPath:tempRoot error:nil];
            return FloeShellBridgeStatusEngineUnavailable;
        }

        BOOL timedOut = NO;
        BOOL cancelled = NO;
        while (!context->finished.load(std::memory_order_acquire)) {
            cancelled = shouldCancel && shouldCancel();
            if (cancelled || NSProcessInfo.processInfo.systemUptime - started > timeout) {
                timedOut = !cancelled;
                FloeInterruptEngine(context->sessionKey);
                break;
            }
            [NSThread sleepForTimeInterval:0.02];
        }
        if (timedOut || cancelled) {
            // Give the interrupt a short grace period to flush output.
            NSTimeInterval graceStarted = NSProcessInfo.processInfo.systemUptime;
            while (!context->finished.load(std::memory_order_acquire) && NSProcessInfo.processInfo.systemUptime - graceStarted < 1.0) {
                [NSThread sleepForTimeInterval:0.02];
            }
        }
        if (context->finished.load(std::memory_order_acquire)) {
            pthread_join(thread, NULL);
            ios_closeSession(context->sessionKey);
        } else {
            pthread_detach(thread);
        }

        if (rootPath.length > 0) { [fileManager changeCurrentDirectoryPath:originalDirectory]; }

        if (outStdout) { *outStdout = context->outputCapture->snapshot(); }
        if (outStderr) { *outStderr = context->errorCapture->snapshot(); }
        if (outExitCode) { *outExitCode = context->finished.load(std::memory_order_acquire) ? context->exitCode : 124; }
        // On timeout the worker still owns `context` (it frees itself when it
        // exits); the deadline path intentionally abandons the thread rather
        // than racing a free against it.
        [fileManager removeItemAtPath:tempRoot error:nil];

        if (cancelled) { return FloeShellBridgeStatusCancelled; }
        if (timedOut) { return FloeShellBridgeStatusTimedOut; }
        return FloeShellBridgeStatusOK;
    } @finally {
        [FloeShellRunLock() unlock];
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
        ios_switchSession(context->sessionKey);
        ios_setContext(context->sessionKey);
        ios_fork();
        FloeShellSetEnvironment(context->environment);
        ios_setStreams(input ?: stdin, output ?: stdout, output ?: stderr);
        thread_stdin = input ?: stdin;
        thread_stdout = output ?: stdout;
        thread_stderr = output ?: stderr;
        if (context->rootPath) {
            ios_setDirectoryURL([NSURL fileURLWithPath:[NSString stringWithUTF8String:context->rootPath]]);
        }
        ios_system(context->command);
        context->record.exitCode = ios_getCommandStatus();
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
    [thread start];

    // Give the program a moment to print its banner/prompt.
    [NSThread sleepForTimeInterval:0.4];
    int flags = fcntl(outputPipe[0], F_GETFL, 0);
    fcntl(outputPipe[0], F_SETFL, flags | O_NONBLOCK);
    NSMutableData *banner = [NSMutableData data];
    uint8_t buffer[4096];
    ssize_t count = 0;
    while ((count = read(outputPipe[0], buffer, sizeof(buffer))) > 0) {
        [banner appendBytes:buffer length:(NSUInteger)count];
        if (banner.length > 64 * 1024) { break; }
    }
    if (outInitialOutput) {
        *outInitialOutput = [[NSString alloc] initWithData:banner encoding:NSUTF8StringEncoding] ?: @"";
    }
    if (outInputFD) { *outInputFD = inputPipe[1]; }
    if (outOutputFD) { *outOutputFD = outputPipe[0]; }
    return YES;
}

void FloeShellSignalSession(NSString *sessionID, int signalNumber) {
    FloeShellSessionRecord *record = nil;
    @synchronized (FloeShellSessions()) {
        record = FloeShellSessions()[sessionID];
    }
    if (record == nil || record.commandThread == 0) { return; }
    if (!record.finished) FloeInterruptEngine(record.engineSessionKey);
}

void FloeShellCloseSession(NSString *sessionID) {    FloeShellSessionRecord *record = nil;
    @synchronized (FloeShellSessions()) {
        record = FloeShellSessions()[sessionID];
        [FloeShellSessions() removeObjectForKey:sessionID];
    }
    if (record == nil) { return; }
    if (record.commandThread != 0 && !record.finished) {
        FloeInterruptEngine(record.engineSessionKey);
    }
    if (record.inputWriteFD >= 0) { close(record.inputWriteFD); }
    if (record.outputReadFD >= 0) { close(record.outputReadFD); }
}

void FloeShellResizeSession(NSString *sessionID, NSInteger columns, NSInteger rows) {
    @synchronized (FloeShellSessions()) {
        FloeShellSessionRecord *record = FloeShellSessions()[sessionID];
        if (record && !record.finished) ios_setWindowSize((int)columns, (int)rows, record.engineSessionKey);
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


void FloeShellRegisterCommand(NSString *name) {
#if FLOE_HAS_IOS_SYSTEM
    FloeEnsureEngineInitialized();
    replaceCommand(name, @"floe_shell_command_main", true);
#endif
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
