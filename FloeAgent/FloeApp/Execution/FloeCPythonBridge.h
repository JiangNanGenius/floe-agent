#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimal Objective-C boundary around the CPython C API. The bridge never
/// exposes Python objects to Swift and returns only property-list values.
@interface FloeCPythonBridge : NSObject

+ (nullable NSString *)runtimeVersionWithError:(NSError * _Nullable * _Nullable)error;

+ (NSDictionary<NSString *, id> *)runScript:(NSString *)script
                                   inputJSON:(nullable NSString *)inputJSON
                                      timeout:(NSTimeInterval)timeout
                               maxOutputBytes:(NSInteger)maxOutputBytes;

@end

NS_ASSUME_NONNULL_END
