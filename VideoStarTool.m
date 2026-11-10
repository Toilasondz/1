// ============================================================================
// VideoStarTool.m
// Video Star 14.3.3 (build 1809)
//
// LOGIC:
//   1. Phân loại lớp:
//      - VIDEO / IMAGE có nội dung  -> thay media
//      - RỖNG (chưa nhập)           -> giữ im
//      - KHÁC (3D/text/color/gif/zap/drawing/overlay) -> giữ im
//   2. Lớp đầu tiên dùng bảng chọn media của app (pickNewContent)
//      - CN1: chỉ mở bảng chọn + thay media, KHÔNG tự bấm popup
//      - CN4: mở bảng chọn + thay media + tự bấm Trùng khớp / OK
//   3. Các lớp tiếp theo chạy ngầm hoàn toàn, không mở bảng chọn nữa
// ============================================================================

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/proc.h>
#import <sys/time.h>

#define VS_MAX_LAYERS 30
#define VS_TAG "[VideoStarTool] "

// ============================================================================
// LOG TRONG APP
// ============================================================================

static NSMutableArray<NSString *> *g_logLines = nil;
static dispatch_queue_t g_logQueue = nil;
static NSUInteger g_runCounter = 0;

static void VSLogImpl(NSString *line) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_logLines = [NSMutableArray array];
        g_logQueue = dispatch_queue_create("vstool.log", DISPATCH_QUEUE_SERIAL);
    });
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tmv; localtime_r(&tv.tv_sec, &tmv);
    char buf[16]; strftime(buf, sizeof buf, "%H:%M:%S", &tmv);
    NSString *entry = [NSString stringWithFormat:@"%s.%03d %@", buf, (int)(tv.tv_usec / 1000), line ?: @""];
    NSLog(@"%s%@", VS_TAG, line);
    dispatch_async(g_logQueue, ^{
        [g_logLines addObject:entry];
        if (g_logLines.count > 5000) [g_logLines removeObjectsInRange:NSMakeRange(0, 1500)];
    });
}
#define VSLog(fmt, ...) VSLogImpl([NSString stringWithFormat:fmt, ##__VA_ARGS__])

static NSArray<NSString *> *VSLogSnapshotLines(void) {
    if (!g_logQueue) return @[];
    __block NSArray<NSString *> *copy = nil;
    dispatch_sync(g_logQueue, ^{ copy = [g_logLines copy]; });
    return copy ?: @[];
}

static void VSLogClear(void) {
    if (!g_logQueue) return;
    dispatch_sync(g_logQueue, ^{ [g_logLines removeAllObjects]; });
}

static BOOL VSLineIsError(NSString *line) {
    static NSArray *kw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kw = @[@"❌", @"⚠️", @"lỗi", @"thất bại", @"fail", @"exception", @"[guard]", @"memory", @"timeout",
               @"bị đóng", @"đã bị đóng", @"popup lạ", @"[trace]", @"chưa xác nhận", @"không tìm thấy", @"không thể"];
    });
    for (NSString *k in kw) if ([line rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static NSArray<NSString *> *VSLogLinesLastRun(void) {
    NSArray<NSString *> *lines = VSLogSnapshotLines();
    NSUInteger start = 0;
    for (NSInteger i = (NSInteger)lines.count - 1; i >= 0; i--) {
        if ([lines[(NSUInteger)i] containsString:@"════ RUN"]) { start = (NSUInteger)i; break; }
    }
    return [lines subarrayWithRange:NSMakeRange(start, lines.count - start)];
}

static NSString *VSLogTextLastRun(void) { return [VSLogLinesLastRun() componentsJoinedByString:@"\n"]; }
static NSString *VSLogTextAll(void) { return [VSLogSnapshotLines() componentsJoinedByString:@"\n"]; }

static NSString *VSLogTextErrorsLastRun(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in VSLogLinesLastRun()) if (VSLineIsError(l) || [l containsString:@"════ RUN"] || [l containsString:@"KẾT QUẢ"]) [out addObject:l];
    return [out componentsJoinedByString:@"\n"];
}

static NSUInteger VSLogErrorCountLastRun(void) {
    NSUInteger n = 0;
    for (NSString *l in VSLogLinesLastRun()) if (VSLineIsError(l)) n++;
    return n;
}

static double VSAvailableMemoryMB(void) {
    if (@available(iOS 13.0, *)) return (double)os_proc_available_memory() / 1048576.0;
    return -1;
}

static NSString *VSLogFilePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"VideoStarTool_Log.txt"];
}

static NSString *VSLogWriteFile(void) {
    NSString *header = [NSString stringWithFormat:@"VideoStarTool log — iOS %@ — %@\n\n", UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.model];
    NSString *text = [header stringByAppendingString:VSLogTextAll()];
    NSString *path = VSLogFilePath();
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return path;
}

// ============================================================================
// CÀI ĐẶT GỠ LỖI
// ============================================================================

static NSString *const kVSSetSuppressMenu = @"VSTool.suppressMenu";
static NSString *const kVSSetSkipReselect = @"VSTool.skipReselect";
static NSString *const kVSSetDismissMenu  = @"VSTool.dismissMenu";
static NSString *const kVSSetGuardCancel  = @"VSTool.guardCancel";

static BOOL VSSettingBool(NSString *key, BOOL defaultValue) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : defaultValue;
}
static void VSSettingSet(NSString *key, BOOL value) {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
}

// ============================================================================
// PHẦN 1: PRIVATE API
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

// ============================================================================
// PHẦN 2: UTILITIES
// ============================================================================

static NSUInteger g_runIdentifier = 0;
static BOOL g_autoConfirmPopups = NO;
static BOOL g_suppressLayerActionMenu = NO;
static BOOL g_guardCancel = NO;
static BOOL g_createInProgress = NO;
static BOOL g_dismissLayerMenu = NO;
static BOOL g_taskActive = NO;
static const void *kVSPopupHandledKey = &kVSPopupHandledKey;
static NSHashTable *g_activePopupsTable = nil;
static UIWindow *g_overlayToolWindow = nil;

static inline void VSRunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) { @autoreleasepool { block(); } }
    else { dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { block(); } }); }
}

static inline void VSDispatchAfterMS(int64_t delayMs, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ @autoreleasepool { block(); } });
}

static BOOL VSTry(void (^block)(void)) {
    @try { block(); return YES; }
    @catch (NSException *e) { VSLog(@"Exception: %@ — %@", e.name, e.reason); return NO; }
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
    } @catch (...) { return nil; }
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
    } @catch (...) { return kCMTimeInvalid; }
}

static inline void VSSetQRDelegateSafely(id qrManager, id delegate) {
    if (!qrManager) return;
    SEL sel = @selector(setDelegate:);
    if (![qrManager respondsToSelector:sel]) return;
    @try { ((void (*)(id, SEL, id))[qrManager methodForSelector:sel])(qrManager, sel, delegate); }
    @catch (...) {}
}

static inline BOOL VSSafeIsClass(id object, NSString *className) {
    if (!object || !className.length) return NO;
    Class targetClass = NSClassFromString(className);
    return targetClass && [object isKindOfClass:targetClass];
}

static UIBarButtonItem *VSFindCreateButtonOnEditor(id editorVC) {
    if (!editorVC) return nil;
    NSArray *createKeywords = @[@"tạo", @"create", @"done", @"xong", @"save", @"lưu", @"export", @"xuất"];
    NSArray *cancelKeywords = @[@"hủy", @"huỷ", @"cancel", @"back", @"quay lại", @"dismiss", @"close", @"đóng"];

    id cancelBarButtonRef = VSSafeValueForKey(editorVC, @"cancelBarButton");
    BOOL (^isCreateButton)(UIBarButtonItem *) = ^BOOL(UIBarButtonItem *btn) {
        if (!btn || btn == cancelBarButtonRef) return NO;
        NSString *title = btn.title ?: @"";
        NSString *actionStr = btn.action ? [NSStringFromSelector(btn.action) stringByReplacingOccurrencesOfString:@"_" withString:@""] : @"";
        for (NSString *kw in cancelKeywords) if (VSContains(title, kw) || VSContains(actionStr, kw)) return NO;
        for (NSString *kw in createKeywords) if (VSContains(title, kw) || VSContains(actionStr, kw)) return YES;
        return NO;
    };

    id cancelButton = VSSafeValueForKey(editorVC, @"cancelBarButton");
    id kvcButton = VSSafeValueForKey(editorVC, @"createBarButton");
    if ([kvcButton isKindOfClass:[UIBarButtonItem class]] && kvcButton != cancelButton) {
        VSLog(@"[CreateButton] createBarButton: '%@'", ((UIBarButtonItem *)kvcButton).title ?: @"?");
        return (UIBarButtonItem *)kvcButton;
    }

    UINavigationController *nav = nil;
    @try { nav = [editorVC navigationController]; } @catch (...) { nav = nil; }
    if (nav) {
        UINavigationItem *navItem = nav.topViewController.navigationItem;
        for (UIBarButtonItem *btn in navItem.rightBarButtonItems) {
            if (isCreateButton(btn)) { VSLog(@"[CreateButton] rightBarButtonItems: '%@'", btn.title ?: @"?"); return btn; }
        }
        if (isCreateButton(navItem.rightBarButtonItem)) {
            VSLog(@"[CreateButton] rightBarButtonItem: '%@'", navItem.rightBarButtonItem.title ?: @"?");
            return navItem.rightBarButtonItem;
        }
    }
    VSLog(@"[CreateButton] KHÔNG tìm thấy nút Tạo");
    return nil;
}

static void VSSafePoll(NSUInteger runId, int64_t intervalMs, NSUInteger remainingTries,
                       BOOL (^conditionBlock)(void), void (^completionBlock)(BOOL success)) {
    if (runId != g_runIdentifier) { if (completionBlock) completionBlock(NO); return; }
    BOOL matched = NO;
    @autoreleasepool {
        @try { matched = conditionBlock(); }
        @catch (...) { matched = NO; }
    }
    if (matched) { if (completionBlock) completionBlock(YES); return; }
    if (remainingTries == 0) { if (completionBlock) completionBlock(NO); return; }
    VSDispatchAfterMS(intervalMs, ^{
        VSSafePoll(runId, intervalMs, remainingTries - 1, conditionBlock, completionBlock);
    });
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
    for (UIWindow *w in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (w == g_overlayToolWindow || w.hidden || w.alpha <= 0.01) continue;
        UIViewController *found = VSSearchViewControllerRecursive(w.rootViewController, targetClass, 0);
        if (found) return found;
    }
    return nil;
}

// ============================================================================
// PHẦN 3: SMART POPUP RESOLVER
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
        VSTry(^{
            if ([popup respondsToSelector:@selector(dismiss)]) { VSLog(@"[LayerMenu] đóng menu chọn lớp"); [popup dismiss]; }
        });
    }
}

// FIX: kiểm tra menu chọn lớp còn hiện không (trước khi replay)
static BOOL VSHasVisibleLayerActionMenu(id editorVC) {
    for (id popup in VSCollectAllVisiblePopups(editorVC)) {
        if (VSPopupIsLayerActionMenu(popup)) return YES;
    }
    return NO;
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
    } @catch (...) { alive = NO; }
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

