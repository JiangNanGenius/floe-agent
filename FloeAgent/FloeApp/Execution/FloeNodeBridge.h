//
//  FloeNodeBridge.h
//  Floe Agent
//
//  nodejs-mobile bridge. The runtime is linked as NodeMobile.framework; when
//  the framework is absent every entry point reports unavailability instead
//  of failing the build.
//

#import <Foundation/Foundation.h>
#import "FloeTLSConfiguration.h"

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, FloeNodeBridgeStatus) {
    FloeNodeBridgeStatusOK = 0,
    FloeNodeBridgeStatusUnavailable = 1,
    FloeNodeBridgeStatusTimedOut = 2,
    FloeNodeBridgeStatusCancelled = 3,
};

/// Runs a Node entry script on the shared runtime thread. `entryScript` is a
/// container-relative path (or absolute path inside the app container).
FloeNodeBridgeStatus FloeNodeRun(
    NSString * _Nullable entryScript,
    NSArray<NSString *> *arguments,
    NSString *workingDirectory,
    NSDictionary<NSString *, NSString *> *environment,
    NSData * _Nullable stdinData,
    int stdinFileDescriptor,
    NSTimeInterval timeout,
    NSUInteger maxOutputBytes,
    BOOL (^ _Nullable shouldCancel)(void),
    NSString * _Nullable * _Nullable outStdout,
    NSString * _Nullable * _Nullable outStderr,
    int32_t *outExitCode,
    BOOL *outTruncated
);

/// Control a service independently of the foreground execution queue.
/// Call off the main thread. An unknown result retains ownership until reconciled.
NSDictionary *FloeNodeServiceCommand(NSDictionary *request, NSString *environmentID);
NSArray<NSString *> *FloeNodeServiceIDs(NSString *environmentID);

BOOL FloeNodeRuntimeAvailable(void);
/// Initializes the host if needed and returns its actual version. Call off the main thread.
NSString * _Nullable FloeNodeRuntimeVersion(void);
BOOL FloeNodeHasActiveTask(NSString *environmentID);

/// Absolute path of the bundled tool entry point for a command name
/// (`npm`, `npx`, `pnpm`, `pnpx`, `yarn`), or nil.
NSString * _Nullable FloeNodeBundledToolPath(NSString *command);

#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
