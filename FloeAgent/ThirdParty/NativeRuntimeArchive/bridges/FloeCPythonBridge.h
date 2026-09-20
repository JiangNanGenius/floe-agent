#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimal Objective-C boundary around the CPython C API. The bridge never
/// exposes Python objects to Swift and returns only property-list values.
@interface FloeCPythonBridge : NSObject

/// Service controls must run off the main thread. Worker startup does not prove HTTP readiness.
+ (NSDictionary<NSString *, id> *)startService:(NSString *)script
                                  contextJSON:(NSString *)contextJSON
                                environmentID:(NSString *)environmentID
                               maxOutputBytes:(NSInteger)maxOutputBytes;
+ (NSDictionary<NSString *, id> *)serviceStatus:(NSString *)serviceID environmentID:(NSString *)environmentID;
+ (NSDictionary<NSString *, id> *)stopService:(NSString *)serviceID environmentID:(NSString *)environmentID;
+ (BOOL)hasActiveServices:(NSString *)environmentID;
+ (BOOL)stopServices:(NSString *)environmentID;

+ (nullable NSString *)runtimeVersionWithError:(NSError * _Nullable * _Nullable)error;

+ (NSDictionary<NSString *, id> *)runScript:(NSString *)script
                                   inputJSON:(nullable NSString *)inputJSON
                                 contextJSON:(nullable NSString *)contextJSON
                                      timeout:(NSTimeInterval)timeout
                               maxOutputBytes:(NSInteger)maxOutputBytes
                        allowPackageInstaller:(BOOL)allowPackageInstaller
                                 shouldCancel:(BOOL (^ _Nullable)(void))shouldCancel;

@end

NS_ASSUME_NONNULL_END