static NSString *VSDescribeVCChain(void) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w == g_overlayToolWindow || w.hidden) continue;
        NSMutableArray<NSString *> *chain = [NSMutableArray array];
        UIViewController *vc = w.rootViewController;
        for (int guardN = 0; vc && guardN < 10; guardN++) {
            NSString *d = NSStringFromClass([vc class]);
            if ([vc isKindOfClass:[UINavigationController class]]) {
                NSMutableArray<NSString *> *names = [NSMutableArray array];
                for (UIViewController *c in ((UINavigationController *)vc).viewControllers) [names addObject:NSStringFromClass([c class])];
                d = [NSString stringWithFormat:@"%@[%@]", d, [names componentsJoinedByString:@","]];
            }
            [chain addObject:d];
            vc = vc.presentedViewController;
        }
        [parts addObject:[chain componentsJoinedByString:@" ▸ "]];
    }
    return [parts componentsJoinedByString:@"  ||  "];
}

static NSString *VSPopupSummary(id editorVC) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (id popup in VSCollectAllVisiblePopups(editorVC)) {
        NSArray<NSString *> *titles = VSPopupButtonTitles(popup, NULL);
        [items addObject:[NSString stringWithFormat:@"{%@}", [titles componentsJoinedByString:@"|"]]];
    }
    return [items componentsJoinedByString:@" "];
}

static void VSLogState(NSString *tag, id editorVC) {
    id selected = VSSafeValueForKey(editorVC, @"lastSelectedLayerNum");
    id bordered = VSSafeValueForKey(editorVC, @"borderedLayerNum");
    BOOL menuShowing = VSValueIsTruthy(VSSafeValueForKey(editorVC, @"isMenuShowing"));
    VSLog(@"[State:%@] alive=%d busy=%d selected=%@ bordered=%@ menuShowing=%d mem=%.0fMB popups=[%@] vc=%@",
          tag, VSEditorIsAlive(editorVC), VSEditorIsBusy(editorVC), selected ?: @"?", bordered ?: @"?", menuShowing,
          VSAvailableMemoryMB(), VSPopupSummary(editorVC), VSDescribeVCChain());
}

static void VSApplySettingsToRun(void) {
    g_suppressLayerActionMenu = VSSettingBool(kVSSetSuppressMenu, NO);
    g_dismissLayerMenu        = VSSettingBool(kVSSetDismissMenu, YES);
    g_guardCancel             = VSSettingBool(kVSSetGuardCancel, YES);
    VSLog(@"[Settings] suppressMenu=%d skipReselect=%d dismissMenu=%d guardCancel=%d",
          g_suppressLayerActionMenu, VSSettingBool(kVSSetSkipReselect, NO), g_dismissLayerMenu, g_guardCancel);
}

