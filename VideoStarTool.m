// ============================================================================
// VideoStarTool.m — Video Star 14.3.3 (build 1809) — v5.5
//
// CẬP NHẬT v5.5:
//   - Giao diện mới nền tím đậm + hồng pastel phát sáng (#FF9FCA), nút bo tròn
//     dạng pill (đồng bộ cho Menu, Thông báo, Bảng chọn phân cảnh, Tiến trình, HUD).
//   - Đổi cách mở/đóng menu từ chạm 3 ngón 2 lần sang nút nổi hình Hello Kitty
//     đã xoá nền (kéo thả tự do trên màn hình, chạm để mở/đóng menu).
//   - Fix chức năng 4: sau khi chọn ảnh/video ở đoạn 1, từ đoạn 2 trở đi tự động
//     nhập ngầm đúng ảnh đó (gọi thẳng pickedWithClipPickerResponse: kèm chặn
//     đóng editor), không hiện lại bảng chọn ảnh. Nếu lỗi -> tự quay về chọn tay.
//   - Ẩn hoàn toàn thanh trạng thái hệ thống (giờ, Wi-Fi, sóng, pin) khi ở trong app.
// ============================================================================

#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/proc.h>
#import <math.h>

#define VS_MAX_LAYERS 40
#define VS_MIN_FREE_MB 200
#define VS_COPY_CONFIRM_TIMEOUT 10.0
#define VS_REPLAY_TIMEOUT 6.0
#define VSLog(...) ((void)0)

typedef id (^VSObjProvider)(void);
typedef void (^VSFillCompletion)(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stopReason);

// ============================================================================
// AN TOÀN
// ============================================================================

static void VSAbortActiveTask(NSString *reason);

static void VSGuard(void (^block)(void)) {
    @try { block(); }
    @catch (NSException *e) {
        VSAbortActiveTask([NSString stringWithFormat:@"Dừng an toàn, app báo lỗi: %@", e.reason ?: e.name]);
    }
}

static inline void VSRunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) { @autoreleasepool { VSGuard(block); } }
    else { dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { VSGuard(block); } }); }
}

static inline void VSDispatchAfterMS(int64_t delayMs, dispatch_block_t block) {
    if (delayMs <= 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { VSGuard(block); } });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ @autoreleasepool { VSGuard(block); } });
}

static BOOL VSTry(void (^block)(void)) {
    @try { block(); return YES; }
    @catch (NSException *__unused e) { return NO; }
}

// ============================================================================
// BỘ NHỚ
// ============================================================================

static CFAbsoluteTime g_memoryWarningAt = 0;

static unsigned long long VSAvailableMemoryMB(void) {
    if (@available(iOS 13.0, *)) {
        uint64_t bytes = (uint64_t)os_proc_available_memory();
        return bytes == 0 ? 100000ULL : bytes / (1024ULL * 1024ULL);
    }
    return 100000ULL;
}

static BOOL VSMemoryHealthy(void) {
    if (g_memoryWarningAt > 0 && CFAbsoluteTimeGetCurrent() - g_memoryWarningAt < 5.0) return NO;
    return VSAvailableMemoryMB() >= VS_MIN_FREE_MB;
}

// ============================================================================
// PRIVATE API
// ============================================================================

@protocol ProjectInterface <NSObject>
@property (nonatomic, readonly) NSUInteger sceneCount;
@property (nonatomic, readonly) NSUInteger lastSceneIndex;
@property (nonatomic) CGFloat songBPM;
@property (nonatomic) CGFloat songFirstBeatTime;
- (CGFloat)durationOfSceneAtIndex:(NSUInteger)sceneIndex;
- (CMTime)sceneStartCMTime:(NSUInteger)sceneIndex;
- (BOOL)sceneHasAtLeastOneClipWithSceneIndex:(NSUInteger)sceneIndex;
- (NSUInteger)clipCountForSceneIndex:(NSUInteger)sceneIndex;
- (id)fileManager;
@end

@interface NSObject (VSPrivateDeclarations)
- (id)getMultiLayerEngine;
- (void)pickNewContent;
- (void)pickedWithClipPickerResponse:(id)response;
- (NSInteger)lastSelectedLayerNum;
- (void)selectLayer:(NSUInteger)n bordered:(BOOL)b;
- (void)selectLayerNum:(NSUInteger)n flash:(BOOL)f;
- (void)handleImageGenUpdate;
- (void)engineResync;
- (void)refreshDisplay;
- (void)create;
- (void)importedData:(id)data code:(id)code;
- (void)importOldPreset:(id)preset;
- (void)importNewPreset:(id)preset keyFrameAction:(id)action qrDurationInFrames:(NSInteger)frames;
- (BOOL)isViewLoaded;
- (UIView *)view;
- (UINavigationController *)navigationController;
- (id)layerAtLayerNum:(NSUInteger)n;
- (NSInteger)numActiveLayers;
- (void)reloadLayerEffects;
- (NSUInteger)navSceneIndex;
- (id<ProjectInterface>)project;
- (NSUInteger)sceneIndex;
- (void)showMergeScenes;
- (void)closeMergePanel;
- (void)showMultiLayer;
- (void)showSplitScene;
- (NSUInteger)lastViewedSceneIndex;
- (void)setLastViewedSceneIndex:(NSUInteger)i;
- (BOOL)isEnoughStorageAvailableForSplit;
- (BOOL)beatModeOn;
- (void)toggleBeatMode;
- (BOOL)hasNextBeat;
- (void)jumpToNextBeat;
- (void)setSplitPoint;
- (void)doSplit;
- (void)gotoTime:(CMTime)t;
- (CMTime)currentTime;
+ (id)sharedInstance;
- (void)selectedCode:(id)code withImageData:(id)data;
- (void)startQRImport;
- (void)setDelegate:(id)delegate;
- (id)delegate;
- (void)show;
- (void)dismiss;
- (void)simulateButtonPressButtonWithTitle:(id)title;
@end

@interface NSObject (VSFillDeclarations)
- (BOOL)assetHasBeenLoadedForLayer:(NSUInteger)n;
- (NSInteger)layerTypeForLayer:(NSUInteger)n;
- (BOOL)isNullLayer:(NSUInteger)n;
- (BOOL)particlesExistOnLayerNum:(NSUInteger)n;
- (BOOL)drawingExistsOnLayerNum:(NSUInteger)n;
- (BOOL)gifExistsOnLayerNum:(NSUInteger)n;
- (BOOL)overlayObjectExistsOnLayerNum:(NSUInteger)n;
- (BOOL)zapsObjectExistsOnLayerNum:(NSUInteger)n;
- (void)copyLayer:(NSUInteger)n;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show removeOverlayBlending:(BOOL)remove;
@end

// ============================================================================
// UTILITIES
// ============================================================================

static NSUInteger g_runIdentifier = 0;
static BOOL g_autoConfirmPopups = NO;
static BOOL g_suppressLayerActionMenu = NO;
static BOOL g_createInProgress = NO;
static BOOL g_dismissLayerMenu = NO;
static BOOL g_vsaAutomating = NO;
static id g_cachedPickResponse = nil;            // Lựa chọn ảnh của đoạn đầu, dùng lại cho các đoạn sau
static BOOL g_captureMediaResponse = NO;         // Đang chờ người dùng chọn ảnh thật -> lưu lại
static BOOL g_silentMediaReplay = NO;            // Đang nhập ngầm ảnh đã lưu (chặn đóng editor khi không có picker)
static const void *kVSMenuDismissedKey = &kVSMenuDismissedKey;
static const void *kVSPopupHandledKey = &kVSPopupHandledKey;
static NSHashTable *g_activePopupsTable = nil;
static UIWindow *g_overlayToolWindow = nil;
static void (^g_onLayerAddedHandler)(id sender) = nil;
static IMP g_origConfirmAdd4 = NULL;
static IMP g_origConfirmAdd5 = NULL;

static NSString *VSCheapDescription(id obj) {
    if (!obj || obj == [NSNull null]) return @"";
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([obj isKindOfClass:[NSURL class]]) return ((NSURL *)obj).absoluteString ?: @"";
    if ([obj isKindOfClass:[NSData class]]) return [NSString stringWithFormat:@"data#%lu", (unsigned long)((NSData *)obj).length];
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSDictionary class]] || [obj isKindOfClass:[NSSet class]]) {
        return [NSString stringWithFormat:@"%@#%lu", NSStringFromClass([obj class]), (unsigned long)[obj count]];
    }
    if ([obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSValue class]]) return [obj description] ?: @"";
    return [NSString stringWithFormat:@"%@", NSStringFromClass([obj class])];
}

static UIImage *VSDownscaledImage(UIImage *image, CGFloat maxSide) {
    if (!image) return nil;
    CGSize s = image.size;
    CGFloat longest = MAX(s.width, s.height);
    if (longest <= 0 || longest <= maxSide) return image;
    CGFloat k = maxSide / longest;
    CGSize target = CGSizeMake(floor(s.width * k), floor(s.height * k));
    if (target.width < 1 || target.height < 1) return image;
    UIGraphicsBeginImageContextWithOptions(target, NO, 1.0);
    [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: image;
}

static BOOL VSSafeIsClass(id object, NSString *className) {
    if (!object || !className.length) return NO;
    Class targetClass = NSClassFromString(className);
    return targetClass && [object isKindOfClass:targetClass];
}

static inline BOOL VSContains(NSString *haystack, NSString *needle) {
    if (!haystack.length || !needle.length) return NO;
    return [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL VSHasIvar(id object, NSString *name) {
    if (!object || !name.length) return NO;
    return class_getInstanceVariable(object_getClass(object), name.UTF8String) != NULL;
}

static id VSSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        BOOL available = [object respondsToSelector:NSSelectorFromString(key)]
                      || VSHasIvar(object, [@"_" stringByAppendingString:key])
                      || VSHasIvar(object, key);
        if (!available) return nil;
        return [object valueForKey:key];
    } @catch (NSException *__unused e) { return nil; }
}

static BOOL VSValueIsTruthy(id value) {
    if (!value || value == [NSNull null]) return NO;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value boolValue];
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value length] > 0;
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]] ||
        [value isKindOfClass:[NSDictionary class]]) return [value count] > 0;
    return YES;
}

static NSUInteger VSCountOf(id value) {
    if (!value) return 0;
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]] ||
        [value isKindOfClass:[NSDictionary class]]) return [value count];
    return 0;
}

static inline CMTime VSSafeCurrentTime(id object) {
    if (!object) return kCMTimeInvalid;
    SEL sel = @selector(currentTime);
    if (![object respondsToSelector:sel]) return kCMTimeInvalid;
    @try {
        CMTime (*func)(id, SEL) = (CMTime (*)(id, SEL))[object methodForSelector:sel];
        return func(object, sel);
    } @catch (NSException *__unused e) { return kCMTimeInvalid; }
}

static inline void VSSetQRDelegateSafely(id qrManager, id delegate) {
    if (!qrManager) return;
    SEL sel = @selector(setDelegate:);
    if (![qrManager respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, id))[qrManager methodForSelector:sel])(qrManager, sel, delegate); }
    @catch (NSException *__unused e) {}
}

static UIBarButtonItem *VSFindCreateButtonOnEditor(id editorVC) {
    if (!editorVC) return nil;
    NSArray *createKeywords = @[@"tạo", @"create", @"done", @"xong", @"save", @"lưu", @"export", @"xuất"];
    NSArray *cancelKeywords = @[@"hủy", @"huỷ", @"cancel", @"back", @"quay lại", @"dismiss", @"close", @"đóng"];

    id cancelButton = VSSafeValueForKey(editorVC, @"cancelBarButton");
    BOOL (^isCreateButton)(UIBarButtonItem *) = ^BOOL(UIBarButtonItem *btn) {
        if (!btn || btn == cancelButton) return NO;
        NSString *title = btn.title ?: @"";
        NSString *actionStr = btn.action ? [NSStringFromSelector(btn.action) stringByReplacingOccurrencesOfString:@"_" withString:@""] : @"";
        for (NSString *kw in cancelKeywords) if (VSContains(title, kw) || VSContains(actionStr, kw)) return NO;
        for (NSString *kw in createKeywords) if (VSContains(title, kw) || VSContains(actionStr, kw)) return YES;
        return NO;
    };

    id kvcButton = VSSafeValueForKey(editorVC, @"createBarButton");
    if ([kvcButton isKindOfClass:[UIBarButtonItem class]] && kvcButton != cancelButton) {
        return (UIBarButtonItem *)kvcButton;
    }

    UINavigationController *nav = nil;
    @try { nav = [editorVC navigationController]; } @catch (NSException *__unused e) { nav = nil; }
    if (nav) {
        UINavigationItem *navItem = nav.topViewController.navigationItem;
        for (UIBarButtonItem *btn in navItem.rightBarButtonItems) {
            if (isCreateButton(btn)) return btn;
        }
        if (isCreateButton(navItem.rightBarButtonItem)) return navItem.rightBarButtonItem;
    }
    return nil;
}

static void VSSafePoll(NSUInteger runId, int64_t intervalMs, NSUInteger remainingTries,
                       BOOL (^conditionBlock)(void), void (^completionBlock)(BOOL success)) {
    if (runId != g_runIdentifier) { if (completionBlock) VSGuard(^{ completionBlock(NO); }); return; }
    BOOL matched = NO;
    @autoreleasepool {
        @try { matched = conditionBlock(); }
        @catch (NSException *__unused e) { matched = NO; }
    }
    if (matched) { if (completionBlock) VSGuard(^{ completionBlock(YES); }); return; }
    if (remainingTries == 0) { if (completionBlock) VSGuard(^{ completionBlock(NO); }); return; }
    VSDispatchAfterMS(intervalMs, ^{
        VSSafePoll(runId, intervalMs, remainingTries - 1, conditionBlock, completionBlock);
    });
}

static void VSSafePollEditor(NSUInteger runId, int64_t intervalMs, NSUInteger remainingTries,
                             VSObjProvider provider,
                             BOOL (^cond)(id obj),
                             void (^completion)(BOOL success)) {
    if (runId != g_runIdentifier) { if (completion) VSGuard(^{ completion(NO); }); return; }
    id obj = provider ? provider() : nil;
    if (!obj) { if (completion) VSGuard(^{ completion(NO); }); return; }
    BOOL matched = NO;
    @autoreleasepool {
        @try { matched = cond(obj); }
        @catch (NSException *__unused e) { matched = NO; }
    }
    obj = nil;
    if (matched) { if (completion) VSGuard(^{ completion(YES); }); return; }
    if (remainingTries == 0) { if (completion) VSGuard(^{ completion(NO); }); return; }
    VSDispatchAfterMS(intervalMs, ^{
        VSSafePollEditor(runId, intervalMs, remainingTries - 1, provider, cond, completion);
    });
}

static void VSWaitForMemory(NSUInteger runId, void (^done)(BOOL ok)) {
    if (runId != g_runIdentifier) { done(NO); return; }
    if (VSMemoryHealthy()) { done(YES); return; }
    VSSafePoll(runId, 300, 25, ^BOOL{ return VSMemoryHealthy(); }, ^(BOOL ok) { done(ok); });
}

static id VSEngineFrom(id editor) {
    if (!editor) return nil;
    __block id e = nil;
    VSTry(^{ e = [editor getMultiLayerEngine]; });
    return e;
}

static NSInteger VSLastSelectedLayer(id editor) {
    if (!editor) return -1;
    __block NSInteger n = -1;
    VSTry(^{ n = [editor lastSelectedLayerNum]; });
    return n;
}

static NSInteger VSNumActiveLayers(id engine) {
    if (!engine) return 0;
    __block NSInteger n = 0;
    VSTry(^{ n = [engine numActiveLayers]; });
    return n;
}

static UIViewController *VSSearchViewControllerRecursive(UIViewController *rootVC, Class targetClass, int depth) {
    if (!rootVC || depth > 15) return nil;
    UIViewController *result = nil;
    if (rootVC.presentedViewController) {
        result = VSSearchViewControllerRecursive(rootVC.presentedViewController, targetClass, depth + 1);
        if (result) return result;
    }
    if ([rootVC isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)rootVC).viewControllers.reverseObjectEnumerator) {
            result = VSSearchViewControllerRecursive(child, targetClass, depth + 1);
            if (result) return result;
        }
    }
    if ([rootVC isKindOfClass:[UITabBarController class]]) {
        result = VSSearchViewControllerRecursive(((UITabBarController *)rootVC).selectedViewController, targetClass, depth + 1);
        if (result) return result;
    }
    for (UIViewController *child in rootVC.childViewControllers.reverseObjectEnumerator) {
        result = VSSearchViewControllerRecursive(child, targetClass, depth + 1);
        if (result) return result;
    }
    if ([rootVC isKindOfClass:targetClass] && rootVC.isViewLoaded && rootVC.view.window) return rootVC;
    return nil;
}

static NSArray<UIWindow *> *VSAllWindows(void) {
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [all addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    return all;
}

static UIViewController *VSFindTopViewControllerNamed(NSString *className) {
    Class targetClass = NSClassFromString(className);
    if (!targetClass) return nil;
    for (UIWindow *w in VSAllWindows().reverseObjectEnumerator) {
        if (w == g_overlayToolWindow || w.hidden || w.alpha <= 0.01) continue;
        UIViewController *found = VSSearchViewControllerRecursive(w.rootViewController, targetClass, 0);
        if (found) return found;
    }
    return nil;
}

static void VSRefreshStatusBarHiddenEverywhere(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    VSTry(^{
        [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];
    });
#pragma clang diagnostic pop
    for (UIWindow *w in VSAllWindows()) {
        UIViewController *vc = w.rootViewController;
        if (vc) VSTry(^{ [vc setNeedsStatusBarAppearanceUpdate]; });
        UIViewController *presented = vc.presentedViewController;
        while (presented) {
            VSTry(^{ [presented setNeedsStatusBarAppearanceUpdate]; });
            presented = presented.presentedViewController;
        }
    }
}

// ============================================================================
// POPUP RESOLVER
// ============================================================================

typedef NS_ENUM(NSInteger, VSPopupActionStatus) {
    VSPopupActionStatusNone = 0,
    VSPopupActionStatusHandled,
    VSPopupActionStatusBlockedPurchase
};

static inline NSString *VSLocalizedString(NSString *key) {
    return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil];
}

