// ============================================================================
// VideoStarTool.m — Video Star 14.3.3 (build 1809) — v5.2
//
// CẬP NHẬT v5.2:
//   - Khôi phục nguyên vẹn logic vào phần nhập ảnh (selectSourceAndPick /
//     openPicker / pickConditionOn / timing 500ms sau importPreset) từ code v4
//     để sửa triệt để lỗi treo sau khi nhập code QR.
//   - Giữ nguyên tốc độ copyLayer: siêu nhanh x10 sau khi đã chọn ảnh xong.
//   - Chức năng 4: Không giới hạn số ảnh QR chọn (selectionLimit = 0), tự căn
//     đúng số đoạn theo số QR đã chọn, Đoạn 1 chọn ảnh 1 lần -> Đoạn 2..N tự
//     dùng lại ảnh đó (có fallback an toàn nếu không tự nạp được sau 3s).
//   - Giữ nguyên menu chạm 3 ngón 2 lần & đầy đủ 4 chức năng.
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
#define VSLog(...) ((void)0)

typedef id (^VSObjProvider)(void);
typedef void (^VSFillCompletion)(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stopReason);

// ============================================================================
// AN TOÀN & BỘ NHỚ
// ============================================================================

static void VSAbortActiveTask(NSString *reason);

static void VSGuard(void (^block)(void)) {
    @try { block(); }
    @catch (NSException *e) {
        VSAbortActiveTask([NSString stringWithFormat:@"Dừng an toàn, app báo lỗi: %@", e.reason ?: e.name]);
    }
}

static inline void VSRunOnMain(dispatch_block_t block) {
    if (!block) return;
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
// PRIVATE API DECLARATIONS
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
- (void)makePhotoLayer:(id)img;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show removeOverlayBlending:(BOOL)remove;
@end

// ============================================================================
// MEDIA CACHE AN TOÀN (Dùng lại ảnh/video Đoạn 1 cho Đoạn 2..N)
// ============================================================================

@interface VSCachedSegmentMedia : NSObject
@property (nonatomic, assign) SEL makeSelector;
@property (nonatomic, strong, nullable) id arg1;
@property (nonatomic, strong, nullable) id arg2;
@property (nonatomic, strong, nullable) id arg3;
@property (nonatomic, copy, nullable) NSString *tempVideoPath;
- (void)cleanupTempFile;
@end

@implementation VSCachedSegmentMedia
- (void)cleanupTempFile {
    if (self.tempVideoPath.length) {
        [[NSFileManager defaultManager] removeItemAtPath:self.tempVideoPath error:nil];
        self.tempVideoPath = nil;
    }
}
- (void)dealloc { [self cleanupTempFile]; }
@end

// ============================================================================
// UTILITIES & STATE
// ============================================================================

static NSUInteger g_runIdentifier = 0;
static BOOL g_autoConfirmPopups = NO;
static BOOL g_suppressLayerActionMenu = NO;
static BOOL g_createInProgress = NO;
static BOOL g_dismissLayerMenu = NO;
static BOOL g_vsaAutomating = NO;
static BOOL g_captureFirstMediaEnabled = NO;
static BOOL g_replayingCachedMedia = NO;
static VSCachedSegmentMedia *g_cachedFirstMedia = nil;

static const void *kVSMenuDismissedKey = &kVSMenuDismissedKey;
static const void *kVSPopupHandledKey = &kVSPopupHandledKey;
static NSHashTable *g_activePopupsTable = nil;
static UIWindow *g_overlayToolWindow = nil;
static void (^g_onLayerAddedHandler)(id sender) = nil;

static IMP g_origConfirmAdd4 = NULL;
static IMP g_origConfirmAdd5 = NULL;
static IMP g_origMakePhotoLayer = NULL;

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
    if (longest <= 0) return image;
    CGFloat k = (maxSide > 0 && longest > maxSide) ? (maxSide / longest) : 1.0;
    CGSize target = CGSizeMake(MAX(1.0, floor(s.width * k)), MAX(1.0, floor(s.height * k)));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    fmt.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
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

// ============================================================================
// POPUP RESOLVER (Tự bấm Trùng khớp / OK trong Chức năng 4)
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
        VSTry(^{ if ([popup respondsToSelector:@selector(dismiss)]) [popup dismiss]; });
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
    if (!g_autoConfirmPopups) return VSPopupActionStatusNone;
    NSArray *popups = VSCollectAllVisiblePopups(editorVC);
    if (popups.count == 0) return VSPopupActionStatusNone;

    NSArray *matchNames = @[@"Khớp: rút ngắn/giãn", @"Match: shorten/stretch", @"Trùng khớp", @"Match", @"Vừa khít", @"Fit"];
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
        if (matchBtn) { matchedTitle = matchBtn; }
        else if (VSContains(header, @"Original Preset Layers") || VSContains(header, @"Các lớp Cài đặt sẵn Gốc") ||
                 VSContains(header, VSLocalizedString(@"Original Preset Layers"))) {
            matchedTitle = firstTitleMatching(okNames);
        }
        else if (titles.count == 1) { matchedTitle = firstTitleMatching(okNames); }
        else if (firstTitleMatching(matchFallbackNames) && (VSContains(header, @"dài hơn") || VSContains(header, @"longer"))) {
            matchedTitle = firstTitleMatching(matchFallbackNames);
        }

        if (!matchedTitle) continue;

        objc_setAssociatedObject(popup, kVSPopupHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
// LỚP: QUÉT, CHỮ KÝ, SAO CHÉP & CLONE MEDIA ĐOẠN 1
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

static id VSSafeCloneMediaArg(id obj, NSString **outTempPath) {
    if (!obj || obj == [NSNull null]) return nil;
    if ([obj isKindOfClass:[UIImage class]]) {
        return VSDownscaledImage((UIImage *)obj, 2160.0);
    }
    if ([obj isKindOfClass:[NSURL class]]) {
        NSURL *u = (NSURL *)obj;
        if (u.isFileURL && u.path.length && [[NSFileManager defaultManager] fileExistsAtPath:u.path]) {
            NSString *ext = u.pathExtension.length ? u.pathExtension : @"mov";
            NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"VSTool_Reuse_%lu.%@", (unsigned long)g_runIdentifier, ext]];
            [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
            if ([[NSFileManager defaultManager] copyItemAtPath:u.path toPath:dst error:nil]) {
                if (outTempPath) *outTempPath = dst;
                return [NSURL fileURLWithPath:dst];
            }
        }
        return [u copy];
    }
    if ([obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSString class]] ||
        [obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSDictionary class]] ||
        [obj isKindOfClass:[NSData class]]) {
        return [obj copy];
    }
    return nil;
}

static void VSCaptureMediaIfNeeded(SEL makeSel, id o1, id o2, id o3) {
    if (!g_captureFirstMediaEnabled || g_replayingCachedMedia || !makeSel) return;
    NSString *selName = NSStringFromSelector(makeSel);
    BOOL supported = [selName isEqualToString:@"makePhotoLayer:"] ||
                     [selName isEqualToString:@"makeSelectedClipIndexPhotoLayer:clipIndex:"] ||
                     [selName isEqualToString:@"makeSelectedClipIndexVideoLayer:clipIndex:"] ||
                     [selName isEqualToString:@"makeVideoLayer:frameTimes:volume:"];
    if (!supported) return;

    NSString *tmpPath = nil;
    id c1 = VSSafeCloneMediaArg(o1, &tmpPath);
    id c2 = VSSafeCloneMediaArg(o2, NULL);
    id c3 = VSSafeCloneMediaArg(o3, NULL);
    if (!c1 && !c2) return;

    VSCachedSegmentMedia *m = [VSCachedSegmentMedia new];
    m.makeSelector = makeSel;
    m.arg1 = c1;
    m.arg2 = c2;
    m.arg3 = c3;
    m.tempVideoPath = tmpPath;
    [g_cachedFirstMedia cleanupTempFile];
    g_cachedFirstMedia = m;
}