static void VSLogRunStart(NSString *name) {
    g_runCounter++;
    VSLog(@"════ RUN #%lu: %@ ════", (unsigned long)g_runCounter, name ?: @"?");
    VSLog(@"[Env] iOS %@ | mem=%.0fMB | vc=%@", UIDevice.currentDevice.systemVersion, VSAvailableMemoryMB(), VSDescribeVCChain());
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

    NSArray *matchNames = @[@"Khớp: rút ngắn/giãn", @"Match: shorten/stretch", @"Trùng khớp", @"Match"];
    NSArray *matchFallbackNames = @[@"Bắt đầu", @"Start", @"Kết thúc", @"End"];
    NSArray *okNames = @[@"OK", @"Đồng ý", @"Xong", @"Done"];
    BOOL anyHandled = NO;

    for (id popup in popups) {
        if (VSPopupIsLayerActionMenu(popup)) continue;
        if (VSCheckIfPopupIsPurchasePrompt(popup)) { VSLog(@"Popup mua Pro — dừng"); return VSPopupActionStatusBlockedPurchase; }
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

        NSString *header = [NSString stringWithFormat:@"%@ %@", [VSSafeValueForKey(popup, @"_title") description] ?: @"", [VSSafeValueForKey(popup, @"_message") description] ?: @""];
        NSString *matchedTitle = nil;
        NSString *reason = nil;

        NSString *matchBtn = firstTitleMatching(matchNames);
        if (matchBtn) { matchedTitle = matchBtn; reason = @"trùng khớp"; }
        else if (VSContains(header, @"Original Preset Layers") || VSContains(header, @"Các lớp Cài đặt sẵn Gốc") ||
                 VSContains(header, VSLocalizedString(@"Original Preset Layers"))) {
            matchedTitle = firstTitleMatching(okNames); reason = @"thông tin preset";
        }
        else if (titles.count == 1) { matchedTitle = firstTitleMatching(okNames); reason = @"thông báo 1 nút"; }
        else if (firstTitleMatching(matchFallbackNames) && VSContains(header, @"dài hơn")) {
            matchedTitle = firstTitleMatching(matchFallbackNames); reason = @"trùng khớp (dự phòng)";
        }

        if (!matchedTitle) {
            VSLog(@"[SmartPopup] popup lạ, KHÔNG bấm: %@", [titles componentsJoinedByString:@" | "]);
            continue;
        }

        objc_setAssociatedObject(popup, kVSPopupHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIButton *matchedButton = buttonByTitle[matchedTitle];
        VSTry(^{
            VSLog(@"[SmartPopup] (%@) nhấn: '%@'", reason, matchedTitle);
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
        if (VSPopupWasHandled(popup) && ((UIView *)popup).alpha < 0.05) continue;
        return YES;
    }
    return NO;
}

// ============================================================================
// PHẦN 4: LAYER SNAPSHOT
// ============================================================================

typedef NS_ENUM(NSInteger, VSLayerMediaKind) {
    VSLayerMediaKindUnknown = 0,
    VSLayerMediaKindImage,
    VSLayerMediaKindVideo,
    VSLayerMediaKindEmpty,
    VSLayerMediaKindOther
};

static inline BOOL VSLayerKindIsReplaceable(VSLayerMediaKind kind) {
    return kind == VSLayerMediaKindImage || kind == VSLayerMediaKindVideo;
}

static NSString *VSKindName(VSLayerMediaKind k) {
    switch (k) {
        case VSLayerMediaKindImage: return @"ẢNH";
        case VSLayerMediaKindVideo: return @"VIDEO";
        case VSLayerMediaKindEmpty: return @"RỖNG";
        case VSLayerMediaKindOther: return @"KHÁC";
        default: return @"?";
    }
}

@interface VSLayerSnapshot : NSObject
@property (nonatomic, assign) NSInteger layerTypeValue;
@property (nonatomic, assign) NSUInteger layerIndex;
@property (nonatomic, assign) VSLayerMediaKind mediaKind;
@property (nonatomic, strong) id mediaObject;
@property (nonatomic, assign) unsigned int textureID;
@property (nonatomic, copy)   NSString *assetInfo;
@property (nonatomic, copy)   NSString *signature;
@end
@implementation VSLayerSnapshot
@end

static VSLayerSnapshot *VSInspectLayerDetails(id engine, NSUInteger layerNum) {
    if (!engine || ![engine respondsToSelector:@selector(layerAtLayerNum:)]) return nil;
    @autoreleasepool {
        @try {
            id layer = [engine layerAtLayerNum:layerNum];
            if (!layer) return nil;

            VSLayerSnapshot *snap = [VSLayerSnapshot new];
            snap.layerIndex = layerNum;
            snap.mediaKind = VSLayerMediaKindOther;
            id layerTypeObj = VSSafeValueForKey(layer, @"layerType");
            snap.layerTypeValue = [layerTypeObj isKindOfClass:[NSNumber class]] ? [(NSNumber *)layerTypeObj integerValue] : -1;
            snap.assetInfo = [VSSafeValueForKey(layer, @"origAssetInfo") description] ?: @"";

            if (VSValueIsTruthy(VSSafeValueForKey(layer, @"isNullLayer"))) {
                snap.signature = @"null"; return snap;
            }

            id generator = VSSafeValueForKey(layer, @"imageGenerator");
            if (!generator) {
                snap.mediaKind = VSLayerMediaKindEmpty;
                snap.signature = @"nogen";
                return snap;
            }

            for (NSString *key in @[@"layerGIF", @"layerZaps", @"layerDrawing", @"layerOverlay"]) {
                if (VSValueIsTruthy(VSSafeValueForKey(generator, key))) {
                    snap.signature = key; return snap;
                }
            }

            id asset = VSSafeValueForKey(generator, @"asset");
            BOOL hasVideo = [asset isKindOfClass:[AVAsset class]];
            id rawImage = VSSafeValueForKey(generator, @"layerImage");
            UIImage *img = [rawImage isKindOfClass:[UIImage class]] ? (UIImage *)rawImage : nil;
            BOOL hasImage = img && img.size.width > 1.0;

            id tex = VSSafeValueForKey(generator, @"layerImageTextureID");
            snap.textureID = [tex isKindOfClass:[NSNumber class]] ? [(NSNumber *)tex unsignedIntValue] : 0;

            if (!hasVideo && (VSValueIsTruthy(VSSafeValueForKey(layer, @"textDictionary")) ||
                              VSValueIsTruthy(VSSafeValueForKey(layer, @"particleLabModel")))) {
                snap.signature = @"text_or_particle"; return snap;
            }

            NSString *assetKey = @"";
            if ([asset isKindOfClass:[AVURLAsset class]]) assetKey = ((AVURLAsset *)asset).URL.absoluteString ?: @"";
            else if (hasVideo) assetKey = [NSString stringWithFormat:@"%p", asset];
            else if (hasImage) assetKey = [NSString stringWithFormat:@"%.0fx%.0f", img.size.width, img.size.height];

            if (hasVideo) {
                snap.mediaKind = VSLayerMediaKindVideo;
                snap.mediaObject = asset;
            } else if (hasImage) {
                snap.mediaKind = VSLayerMediaKindImage;
                snap.mediaObject = img;
            } else {
                snap.mediaKind = VSLayerMediaKindEmpty;
            }
            snap.signature = [NSString stringWithFormat:@"%ld|%u|%@|%@", (long)snap.mediaKind, snap.textureID, snap.assetInfo, assetKey];
            return snap;
        } @catch (NSException *e) {
            VSLog(@"Inspect layer %lu: %@", (unsigned long)layerNum, e);
            return nil;
        }
    }
}

static NSArray<VSLayerSnapshot *> *VSScanLayers(id engine) {
    NSMutableArray<VSLayerSnapshot *> *out = [NSMutableArray array];
    NSUInteger misses = 0;
    for (NSUInteger i = 0; i < VS_MAX_LAYERS; i++) {
        VSLayerSnapshot *snap = VSInspectLayerDetails(engine, i);
        if (!snap) { if (++misses >= 3) break; continue; }
        misses = 0;
        [out addObject:snap];
    }
    NSMutableArray<NSString *> *desc = [NSMutableArray array];
    for (VSLayerSnapshot *sn in out)
        [desc addObject:[NSString stringWithFormat:@"%lu:%@(type=%ld)", (unsigned long)(sn.layerIndex + 1), VSKindName(sn.mediaKind), (long)sn.layerTypeValue]];
    VSLog(@"[Scan] %lu lớp → %@", (unsigned long)out.count, [desc componentsJoinedByString:@"  "]);
    return out;
}

static VSLayerSnapshot *VSFirstReplaceableLayer(id engine) {
    for (VSLayerSnapshot *snap in VSScanLayers(engine))
        if (VSLayerKindIsReplaceable(snap.mediaKind)) return snap;
    return nil;
}

static void VSSelectLayerOnEditor(id editorVC, NSUInteger n, NSUInteger runId, void (^done)(BOOL selected)) {
    BOOL (^isSelected)(void) = ^BOOL{ return [editorVC lastSelectedLayerNum] == (NSInteger)n; };
    BOOL already = NO;
    @try { already = isSelected(); } @catch (...) {}
    BOOL skipReselect = VSSettingBool(kVSSetSkipReselect, NO);
    VSLog(@"[Select] lớp %lu (đã chọn sẵn=%d, skipReselect=%d)", (unsigned long)(n + 1), already, skipReselect);
    if (already && skipReselect) { VSDismissLayerActionMenus(editorVC); done(YES); return; }

    VSTry(^{ if ([editorVC respondsToSelector:@selector(selectLayer:bordered:)]) [editorVC selectLayer:n bordered:NO]; });
    VSSafePoll(runId, 50, 20, isSelected, ^(BOOL sel) {
        if (sel) { VSDismissLayerActionMenus(editorVC); done(YES); return; }
        VSTry(^{ if ([editorVC respondsToSelector:@selector(selectLayerNum:flash:)]) [editorVC selectLayerNum:n flash:NO]; });
        VSSafePoll(runId, 50, 12, isSelected, ^(BOOL sel2) {
            VSDismissLayerActionMenus(editorVC);
            done(sel2);
        });
    });
}

static void VSRefreshEditorAfterReplace(id editorVC, id engine) {
    VSTry(^{ if ([engine respondsToSelector:@selector(reloadLayerEffects)]) [engine reloadLayerEffects]; });
    VSTry(^{ if ([editorVC respondsToSelector:@selector(handleImageGenUpdate)]) [editorVC handleImageGenUpdate]; });
    VSTry(^{ if ([editorVC respondsToSelector:@selector(engineResync)]) [editorVC engineResync]; });
    VSTry(^{ if ([editorVC respondsToSelector:@selector(refreshDisplay)]) [editorVC refreshDisplay]; });
}

// ============================================================================
// PHẦN 5: QR STORAGE
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
            if (image) {
                NSData *png = UIImagePNGRepresentation(image);
                if (png.length) {
                    [png writeToFile:VSGetLastQRCodeStoragePath() atomically:YES];
                    VSLog(@"Đã lưu QR (%lu bytes)", (unsigned long)png.length);
                }
            }
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
// PHẦN 6: HOOKS
// ============================================================================

static IMP g_origPickedWithResponse = NULL;
static IMP g_origSelectedCodeWithImageData = NULL;
static IMP g_origImportNewPreset = NULL;
static IMP g_origImportOldPreset = NULL;
static IMP g_origCustomPopupDidMove = NULL;
static IMP g_origShowLayerActionMenu = NULL;
static IMP g_origEditorCancel = NULL;
static IMP g_origEditorCancelCreate = NULL;
static IMP g_origEditorClose = NULL;
static IMP g_origNavCancel = NULL;
static IMP g_origVCDismiss = NULL;
static IMP g_origNavPop = NULL;
static IMP g_origNavPopRoot = NULL;
static IMP g_origNavPopTo = NULL;
static IMP g_origEditorWillDisappear = NULL;
static IMP g_origEditorMemWarn = NULL;
static IMP g_origNavMemWarn = NULL;

static NSUInteger g_presetImportEventCounter = 0;
static void (^g_activeMediaPickedHandler)(id editorVC, id response) = nil;

static BOOL VSRobustSwizzleMethod(NSString *className, SEL selector, id blockImpl, IMP *origImp) {
    Class cls = NSClassFromString(className);
    if (!cls) { VSLog(@"Không tìm thấy class: %@", className); return NO; }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) { VSLog(@"Không tìm thấy method: -[%@ %@]", className, NSStringFromSelector(selector)); return NO; }
    if (*origImp != NULL) return YES;
    IMP newImp = imp_implementationWithBlock(blockImpl);
    if (class_addMethod(cls, selector, newImp, method_getTypeEncoding(method))) {
        *origImp = method_getImplementation(method);
    } else {
        *origImp = method_setImplementation(method, newImp);
    }
    return YES;
}

static void VSInstallCoreHooksOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_activePopupsTable = [NSHashTable weakObjectsHashTable];

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(pickedWithClipPickerResponse:), ^(id selfInstance, id response) {
            if (g_origPickedWithResponse)
                ((void (*)(id, SEL, id))g_origPickedWithResponse)(selfInstance, @selector(pickedWithClipPickerResponse:), response);
            void (^handler)(id, id) = g_activeMediaPickedHandler;
            if (handler) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { handler(selfInstance, response); } });
        }, &g_origPickedWithResponse);

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
            if (g_suppressLayerActionMenu) { VSLog(@"[LayerMenu] chặn showLayerActionMenu (lớp %lu)", (unsigned long)layerNum); return; }
            if (g_origShowLayerActionMenu)
                ((void (*)(id, SEL, NSUInteger, BOOL))g_origShowLayerActionMenu)(selfInstance, @selector(showLayerActionMenu:newLayer:), layerNum, isNewLayer);
        }, &g_origShowLayerActionMenu);

        // ---- Guard: chặn Hủy/Đóng do CODE phát ra khi tool đang chạy ----
        BOOL (^isUserTouch)(void) = ^BOOL{
            for (NSString *sym in [NSThread callStackSymbols]) if ([sym containsString:@"sendEvent:"]) return YES;
            return NO;
        };

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(cancel), ^(id selfInstance) {
            if (g_guardCancel && !g_createInProgress && !isUserTouch()) {
                NSArray *st = [NSThread callStackSymbols];
                VSLog(@"[Guard] CHẶN -cancel do code gọi. Nguồn:\n%@", [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                return;
            }
            if (g_origEditorCancel) ((void (*)(id, SEL))g_origEditorCancel)(selfInstance, @selector(cancel));
        }, &g_origEditorCancel);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(cancelCreate), ^(id selfInstance) {
            if (g_guardCancel && !g_createInProgress && !isUserTouch()) { VSLog(@"[Guard] CHẶN -cancelCreate do code gọi"); return; }
            if (g_origEditorCancelCreate) ((void (*)(id, SEL))g_origEditorCancelCreate)(selfInstance, @selector(cancelCreate));
        }, &g_origEditorCancelCreate);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(close), ^(id selfInstance) {
            if (g_guardCancel && !g_createInProgress && !isUserTouch()) {
                NSArray *st = [NSThread callStackSymbols];
                VSLog(@"[Guard] CHẶN -close do code gọi. Nguồn:\n%@", [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                return;
            }
            if (g_origEditorClose) ((void (*)(id, SEL))g_origEditorClose)(selfInstance, @selector(close));
        }, &g_origEditorClose);

        VSRobustSwizzleMethod(@"MultiLayerNavController", @selector(cancel), ^(id selfInstance) {
            if (g_guardCancel && !g_createInProgress && !isUserTouch()) {
                NSArray *st = [NSThread callStackSymbols];
                VSLog(@"[Guard] CHẶN MultiLayerNavController -cancel do code gọi. Nguồn:\n%@", [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                return;
            }
            if (g_taskActive) VSLog(@"[Trace] MultiLayerNavController -cancel (chạm thật hoặc tool đang Tạo)");
            if (g_origNavCancel) ((void (*)(id, SEL))g_origNavCancel)(selfInstance, @selector(cancel));
        }, &g_origNavCancel);

        // ---- Trace: ai đóng editor? ----
        void (^traceStack)(NSString *, id) = ^(NSString *what, id obj) {
            NSArray *st = [NSThread callStackSymbols];
            NSUInteger n = MIN((NSUInteger)18, st.count);
            NSUInteger from = st.count > 1 ? 1 : 0;
            VSLog(@"[Trace] %@ trên %@ | nguồn gọi:\n%@", what, NSStringFromClass([obj class]),
                  [[st subarrayWithRange:NSMakeRange(from, n - from)] componentsJoinedByString:@"\n"]);
        };
        BOOL (^involvesEditor)(id) = ^BOOL(id vcObj) {
            NSString *names = [NSString stringWithFormat:@"%@ %@ %@", NSStringFromClass([vcObj class]),
                               NSStringFromClass([[vcObj presentedViewController] class]),
                               NSStringFromClass([[vcObj presentingViewController] class])];
            return [names containsString:@"MultiLayer"] || [names containsString:@"VideoReview"];
        };
        // FIX: chỉ khớp chính editor hoặc nav của nó — không chặn picker đang present trên editor.
        BOOL (^isEditorOrNav)(id) = ^BOOL(id vcObj) {
            NSString *name = NSStringFromClass([vcObj class]);
            return [name containsString:@"MultiLayerWizEffectVC"] || [name containsString:@"MultiLayerNavController"];
        };

        // FIX: chặn dismissViewControllerAnimated do code gọi trên editor/nav khi tool đang chạy.
        VSRobustSwizzleMethod(@"UIViewController", @selector(dismissViewControllerAnimated:completion:), ^(id selfInstance, BOOL animated, id completion) {
            if (g_taskActive) {
                if (isEditorOrNav(selfInstance)) {
                    if (g_guardCancel && !g_createInProgress && !isUserTouch()) {
                        NSArray *st = [NSThread callStackSymbols];
                        VSLog(@"[Guard] CHẶN dismissViewControllerAnimated do code gọi trên %@. Nguồn:\n%@",
                              NSStringFromClass([selfInstance class]),
                              [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ ((void (^)(void))completion)(); });
                        return;
                    }
                    traceStack(@"dismissViewControllerAnimated", selfInstance);
                } else if (involvesEditor(selfInstance)) {
                    traceStack(@"dismissViewControllerAnimated", selfInstance);
                }
            }
            if (g_origVCDismiss) ((void (*)(id, SEL, BOOL, id))g_origVCDismiss)(selfInstance, @selector(dismissViewControllerAnimated:completion:), animated, completion);
        }, &g_origVCDismiss);

        // FIX: chặn pop do code gọi trên editor/nav khi tool đang chạy.
        VSRobustSwizzleMethod(@"UINavigationController", @selector(popViewControllerAnimated:), ^id(id selfInstance, BOOL animated) {
            if (g_taskActive && isEditorOrNav(selfInstance) && g_guardCancel && !g_createInProgress && !isUserTouch()) {
                NSArray *st = [NSThread callStackSymbols];
                VSLog(@"[Guard] CHẶN popViewControllerAnimated do code gọi trên %@. Nguồn:\n%@",
                      NSStringFromClass([selfInstance class]),
                      [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                return nil;
            }
            if (g_taskActive && involvesEditor(selfInstance)) traceStack(@"popViewControllerAnimated", selfInstance);
            return g_origNavPop ? ((id (*)(id, SEL, BOOL))g_origNavPop)(selfInstance, @selector(popViewControllerAnimated:), animated) : nil;
        }, &g_origNavPop);

        VSRobustSwizzleMethod(@"UINavigationController", @selector(popToRootViewControllerAnimated:), ^id(id selfInstance, BOOL animated) {
            if (g_taskActive && isEditorOrNav(selfInstance) && g_guardCancel && !g_createInProgress && !isUserTouch()) {
                NSArray *st = [NSThread callStackSymbols];
                VSLog(@"[Guard] CHẶN popToRootViewControllerAnimated do code gọi trên %@. Nguồn:\n%@",
                      NSStringFromClass([selfInstance class]),
                      [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                return nil;
            }
            if (g_taskActive && involvesEditor(selfInstance)) traceStack(@"popToRootViewControllerAnimated", selfInstance);
            return g_origNavPopRoot ? ((id (*)(id, SEL, BOOL))g_origNavPopRoot)(selfInstance, @selector(popToRootViewControllerAnimated:), animated) : nil;
        }, &g_origNavPopRoot);

        VSRobustSwizzleMethod(@"UINavigationController", @selector(popToViewController:animated:), ^id(id selfInstance, id target, BOOL animated) {
            if (g_taskActive && isEditorOrNav(selfInstance) && g_guardCancel && !g_createInProgress && !isUserTouch()) {
                NSArray *st = [NSThread callStackSymbols];
                VSLog(@"[Guard] CHẶN popToViewController do code gọi trên %@. Nguồn:\n%@",
                      NSStringFromClass([selfInstance class]),
                      [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                return nil;
            }
            if (g_taskActive && involvesEditor(selfInstance)) traceStack(@"popToViewController", selfInstance);
            return g_origNavPopTo ? ((id (*)(id, SEL, id, BOOL))g_origNavPopTo)(selfInstance, @selector(popToViewController:animated:), target, animated) : nil;
        }, &g_origNavPopTo);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(viewWillDisappear:), ^(id selfInstance, BOOL animated) {
            if (g_taskActive) {
                UIViewController *vc = (UIViewController *)selfInstance;
                BOOL closing = vc.isBeingDismissed || vc.isMovingFromParentViewController || vc.navigationController.isBeingDismissed;
                VSLog(@"[Trace] editor viewWillDisappear: closing=%d presented=%@ createInProgress=%d", closing,
                      NSStringFromClass([vc.presentedViewController class]), g_createInProgress);
                if (closing && !g_createInProgress) traceStack(@"EDITOR ĐANG BỊ ĐÓNG (không phải do Tạo)", selfInstance);
            }
            if (g_origEditorWillDisappear) ((void (*)(id, SEL, BOOL))g_origEditorWillDisappear)(selfInstance, @selector(viewWillDisappear:), animated);
        }, &g_origEditorWillDisappear);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(didReceiveMemoryWarning), ^(id selfInstance) {
            VSLog(@"❌ MEMORY WARNING (editor) mem=%.0fMB taskActive=%d", VSAvailableMemoryMB(), g_taskActive);
            if (g_origEditorMemWarn) ((void (*)(id, SEL))g_origEditorMemWarn)(selfInstance, @selector(didReceiveMemoryWarning));
        }, &g_origEditorMemWarn);

        VSRobustSwizzleMethod(@"MultiLayerNavController", @selector(didReceiveMemoryWarning), ^(id selfInstance) {
            VSLog(@"❌ MEMORY WARNING (nav) mem=%.0fMB taskActive=%d", VSAvailableMemoryMB(), g_taskActive);
            if (g_origNavMemWarn) ((void (*)(id, SEL))g_origNavMemWarn)(selfInstance, @selector(didReceiveMemoryWarning));
        }, &g_origNavMemWarn);

        for (NSString *name in @[UIApplicationDidReceiveMemoryWarningNotification, UIApplicationWillResignActiveNotification,
                                 UIApplicationDidEnterBackgroundNotification, UIApplicationDidBecomeActiveNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (!g_taskActive) return;
                BOOL isMem = [note.name isEqualToString:UIApplicationDidReceiveMemoryWarningNotification];
                VSLog(@"%@[App] %@ mem=%.0fMB", isMem ? @"❌ " : @"", note.name, VSAvailableMemoryMB());
            }];
        }

        VSLog(@"Hooks installed");
    });
}

static BOOL VSReplayClipPickerResponseOnEditor(id editorVC, id response) {
    if (!editorVC || !response || !g_origPickedWithResponse) return NO;
    @autoreleasepool {
        @try {
            ((void (*)(id, SEL, id))g_origPickedWithResponse)(editorVC, @selector(pickedWithClipPickerResponse:), response);
            return YES;
        } @catch (NSException *e) { VSLog(@"Replay exception: %@", e); return NO; }
    }
}

// ============================================================================
// PHẦN 7: UI CLASSES
// ============================================================================

@interface VSToolPassThroughWindow : UIWindow
@end
@implementation VSToolPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

static inline UIColor *VSToolCyanColor(void) { return [UIColor colorWithRed:0.25 green:0.85 blue:0.96 alpha:1.0]; }
static inline UIColor *VSToolCardBackgroundColor(void) { return [UIColor colorWithRed:0.03 green:0.08 blue:0.12 alpha:0.96]; }

static UIButton *VSToolCreateOutlineButton(NSString *title, CGRect frame) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.layer.cornerRadius = 8.0;
    btn.layer.borderWidth = 1.2;
    btn.layer.borderColor = VSToolCyanColor().CGColor;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:VSToolCyanColor() forState:UIControlStateNormal];
    [btn setTitleColor:[VSToolCyanColor() colorWithAlphaComponent:0.35] forState:UIControlStateDisabled];
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
    if (block) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { block(data, code); } });
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
    void *zero = NULL;
    if (invocation.methodSignature.methodReturnLength >= sizeof(void *)) [invocation setReturnValue:&zero];
}
@end