static NSArray *VSCollectAllVisiblePopups(id editorVC) {
    NSMutableArray *results = [NSMutableArray array];
    if (editorVC) {
        for (NSString *ivarName in @[@"ourPopup", @"warningPopup", @"object3DPickerPopup", @"copyLayerPopup"]) {
            id popup = VSSafeValueForKey(editorVC, ivarName);
            if (popup && ![results containsObject:popup]) [results addObject:popup];
        }
    }
    if (g_activePopupsTable) {
        for (id popup in g_activePopupsTable.allObjects) {
            if (popup && ![results containsObject:popup]) [results addObject:popup];
        }
    }
    NSMutableArray *visibleOnly = [NSMutableArray array];
    for (id popup in results) {
        if (!VSSafeIsClass(popup, @"CustomPopup")) continue;
        UIView *dimView = VSSafeValueForKey(popup, @"dimView");
        UIView *popupView = [popup isKindOfClass:[UIView class]] ? (UIView *)popup : nil;
        if ((dimView && dimView.window) || (popupView && popupView.window)) [visibleOnly addObject:popup];
    }
    return visibleOnly;
}

static BOOL VSCheckIfPopupIsPurchasePrompt(id popup) {
    NSString *message = [VSSafeValueForKey(popup, @"_message") description] ?: @"";
    NSString *title = [VSSafeValueForKey(popup, @"_title") description] ?: @"";
    NSString *combined = [NSString stringWithFormat:@" %@ %@ ", title, message];
    NSArray *keywords = @[@"purchase", @"subscription", @"unlock pro", @"pro pack", @"restore purchase",
                          @"all access", @" pass ", @" buy ", @"upgrade", @"free trial",
                          @"mua gói", @"khôi phục", @"đăng ký", @"nâng cấp",
                          @"dùng thử", @"mở khóa", @"thanh toán"];
    for (NSString *keyword in keywords) if (VSContains(combined, keyword)) return YES;
    return NO;
}

static BOOL VSTitleMatches(NSString *title, NSString *candidate) {
    if (!title.length || !candidate.length) return NO;
    NSString *trimmed = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (candidate.length <= 4) return [trimmed caseInsensitiveCompare:candidate] == NSOrderedSame;
    return VSContains(trimmed, candidate);
}

static NSArray<NSString *> *VSPopupButtonTitles(id popup, NSDictionary<NSString *, UIButton *> **buttonMap) {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableDictionary<NSString *, UIButton *> *map = [NSMutableDictionary dictionary];
    id strings = VSSafeValueForKey(popup, @"_buttonStrings");
    if ([strings isKindOfClass:[NSArray class]])
        for (id t in (NSArray *)strings) if ([t isKindOfClass:[NSString class]] && [(NSString *)t length]) [titles addObject:t];
    id buttons = VSSafeValueForKey(popup, @"_buttons");
    if ([buttons isKindOfClass:[NSArray class]]) {
        for (id b in (NSArray *)buttons) {
            if (![b isKindOfClass:[UIButton class]]) continue;
            NSString *t = ((UIButton *)b).currentTitle;
            if (!t.length) continue;
            map[t] = (UIButton *)b;
            if (![titles containsObject:t]) [titles addObject:t];
        }
    }
    if (buttonMap) *buttonMap = map;
    return titles;
}

static BOOL VSPopupIsLayerActionMenu(id popup) {
    NSArray<NSString *> *titles = VSPopupButtonTitles(popup, NULL);
    if (titles.count < 3) return NO;
    NSArray *known = @[@"Edit Keyframes", @"Biên tập Khung hình chính",
                       @"Add Mask", @"Thêm Mặt nạ",
                       @"Edit Title", @"Sửa tiêu đề",
                       @"Replace Content", @"Thay Nội dung",
                       @"Deactivate", @"Activate", @"Hủy kích hoạt", @"Kích hoạt",
                       @"Delete", @"Xoá", @"Xóa"];
    NSUInteger hits = 0;
    for (NSString *t in titles) {
        for (NSString *k in known) {
            if (VSTitleMatches(t, k)) { hits++; break; }
        }
    }
    return hits >= 3;
}

static void VSDismissLayerActionMenus(id editorVC) {
    if (!g_dismissLayerMenu) return;
    for (id popup in VSCollectAllVisiblePopups(editorVC)) {
        if (!VSPopupIsLayerActionMenu(popup)) continue;
        if ([objc_getAssociatedObject(popup, kVSMenuDismissedKey) boolValue]) continue;
        objc_setAssociatedObject(popup, kVSMenuDismissedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VSTry(^{
            if ([popup respondsToSelector:@selector(dismiss)]) [popup dismiss];
        });
    }
}

static BOOL VSEditorIsAlive(id editorVC) {
    if (!editorVC) return NO;
    BOOL alive = NO;
    @try {
        UIViewController *vc = (UIViewController *)editorVC;
        UINavigationController *nav = vc.navigationController;
        if (vc.isBeingDismissed || nav.isBeingDismissed) alive = NO;
        else if (vc.isViewLoaded && vc.view.window) alive = YES;
        else if (nav.isViewLoaded && nav.view.window) alive = YES;
        else if (vc.presentedViewController || nav.presentedViewController) alive = YES;
        else if (nav.presentingViewController) alive = YES;
    } @catch (NSException *__unused e) { alive = NO; }
    return alive;
}

static BOOL VSEditorIsBusy(id editorVC) {
    id spinner = VSSafeValueForKey(editorVC, @"spinner");
    if ([spinner isKindOfClass:[UIActivityIndicatorView class]]) {
        UIActivityIndicatorView *sp = (UIActivityIndicatorView *)spinner;
        if (sp.isAnimating && sp.window && !sp.hidden) return YES;
    }
    id alert = VSSafeValueForKey(editorVC, @"loadingAlert");
    if ([alert isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)alert;
        if (v.window && !v.hidden && v.alpha > 0.01) return YES;
    }
    return NO;
}

static BOOL VSPopupWasHandled(id popup) {
    return [objc_getAssociatedObject(popup, kVSPopupHandledKey) boolValue];
}

static BOOL VSTitleIsCancelLike(NSString *title) {
    for (NSString *kw in @[@"hủy", @"huỷ", @"cancel", @"không", @"no", @"back", @"quay lại", @"close", @"đóng", @"dismiss"]) {
        if (kw.length <= 3 ? [title.lowercaseString isEqualToString:kw] : VSContains(title, kw)) return YES;
    }
    return NO;
}

static VSPopupActionStatus VSResolvePopupsImmediately(id editorVC) {
    if (!g_autoConfirmPopups && !g_vsaAutomating) return VSPopupActionStatusNone;
    NSArray *popups = VSCollectAllVisiblePopups(editorVC);
    if (popups.count == 0) return VSPopupActionStatusNone;

    NSArray *matchNames = @[
        @"Khớp: rút ngắn/giãn", @"Match: shorten/stretch",
        @"Trùng khớp", @"Trung khop", @"Match",
        @"Rút ngắn/giãn", @"Shorten/Stretch",
        @"Vừa khít", @"Fit", @"Khớp"
    ];
    NSArray *matchFallbackNames = @[@"Bắt đầu", @"Start", @"Kết thúc", @"End"];
    NSArray *okNames = @[@"OK", @"Đồng ý", @"Xong", @"Done"];
    BOOL anyHandled = NO;

    for (id popup in popups) {
        if (VSPopupIsLayerActionMenu(popup)) continue;
        if (VSCheckIfPopupIsPurchasePrompt(popup)) return VSPopupActionStatusBlockedPurchase;
        if (VSPopupWasHandled(popup)) { anyHandled = YES; continue; }

        NSDictionary<NSString *, UIButton *> *buttonByTitle = nil;
        NSArray<NSString *> *titles = VSPopupButtonTitles(popup, &buttonByTitle);
        if (titles.count == 0) continue;

        NSString *(^firstTitleMatching)(NSArray *) = ^NSString *(NSArray *names) {
            for (NSString *candidate in names) {
                NSString *localized = VSLocalizedString(candidate);
                for (NSString *t in titles) {
                    if (VSTitleIsCancelLike(t)) continue;
                    if (VSTitleMatches(t, candidate) || VSTitleMatches(t, localized)) return t;
                }
            }
            return nil;
        };

        NSString *header = [NSString stringWithFormat:@"%@ %@",
                            [VSSafeValueForKey(popup, @"_title") description] ?: @"",
                            [VSSafeValueForKey(popup, @"_message") description] ?: @""];
        NSString *matchedTitle = nil;

        NSString *matchBtn = firstTitleMatching(matchNames);
        if (matchBtn) {
            matchedTitle = matchBtn;
        } else if (g_autoConfirmPopups) {
            if (VSContains(header, @"Original Preset Layers") || VSContains(header, @"Các lớp Cài đặt sẵn Gốc") ||
                VSContains(header, VSLocalizedString(@"Original Preset Layers"))) {
                matchedTitle = firstTitleMatching(okNames);
            } else if (titles.count == 1) {
                matchedTitle = firstTitleMatching(okNames);
            } else if (firstTitleMatching(matchFallbackNames) && (VSContains(header, @"dài hơn") || VSContains(header, @"longer") || VSContains(header, @"shorter"))) {
                matchedTitle = firstTitleMatching(matchFallbackNames);
            }
        }

        if (!matchedTitle) continue;

        objc_setAssociatedObject(popup, kVSPopupHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([popup isKindOfClass:[UIView class]]) ((UIView *)popup).alpha = 0.0;
        UIView *dimView = VSSafeValueForKey(popup, @"dimView");
        if ([dimView isKindOfClass:[UIView class]]) dimView.alpha = 0.0;

        UIButton *matchedButton = buttonByTitle[matchedTitle];
        VSTry(^{
            if ([popup respondsToSelector:@selector(simulateButtonPressButtonWithTitle:)]) {
                [popup simulateButtonPressButtonWithTitle:matchedTitle];
            } else if (matchedButton) {
                [matchedButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        });
        return VSPopupActionStatusHandled;
    }
    return anyHandled ? VSPopupActionStatusHandled : VSPopupActionStatusNone;
}

static BOOL VSHasAnyActivePopup(id editorVC) {
    for (id popup in VSCollectAllVisiblePopups(editorVC)) {
        if (VSPopupIsLayerActionMenu(popup)) continue;
        if (VSPopupWasHandled(popup) && [popup isKindOfClass:[UIView class]] && ((UIView *)popup).alpha < 0.05) continue;
        return YES;
    }
    return NO;
}

static BOOL VSPurchasePopupVisible(id editorVC) {
    for (id popup in VSCollectAllVisiblePopups(editorVC)) {
        if (VSPopupIsLayerActionMenu(popup)) continue;
        if (VSCheckIfPopupIsPurchasePrompt(popup)) return YES;
    }
    return NO;
}

// ============================================================================
// LỚP: NHẬN DIỆN, CHỮ KÝ, SAO CHÉP
// ============================================================================

static BOOL VSLayerAssetLoaded(id engine, NSUInteger n) {
    SEL s = @selector(assetHasBeenLoadedForLayer:);
    if (!engine || ![engine respondsToSelector:s]) return YES;
    @try { return ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(engine, s, n); }
    @catch (NSException *__unused e) { return YES; }
}

static BOOL VSLayerFlag(id engine, SEL sel, NSUInteger n) {
    if (!engine || ![engine respondsToSelector:sel]) return NO;
    @try { return ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(engine, sel, n); }
    @catch (NSException *__unused e) { return NO; }
}

static NSString *VSLayerSignature(id engine, NSUInteger n) {
    if (!engine) return nil;
    __block NSString *sig = nil;
    VSTry(^{
        if (![engine respondsToSelector:@selector(layerAtLayerNum:)]) return;
        id layer = [engine layerAtLayerNum:n];
        if (!layer) return;
        id generator = VSSafeValueForKey(layer, @"imageGenerator");
        id asset = VSSafeValueForKey(generator, @"asset");
        NSString *assetKey = @"";
        if ([asset isKindOfClass:[AVURLAsset class]]) assetKey = ((AVURLAsset *)asset).URL.absoluteString ?: @"";
        id tex = VSSafeValueForKey(generator, @"layerImageTextureID");
        NSString *texKey = [tex isKindOfClass:[NSNumber class]] ? [tex description] : @"";
        NSString *infoKey = VSCheapDescription(VSSafeValueForKey(layer, @"origAssetInfo"));
        sig = [NSString stringWithFormat:@"%@|%@|%@", assetKey, texKey, infoKey];
    });
    return sig;
}

static NSArray<NSNumber *> *VSDetectFillableLayers(id engine, BOOL includeEmpty) {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    if (!engine) return out;
    for (NSUInteger i = 0; i < VS_MAX_LAYERS; i++) {
        __block BOOL fillable = NO;
        VSTry(^{
            if (!includeEmpty && !VSLayerAssetLoaded(engine, i)) return;
            NSInteger type = [engine respondsToSelector:@selector(layerTypeForLayer:)] ? [engine layerTypeForLayer:i] : 0;
            if (type != 1 && type != 4) return;
            if (VSLayerFlag(engine, @selector(isNullLayer:), i)) return;
            if (VSLayerFlag(engine, @selector(particlesExistOnLayerNum:), i)) return;
            if (VSLayerFlag(engine, @selector(drawingExistsOnLayerNum:), i)) return;
            if (VSLayerFlag(engine, @selector(gifExistsOnLayerNum:), i)) return;
            if (VSLayerFlag(engine, @selector(overlayObjectExistsOnLayerNum:), i)) return;
            if (VSLayerFlag(engine, @selector(zapsObjectExistsOnLayerNum:), i)) return;
            id layer = [engine layerAtLayerNum:i];
            if (!layer) return;
            if (VSValueIsTruthy(VSSafeValueForKey(layer, @"is3DLayer"))) return;
            if (VSValueIsTruthy(VSSafeValueForKey(layer, @"textDictionary"))) return;
            fillable = YES;
        });
        if (fillable) [out addObject:@(i)];
    }
    return out;
}

static BOOL VSFireCopyLayer(id editor, id engine, NSUInteger src) {
    SEL s = NSSelectorFromString(@"copyLayer:");
    id receiver = nil;
    if ([editor respondsToSelector:s]) receiver = editor;
    else if ([engine respondsToSelector:s]) receiver = engine;
    if (!receiver) return NO;
    @try {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(receiver, s, src);
        return YES;
    } @catch (NSException *__unused e) { return NO; }
}

// ============================================================================
// QR STORAGE
// ============================================================================

static NSString *VSGetLastQRCodeStoragePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"VideoStarTool_CachedLastQR.png"];
}

static void VSPersistQRCodeImageData(id rawData) {
    if (!rawData) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @autoreleasepool {
            UIImage *image = nil;
            if ([rawData isKindOfClass:[NSData class]]) image = [UIImage imageWithData:(NSData *)rawData];
            else if ([rawData isKindOfClass:[UIImage class]]) image = (UIImage *)rawData;
            if (!image) return;
            NSData *png = UIImagePNGRepresentation(VSDownscaledImage(image, 1024.0));
            if (png.length) [png writeToFile:VSGetLastQRCodeStoragePath() atomically:YES];
        }
    });
}

static UIImage *VSReadLastPersistedQRCodeImage(void) {
    NSData *data = [NSData dataWithContentsOfFile:VSGetLastQRCodeStoragePath()];
    return data.length ? [UIImage imageWithData:data] : nil;
}

static NSString *VSDecodeQRCodeMessageFromImage(UIImage *image) {
    if (!image) return nil;
    @autoreleasepool {
        CIImage *ci = image.CGImage ? [CIImage imageWithCGImage:image.CGImage] : nil;
        if (!ci) ci = [[CIImage alloc] initWithImage:image];
        if (!ci) return nil;
        CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil
                                                  options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
        for (CIFeature *f in [detector featuresInImage:ci])
            if ([f isKindOfClass:[CIQRCodeFeature class]] && ((CIQRCodeFeature *)f).messageString.length)
                return ((CIQRCodeFeature *)f).messageString;
        return nil;
    }
}

// ============================================================================
// HOOKS (bao gồm ẩn thanh trạng thái & chặn đóng editor khi nhập ngầm)
// ============================================================================

static IMP g_origSelectedCodeWithImageData = NULL;
static IMP g_origImportNewPreset = NULL;
static IMP g_origImportOldPreset = NULL;
static IMP g_origCustomPopupDidMove = NULL;
static IMP g_origShowLayerActionMenu = NULL;
static IMP g_origShowImportConfirmation = NULL;
static IMP g_origConfirmOverwrite1 = NULL;
static IMP g_origConfirmOverwrite2 = NULL;
static IMP g_origEditorMemWarn = NULL;
static IMP g_origNavMemWarn = NULL;
static IMP g_origPickedResponse = NULL;
static IMP g_origDismissVC = NULL;
static IMP g_origPrefersStatusBarHidden = NULL;
static IMP g_origChildForStatusBarHidden = NULL;
static IMP g_origVCViewWillAppear = NULL;
static IMP g_origAppStatusBarHidden = NULL;
static IMP g_origAppSetStatusBarHidden = NULL;
static IMP g_origAppSetStatusBarHiddenAnim = NULL;

static NSUInteger g_presetImportEventCounter = 0;