static void VSCaptureFallbackImageFromLayer(id engine, NSUInteger layerNum) {
    if (g_cachedFirstMedia || !engine) return;
    @autoreleasepool {
        VSTry(^{
            id layer = [engine layerAtLayerNum:layerNum];
            id gen = VSSafeValueForKey(layer, @"imageGenerator");
            id rawImg = VSSafeValueForKey(gen, @"layerImage");
            if ([rawImg isKindOfClass:[UIImage class]]) {
                UIImage *clean = VSDownscaledImage((UIImage *)rawImg, 2160.0);
                if (clean) {
                    VSCachedSegmentMedia *m = [VSCachedSegmentMedia new];
                    m.makeSelector = @selector(makePhotoLayer:);
                    m.arg1 = clean;
                    g_cachedFirstMedia = m;
                }
            }
        });
    }
}

static BOOL VSApplyCachedMediaOnEditor(id editor, VSCachedSegmentMedia *media) {
    if (!editor || !media || !media.makeSelector) return NO;
    SEL sel5 = @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:);
    __block BOOL ok = NO;
    @autoreleasepool {
        g_replayingCachedMedia = YES;
        @try {
            if (g_origConfirmAdd5) {
                ((void (*)(id, SEL, SEL, id, id, id, BOOL))g_origConfirmAdd5)(editor, sel5, media.makeSelector, media.arg1, media.arg2, media.arg3, NO);
                ok = YES;
            } else if ([editor respondsToSelector:sel5]) {
                ((void (*)(id, SEL, SEL, id, id, id, BOOL))objc_msgSend)(editor, sel5, media.makeSelector, media.arg1, media.arg2, media.arg3, NO);
                ok = YES;
            } else if (media.makeSelector == @selector(makePhotoLayer:) && media.arg1 && [editor respondsToSelector:@selector(makePhotoLayer:)]) {
                [editor makePhotoLayer:media.arg1];
                ok = YES;
            }
        } @catch (NSException *__unused e) {
            ok = NO;
        }
        g_replayingCachedMedia = NO;
    }
    return ok;
}

// ============================================================================
// QR STORAGE (Cho Chức năng 2 — Xem code gần nhất)
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
// HOOKS
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

static void VSNotifyLayerAdded(id sender) {
    void (^handler)(id) = g_onLayerAddedHandler;
    if (!handler) return;
    VSGuard(^{ handler(sender); });
}

static void VSInstallCoreHooksOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_activePopupsTable = [NSHashTable weakObjectsHashTable];

        VSRobustSwizzleMethod(@"QRCodeManager", @selector(selectedCode:withImageData:), ^(id selfInstance, id code, id imageData) {
            VSPersistQRCodeImageData(imageData);
            if (g_origSelectedCodeWithImageData)
                ((void (*)(id, SEL, id, id))g_origSelectedCodeWithImageData)(selfInstance, @selector(selectedCode:withImageData:), code, imageData);
        }, &g_origSelectedCodeWithImageData);

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
            if (g_autoConfirmPopups) VSDispatchAfterMS(80, ^{ VSResolvePopupsImmediately(nil); });
        }, &g_origCustomPopupDidMove);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(showLayerActionMenu:newLayer:), ^(id selfInstance, NSUInteger layerNum, BOOL isNewLayer) {
            if (g_suppressLayerActionMenu) return;
            if (g_origShowLayerActionMenu)
                ((void (*)(id, SEL, NSUInteger, BOOL))g_origShowLayerActionMenu)(selfInstance, @selector(showLayerActionMenu:newLayer:), layerNum, isNewLayer);
        }, &g_origShowLayerActionMenu);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(showImportConfirmation), ^BOOL(id selfInstance) {
            if (g_vsaAutomating) return NO;
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
            VSCaptureMediaIfNeeded(makeSel, o1, o2, o3);
            if (g_origConfirmAdd5)
                ((void (*)(id, SEL, SEL, id, id, id, BOOL))g_origConfirmAdd5)(selfInstance, @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:), makeSel, o1, o2, o3, able);
            VSNotifyLayerAdded(selfInstance);
        }, &g_origConfirmAdd5);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmAddingLayer:object:object2:object3:), ^(id selfInstance, SEL makeSel, id o1, id o2, id o3) {
            VSCaptureMediaIfNeeded(makeSel, o1, o2, o3);
            if (g_origConfirmAdd4)
                ((void (*)(id, SEL, SEL, id, id, id))g_origConfirmAdd4)(selfInstance, @selector(confirmAddingLayer:object:object2:object3:), makeSel, o1, o2, o3);
            VSNotifyLayerAdded(selfInstance);
        }, &g_origConfirmAdd4);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(makePhotoLayer:), ^(id selfInstance, id imgObj) {
            VSCaptureMediaIfNeeded(@selector(makePhotoLayer:), imgObj, nil, nil);
            if (g_origMakePhotoLayer)
                ((void (*)(id, SEL, id))g_origMakePhotoLayer)(selfInstance, @selector(makePhotoLayer:), imgObj);
            VSNotifyLayerAdded(selfInstance);
        }, &g_origMakePhotoLayer);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(didReceiveMemoryWarning), ^(id selfInstance) {
            g_memoryWarningAt = CFAbsoluteTimeGetCurrent();
            if (g_origEditorMemWarn) ((void (*)(id, SEL))g_origEditorMemWarn)(selfInstance, @selector(didReceiveMemoryWarning));
        }, &g_origEditorMemWarn);

        VSRobustSwizzleMethod(@"MultiLayerNavController", @selector(didReceiveMemoryWarning), ^(id selfInstance) {
            g_memoryWarningAt = CFAbsoluteTimeGetCurrent();
            if (g_origNavMemWarn) ((void (*)(id, SEL))g_origNavMemWarn)(selfInstance, @selector(didReceiveMemoryWarning));
        }, &g_origNavMemWarn);
    });
}

// ============================================================================
// UI: PREVIEW QR, PROXY QR, WINDOW, MENU 3 NGÓN TAY 2 LẦN
// ============================================================================

@interface VSToolPassThroughWindow : UIWindow
@end
@implementation VSToolPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

static inline UIColor *VSToolAccentColor(void) { return [UIColor colorWithRed:0.86 green:0.71 blue:0.42 alpha:1.0]; }
static inline UIColor *VSToolCardBackgroundColor(void) { return [UIColor colorWithRed:0.075 green:0.065 blue:0.055 alpha:0.96]; }

static UIButton *VSToolCreateOutlineButton(NSString *title, CGRect frame) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.layer.cornerRadius = 8.0;
    btn.layer.borderWidth = 1.2;
    btn.layer.borderColor = VSToolAccentColor().CGColor;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:VSToolAccentColor() forState:UIControlStateNormal];
    [btn setTitleColor:[VSToolAccentColor() colorWithAlphaComponent:0.35] forState:UIControlStateDisabled];
    btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    return btn;
}

@interface VSToolQRCodePreviewVC : UIViewController
@property (nonatomic, strong) UIImage *qrImage;
@end
@implementation VSToolQRCodePreviewVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.90];
    UIImageView *iv = [[UIImageView alloc] initWithImage:self.qrImage];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 14; iv.clipsToBounds = YES;
    iv.frame = CGRectInset(self.view.bounds, 24, 110);
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:iv];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 56, self.view.bounds.size.width, 32)];
    title.text = @"Code gần nhất đã nhập";
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:18];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:title];
    CGFloat w = (self.view.bounds.size.width - 48) / 2.0;
    NSArray *titles = @[@"Đóng", @"Chia sẻ / Lưu"];
    for (NSUInteger i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(24 + i * (w + 12), self.view.bounds.size.height - 84, w - 6, 44);
        b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }
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

// ============================================================================
// VSTOOL INTERFACE
// ============================================================================

@interface VSToolRootVC : UIViewController
@end

