#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Serialized native content-stream editing. No network or active PDF content.
@interface FloePDFiumBridge : NSObject
+ (nullable NSData *)inspect:(NSData *)input error:(NSError **)error;
+ (nullable NSData *)inspect:(NSData *)input pages:(nullable NSArray<NSNumber *> *)selection error:(NSError **)error;
+ (nullable NSData *)flatten:(NSData *)input error:(NSError **)error;
+ (nullable NSData *)unlock:(NSData *)input password:(NSString *)password error:(NSError **)error;
+ (nullable NSData *)replaceRegion:(NSData *)input page:(NSInteger)page bounds:(NSArray<NSNumber *> *)bounds
                           overlay:(nullable NSData *)overlay objectType:(NSInteger)objectType
                    expectedCount:(NSInteger)expectedCount error:(NSError **)error;
+ (nullable NSDictionary<NSString *, id> *)rewrite:(NSData *)input
                                  operationsJSON:(NSData *)operations
                                       cancelled:(BOOL (^)(void))cancelled
                                           error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