@interface VSToolLogViewController : UIViewController
@end
@implementation VSToolLogViewController {
    UITextView *_textView;
    UISegmentedControl *_segment;
    UIButton *_closeButton, *_copyButton, *_shareButton;
}
- (UIButton *)makeButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b setTitleColor:VSToolCyanColor() forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.03 green:0.05 blue:0.08 alpha:1.0];
    _closeButton = [self makeButton:@"Đóng" action:@selector(closeTapped)];
    _copyButton = [self makeButton:@"Sao chép" action:@selector(copyTapped)];
    _shareButton = [self makeButton:@"Chia sẻ file" action:@selector(shareTapped)];
    _segment = [[UISegmentedControl alloc] initWithItems:@[@"Lần chạy cuối", @"Chỉ lỗi", @"Toàn bộ"]];
    _segment.selectedSegmentIndex = 0;
    [_segment addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_segment];
    _textView = [[UITextView alloc] init];
    _textView.editable = NO;
    _textView.backgroundColor = UIColor.clearColor;
    _textView.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    _textView.font = [UIFont fontWithName:@"Menlo" size:10.5] ?: [UIFont systemFontOfSize:10.5];
    [self.view addSubview:_textView];
    [self reload];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets ins = self.view.safeAreaInsets;
    CGFloat w = self.view.bounds.size.width, top = ins.top + 6;
    _closeButton.frame = CGRectMake(12, top, 70, 36);
    _copyButton.frame = CGRectMake(w - 12 - 200, top, 90, 36);
    _shareButton.frame = CGRectMake(w - 12 - 106, top, 106, 36);
    _segment.frame = CGRectMake(12, top + 44, w - 24, 32);
    CGFloat textTop = top + 84;
    _textView.frame = CGRectMake(8, textTop, w - 16, self.view.bounds.size.height - textTop - ins.bottom - 4);
}
- (void)reload {
    NSString *text = nil;
    switch (_segment.selectedSegmentIndex) {
        case 1: text = VSLogTextErrorsLastRun(); break;
        case 2: text = VSLogTextAll(); break;
        default: text = VSLogTextLastRun(); break;
    }
    if (!text.length) text = @"(log trống — chạy một chức năng rồi mở lại)";
    _textView.text = text;
    if (_segment.selectedSegmentIndex == 1) [_textView setContentOffset:CGPointZero animated:NO];
    else [_textView scrollRangeToVisible:NSMakeRange(text.length > 0 ? text.length - 1 : 0, 1)];
}
- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)copyTapped {
    UIPasteboard.generalPasteboard.string = _textView.text ?: @"";
    [_copyButton setTitle:@"Đã chép ✓" forState:UIControlStateNormal];
    VSDispatchAfterMS(1200, ^{ [self->_copyButton setTitle:@"Sao chép" forState:UIControlStateNormal]; });
}
- (void)shareTapped {
    NSString *path = VSLogWriteFile();
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = _shareButton;
    [self presentViewController:avc animated:YES completion:nil];
}
@end

// ============================================================================
// PHẦN 8: VSTOOL INTERFACE
// ============================================================================

@interface VSToolRootVC : UIViewController
@end

@interface VSTool : NSObject
@property (nonatomic, strong) VSToolPassThroughWindow *window;
@property (nonatomic, strong) UIButton *floatingButton;
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
- (void)adjustFloatingButtonBounds;
- (void)restoreOriginalQRCodeDelegate;
- (void)terminateCurrentTaskQuietly;
- (void)handleFabPan:(UIPanGestureRecognizer *)gesture;
- (void)fabClicked;
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
- (void)presentLogViewer;
- (void)showDebugSettings;

- (void)requestUserMediaSelectionOnEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(id clipResponse, VSLayerSnapshot *firstLayerInfo))done;
- (void)applyMediaResponse:(id)response toEditor:(id)editorVC skipLayer:(NSInteger)skipIndex runId:(NSUInteger)runId completion:(void (^)(NSUInteger changedCount, NSUInteger totalCount, NSUInteger failedCount, BOOL blockedByPurchase))done;
- (void)executeFeature1ReplaceLayers;
- (void)executeFeature2DisplayLastCode;
- (void)executeFeature3AutoSplitBeat;
- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)splitView runId:(NSUInteger)runId;
- (void)executeFeature4BatchMultiScene;
- (void)parseMergeRangeAndPresentCodePanel:(id)reviewVC runId:(NSUInteger)runId originalLastViewed:(NSUInteger)originalLastViewed;
- (NSUInteger)countOfReceivedCodes;
- (void)renderMultiSceneCodeCollectionPanel;
- (void)handleMultiSceneCancel;
- (void)restoreMultiSceneCodePanel;
- (void)handleCodeRowButtonTapped:(UIButton *)button;
- (void)handleMultiSceneProceedWithMedia;
- (void)showProcessingProgressPanel;
- (void)executeBatchProcessingScenesWithResponse:(id)response runId:(NSUInteger)runId;
- (void)openMultiLayerEditorForScene:(NSUInteger)sceneIndex reviewVC:(id)reviewVC runId:(NSUInteger)runId completion:(void (^)(id editorVC))done;
- (void)importPresetPayload:(id)preset codeIdentifier:(id)code intoEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
- (void)waitForEditorSettledThenCreate:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
- (void)triggerCreateInEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
@end

@implementation VSToolRootVC
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [VSTool.shared adjustFloatingButtonBounds]; }
@end

@implementation VSTool

+ (instancetype)shared {
    static VSTool *t; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ t = [VSTool new]; });
    return t;
}

- (void)setupToolInterfaceIfNeeded {
    if (self.window) return;
    static BOOL delayPassed = NO;
    if (!delayPassed) { delayPassed = YES; VSDispatchAfterMS(2500, ^{ [self setupToolInterfaceIfNeeded]; }); return; }

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

    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(b.size.width - 64, b.size.height * 0.35, 48, 48);
    fab.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.13 alpha:0.85];
    fab.layer.cornerRadius = 24.0;
    fab.layer.borderWidth = 1.5;
    fab.layer.borderColor = VSToolCyanColor().CGColor;
    [fab setTitle:@"VS" forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [fab setTitleColor:VSToolCyanColor() forState:UIControlStateNormal];
    [fab addTarget:self action:@selector(fabClicked) forControlEvents:UIControlEventTouchUpInside];
    [fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleFabPan:)]];
    [root.view addSubview:fab];

    UILabel *hud = [[UILabel alloc] init];
    hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    hud.textColor = UIColor.whiteColor;
    hud.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    hud.textAlignment = NSTextAlignmentCenter;
    hud.numberOfLines = 2;
    hud.layer.cornerRadius = 10; hud.clipsToBounds = YES; hud.hidden = YES;
    [root.view addSubview:hud];

    self.window = w; self.floatingButton = fab; self.statusHUDLabel = hud;
    self.multiSceneActiveCapturingIndex = -1;
    g_overlayToolWindow = w;
    w.hidden = NO;
    VSInstallCoreHooksOnce();
    VSLog(@"Giao diện VSTool đã cài");
}

