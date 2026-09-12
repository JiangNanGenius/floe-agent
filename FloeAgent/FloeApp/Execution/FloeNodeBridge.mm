//
//  FloeNodeBridge.mm
//  Floe Agent
//
//  nodejs-mobile bridge. One Node instance per process (libuv is single
//  instance); calls are serialized and captured through file descriptors.
//

#import "FloeNodeBridge.h"

#import <unistd.h>
#import <fcntl.h>
#import <pthread.h>
#import <string.h>

#if __has_include(<NodeMobile/NodeMobile.h>)
#import <NodeMobile/NodeMobile.h>
#define FLOE_HAS_NODE 1
#else
#define FLOE_HAS_NODE 0
#endif

extern int node_start(int argc, char **argv);

static NSLock *FloeNodeLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

BOOL FloeNodeRuntimeAvailable(void) {
#if FLOE_HAS_NODE
    return YES;
#else
    return NO;
#endif
}

NSString *FloeNodeBundledToolPath(NSString *command) {
    NSString *relative = nil;
    if ([command isEqualToString:@"npm"]) { relative = @"NodeTools/npm/bin/npm-cli.js"; }
    else if ([command isEqualToString:@"npx"]) { relative = @"NodeTools/npm/bin/npx-cli.js"; }
    else if ([command isEqualToString:@"pnpm"]) { relative = @"NodeTools/pnpm/pnpm.cjs"; }
    else if ([command isEqualToString:@"pnpx"]) { relative = @"NodeTools/pnpm/pnpx.cjs"; }
    else if ([command isEqualToString:@"yarn"]) { relative = @"NodeTools/yarn/bin/yarn.js"; }
    if (relative == nil) { return nil; }
    NSString *path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:relative];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

namespace {

struct FloeNodeRunContext {
    int argc;
    char **argv;
    int32_t exitCode;
    BOOL finished;
};

void *FloeNodeThreadMain(void *rawContext) {
    FloeNodeRunContext *context = (FloeNodeRunContext *)rawContext;
    @autoreleasepool {
        context->exitCode = (int32_t)node_start(context->argc, context->argv);
        context->finished = YES;
    }
    return NULL;
}

NSString *FloeNodeReadFile(NSString *path, NSUInteger maxBytes) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) { return @""; }
    NSData *data = [handle readDataUpToLength:maxBytes error:nil] ?: [NSData data];
    [handle closeFile];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

} // namespace

FloeNodeBridgeStatus FloeNodeRun(
    NSString *entryScript,
    NSArray<NSString *> *arguments,
    NSString *workingDirectory,
    NSDictionary<NSString *, NSString *> *environment,
    NSData *stdinData,
    NSTimeInterval timeout,
    NSUInteger maxOutputBytes,
    NSString **outStdout,
    NSString **outStderr,
    int32_t *outExitCode
) {
    if (!FloeNodeRuntimeAvailable()) {
        return FloeNodeBridgeStatusUnavailable;
    }
    [FloeNodeLock() lock];
    @try {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *tempRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"floe-node-%@", NSUUID.UUID.UUIDString]];
        [fileManager createDirectoryAtPath:tempRoot withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *stdoutPath = [tempRoot stringByAppendingPathComponent:@"stdout"];
        NSString *stderrPath = [tempRoot stringByAppendingPathComponent:@"stderr"];
        [fileManager createFileAtPath:stdoutPath contents:[NSData data] attributes:nil];
        [fileManager createFileAtPath:stderrPath contents:[NSData data] attributes:nil];

        for (NSString *key in environment) {
            setenv(key.UTF8String, environment[key].UTF8String, 1);
        }
        if (workingDirectory.length > 0) {
            [fileManager changeCurrentDirectoryPath:workingDirectory];
        }

        int stdoutFD = open(stdoutPath.fileSystemRepresentation, O_WRONLY | O_APPEND);
        int stderrFD = open(stderrPath.fileSystemRepresentation, O_WRONLY | O_APPEND);
        int savedStdout = dup(STDOUT_FILENO);
        int savedStderr = dup(STDERR_FILENO);
        int savedStdin = dup(STDIN_FILENO);
        if (stdoutFD >= 0) { dup2(stdoutFD, STDOUT_FILENO); }
        if (stderrFD >= 0) { dup2(stderrFD, STDERR_FILENO); }

        NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:@"node"];
        if (entryScript.length > 0) {
            [argv addObject:entryScript];
        }
        [argv addObjectsFromArray:arguments];

        int argc = (int)argv.count;
        char **cargv = (char **)malloc(sizeof(char *) * (argc + 1));
        for (int index = 0; index < argc; index++) {
            cargv[index] = strdup(argv[index].UTF8String);
        }
        cargv[argc] = NULL;

        FloeNodeRunContext *context = new FloeNodeRunContext();
        context->argc = argc;
        context->argv = cargv;
        context->exitCode = 0;
        context->finished = NO;

        NSTimeInterval started = [NSDate date].timeIntervalSince1970;
        pthread_t thread;
        pthread_create(&thread, NULL, FloeNodeThreadMain, context);
        BOOL timedOut = NO;
        while (!context->finished) {
            if ([NSDate date].timeIntervalSince1970 - started > timeout) {
                timedOut = YES;
                pthread_kill(thread, SIGINT);
                break;
            }
            [NSThread sleepForTimeInterval:0.05];
        }
        if (!timedOut) { pthread_join(thread, NULL); }

        if (savedStdout >= 0) { dup2(savedStdout, STDOUT_FILENO); close(savedStdout); }
        if (savedStderr >= 0) { dup2(savedStderr, STDERR_FILENO); close(savedStderr); }
        if (savedStdin >= 0) { dup2(savedStdin, STDIN_FILENO); close(savedStdin); }
        if (stdoutFD >= 0) { close(stdoutFD); }
        if (stderrFD >= 0) { close(stderrFD); }

        if (outStdout) { *outStdout = FloeNodeReadFile(stdoutPath, maxOutputBytes); }
        if (outStderr) { *outStderr = FloeNodeReadFile(stderrPath, maxOutputBytes); }
        if (outExitCode) { *outExitCode = context->exitCode; }
        for (int index = 0; index < argc; index++) { free(cargv[index]); }
        free(cargv);
        delete context;
        [fileManager removeItemAtPath:tempRoot error:nil];
        return timedOut ? FloeNodeBridgeStatusTimedOut : FloeNodeBridgeStatusOK;
    } @finally {
        [FloeNodeLock() unlock];
    }
}
