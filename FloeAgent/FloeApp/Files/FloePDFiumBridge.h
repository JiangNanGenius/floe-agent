#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Serialized native content-stream editing. No network or active PDF content.
@interface FloePDFiumBridge : NSObject
+ (nullable NSDictionary<NSString *, id> *)rewrite:(NSData *)input
                                  operationsJSON:(NSData *)operations
                                       cancelled:(BOOL (^)(void))cancelled
                                           error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