- (void)adjustFloatingButtonBounds {
    if (!self.window || !self.floatingButton) return;
    UIView *c = self.window.rootViewController.view;
    UIEdgeInsets ins = c.safeAreaInsets;
    CGFloat hw = self.floatingButton.bounds.size.width / 2.0;
    CGPoint p = self.floatingButton.center;
    p.x = MIN(MAX(p.x, hw + 4), c.bounds.size.width - hw - 4);
    p.y = MIN(MAX(p.y, ins.top + hw + 4), c.bounds.size.height - ins.bottom - hw - 4);
    self.floatingButton.center = p;
}

- (void)handleFabPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.floatingButton.superview];
    self.floatingButton.center = CGPointMake(self.floatingButton.center.x + t.x, self.floatingButton.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.floatingButton.superview];
    if (g.state == UIGestureRecognizerStateEnded) [self adjustFloatingButtonBounds];
}

- (UIViewController *)topPresenterVC {
    UIViewController *vc = self.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (void)updateStatusHUD:(NSString *)msg {
    if (msg.length) VSLog(@"[HUD] %@", msg);
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
    [[self topPresenterVC] presentViewController:a animated:YES completion:nil];
}

- (void)dismissBottomActionBar { [self.bottomActionBar removeFromSuperview]; self.bottomActionBar = nil; }

- (UIView *)buildCardContainerWithFrame:(CGRect)f title:(NSString *)title subtitle:(NSString *)subtitle {
    UIView *card = [[UIView alloc] initWithFrame:f];
    card.backgroundColor = VSToolCardBackgroundColor();
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = 1.2;
    card.layer.borderColor = VSToolCyanColor().CGColor;
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, f.size.width - 32, 24)];
    h.text = title; h.textColor = VSToolCyanColor(); h.font = [UIFont boldSystemFontOfSize:17];
    h.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, f.size.width - 32, 36)];
    s.text = subtitle; s.numberOfLines = 0; s.textColor = [UIColor colorWithWhite:0.86 alpha:1.0]; s.font = [UIFont systemFontOfSize:13];
    s.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:h]; [card addSubview:s];
    return card;
}

- (void)displayBottomActionBarWithTitle:(NSString *)title message:(NSString *)msg confirmTitle:(NSString *)confirmTitle onConfirm:(void (^)(void))onConfirm onCancel:(void (^)(void))onCancel {
    [self dismissBottomActionBar];
    UIView *c = self.window.rootViewController.view;
    CGFloat w = MIN(c.bounds.size.width - 24, 460), h = 132;
    UIView *bar = [self buildCardContainerWithFrame:CGRectMake((c.bounds.size.width - w) / 2.0, c.bounds.size.height - c.safeAreaInsets.bottom - h - 70, w, h) title:title subtitle:msg];
    self.bottomBarConfirmBlock = onConfirm; self.bottomBarCancelBlock = onCancel;
    CGFloat bw = (w - 32 - 12) / 2.0;
    UIButton *cb = VSToolCreateOutlineButton(@"Hủy", CGRectMake(16, h - 52, bw, 38));
    cb.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1.0].CGColor;
    [cb setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    UIButton *ok = VSToolCreateOutlineButton(confirmTitle, CGRectMake(16 + bw + 12, h - 52, bw, 38));
    [cb addTarget:self action:@selector(handleBottomBarCancel) forControlEvents:UIControlEventTouchUpInside];
    [ok addTarget:self action:@selector(handleBottomBarConfirm) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:cb]; [bar addSubview:ok];
    [c addSubview:bar]; self.bottomActionBar = bar;
}

- (void)handleBottomBarConfirm { void (^cb)(void) = self.bottomBarConfirmBlock; self.bottomBarConfirmBlock = nil; self.bottomBarCancelBlock = nil; [self dismissBottomActionBar]; if (cb) cb(); }
- (void)handleBottomBarCancel { void (^cb)(void) = self.bottomBarCancelBlock; self.bottomBarConfirmBlock = nil; self.bottomBarCancelBlock = nil; [self dismissBottomActionBar]; if (cb) cb(); }

- (void)fabClicked {
    if (self.currentTaskName) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Đang chạy" message:self.currentTaskName preferredStyle:UIAlertControllerStyleAlert];
        if (self.multiSceneCardView && self.multiSceneCardView.hidden)
            [a addAction:[UIAlertAction actionWithTitle:@"Mở lại bảng QR" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self restoreMultiSceneCodePanel]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Dừng" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [self terminateCurrentTaskQuietly]; [self showNotificationAlert:@"Đã dừng" title:@"Đã Dừng"]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Tiếp tục" style:UIAlertActionStyleCancel handler:nil]];
        [[self topPresenterVC] presentViewController:a animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"VideoStarTool" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"1. Auto nhập ảnh vào các lớp" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self executeFeature1ReplaceLayers]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"2. Hiển thị code gần nhất" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self executeFeature2DisplayLastCode]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"3. Auto chia beat" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self executeFeature3AutoSplitBeat]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"4. Auto nhập code + ảnh vào phân cảnh" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self executeFeature4BatchMultiScene]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"5. Xem log lần chạy cuối" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self presentLogViewer]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"6. Cài đặt gỡ lỗi" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self showDebugSettings]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.floatingButton;
    sheet.popoverPresentationController.sourceRect = self.floatingButton.bounds;
    [[self topPresenterVC] presentViewController:sheet animated:YES completion:nil];
}

- (NSUInteger)startNewTaskWithDescription:(NSString *)name initialStatus:(NSString *)status {
    g_runIdentifier++;
    g_autoConfirmPopups = NO;
    g_suppressLayerActionMenu = NO;
    g_dismissLayerMenu = NO;
    g_guardCancel = NO;
    g_createInProgress = NO;
    g_taskActive = YES;
    VSLogRunStart(name);
    VSApplySettingsToRun();
    self.currentTaskName = name;
    self.floatingButton.alpha = 0.55;
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
    g_guardCancel = NO;
    g_createInProgress = NO;
    g_taskActive = NO;
    g_activeMediaPickedHandler = nil;
    [self restoreOriginalQRCodeDelegate];
    [self dismissBottomActionBar];
    [self.multiSceneCardView removeFromSuperview];
    self.multiSceneCardView = nil;
    self.multiSceneActiveCapturingIndex = -1;
    self.qrCaptureProxy = nil;
    self.currentTaskName = nil;
    self.floatingButton.alpha = 1.0;
    [self updateStatusHUD:nil];
}

- (void)finalizeTaskWithMessage:(NSString *)msg {
    VSLog(@"KẾT QUẢ: %@", msg.length ? msg : @"(không có)");
    VSLog(@"[Finish] vc=%@ mem=%.0fMB", VSDescribeVCChain(), VSAvailableMemoryMB());
    [self terminateCurrentTaskQuietly];
    if (msg.length) [self showRunResultAlert:msg title:@"VideoStarTool"];
}

- (void)showRunResultAlert:(NSString *)msg title:(NSString *)title {
    [self updateStatusHUD:nil];
    VSLogWriteFile();
    NSUInteger errs = VSLogErrorCountLastRun();
    NSString *full = errs ? [msg stringByAppendingFormat:@"\n\n⚠️ %lu dòng cảnh báo/lỗi trong log", (unsigned long)errs] : msg;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title ?: @"VideoStarTool" message:full preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Xem log" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self presentLogViewer]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [[self topPresenterVC] presentViewController:a animated:YES completion:nil];
}

- (void)presentLogViewer {
    VSToolLogViewController *vc = [VSToolLogViewController new];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [[self topPresenterVC] presentViewController:vc animated:YES completion:nil];
}

- (void)showDebugSettings {
    NSArray *items = @[
        @[kVSSetSuppressMenu, @"Chặn hẳn menu chọn lớp (hook)", @NO],
        @[kVSSetSkipReselect, @"Bỏ qua chọn lại lớp đang chọn", @NO],
        @[kVSSetDismissMenu,  @"Tự đóng menu chọn lớp", @YES],
        @[kVSSetGuardCancel,  @"Chặn Hủy/Đóng do code", @YES]];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Cài đặt gỡ lỗi" message:@"Bấm để bật/tắt, áp dụng từ lần chạy sau" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *item in items) {
        BOOL on = VSSettingBool(item[0], [item[2] boolValue]);
        NSString *title = [NSString stringWithFormat:@"%@: %@", item[1], on ? @"BẬT" : @"TẮT"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            VSSettingSet(item[0], !on);
            [self showDebugSettings];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Xoá toàn bộ log" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { VSLogClear(); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.floatingButton;
    sheet.popoverPresentationController.sourceRect = self.floatingButton.bounds;
    [[self topPresenterVC] presentViewController:sheet animated:YES completion:nil];
}

// ============================================================================
// PHẦN 9: FEATURE 1 — Auto replace layers
// ============================================================================

- (void)requestUserMediaSelectionOnEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(id, VSLayerSnapshot *))done {
    if (!g_origPickedWithResponse) { done(nil, nil); return; }

    g_activeMediaPickedHandler = ^(id me, id response) {
        if (runId != g_runIdentifier || me != editorVC) return;
        g_activeMediaPickedHandler = nil;
        VSLog(@"[Pick] đã chọn media: type=%@ clipIndex=%@", VSSafeValueForKey(response, @"clipPickerResponseType") ?: @"?", VSSafeValueForKey(response, @"clipIndex") ?: @"?");
        VSLogState(@"ngay sau khi chọn", me);
        __block VSLayerSnapshot *snap = nil;
        VSSafePoll(runId, 120, 100, ^BOOL{
            id eng = [me getMultiLayerEngine];
            NSInteger n = [me lastSelectedLayerNum];
            if (!eng || n < 0) return NO;
            snap = VSInspectLayerDetails(eng, (NSUInteger)n);
            return snap != nil && VSLayerKindIsReplaceable(snap.mediaKind);
        }, ^(BOOL ok) {
            if (runId != g_runIdentifier) return;
            VSLog(@"[Pick] lớp đầu sau khi chọn: %@ (ok=%d)", snap ? VSKindName(snap.mediaKind) : @"nil", ok);
            VSLogState(@"lớp đầu đã nhận media", me);
            done(response, snap);
        });
    };

    VSSafePoll(runId, 100, 60, ^BOOL{
        return [editorVC isViewLoaded] && [[editorVC view] window] && [editorVC getMultiLayerEngine];
    }, ^(BOOL ready) {
        if (runId != g_runIdentifier) return;
        if (!ready) { g_activeMediaPickedHandler = nil; done(nil, nil); return; }

        void (^openPicker)(void) = ^{
            VSDispatchAfterMS(150, ^{
                if (runId != g_runIdentifier) return;
                if (!VSTry(^{ [editorVC pickNewContent]; })) { g_activeMediaPickedHandler = nil; done(nil, nil); }
            });
        };

        VSLayerSnapshot *first = nil;
        @try { first = VSFirstReplaceableLayer([editorVC getMultiLayerEngine]); } @catch (...) {}
        if (!first) { openPicker(); return; }
        VSSelectLayerOnEditor(editorVC, first.layerIndex, runId, ^(BOOL selected) {
            if (runId != g_runIdentifier) return;
            if (!selected) { g_activeMediaPickedHandler = nil; done(nil, nil); return; }
            openPicker();
        });
    });
}