static BOOL VSRobustSwizzleMethod(NSString *className, SEL selector, id blockImpl, IMP *origImp) {
    Class cls = NSClassFromString(className);
    if (!cls) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    if (*origImp != NULL) return YES;
    IMP newImp = imp_implementationWithBlock(blockImpl);
    if (class_addMethod(cls, selector, newImp, method_getTypeEncoding(method))) {
        *origImp = method_getImplementation(method);
    } else {
        *origImp = method_setImplementation(method, newImp);
    }
    return YES;
}

static void VSForceStatusBarHiddenOnClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL sel = @selector(prefersStatusBarHidden);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP alwaysYes = imp_implementationWithBlock(^BOOL(id __unused selfObj) { return YES; });
    class_replaceMethod(cls, sel, alwaysYes, method_getTypeEncoding(m));
}

static void VSNotifyLayerAdded(id sender) {
    void (^handler)(id) = g_onLayerAddedHandler;
    if (!handler) return;
    VSGuard(^{ handler(sender); });
}

static void VSInstallCoreHooksOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_activePopupsTable = [NSHashTable weakObjectsHashTable];

        // Ẩn thanh trạng thái (giờ, Wi-Fi, sóng, pin) hoàn toàn trong app
        VSRobustSwizzleMethod(@"UIViewController", @selector(prefersStatusBarHidden), ^BOOL(id __unused selfVC) {
            return YES;
        }, &g_origPrefersStatusBarHidden);

        VSRobustSwizzleMethod(@"UIViewController", @selector(childViewControllerForStatusBarHidden), ^UIViewController *(id __unused selfVC) {
            return nil;
        }, &g_origChildForStatusBarHidden);

        VSRobustSwizzleMethod(@"UIViewController", @selector(viewWillAppear:), ^(UIViewController *selfVC, BOOL animated) {
            if (g_origVCViewWillAppear)
                ((void (*)(id, SEL, BOOL))g_origVCViewWillAppear)(selfVC, @selector(viewWillAppear:), animated);
            [selfVC setNeedsStatusBarAppearanceUpdate];
        }, &g_origVCViewWillAppear);

        for (NSString *vcClass in @[@"UINavigationController", @"UITabBarController",
                                    @"VideoReviewEditVC", @"MultiLayerWizEffectVC", @"MultiLayerNavController"]) {
            VSForceStatusBarHiddenOnClass(vcClass);
        }

        VSRobustSwizzleMethod(@"UIApplication", @selector(isStatusBarHidden), ^BOOL(id __unused selfApp) {
            return YES;
        }, &g_origAppStatusBarHidden);

        VSRobustSwizzleMethod(@"UIApplication", @selector(setStatusBarHidden:), ^(id selfApp, BOOL __unused hidden) {
            if (g_origAppSetStatusBarHidden)
                ((void (*)(id, SEL, BOOL))g_origAppSetStatusBarHidden)(selfApp, @selector(setStatusBarHidden:), YES);
        }, &g_origAppSetStatusBarHidden);

        VSRobustSwizzleMethod(@"UIApplication", @selector(setStatusBarHidden:withAnimation:), ^(id selfApp, BOOL __unused hidden, UIStatusBarAnimation anim) {
            if (g_origAppSetStatusBarHiddenAnim)
                ((void (*)(id, SEL, BOOL, UIStatusBarAnimation))g_origAppSetStatusBarHiddenAnim)(selfApp, @selector(setStatusBarHidden:withAnimation:), YES, anim);
        }, &g_origAppSetStatusBarHiddenAnim);

        // Chặn editor tự đóng khi gọi thẳng pickedWithClipPickerResponse: mà không mở picker
        VSRobustSwizzleMethod(@"UIViewController", @selector(dismissViewControllerAnimated:completion:), ^(UIViewController *selfVC, BOOL flag, void (^completion)(void)) {
            if (g_silentMediaReplay && selfVC.presentedViewController == nil &&
                (VSSafeIsClass(selfVC, @"MultiLayerWizEffectVC") || VSSafeIsClass(selfVC, @"MultiLayerNavController"))) {
                if (completion) completion();
                return;
            }
            if (g_origDismissVC)
                ((void (*)(id, SEL, BOOL, void (^)(void)))g_origDismissVC)(selfVC, @selector(dismissViewControllerAnimated:completion:), flag, completion);
        }, &g_origDismissVC);

        VSRobustSwizzleMethod(@"QRCodeManager", @selector(selectedCode:withImageData:), ^(id selfInstance, id code, id imageData) {
            VSPersistQRCodeImageData(imageData);
            if (g_origSelectedCodeWithImageData)
                ((void (*)(id, SEL, id, id))g_origSelectedCodeWithImageData)(selfInstance, @selector(selectedCode:withImageData:), code, imageData);
        }, &g_origSelectedCodeWithImageData);

        // Lưu lại lựa chọn ảnh của đoạn đầu để các đoạn sau nhập ngầm, không mở lại bảng chọn
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(pickedWithClipPickerResponse:), ^(id selfInstance, id response) {
            if (g_captureMediaResponse && response) g_cachedPickResponse = response;
            if (g_origPickedResponse)
                ((void (*)(id, SEL, id))g_origPickedResponse)(selfInstance, @selector(pickedWithClipPickerResponse:), response);
        }, &g_origPickedResponse);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), ^(id selfInstance, id preset, id action, NSInteger frames) {
            if (g_origImportNewPreset)
                ((void (*)(id, SEL, id, id, NSInteger))g_origImportNewPreset)(selfInstance, @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), preset, action, frames);
            g_presetImportEventCounter++;
        }, &g_origImportNewPreset);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(importOldPreset:), ^(id selfInstance, id preset) {
            if (g_origImportOldPreset)
                ((void (*)(id, SEL, id))g_origImportOldPreset)(selfInstance, @selector(importOldPreset:), preset);
            g_presetImportEventCounter++;
        }, &g_origImportOldPreset);

        VSRobustSwizzleMethod(@"CustomPopup", @selector(didMoveToWindow), ^(id selfInstance) {
            if (g_origCustomPopupDidMove)
                ((void (*)(id, SEL))g_origCustomPopupDidMove)(selfInstance, @selector(didMoveToWindow));
            if (![selfInstance isKindOfClass:[UIView class]] || !((UIView *)selfInstance).window) return;
            [g_activePopupsTable addObject:selfInstance];
            if (g_autoConfirmPopups || g_vsaAutomating) {
                VSDispatchAfterMS(0, ^{
                    if (VSResolvePopupsImmediately(nil) == VSPopupActionStatusNone) {
                        VSDispatchAfterMS(40, ^{ VSResolvePopupsImmediately(nil); });
                    }
                });
            }
        }, &g_origCustomPopupDidMove);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(showLayerActionMenu:newLayer:), ^(id selfInstance, NSUInteger layerNum, BOOL isNewLayer) {
            if (g_suppressLayerActionMenu) return;
            if (g_origShowLayerActionMenu)
                ((void (*)(id, SEL, NSUInteger, BOOL))g_origShowLayerActionMenu)(selfInstance, @selector(showLayerActionMenu:newLayer:), layerNum, isNewLayer);
        }, &g_origShowLayerActionMenu);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(showImportConfirmation), ^BOOL(id selfInstance) {
            if (g_vsaAutomating || g_autoConfirmPopups) return NO;
            if (g_origShowImportConfirmation)
                return ((BOOL (*)(id, SEL))g_origShowImportConfirmation)(selfInstance, @selector(showImportConfirmation));
            return NO;
        }, &g_origShowImportConfirmation);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:), ^(id selfInstance, id object, BOOL showMenu) {
            if (g_vsaAutomating && [selfInstance respondsToSelector:@selector(overwrite:isAbleToShowTheLayerActionMenu:)]) {
                [selfInstance overwrite:object isAbleToShowTheLayerActionMenu:NO];
                return;
            }
            if (g_origConfirmOverwrite1)
                ((void (*)(id, SEL, id, BOOL))g_origConfirmOverwrite1)(selfInstance, @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:), object, showMenu);
        }, &g_origConfirmOverwrite1);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:removeOverlayBlending:), ^(id selfInstance, id object, BOOL showMenu, BOOL removeOverlay) {
            if (g_vsaAutomating && [selfInstance respondsToSelector:@selector(overwrite:isAbleToShowTheLayerActionMenu:removeOverlayBlending:)]) {
                [selfInstance overwrite:object isAbleToShowTheLayerActionMenu:NO removeOverlayBlending:removeOverlay];
                return;
            }
            if (g_origConfirmOverwrite2)
                ((void (*)(id, SEL, id, BOOL, BOOL))g_origConfirmOverwrite2)(selfInstance, @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:removeOverlayBlending:), object, showMenu, removeOverlay);
        }, &g_origConfirmOverwrite2);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:), ^(id selfInstance, SEL makeSel, id o1, id o2, id o3, BOOL able) {
            if (g_origConfirmAdd5)
                ((void (*)(id, SEL, SEL, id, id, id, BOOL))g_origConfirmAdd5)(selfInstance, @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:), makeSel, o1, o2, o3, able);
            VSNotifyLayerAdded(selfInstance);
        }, &g_origConfirmAdd5);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmAddingLayer:object:object2:object3:), ^(id selfInstance, SEL makeSel, id o1, id o2, id o3) {
            if (g_origConfirmAdd4)
                ((void (*)(id, SEL, SEL, id, id, id))g_origConfirmAdd4)(selfInstance, @selector(confirmAddingLayer:object:object2:object3:), makeSel, o1, o2, o3);
            VSNotifyLayerAdded(selfInstance);
        }, &g_origConfirmAdd4);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(didReceiveMemoryWarning), ^(id selfInstance) {
            g_memoryWarningAt = CFAbsoluteTimeGetCurrent();
            if (g_origEditorMemWarn) ((void (*)(id, SEL))g_origEditorMemWarn)(selfInstance, @selector(didReceiveMemoryWarning));
        }, &g_origEditorMemWarn);

        VSRobustSwizzleMethod(@"MultiLayerNavController", @selector(didReceiveMemoryWarning), ^(id selfInstance) {
            g_memoryWarningAt = CFAbsoluteTimeGetCurrent();
            if (g_origNavMemWarn) ((void (*)(id, SEL))g_origNavMemWarn)(selfInstance, @selector(didReceiveMemoryWarning));
        }, &g_origNavMemWarn);

        VSRefreshStatusBarHiddenEverywhere();
    });
}

// ============================================================================
// BẢNG MÀU TÍM ĐẬM + HỒNG PASTEL & ICON NÚT NỔI HELLO KITTY (ĐÃ XOÁ NỀN)
// ============================================================================

static inline UIColor *VSToolPinkAccent(void) {
    return [UIColor colorWithRed:1.000 green:0.624 blue:0.792 alpha:1.0]; // #FF9FCA
}

static inline UIColor *VSToolCardTopColor(void) {
    return [UIColor colorWithRed:0.165 green:0.094 blue:0.235 alpha:0.98]; // #2A183C
}

static inline UIColor *VSToolCardBottomColor(void) {
    return [UIColor colorWithRed:0.094 green:0.051 blue:0.141 alpha:0.98]; // #180D24
}

static inline UIColor *VSToolCardBackgroundColor(void) {
    return [UIColor colorWithRed:0.133 green:0.075 blue:0.196 alpha:0.96];
}

static inline UIColor *VSToolSubtitleColor(void) {
    return [UIColor colorWithRed:0.86 green:0.80 blue:0.90 alpha:0.80];
}

static inline UIColor *VSToolPillTextColor(void) {
    return [UIColor colorWithRed:0.094 green:0.051 blue:0.141 alpha:1.0];
}

static UIImage *VSFloatingButtonIconImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *b64 =
            @"iVBORw0KGgoAAAANSUhEUgAAAHgAAAB4CAMAAAAOusbgAAAA/1BMVEVfWVthXl9gWlsxLy9hU1ijeIiyhZXPlqr6+vyinp9wJyc9PkA+QUBmMGZEOjyTb2+GYG07MzVBQD6hXaGRjo4rKyw+QD6BeXr/AAD/AP9BPT6De33g3+A8NTg2Nkg/Tz8A/wAA//9xjY2q////f/8AAAD+/v5JRkfsm7g7OztYVVZ+fn5qZmhFPUHo6OhVVVTrorzHx8d3d3fY2NiHh4fSl62YmJioqKjvpsFPSEqLZ3W3uLhwWWJnVVtBPD5SSUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAASyMhKAAAAQHRSTlNfIqAc6P///wEUCv78EVEQ/138BG7//FoBAYa1/4sOEAEBCQMCAP/9//z8A/3+/wb///7////////P///9/P2vMmNGnAAACGxJREFUeNrtWteS6zYSBUgqTbz52uuw9q4pDAEwJwWG//+r7QZJiZI4IqSZa9dWqV9mShJ50Ol0NwBi/0NCbsA34BvwDfgGfAO+Ad+A3yLCB/kHgEXzxxd/LzDACXp3RxcAffiF8MWZxbyDxoRzxsqaLDrdbXH3wzVe2MRijXALoJWm6huTEPJE6MXAZvvHPOu5O5swVrnMspgL0Aa9U89RaqzXXC3H+Le4CFj04MUZ/yKuNZml6WzCqoobiEoMzvZiXKgxqdcg1kdCBp0mBHxEwb3MLdPg5eUlCGYWKE2IwRDWcb4xztUCyPDKB4Hpwtgv2TJUbO4Ch1LT7H5Ys6rBBVnNWm87DuNRto09zwsB2hDawGBB/ok56h2Oq8LGRH+CnqbfcQbAm7i8WYsLyBNXPcKTbbxsZfuqygPAc3uBa4/CMMwTCW+qGFsb3Q+/Q7R+rC0LPcGYO9nhgrk38Msi95Y9iRwA/llT4wW4jmXNg16YSaU8hCwlgMf6keN+eOlLWjInWx5I7rBaP7gkJEhv3WGioPeQroOC/02DPnAwYZ/4gcLLGKxFh2w9BAw5wrYHj3fQCo5zKaMoAUuwvcIBCKh88uRSOpzoAfu2wRy5PJIwYipY820M4ao+shw2XXW4s8lmkgarjeskhw8m2sC2bzEnX55ImG0PrAgBW6YtLtCHW7nAJBuX8cOfZQ43tYB9m4Ivw+WoZK67WXXh7GImuW7ZsHYSHqzPmM+1gE141BsHhkRpQyuYMdeaphMVdyAQCImHCZFnSRKxKpr7msAPUgNYVh15IHNMVoECLjabDbCAI7OIIwVgTBaaBGIOxNapeNy1WhevNo6VBlPQdjNT6TxpiNNFB6AP1pSOAwsM6mgcOOZOuQOuIL4Ll22CzgQNy6P6H5AFC2p/HgOe2wa/EBiVLSbMKWcHtD1NIbtXQTopXdD553EfEzD1uI896bB0R9IqqHu8nbL7ovt2lULBpFo+ZvKiqAacDZp21mNtec+6evmymrqs9uda6RRr5PED+HTHmGDtLtY6GxS7ijkrHH5M2MPAQLij0CH8bLLqmbMPPCvuIZ47iwQbpC8d5vomI5aNISeQox+An1cQQFN50BOoarGnVABmo8DQZtSqECU64dUwRtEUy53+mE+VnOw+CaSGxiqRmZab48jZkyQQvNWFU5BCuzudlU5D5kEKqTbqY7Q2vK7KlhrslWNnBKgyCz1YRZGuGocXDApIyqpG49WkgjbkbrwRmHMwlEZCqRDLszwPPcUoLiunafqSTrFIbaZF1SZYWmDj9ee4qbEDCZcXS8ihJS2LooR4dt2qqlpGwerBNQhEmGuNyBq0fILdmKpRk01RbKadw11GTirjIGUyFi+vkjCRmFfga3DuatUaumIwE4jxIlFrVafXtPamwLj7hA5m0n2AAUqMmXqu5qHt8g0CNL1rAlsWN+z5qI8XhlZxGuXSZpKbQpUGr9d0VGP7+XQauFRyKJKbNA1mU6VuplrrxRgwvS6XDgvXJyTqApn0nufQ4UJUjzQCqvF5m6WVzhyz6h6snMTY4bpyMWrqf12ZxEc0nuBUzqOw6ZIYuxsDNuvBMeKKvIIp1+vKGBtrfYT9CCN5uHxngfpxksknGrOKx+8NDC2DIZTMzwC/Q2ydRLmz2/x57LiTXDVGXK5xTSl9XiwWr2ismuroXUHjME9wK4GDlFKSbrOP9Leu/Gf7l/cFjtXo1ts14YXVhFkL3O0czpE/fn0/4FztXTTbZa2caExQDI77WjJKDjeNltfGm5fn2zBOBrZ+SFsLjWYfqWq31ZyvfYOHUiaa0F4io/BUb/bbILCw140DSonoMooimffrnKPt+QSbzvj1dDqOahMFIp4ONXqJig4tWgnVLJANEMgoc61PdqqWamJwtnrBhD+NhijTPwv8iNUpO950UG/LNTnqFNgD/z1iqRcj9fj4OakCINTWmPXr6jZJ8HnDfP6vbf8kXgceaG7Rx5pEqqxz4JXka0Mga24Q8rrG/iMMqSe2BifzcKDibsOTJMuPFFbzVcdarP64azfJ4YQKXWaBnYOUMj6A8AZ6jMpxeHb8RbwNT7ZpoAGDN/L1GmLscQBYqJOMdpdWxqPD8YdN4Wr0SVu1c3ymAxE2NdpDG5bFo1FUzgLomzWCTiJhnmnoIa5wvFyvtdgiU0N3MBvP71AdS/ivA/s2ffpIqPkZOOR+1IBbh01n0LKPawzssdY8GjjdoR8k5aqUIz6OsyzP2AMobJ4HFndNglswAMSqezinc4RV9iyfZV+bowvbPmfqHv4jGFuGeTTiQC/+daz/aBPYeLaf/XHgR2VsjZzSGFmbMxRukWOlhw68hDodYMenC1cIHrSxmvHKZTUZ0/gzsEjbF8Rvxn1g7Kljpdo/C/wHtEF4JKyw3zYoZ/iKpwbGUPsC4kxZFPiT8onaeArsRNfPUc2+3xOC/aTOhWtyBthW+4nYggofIwwG3OugvZw3+pqvXJk4zOO/FnXFLIBV9zpocyAcXRFj26YW9qgSBuTnV4Ehj8rS+L09pfYxytDeDzy5CFttcWL2msrIekf19PthY9BmNJNJrmfzGEalB/SuRcSZ6wUD6dTfNACjU8NCbz2oA/g8jL3zA1o3K61xOBMX3APxP9vHPQk1dzcOHBxvoiTbhmGMp6qNwL94mhdJztpjZYLXCPw3XkBRy6akZh14+3KcO6FDku3lh+5zaKzOXDu58OaLD2/6D/CPYRW8u/ngfHP2ggylFiMNo73I8E5XbvxGCUpt8otR12suS96TUq7r2iA2Vealvv1uwMfy5ct30pMvXxY//D6XL6BdGAhX6gv/hwK3MEJQfy9CiB+u8e2y4A34BnwDvgHfgG/AN+D/X+D/AYJSM1O/FLVvAAAAAElFTkSuQmCC";
        NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        if (data.length) img = [UIImage imageWithData:data scale:3.0];
    });
    return img;
}

