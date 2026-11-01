#import "BootstrapShim.h"

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

typedef int (*FBCXCTestMainFn)(id);

typedef struct {
    char *xctestPath;
    char *logPath;
    char *runtimePath;
    FBCXCTestMainFn entryPoint;
} FBCEntryContext;

static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL gBootstrapStarted = NO;
static NSString *gLastError = nil;
static void *gRuntimeHandle = NULL;

static void FBCMakeTimestamp(char out[40]) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmValue;
    gmtime_r(&tv.tv_sec, &tmValue);
    snprintf(out, 40, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
             tmValue.tm_year + 1900, tmValue.tm_mon + 1, tmValue.tm_mday,
             tmValue.tm_hour, tmValue.tm_min, tmValue.tm_sec,
             (int)(tv.tv_usec / 1000));
}

void FBCAppendLog(NSString *logPath, NSString *message) {
    if (logPath.length == 0 || message == nil) {
        return;
    }
    char timestamp[40];
    FBCMakeTimestamp(timestamp);
    NSString *line = [NSString stringWithFormat:@"%s %@\n", timestamp, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }

    pthread_mutex_lock(&gLogLock);
    int fd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        const uint8_t *bytes = data.bytes;
        size_t remaining = data.length;
        while (remaining > 0) {
            ssize_t written = write(fd, bytes, remaining);
            if (written <= 0) {
                break;
            }
            bytes += written;
            remaining -= (size_t)written;
        }
        fsync(fd);
        close(fd);
    }
    pthread_mutex_unlock(&gLogLock);
}

static void FBCSetLastError(NSString *message) {
    pthread_mutex_lock(&gStateLock);
    gLastError = [message copy];
    pthread_mutex_unlock(&gStateLock);
}

NSString *FBCLastBootstrapError(void) {
    pthread_mutex_lock(&gStateLock);
    NSString *message = [gLastError copy];
    pthread_mutex_unlock(&gStateLock);
    return message;
}

static NSArray<NSString *> *FBCCandidatePaths(void) {
    return @[
        @"/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
        @"/Developer/Library/Frameworks/XCTest.framework/XCTest",
        @"/private/preboot/Cryptexes/OS/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
        @"/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
        @"/private/preboot/Cryptexes/OS/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
    ];
}

static NSArray<NSString *> *FBCDeveloperDirectories(void) {
    return @[
        @"/System/Developer",
        @"/Developer",
        @"/private/preboot/Cryptexes/OS/System/Developer",
    ];
}

NSDictionary<NSString *, id> *FBCProbeDDI(NSString *logPath) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates = [NSMutableArray array];
    NSString *selected = nil;
    NSUInteger readableCount = 0;

    for (NSString *path in FBCCandidatePaths()) {
        BOOL isDirectory = NO;
        BOOL exists = [fileManager fileExistsAtPath:path isDirectory:&isDirectory];
        BOOL readable = exists && !isDirectory && access(path.fileSystemRepresentation, R_OK) == 0;
        char resolvedBuffer[PATH_MAX];
        resolvedBuffer[0] = '\0';
        if (exists) {
            (void)realpath(path.fileSystemRepresentation, resolvedBuffer);
        }
        NSDictionary *attributes =
            exists ? [fileManager attributesOfItemAtPath:path error:NULL] : nil;
        NSNumber *size = attributes ? @([attributes[NSFileSize] unsignedLongLongValue]) : @0;
        NSString *realPath = resolvedBuffer[0] != '\0'
            ? [NSString stringWithUTF8String:resolvedBuffer]
            : nil;

        NSMutableDictionary<NSString *, id> *candidate = [@{
            @"path": path,
            @"exists": @(exists),
            @"isDirectory": @(isDirectory),
            @"readable": @(readable),
            @"size": size,
        } mutableCopy];
        candidate[@"realPath"] = realPath ?: [NSNull null];
        [candidates addObject:candidate];

        if (readable) {
            readableCount += 1;
            if (selected == nil) {
                selected = path;
            }
        }
        FBCAppendLog(logPath, [NSString stringWithFormat:
            @"ddi_candidate path=%@ exists=%d dir=%d readable=%d size=%llu real=%@",
            path, exists ? 1 : 0, isDirectory ? 1 : 0, readable ? 1 : 0,
            [size unsignedLongLongValue], realPath ?: @"<none>"]);
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *developerDirectories = [NSMutableArray array];
    for (NSString *directory in FBCDeveloperDirectories()) {
        BOOL isDirectory = NO;
        BOOL exists = [fileManager fileExistsAtPath:directory isDirectory:&isDirectory];
        [developerDirectories addObject:@{ @"path": directory, @"exists": @(exists), @"isDirectory": @(isDirectory) }];
    }

    char probedAt[40];
    FBCMakeTimestamp(probedAt);
    NSDictionary<NSString *, id> *result = @{
        @"probedAt": [NSString stringWithUTF8String:probedAt],
        @"selected": selected ?: [NSNull null],
        @"readableCount": @(readableCount),
        @"candidates": candidates,
        @"developerDirectories": developerDirectories,
    };
    FBCAppendLog(logPath, [NSString stringWithFormat:
        @"ddi_probe selected=%@ readable=%lu/%lu",
        selected ?: @"<none>", (unsigned long)readableCount,
        (unsigned long)FBCCandidatePaths().count]);
    return result;
}

