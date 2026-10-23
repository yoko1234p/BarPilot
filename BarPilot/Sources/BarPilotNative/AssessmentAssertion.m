#import "BarPilotNative.h"
#import <dlfcn.h>
#import <objc/runtime.h>

static NSString *BPLocalized(NSString *key, NSString *fallback) {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"BarPilot_BarPilotCore" withExtension:@"bundle"];
    NSBundle *bundle = url ? [NSBundle bundleWithURL:url] : NSBundle.mainBundle;
    NSString *override = NSProcessInfo.processInfo.environment[@"APP_UI_LANGUAGE"];
    if (override && [@[@"en", @"zh-Hant", @"zh-Hans"] containsObject:override]) {
        NSString *path = [bundle pathForResource:override ofType:@"lproj"];
        if (path) bundle = [NSBundle bundleWithPath:path];
    }
    return [bundle localizedStringForKey:key value:fallback table:nil];
}

@interface NSObject (BPAssessmentSelectors)
- (instancetype)initWithAllowedSystemItems:(NSArray *)items allowedBundleIdentifiers:(NSArray *)identifiers;
- (void)activateWithConfiguration:(id)configuration completionHandler:(void (^)(NSError *))completion;
- (void)invalidate;
@end

static NSString *BPCheckCapability(void) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY | RTLD_LOCAL);
    });
    if (!framework) return BPLocalized(@"未能載入 macOS 選單列服務。", @"Could not load the macOS menu bar service.");
    Class config = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
    Method initializer = class_getInstanceMethod(config, @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:));
    Method activation = class_getInstanceMethod(assertion, @selector(activateWithConfiguration:completionHandler:));
    Method invalidation = class_getInstanceMethod(assertion, @selector(invalidate));
    if (!initializer || !activation || !invalidation
        || strcmp(method_getTypeEncoding(initializer), "@32@0:8@16@24")
        || strcmp(method_getTypeEncoding(activation), "v32@0:8@16@?24")
        || strcmp(method_getTypeEncoding(invalidation), "v16@0:8")) {
        return BPLocalized(@"這個 macOS 版本的選單列介面已改變，隱藏管理未有啟動。", @"The menu bar interface has changed in this macOS version. Hiding was not enabled.");
    }
    return nil;
}

@implementation BPAssessmentAssertion {
    id _assertion;
    NSUInteger _generation;
}
+ (NSString *)capabilityError { return BPCheckCapability(); }
- (void)activateWithSystemItems:(NSArray<NSNumber *> *)systemItems bundleIdentifiers:(NSArray<NSString *> *)identifiers
                   completion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Assessment lifecycle runs on the main thread");
    [self invalidate];
    NSUInteger request = _generation;
    NSString *error = BPCheckCapability();
    NSString *ownIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (!ownIdentifier.length || ![identifiers containsObject:ownIdentifier]) {
        error = BPLocalized(@"未能保留 BarPilot 控制圖示，已取消隱藏。", @"Could not keep the BarPilot control visible. Hiding was cancelled.");
    }
    if (error) {
        completion([NSError errorWithDomain:@"BarPilot.Assessment" code:1 userInfo:@{NSLocalizedDescriptionKey:error}]);
        return;
    }
    @try {
        Class configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        id configuration = [[configClass alloc] initWithAllowedSystemItems:systemItems allowedBundleIdentifiers:identifiers];
        _assertion = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        if (!configuration || !_assertion) {
            [self invalidate];
            completion([NSError errorWithDomain:@"BarPilot.Assessment" code:2 userInfo:@{NSLocalizedDescriptionKey:BPLocalized(@"macOS 未能建立隱藏設定。", @"macOS could not create the hiding configuration.")}]);
            return;
        }
        __weak BPAssessmentAssertion *weakSelf = self;
        [_assertion activateWithConfiguration:configuration completionHandler:^(NSError *nativeError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BPAssessmentAssertion *owner = weakSelf;
                if (!owner || owner->_generation != request) return;
                if (nativeError) [owner invalidate];
                completion(nativeError);
            });
        }];
    } @catch (NSException *exception) {
        [self invalidate];
        completion([NSError errorWithDomain:@"BarPilot.Assessment" code:3 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: BPLocalized(@"macOS 隱藏服務未能完成。", @"The macOS hiding service could not finish.")}]);
    }
}
- (void)invalidate {
    _generation++;
    if (_assertion) {
        @try { [_assertion invalidate]; } @catch (NSException *exception) { /* Handle is still released. */ }
        _assertion = nil;
    }
}
- (void)dealloc { [self invalidate]; }
@end