- (void)applyMediaResponse:(id)response toEditor:(id)editorVC skipLayer:(NSInteger)skipIndex runId:(NSUInteger)runId completion:(void (^)(NSUInteger, NSUInteger, NSUInteger, BOOL))done {
    __block NSUInteger idleChecks = 0;
    VSSafePoll(runId, 100, 100, ^BOOL{
        VSDismissLayerActionMenus(editorVC);
        idleChecks = VSEditorIsBusy(editorVC) ? 0 : idleChecks + 1;
        return idleChecks >= 2;
    }, ^(BOOL idle) {
        if (runId != g_runIdentifier) return;

        id engine = nil;
        @try { engine = [editorVC getMultiLayerEngine]; } @catch (...) {}
        if (!engine) { done(0, 0, 0, NO); return; }

        NSMutableArray<NSNumber *> *targets = [NSMutableArray array];
        for (VSLayerSnapshot *snap in VSScanLayers(engine)) {
            if (!VSLayerKindIsReplaceable(snap.mediaKind)) continue;
            if ((NSInteger)snap.layerIndex == skipIndex) continue;
            [targets addObject:@(snap.layerIndex)];
        }
        NSUInteger total = targets.count;
        VSLog(@"[Apply] bắt đầu: %lu lớp cần thay (skip=%ld) idle=%d", (unsigned long)total, (long)skipIndex, idle);
        VSLogState(@"trước khi thay ngầm", editorVC);
        if (total == 0) { done(0, 0, 0, NO); return; }

        __block NSUInteger idx = 0, changed = 0, failed = 0;
        __block BOOL blockedPurchase = NO;
        __block void (^iterate)(void) = nil;

        BOOL (^cancelled)(void) = ^BOOL{
            if (runId != g_runIdentifier) { iterate = nil; return YES; }
            return NO;
        };
        // FIX: log rõ editor còn sống hay đã bị đóng ở cuối.
        void (^finishRun)(void) = ^{
            iterate = nil;
            VSDismissLayerActionMenus(editorVC);
            if (changed > 0) VSRefreshEditorAfterReplace(editorVC, engine);
            NSUInteger notReached = (idx < total) ? (total - idx) : 0;
            BOOL editorDead = !VSEditorIsAlive(editorVC);
            VSLog(@"[Apply] kết thúc: confirmed=%lu total=%lu failed=%lu chưaTới=%lu blocked=%d editorAlive=%d",
                  (unsigned long)changed, (unsigned long)total, (unsigned long)failed,
                  (unsigned long)notReached, blockedPurchase, !editorDead);
            VSLogState(@"sau khi thay ngầm", editorVC);
            done(changed, total, failed + notReached, blockedPurchase);
        };
        void (^next)(void) = ^{ VSDispatchAfterMS(30, ^{ if (iterate) iterate(); }); };

        iterate = ^{
            if (cancelled()) return;
            if (idx >= total) { finishRun(); return; }
            if (!VSEditorIsAlive(editorVC)) { VSLog(@"Editor đã bị đóng giữa chừng → dừng"); finishRun(); return; }
            VSDismissLayerActionMenus(editorVC);

            NSUInteger waitTries = g_autoConfirmPopups ? 150 : 1200;
            VSSafePoll(runId, 100, waitTries, ^BOOL{
                if (VSResolvePopupsImmediately(editorVC) == VSPopupActionStatusBlockedPurchase) { blockedPurchase = YES; return YES; }
                return !VSHasAnyActivePopup(editorVC);
            }, ^(BOOL clear) {
                if (cancelled()) return;
                if (blockedPurchase || !clear) { finishRun(); return; }

                NSUInteger n = targets[idx++].unsignedIntegerValue;
                [self updateStatusHUD:[NSString stringWithFormat:@"Đang thay: lớp %lu (%lu/%lu)", (unsigned long)(n + 1), (unsigned long)idx, (unsigned long)total]];

                VSSelectLayerOnEditor(editorVC, n, runId, ^(BOOL selected) {
                    if (cancelled()) return;
                    if (!selected) { VSLog(@"layer %lu: chọn lớp thất bại", (unsigned long)n); failed++; next(); return; }

                    VSDispatchAfterMS(40, ^{
                        if (cancelled()) return;

                        // FIX: chờ menu chọn lớp đóng hẳn trước khi replay.
                        VSSafePoll(runId, 50, 20, ^BOOL{
                            VSDismissLayerActionMenus(editorVC);
                            return !VSHasVisibleLayerActionMenu(editorVC);
                        }, ^(BOOL menuGone) {
                            if (cancelled()) return;
                            if (!menuGone) VSLog(@"layer %lu: menu chọn lớp chưa đóng hết, vẫn thử replay", (unsigned long)n);

                            if (!VSEditorIsAlive(editorVC)) {
                                VSLog(@"Editor đã đóng trước replay lớp %lu", (unsigned long)n);
                                failed++;
                                finishRun();
                                return;
                            }

                            VSLayerSnapshot *before = VSInspectLayerDetails(engine, n);
                            if (!before || !VSLayerKindIsReplaceable(before.mediaKind)) {
                                VSLog(@"layer %lu: không còn là video/ảnh → bỏ qua", (unsigned long)n);
                                next();
                                return;
                            }
                            NSString *beforeSignature = before.signature ?: @"";
                            VSLogState([NSString stringWithFormat:@"lớp %lu trước replay", (unsigned long)(n + 1)], editorVC);
                            if (!VSReplayClipPickerResponseOnEditor(editorVC, response)) {
                                VSLog(@"layer %lu: replay fail", (unsigned long)n);
                                failed++;
                                next();
                                return;
                            }

                            CFAbsoluteTime replayStart = CFAbsoluteTimeGetCurrent();
                            __block BOOL confirmed = NO, blocked = NO, changedSeen = NO;
                            __block CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 8.0;
                            __block CFAbsoluteTime idleDeadline = 0;
                            NSUInteger confirmTries = g_autoConfirmPopups ? 500 : 2000;
                            VSSafePoll(runId, 80, confirmTries, ^BOOL{
                                VSDismissLayerActionMenus(editorVC);
                                if (!VSEditorIsAlive(editorVC)) return YES;
                                if (VSResolvePopupsImmediately(editorVC) == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
                                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                                if (VSHasAnyActivePopup(editorVC)) {
                                    deadline = MAX(deadline, now + 2.5);
                                    if (changedSeen) idleDeadline = MAX(idleDeadline, now + 4.0);
                                    return NO;
                                }
                                if (!changedSeen) {
                                    VSLayerSnapshot *cur = VSInspectLayerDetails(engine, n);
                                    if (cur && ![cur.signature ?: @"" isEqualToString:beforeSignature]) {
                                        changedSeen = YES; confirmed = YES; idleDeadline = now + 6.0;
                                    } else {
                                        return now > deadline;
                                    }
                                }
                                if (VSEditorIsBusy(editorVC) && now < idleDeadline) return NO;
                                return YES;
                            }, ^(BOOL r) {
                                if (cancelled()) return;
                                if (blocked) { blockedPurchase = YES; finishRun(); return; }
                                if (!VSEditorIsAlive(editorVC)) { VSLog(@"Editor đóng trong lúc thay lớp %lu", (unsigned long)n); failed++; finishRun(); return; }
                                if (confirmed) changed++;
                                VSLog(@"layer %lu: %@ (mất %.1fs)", (unsigned long)n, confirmed ? @"✅" : @"⚠️ chưa xác nhận", CFAbsoluteTimeGetCurrent() - replayStart);
                                VSLogState([NSString stringWithFormat:@"lớp %lu sau replay", (unsigned long)(n + 1)], editorVC);
                                next();
                            });
                        });
                    });
                });
            });
        };
        VSDispatchAfterMS(200, ^{ if (iterate) iterate(); });
    });
}

- (void)executeFeature1ReplaceLayers {
    id editor = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
    if (!editor) { [self showNotificationAlert:@"Vào màn hình Nhiều lớp trước." title:@"Chưa ở Nhiều lớp"]; return; }

    id engine = nil;
    @try { engine = [editor getMultiLayerEngine]; } @catch (...) {}
    if (!VSFirstReplaceableLayer(engine)) {
        [self showNotificationAlert:@"Không có lớp video/ảnh nào để thay." title:@"Không có lớp"];
        return;
    }

    NSUInteger runId = [self startNewTaskWithDescription:@"Auto nhập ảnh" initialStatus:@"Chọn 1 ảnh/video…"];
    [self requestUserMediaSelectionOnEditor:editor runId:runId completion:^(id clipResponse, VSLayerSnapshot *first) {
        if (runId != g_runIdentifier) return;
        if (!clipResponse) { [self finalizeTaskWithMessage:@"Không nhận được media"]; return; }
        if (!first || !VSLayerKindIsReplaceable(first.mediaKind)) {
            [self finalizeTaskWithMessage:@"Lớp đầu không phải ảnh/video (đã chọn Màu / Văn bản / GIF?)"];
            return;
        }
        [self applyMediaResponse:clipResponse toEditor:editor skipLayer:(NSInteger)first.layerIndex runId:runId completion:^(NSUInteger c, NSUInteger t, NSUInteger f, BOOL blocked) {
            NSString *msg = t == 0 ? @"Xong lớp đầu, không còn lớp video/ảnh nào khác"
                                   : [NSString stringWithFormat:@"Xong lớp đầu + %lu/%lu lớp còn lại%@", (unsigned long)c, (unsigned long)t,
                                      f ? [NSString stringWithFormat:@" (%lu lớp lỗi)", (unsigned long)f] : @""];
            [self finalizeTaskWithMessage:blocked ? [msg stringByAppendingString:@"\nDừng vì popup mua Pro"] : msg];
        }];
    }];
}

// ============================================================================
// PHẦN 10: FEATURE 2
// ============================================================================

- (void)executeFeature2DisplayLastCode {
    UIImage *img = VSReadLastPersistedQRCodeImage();
    if (!img) { [self showNotificationAlert:@"Chưa có QR nào" title:@"Chưa có"]; return; }
    if (!VSDecodeQRCodeMessageFromImage(img)) { [self showNotificationAlert:@"QR không hợp lệ" title:@"Lỗi"]; return; }
    VSToolQRCodePreviewVC *vc = [VSToolQRCodePreviewVC new];
    vc.qrImage = img;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [[self topPresenterVC] presentViewController:vc animated:YES completion:nil];
}

// ============================================================================
// PHẦN 11: FEATURE 3 — Beat split
// ============================================================================

- (void)executeFeature3AutoSplitBeat {
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!reviewVC) { [self showNotificationAlert:@"Vào màn hình Review trước." title:@"Sai vị trí"]; return; }
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto chia beat" initialStatus:@"Chuẩn bị…"];

    id (^fetchSV)(void) = ^id{ return VSSafeValueForKey(reviewVC, @"splitView"); };
    BOOL (^visible)(void) = ^BOOL{
        id sv = fetchSV(); if (!sv) return NO;
        UIView *v = [sv isKindOfClass:[UIView class]] ? sv : VSSafeValueForKey(sv, @"splitPanel");
        return [v isKindOfClass:[UIView class]] && v.window != nil;
    };
    if (!visible()) {
        if (!VSTry(^{ [reviewVC showSplitScene]; })) { [self finalizeTaskWithMessage:@"Không mở được bảng chia"]; return; }
    }

    VSSafePoll(runId, 100, 35, ^BOOL{ return visible(); }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        id sv = fetchSV();
        if (!ok || !sv) { [self finalizeTaskWithMessage:@"Không tìm thấy MultiSplitView"]; return; }
        [self validateAndRunBeatSplitting:reviewVC splitView:sv runId:runId];
    });
}

- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)sv runId:(NSUInteger)runId {
    __block NSString *err = nil;
    VSTry(^{
        id<ProjectInterface> p = [reviewVC project];
        NSUInteger s = [reviewVC sceneIndex];
        NSUInteger cc = [p clipCountForSceneIndex:s];
        if (![reviewVC isEnoughStorageAvailableForSplit]) err = @"Bộ nhớ không đủ";
        else if (![p sceneHasAtLeastOneClipWithSceneIndex:s] || cc == 0) err = @"Không có clip";
    });
    if (err) { [self finalizeTaskWithMessage:err]; return; }

    id<ProjectInterface> p = [reviewVC project];
    if (!p) { [self finalizeTaskWithMessage:@"Lỗi kiểm tra"]; return; }
    NSUInteger before = [p sceneCount];
    BOOL started = VSTry(^{
        if (![sv beatModeOn]) [sv toggleBeatMode];
        [sv gotoTime:kCMTimeZero];
    });
    if (!started) { [self finalizeTaskWithMessage:@"Không bật Beat Mode"]; return; }

    __block NSUInteger guard = 0, count = 0;
    __block CMTime last = kCMTimeInvalid;
    __block void (^step)(void) = nil;

    void (^finish)(void) = ^{
        step = nil;
        if (runId != g_runIdentifier) return;
        if (count == 0 && VSCountOf(VSSafeValueForKey(sv, @"splitTimes")) == 0) { [self finalizeTaskWithMessage:@"Không có beat"]; return; }
        if (!VSTry(^{ [sv doSplit]; })) { [self finalizeTaskWithMessage:@"Lỗi chia"]; return; }
        [self updateStatusHUD:@"Đang chia…"];
        VSSafePoll(runId, 120, 150, ^BOOL{ return [p sceneCount] > before; }, ^(BOOL ok) {
            if (runId != g_runIdentifier) return;
            [self finalizeTaskWithMessage:ok ? [NSString stringWithFormat:@"Xong, +%lu scene", (unsigned long)([p sceneCount] - before)] : @"Chưa xong"];
        });
    };

    step = ^{
        if (runId != g_runIdentifier) { step = nil; return; }
        if (++guard >= 2048) { finish(); return; }
        __block BOOL hasNext = NO;
        __block CMTime fromTime = kCMTimeInvalid;
        BOOL called = VSTry(^{
            hasNext = [sv hasNextBeat];
            if (hasNext) { fromTime = VSSafeCurrentTime(sv); [sv jumpToNextBeat]; }
        });
        if (!called || !hasNext) { finish(); return; }
        CMTime from = fromTime;
        VSSafePoll(runId, 16, 60, ^BOOL{
            CMTime cur = VSSafeCurrentTime(sv);
            return CMTIME_IS_VALID(cur) && (CMTIME_IS_INVALID(from) || CMTimeCompare(cur, from) > 0);
        }, ^(BOOL moved) {
            if (runId != g_runIdentifier) { step = nil; return; }
            CMTime cur = VSSafeCurrentTime(sv);
            if (!moved || (CMTIME_IS_VALID(last) && CMTimeCompare(cur, last) <= 0)) { finish(); return; }
            last = cur;
            if (!VSTry(^{ [sv setSplitPoint]; })) { finish(); return; }
            count++;
            [self updateStatusHUD:[NSString stringWithFormat:@"%lu điểm chia…", (unsigned long)count]];
            VSDispatchAfterMS(20, ^{ if (step) step(); });
        });
    };
    VSDispatchAfterMS(250, ^{ if (step) step(); });
}

// ============================================================================
// PHẦN 12: FEATURE 4 — Batch multi-scene
// ============================================================================

- (void)executeFeature4BatchMultiScene {
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!reviewVC) { [self showNotificationAlert:@"Vào màn hình phân cảnh trước" title:@"Sai vị trí"]; return; }
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto code + ảnh" initialStatus:nil];

    NSUInteger origScene = 0;
    @try { origScene = [reviewVC lastViewedSceneIndex]; } @catch (...) {}
    if (!VSTry(^{ [reviewVC showMergeScenes]; })) { [self finalizeTaskWithMessage:@"Không mở được Hợp nhất"]; return; }
    [self displayBottomActionBarWithTitle:@"Chọn phân cảnh" message:@"Chọn đầu và cuối, bấm Bắt đầu" confirmTitle:@"Bắt đầu" onConfirm:^{
        [self parseMergeRangeAndPresentCodePanel:reviewVC runId:runId originalLastViewed:origScene];
    } onCancel:^{ VSTry(^{ [reviewVC closeMergePanel]; }); [self terminateCurrentTaskQuietly]; }];
}

- (void)parseMergeRangeAndPresentCodePanel:(id)reviewVC runId:(NSUInteger)runId originalLastViewed:(NSUInteger)orig {
    if (runId != g_runIdentifier) return;
    id<ProjectInterface> p = nil;
    @try { p = [reviewVC project]; } @catch (...) {}
    NSInteger total = p ? (NSInteger)[p sceneCount] : 0;
    id sObj = VSSafeValueForKey(reviewVC, @"startScene"), lObj = VSSafeValueForKey(reviewVC, @"lastScene");
    NSInteger s = [sObj respondsToSelector:@selector(integerValue)] ? [sObj integerValue] : -1;
    NSInteger l = [lObj respondsToSelector:@selector(integerValue)] ? [lObj integerValue] : -1;
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
    [self renderMultiSceneCodeCollectionPanel];
}

- (NSUInteger)countOfReceivedCodes {
    NSUInteger c = 0;
    for (id code in self.multiSceneCodes) if (code != [NSNull null]) c++;
    return c;
}

- (void)renderMultiSceneCodeCollectionPanel {
    if (self.multiSceneRunId != g_runIdentifier) return;
    [self.multiSceneCardView removeFromSuperview];
    UIView *c = self.window.rootViewController.view;
    UIEdgeInsets ins = c.safeAreaInsets;
    CGFloat w = MIN(c.bounds.size.width - 24, 460);
    CGFloat top = ins.top + 28, h = c.bounds.size.height - top - ins.bottom - 84;
    NSUInteger got = [self countOfReceivedCodes];
    UIView *card = [self buildCardContainerWithFrame:CGRectMake((c.bounds.size.width - w) / 2.0, top, w, h) title:@"Nhập QR" subtitle:[NSString stringWithFormat:@"Đã nhận %lu/%lu", (unsigned long)got, (unsigned long)self.multiSceneCount]];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 70, w - 24, h - 70 - 66)];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    for (NSUInteger i = 0; i < self.multiSceneCount; i++) {
        BOOL has = (self.multiSceneCodes[i] != [NSNull null]);
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, i * 68, sv.bounds.size.width, 60)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06]; row.layer.cornerRadius = 10;
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 9, row.bounds.size.width - 140, 20)];
        t.text = [NSString stringWithFormat:@"Phân cảnh %lu", (unsigned long)(self.multiSceneStart + i + 1)];
        t.textColor = UIColor.whiteColor; t.font = [UIFont boldSystemFontOfSize:15];
        UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(14, 33, row.bounds.size.width - 140, 16)];
        s.text = has ? @"Đã nhận" : @"Chưa nhập";
        s.textColor = has ? VSToolCyanColor() : [UIColor colorWithWhite:0.6 alpha:1.0];
        s.font = [UIFont systemFontOfSize:11];
        UIButton *b = VSToolCreateOutlineButton(has ? @"Đổi code" : @"Nhập code", CGRectMake(row.bounds.size.width - 112, 12, 100, 36));
        b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(handleCodeRowButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:t]; [row addSubview:s]; [row addSubview:b];
        [sv addSubview:row];
    }
    sv.contentSize = CGSizeMake(sv.bounds.size.width, self.multiSceneCount * 68);
    [card addSubview:sv];
    CGFloat bw = (w - 32 - 12) / 2.0;
    UIButton *cb = VSToolCreateOutlineButton(@"Hủy", CGRectMake(16, h - 52, bw, 38));
    cb.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1.0].CGColor;
    [cb setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    cb.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [cb addTarget:self action:@selector(handleMultiSceneCancel) forControlEvents:UIControlEventTouchUpInside];
    UIButton *nx = VSToolCreateOutlineButton(@"Chọn ảnh/video", CGRectMake(16 + bw + 12, h - 52, bw, 38));
    nx.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    nx.enabled = (got == self.multiSceneCount);
    [nx addTarget:self action:@selector(handleMultiSceneProceedWithMedia) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cb]; [card addSubview:nx];
    [c addSubview:card];
    self.multiSceneCardView = card;
}

- (void)handleMultiSceneCancel { [self terminateCurrentTaskQuietly]; }

- (void)restoreMultiSceneCodePanel {
    g_activeMediaPickedHandler = nil;
    [self restoreOriginalQRCodeDelegate];
    self.qrCaptureProxy = nil;
    self.multiSceneActiveCapturingIndex = -1;
    [self updateStatusHUD:nil];
    if (self.multiSceneCardView && self.multiSceneCount > 0) [self renderMultiSceneCodeCollectionPanel];
}

- (void)handleCodeRowButtonTapped:(UIButton *)btn {
    NSUInteger off = (NSUInteger)btn.tag;
    if (off >= self.multiSceneCount) return;
    Class qc = NSClassFromString(@"QRCodeManager");
    id qr = [qc respondsToSelector:@selector(sharedInstance)] ? [qc sharedInstance] : nil;
    if (!qr || ![qr respondsToSelector:@selector(startQRImport)]) { [self showNotificationAlert:@"Không có QRCodeManager" title:@"Lỗi"]; return; }
    VSToolQRCodeCaptureProxy *proxy = [VSToolQRCodeCaptureProxy new];
    NSUInteger runId = self.multiSceneRunId;
    proxy.onCodeCapturedBlock = ^(id preset, id code) {
        if (runId != g_runIdentifier || self.multiSceneActiveCapturingIndex != (NSInteger)off) return;
        [self restoreOriginalQRCodeDelegate];
        self.qrCaptureProxy = nil;
        self.multiSceneActiveCapturingIndex = -1;
        if (!preset || ![code isKindOfClass:[NSString class]] || ![(NSString *)code length]) {
            [self renderMultiSceneCodeCollectionPanel];
            [self showNotificationAlert:@"Mã QR không hợp lệ" title:@"Lỗi"];
            return;
        }
        self.multiScenePresets[off] = preset;
        self.multiSceneCodes[off] = code;
        [self renderMultiSceneCodeCollectionPanel];
    };
    self.qrCaptureProxy = proxy;
    self.multiSceneActiveCapturingIndex = (NSInteger)off;
    if (!self.savedOriginalQRDelegateValid) {
        self.savedOriginalQRDelegate = VSSafeValueForKey(qr, @"delegate");
        self.savedOriginalQRDelegateValid = YES;
    }
    @try {
        VSSetQRDelegateSafely(qr, proxy);
        self.multiSceneCardView.hidden = YES;
        [qr startQRImport];
    } @catch (NSException *e) {
        [self restoreMultiSceneCodePanel];
        [self showNotificationAlert:[NSString stringWithFormat:@"Lỗi mở QR: %@", e.reason ?: e.name] title:@"Lỗi"];
    }
}

