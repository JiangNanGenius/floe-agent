#import "BridgeBootstrapShim.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <limits.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>

typedef int (*BRXCTestMainFn)(id);
typedef BOOL (^BRCancellationCheck)(uint64_t);

typedef struct {
    char *xctestPath;
    char *logPath;
    char *runtimePath;
    BRXCTestMainFn entryPoint;
    uint64_t generation;
} BREntryContext;

static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL gBootstrapStarted = NO;
static NSString *gLastError = nil;
static BRCancellationCheck gCancellationCheck = nil;
static void *gRuntimeHandle = NULL;

static void BRMakeTimestamp(char out[40]) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmValue;
    gmtime_r(&tv.tv_sec, &tmValue);
    snprintf(out, 40, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
             tmValue.tm_year + 1900, tmValue.tm_mon + 1, tmValue.tm_mday,
             tmValue.tm_hour, tmValue.tm_min, tmValue.tm_sec,
             (int)(tv.tv_usec / 1000));
}

void BRAppendLog(NSString *logPath, NSString *message) {
    if (logPath.length == 0 || message == nil) { return; }
    char timestamp[40];
    BRMakeTimestamp(timestamp);
    NSString *line = [NSString stringWithFormat:@"%s %@\n", timestamp, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) { return; }

    pthread_mutex_lock(&gLogLock);
    int fd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
        const uint8_t *bytes = data.bytes;
        size_t remaining = data.length;
        while (remaining > 0) {
            ssize_t written = write(fd, bytes, remaining);
            if (written <= 0) { break; }
            bytes += written;
            remaining -= (size_t)written;
        }
        fsync(fd);
        close(fd);
    }
    pthread_mutex_unlock(&gLogLock);
}

/// Nonsecret terminal evidence for the two `_exit` paths only. It records the
/// actual result and PID; it is never used as readiness or process-alive
/// evidence by the host.
static NSString *BRTerminalMarkerPath(NSString *logPath) {
    NSString *logsDirectory = [logPath stringByDeletingLastPathComponent];
    NSString *rootDirectory = [logsDirectory stringByDeletingLastPathComponent];
    return [[rootDirectory stringByAppendingPathComponent:@"diagnostics"]
        stringByAppendingPathComponent:@"engine-terminal.json"];
}

static void BRWriteTerminalMarker(NSString *logPath,
                                  uint64_t generation,
                                  int result,
                                  NSString *kind,
                                  NSString *detail) {
    if (logPath.length == 0) { return; }
    char timestamp[40];
    BRMakeTimestamp(timestamp);
    NSMutableDictionary *payload = [@{
        @"schema": @1,
        @"kind": kind ?: @"unknown",
        @"xctestMainReturned": @([kind isEqualToString:@"xctest-main-returned"]),
        @"result": @(result),
        @"processIdentifier": @(getpid()),
        @"generation": @(generation),
        @"at": [NSString stringWithUTF8String:timestamp] ?: @"",
    } mutableCopy];
    if (detail.length > 0) { payload[@"detail"] = detail; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (data == nil) { return; }
    NSString *path = BRTerminalMarkerPath(logPath);
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    if ([data writeToFile:path atomically:YES]) {
        chmod(path.fileSystemRepresentation, 0600);
    }
}

static void BRSetLastError(NSString *message) {
    pthread_mutex_lock(&gStateLock);
    gLastError = [message copy];
    pthread_mutex_unlock(&gStateLock);
}

NSString *BRLastBootstrapError(void) {
    pthread_mutex_lock(&gStateLock);
    NSString *message = [gLastError copy];
    pthread_mutex_unlock(&gStateLock);
    return message;
}

static NSArray<NSString *> *BRCandidatePaths(void) {
    return @[
        @"/private/preboot/Cryptexes/OS/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
        @"/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
        @"/Developer/Library/Frameworks/XCTest.framework/XCTest",
        @"/private/preboot/Cryptexes/OS/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
        @"/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
    ];
}

BOOL BRProbeDDI(NSString *logPath) {
    for (NSString *path in BRCandidatePaths()) {
        BOOL isDirectory = NO;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
        BOOL readable = exists && !isDirectory && access(path.fileSystemRepresentation, R_OK) == 0;
        if (readable) {
            BRAppendLog(logPath, [NSString stringWithFormat:@"ddi_runtime_readable path=%@", path]);
            return YES;
        }
    }
    BRAppendLog(logPath, @"ddi_runtime_not_readable");
    return NO;
}

static BOOL BRValidateTestBundle(NSString *xctestPath, NSString *logPath,
                                 NSString **bundleIdentifier, NSString **error) {
    BOOL isDirectory = NO;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:xctestPath isDirectory:&isDirectory] || !isDirectory) {
        *error = [NSString stringWithFormat:@"test bundle missing or not a directory: %@", xctestPath];
        return NO;
    }
    NSString *infoPath = [xctestPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    if (info == nil) {
        *error = [NSString stringWithFormat:@"test bundle Info.plist is not readable: %@", infoPath];
        return NO;
    }
    BOOL containsUITests = [info[@"XCTContainsUITests"] boolValue];
    NSString *identifier = info[@"CFBundleIdentifier"];
    *bundleIdentifier = identifier;
    BRAppendLog(logPath, [NSString stringWithFormat:
        @"test_bundle path=%@ bundleID=%@ XCTContainsUITests=%d",
        xctestPath, identifier ?: @"<missing>", containsUITests ? 1 : 0]);
    if (!containsUITests) {
        *error = @"test bundle Info.plist does not declare XCTContainsUITests=true";
        return NO;
    }
    if (identifier.length == 0) {
        *error = @"test bundle Info.plist has no CFBundleIdentifier";
        return NO;
    }
    return YES;
}

