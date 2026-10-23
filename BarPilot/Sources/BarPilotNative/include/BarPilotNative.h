#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Owns one process-scoped assertion; invalidation also cancels pending activation.
@interface BPAssessmentAssertion : NSObject
+ (nullable NSString *)capabilityError;
- (void)activateWithSystemItems:(NSArray<NSNumber *> *)systemItems
            bundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                   completion:(void (^)(NSError * _Nullable error))completion;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