@interface VSTool : NSObject
@property (nonatomic, strong) VSToolPassThroughWindow *window;
@property (nonatomic, strong) UIView *menuView;
@property (nonatomic, strong) UILabel *statusHUDLabel;
@property (nonatomic, strong) VSToolQRCodeCaptureProxy *qrCaptureProxy;
@property (nonatomic, strong) NSMutableArray *multiScenePresets;
@property (nonatomic, strong) NSMutableArray *multiSceneCodes;
@property (nonatomic, assign) NSUInteger multiSceneStart;
@property (nonatomic, assign) NSUInteger multiSceneCount;
@property (nonatomic, assign) NSUInteger multiSceneOriginalLastViewed;
@property (nonatomic, assign) NSUInteger multiSceneRunId;
@property (nonatomic, strong) UIView *multiSceneCardView;
@property (nonatomic, copy)   NSString *currentTaskName;
@property (nonatomic, strong) id savedOriginalQRDelegate;
@property (nonatomic, assign) BOOL savedOriginalQRDelegateValid;
@property (nonatomic, weak)   id initialMultiLayerEditorForF4;

+ (instancetype)shared;
- (void)setupToolInterfaceIfNeeded;
- (void)restoreOriginalQRCodeDelegate;
- (void)terminateCurrentTaskQuietly;
- (void)toggleMenu;
- (void)showMenu;
- (void)hideMenuWithCompletion:(void (^)(void))completion;
- (void)handleMenuGesture:(UIGestureRecognizer *)g;
- (void)runMenuFeature:(NSInteger)index;
- (void)stopCurrentTaskFromMenu;
- (void)presentFromTop:(UIViewController *)controller;
- (void)presentController:(UIViewController *)controller retry:(BOOL)retry;
- (void)installMenuGestures;
- (void)attachMenuGestureToView:(id)object;
- (void)showMenuHintOnce;
- (UIViewController *)topPresenterVC;
- (void)updateStatusHUD:(NSString *)message;
- (void)showNotificationAlert:(NSString *)message title:(NSString *)title;
- (UIView *)buildCardContainerWithFrame:(CGRect)frame title:(NSString *)title subtitle:(NSString *)subtitle;
- (NSUInteger)startNewTaskWithDescription:(NSString *)taskName initialStatus:(NSString *)initialStatus;
- (void)finalizeTaskWithMessage:(NSString *)msg;
- (void)showRunResultAlert:(NSString *)msg title:(NSString *)title;
- (void)executeFeature1ReplaceLayers;
- (void)executeFeature2DisplayLastCode;
- (void)executeFeature3AutoSplitBeat;
- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)splitView runId:(NSUInteger)runId;
- (void)executeFeature4BatchMultiScene;
- (void)showProcessingProgressPanel;
- (void)executeBatchProcessingScenesWithRunId:(NSUInteger)runId;
- (void)openMultiLayerEditorForScene:(NSUInteger)sceneIndex reviewVC:(id)reviewVC runId:(NSUInteger)runId completion:(void (^)(id editorVC))done;
- (void)importPresetPayload:(id)preset codeIdentifier:(id)code intoEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
- (void)waitForEditorSettledThenCreate:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
- (void)triggerCreateInEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
@end

// ============================================================================
// MENU 3 NGÓN TAY 2 LẦN
// ============================================================================

static NSString *const kVSMenuGestureName = @"VSToolMenuGesture3x2";
static const CGFloat kVSMenuCorner = 26.0;
static const NSInteger kVSMenuTagStop = 100;
static const NSInteger kVSMenuTagClose = 102;

static inline UIColor *VSMenuChampagne(void) { return [UIColor colorWithRed:0.97 green:0.94 blue:0.87 alpha:1.0]; }

static UIFont *VSMenuDisplayFont(CGFloat size) {
    return [UIFont fontWithName:@"Didot-Bold" size:size] ?: [UIFont boldSystemFontOfSize:size];
}

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

static CAGradientLayer *VSMakeGoldGradient(CGRect frame, CGFloat corner) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = frame;
    g.cornerRadius = corner;
    g.masksToBounds = YES;
    g.colors = @[(id)[UIColor colorWithRed:1.00 green:0.90 blue:0.64 alpha:1.0].CGColor,
                 (id)[UIColor colorWithRed:0.66 green:0.48 blue:0.20 alpha:1.0].CGColor];
    g.startPoint = CGPointMake(0.0, 0.0);
    g.endPoint = CGPointMake(1.0, 1.0);
    return g;
}

static UIView *VSMakeDivider(CGRect frame) {
    UIView *d = [[UIView alloc] initWithFrame:frame];
    d.userInteractionEnabled = NO;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
    g.startPoint = CGPointMake(0.0, 0.5);
    g.endPoint = CGPointMake(1.0, 0.5);
    UIColor *gold = VSToolAccentColor();
    g.colors = @[(id)[gold colorWithAlphaComponent:0.0].CGColor,
                 (id)gold.CGColor,
                 (id)[gold colorWithAlphaComponent:0.0].CGColor];
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
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:(highlighted ? 0.10 : 0.05)];
    } completion:nil];
}
@end

@interface VSToolMenuView : UIView
- (void)showAnimated;
- (void)hideAnimatedWithCompletion:(void (^)(void))completion;
- (void)buildPanel;
- (UIButton *)pillWithTitle:(NSString *)title color:(UIColor *)color frame:(CGRect)frame;
- (VSToolMenuRowControl *)rowWithIndex:(NSInteger)index title:(NSString *)title subtitle:(NSString *)subtitle frame:(CGRect)frame;
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
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.30];
    [dim addTarget:self action:@selector(dimTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:dim];

    [self buildPanel];
    return self;
}