static void BRRunXCTestEntry(BREntryContext *context) {
    NSString *logPath = [NSString stringWithUTF8String:context->logPath];

    BRCancellationCheck cancellationCheck = nil;
    pthread_mutex_lock(&gStateLock);
    cancellationCheck = gCancellationCheck;
    pthread_mutex_unlock(&gStateLock);
    if (cancellationCheck != nil && !cancellationCheck(context->generation)) {
        BRAppendLog(logPath, [NSString stringWithFormat:
            @"bootstrap_cancelled_before_entry generation=%llu", context->generation]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        free(context->xctestPath);
        free(context->logPath);
        free(context->runtimePath);
        free(context);
        return;
    }

    uint64_t threadID = 0;
    (void)pthread_threadid_np(NULL, &threadID);
    BRAppendLog(logPath, [NSString stringWithFormat:
        @"xctest_main_entry_entered main_thread=%d thread_id=%llu pid=%d runtime=%@ generation=%llu",
        pthread_main_np() ? 1 : 0, threadID, getpid(),
        [NSString stringWithUTF8String:context->runtimePath], context->generation]);

    if (!pthread_main_np()) {
        BRAppendLog(logPath, @"bootstrap_failed reason=XCTestMain entry did not run on the main thread");
        BRWriteTerminalMarker(logPath, context->generation, 70, @"fault", @"entry-not-main-thread");
        _exit(70);
    }

    BRAppendLog(logPath, [NSString stringWithFormat:
        @"about_to_call_XCTestMain(nil) entry=%p main_thread=1 one_shot=1", (void *)context->entryPoint]);
    int result = context->entryPoint(nil);
    BRAppendLog(logPath, [NSString stringWithFormat:@"XCTestMain_returned result=%d", result]);
    // Persist the actual return/fault result immediately before the existing
    // exit path. The return/exit architecture itself is unchanged.
    BRWriteTerminalMarker(logPath, context->generation, result, @"xctest-main-returned", nil);
    _exit(result == 0 ? 0 : result);
}

BRBootstrapResult BRStartBootstrap(NSString *xctestPath,
                                   NSString *logPath,
                                   uint64_t generation,
                                   BOOL (^cancellationCheck)(uint64_t)) {
    pthread_mutex_lock(&gStateLock);
    BOOL alreadyStarted = gBootstrapStarted;
    if (!alreadyStarted) { gBootstrapStarted = YES; }
    pthread_mutex_unlock(&gStateLock);

    if (alreadyStarted) {
        BRSetLastError(@"bootstrap was already dispatched in this process; relaunch the app to retry");
        BRAppendLog(logPath, @"bootstrap_refused already_started=1");
        return BRBootstrapResultAlreadyStarted;
    }

    NSString *resolvedBundlePath = [xctestPath stringByResolvingSymlinksInPath];
    BRAppendLog(logPath, [NSString stringWithFormat:
        @"bootstrap_begin pid=%d generation=%llu bundle=%@ log=%@",
        getpid(), generation, resolvedBundlePath, logPath]);

    NSString *bundleIdentifier = nil;
    NSString *validationError = nil;
    if (!BRValidateTestBundle(resolvedBundlePath, logPath, &bundleIdentifier, &validationError)) {
        BRSetLastError(validationError);
        BRAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", validationError]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return BRBootstrapResultInvalidBundle;
    }

    if (!BRProbeDDI(logPath)) {
        NSString *message = @"no readable DDI XCTest runtime found; mount the Developer Disk Image and retry";
        BRSetLastError(message);
        BRAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return BRBootstrapResultNoXCTestRuntime;
    }

    const char *bundlePathUTF8 = resolvedBundlePath.fileSystemRepresentation;
    const char *logPathUTF8 = logPath.fileSystemRepresentation;
    if (bundlePathUTF8 == NULL || logPathUTF8 == NULL) {
        NSString *message = @"could not encode test bundle or log path as UTF-8";
        BRSetLastError(message);
        BRAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return BRBootstrapResultInvalidBundle;
    }

    int setenvResult = setenv("XCTestBundlePath", bundlePathUTF8, 1);
    BRAppendLog(logPath, [NSString stringWithFormat:
        @"env_set XCTestBundlePath=%@ result=%d", resolvedBundlePath, setenvResult]);
    const char *keysToUnset[] = {
        "XCTestConfigurationFilePath",
        "XCTestConfigurationEncodedValueEnvironmentKey",
        "XCTestBundleInjectPath",
        "XCTestSessionIdentifier",
        "XCTestManagerVariant",
    };
    for (size_t index = 0; index < sizeof(keysToUnset) / sizeof(keysToUnset[0]); index++) {
        int unsetResult = unsetenv(keysToUnset[index]);
        BRAppendLog(logPath, [NSString stringWithFormat:@"env_unset %s result=%d", keysToUnset[index], unsetResult]);
    }

    NSString *loadedRuntime = nil;
    void *entrySymbol = NULL;
    void *loadedHandle = NULL;
    for (NSInteger pass = 0; pass < 2 && entrySymbol == NULL; pass++) {
        NSString *suffix = pass == 0 ? @"/XCTest.framework/XCTest" : @"/XCTestCore.framework/XCTestCore";
        for (NSString *path in BRCandidatePaths()) {
            if (![path hasSuffix:suffix]) { continue; }
            BOOL isDirectory = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) { continue; }
            dlerror();
            void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            if (handle == NULL) {
                const char *error = dlerror();
                BRAppendLog(logPath, [NSString stringWithFormat:@"dlopen_failed path=%@ error=%s", path, error ?: "<none>"]);
                continue;
            }
            dlerror();
            void *symbol = dlsym(handle, "_XCTestMain");
            if (symbol == NULL) { symbol = dlsym(RTLD_DEFAULT, "_XCTestMain"); }
            if (symbol == NULL) {
                const char *error = dlerror();
                BRAppendLog(logPath, [NSString stringWithFormat:
                    @"dlsym_failed path=%@ symbol=_XCTestMain error=%s", path, error ?: "<none>"]);
                continue;
            }
            loadedHandle = handle;
            loadedRuntime = path;
            entrySymbol = symbol;
            break;
        }
    }

    if (entrySymbol == NULL) {
        NSString *message = @"could not load the DDI XCTest runtime or resolve _XCTestMain";
        BRSetLastError(message);
        BRAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return BRBootstrapResultMissingEntryPoint;
    }

    gRuntimeHandle = loadedHandle;
    BRAppendLog(logPath, [NSString stringWithFormat:
        @"xctest_runtime_loaded path=%@ _XCTestMain=%p bundle=%@",
        loadedRuntime, entrySymbol, bundleIdentifier]);

    BREntryContext *context = calloc(1, sizeof(BREntryContext));
    if (context == NULL) {
        NSString *message = @"could not allocate the XCTest entry context";
        BRSetLastError(message);
        BRAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return BRBootstrapResultEntryContextFailure;
    }
    context->xctestPath = strdup(bundlePathUTF8);
    context->logPath = strdup(logPathUTF8);
    context->runtimePath = strdup(loadedRuntime.fileSystemRepresentation);
    context->entryPoint = (BRXCTestMainFn)entrySymbol;
    context->generation = generation;
    pthread_mutex_lock(&gStateLock);
    gCancellationCheck = [cancellationCheck copy];
    pthread_mutex_unlock(&gStateLock);
    if (context->xctestPath == NULL || context->logPath == NULL || context->runtimePath == NULL) {
        NSString *message = @"could not copy the XCTest entry context strings";
        BRSetLastError(message);
        BRAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        free(context->xctestPath);
        free(context->logPath);
        free(context->runtimePath);
        free(context);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return BRBootstrapResultEntryContextFailure;
    }

    // Enter the XCTest driver from a main CFRunLoop block, not from a
    // dispatch_async(main) work item. _XCTestMain never returns while the
    // engine is alive; holding a main-queue item for that lifetime leaves the
    // serial main queue busy forever, so every later main-queue/MainActor job
    // (SwiftUI refresh, host command poller, coordinator continuations) is
    // queued but never runs even though a nested run loop keeps UIKit timers
    // firing. A run-loop block keeps the same main-thread requirement without
    // occupying the main dispatch queue, and the nested run loop can continue
    // draining ordinary main-queue work.
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    if (mainRunLoop == NULL) {
        NSString *message = @"the main run loop is unavailable; cannot enter XCTest on the main thread";
        BRSetLastError(message);
        BRAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        free(context->xctestPath);
        free(context->logPath);
        free(context->runtimePath);
        free(context);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return BRBootstrapResultEntryContextFailure;
    }

    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, ^{
        BRRunXCTestEntry(context);
    });
    CFRunLoopWakeUp(mainRunLoop);

    BRAppendLog(logPath, [NSString stringWithFormat:
        @"bootstrap_dispatched runtime=%@ queue=main-runloop-block entry=%p one_shot=1 generation=%llu",
        loadedRuntime, entrySymbol, generation]);
    return BRBootstrapResultOK;
}