static CAGradientLayer *VSMakePlumGradient(CGRect frame, CGFloat corner) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = frame;
    g.cornerRadius = corner;
    g.masksToBounds = YES;
    g.colors = @[(id)VSToolCardTopColor().CGColor, (id)VSToolCardBottomColor().CGColor];
    g.startPoint = CGPointMake(0.5, 0.0);
    g.endPoint = CGPointMake(0.5, 1.0);
    return g;
}

static UIButton *VSToolCreatePillButton(NSString *title, CGRect frame, BOOL primary) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.layer.cornerRadius = frame.size.height / 2.0;
    [btn setTitle:title forState:UIControlStateNormal];
    if (primary) {
        btn.backgroundColor = VSToolPinkAccent();
        [btn setTitleColor:VSToolPillTextColor() forState:UIControlStateNormal];
        [btn setTitleColor:[VSToolPillTextColor() colorWithAlphaComponent:0.45] forState:UIControlStateDisabled];
        btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        btn.layer.shadowColor = VSToolPinkAccent().CGColor;
        btn.layer.shadowOpacity = 0.48;
        btn.layer.shadowRadius = 12.0;
        btn.layer.shadowOffset = CGSizeMake(0, 2);
    } else {
        btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        btn.layer.borderWidth = 1.0;
        btn.layer.borderColor = [VSToolPinkAccent() colorWithAlphaComponent:0.32].CGColor;
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.4] forState:UIControlStateDisabled];
        btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    }
    return btn;
}

// ============================================================================
// UI: WINDOW, PREVIEW QR, PROXY QR, CUSTOM ALERT
// ============================================================================

@interface VSToolPassThroughWindow : UIWindow
@end
@implementation VSToolPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

@interface VSToolQRCodePreviewVC : UIViewController
@property (nonatomic, strong) UIImage *qrImage;
@end
@implementation VSToolQRCodePreviewVC
- (BOOL)prefersStatusBarHidden { return YES; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = VSToolCardBottomColor();
    UIImageView *iv = [[UIImageView alloc] initWithImage:self.qrImage];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 18; iv.clipsToBounds = YES;
    iv.frame = CGRectInset(self.view.bounds, 24, 110);
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:iv];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 56, self.view.bounds.size.width, 32)];
    title.text = @"Code gần nhất đã nhập";
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:19];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:title];
    CGFloat w = (self.view.bounds.size.width - 60) / 2.0;
    UIButton *closeBtn = VSToolCreatePillButton(@"ĐÓNG", CGRectMake(24, self.view.bounds.size.height - 86, w, 46), NO);
    closeBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    closeBtn.tag = 0;
    [closeBtn addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:closeBtn];

    UIButton *shareBtn = VSToolCreatePillButton(@"CHIA SẺ / LƯU", CGRectMake(24 + w + 12, self.view.bounds.size.height - 86, w, 46), YES);
    shareBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    shareBtn.tag = 1;
    [shareBtn addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:shareBtn];
}
- (void)tapped:(UIButton *)button {
    if (button.tag == 0) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    if (!self.qrImage) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[self.qrImage] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = button;
    [self presentViewController:avc animated:YES completion:nil];
}
@end

@interface VSToolQRCodeCaptureProxy : NSObject
@property (nonatomic, copy) void (^onCodeCapturedBlock)(id presetData, id codeIdentifier);
@end
@implementation VSToolQRCodeCaptureProxy
- (NSString *)qrLabel { return VSLocalizedString(@"Multi-Layer"); }
- (NSString *)qrSetupLabel { return @""; }
- (NSString *)codePrefix { return @"n"; }
- (BOOL)validCode:(NSString *)code { return [code isKindOfClass:[NSString class]] && ([code hasPrefix:@"m"] || [code hasPrefix:@"n"]); }
- (void)importedData:(id)data code:(id)code {
    void (^block)(id, id) = self.onCodeCapturedBlock;
    if (block) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { VSGuard(^{ block(data, code); }); } });
}
- (id)dataToShare { return nil; }
- (void)setActivityiPadPopup:(id)popup {}
- (id)qrImage { return nil; }
- (id)qrIcon { return nil; }

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *s = [super methodSignatureForSelector:sel];
    return s ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    NSUInteger len = invocation.methodSignature.methodReturnLength;
    if (len == 0) return;
    void *zero = calloc(1, len);
    [invocation setReturnValue:zero];
    free(zero);
}
@end

// Thông báo kiểu nền tím đậm + vòng tròn icon hồng phát sáng + nút pill XONG
@interface VSToolAlertView : UIView
- (instancetype)initWithFrame:(CGRect)frame title:(NSString *)title message:(NSString *)message iconText:(NSString *)iconText buttonTitle:(NSString *)buttonTitle;
- (void)showAnimated;
- (void)dismissAnimated;
@end

@implementation VSToolAlertView {
    UIView *_card;
}

- (instancetype)initWithFrame:(CGRect)frame title:(NSString *)title message:(NSString *)message iconText:(NSString *)iconText buttonTitle:(NSString *)buttonTitle {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithRed:0.06 green:0.03 blue:0.10 alpha:0.56];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    CGFloat W = frame.size.width;
    CGFloat cardW = MIN(W - 44.0, 340.0);
    CGFloat pad = 22.0;
    CGFloat cw = cardW - pad * 2.0;

    _card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, 200)];
    _card.layer.cornerRadius = 26.0;
    _card.layer.borderWidth = 1.0;
    _card.layer.borderColor = [VSToolPinkAccent() colorWithAlphaComponent:0.25].CGColor;
    _card.layer.shadowColor = UIColor.blackColor.CGColor;
    _card.layer.shadowOpacity = 0.65;
    _card.layer.shadowRadius = 26.0;
    _card.layer.shadowOffset = CGSizeMake(0, 14);
    _card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                             UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self addSubview:_card];

    CGFloat y = 26.0;
    CGFloat badgeSize = 58.0;
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake((cardW - badgeSize) / 2.0, y, badgeSize, badgeSize)];
    badge.backgroundColor = VSToolPinkAccent();
    badge.layer.cornerRadius = badgeSize / 2.0;
    badge.layer.shadowColor = VSToolPinkAccent().CGColor;
    badge.layer.shadowOpacity = 0.55;
    badge.layer.shadowRadius = 14.0;
    badge.layer.shadowOffset = CGSizeZero;
    UILabel *iconLbl = [[UILabel alloc] initWithFrame:badge.bounds];
    iconLbl.text = iconText.length ? iconText : @"!";
    iconLbl.textColor = VSToolPillTextColor();
    iconLbl.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    iconLbl.textAlignment = NSTextAlignmentCenter;
    [badge addSubview:iconLbl];
    [_card addSubview:badge];
    y += badgeSize + 18.0;

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, cw, 28)];
    titleLbl.text = title ?: @"VideoStarTool";
    titleLbl.textColor = UIColor.whiteColor;
    titleLbl.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    titleLbl.numberOfLines = 2;
    CGSize tSize = [titleLbl sizeThatFits:CGSizeMake(cw, 60)];
    titleLbl.frame = CGRectMake(pad, y, cw, ceil(tSize.height));
    [_card addSubview:titleLbl];
    y += titleLbl.frame.size.height + 12.0;

    if (message.length) {
        UILabel *msgLbl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, cw, 20)];
        msgLbl.text = message;
        msgLbl.textColor = VSToolSubtitleColor();
        msgLbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
        msgLbl.textAlignment = NSTextAlignmentCenter;
        msgLbl.numberOfLines = 0;
        CGSize mSize = [msgLbl sizeThatFits:CGSizeMake(cw, 220)];
        msgLbl.frame = CGRectMake(pad, y, cw, ceil(mSize.height));
        [_card addSubview:msgLbl];
        y += msgLbl.frame.size.height + 24.0;
    } else {
        y += 14.0;
    }

    UIButton *okBtn = VSToolCreatePillButton(buttonTitle ?: @"XONG", CGRectMake(pad, y, cw, 48.0), YES);
    [okBtn addTarget:self action:@selector(dismissAnimated) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:okBtn];
    y += 48.0 + 22.0;

    _card.frame = CGRectMake(0, 0, cardW, y);
    _card.center = CGPointMake(W / 2.0, frame.size.height / 2.0);
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:26.0].CGPath;
    [_card.layer insertSublayer:VSMakePlumGradient(_card.bounds, 26.0) atIndex:0];
    return self;
}

- (void)showAnimated {
    self.alpha = 0.0;
    _card.transform = CGAffineTransformMakeScale(0.90, 0.90);
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.alpha = 1.0;
        self->_card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)dismissAnimated {
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.alpha = 0.0;
        self->_card.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(BOOL __unused finished) {
        [self removeFromSuperview];
    }];
}

@end

// ============================================================================
// VSTOOL INTERFACE
// ============================================================================

@interface VSToolRootVC : UIViewController
@end

@interface VSTool : NSObject
@property (nonatomic, strong) VSToolPassThroughWindow *window;
@property (nonatomic, strong) UIButton *floatingMenuButton;
@property (nonatomic, strong) UIView *menuView;
@property (nonatomic, strong) VSToolAlertView *activeAlertView;
@property (nonatomic, strong) UILabel *statusHUDLabel;
@property (nonatomic, strong) UIView *bottomActionBar;
@property (nonatomic, strong) VSToolQRCodeCaptureProxy *qrCaptureProxy;
@property (nonatomic, strong) NSMutableArray *multiScenePresets;
@property (nonatomic, strong) NSMutableArray *multiSceneCodes;
@property (nonatomic, assign) NSUInteger multiSceneStart;
@property (nonatomic, assign) NSUInteger multiSceneCount;
@property (nonatomic, assign) NSUInteger multiSceneOriginalLastViewed;
@property (nonatomic, assign) NSUInteger multiSceneRunId;
@property (nonatomic, assign) NSInteger multiSceneActiveCapturingIndex;
@property (nonatomic, strong) UIView *multiSceneCardView;
@property (nonatomic, copy)   NSString *currentTaskName;
@property (nonatomic, strong) id savedOriginalQRDelegate;
@property (nonatomic, assign) BOOL savedOriginalQRDelegateValid;
@property (nonatomic, copy)   void (^bottomBarConfirmBlock)(void);
@property (nonatomic, copy)   void (^bottomBarCancelBlock)(void);

+ (instancetype)shared;
- (void)setupToolInterfaceIfNeeded;
- (void)setupFloatingMenuButton;
- (void)handleFloatingButtonTap:(UIButton *)sender;
- (void)handleFloatingButtonPan:(UIPanGestureRecognizer *)pan;
- (void)restoreOriginalQRCodeDelegate;
- (void)terminateCurrentTaskQuietly;
- (void)toggleMenu;
- (void)showMenu;
- (void)hideMenuWithCompletion:(void (^)(void))completion;
- (void)runMenuFeature:(NSInteger)index;
- (void)stopCurrentTaskFromMenu;
- (void)presentFromTop:(UIViewController *)controller;
- (void)presentController:(UIViewController *)controller retry:(BOOL)retry;
- (UIViewController *)topPresenterVC;
- (void)updateStatusHUD:(NSString *)message;
- (void)showNotificationAlert:(NSString *)message title:(NSString *)title;
- (void)dismissBottomActionBar;
- (UIView *)buildCardContainerWithFrame:(CGRect)frame title:(NSString *)title subtitle:(NSString *)subtitle;
- (void)displayBottomActionBarWithTitle:(NSString *)title message:(NSString *)msg confirmTitle:(NSString *)confirmTitle onConfirm:(void (^)(void))onConfirm onCancel:(void (^)(void))onCancel;
- (void)handleBottomBarConfirm;
- (void)handleBottomBarCancel;
- (NSUInteger)startNewTaskWithDescription:(NSString *)taskName initialStatus:(NSString *)initialStatus;
- (void)finalizeTaskWithMessage:(NSString *)msg;
- (void)showRunResultAlert:(NSString *)msg title:(NSString *)title;
- (void)executeFeature1ReplaceLayers;
- (void)executeFeature2DisplayLastCode;
- (void)executeFeature3AutoSplitBeat;
- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)splitView runId:(NSUInteger)runId;
- (void)executeFeature4BatchMultiScene;
- (void)parseMergeRangeThenPickCodes:(id)reviewVC runId:(NSUInteger)runId originalLastViewed:(NSUInteger)originalLastViewed;
- (void)presentQRPicker;
- (void)handleMultiSceneCancel;
- (void)beginBatchProcessing;
- (void)showProcessingProgressPanel;
- (void)openMultiLayerEditorForScene:(NSUInteger)sceneIndex reviewVC:(id)reviewVC runId:(NSUInteger)runId completion:(void (^)(id editorVC))done;
- (void)importPresetPayload:(id)preset codeIdentifier:(id)code intoEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
- (void)waitForEditorSettledThenCreate:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
- (void)triggerCreateInEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
@end

// ============================================================================
// MENU (mở / đóng bằng NÚT NỔI HELLO KITTY — phong cách Tím Đậm + Hồng Pastel)
// ============================================================================

static const CGFloat kVSMenuCorner = 26.0;
static const NSInteger kVSMenuTagStop = 100;
static const NSInteger kVSMenuTagClose = 102;

static NSAttributedString *VSLetterSpaced(NSString *text, CGFloat kern, UIColor *color, UIFont *font) {
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSKernAttributeName: @(kern),
        NSForegroundColorAttributeName: color,
        NSFontAttributeName: font
    }];
}

static UILabel *VSMenuMakeLabel(CGRect frame, NSString *text, UIFont *font, UIColor *color, NSTextAlignment align) {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.textAlignment = align;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.75;
    l.userInteractionEnabled = NO;
    return l;
}

static UIView *VSMakeDivider(CGRect frame) {
    UIView *d = [[UIView alloc] initWithFrame:frame];
    d.userInteractionEnabled = NO;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
    g.startPoint = CGPointMake(0.0, 0.5);
    g.endPoint = CGPointMake(1.0, 0.5);
    UIColor *pink = VSToolPinkAccent();
    g.colors = @[(id)[pink colorWithAlphaComponent:0.0].CGColor,
                 (id)[pink colorWithAlphaComponent:0.55].CGColor,
                 (id)[pink colorWithAlphaComponent:0.0].CGColor];
    [d.layer addSublayer:g];
    return d;
}

@interface VSToolMenuRowControl : UIControl
@end
@implementation VSToolMenuRowControl
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.975, 0.975) : CGAffineTransformIdentity;
        self.backgroundColor = highlighted
            ? [VSToolPinkAccent() colorWithAlphaComponent:0.18]
            : [UIColor colorWithWhite:1.0 alpha:0.06];
    } completion:nil];
}
@end

@interface VSToolMenuView : UIView
- (void)showAnimated;
- (void)hideAnimatedWithCompletion:(void (^)(void))completion;
- (void)buildPanel;
- (UIButton *)pillWithTitle:(NSString *)title frame:(CGRect)frame;
- (VSToolMenuRowControl *)rowWithIndex:(NSInteger)index title:(NSString *)title frame:(CGRect)frame;
- (void)haptic;
- (BOOL)isSingleTouchInArea:(UIView *)area forEvent:(UIEvent *)event;
- (void)menuControlTapped:(UIControl *)sender forEvent:(UIEvent *)event;
- (void)dimTapped:(UIControl *)sender forEvent:(UIEvent *)event;
- (void)performActionWithTag:(NSInteger)tag;
@end