- (void)buildPanel {
    VSTool *tool = [VSTool shared];
    BOOL running = tool.currentTaskName.length > 0;

    CGFloat W = self.bounds.size.width;
    CGFloat pw = MIN(W - 40.0, 360.0);
    CGFloat inner = 22.0;
    CGFloat cw = pw - inner * 2.0;

    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, 100)];
    _panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                              UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    _panel.layer.borderWidth = 1.0;
    _panel.layer.borderColor = [VSToolAccentColor() colorWithAlphaComponent:0.45].CGColor;
    _panel.layer.shadowColor = UIColor.blackColor.CGColor;
    _panel.layer.shadowOpacity = 0.7;
    _panel.layer.shadowRadius = 30.0;
    _panel.layer.shadowOffset = CGSizeMake(0, 18);
    [self addSubview:_panel];

    UIFont *kickerFont = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    CGFloat y = 20.0;

    UILabel *kicker = VSMenuMakeLabel(CGRectMake(inner, y, cw, 14), nil, kickerFont, VSToolAccentColor(), NSTextAlignmentCenter);
    kicker.attributedText = VSLetterSpaced(@"VIDEO STAR TURBO", 3.0, VSToolAccentColor(), kickerFont);
    [_panel addSubview:kicker];
    y += 22.0;

    UILabel *title = VSMenuMakeLabel(CGRectMake(inner, y, cw, 32), @"VideoStarTool", VSMenuDisplayFont(25), VSMenuChampagne(), NSTextAlignmentCenter);
    [_panel addSubview:title];
    y += 36.0;

    UILabel *sub = VSMenuMakeLabel(CGRectMake(inner, y, cw, 16), @"Chạm 3 ngón 2 lần để mở hoặc đóng menu",
                                   [UIFont systemFontOfSize:11.5], [UIColor colorWithWhite:1.0 alpha:0.55], NSTextAlignmentCenter);
    [_panel addSubview:sub];
    y += 26.0;

    [_panel addSubview:VSMakeDivider(CGRectMake(inner, y, cw, 1))];
    y += 16.0;

    CGFloat cardH = 56.0;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(inner, y, cw, cardH)];
    card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    card.layer.cornerRadius = 16.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [VSToolAccentColor() colorWithAlphaComponent:0.22].CGColor;
    [_panel addSubview:card];

    UIFont *capFont = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    UILabel *cap = VSMenuMakeLabel(CGRectMake(16, 10, cw - 120, 14), nil, capFont, VSToolAccentColor(), NSTextAlignmentLeft);
    if (running) {
        cap.attributedText = VSLetterSpaced(@"ĐANG CHẠY", 2.0, VSToolAccentColor(), capFont);
        UILabel *name = VSMenuMakeLabel(CGRectMake(16, 27, cw - 120, 20), tool.currentTaskName,
                                        [UIFont systemFontOfSize:14 weight:UIFontWeightMedium], [UIColor colorWithWhite:1.0 alpha:0.92], NSTextAlignmentLeft);
        [card addSubview:name];
        UIButton *stop = [self pillWithTitle:@"Dừng" color:[UIColor colorWithRed:1.0 green:0.56 blue:0.52 alpha:1.0]
                                       frame:CGRectMake(cw - 16 - 80, (cardH - 32) / 2.0, 80, 32)];
        stop.tag = kVSMenuTagStop;
        [stop addTarget:self action:@selector(menuControlTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:stop];
    } else {
        cap.attributedText = VSLetterSpaced(@"SẴN SÀNG", 2.0, VSToolAccentColor(), capFont);
        UILabel *hint = VSMenuMakeLabel(CGRectMake(16, 27, cw - 32, 20), @"Chọn một chức năng bên dưới",
                                        [UIFont systemFontOfSize:13], [UIColor colorWithWhite:1.0 alpha:0.7], NSTextAlignmentLeft);
        [card addSubview:hint];
    }
    [card addSubview:cap];
    y += cardH + 12.0;

    NSArray<NSArray<NSString *> *> *items = @[
        @[@"Auto nhập ảnh siêu tốc (x10)", @"Chọn 1 ảnh/video, copy siêu nhanh sang mọi lớp"],
        @[@"Hiển thị code gần nhất", @"Xem lại mã QR vừa nhập"],
        @[@"Auto chia beat", @"Tự chia phân cảnh theo nhịp"],
        @[@"Auto QR + ảnh hàng loạt", @"Chọn không giới hạn QR -> tự căn đoạn & dùng chung ảnh Đoạn 1"]
    ];
    CGFloat rowH = 54.0, gap = 8.0;
    for (NSUInteger i = 0; i < items.count; i++) {
        VSToolMenuRowControl *row = [self rowWithIndex:(NSInteger)(i + 1) title:items[i][0] subtitle:items[i][1]
                                                 frame:CGRectMake(inner, y, cw, rowH)];
        [row addTarget:self action:@selector(menuControlTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:row];
        y += rowH + gap;
    }
    y += 4.0;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(inner, y, cw, 44);
    close.layer.cornerRadius = 14.0;
    close.layer.borderWidth = 1.0;
    close.layer.borderColor = VSToolAccentColor().CGColor;
    [close setTitle:@"Đóng" forState:UIControlStateNormal];
    [close setTitleColor:VSToolAccentColor() forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    close.tag = kVSMenuTagClose;
    [close addTarget:self action:@selector(menuControlTapped:forEvent:) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:close];
    y += 44.0 + 22.0;

    CGFloat ph = y;
    _panel.frame = CGRectMake(0, 0, pw, ph);
    _panel.center = CGPointMake(W / 2.0, self.bounds.size.height / 2.0);
    _panel.layer.cornerRadius = kVSMenuCorner;
    _panel.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_panel.bounds cornerRadius:kVSMenuCorner].CGPath;

    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.frame = CGRectInset(_panel.bounds, 1.0, 1.0);
    bg.cornerRadius = kVSMenuCorner - 1.0;
    bg.masksToBounds = YES;
    bg.colors = @[(id)[UIColor colorWithRed:0.12 green:0.105 blue:0.09 alpha:1.0].CGColor,
                  (id)[UIColor colorWithRed:0.035 green:0.035 blue:0.045 alpha:1.0].CGColor];
    bg.startPoint = CGPointMake(0.5, 0.0);
    bg.endPoint = CGPointMake(0.5, 1.0);
    [_panel.layer insertSublayer:bg atIndex:0];
}

- (UIButton *)pillWithTitle:(NSString *)title color:(UIColor *)color frame:(CGRect)frame {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.layer.cornerRadius = frame.size.height / 2.0;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [color colorWithAlphaComponent:0.7].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:color forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    return b;
}

- (VSToolMenuRowControl *)rowWithIndex:(NSInteger)index title:(NSString *)title subtitle:(NSString *)subtitle frame:(CGRect)frame {
    VSToolMenuRowControl *row = [[VSToolMenuRowControl alloc] initWithFrame:frame];
    row.tag = index;
    row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
    row.layer.cornerRadius = 16.0;
    row.layer.borderWidth = 1.0;
    row.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    CGFloat d = 36.0;
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(14, (frame.size.height - d) / 2.0, d, d)];
    badge.userInteractionEnabled = NO;
    badge.layer.cornerRadius = d / 2.0;
    badge.clipsToBounds = YES;
    [badge.layer insertSublayer:VSMakeGoldGradient(CGRectMake(0, 0, d, d), d / 2.0) atIndex:0];
    UILabel *num = VSMenuMakeLabel(CGRectMake(0, 0, d, d), [NSString stringWithFormat:@"%ld", (long)index],
                                   VSMenuDisplayFont(17), [UIColor colorWithRed:0.10 green:0.07 blue:0.03 alpha:1.0],
                                   NSTextAlignmentCenter);
    [badge addSubview:num];
    [row addSubview:badge];

    CGFloat tx = 14.0 + d + 14.0;
    CGFloat tw = frame.size.width - tx - 40.0;
    UILabel *t = VSMenuMakeLabel(CGRectMake(tx, 10, tw, 20), title,
                                 [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold], VSMenuChampagne(), NSTextAlignmentLeft);
    UILabel *s = VSMenuMakeLabel(CGRectMake(tx, 30, tw, 16), subtitle,
                                 [UIFont systemFontOfSize:11.5], [UIColor colorWithWhite:1.0 alpha:0.5], NSTextAlignmentLeft);
    [row addSubview:t];
    [row addSubview:s];

    UILabel *chev = VSMenuMakeLabel(CGRectMake(frame.size.width - 34, (frame.size.height - 26) / 2.0, 20, 26), @"›",
                                    [UIFont systemFontOfSize:24 weight:UIFontWeightLight], VSToolAccentColor(), NSTextAlignmentCenter);
    chev.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:chev];
    return row;
}