- (void)handleMultiSceneProceedWithMedia {
    NSUInteger runId = self.multiSceneRunId;
    if (runId != g_runIdentifier || [self countOfReceivedCodes] != self.multiSceneCount) return;
    g_autoConfirmPopups = YES;
    self.multiSceneCardView.hidden = YES;
    [self updateStatusHUD:@"Mở Nhiều lớp ở scene đầu…"];
    id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    [self openMultiLayerEditorForScene:self.multiSceneStart reviewVC:rvc runId:runId completion:^(id editor) {
        if (runId != g_runIdentifier) return;
        if (!editor) { [self finalizeTaskWithMessage:@"Không mở được Nhiều lớp"]; return; }
        [self updateStatusHUD:@"Chọn 1 ảnh/video dùng chung…"];
        [self requestUserMediaSelectionOnEditor:editor runId:runId completion:^(id resp, VSLayerSnapshot *first) {
            if (runId != g_runIdentifier) return;
            if (!resp) { [self finalizeTaskWithMessage:@"Không lấy được media"]; return; }
            if (!first || !VSLayerKindIsReplaceable(first.mediaKind)) {
                [self finalizeTaskWithMessage:@"Lớp đầu không phải ảnh/video (đã chọn Màu / Văn bản / GIF?)"];
                return;
            }
            [self.multiSceneCardView removeFromSuperview];
            self.multiSceneCardView = nil;
            [self updateStatusHUD:nil];
            [self showProcessingProgressPanel];
            [self executeBatchProcessingScenesWithResponse:resp runId:runId];
        }];
    }];
}

- (void)showProcessingProgressPanel {
    UIView *c = self.window.rootViewController.view;
    CGFloat w = MIN(c.bounds.size.width - 24, 460), h = 132;
    UIView *card = [self buildCardContainerWithFrame:CGRectMake((c.bounds.size.width - w) / 2.0, c.bounds.size.height - c.safeAreaInsets.bottom - h - 70, w, h) title:@"Đang áp dụng" subtitle:@"Xử lý từng phân cảnh…"];
    UIButton *b = VSToolCreateOutlineButton(@"Đang chạy…", CGRectMake(w - 16 - 130, h - 52, 130, 38));
    b.enabled = NO;
    [card addSubview:b];
    [c addSubview:card];
    self.multiSceneCardView = card;
}

- (void)executeBatchProcessingScenesWithResponse:(id)resp runId:(NSUInteger)runId {
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
        VSLog(@"[Finish] vc=%@ mem=%.0fMB", VSDescribeVCChain(), VSAvailableMemoryMB());
        [self terminateCurrentTaskQuietly];
        NSString *msg = [NSString stringWithFormat:@"Xong %lu/%lu scene", (unsigned long)okCount, (unsigned long)total];
        NSString *fullMsg = err ? [err stringByAppendingFormat:@"\n%@", msg] : msg;
        VSLog(@"KẾT QUẢ: %@", fullMsg);
        [self showRunResultAlert:fullMsg title:err ? @"Dừng" : @"Thành công"];
    };

    step = ^{
        if (runId != g_runIdentifier) { step = nil; return; }
        if (offset >= total) { finish(nil); return; }
        NSUInteger o = offset++, sc = start + o;
        [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu (%lu/%lu): mở…", (unsigned long)(sc + 1), (unsigned long)(o + 1), (unsigned long)total]];
        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        [self openMultiLayerEditorForScene:sc reviewVC:rvc runId:runId completion:^(id editor) {
            if (runId != g_runIdentifier) { step = nil; return; }
            if (!editor) { finish([NSString stringWithFormat:@"Không mở được scene %lu", (unsigned long)(sc + 1)]); return; }
            [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: nhập code…", (unsigned long)(sc + 1)]];
            [self importPresetPayload:presets[o] codeIdentifier:codes[o] intoEditor:editor runId:runId completion:^(NSString *e1) {
                if (runId != g_runIdentifier) { step = nil; return; }
                if (e1) { finish([NSString stringWithFormat:@"Scene %lu: %@", (unsigned long)(sc + 1), e1]); return; }
                [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: đợi ổn định…", (unsigned long)(sc + 1)]];
                VSDispatchAfterMS(500, ^{
                    if (runId != g_runIdentifier) { step = nil; return; }
                    [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: thay media…", (unsigned long)(sc + 1)]];
                    [self applyMediaResponse:resp toEditor:editor skipLayer:-1 runId:runId completion:^(NSUInteger c, NSUInteger t, NSUInteger f, BOOL blocked) {
                        if (runId != g_runIdentifier) { step = nil; return; }
                        if (blocked) { finish([NSString stringWithFormat:@"Scene %lu: popup mua Pro", (unsigned long)(sc + 1)]); return; }
                        if (!VSEditorIsAlive(editor)) { finish([NSString stringWithFormat:@"Scene %lu: editor bị đóng trước khi Tạo", (unsigned long)(sc + 1)]); return; }
                        if (f > 0) { finish([NSString stringWithFormat:@"Scene %lu: còn %lu lớp chưa thay được — chưa bấm Tạo", (unsigned long)(sc + 1), (unsigned long)f]); return; }
                        [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: đã thay %lu/%lu lớp, chuẩn bị Tạo…", (unsigned long)(sc + 1), (unsigned long)c, (unsigned long)t]];
                        [self waitForEditorSettledThenCreate:editor runId:runId completion:^(NSString *e2) {
                            if (runId != g_runIdentifier) { step = nil; return; }
                            if (e2) { finish([NSString stringWithFormat:@"Scene %lu: %@", (unsigned long)(sc + 1), e2]); return; }
                            okCount++;
                            VSSafePoll(runId, 100, 120, ^BOOL{ return VSFindTopViewControllerNamed(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                                if (runId != g_runIdentifier) { step = nil; return; }
                                if (!back) { finish(@"Không quay lại được"); return; }
                                VSDispatchAfterMS(300, ^{ if (step) step(); });
                            });
                        }];
                    }];
                });
            }];
        }];
    };
    step();
}

- (void)openMultiLayerEditorForScene:(NSUInteger)scene reviewVC:(id)rvc runId:(NSUInteger)runId completion:(void (^)(id))done {
    id (^current)(void) = ^id{
        id ed = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
        if (!ed || ![ed getMultiLayerEngine]) return nil;
        id nav = [ed navigationController];
        BOOL ok = YES;
        if ([nav respondsToSelector:@selector(navSceneIndex)]) ok = ([nav navSceneIndex] == scene);
        return ok ? ed : nil;
    };
    id existing = nil;
    @try { existing = current(); } @catch (...) {}
    if (existing) { done(existing); return; }
    if (!rvc) { done(nil); return; }
    if (!VSTry(^{ [rvc setLastViewedSceneIndex:scene]; [rvc showMultiLayer]; })) { done(nil); return; }
    VSSafePoll(runId, 80, 100, ^BOOL{ return current() != nil; }, ^(BOOL ok) {
        id ed = nil;
        if (ok) { @try { ed = current(); } @catch (...) {} }
        done(ed);
    });
}

- (void)importPresetPayload:(id)preset codeIdentifier:(id)code intoEditor:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    if (![editor respondsToSelector:@selector(importedData:code:)]) { done(@"Editor không hỗ trợ"); return; }
    NSUInteger before = g_presetImportEventCounter;
    @try { [editor importedData:preset code:code]; }
    @catch (NSException *e) { done([NSString stringWithFormat:@"Lỗi nạp: %@", e.reason ?: e.name]); return; }
    __block BOOL blocked = NO;
    VSSafePoll(runId, 50, 200, ^BOOL{
        VSPopupActionStatus s = VSResolvePopupsImmediately(editor);
        if (s == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
        return g_presetImportEventCounter > before;
    }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        if (blocked) { done(@"Popup mua Pro"); return; }
        if (!ok) { done(@"Timeout 10s"); return; }
        VSDispatchAfterMS(500, ^{
            if (runId != g_runIdentifier) return;
            id engine = [editor getMultiLayerEngine];
            __block BOOL purchase = NO;
            VSSafePoll(runId, 60, 60, ^BOOL{
                if (VSResolvePopupsImmediately(editor) == VSPopupActionStatusBlockedPurchase) { purchase = YES; return YES; }
                return !VSHasAnyActivePopup(editor) && [engine numActiveLayers] > 0;
            }, ^(BOOL ready) {
                if (runId != g_runIdentifier) return;
                done(purchase ? @"Popup mua Pro" : (ready ? nil : @"Engine chưa sẵn sàng"));
            });
        });
    });
}

- (void)waitForEditorSettledThenCreate:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    __block NSUInteger stable = 0;
    __block BOOL purchase = NO;
    VSSafePoll(runId, 100, 150, ^BOOL{
        if (!VSEditorIsAlive(editor)) return YES;
        VSDismissLayerActionMenus(editor);
        if (VSResolvePopupsImmediately(editor) == VSPopupActionStatusBlockedPurchase) { purchase = YES; return YES; }
        BOOL calm = !VSHasAnyActivePopup(editor) && !VSEditorIsBusy(editor);
        stable = calm ? stable + 1 : 0;
        return stable >= 8;
    }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        if (purchase) { done(@"Popup mua Pro"); return; }
        if (!VSEditorIsAlive(editor)) { done(@"Editor bị đóng trước khi Tạo"); return; }
        if (!ok) { done(@"Editor chưa ổn định để Tạo (còn popup / đang tải)"); return; }
        [self triggerCreateInEditor:editor runId:runId completion:done];
    });
}

- (void)triggerCreateInEditor:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    UIBarButtonItem *btn = VSFindCreateButtonOnEditor(editor);
    if (!btn) { done(@"Không tìm thấy nút Tạo"); return; }
    VSLog(@"[Create] '%@' action='%@' enabled=%d", btn.title ?: @"?", btn.action ? NSStringFromSelector(btn.action) : @"?", btn.enabled);
    VSLogState(@"ngay trước khi Tạo", editor);
    g_createInProgress = YES;
    __block BOOL fired = NO;
    if (btn.action && btn.target) {
        if (!VSTry(^{ fired = [UIApplication.sharedApplication sendAction:btn.action to:btn.target from:btn forEvent:nil]; })) {
            done(@"Lỗi nhấn nút Tạo"); return;
        }
    }
    if (!fired && [editor respondsToSelector:@selector(create)]) {
        if (!VSTry(^{ [editor create]; fired = YES; })) { done(@"Lỗi create"); return; }
    }
    if (!fired) { g_createInProgress = NO; done(@"Không kích hoạt được"); return; }
    __block BOOL blocked = NO;
    VSSafePoll(runId, 100, 600, ^BOOL{
        if (VSResolvePopupsImmediately(editor) == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
        return !([editor isViewLoaded] && [[editor view] window]);
    }, ^(BOOL closed) {
        g_createInProgress = NO;
        VSLog(@"[Create] kết quả: closed=%d blocked=%d vc=%@", closed, blocked, VSDescribeVCChain());
        if (runId != g_runIdentifier) return;
        done(blocked ? @"Tạo yêu cầu Pro" : (closed ? nil : @"Tạo timeout"));
    });
}

@end

// ============================================================================
// PHẦN 13: ENTRY POINT
// ============================================================================

static void VSBootstrapAutomation(void) {
    if (!NSClassFromString(@"MultiLayerWizEffectVC")) {
        VSLog(@"Không phải Video Star");
        return;
    }
    VSRunOnMain(^{
        @try { [VSTool.shared setupToolInterfaceIfNeeded]; }
        @catch (NSException *e) { VSLog(@"Setup error: %@", e); }
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