@implementation VSToolMenuView {
    UIView *_panel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = self.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [self addSubview:blur];

    UIControl *dim = [[UIControl alloc] initWithFrame:self.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithRed:0.07 green:0.03 blue:0.12 alpha:0.42];
    [dim addTarget:self action:@selector(dimTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:dim];

    [self buildPanel];
    return self;
}

- (void)buildPanel {
    VSTool *tool = [VSTool shared];
    BOOL running = tool.currentTaskName.length > 0;

    CGFloat W = self.bounds.size.width;
    CGFloat pw = MIN(W - 40.0, 356.0);
    CGFloat inner = 22.0;
    CGFloat cw = pw - inner * 2.0;

    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 100)];
    _panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                              UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    _panel.layer.borderWidth = 1.0;
    _panel.layer.borderColor = [VSToolPinkAccent() colorWithAlphaComponent:0.28].CGColor;
    _panel.layer.shadowColor = UIColor.blackColor.CGColor;
    _panel.layer.shadowOpacity = 0.72;
    _panel.layer.shadowRadius = 28.0;
    _panel.layer.shadowOffset = CGSizeMake(0, 16);
    [self addSubview:_panel];

    CGFloat y = 22.0;
    UIImage *kitty = VSFloatingButtonIconImage();
    if (kitty) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:kitty];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.frame = CGRectMake((pw - 48.0) / 2.0, y, 48.0, 48.0);
        iv.layer.shadowColor = VSToolPinkAccent().CGColor;
        iv.layer.shadowOpacity = 0.45;
        iv.layer.shadowRadius = 10.0;
        iv.layer.shadowOffset = CGSizeZero;
        [_panel addSubview:iv];
        y += 52.0;
    }

    UILabel *title = VSMenuMakeLabel(CGRectMake(inner, y, cw, 28), @"VideoStarTool",
                                     [UIFont systemFontOfSize:21 weight:UIFontWeightBold], UIColor.whiteColor, NSTextAlignmentCenter);
    [_panel addSubview:title];
    y += 36.0;

    [_panel addSubview:VSMakeDivider(CGRectMake(inner, y, cw, 1))];
    y += 14.0;

    if (running) {
        CGFloat cardH = 52.0;
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(inner, y, cw, cardH)];
        card.backgroundColor = [VSToolPinkAccent() colorWithAlphaComponent:0.08];
        card.layer.cornerRadius = 16.0;
        card.layer.borderWidth = 1.0;
        card.layer.borderColor = [VSToolPinkAccent() colorWithAlphaComponent:0.22].CGColor;
        [_panel addSubview:card];

        UIFont *capFont = [UIFont systemFontOfSize:10.5 weight:UIFontWeightBold];
        UILabel *cap = VSMenuMakeLabel(CGRectMake(16, 8, cw - 116, 14), nil, capFont, VSToolPinkAccent(), NSTextAlignmentLeft);
        cap.attributedText = VSLetterSpaced(@"ĐANG CHẠY", 1.8, VSToolPinkAccent(), capFont);
        [card addSubview:cap];

        UILabel *name = VSMenuMakeLabel(CGRectMake(16, 25, cw - 116, 20), tool.currentTaskName,
                                        [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold], UIColor.whiteColor, NSTextAlignmentLeft);
        [card addSubview:name];

        UIButton *stop = [self pillWithTitle:@"Dừng" frame:CGRectMake(cw - 14 - 76, (cardH - 32) / 2.0, 76, 32)];
        stop.tag = kVSMenuTagStop;
        [stop addTarget:self action:@selector(menuControlTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:stop];
        y += cardH + 12.0;
    }

    NSArray<NSString *> *items = @[
        @"Auto nhập ảnh vào các lớp (x10)",
        @"Hiển thị code gần nhất",
        @"Auto chia beat",
        @"Auto nhập code + ảnh vào phân cảnh"
    ];
    CGFloat rowH = 48.0, gap = 9.0;
    for (NSUInteger i = 0; i < items.count; i++) {
        VSToolMenuRowControl *row = [self rowWithIndex:(NSInteger)(i + 1) title:items[i]
                                                 frame:CGRectMake(inner, y, cw, rowH)];
        [row addTarget:self action:@selector(menuControlTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:row];
        y += rowH + gap;
    }
    y += 8.0;

    UIButton *close = VSToolCreatePillButton(@"XONG", CGRectMake(inner, y, cw, 46), YES);
    close.tag = kVSMenuTagClose;
    [close addTarget:self action:@selector(menuControlTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:close];
    y += 46.0 + 22.0;

    CGFloat ph = y;
    _panel.frame = CGRectMake(0, 0, pw, ph);
    _panel.center = CGPointMake(W / 2.0, self.bounds.size.height / 2.0);
    _panel.layer.cornerRadius = kVSMenuCorner;
    _panel.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_panel.bounds cornerRadius:kVSMenuCorner].CGPath;
    [_panel.layer insertSublayer:VSMakePlumGradient(_panel.bounds, kVSMenuCorner) atIndex:0];
}

- (UIButton *)pillWithTitle:(NSString *)title frame:(CGRect)frame {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.backgroundColor = VSToolPinkAccent();
    b.layer.cornerRadius = frame.size.height / 2.0;
    b.layer.shadowColor = VSToolPinkAccent().CGColor;
    b.layer.shadowOpacity = 0.45;
    b.layer.shadowRadius = 8.0;
    b.layer.shadowOffset = CGSizeZero;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:VSToolPillTextColor() forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    return b;
}

- (VSToolMenuRowControl *)rowWithIndex:(NSInteger)index title:(NSString *)title frame:(CGRect)frame {
    VSToolMenuRowControl *row = [[VSToolMenuRowControl alloc] initWithFrame:frame];
    row.tag = index;
    row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    row.layer.cornerRadius = 15.0;
    row.layer.borderWidth = 1.0;
    row.layer.borderColor = [VSToolPinkAccent() colorWithAlphaComponent:0.16].CGColor;
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    CGFloat d = 32.0;
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(12, (frame.size.height - d) / 2.0, d, d)];
    badge.userInteractionEnabled = NO;
    badge.backgroundColor = VSToolPinkAccent();
    badge.layer.cornerRadius = d / 2.0;
    badge.layer.shadowColor = VSToolPinkAccent().CGColor;
    badge.layer.shadowOpacity = 0.45;
    badge.layer.shadowRadius = 7.0;
    badge.layer.shadowOffset = CGSizeZero;
    UILabel *num = VSMenuMakeLabel(CGRectMake(0, 0, d, d), [NSString stringWithFormat:@"%ld", (long)index],
                                   [UIFont systemFontOfSize:14.5 weight:UIFontWeightBold], VSToolPillTextColor(),
                                   NSTextAlignmentCenter);
    [badge addSubview:num];
    [row addSubview:badge];

    CGFloat tx = 12.0 + d + 12.0;
    CGFloat tw = frame.size.width - tx - 30.0;
    UILabel *t = VSMenuMakeLabel(CGRectMake(tx, (frame.size.height - 22.0) / 2.0, tw, 22.0), title,
                                 [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold], UIColor.whiteColor, NSTextAlignmentLeft);
    t.minimumScaleFactor = 0.72;
    [row addSubview:t];

    UILabel *chev = VSMenuMakeLabel(CGRectMake(frame.size.width - 28, (frame.size.height - 26) / 2.0, 18, 26), @"›",
                                    [UIFont systemFontOfSize:22 weight:UIFontWeightMedium], VSToolPinkAccent(), NSTextAlignmentCenter);
    chev.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:chev];
    return row;
}

- (void)showAnimated {
    self.alpha = 0.0;
    _panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.alpha = 1.0;
        self->_panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)hideAnimatedWithCompletion:(void (^)(void))completion {
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.alpha = 0.0;
        self->_panel.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:^(BOOL __unused finished) {
        [self removeFromSuperview];
        if (completion) completion();
    }];
}

- (void)haptic {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [g prepare];
        [g impactOccurred];
    }
}

- (BOOL)isSingleTouchInArea:(UIView *)area forEvent:(UIEvent *)event {
    NSUInteger n = 0;
    for (UITouch *t in event.allTouches) {
        if (t.view && [t.view isDescendantOfView:area]) n++;
    }
    return n <= 1;
}

- (void)menuControlTapped:(UIControl *)sender forEvent:(UIEvent *)event {
    if (![self isSingleTouchInArea:_panel forEvent:event]) return;
    if ([VSTool shared].menuView != self) return;
    [self performActionWithTag:sender.tag];
}

- (void)dimTapped:(UIControl *)sender forEvent:(UIEvent *)event {
    if (![self isSingleTouchInArea:self forEvent:event]) return;
    if ([VSTool shared].menuView != self) return;
    [[VSTool shared] hideMenuWithCompletion:nil];
}

- (void)performActionWithTag:(NSInteger)tag {
    [self haptic];
    VSTool *tool = [VSTool shared];
    if (tag == kVSMenuTagClose) { [tool hideMenuWithCompletion:nil]; return; }
    if (tag == kVSMenuTagStop) { [tool hideMenuWithCompletion:^{ [tool stopCurrentTaskFromMenu]; }]; return; }
    [tool hideMenuWithCompletion:^{ [tool runMenuFeature:tag]; }];
}

@end

// ============================================================================
// NHẬP MEDIA: PICKER (ĐOẠN 1) + NHẬP NGẦM KHÔNG MỞ PICKER (ĐOẠN 2+) + COPY X10
// ============================================================================

static NSString *VSFillSummary(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stop) {
    if (stop) return stop;
    if (targets == 0) return @"Xong. Chỉ có 1 lớp, không có lớp nào khác để chép.";
    NSMutableString *msg = [NSMutableString stringWithFormat:@"Xong lớp nguồn + %lu/%lu lớp còn lại",
                            (unsigned long)copied, (unsigned long)targets];
    if (unconfirmed.count) {
        [msg appendFormat:@"\n⚠️ %lu lớp chưa xác nhận — kiểm tra lại trong Video Star", (unsigned long)unconfirmed.count];
    }
    return msg;
}

@interface VSLayerFiller : NSObject
@property (nonatomic, weak) id editor;
@property (nonatomic, assign) NSUInteger runId;
@property (nonatomic, copy) NSArray<NSNumber *> *layers;
@property (nonatomic, copy) VSFillCompletion completion;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *unconfirmed;
@property (nonatomic, assign) NSUInteger source;
@property (nonatomic, assign) NSUInteger nextIndex;
@property (nonatomic, assign) NSUInteger copied;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, copy) NSString *beforeSignature;
@property (nonatomic, assign) BOOL pickerSeenOpen;
@property (nonatomic, assign) BOOL pickerConfirmed;
@property (nonatomic, assign) CFAbsoluteTime pickerClosedAt;
@property (nonatomic, assign) CFAbsoluteTime pickStartedAt;
@property (nonatomic, assign) NSInteger pickOutcome;   // 0 chờ, 1 đã chọn, 2 huỷ, 3 popup Pro, 4 nhập ngầm thất bại, 5 editor đóng
@property (nonatomic, assign) BOOL requirePickerOpen;
@property (nonatomic, assign) BOOL replaying;          // Nhập ngầm lựa chọn đã lưu, không mở bảng chọn
+ (void)fillLayers:(NSArray<NSNumber *> *)layers editor:(id)editor runId:(NSUInteger)runId completion:(VSFillCompletion)completion;
+ (void)fillLayers:(NSArray<NSNumber *> *)layers editor:(id)editor runId:(NSUInteger)runId requirePickerOpen:(BOOL)requirePicker completion:(VSFillCompletion)completion;
@end

static VSLayerFiller *g_activeFiller = nil;

@implementation VSLayerFiller

+ (void)fillLayers:(NSArray<NSNumber *> *)layers editor:(id)editor runId:(NSUInteger)runId completion:(VSFillCompletion)completion {
    [self fillLayers:layers editor:editor runId:runId requirePickerOpen:NO completion:completion];
}

+ (void)fillLayers:(NSArray<NSNumber *> *)layers editor:(id)editor runId:(NSUInteger)runId requirePickerOpen:(BOOL)requirePicker completion:(VSFillCompletion)completion {
    if (layers.count == 0) { if (completion) completion(0, 0, @[], @"Không có lớp để thay"); return; }
    VSLayerFiller *f = [VSLayerFiller new];
    f.editor = editor;
    f.runId = runId;
    f.layers = layers;
    f.completion = completion;
    f.unconfirmed = [NSMutableArray array];
    f.source = layers.firstObject.unsignedIntegerValue;
    f.nextIndex = 1;
    f.requirePickerOpen = requirePicker;
    g_vsaAutomating = YES;
    g_suppressLayerActionMenu = YES;
    g_activeFiller = f;
    [f selectSourceAndPick];
}

- (BOOL)alive {
    return !self.finished && self.runId == g_runIdentifier;
}

- (VSObjProvider)provider {
    __weak VSLayerFiller *wSelf = self;
    return ^id{ return wSelf.editor; };
}

- (void)finishWithStop:(NSString *)reason {
    if (self.finished) return;
    self.finished = YES;
    g_onLayerAddedHandler = nil;
    g_captureMediaResponse = NO;
    g_silentMediaReplay = NO;
    g_vsaAutomating = NO;
    g_suppressLayerActionMenu = NO;
    BOOL live = (self.runId == g_runIdentifier);
    VSFillCompletion cb = self.completion;
    self.completion = nil;
    if (g_activeFiller == self) g_activeFiller = nil;
    if (live && cb) {
        NSUInteger targets = self.layers.count > 0 ? self.layers.count - 1 : 0;
        cb(self.copied, targets, [self.unconfirmed copy], reason);
    }
}

- (void)selectLayerV4:(NSUInteger)n then:(void (^)(BOOL ok))next {
    VSObjProvider p = [self provider];
    id ed = p();
    if (!ed) { next(NO); return; }
    if ([ed respondsToSelector:@selector(selectLayerNum:flash:)]) {
        VSTry(^{ [ed selectLayerNum:n flash:NO]; });
    }
    if (![ed respondsToSelector:@selector(lastSelectedLayerNum)]) {
        VSDispatchAfterMS(300, ^{ next(YES); });
        return;
    }
    VSSafePollEditor(self.runId, 50, 80, p, ^BOOL(id e) {
        return VSLastSelectedLayer(e) == (NSInteger)n;
    }, ^(BOOL ok) { next(ok); });
}

- (void)selectLayerTurbo:(NSUInteger)n then:(void (^)(BOOL ok))next {
    VSObjProvider p = [self provider];
    id ed = p();
    if (!ed) { next(NO); return; }
    BOOL supportsQuery = [ed respondsToSelector:@selector(lastSelectedLayerNum)];
    if (supportsQuery && VSLastSelectedLayer(ed) == (NSInteger)n) { next(YES); return; }
    if ([ed respondsToSelector:@selector(selectLayerNum:flash:)]) {
        VSTry(^{ [ed selectLayerNum:n flash:NO]; });
    }
    if (!supportsQuery) { VSDispatchAfterMS(20, ^{ next(YES); }); return; }
    if (VSLastSelectedLayer(ed) == (NSInteger)n) { next(YES); return; }
    VSSafePollEditor(self.runId, 15, 120, p, ^BOOL(id e) {
        return VSLastSelectedLayer(e) == (NSInteger)n;
    }, ^(BOOL ok) { next(ok); });
}

- (void)selectSourceAndPick {
    [self selectLayerV4:self.source then:^(BOOL ok) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!ok) { [self finishWithStop:@"Không chọn được lớp nguồn"]; return; }
        VSDispatchAfterMS(self.requirePickerOpen ? 220 : 100, ^{ [self openPicker]; });
    }];
}

// Đoạn 1 (chưa có ảnh lưu): mở bảng chọn ảnh như cũ.
// Đoạn 2+ (đã có g_cachedPickResponse): gọi thẳng pickedWithClipPickerResponse:, KHÔNG mở bảng chọn.
- (void)openPicker {
    if (![self alive]) { [self finishWithStop:nil]; return; }
    id ed = self.editor;
    if (!VSEditorIsAlive(ed)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }

    BOOL canReplay = (g_cachedPickResponse != nil) && [ed respondsToSelector:@selector(pickedWithClipPickerResponse:)];
    if (!canReplay && ![ed respondsToSelector:@selector(pickNewContent)]) { [self finishWithStop:@"Không tìm thấy pickNewContent"]; return; }

    self.beforeSignature = VSLayerSignature(VSEngineFrom(ed), self.source) ?: @"";
    self.pickerSeenOpen = NO;
    self.pickerConfirmed = NO;
    self.pickerClosedAt = 0;
    self.pickOutcome = 0;
    self.replaying = canReplay;
    self.pickStartedAt = CFAbsoluteTimeGetCurrent();

    __weak VSLayerFiller *wSelf = self;
    g_onLayerAddedHandler = ^(id sender) {
        VSLayerFiller *s = wSelf;
        if (!s || sender != s.editor) return;
        s.pickerConfirmed = YES;
    };

    if (!canReplay) {
        g_silentMediaReplay = NO;
        g_captureMediaResponse = YES;
        BOOL opened = VSTry(^{ [ed pickNewContent]; });
        if (!opened) {
            g_captureMediaResponse = NO;
            [self finishWithStop:@"Không mở được bảng chọn media"];
            return;
        }
        VSSafePollEditor(self.runId, 120, 1500, [self provider], ^BOOL(id e) {
            return [self pickConditionOn:e];
        }, ^(BOOL __unused ok) {
            [self afterPickWait];
        });
        return;
    }

    // NHẬP NGẦM TRỰC TIẾP: không gọi pickNewContent, không hiện bảng chọn ảnh.
    // Hook dismissViewControllerAnimated:completion: sẽ chặn editor tự đóng khi không có picker.
    id response = g_cachedPickResponse;
    g_captureMediaResponse = NO;
    g_silentMediaReplay = YES;

    BOOL fired = VSTry(^{ [ed pickedWithClipPickerResponse:response]; });
    if (!fired) {
        g_silentMediaReplay = NO;
        g_cachedPickResponse = nil;
        self.replaying = NO;
        self.requirePickerOpen = NO;
        [[VSTool shared] updateStatusHUD:@"Nhập ngầm không ăn, mở chọn tay 1 lần…"];
        VSDispatchAfterMS(80, ^{ [self openPicker]; });
        return;
    }

    VSSafePollEditor(self.runId, 60, 200, [self provider], ^BOOL(id e) {
        return [self pickConditionOn:e];
    }, ^(BOOL __unused ok) {
        [self afterPickWait];
    });
}