- (void)showAnimated {
    self.alpha = 0.0;
    _panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.84 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.alpha = 1.0;
        self->_panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)hideAnimatedWithCompletion:(void (^)(void))completion {
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.alpha = 0.0;
        self->_panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
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
// VSLayerFiller: LOGIC VÀO PHẦN NHẬP ẢNH CHUẨN V4 + COPY SIÊU NHANH X10
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
@property (nonatomic, assign) NSInteger pickOutcome;   // 0 chờ, 1 đã chọn, 2 huỷ, 3 popup Pro
@property (nonatomic, assign) BOOL requirePickerOpen;
@property (nonatomic, assign) BOOL captureForNextScenes;
@property (nonatomic, strong, nullable) VSCachedSegmentMedia *reuseMedia;

+ (void)fillLayers:(NSArray<NSNumber *> *)layers
            editor:(id)editor
             runId:(NSUInteger)runId
 requirePickerOpen:(BOOL)requirePicker
captureForNextScenes:(BOOL)captureForNext
        reuseMedia:(nullable VSCachedSegmentMedia *)reuseMedia
        completion:(VSFillCompletion)completion;
@end

static VSLayerFiller *g_activeFiller = nil;

@implementation VSLayerFiller

+ (void)fillLayers:(NSArray<NSNumber *> *)layers
            editor:(id)editor
             runId:(NSUInteger)runId
 requirePickerOpen:(BOOL)requirePicker
captureForNextScenes:(BOOL)captureForNext
        reuseMedia:(nullable VSCachedSegmentMedia *)reuseMedia
        completion:(VSFillCompletion)completion {
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
    f.captureForNextScenes = captureForNext;
    f.reuseMedia = reuseMedia;
    g_vsaAutomating = YES;
    g_suppressLayerActionMenu = YES;
    g_activeFiller = f;

    if (reuseMedia) {
        [f applyReusedMediaToSource];
    } else {
        [f selectSourceAndPick];
    }
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
    g_captureFirstMediaEnabled = NO;
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

// Chọn lớp chuẩn v4 cho bước đầu mở picker
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

// Chọn lớp siêu tốc cho vòng lặp copy x10
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

#pragma mark - Đoạn 2..N: Tự nạp ảnh đã chọn từ Đoạn 1 (KHÔNG mở bảng chọn ảnh)

- (void)applyReusedMediaToSource {
    [self selectLayerV4:self.source then:^(BOOL ok) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!ok) { [self finishWithStop:@"Không chọn được lớp nguồn"]; return; }

        VSDispatchAfterMS(80, ^{
            if (![self alive]) { [self finishWithStop:nil]; return; }
            id ed = self.editor;
            if (!VSEditorIsAlive(ed)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }

            NSString *before = VSLayerSignature(VSEngineFrom(ed), self.source) ?: @"";
            if (!VSApplyCachedMediaOnEditor(ed, self.reuseMedia)) {
                self.reuseMedia = nil;
                [self openPicker];
                return;
            }

            // Chờ tối đa 3s để xác nhận tự nạp; nếu media không hợp lệ sẽ tự mở bảng chọn ảnh thay vì treo
            VSSafePollEditor(self.runId, 30, 100, [self provider], ^BOOL(id e) {
                if (VSPurchasePopupVisible(e)) return YES;
                if (g_autoConfirmPopups) VSResolvePopupsImmediately(e);
                if (VSEditorIsBusy(e)) return NO;
                id eng = VSEngineFrom(e);
                NSString *now = VSLayerSignature(eng, self.source) ?: @"";
                return VSLayerAssetLoaded(eng, self.source) && now.length > 0 && ![now isEqualToString:before];
            }, ^(BOOL loaded) {
                if (![self alive]) { [self finishWithStop:nil]; return; }
                if (VSPurchasePopupVisible(self.editor)) { [self finishWithStop:@"Popup mua Pro"]; return; }
                if (!loaded) {
                    self.reuseMedia = nil;
                    [self openPicker];
                    return;
                }
                [self copyNext];
            });
        });
    }];
}

#pragma mark - ĐÚNG LOGIC V4 VÀO PHẦN NHẬP HÌNH ẢNH (selectSourceAndPick -> openPicker -> pickConditionOn)

- (void)selectSourceAndPick {
    [self selectLayerV4:self.source then:^(BOOL ok) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!ok) { [self finishWithStop:@"Không chọn được lớp nguồn"]; return; }
        VSDispatchAfterMS(250, ^{ [self openPicker]; });
    }];
}

- (void)openPicker {
    if (![self alive]) { [self finishWithStop:nil]; return; }
    id ed = self.editor;
    if (!VSEditorIsAlive(ed)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }
    if (![ed respondsToSelector:@selector(pickNewContent)]) { [self finishWithStop:@"Không tìm thấy pickNewContent"]; return; }

    self.beforeSignature = VSLayerSignature(VSEngineFrom(ed), self.source) ?: @"";
    self.pickerSeenOpen = NO;
    self.pickerConfirmed = NO;
    self.pickerClosedAt = 0;
    self.pickOutcome = 0;

    if (self.captureForNextScenes) {
        [g_cachedFirstMedia cleanupTempFile];
        g_cachedFirstMedia = nil;
        g_captureFirstMediaEnabled = YES;
    }

    __weak VSLayerFiller *wSelf = self;
    g_onLayerAddedHandler = ^(id sender) {
        VSLayerFiller *s = wSelf;
        if (!s || sender != s.editor) return;
        s.pickerConfirmed = YES;
    };

    BOOL opened = VSTry(^{ [ed pickNewContent]; });
    if (!opened) { [self finishWithStop:@"Không mở được bảng chọn media"]; return; }

    VSSafePollEditor(self.runId, 200, 900, [self provider], ^BOOL(id e) {
        return [self pickConditionOn:e];
    }, ^(BOOL ok) {
        [self afterPickWait];
    });
}

- (BOOL)pickConditionOn:(id)ed {
    UIViewController *vc = (UIViewController *)ed;
    BOOL open = vc.presentedViewController != nil || vc.navigationController.presentedViewController != nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (open) {
        self.pickerSeenOpen = YES;
        self.pickerClosedAt = 0;
        return NO;
    }
    if (VSPurchasePopupVisible(ed)) { self.pickOutcome = 3; return YES; }

    id engine = VSEngineFrom(ed);
    NSString *sig = VSLayerSignature(engine, self.source) ?: @"";
    BOOL changed = sig.length > 0 && ![sig isEqualToString:(self.beforeSignature ?: @"")];
    BOOL pickedSignal = self.pickerConfirmed || changed;
    BOOL pickerOK = !self.requirePickerOpen || self.pickerSeenOpen;
    if (pickedSignal && pickerOK && VSLayerAssetLoaded(engine, self.source) && !VSEditorIsBusy(ed)) {
        self.pickOutcome = 1;
        return YES;
    }
    if (self.pickerSeenOpen) {
        if (self.pickerClosedAt == 0) self.pickerClosedAt = now;
        if (now - self.pickerClosedAt > 2.5) { self.pickOutcome = 2; return YES; }
    }
    return NO;
}

- (void)afterPickWait {
    g_onLayerAddedHandler = nil;
    g_captureFirstMediaEnabled = NO;
    if (![self alive]) { [self finishWithStop:nil]; return; }
    switch (self.pickOutcome) {
        case 1:
            if (self.captureForNextScenes && !g_cachedFirstMedia && self.editor) {
                VSCaptureFallbackImageFromLayer(VSEngineFrom(self.editor), self.source);
            }
            [self copyNext];
            break;
        case 2: [self finishWithStop:@"Đã huỷ (chưa chọn media)"]; break;
        case 3: [self finishWithStop:@"Popup mua Pro"]; break;
        default: [self finishWithStop:@"Quá thời gian chọn media"]; break;
    }
}