static BOOL FBCValidateTestBundle(NSString *xctestPath, NSString *logPath, NSString **bundleIdentifier, NSString **error) {
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
    FBCAppendLog(logPath, [NSString stringWithFormat:
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

static void FBCRunXCTestEntry(FBCEntryContext *context) {
    NSString *logPath = [NSString stringWithUTF8String:context->logPath];

    uint64_t threadID = 0;
    (void)pthread_threadid_np(NULL, &threadID);
    FBCAppendLog(logPath, [NSString stringWithFormat:
        @"xctest_main_entry_entered main_thread=%d thread_id=%llu pid=%d runtime=%@",
        pthread_main_np() ? 1 : 0, threadID, getpid(),
        [NSString stringWithUTF8String:context->runtimePath]]);

    if (!pthread_main_np()) {
        FBCAppendLog(logPath, @"bootstrap_failed reason=XCTestMain entry did not run on the main thread");
        _exit(70);
    }

    FBCAppendLog(logPath, [NSString stringWithFormat:
        @"about_to_call_XCTestMain(nil) entry=%p main_thread=1", (void *)context->entryPoint]);

    int result = context->entryPoint(nil);

    FBCAppendLog(logPath, [NSString stringWithFormat:@"XCTestMain_returned result=%d", result]);
    _exit(result == 0 ? 0 : result);
}

FBCBootstrapResult FBCStartBootstrap(NSString *xctestPath, NSString *logPath) {
    pthread_mutex_lock(&gStateLock);
    BOOL alreadyStarted = gBootstrapStarted;
    if (!alreadyStarted) {
        gBootstrapStarted = YES;
    }
    pthread_mutex_unlock(&gStateLock);

    if (alreadyStarted) {
        FBCSetLastError(@"bootstrap was already dispatched in this process; relaunch the app to retry");
        FBCAppendLog(logPath, @"bootstrap_refused already_started=1");
        return FBCBootstrapResultAlreadyStarted;
    }

    NSString *resolvedBundlePath = [xctestPath stringByResolvingSymlinksInPath];
    FBCAppendLog(logPath, [NSString stringWithFormat:
        @"bootstrap_begin pid=%d bundle=%@ log=%@",
        getpid(), resolvedBundlePath, logPath]);

    NSString *bundleIdentifier = nil;
    NSString *validationError = nil;
    if (!FBCValidateTestBundle(resolvedBundlePath, logPath, &bundleIdentifier, &validationError)) {
        FBCSetLastError(validationError);
        FBCAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", validationError]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return FBCBootstrapResultInvalidBundle;
    }

    NSDictionary<NSString *, id> *ddi = FBCProbeDDI(logPath);
    NSString *selectedRuntime = ddi[@"selected"];
    if (selectedRuntime == nil || ![selectedRuntime isKindOfClass:[NSString class]]) {
        NSString *message = @"no readable DDI XCTest runtime found; mount the Developer Disk Image and relaunch";
        FBCSetLastError(message);
        FBCAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return FBCBootstrapResultNoXCTestRuntime;
    }

    const char *bundlePathUTF8 = resolvedBundlePath.fileSystemRepresentation;
    const char *logPathUTF8 = logPath.fileSystemRepresentation;
    if (bundlePathUTF8 == NULL || logPathUTF8 == NULL) {
        NSString *message = @"could not encode test bundle or log path as UTF-8";
        FBCSetLastError(message);
        FBCAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return FBCBootstrapResultInvalidBundle;
    }

    int setenvResult = setenv("XCTestBundlePath", bundlePathUTF8, 1);
    FBCAppendLog(logPath, [NSString stringWithFormat:
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
        FBCAppendLog(logPath, [NSString stringWithFormat:
            @"env_unset %s result=%d", keysToUnset[index], unsetResult]);
    }

    NSArray<NSDictionary<NSString *, id> *> *candidates = ddi[@"candidates"];
    NSString *loadedRuntime = nil;
    void *entrySymbol = NULL;
    void *loadedHandle = NULL;

    // Prefer XCTest.framework (which re-exports XCTestCore and XCUIAutomation).
    // XCTestCore is attempted only as an explicit fallback so the test bundle's
    // @rpath/XCTest load can reuse one already-loaded XCTest image.
    for (NSInteger pass = 0; pass < 2 && entrySymbol == NULL; pass++) {
        NSString *suffix = pass == 0 ? @"/XCTest.framework/XCTest" : @"/XCTestCore.framework/XCTestCore";
        for (NSDictionary<NSString *, id> *candidate in candidates) {
            if (![candidate[@"exists"] boolValue] || [candidate[@"isDirectory"] boolValue]) {
                continue;
            }
            NSString *path = candidate[@"path"];
            if (![path hasSuffix:suffix]) {
                continue;
            }
            dlerror();
            void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            if (handle == NULL) {
                const char *error = dlerror();
                FBCAppendLog(logPath, [NSString stringWithFormat:
                    @"dlopen_failed path=%@ error=%s", path, error ?: "<none>"]);
                continue;
            }
            dlerror();
            void *symbol = dlsym(handle, "_XCTestMain");
            if (symbol == NULL) {
                symbol = dlsym(RTLD_DEFAULT, "_XCTestMain");
            }
            if (symbol == NULL) {
                const char *error = dlerror();
                FBCAppendLog(logPath, [NSString stringWithFormat:
                    @"dlsym_failed path=%@ symbol=_XCTestMain error=%s",
                    path, error ?: "<none>"]);
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
        FBCSetLastError(message);
        FBCAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return FBCBootstrapResultMissingEntryPoint;
    }

    gRuntimeHandle = loadedHandle;
    FBCAppendLog(logPath, [NSString stringWithFormat:
        @"xctest_runtime_loaded path=%@ _XCTestMain=%p bundle=%@",
        loadedRuntime, entrySymbol, bundleIdentifier]);

    FBCEntryContext *context = calloc(1, sizeof(FBCEntryContext));
    if (context == NULL) {
        NSString *message = @"could not allocate the XCTest entry context";
        FBCSetLastError(message);
        FBCAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return FBCBootstrapResultEntryContextFailure;
    }
    context->xctestPath = strdup(bundlePathUTF8);
    context->logPath = strdup(logPathUTF8);
    context->runtimePath = strdup(loadedRuntime.fileSystemRepresentation);
    context->entryPoint = (FBCXCTestMainFn)entrySymbol;
    if (context->xctestPath == NULL || context->logPath == NULL || context->runtimePath == NULL) {
        NSString *message = @"could not copy the XCTest entry context strings";
        FBCSetLastError(message);
        FBCAppendLog(logPath, [NSString stringWithFormat:@"bootstrap_failed reason=%@", message]);
        free(context->xctestPath);
        free(context->logPath);
        free(context->runtimePath);
        free(context);
        pthread_mutex_lock(&gStateLock);
        gBootstrapStarted = NO;
        pthread_mutex_unlock(&gStateLock);
        return FBCBootstrapResultEntryContextFailure;
    }

    // The XCTest/XCUI driver initializes on the calling thread and asserts that
    // XCUIInitializeForUITesting runs on the main thread. The host UI is already
    // up when Start is dispatched, so enqueue the one _XCTestMain(nil) entry on
    // the main queue. There is no second initializer, retry, delay or entry call.
    dispatch_async(dispatch_get_main_queue(), ^{
        FBCRunXCTestEntry(context);
    });

    FBCAppendLog(logPath, [NSString stringWithFormat:
        @"bootstrap_dispatched runtime=%@ queue=main entry=%p one_shot=1",
        loadedRuntime, entrySymbol]);
    return FBCBootstrapResultOK;
}