- (BOOL)pickConditionOn:(id)ed {
    UIViewController *vc = (UIViewController *)ed;
    BOOL open = vc.presentedViewController != nil || vc.navigationController.presentedViewController != nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!VSEditorIsAlive(ed)) { self.pickOutcome = 5; return YES; }
    if (self.replaying && now - self.pickStartedAt > VS_REPLAY_TIMEOUT) { self.pickOutcome = 4; return YES; }
    if (open) {
        self.pickerSeenOpen = YES;
        self.pickerClosedAt = 0;
        return NO;
    }
    if (VSPurchasePopupVisible(ed)) { self.pickOutcome = 3; return YES; }
    VSResolvePopupsImmediately(ed);

    id engine = VSEngineFrom(ed);
    NSString *sig = VSLayerSignature(engine, self.source) ?: @"";
    BOOL changed = sig.length > 0 && ![sig isEqualToString:(self.beforeSignature ?: @"")];
    BOOL pickedSignal = self.pickerConfirmed || changed;
    BOOL pickerOK = !self.requirePickerOpen || self.pickerSeenOpen || self.replaying;
    if (pickedSignal && pickerOK && VSLayerAssetLoaded(engine, self.source) && !VSEditorIsBusy(ed)) {
        self.pickOutcome = 1;
        return YES;
    }
    if (self.pickerSeenOpen && !self.replaying) {
        if (self.pickerClosedAt == 0) self.pickerClosedAt = now;
        if (now - self.pickerClosedAt > 2.5) { self.pickOutcome = 2; return YES; }
    }
    return NO;
}

- (void)afterPickWait {
    g_onLayerAddedHandler = nil;
    g_captureMediaResponse = NO;
    g_silentMediaReplay = NO;
    if (![self alive]) { [self finishWithStop:nil]; return; }
    switch (self.pickOutcome) {
        case 1: [self copyNext]; break;
        case 2: [self finishWithStop:@"Đã huỷ (chưa chọn media)"]; break;
        case 3: [self finishWithStop:@"Popup mua Pro"]; break;
        case 4: {
            // Nhập ngầm không ăn -> bỏ ảnh đã lưu, mở chọn tay 1 lần rồi lưu lại
            g_cachedPickResponse = nil;
            self.replaying = NO;
            self.requirePickerOpen = NO;
            [[VSTool shared] updateStatusHUD:@"Dùng lại ảnh không được, chọn tay 1 lần…"];
            VSDispatchAfterMS(100, ^{ [self openPicker]; });
            break;
        }
        case 5: [self finishWithStop:@"Editor bị đóng khi nhập ảnh"]; break;
        default: [self finishWithStop:@"Quá thời gian chọn media"]; break;
    }
}

// ===== VÒNG LẶP COPY SIÊU NHANH X10 =====

- (void)advance {
    self.nextIndex += 1;
    VSDispatchAfterMS(15, ^{ [self copyNext]; });
}

- (void)skipTarget:(NSUInteger)target {
    [self.unconfirmed addObject:@(target)];
    [self advance];
}

- (void)copyNext {
    if (![self alive]) { [self finishWithStop:nil]; return; }
    id ed = self.editor;
    if (!VSEditorIsAlive(ed)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }
    if (VSPurchasePopupVisible(ed)) { [self finishWithStop:@"Popup mua Pro"]; return; }

    if (self.nextIndex >= self.layers.count) {
        [self selectLayerTurbo:self.source then:^(BOOL __unused ok) {
            id eFinal = self.editor;
            if (eFinal) {
                VSTry(^{ if ([eFinal respondsToSelector:@selector(refreshDisplay)]) [eFinal refreshDisplay]; });
            }
            [self finishWithStop:nil];
        }];
        return;
    }

    NSUInteger target = [self.layers[self.nextIndex] unsignedIntegerValue];
    [[VSTool shared] updateStatusHUD:[NSString stringWithFormat:@"⚡ Chép nhanh lớp %lu (%lu/%lu)…",
                                      (unsigned long)target + 1,
                                      (unsigned long)self.nextIndex,
                                      (unsigned long)(self.layers.count - 1)]];
    VSDismissLayerActionMenus(ed);

    VSWaitForMemory(self.runId, ^(BOOL memOK) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!memOK) { [self skipTarget:target]; return; }
        [self copyToTarget:target];
    });
}

- (void)copyToTarget:(NSUInteger)target {
    [self selectLayerTurbo:target then:^(BOOL selected) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!selected || !VSEditorIsAlive(self.editor)) { [self skipTarget:target]; return; }

        id e2 = self.editor;
        id eng2 = VSEngineFrom(e2);
        NSString *before = VSLayerSignature(eng2, target) ?: @"";

        if (!VSFireCopyLayer(e2, eng2, self.source)) { [self skipTarget:target]; return; }

        if (!VSEditorIsBusy(e2) && !VSPurchasePopupVisible(e2)) {
            NSString *now = VSLayerSignature(eng2, target) ?: @"";
            if (VSLayerAssetLoaded(eng2, target) && now.length > 0 && ![now isEqualToString:before]) {
                self.copied += 1;
                [self advance];
                return;
            }
        }

        [self waitCopyConfirmTarget:target before:before];
    }];
}

- (void)waitCopyConfirmTarget:(NSUInteger)target before:(NSString *)before {
    NSUInteger tries = (NSUInteger)(VS_COPY_CONFIRM_TIMEOUT * 1000.0 / 20.0);
    VSSafePollEditor(self.runId, 20, tries, [self provider], ^BOOL(id e) {
        if (VSPurchasePopupVisible(e)) return YES;
        VSResolvePopupsImmediately(e);
        if (VSEditorIsBusy(e)) return NO;
        id engine = VSEngineFrom(e);
        NSString *now = VSLayerSignature(engine, target) ?: @"";
        return VSLayerAssetLoaded(engine, target) && now.length > 0 && ![now isEqualToString:before];
    }, ^(BOOL ok) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (VSPurchasePopupVisible(self.editor)) { [self finishWithStop:@"Popup mua Pro"]; return; }
        if (ok) {
            self.copied += 1;
        } else {
            [self.unconfirmed addObject:@(target)];
        }
        [self advance];
    });
}

@end

@implementation VSToolRootVC
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation { return UIStatusBarAnimationNone; }
@end

// ============================================================================
// ĐỌC QR TỪ ẢNH
// ============================================================================

static NSString *VSFirstQRMessage(NSArray *features) {
    NSString *fallback = nil;
    for (id f in features) {
        if (![f isKindOfClass:[CIQRCodeFeature class]]) continue;
        NSString *msg = ((CIQRCodeFeature *)f).messageString;
        if (!msg.length) continue;
        if ([msg hasPrefix:@"m"] || [msg hasPrefix:@"n"]) return msg;
        if (!fallback) fallback = msg;
    }
    return fallback;
}

static NSString *VSDecodeQRRobust(UIImage *image) {
    if (!image) return nil;
    CIImage *base = [[CIImage alloc] initWithImage:image];
    if (!base && image.CGImage) base = [CIImage imageWithCGImage:image.CGImage];
    if (!base) return nil;
    NSString *result = nil;
    @autoreleasepool {
        CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil
                                                  options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
        if (!detector) return nil;
        CGFloat scales[] = {1.0, 0.5, 2.0};
        for (NSUInteger i = 0; i < 3 && !result; i++) {
            CIImage *scaled = (scales[i] == 1.0) ? base
                : [base imageByApplyingTransform:CGAffineTransformMakeScale(scales[i], scales[i])];
            result = VSFirstQRMessage([detector featuresInImage:scaled]);
            if (result) break;
            CIFilter *f = [CIFilter filterWithName:@"CIColorControls"];
            if (!f) continue;
            [f setValue:scaled forKey:kCIInputImageKey];
            [f setValue:@0.0 forKey:kCIInputSaturationKey];
            [f setValue:@1.6 forKey:kCIInputContrastKey];
            if (f.outputImage) result = VSFirstQRMessage([detector featuresInImage:f.outputImage]);
        }
    }
    return result;
}

API_AVAILABLE(ios(14.0))
@interface VSQRBatchPickerDelegate : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, copy) void (^onPicked)(NSArray<PHPickerResult *> *results);
@end
API_AVAILABLE(ios(14.0))
@implementation VSQRBatchPickerDelegate
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    void (^cb)(NSArray<PHPickerResult *> *) = self.onPicked;
    self.onPicked = nil;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(results);
    }];
}
@end

static id g_qrBatchPickerDelegate = nil;

static void VSLoadPickedImages(NSArray<PHPickerResult *> *results, void (^done)(NSArray *images)) API_AVAILABLE(ios(14.0)) {
    NSMutableArray *images = [NSMutableArray arrayWithCapacity:results.count];
    for (NSUInteger i = 0; i < results.count; i++) [images addObject:[NSNull null]];
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger i = 0; i < results.count; i++) {
        NSItemProvider *provider = results[i].itemProvider;
        if (![provider canLoadObjectOfClass:[UIImage class]]) continue;
        dispatch_group_enter(group);
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(id obj, NSError *__unused err) {
            @synchronized (images) {
                images[i] = [obj isKindOfClass:[UIImage class]] ? obj : [NSNull null];
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{ done([images copy]); });
}

// ============================================================================
// NHẬP QR HÀNG LOẠT
// ============================================================================

@interface VSQRBatchImporter : NSObject
@property (nonatomic, weak) VSTool *tool;
@property (nonatomic, copy) NSArray *images;
@property (nonatomic, assign) NSUInteger runId;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, assign) BOOL gotCurrent;
@property (nonatomic, assign) BOOL done;
@property (nonatomic, copy) void (^completion)(NSString *errorMessage);
- (void)start;
@end

static VSQRBatchImporter *g_activeImporter = nil;

@implementation VSQRBatchImporter

- (void)start {
    g_activeImporter = self;
    [self next];
}

- (void)finishWithError:(NSString *)err {
    if (self.done) return;
    self.done = YES;
    VSQRBatchImporter *keep __attribute__((objc_precise_lifetime)) = self;
    VSTool *t = self.tool;
    void (^cb)(NSString *) = self.completion;
    self.completion = nil;
    BOOL live = (self.runId == g_runIdentifier);
    if (g_activeImporter == self) g_activeImporter = nil;
    t.multiSceneActiveCapturingIndex = -1;
    [t restoreOriginalQRCodeDelegate];
    t.qrCaptureProxy = nil;
    if (live && cb) cb(err);
    (void)keep;
}

- (void)next {
    VSTool *t = self.tool;
    if (!t || self.done || self.runId != g_runIdentifier) { [self finishWithError:nil]; return; }
    if (self.index >= self.images.count) { [self finishWithError:nil]; return; }

    NSUInteger i = self.index;
    id item = self.images[i];
    UIImage *img = [item isKindOfClass:[UIImage class]] ? (UIImage *)item : nil;
    NSString *code = VSDecodeQRRobust(img);
    if (!code.length || !([code hasPrefix:@"m"] || [code hasPrefix:@"n"])) {
        [self finishWithError:[NSString stringWithFormat:@"Ảnh thứ %lu không đọc được mã QR của Video Star.", (unsigned long)(i + 1)]];
        return;
    }
    Class qc = NSClassFromString(@"QRCodeManager");
    id qr = [qc respondsToSelector:@selector(sharedInstance)] ? [qc sharedInstance] : nil;
    if (!qr || ![qr respondsToSelector:@selector(selectedCode:withImageData:)]) {
        [self finishWithError:@"Không tìm thấy QRCodeManager"];
        return;
    }
    if (!t.savedOriginalQRDelegateValid) {
        t.savedOriginalQRDelegate = VSSafeValueForKey(qr, @"delegate");
        t.savedOriginalQRDelegateValid = YES;
    }
    t.multiSceneActiveCapturingIndex = (NSInteger)i;
    [t updateStatusHUD:[NSString stringWithFormat:@"Nhập code %lu/%lu…", (unsigned long)(i + 1), (unsigned long)self.images.count]];

    self.gotCurrent = NO;
    __weak VSQRBatchImporter *wSelf = self;
    VSToolQRCodeCaptureProxy *proxy = [VSToolQRCodeCaptureProxy new];
    proxy.onCodeCapturedBlock = ^(id preset, id codeId) {
        VSQRBatchImporter *s = wSelf;
        VSTool *st = s.tool;
        if (!s || !st || s.done || s.gotCurrent || s.index != i || s.runId != g_runIdentifier) return;
        if (!preset || ![codeId isKindOfClass:[NSString class]]) return;
        s.gotCurrent = YES;
        st.multiScenePresets[i] = preset;
        st.multiSceneCodes[i] = codeId;
        s.index = i + 1;
        VSDispatchAfterMS(300, ^{ [s next]; });
    };
    t.qrCaptureProxy = proxy;
    VSSetQRDelegateSafely(qr, proxy);
    NSData *png = UIImagePNGRepresentation(VSDownscaledImage(img, 1024.0));
    VSTry(^{ [qr selectedCode:code withImageData:png]; });

    VSDispatchAfterMS(6000, ^{
        VSQRBatchImporter *s = wSelf;
        if (!s || s.done || s.gotCurrent || s.index != i || s.runId != g_runIdentifier) return;
        [s finishWithError:[NSString stringWithFormat:@"App không nhận được mã của ảnh thứ %lu.", (unsigned long)(i + 1)]];
    });
}

@end

// ============================================================================
// CHẠY HÀNG LOẠT CÁC PHÂN CẢNH
// Đoạn 1: chọn ảnh thật. Các đoạn sau: tự nhập ngầm không hiện bảng chọn.
// ============================================================================

@interface VSSceneBatchRunner : NSObject
@property (nonatomic, assign) NSUInteger runId;
@property (nonatomic, assign) NSUInteger start;
@property (nonatomic, assign) NSUInteger total;
@property (nonatomic, assign) NSUInteger orig;
@property (nonatomic, assign) NSUInteger offset;
@property (nonatomic, assign) NSUInteger okCount;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, copy) NSArray *presets;
@property (nonatomic, copy) NSArray *codes;
- (void)begin;
@end

static VSSceneBatchRunner *g_activeBatchRunner = nil;

@implementation VSSceneBatchRunner

- (BOOL)alive {
    return !self.finished && self.runId == g_runIdentifier;
}

- (void)begin {
    g_activeBatchRunner = self;
    [self nextScene];
}

- (void)finishWithError:(NSString *)err {
    if (self.finished) return;
    self.finished = YES;
    VSSceneBatchRunner *keep __attribute__((objc_precise_lifetime)) = self;
    BOOL live = (self.runId == g_runIdentifier);
    if (g_activeBatchRunner == self) g_activeBatchRunner = nil;
    if (!live) return;

    VSTool *tool = [VSTool shared];
    NSUInteger ok = self.okCount, total = self.total, orig = self.orig;

    id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (rvc) VSTry(^{ [rvc setLastViewedSceneIndex:orig]; });

    [tool terminateCurrentTaskQuietly];

    NSString *msg = [NSString stringWithFormat:@"Đã nhập xong %lu/%lu đoạn", (unsigned long)ok, (unsigned long)total];
    NSString *full = err ? [err stringByAppendingFormat:@"\n%@", msg] : msg;
    [tool showRunResultAlert:full title:err ? @"Dừng" : @"Thành công"];
    (void)keep;
}

- (void)nextScene {
    if (![self alive]) return;
    if (self.offset >= self.total) {
        VSDispatchAfterMS(600, ^{ [self finishWithError:nil]; });
        return;
    }
    NSUInteger o = self.offset++;
    NSUInteger sc = self.start + o;
    NSString *label = [NSString stringWithFormat:@"Đoạn %lu", (unsigned long)(sc + 1)];
    NSUInteger runId = self.runId;
    VSTool *tool = [VSTool shared];
    [tool updateStatusHUD:[NSString stringWithFormat:@"%@ (%lu/%lu): mở…", label, (unsigned long)(o + 1), (unsigned long)self.total]];

    VSWaitForMemory(runId, ^(BOOL __unused memOK) {
        if (![self alive]) return;
        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        [tool openMultiLayerEditorForScene:sc reviewVC:rvc runId:runId completion:^(id editor) {
            if (![self alive]) return;
            if (!editor) { [self finishWithError:[label stringByAppendingString:@": không mở được editor"]]; return; }
            [self importIntoEditor:editor index:o label:label];
        }];
    });
}

- (void)importIntoEditor:(id)editor index:(NSUInteger)o label:(NSString *)label {
    VSTool *tool = [VSTool shared];
    NSUInteger runId = self.runId;
    __weak id wEd = editor;
    [tool updateStatusHUD:[label stringByAppendingString:@": nhập preset…"]];

    [tool importPresetPayload:self.presets[o] codeIdentifier:self.codes[o] intoEditor:editor runId:runId completion:^(NSString *e1) {
        if (![self alive]) return;
        if (e1) { [self finishWithError:[NSString stringWithFormat:@"%@: %@", label, e1]]; return; }
        VSDispatchAfterMS(450, ^{
            if (![self alive]) return;
            id ed = wEd;
            if (!VSEditorIsAlive(ed)) { [self finishWithError:[label stringByAppendingString:@": editor đã bị đóng"]]; return; }

            NSArray<NSNumber *> *layers = VSDetectFillableLayers(VSEngineFrom(ed), YES);
            if (layers.count == 0) { [self finishWithError:[label stringByAppendingString:@": preset không có lớp video/ảnh"]]; return; }

            BOOL reuse = (g_cachedPickResponse != nil);
            [tool updateStatusHUD:[label stringByAppendingString:reuse ? @": tự động nhập ảnh đã lưu…" : @": chọn ảnh/video để điền các lớp…"]];

            [VSLayerFiller fillLayers:layers editor:ed runId:runId requirePickerOpen:!reuse completion:^(NSUInteger __unused copied, NSUInteger __unused targets, NSArray<NSNumber *> *unconfirmed, NSString *stop) {
                if (![self alive]) return;
                if (stop) { [self finishWithError:[NSString stringWithFormat:@"%@: %@", label, stop]]; return; }
                if (unconfirmed.count) {
                    [self finishWithError:[NSString stringWithFormat:@"%@: còn %lu lớp chưa xác nhận, chưa Tạo", label, (unsigned long)unconfirmed.count]];
                    return;
                }
                id edDone = wEd;
                if (!VSEditorIsAlive(edDone)) { [self finishWithError:[label stringByAppendingString:@": editor bị đóng trước khi Tạo"]]; return; }

                [tool waitForEditorSettledThenCreate:edDone runId:runId completion:^(NSString *e2) {
                    if (![self alive]) return;
                    if (e2) { [self finishWithError:[NSString stringWithFormat:@"%@: %@", label, e2]]; return; }
                    self.okCount += 1;
                    VSSafePoll(runId, 100, 120, ^BOOL{ return VSFindTopViewControllerNamed(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                        if (![self alive]) return;
                        if (!back) { [self finishWithError:@"Không quay lại được màn hình phân cảnh"]; return; }
                        VSDispatchAfterMS(300, ^{ [self nextScene]; });
                    });
                }];
            }];
        });
    }];
}

@end

// ============================================================================
// VSTOOL IMPLEMENTATION
// ============================================================================

@implementation VSTool

+ (instancetype)shared {
    static VSTool *t; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ t = [VSTool new]; });
    return t;
}