#pragma mark - Copy Siêu Nhanh x10 Sang Tất Cả Các Lớp Còn Lại (Giữ nguyên copyLayer:)

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
        [self selectLayerTurbo:self.source then:^(BOOL ok) {
            id eFinal = self.editor;
            if (eFinal) {
                VSTry(^{ if ([eFinal respondsToSelector:@selector(refreshDisplay)]) [eFinal refreshDisplay]; });
            }
            [self finishWithStop:nil];
        }];
        return;
    }

    NSUInteger target = [self.layers[self.nextIndex] unsignedIntegerValue];
    [[VSTool shared] updateStatusHUD:[NSString stringWithFormat:@"⚡ Chép siêu tốc lớp %lu (%lu/%lu)…",
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

        if (!VSFireCopyLayer(e2, eng2, self.source)) {
            [self skipTarget:target];
            return;
        }

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
        if (g_autoConfirmPopups) VSResolvePopupsImmediately(e);
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
@end

// ============================================================================
// GIẢI MÃ HÀNG LOẠT QR & NẠP CHO CHỨC NĂNG 4
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
    CIImage *base = image.CGImage ? [CIImage imageWithCGImage:image.CGImage] : [[CIImage alloc] initWithImage:image];
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
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(id obj, NSError *err) {
            @synchronized (images) {
                images[i] = [obj isKindOfClass:[UIImage class]] ? obj : [NSNull null];
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{ done([images copy]); });
}

static void VSImportBatchCodesAndRun(VSTool *tool, NSArray *images, NSUInteger runId) {
    NSUInteger count = images.count;
    [tool updateStatusHUD:[NSString stringWithFormat:@"Đang giải mã %lu ảnh QR…", (unsigned long)count]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *decodedCodes = [NSMutableArray arrayWithCapacity:count];
        NSMutableArray *decodedPNGs = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            [decodedCodes addObject:[NSNull null]];
            [decodedPNGs addObject:[NSNull null]];
        }

        dispatch_apply(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            @autoreleasepool {
                id obj = images[i];
                UIImage *img = [obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
                NSString *code = VSDecodeQRRobust(img);
                if (code.length && ([code hasPrefix:@"m"] || [code hasPrefix:@"n"])) {
                    NSData *png = UIImagePNGRepresentation(VSDownscaledImage(img, 1024.0));
                    @synchronized (decodedCodes) {
                        decodedCodes[i] = code;
                        if (png) decodedPNGs[i] = png;
                    }
                }
            }
        });

        VSRunOnMain(^{
            if (runId != g_runIdentifier) return;
            for (NSUInteger i = 0; i < count; i++) {
                if (decodedCodes[i] == [NSNull null]) {
                    [tool finalizeTaskWithMessage:[NSString stringWithFormat:@"Ảnh thứ %lu không đọc được mã QR Video Star hợp lệ.", (unsigned long)(i + 1)]];
                    return;
                }
            }

            __weak VSTool *wTool = tool;
            __block NSUInteger idx = 0;
            __block void (^step)(void) = nil;

            step = ^{
                VSTool *t = wTool;
                if (!t || runId != g_runIdentifier) { step = nil; return; }
                if (idx >= count) {
                    step = nil;
                    [t restoreOriginalQRCodeDelegate];
                    t.qrCaptureProxy = nil;
                    g_autoConfirmPopups = YES;
                    [t showProcessingProgressPanel];
                    [t executeBatchProcessingScenesWithRunId:runId];
                    return;
                }

                NSUInteger i = idx;
                Class qc = NSClassFromString(@"QRCodeManager");
                id qr = [qc respondsToSelector:@selector(sharedInstance)] ? [qc sharedInstance] : nil;
                if (!qr || ![qr respondsToSelector:@selector(selectedCode:withImageData:)]) {
                    step = nil;
                    [t finalizeTaskWithMessage:@"Không tìm thấy QRCodeManager"];
                    return;
                }
                if (!t.savedOriginalQRDelegateValid) {
                    t.savedOriginalQRDelegate = VSSafeValueForKey(qr, @"delegate");
                    t.savedOriginalQRDelegateValid = YES;
                }
                [t updateStatusHUD:[NSString stringWithFormat:@"Nạp dữ liệu QR %lu/%lu…", (unsigned long)(i + 1), (unsigned long)count]];

                __block BOOL got = NO;
                VSToolQRCodeCaptureProxy *proxy = [VSToolQRCodeCaptureProxy new];
                proxy.onCodeCapturedBlock = ^(id preset, id codeId) {
                    VSTool *s = wTool;
                    if (!s || got || runId != g_runIdentifier) return;
                    if (!preset || ![codeId isKindOfClass:[NSString class]]) return;
                    got = YES;
                    s.multiScenePresets[i] = preset;
                    s.multiSceneCodes[i] = codeId;
                    idx = i + 1;
                    VSDispatchAfterMS(150, ^{ if (step) step(); });
                };
                t.qrCaptureProxy = proxy;
                VSSetQRDelegateSafely(qr, proxy);
                NSData *png = (decodedPNGs[i] != [NSNull null]) ? decodedPNGs[i] : nil;
                VSTry(^{ [qr selectedCode:decodedCodes[i] withImageData:png]; });

                VSDispatchAfterMS(7000, ^{
                    if (got || runId != g_runIdentifier) return;
                    got = YES;
                    step = nil;
                    VSTool *tErr = wTool;
                    if (tErr) [tErr finalizeTaskWithMessage:[NSString stringWithFormat:@"App không nhận được mã của ảnh thứ %lu.", (unsigned long)(i + 1)]];
                });
            };
            step();
        });
    });
}

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
    hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.84];
    hud.textColor = UIColor.whiteColor;
    hud.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    hud.textAlignment = NSTextAlignmentCenter;
    hud.numberOfLines = 2;
    hud.layer.cornerRadius = 10; hud.clipsToBounds = YES; hud.hidden = YES;
    [root.view addSubview:hud];

    self.window = w;
    self.statusHUDLabel = hud;
    g_overlayToolWindow = w;
    w.hidden = NO;
    VSInstallCoreHooksOnce();
    [self installMenuGestures];
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
        VSDispatchAfterMS(250, ^{ [self presentController:controller retry:NO]; });
    }
}

- (void)updateStatusHUD:(NSString *)msg {
    UIView *c = self.window.rootViewController.view;
    self.statusHUDLabel.text = msg;
    CGFloat w = MIN(c.bounds.size.width - 32, 440);
    self.statusHUDLabel.frame = CGRectMake((c.bounds.size.width - w) / 2.0, c.safeAreaInsets.top + 8, w, 40);
    self.statusHUDLabel.hidden = (msg.length == 0);
}

- (void)showNotificationAlert:(NSString *)msg title:(NSString *)title {
    [self updateStatusHUD:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title ?: @"VideoStarTool" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentFromTop:a];
}

- (UIView *)buildCardContainerWithFrame:(CGRect)f title:(NSString *)title subtitle:(NSString *)subtitle {
    UIView *card = [[UIView alloc] initWithFrame:f];
    card.backgroundColor = VSToolCardBackgroundColor();
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = 1.2;
    card.layer.borderColor = VSToolAccentColor().CGColor;
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, f.size.width - 32, 24)];
    h.text = title; h.textColor = VSToolAccentColor(); h.font = [UIFont boldSystemFontOfSize:17];
    h.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, f.size.width - 32, 36)];
    s.text = subtitle; s.numberOfLines = 0; s.textColor = [UIColor colorWithWhite:0.86 alpha:1.0]; s.font = [UIFont systemFontOfSize:13];
    s.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:h]; [card addSubview:s];
    return card;
}

- (void)installMenuGestures {
    [self attachMenuGestureToView:self.window.rootViewController.view];
    for (UIWindow *w in VSAllWindows()) [self attachMenuGestureToView:w];
    [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeVisibleNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        [self attachMenuGestureToView:note.object];
    }];
    [self showMenuHintOnce];
}

- (void)attachMenuGestureToView:(id)object {
    if (![object isKindOfClass:[UIView class]]) return;
    UIView *view = (UIView *)object;
    if (view == g_overlayToolWindow || view.hidden) return;
    NSString *cn = NSStringFromClass([view class]);
    if ([cn containsString:@"Keyboard"] || [cn containsString:@"TextEffects"]) return;
    for (UIGestureRecognizer *g in view.gestureRecognizers) {
        if ([g.name isEqualToString:kVSMenuGestureName]) return;
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuGesture:)];
    tap.numberOfTouchesRequired = 3;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.name = kVSMenuGestureName;
    [view addGestureRecognizer:tap];
}

- (void)handleMenuGesture:(UIGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) [self toggleMenu];
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
    [self showNotificationAlert:@"Đã dừng" title:@"Đã Dừng"];
}

- (void)showMenuHintOnce {
    static BOOL shown = NO;
    if (shown) return;
    shown = YES;
    NSString *hint = @"Chạm 3 ngón 2 lần để mở menu";
    [self updateStatusHUD:hint];
    VSDispatchAfterMS(3000, ^{
        if (!self.currentTaskName && [self.statusHUDLabel.text isEqualToString:hint]) [self updateStatusHUD:nil];
    });
}

