//
//  FloeNodeBridge.h
//  Floe Agent
//
//  nodejs-mobile bridge. The runtime is linked as NodeMobile.framework; when
//  the framework is absent every entry point reports unavailability instead
//  of failing the build.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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
    NSTimeInterval timeout,
    NSUInteger maxOutputBytes,
    NSString * _Nullable * _Nullable outStdout,
    NSString * _Nullable * _Nullable outStderr,
    int32_t *outExitCode
);

BOOL FloeNodeRuntimeAvailable(void);

/// Absolute path of the bundled tool entry point for a command name
/// (`npm`, `npx`, `pnpm`, `pnpx`, `yarn`), or nil.
NSString * _Nullable FloeNodeBundledToolPath(NSString *command);

NS_ASSUME_NONNULL_END