- (void)setupToolInterfaceIfNeeded {
    VSInstallCoreHooksOnce();
    VSRefreshStatusBarHiddenEverywhere();
    if (self.window) return;
    static BOOL delayPassed = NO;
    if (!delayPassed) { delayPassed = YES; VSDispatchAfterMS(2000, ^{ [self setupToolInterfaceIfNeeded]; }); return; }

    CGRect b = UIScreen.mainScreen.bounds;
    VSToolPassThroughWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { w = [[VSToolPassThroughWindow alloc] initWithWindowScene:(UIWindowScene *)s]; break; }
    }
    if (!w) w = [[VSToolPassThroughWindow alloc] initWithFrame:b];
    w.frame = b;
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = UIColor.clearColor;

    VSToolRootVC *root = [VSToolRootVC new];
    root.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = root;

    UILabel *hud = [[UILabel alloc] init];
    hud.backgroundColor = VSToolCardBackgroundColor();
    hud.textColor = UIColor.whiteColor;
    hud.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    hud.textAlignment = NSTextAlignmentCenter;
    hud.numberOfLines = 2;
    hud.layer.cornerRadius = 14;
    hud.layer.borderWidth = 1.0;
    hud.layer.borderColor = [VSToolPinkAccent() colorWithAlphaComponent:0.42].CGColor;
    hud.clipsToBounds = YES;
    hud.hidden = YES;
    [root.view addSubview:hud];

    self.window = w;
    self.statusHUDLabel = hud;
    self.multiSceneActiveCapturingIndex = -1;
    g_overlayToolWindow = w;
    w.hidden = NO;

    [self setupFloatingMenuButton];
    VSRefreshStatusBarHiddenEverywhere();
}

- (void)setupFloatingMenuButton {
    UIView *host = self.window.rootViewController.view;
    if (!host || self.floatingMenuButton) return;

    CGFloat btnSize = 54.0;
    CGFloat topPad = MAX(host.safeAreaInsets.top, 12.0) + 4.0;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(10.0, topPad, btnSize, btnSize);
    btn.backgroundColor = UIColor.clearColor;
    btn.adjustsImageWhenHighlighted = YES;
    btn.imageView.contentMode = UIViewContentModeScaleAspectFit;

    UIImage *icon = VSFloatingButtonIconImage();
    if (icon) {
        [btn setImage:icon forState:UIControlStateNormal];
    } else {
        btn.backgroundColor = VSToolPinkAccent();
        btn.layer.cornerRadius = btnSize / 2.0;
        [btn setTitle:@"VS" forState:UIControlStateNormal];
        [btn setTitleColor:VSToolPillTextColor() forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    }

    btn.layer.shadowColor = VSToolPinkAccent().CGColor;
    btn.layer.shadowOpacity = 0.50;
    btn.layer.shadowRadius = 8.0;
    btn.layer.shadowOffset = CGSizeMake(0, 2);

    [btn addTarget:self action:@selector(handleFloatingButtonTap:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleFloatingButtonPan:)];
    [btn addGestureRecognizer:pan];

    [host addSubview:btn];
    self.floatingMenuButton = btn;
}

- (void)handleFloatingButtonTap:(UIButton *)sender {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [g prepare];
        [g impactOccurred];
    }
    [UIView animateWithDuration:0.10 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.88, 0.88);
    } completion:^(BOOL __unused finished) {
        [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{
            sender.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
    [self toggleMenu];
}

- (void)handleFloatingButtonPan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    UIView *host = btn.superview;
    if (!btn || !host) return;
    CGPoint delta = [pan translationInView:host];
    CGPoint next = CGPointMake(btn.center.x + delta.x, btn.center.y + delta.y);
    UIEdgeInsets safe = host.safeAreaInsets;
    CGFloat hw = btn.bounds.size.width / 2.0;
    CGFloat hh = btn.bounds.size.height / 2.0;
    next.x = MAX(hw + 4.0, MIN(host.bounds.size.width - hw - 4.0, next.x));
    next.y = MAX(MAX(safe.top, 8.0) + hh, MIN(host.bounds.size.height - MAX(safe.bottom, 8.0) - hh, next.y));
    btn.center = next;
    [pan setTranslation:CGPointZero inView:host];
}

- (UIViewController *)topPresenterVC {
    UIViewController *vc = self.window.rootViewController;
    for (int guardN = 0; guardN < 12 && vc.presentedViewController; guardN++) {
        UIViewController *next = vc.presentedViewController;
        if (next.isBeingDismissed) break;
        vc = next;
    }
    return vc;
}

- (void)presentFromTop:(UIViewController *)controller {
    [self presentController:controller retry:YES];
}

- (void)presentController:(UIViewController *)controller retry:(BOOL)retry {
    if (!controller || !self.window.rootViewController) return;
    UIViewController *presenter = [self topPresenterVC];
    BOOL presented = NO;
    @try {
        [presenter presentViewController:controller animated:YES completion:nil];
        presented = YES;
    } @catch (NSException *__unused e) {
        presented = NO;
    }
    if (presented || !retry) return;
    UIViewController *blocker = presenter.presentedViewController;
    if (blocker && !blocker.isBeingDismissed) {
        [presenter dismissViewControllerAnimated:NO completion:^{ [self presentController:controller retry:NO]; }];
    } else {
        VSDispatchAfterMS(300, ^{ [self presentController:controller retry:NO]; });
    }
}

- (void)updateStatusHUD:(NSString *)msg {
    UIView *c = self.window.rootViewController.view;
    self.statusHUDLabel.text = msg;
    CGFloat w = MIN(c.bounds.size.width - 136.0, 320.0);
    CGFloat topY = MAX(c.safeAreaInsets.top, 10.0) + 8.0;
    self.statusHUDLabel.frame = CGRectMake((c.bounds.size.width - w) / 2.0, topY, w, 40.0);
    self.statusHUDLabel.hidden = (msg.length == 0);
}

- (void)showStyledAlertWithTitle:(NSString *)title message:(NSString *)msg {
    [self updateStatusHUD:nil];
    UIView *host = self.window.rootViewController.view;
    if (!host) return;
    if (self.activeAlertView) {
        [self.activeAlertView removeFromSuperview];
        self.activeAlertView = nil;
    }
    NSString *icon = VSContains(title ?: @"", @"Thành công") ? @"✓" : @"!";
    VSToolAlertView *alert = [[VSToolAlertView alloc] initWithFrame:host.bounds
                                                              title:title ?: @"VideoStarTool"
                                                            message:msg
                                                           iconText:icon
                                                        buttonTitle:@"XONG"];
    [host addSubview:alert];
    if (self.floatingMenuButton) [host bringSubviewToFront:self.floatingMenuButton];
    self.activeAlertView = alert;
    [alert showAnimated];
}

- (void)showNotificationAlert:(NSString *)msg title:(NSString *)title {
    [self showStyledAlertWithTitle:title message:msg];
}

- (void)dismissBottomActionBar { [self.bottomActionBar removeFromSuperview]; self.bottomActionBar = nil; }

// Thẻ tím đậm bo tròn + viền hồng pastel
- (UIView *)buildCardContainerWithFrame:(CGRect)f title:(NSString *)title subtitle:(NSString *)subtitle {
    UIView *card = [[UIView alloc] initWithFrame:f];
    card.backgroundColor = UIColor.clearColor;
    card.layer.cornerRadius = 22.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [VSToolPinkAccent() colorWithAlphaComponent:0.28].CGColor;
    card.layer.shadowColor = UIColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.60;
    card.layer.shadowRadius = 20.0;
    card.layer.shadowOffset = CGSizeMake(0, 10);
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [card.layer insertSublayer:VSMakePlumGradient(CGRectMake(0, 0, f.size.width, f.size.height), 22.0) atIndex:0];

    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(18, 14, f.size.width - 36, 22)];
    h.text = title;
    h.textColor = UIColor.whiteColor;
    h.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    h.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(18, 38, f.size.width - 36, 38)];
    s.text = subtitle;
    s.numberOfLines = 0;
    s.textColor = VSToolSubtitleColor();
    s.font = [UIFont systemFontOfSize:13];
    s.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    [card addSubview:h];
    [card addSubview:s];
    return card;
}

- (void)displayBottomActionBarWithTitle:(NSString *)title message:(NSString *)msg confirmTitle:(NSString *)confirmTitle onConfirm:(void (^)(void))onConfirm onCancel:(void (^)(void))onCancel {
    [self dismissBottomActionBar];
    UIView *c = self.window.rootViewController.view;
    CGFloat w = MIN(c.bounds.size.width - 28.0, 440.0), h = 142.0;
    UIView *bar = [self buildCardContainerWithFrame:CGRectMake((c.bounds.size.width - w) / 2.0, c.bounds.size.height - c.safeAreaInsets.bottom - h - 68.0, w, h) title:title subtitle:msg];
    self.bottomBarConfirmBlock = onConfirm; self.bottomBarCancelBlock = onCancel;
    CGFloat bw = (w - 36.0 - 12.0) / 2.0;
    UIButton *cb = VSToolCreatePillButton(@"Hủy", CGRectMake(18, h - 54, bw, 40), NO);
    UIButton *ok = VSToolCreatePillButton(confirmTitle, CGRectMake(18 + bw + 12, h - 54, bw, 40), YES);
    [cb addTarget:self action:@selector(handleBottomBarCancel) forControlEvents:UIControlEventTouchUpInside];
    [ok addTarget:self action:@selector(handleBottomBarConfirm) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:cb];
    [bar addSubview:ok];
    [c addSubview:bar];
    self.bottomActionBar = bar;
}

- (void)handleBottomBarConfirm {
    void (^cb)(void) = self.bottomBarConfirmBlock;
    self.bottomBarConfirmBlock = nil; self.bottomBarCancelBlock = nil;
    [self dismissBottomActionBar];
    if (cb) cb();
}

- (void)handleBottomBarCancel {
    void (^cb)(void) = self.bottomBarCancelBlock;
    self.bottomBarConfirmBlock = nil; self.bottomBarCancelBlock = nil;
    [self dismissBottomActionBar];
    if (cb) cb();
}

- (void)toggleMenu {
    if (self.menuView) { [self hideMenuWithCompletion:nil]; return; }
    [self showMenu];
}

- (void)showMenu {
    UIView *host = self.window.rootViewController.view;
    if (!host || self.menuView) return;
    VSToolMenuView *menu = [[VSToolMenuView alloc] initWithFrame:host.bounds];
    [host addSubview:menu];
    if (self.floatingMenuButton) [host bringSubviewToFront:self.floatingMenuButton];
    self.menuView = menu;
    [menu showAnimated];
}

- (void)hideMenuWithCompletion:(void (^)(void))completion {
    UIView *menu = self.menuView;
    self.menuView = nil;
    if (!menu) { if (completion) completion(); return; }
    [(VSToolMenuView *)menu hideAnimatedWithCompletion:completion];
}

- (void)runMenuFeature:(NSInteger)index {
    if (self.currentTaskName) {
        [self showNotificationAlert:@"Đang có tác vụ chạy. Mở menu và chọn Dừng trước." title:@"Đang chạy"];
        return;
    }
    switch (index) {
        case 1: [self executeFeature1ReplaceLayers]; break;
        case 2: [self executeFeature2DisplayLastCode]; break;
        case 3: [self executeFeature3AutoSplitBeat]; break;
        case 4: [self executeFeature4BatchMultiScene]; break;
        default: break;
    }
}

- (void)stopCurrentTaskFromMenu {
    [self terminateCurrentTaskQuietly];
    [self showNotificationAlert:@"Đã dừng tác vụ hiện tại." title:@"Đã Dừng"];
}

- (NSUInteger)startNewTaskWithDescription:(NSString *)name initialStatus:(NSString *)status {
    g_runIdentifier++;
    g_autoConfirmPopups = NO;
    g_suppressLayerActionMenu = NO;
    g_dismissLayerMenu = YES;
    g_createInProgress = NO;
    g_vsaAutomating = NO;
    g_captureMediaResponse = NO;
    g_silentMediaReplay = NO;
    g_cachedPickResponse = nil;
    g_onLayerAddedHandler = nil;
    self.currentTaskName = name;
    [self updateStatusHUD:status];
    return g_runIdentifier;
}

- (void)restoreOriginalQRCodeDelegate {
    if (!self.savedOriginalQRDelegateValid) return;
    Class qc = NSClassFromString(@"QRCodeManager");
    id qr = [qc respondsToSelector:@selector(sharedInstance)] ? [qc sharedInstance] : nil;
    if (qr) VSSetQRDelegateSafely(qr, self.savedOriginalQRDelegate);
    self.savedOriginalQRDelegate = nil; self.savedOriginalQRDelegateValid = NO;
}

- (void)terminateCurrentTaskQuietly {
    g_runIdentifier++;
    g_autoConfirmPopups = NO;
    g_suppressLayerActionMenu = NO;
    g_dismissLayerMenu = NO;
    g_createInProgress = NO;
    g_vsaAutomating = NO;
    g_captureMediaResponse = NO;
    g_silentMediaReplay = NO;
    g_cachedPickResponse = nil;
    g_onLayerAddedHandler = nil;
    g_activeFiller = nil;
    g_activeImporter = nil;
    g_activeBatchRunner = nil;
    [self restoreOriginalQRCodeDelegate];
    [self dismissBottomActionBar];
    [self.multiSceneCardView removeFromSuperview];
    self.multiSceneCardView = nil;
    self.multiSceneActiveCapturingIndex = -1;
    self.qrCaptureProxy = nil;
    self.currentTaskName = nil;
    [self updateStatusHUD:nil];
}

- (void)finalizeTaskWithMessage:(NSString *)msg {
    [self terminateCurrentTaskQuietly];
    if (msg.length) [self showRunResultAlert:msg title:@"VideoStarTool"];
}

- (void)showRunResultAlert:(NSString *)msg title:(NSString *)title {
    [self showStyledAlertWithTitle:title message:msg];
}

// ============================================================================
// CHỨC NĂNG 1: Auto nhập ảnh/video (Copy siêu tốc x10)
// ============================================================================

- (void)executeFeature1ReplaceLayers {
    id editor = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
    if (!editor) { [self showNotificationAlert:@"Hãy mở một Scene Multi-Layer rồi bấm lại." title:@"Chưa mở Multi-Layer"]; return; }

    NSArray<NSNumber *> *layers = VSDetectFillableLayers(VSEngineFrom(editor), NO);
    if (layers.count == 0) { [self showNotificationAlert:@"Không có lớp video/ảnh nào để thay." title:@"Không có lớp"]; return; }

    NSUInteger runId = [self startNewTaskWithDescription:@"Auto nhập ảnh x10" initialStatus:@"Chọn 1 ảnh/video…"];
    [VSLayerFiller fillLayers:layers editor:editor runId:runId completion:^(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stop) {
        if (runId != g_runIdentifier) return;
        NSString *msg = VSFillSummary(copied, targets, unconfirmed, stop);
        VSDispatchAfterMS(200, ^{ [self finalizeTaskWithMessage:msg]; });
    }];
}

// ============================================================================
// CHỨC NĂNG 2: Xem code gần nhất
// ============================================================================

- (void)executeFeature2DisplayLastCode {
    UIImage *img = VSReadLastPersistedQRCodeImage();
    if (!img) { [self showNotificationAlert:@"Chưa có QR nào được lưu." title:@"Chưa có"]; return; }
    if (!VSDecodeQRCodeMessageFromImage(img)) { [self showNotificationAlert:@"QR không hợp lệ." title:@"Lỗi"]; return; }
    VSToolQRCodePreviewVC *vc = [VSToolQRCodePreviewVC new];
    vc.qrImage = img;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentFromTop:vc];
}

// ============================================================================
// CHỨC NĂNG 3: Auto chia beat
// ============================================================================

- (void)executeFeature3AutoSplitBeat {
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!reviewVC) { [self showNotificationAlert:@"Hãy vào màn hình Review trước rồi bấm lại." title:@"Sai vị trí"]; return; }
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto chia beat" initialStatus:@"Chuẩn bị…"];

    __weak id wRvc = reviewVC;
    VSObjProvider rvcProv = ^id{ return wRvc; };
    VSObjProvider svProv = ^id{
        id r = wRvc;
        return r ? VSSafeValueForKey(r, @"splitView") : nil;
    };
    BOOL (^svVisible)(void) = ^BOOL{
        id sv = svProv();
        if (!sv) return NO;
        UIView *v = [sv isKindOfClass:[UIView class]] ? sv : VSSafeValueForKey(sv, @"splitPanel");
        return [v isKindOfClass:[UIView class]] && v.window != nil;
    };

    if (!svVisible()) {
        id r = rvcProv();
        if (!r || !VSTry(^{ [r showSplitScene]; })) { [self finalizeTaskWithMessage:@"Không mở được bảng chia"]; return; }
    }

    VSSafePoll(runId, 100, 35, ^BOOL{ return svVisible(); }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        id sv = svProv();
        id r = rvcProv();
        if (!ok || !sv || !r) { [self finalizeTaskWithMessage:@"Không tìm thấy MultiSplitView"]; return; }
        [self validateAndRunBeatSplitting:r splitView:sv runId:runId];
    });
}

- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)sv runId:(NSUInteger)runId {
    __block NSString *err = nil;
    __block id<ProjectInterface> p = nil;
    __block NSUInteger before = 0;
    VSTry(^{
        p = [reviewVC project];
        NSUInteger s = [reviewVC sceneIndex];
        NSUInteger cc = [p clipCountForSceneIndex:s];
        if (![reviewVC isEnoughStorageAvailableForSplit]) err = @"Bộ nhớ không đủ";
        else if (![p sceneHasAtLeastOneClipWithSceneIndex:s] || cc == 0) err = @"Không có clip";
        else before = [p sceneCount];
    });
    if (err) { [self finalizeTaskWithMessage:err]; return; }
    if (!p) { [self finalizeTaskWithMessage:@"Lỗi kiểm tra"]; return; }

    BOOL started = VSTry(^{
        if (![sv beatModeOn]) [sv toggleBeatMode];
        [sv gotoTime:kCMTimeZero];
    });
    if (!started) { [self finalizeTaskWithMessage:@"Không bật Beat Mode"]; return; }

    __weak id wSv = sv;
    __block NSUInteger guard = 0, count = 0;
    __block CMTime last = kCMTimeInvalid;
    __block void (^step)(void) = nil;

    void (^finish)(void) = ^{
        step = nil;
        if (runId != g_runIdentifier) return;
        id s = wSv;
        if (!s) { [self finalizeTaskWithMessage:@"Mất màn hình chia beat"]; return; }
        if (count == 0 && VSCountOf(VSSafeValueForKey(s, @"splitTimes")) == 0) { [self finalizeTaskWithMessage:@"Không có beat"]; return; }
        if (!VSTry(^{ [s doSplit]; })) { [self finalizeTaskWithMessage:@"Lỗi chia"]; return; }
        [self updateStatusHUD:@"Đang chia…"];
        VSSafePoll(runId, 120, 150, ^BOOL{
            __block NSUInteger now = 0;
            VSTry(^{ now = [p sceneCount]; });
            return now > before;
        }, ^(BOOL ok) {
            if (runId != g_runIdentifier) return;
            __block NSUInteger after = before;
            VSTry(^{ after = [p sceneCount]; });
            [self finalizeTaskWithMessage:ok ? [NSString stringWithFormat:@"Xong, +%lu scene", (unsigned long)(after - before)] : @"Chưa xong"];
        });
    };

    step = ^{
        if (runId != g_runIdentifier) { step = nil; return; }
        if (++guard >= 2048) { finish(); return; }
        id s = wSv;
        if (!s) { finish(); return; }
        __block BOOL hasNext = NO;
        __block CMTime fromTime = kCMTimeInvalid;
        BOOL called = VSTry(^{
            hasNext = [s hasNextBeat];
            if (hasNext) { fromTime = VSSafeCurrentTime(s); [s jumpToNextBeat]; }
        });
        if (!called || !hasNext) { finish(); return; }
        CMTime from = fromTime;
        VSSafePoll(runId, 16, 60, ^BOOL{
            id s2 = wSv;
            if (!s2) return YES;
            CMTime cur = VSSafeCurrentTime(s2);
            return CMTIME_IS_VALID(cur) && (CMTIME_IS_INVALID(from) || CMTimeCompare(cur, from) > 0);
        }, ^(BOOL moved) {
            if (runId != g_runIdentifier) { step = nil; return; }
            id s3 = wSv;
            if (!s3) { finish(); return; }
            CMTime cur = VSSafeCurrentTime(s3);
            if (!moved || (CMTIME_IS_VALID(last) && CMTimeCompare(cur, last) <= 0)) { finish(); return; }
            last = cur;
            if (!VSTry(^{ [s3 setSplitPoint]; })) { finish(); return; }
            count++;
            [self updateStatusHUD:[NSString stringWithFormat:@"%lu điểm chia…", (unsigned long)count]];
            VSDispatchAfterMS(20, ^{ if (step) step(); });
        });
    };
    VSDispatchAfterMS(250, ^{ if (step) step(); });
}

// ============================================================================
// CHỨC NĂNG 4: Chọn phân cảnh -> Bắt đầu -> chọn ảnh QR -> tự chạy ngầm
// ============================================================================

- (void)executeFeature4BatchMultiScene {
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!reviewVC) { [self showNotificationAlert:@"Hãy vào màn hình phân cảnh trước rồi bấm lại." title:@"Sai vị trí"]; return; }
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto code + ảnh" initialStatus:nil];

    __block NSUInteger origScene = 0;
    VSTry(^{ origScene = [reviewVC lastViewedSceneIndex]; });
    if (!VSTry(^{ [reviewVC showMergeScenes]; })) { [self finalizeTaskWithMessage:@"Không mở được Hợp nhất"]; return; }

    __weak id wRvc = reviewVC;
    [self displayBottomActionBarWithTitle:@"Chọn phân cảnh"
                                  message:@"Chọn phân cảnh đầu và cuối, bấm Bắt đầu rồi chọn ảnh QR (mỗi đoạn 1 ảnh)."
                             confirmTitle:@"Bắt đầu"
                                onConfirm:^{
        id r = wRvc;
        if (!r) { [self finalizeTaskWithMessage:@"Mất màn hình phân cảnh"]; return; }
        [self parseMergeRangeThenPickCodes:r runId:runId originalLastViewed:origScene];
    } onCancel:^{
        id r = wRvc;
        if (r) VSTry(^{ [r closeMergePanel]; });
        [self terminateCurrentTaskQuietly];
    }];
}

- (void)parseMergeRangeThenPickCodes:(id)reviewVC runId:(NSUInteger)runId originalLastViewed:(NSUInteger)orig {
    if (runId != g_runIdentifier) return;
    __block id<ProjectInterface> p = nil;
    __block NSInteger total = 0;
    __block NSInteger s = -1, l = -1;
    VSTry(^{
        p = [reviewVC project];
        total = p ? (NSInteger)[p sceneCount] : 0;
        id sObj = VSSafeValueForKey(reviewVC, @"startScene"), lObj = VSSafeValueForKey(reviewVC, @"lastScene");
        s = [sObj respondsToSelector:@selector(integerValue)] ? [sObj integerValue] : -1;
        l = [lObj respondsToSelector:@selector(integerValue)] ? [lObj integerValue] : -1;
    });
    VSTry(^{ [reviewVC closeMergePanel]; });
    if (!p || s < 0 || l < s || l >= total) { [self finalizeTaskWithMessage:@"Phạm vi không hợp lệ"]; return; }

    self.multiSceneStart = (NSUInteger)s;
    self.multiSceneCount = (NSUInteger)(l - s + 1);
    self.multiSceneOriginalLastViewed = orig;
    self.multiSceneRunId = runId;
    self.multiSceneActiveCapturingIndex = -1;
    self.multiScenePresets = [NSMutableArray array];
    self.multiSceneCodes = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.multiSceneCount; i++) {
        [self.multiScenePresets addObject:[NSNull null]];
        [self.multiSceneCodes addObject:[NSNull null]];
    }
    VSDispatchAfterMS(350, ^{ [self presentQRPicker]; });
}

- (void)presentQRPicker {
    if (self.multiSceneRunId != g_runIdentifier) return;
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = (NSInteger)self.multiSceneCount;
        cfg.filter = [PHPickerFilter imagesFilter];
        if (@available(iOS 15.0, *)) {
            cfg.selection = PHPickerConfigurationSelectionOrdered;
        }
        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        VSQRBatchPickerDelegate *del = [VSQRBatchPickerDelegate new];
        NSUInteger runId = self.multiSceneRunId;
        __weak VSTool *wSelf = self;
        del.onPicked = ^(NSArray<PHPickerResult *> *results) {
            g_qrBatchPickerDelegate = nil;
            VSTool *s = wSelf;
            if (!s || runId != g_runIdentifier) return;
            if (results.count == 0) { [s terminateCurrentTaskQuietly]; return; }
            if (results.count != s.multiSceneCount) {
                NSString *m = [NSString stringWithFormat:@"Cần đúng %lu ảnh QR, bạn đã chọn %lu.",
                               (unsigned long)s.multiSceneCount, (unsigned long)results.count];
                [s terminateCurrentTaskQuietly];
                [s showNotificationAlert:m title:@"Sai số lượng"];
                return;
            }
            [s updateStatusHUD:@"Đang đọc ảnh QR…"];
            VSLoadPickedImages(results, ^(NSArray *images) {
                VSTool *s2 = wSelf;
                if (!s2 || runId != g_runIdentifier) return;
                VSQRBatchImporter *imp = [VSQRBatchImporter new];
                imp.tool = s2;
                imp.images = images;
                imp.runId = runId;
                imp.completion = ^(NSString *err) {
                    VSTool *s3 = wSelf;
                    if (!s3 || runId != g_runIdentifier) return;
                    if (err) {
                        [s3 terminateCurrentTaskQuietly];
                        [s3 showNotificationAlert:err title:@"Lỗi QR"];
                        return;
                    }
                    [s3 beginBatchProcessing];
                };
                [imp start];
            });
        };
        g_qrBatchPickerDelegate = del;
        pk.delegate = del;
        [self presentFromTop:pk];
    } else {
        [self finalizeTaskWithMessage:@"Cần iOS 14 trở lên để chọn nhiều ảnh QR"];
    }
}

- (void)handleMultiSceneCancel { [self terminateCurrentTaskQuietly]; }

- (void)beginBatchProcessing {
    NSUInteger runId = self.multiSceneRunId;
    if (runId != g_runIdentifier) return;
    g_autoConfirmPopups = YES;
    g_cachedPickResponse = nil;
    [self showProcessingProgressPanel];

    VSSceneBatchRunner *runner = [VSSceneBatchRunner new];
    runner.runId = runId;
    runner.start = self.multiSceneStart;
    runner.total = self.multiSceneCount;
    runner.orig = self.multiSceneOriginalLastViewed;
    runner.presets = [self.multiScenePresets copy];
    runner.codes = [self.multiSceneCodes copy];
    [runner begin];
}

- (void)showProcessingProgressPanel {
    [self.multiSceneCardView removeFromSuperview];
    UIView *c = self.window.rootViewController.view;
    CGFloat w = MIN(c.bounds.size.width - 28.0, 440.0), h = 68.0;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((c.bounds.size.width - w) / 2.0, c.bounds.size.height - c.safeAreaInsets.bottom - h - 68.0, w, h)];
    card.backgroundColor = UIColor.clearColor;
    card.layer.cornerRadius = 22.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [VSToolPinkAccent() colorWithAlphaComponent:0.28].CGColor;
    card.layer.shadowColor = UIColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.60;
    card.layer.shadowRadius = 20.0;
    card.layer.shadowOffset = CGSizeMake(0, 10);
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [card.layer insertSublayer:VSMakePlumGradient(CGRectMake(0, 0, w, h), 22.0) atIndex:0];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(20.0, (h - 24.0) / 2.0, w - 156.0, 24.0)];
    lbl.text = @"Đang chạy";
    lbl.textColor = UIColor.whiteColor;
    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    lbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:lbl];

    UIButton *b = VSToolCreatePillButton(@"Dừng", CGRectMake(w - 16.0 - 110.0, (h - 40.0) / 2.0, 110.0, 40.0), YES);
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [b addTarget:self action:@selector(handleMultiSceneCancel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:b];

    [c addSubview:card];
    self.multiSceneCardView = card;
}

- (void)openMultiLayerEditorForScene:(NSUInteger)scene reviewVC:(id)rvc runId:(NSUInteger)runId completion:(void (^)(id))done {
    id (^current)(void) = ^id{
        __block id ed = nil;
        VSTry(^{
            id candidate = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
            if (!candidate || ![candidate getMultiLayerEngine]) return;
            id nav = [candidate navigationController];
            BOOL ok = YES;
            if ([nav respondsToSelector:@selector(navSceneIndex)]) ok = ([nav navSceneIndex] == scene);
            if (ok) ed = candidate;
        });
        return ed;
    };
    id existing = current();
    if (existing) { done(existing); return; }
    if (!rvc) { done(nil); return; }
    if (!VSTry(^{ [rvc setLastViewedSceneIndex:scene]; [rvc showMultiLayer]; })) { done(nil); return; }
    VSSafePoll(runId, 80, 100, ^BOOL{ return current() != nil; }, ^(BOOL ok) {
        done(ok ? current() : nil);
    });
}

- (void)importPresetPayload:(id)preset codeIdentifier:(id)code intoEditor:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    if (![editor respondsToSelector:@selector(importedData:code:)]) { done(@"Editor không hỗ trợ"); return; }
    NSUInteger before = g_presetImportEventCounter;
    BOOL imported = VSTry(^{ [editor importedData:preset code:code]; });
    if (!imported) { done(@"Lỗi nạp preset"); return; }

    __weak id wEd = editor;
    VSObjProvider prov = ^id{ return wEd; };
    __block BOOL blocked = NO;
    VSSafePollEditor(runId, 40, 250, prov, ^BOOL(id ed) {
        VSPopupActionStatus s = VSResolvePopupsImmediately(ed);
        if (s == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
        return g_presetImportEventCounter > before;
    }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        if (blocked) { done(@"Popup mua Pro"); return; }
        if (!ok) { done(@"Timeout 10s"); return; }
        VSDispatchAfterMS(500, ^{
            if (runId != g_runIdentifier) return;
            __block BOOL purchase = NO;
            VSSafePollEditor(runId, 60, 60, prov, ^BOOL(id ed) {
                if (VSResolvePopupsImmediately(ed) == VSPopupActionStatusBlockedPurchase) { purchase = YES; return YES; }
                return !VSHasAnyActivePopup(ed) && VSNumActiveLayers(VSEngineFrom(ed)) > 0;
            }, ^(BOOL ready) {
                if (runId != g_runIdentifier) return;
                done(purchase ? @"Popup mua Pro" : (ready ? nil : @"Engine chưa sẵn sàng"));
            });
        });
    });
}

- (void)waitForEditorSettledThenCreate:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    __weak id wEd = editor;
    VSObjProvider prov = ^id{ return wEd; };
    __block NSUInteger stable = 0;
    __block BOOL purchase = NO;
    VSSafePollEditor(runId, 80, 150, prov, ^BOOL(id ed) {
        if (!VSEditorIsAlive(ed)) return YES;
        VSDismissLayerActionMenus(ed);
        if (VSResolvePopupsImmediately(ed) == VSPopupActionStatusBlockedPurchase) { purchase = YES; return YES; }
        BOOL calm = !VSHasAnyActivePopup(ed) && !VSEditorIsBusy(ed);
        stable = calm ? stable + 1 : 0;
        return stable >= 6;
    }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        if (purchase) { done(@"Popup mua Pro"); return; }
        id edNow = prov();
        if (!edNow || !VSEditorIsAlive(edNow)) { done(@"Editor bị đóng trước khi Tạo"); return; }
        if (!ok) { done(@"Editor chưa ổn định để Tạo (còn popup / đang tải)"); return; }
        [self triggerCreateInEditor:edNow runId:runId completion:done];
    });
}

- (void)triggerCreateInEditor:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    UIBarButtonItem *btn = VSFindCreateButtonOnEditor(editor);
    if (!btn) { done(@"Không tìm thấy nút Tạo"); return; }
    g_createInProgress = YES;
    __block BOOL fired = NO;
    if (btn.action && btn.target) {
        if (!VSTry(^{ fired = [UIApplication.sharedApplication sendAction:btn.action to:btn.target from:btn forEvent:nil]; })) {
            g_createInProgress = NO;
            done(@"Lỗi nhấn nút Tạo"); return;
        }
    }
    if (!fired && [editor respondsToSelector:@selector(create)]) {
        if (!VSTry(^{ [editor create]; fired = YES; })) { g_createInProgress = NO; done(@"Lỗi create"); return; }
    }
    if (!fired) { g_createInProgress = NO; done(@"Không kích hoạt được"); return; }

    __weak id wEd = editor;
    VSObjProvider prov = ^id{ return wEd; };
    __block BOOL blocked = NO;
    VSSafePollEditor(runId, 100, 600, prov, ^BOOL(id ed) {
        if (VSResolvePopupsImmediately(ed) == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
        return !([ed isViewLoaded] && [[ed view] window]);
    }, ^(BOOL closed) {
        g_createInProgress = NO;
        if (runId != g_runIdentifier) return;
        BOOL gone = (prov() == nil);
        done(blocked ? @"Tạo yêu cầu Pro" : ((closed || gone) ? nil : @"Tạo timeout"));
    });
}

@end

// ============================================================================
// HỦY TÁC VỤ & ENTRY POINT
// ============================================================================

static void VSAbortActiveTask(NSString *reason) {
    void (^body)(void) = ^{
        VSTool *tool = VSTool.shared;
        if (!tool.currentTaskName) return;
        [tool finalizeTaskWithMessage:reason];
    };
    if ([NSThread isMainThread]) body();
    else dispatch_async(dispatch_get_main_queue(), body);
}

static void VSBootstrapAutomation(void) {
    VSRunOnMain(^{
        VSInstallCoreHooksOnce();
        VSRefreshStatusBarHiddenEverywhere();
        if (!NSClassFromString(@"MultiLayerWizEffectVC")) return;
        VSTry(^{ [VSTool.shared setupToolInterfaceIfNeeded]; });
    });
}

__attribute__((constructor)) static void VSToolInitializerEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                             object:nil
                                                              queue:NSOperationQueue.mainQueue
                                                         usingBlock:^(NSNotification *__unused note) {
                @autoreleasepool { VSBootstrapAutomation(); }
            }];
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                VSBootstrapAutomation();
            }
        }
    });
}