- (NSUInteger)startNewTaskWithDescription:(NSString *)name initialStatus:(NSString *)status {
    g_runIdentifier++;
    g_autoConfirmPopups = NO;
    g_suppressLayerActionMenu = NO;
    g_dismissLayerMenu = YES;
    g_createInProgress = NO;
    g_vsaAutomating = NO;
    g_captureFirstMediaEnabled = NO;
    g_onLayerAddedHandler = nil;
    [g_cachedFirstMedia cleanupTempFile];
    g_cachedFirstMedia = nil;
    self.initialMultiLayerEditorForF4 = nil;
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
    g_captureFirstMediaEnabled = NO;
    g_onLayerAddedHandler = nil;
    g_activeFiller = nil;
    [g_cachedFirstMedia cleanupTempFile];
    g_cachedFirstMedia = nil;
    self.initialMultiLayerEditorForF4 = nil;
    [self restoreOriginalQRCodeDelegate];
    [self.multiSceneCardView removeFromSuperview];
    self.multiSceneCardView = nil;
    self.qrCaptureProxy = nil;
    self.currentTaskName = nil;
    [self updateStatusHUD:nil];
}

- (void)finalizeTaskWithMessage:(NSString *)msg {
    [self terminateCurrentTaskQuietly];
    if (msg.length) [self showRunResultAlert:msg title:@"VideoStarTool"];
}

- (void)showRunResultAlert:(NSString *)msg title:(NSString *)title {
    [self updateStatusHUD:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title ?: @"VideoStarTool" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentFromTop:a];
}

// ============================================================================
// CHỨC NĂNG 1: Auto nhập ảnh siêu tốc x10
// ============================================================================

- (void)executeFeature1ReplaceLayers {
    id editor = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
    if (!editor) { [self showNotificationAlert:@"Vào màn hình Nhiều lớp trước." title:@"Chưa ở Nhiều lớp"]; return; }

    NSArray<NSNumber *> *layers = VSDetectFillableLayers(VSEngineFrom(editor), NO);
    if (layers.count == 0) { [self showNotificationAlert:@"Không có lớp video/ảnh nào để thay." title:@"Không có lớp"]; return; }

    NSUInteger runId = [self startNewTaskWithDescription:@"Auto nhập ảnh x10" initialStatus:@"Chọn 1 ảnh/video…"];
    [VSLayerFiller fillLayers:layers
                       editor:editor
                        runId:runId
            requirePickerOpen:NO
         captureForNextScenes:NO
                   reuseMedia:nil
                   completion:^(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stop) {
        if (runId != g_runIdentifier) return;
        NSString *msg = VSFillSummary(copied, targets, unconfirmed, stop);
        VSDispatchAfterMS(150, ^{ [self finalizeTaskWithMessage:msg]; });
    }];
}

// ============================================================================
// CHỨC NĂNG 2: Xem code gần nhất
// ============================================================================

- (void)executeFeature2DisplayLastCode {
    UIImage *img = VSReadLastPersistedQRCodeImage();
    if (!img) { [self showNotificationAlert:@"Chưa có QR nào" title:@"Chưa có"]; return; }
    if (!VSDecodeQRCodeMessageFromImage(img)) { [self showNotificationAlert:@"QR không hợp lệ" title:@"Lỗi"]; return; }
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
    if (!reviewVC) { [self showNotificationAlert:@"Vào màn hình Review trước." title:@"Sai vị trí"]; return; }
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

    VSSafePoll(runId, 80, 40, ^BOOL{ return svVisible(); }, ^(BOOL ok) {
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
        VSSafePoll(runId, 100, 180, ^BOOL{
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
            VSDispatchAfterMS(15, ^{ if (step) step(); });
        });
    };
    VSDispatchAfterMS(200, ^{ if (step) step(); });
}

// ============================================================================
// CHỨC NĂNG 4: Chọn KHÔNG GIỚI HẠN QR -> Tự căn số đoạn -> Dùng chung ảnh Đoạn 1
// ============================================================================

- (void)executeFeature4BatchMultiScene {
    id mlEditor = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");

    if (!mlEditor && !reviewVC) {
        [self showNotificationAlert:@"Vào màn hình Kết hợp (Nhiều lớp) hoặc màn hình Phân cảnh trước." title:@"Sai vị trí"];
        return;
    }

    __block NSUInteger startScene = 0;
    __block NSUInteger origScene = 0;

    if (mlEditor) {
        VSTry(^{
            id nav = [mlEditor navigationController];
            if ([nav respondsToSelector:@selector(navSceneIndex)]) {
                startScene = [nav navSceneIndex];
            } else if ([mlEditor respondsToSelector:@selector(sceneIndex)]) {
                startScene = [mlEditor sceneIndex];
            }
            origScene = startScene;
        });
    } else if (reviewVC) {
        VSTry(^{
            origScene = [reviewVC lastViewedSceneIndex];
            id sObj = VSSafeValueForKey(reviewVC, @"startScene");
            NSInteger mergeStart = [sObj respondsToSelector:@selector(integerValue)] ? [sObj integerValue] : -1;
            if (mergeStart >= 0) {
                startScene = (NSUInteger)mergeStart;
            } else if ([reviewVC respondsToSelector:@selector(sceneIndex)]) {
                startScene = [reviewVC sceneIndex];
            } else {
                startScene = origScene;
            }
            [reviewVC closeMergePanel];
        });
    }

    NSUInteger runId = [self startNewTaskWithDescription:@"Auto QR + ảnh x10"
                                           initialStatus:@"Chọn ảnh QR (không giới hạn số lượng)…"];
    self.multiSceneStart = startScene;
    self.multiSceneOriginalLastViewed = origScene;
    self.multiSceneRunId = runId;
    self.initialMultiLayerEditorForF4 = mlEditor;

    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = 0; // KHÔNG GIỚI HẠN số lượng ảnh QR chọn
        cfg.filter = [PHPickerFilter imagesFilter];
        if (@available(iOS 15.0, *)) {
            cfg.selection = PHPickerConfigurationSelectionOrdered;
        }

        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        VSQRBatchPickerDelegate *del = [VSQRBatchPickerDelegate new];
        __weak VSTool *wSelf = self;
        del.onPicked = ^(NSArray<PHPickerResult *> *results) {
            g_qrBatchPickerDelegate = nil;
            VSTool *s = wSelf;
            if (!s || runId != g_runIdentifier) return;
            if (results.count == 0) {
                [s terminateCurrentTaskQuietly];
                return;
            }

            NSUInteger pickedCount = results.count;
            s.multiSceneCount = pickedCount;
            s.multiScenePresets = [NSMutableArray arrayWithCapacity:pickedCount];
            s.multiSceneCodes = [NSMutableArray arrayWithCapacity:pickedCount];
            for (NSUInteger i = 0; i < pickedCount; i++) {
                [s.multiScenePresets addObject:[NSNull null]];
                [s.multiSceneCodes addObject:[NSNull null]];
            }

            VSLoadPickedImages(results, ^(NSArray *images) {
                if (runId != g_runIdentifier) return;
                VSImportBatchCodesAndRun(s, images, runId);
            });
        };
        g_qrBatchPickerDelegate = del;
        pk.delegate = del;
        [self presentFromTop:pk];
    } else {
        [self finalizeTaskWithMessage:@"Cần iOS 14 trở lên để chọn nhiều ảnh QR"];
    }
}

- (void)showProcessingProgressPanel {
    [self.multiSceneCardView removeFromSuperview];
    UIView *c = self.window.rootViewController.view;
    CGFloat w = MIN(c.bounds.size.width - 24, 460), h = 112;
    UIView *card = [self buildCardContainerWithFrame:CGRectMake((c.bounds.size.width - w) / 2.0,
                                                                c.bounds.size.height - c.safeAreaInsets.bottom - h - 60,
                                                                w, h)
                                               title:[NSString stringWithFormat:@"Đang chạy %lu phân cảnh", (unsigned long)self.multiSceneCount]
                                            subtitle:@"Đoạn 1 chọn ảnh 1 lần -> Đoạn 2..N tự dùng lại ảnh đó & copy x10"];
    card.userInteractionEnabled = NO;
    [c addSubview:card];
    self.multiSceneCardView = card;
}

- (void)executeBatchProcessingScenesWithRunId:(NSUInteger)runId {
    NSUInteger start = self.multiSceneStart;
    NSUInteger total = self.multiSceneCount;
    NSUInteger orig = self.multiSceneOriginalLastViewed;
    NSArray *presets = [self.multiScenePresets copy];
    NSArray *codes = [self.multiSceneCodes copy];
    __block NSUInteger offset = 0, okCount = 0;
    __block void (^step)(void) = nil;

    void (^finish)(NSString *) = ^(NSString *err) {
        step = nil;
        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        VSTry(^{ [rvc setLastViewedSceneIndex:orig]; });
        [self terminateCurrentTaskQuietly];
        NSString *msg = [NSString stringWithFormat:@"Xong %lu/%lu phân cảnh", (unsigned long)okCount, (unsigned long)total];
        NSString *full = err ? [err stringByAppendingFormat:@"\n%@", msg] : msg;
        [self showRunResultAlert:full title:err ? @"Dừng" : @"Thành công"];
    };

    step = ^{
        if (runId != g_runIdentifier) { step = nil; return; }
        if (offset >= total) { finish(nil); return; }

        NSUInteger o = offset++, sc = start + o;

        id rvcCheck = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        if (rvcCheck) {
            __block NSUInteger projectScenes = NSUIntegerMax;
            VSTry(^{
                id<ProjectInterface> proj = [rvcCheck project];
                if (proj) projectScenes = [proj sceneCount];
            });
            if (projectScenes != NSUIntegerMax && sc >= projectScenes) {
                finish(nil);
                return;
            }
        }

        NSString *label = [NSString stringWithFormat:@"Đoạn %lu (%lu/%lu)", (unsigned long)(sc + 1), (unsigned long)(o + 1), (unsigned long)total];
        [self updateStatusHUD:[label stringByAppendingString:@": mở…"]];

        void (^runOnEditor)(id) = ^(id editor) {
            if (runId != g_runIdentifier) { step = nil; return; }
            if (!editor) { finish([label stringByAppendingString:@": không mở được editor"]); return; }

            __weak id wEd = editor;
            [self updateStatusHUD:[label stringByAppendingString:@": nhập preset…"]];
            [self importPresetPayload:presets[o] codeIdentifier:codes[o] intoEditor:editor runId:runId completion:^(NSString *e1) {
                if (runId != g_runIdentifier) { step = nil; return; }
                if (e1) { finish([NSString stringWithFormat:@"%@: %@", label, e1]); return; }

                // Giữ đúng nhịp 500ms của bản v4 sau khi nạp preset để editor sẵn sàng mở bảng chọn ảnh
                VSDispatchAfterMS(500, ^{
                    if (runId != g_runIdentifier) { step = nil; return; }
                    id ed = wEd;
                    if (!VSEditorIsAlive(ed)) { finish([label stringByAppendingString:@": editor đã bị đóng"]); return; }

                    NSArray<NSNumber *> *layers = VSDetectFillableLayers(VSEngineFrom(ed), YES);
                    if (layers.count == 0) { finish([label stringByAppendingString:@": preset không có lớp video/ảnh"]); return; }

                    VSCachedSegmentMedia *reuse = (o > 0) ? g_cachedFirstMedia : nil;
                    BOOL shouldCapture = (o == 0);
                    if (reuse) {
                        [self updateStatusHUD:[label stringByAppendingString:@": tự nạp ảnh Đoạn 1 & copy x10…"]];
                    } else {
                        self.multiSceneCardView.hidden = YES;
                        [self updateStatusHUD:[label stringByAppendingString:@": chọn 1 ảnh/video để điền các lớp…"]];
                    }

                    [VSLayerFiller fillLayers:layers
                                       editor:ed
                                        runId:runId
                            requirePickerOpen:(reuse == nil)
                         captureForNextScenes:shouldCapture
                                   reuseMedia:reuse
                                   completion:^(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stop) {
                        if (runId != g_runIdentifier) { step = nil; return; }
                        self.multiSceneCardView.hidden = NO;
                        if (stop) { finish([NSString stringWithFormat:@"%@: %@", label, stop]); return; }
                        if (unconfirmed.count) {
                            finish([NSString stringWithFormat:@"%@: còn %lu lớp chưa xác nhận, chưa Tạo", label, (unsigned long)unconfirmed.count]);
                            return;
                        }
                        id edDone = wEd;
                        if (!VSEditorIsAlive(edDone)) { finish([label stringByAppendingString:@": editor bị đóng trước khi Tạo"]); return; }

                        [self updateStatusHUD:[label stringByAppendingString:@": đang Tạo…"]];
                        [self waitForEditorSettledThenCreate:edDone runId:runId completion:^(NSString *e2) {
                            if (runId != g_runIdentifier) { step = nil; return; }
                            if (e2) { finish([NSString stringWithFormat:@"%@: %@", label, e2]); return; }
                            okCount++;
                            if (offset >= total) { finish(nil); return; }
                            VSSafePoll(runId, 100, 140, ^BOOL{ return VSFindTopViewControllerNamed(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                                if (runId != g_runIdentifier) { step = nil; return; }
                                if (!back) { finish(@"Không quay lại được màn hình phân cảnh"); return; }
                                VSDispatchAfterMS(250, ^{ if (step) step(); });
                            });
                        }];
                    }];
                });
            }];
        };

        if (o == 0 && self.initialMultiLayerEditorForF4 && VSEditorIsAlive(self.initialMultiLayerEditorForF4)) {
            id readyEd = self.initialMultiLayerEditorForF4;
            self.initialMultiLayerEditorForF4 = nil;
            runOnEditor(readyEd);
            return;
        }

        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        [self openMultiLayerEditorForScene:sc reviewVC:rvc runId:runId completion:runOnEditor];
    };
    step();
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

// Giữ đúng nhịp 500ms của bản v4 sau khi nạp preset
- (void)importPresetPayload:(id)preset codeIdentifier:(id)code intoEditor:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    if (![editor respondsToSelector:@selector(importedData:code:)]) { done(@"Editor không hỗ trợ"); return; }
    NSUInteger before = g_presetImportEventCounter;
    BOOL imported = VSTry(^{ [editor importedData:preset code:code]; });
    if (!imported) { done(@"Lỗi nạp preset"); return; }

    __weak id wEd = editor;
    VSObjProvider prov = ^id{ return wEd; };
    __block BOOL blocked = NO;
    VSSafePollEditor(runId, 50, 200, prov, ^BOOL(id ed) {
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
    VSSafePollEditor(runId, 60, 200, prov, ^BOOL(id ed) {
        if (!VSEditorIsAlive(ed)) return YES;
        VSDismissLayerActionMenus(ed);
        if (VSResolvePopupsImmediately(ed) == VSPopupActionStatusBlockedPurchase) { purchase = YES; return YES; }
        BOOL calm = !VSHasAnyActivePopup(ed) && !VSEditorIsBusy(ed);
        stable = calm ? stable + 1 : 0;
        return stable >= 4;
    }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        if (purchase) { done(@"Popup mua Pro"); return; }
        id edNow = prov();
        if (!edNow || !VSEditorIsAlive(edNow)) { done(@"Editor bị đóng trước khi Tạo"); return; }
        if (!ok) { done(@"Editor chưa ổn định để Tạo"); return; }
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
    VSSafePollEditor(runId, 80, 750, prov, ^BOOL(id ed) {
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
    if (!NSClassFromString(@"MultiLayerWizEffectVC")) return;
    VSRunOnMain(^{
        VSTry(^{ [VSTool.shared setupToolInterfaceIfNeeded]; });
    });
}

__attribute__((constructor)) static void VSToolInitializerEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                             object:nil
                                                              queue:NSOperationQueue.mainQueue
                                                         usingBlock:^(NSNotification *note) {
                @autoreleasepool { VSBootstrapAutomation(); }
            }];
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                VSBootstrapAutomation();
            }
        }
    });
}
