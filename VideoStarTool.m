// ============================================================================
// VideoStarTool.m — full + fix replay confirmAddingLayer không dismiss editor
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

// ===== LOG =====
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
static void VSLogClear(void) { if (!g_logQueue) return; dispatch_sync(g_logQueue, ^{ [g_logLines removeAllObjects]; }); }
static BOOL VSLineIsError(NSString *line) {
    static NSArray *kw = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ kw = @[@"❌", @"⚠️", @"lỗi", @"thất bại", @"fail", @"exception", @"memory", @"timeout", @"bị đóng", @"đã bị đóng", @"popup lạ", @"chưa xác nhận", @"không tìm thấy", @"không thể"]; });
    for (NSString *k in kw) if ([line rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}
static NSArray<NSString *> *VSLogLinesLastRun(void) {
    NSArray<NSString *> *lines = VSLogSnapshotLines();
    NSUInteger start = 0;
    for (NSInteger i = (NSInteger)lines.count - 1; i >= 0; i--) { if ([lines[(NSUInteger)i] containsString:@"════ RUN"]) { start = (NSUInteger)i; break; } }
    return [lines subarrayWithRange:NSMakeRange(start, lines.count - start)];
}
static NSString *VSLogTextLastRun(void) { return [VSLogLinesLastRun() componentsJoinedByString:@"\n"]; }
static NSString *VSLogTextAll(void) { return [VSLogSnapshotLines() componentsJoinedByString:@"\n"]; }
static NSString *VSLogTextErrorsLastRun(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in VSLogLinesLastRun()) if (VSLineIsError(l) || [l containsString:@"════ RUN"] || [l containsString:@"KẾT QUẢ"]) [out addObject:l];
    return [out componentsJoinedByString:@"\n"];
}
static NSUInteger VSLogErrorCountLastRun(void) { NSUInteger n = 0; for (NSString *l in VSLogLinesLastRun()) if (VSLineIsError(l)) n++; return n; }
static double VSAvailableMemoryMB(void) { if (@available(iOS 13.0, *)) return (double)os_proc_available_memory() / 1048576.0; return -1; }
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

// ===== DEBUG SETTINGS =====
static NSString *const kVSSetSuppressMenu = @"VSTool.suppressMenu";
static NSString *const kVSSetSkipReselect = @"VSTool.skipReselect";
static NSString *const kVSSetDismissMenu  = @"VSTool.dismissMenu";
static NSString *const kVSSetGuardCancel  = @"VSTool.guardCancel";
static BOOL VSSettingBool(NSString *key, BOOL defaultValue) { id v = [NSUserDefaults.standardUserDefaults objectForKey:key]; return v ? [v boolValue] : defaultValue; }
static void VSSettingSet(NSString *key, BOOL value) { [NSUserDefaults.standardUserDefaults setBool:value forKey:key]; }

// ===== PRIVATE API =====
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
- (void)confirmAddingLayer:(SEL)s object:(id)o1 object2:(id)o2 object3:(id)o3;
- (void)confirmAddingLayer:(SEL)s object:(id)o1 object2:(id)o2 object3:(id)o3 isAbleToShowTheLayerActionMenu:(BOOL)b;
- (void)cancelClipPicker;
- (BOOL)assetHasBeenLoadedForLayer:(NSUInteger)n;
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

// ===== GLOBALS =====
static NSUInteger g_runIdentifier = 0;
static BOOL g_autoConfirmPopups = NO;
static BOOL g_suppressLayerActionMenu = NO;
static BOOL g_guardCancel = NO;
static BOOL g_createInProgress = NO;
static BOOL g_dismissLayerMenu = NO;
static BOOL g_taskActive = NO;
static BOOL g_replayInProgress = NO;
static BOOL g_addReplayInProgress = NO;
static NSString *g_chosenMediaKey = nil;
static NSUInteger g_lastApplyUnconfirmed = 0;
static CFAbsoluteTime g_clipPickerCancelHintAt = 0;
static const void *kVSMenuDismissedKey = &kVSMenuDismissedKey;
static const void *kVSPopupHandledKey = &kVSPopupHandledKey;
static NSHashTable *g_activePopupsTable = nil;
static UIWindow *g_overlayToolWindow = nil;

@interface VSCapturedAdd : NSObject
@property (nonatomic, assign) SEL makeSelector;
@property (nonatomic, strong) id object1;
@property (nonatomic, strong) id object2;
@property (nonatomic, strong) id object3;
@end
@implementation VSCapturedAdd
@end
static VSCapturedAdd *g_lastCapturedAdd = nil;

// ===== UTILS =====
static inline void VSRunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) { @autoreleasepool { block(); } }
    else { dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { block(); } }); }
}
static inline void VSDispatchAfterMS(int64_t delayMs, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ @autoreleasepool { block(); } });
}
static BOOL VSTry(void (^block)(void)) {
    @try { block(); return YES; } @catch (NSException *e) { VSLog(@"Exception: %@ — %@", e.name, e.reason); return NO; }
}
static inline BOOL VSContains(NSString *h, NSString *n) { if (!h.length || !n.length) return NO; return [h rangeOfString:n options:NSCaseInsensitiveSearch].location != NSNotFound; }
static BOOL VSHasIvar(id o, NSString *name) { if (!o || !name.length) return NO; return class_getInstanceVariable(object_getClass(o), name.UTF8String) != NULL; }
static id VSSafeValueForKey(id o, NSString *k) {
    if (!o || !k.length) return nil;
    @try {
        BOOL available = [o respondsToSelector:NSSelectorFromString(k)] || VSHasIvar(o, [@"_" stringByAppendingString:k]) || VSHasIvar(o, k);
        if (!available) return nil;
        return [o valueForKey:k];
    } @catch (...) { return nil; }
}
static BOOL VSValueIsTruthy(id v) {
    if (!v || v == [NSNull null]) return NO;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v length] > 0;
    if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]] || [v isKindOfClass:[NSDictionary class]]) return [v count] > 0;
    return YES;
}
static NSUInteger VSCountOf(id v) {
    if (!v) return 0;
    if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]] || [v isKindOfClass:[NSDictionary class]]) return [v count];
    return 0;
}
static inline CMTime VSSafeCurrentTime(id o) {
    if (!o) return kCMTimeInvalid;
    SEL s = @selector(currentTime);
    if (![o respondsToSelector:s]) return kCMTimeInvalid;
    @try { CMTime (*f)(id, SEL) = (CMTime (*)(id, SEL))[o methodForSelector:s]; return f(o, s); } @catch (...) { return kCMTimeInvalid; }
}
static inline void VSSetQRDelegateSafely(id qr, id d) {
    if (!qr) return;
    SEL s = @selector(setDelegate:);
    if (![qr respondsToSelector:s]) return;
    @try { ((void (*)(id, SEL, id))[qr methodForSelector:s])(qr, s, d); } @catch (...) {}
}
static inline BOOL VSSafeIsClass(id o, NSString *cn) {
    if (!o || !cn.length) return NO;
    Class c = NSClassFromString(cn);
    return c && [o isKindOfClass:c];
}
static BOOL VSLayerAssetLoaded(id engine, NSUInteger n) {
    SEL s = @selector(assetHasBeenLoadedForLayer:);
    if (!engine || ![engine respondsToSelector:s]) return YES;
    @try { return ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(engine, s, n); } @catch (...) { return YES; }
}
static UIBarButtonItem *VSFindCreateButtonOnEditor(id editorVC) {
    if (!editorVC) return nil;
    NSArray *createKw = @[@"tạo", @"create", @"done", @"xong", @"save", @"lưu", @"export", @"xuất"];
    NSArray *cancelKw = @[@"hủy", @"huỷ", @"cancel", @"back", @"quay lại", @"dismiss", @"close", @"đóng"];
    id cancelRef = VSSafeValueForKey(editorVC, @"cancelBarButton");
    BOOL (^isCreate)(UIBarButtonItem *) = ^BOOL(UIBarButtonItem *btn) {
        if (!btn || btn == cancelRef) return NO;
        NSString *title = btn.title ?: @"";
        NSString *actStr = btn.action ? [NSStringFromSelector(btn.action) stringByReplacingOccurrencesOfString:@"_" withString:@""] : @"";
        for (NSString *kw in cancelKw) if (VSContains(title, kw) || VSContains(actStr, kw)) return NO;
        for (NSString *kw in createKw) if (VSContains(title, kw) || VSContains(actStr, kw)) return YES;
        return NO;
    };
    id cancelBtn = VSSafeValueForKey(editorVC, @"cancelBarButton");
    id kvcBtn = VSSafeValueForKey(editorVC, @"createBarButton");
    if ([kvcBtn isKindOfClass:[UIBarButtonItem class]] && kvcBtn != cancelBtn) { VSLog(@"[CreateButton] createBarButton: '%@'", ((UIBarButtonItem *)kvcBtn).title ?: @"?"); return (UIBarButtonItem *)kvcBtn; }
    UINavigationController *nav = nil; @try { nav = [editorVC navigationController]; } @catch (...) { nav = nil; }
    if (nav) {
        UINavigationItem *ni = nav.topViewController.navigationItem;
        for (UIBarButtonItem *btn in ni.rightBarButtonItems) if (isCreate(btn)) { VSLog(@"[CreateButton] right: '%@'", btn.title ?: @"?"); return btn; }
        if (isCreate(ni.rightBarButtonItem)) { VSLog(@"[CreateButton] right1: '%@'", ni.rightBarButtonItem.title ?: @"?"); return ni.rightBarButtonItem; }
    }
    VSLog(@"[CreateButton] KHÔNG tìm thấy nút Tạo"); return nil;
}
static void VSSafePoll(NSUInteger runId, int64_t intervalMs, NSUInteger remainingTries, BOOL (^cond)(void), void (^done)(BOOL)) {
    if (runId != g_runIdentifier) { if (done) done(NO); return; }
    BOOL matched = NO; @autoreleasepool { @try { matched = cond(); } @catch (...) { matched = NO; } }
    if (matched) { if (done) done(YES); return; }
    if (remainingTries == 0) { if (done) done(NO); return; }
    VSDispatchAfterMS(intervalMs, ^{ VSSafePoll(runId, intervalMs, remainingTries - 1, cond, done); });
}
static UIViewController *VSSearchVC(UIViewController *root, Class tgt, int depth) {
    if (!root || depth > 15) return nil;
    UIViewController *r = nil;
    if (root.presentedViewController) { r = VSSearchVC(root.presentedViewController, tgt, depth + 1); if (r) return r; }
    if ([root isKindOfClass:[UINavigationController class]]) { for (UIViewController *c in ((UINavigationController *)root).viewControllers.reverseObjectEnumerator) { r = VSSearchVC(c, tgt, depth + 1); if (r) return r; } }
    if ([root isKindOfClass:[UITabBarController class]]) { r = VSSearchVC(((UITabBarController *)root).selectedViewController, tgt, depth + 1); if (r) return r; }
    for (UIViewController *c in root.childViewControllers.reverseObjectEnumerator) { r = VSSearchVC(c, tgt, depth + 1); if (r) return r; }
    if ([root isKindOfClass:tgt] && root.isViewLoaded && root.view.window) return root;
    return nil;
}
static UIViewController *VSFindTopViewControllerNamed(NSString *cn) {
    Class tgt = NSClassFromString(cn); if (!tgt) return nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (w == g_overlayToolWindow || w.hidden || w.alpha <= 0.01) continue;
        UIViewController *f = VSSearchVC(w.rootViewController, tgt, 0);
        if (f) return f;
    }
    return nil;
}

// ===== SMART POPUP =====
typedef NS_ENUM(NSInteger, VSPopupActionStatus) { VSPopupActionStatusNone = 0, VSPopupActionStatusHandled, VSPopupActionStatusBlockedPurchase };
static inline NSString *VSLocalizedString(NSString *key) { return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil]; }
static NSArray *VSCollectAllVisiblePopups(id editorVC) {
    NSMutableArray *rs = [NSMutableArray array];
    if (editorVC) for (NSString *iv in @[@"ourPopup", @"warningPopup", @"object3DPickerPopup", @"copyLayerPopup"]) { id p = VSSafeValueForKey(editorVC, iv); if (p && ![rs containsObject:p]) [rs addObject:p]; }
    if (g_activePopupsTable) for (id p in g_activePopupsTable.allObjects) { if (p && ![rs containsObject:p]) [rs addObject:p]; }
    NSMutableArray *vis = [NSMutableArray array];
    for (id p in rs) {
        if (!VSSafeIsClass(p, @"CustomPopup")) continue;
        UIView *dv = VSSafeValueForKey(p, @"dimView");
        UIView *pv = [p isKindOfClass:[UIView class]] ? (UIView *)p : nil;
        if ((dv && dv.window) || (pv && pv.window)) [vis addObject:p];
    }
    return vis;
}
static BOOL VSCheckIfPopupIsPurchasePrompt(id popup) {
    NSString *msg = [VSSafeValueForKey(popup, @"_message") description] ?: @"";
    NSString *title = [VSSafeValueForKey(popup, @"_title") description] ?: @"";
    NSString *combined = [NSString stringWithFormat:@" %@ %@ ", title, msg];
    NSArray *kws = @[@"purchase", @"subscription", @"unlock pro", @"pro pack", @"restore purchase", @"all access", @" pass ", @" buy ", @"upgrade", @"free trial", @"mua gói", @"khôi phục", @"đăng ký", @"nâng cấp", @"dùng thử", @"mở khóa", @"thanh toán"];
    for (NSString *k in kws) if (VSContains(combined, k)) return YES;
    return NO;
}
static BOOL VSTitleMatches(NSString *t, NSString *c) {
    if (!t.length || !c.length) return NO;
    NSString *trimmed = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (c.length <= 4) return [trimmed caseInsensitiveCompare:c] == NSOrderedSame;
    return VSContains(trimmed, c);
}
static NSArray<NSString *> *VSPopupButtonTitles(id popup, NSDictionary<NSString *, UIButton *> **bm) {
    NSMutableArray *ts = [NSMutableArray array];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    id strs = VSSafeValueForKey(popup, @"_buttonStrings");
    if ([strs isKindOfClass:[NSArray class]]) for (id t in (NSArray *)strs) if ([t isKindOfClass:[NSString class]] && [(NSString *)t length]) [ts addObject:t];
    id btns = VSSafeValueForKey(popup, @"_buttons");
    if ([btns isKindOfClass:[NSArray class]]) {
        for (id b in (NSArray *)btns) {
            if (![b isKindOfClass:[UIButton class]]) continue;
            NSString *t = ((UIButton *)b).currentTitle;
            if (!t.length) continue;
            map[t] = (UIButton *)b;
            if (![ts containsObject:t]) [ts addObject:t];
        }
    }
    if (bm) *bm = map;
    return ts;
}
static BOOL VSPopupIsLayerActionMenu(id popup) {
    NSArray *ts = VSPopupButtonTitles(popup, NULL);
    if (ts.count < 3) return NO;
    NSArray *known = @[@"Edit Keyframes", @"Biên tập Khung hình chính", @"Add Mask", @"Thêm Mặt nạ", @"Edit Title", @"Sửa tiêu đề", @"Replace Content", @"Thay Nội dung", @"Deactivate", @"Activate", @"Hủy kích hoạt", @"Kích hoạt", @"Delete", @"Xoá", @"Xóa"];
    NSUInteger hits = 0;
    for (NSString *t in ts) for (NSString *k in known) if (VSTitleMatches(t, k)) { hits++; break; }
    return hits >= 3;
}
static void VSDismissLayerActionMenus(id editorVC) {
    if (!g_dismissLayerMenu) return;
    for (id popup in VSCollectAllVisiblePopups(editorVC)) {
        if (!VSPopupIsLayerActionMenu(popup)) continue;
        if ([objc_getAssociatedObject(popup, kVSMenuDismissedKey) boolValue]) continue;
        objc_setAssociatedObject(popup, kVSMenuDismissedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VSTry(^{ if ([popup respondsToSelector:@selector(dismiss)]) { VSLog(@"[LayerMenu] đóng menu chọn lớp"); [popup dismiss]; } });
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
    } @catch (...) { alive = NO; }
    return alive;
}
static BOOL VSEditorIsBusy(id editorVC) {
    id sp = VSSafeValueForKey(editorVC, @"spinner");
    if ([sp isKindOfClass:[UIActivityIndicatorView class]]) { UIActivityIndicatorView *s = sp; if (s.isAnimating && s.window && !s.hidden) return YES; }
    id al = VSSafeValueForKey(editorVC, @"loadingAlert");
    if ([al isKindOfClass:[UIView class]]) { UIView *v = al; if (v.window && !v.hidden && v.alpha > 0.01) return YES; }
    return NO;
}
static NSString *VSDescribeVCChain(void) {
    NSMutableArray *parts = [NSMutableArray array];
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w == g_overlayToolWindow || w.hidden) continue;
        NSMutableArray *chain = [NSMutableArray array];
        UIViewController *vc = w.rootViewController;
        for (int i = 0; vc && i < 10; i++) {
            NSString *d = NSStringFromClass([vc class]);
            if ([vc isKindOfClass:[UINavigationController class]]) {
                NSMutableArray *ns = [NSMutableArray array];
                for (UIViewController *c in ((UINavigationController *)vc).viewControllers) [ns addObject:NSStringFromClass([c class])];
                d = [NSString stringWithFormat:@"%@[%@]", d, [ns componentsJoinedByString:@","]];
            }
            [chain addObject:d];
            vc = vc.presentedViewController;
        }
        [parts addObject:[chain componentsJoinedByString:@" ▸ "]];
    }
    return [parts componentsJoinedByString:@"  ||  "];
}
static NSString *VSPopupSummary(id editorVC) {
    NSMutableArray *items = [NSMutableArray array];
    for (id p in VSCollectAllVisiblePopups(editorVC)) { NSArray *t = VSPopupButtonTitles(p, NULL); [items addObject:[NSString stringWithFormat:@"{%@}", [t componentsJoinedByString:@"|"]]]; }
    return [items componentsJoinedByString:@" "];
}
static void VSLogState(NSString *tag, id editorVC) {
    id sel = VSSafeValueForKey(editorVC, @"lastSelectedLayerNum");
    id bor = VSSafeValueForKey(editorVC, @"borderedLayerNum");
    BOOL ms = VSValueIsTruthy(VSSafeValueForKey(editorVC, @"isMenuShowing"));
    VSLog(@"[State:%@] alive=%d busy=%d selected=%@ bordered=%@ menuShowing=%d mem=%.0fMB popups=[%@] vc=%@",
          tag, VSEditorIsAlive(editorVC), VSEditorIsBusy(editorVC), sel ?: @"?", bor ?: @"?", ms, VSAvailableMemoryMB(), VSPopupSummary(editorVC), VSDescribeVCChain());
}
static void VSApplySettingsToRun(void) {
    g_suppressLayerActionMenu = VSSettingBool(kVSSetSuppressMenu, NO);
    g_dismissLayerMenu        = VSSettingBool(kVSSetDismissMenu, YES);
    g_guardCancel             = VSSettingBool(kVSSetGuardCancel, YES);
    VSLog(@"[Settings] suppressMenu=%d skipReselect=%d dismissMenu=%d guardCancel=%d", g_suppressLayerActionMenu, VSSettingBool(kVSSetSkipReselect, NO), g_dismissLayerMenu, g_guardCancel);
}
static void VSLogRunStart(NSString *name) {
    g_runCounter++;
    VSLog(@"════ RUN #%lu: %@ ════", (unsigned long)g_runCounter, name ?: @"?");
    VSLog(@"[Env] iOS %@ | mem=%.0fMB | vc=%@", UIDevice.currentDevice.systemVersion, VSAvailableMemoryMB(), VSDescribeVCChain());
}
static BOOL VSPopupWasHandled(id popup) { return [objc_getAssociatedObject(popup, kVSPopupHandledKey) boolValue]; }
static BOOL VSTitleIsCancelLike(NSString *t) {
    for (NSString *kw in @[@"hủy", @"huỷ", @"cancel", @"không", @"no", @"back", @"quay lại", @"close", @"đóng", @"dismiss"]) {
        if (kw.length <= 3 ? [t.lowercaseString isEqualToString:kw] : VSContains(t, kw)) return YES;
    }
    return NO;
}
static VSPopupActionStatus VSResolvePopupsImmediately(id editorVC) {
    if (!g_autoConfirmPopups) return VSPopupActionStatusNone;
    NSArray *popups = VSCollectAllVisiblePopups(editorVC);
    if (popups.count == 0) return VSPopupActionStatusNone;
    NSArray *matchNames = @[@"Khớp: rút ngắn/giãn", @"Match: shorten/stretch", @"Trùng khớp", @"Match"];
    NSArray *matchFallback = @[@"Bắt đầu", @"Start", @"Kết thúc", @"End"];
    NSArray *okNames = @[@"OK", @"Đồng ý", @"Xong", @"Done"];
    BOOL anyHandled = NO;
    for (id popup in popups) {
        if (VSPopupIsLayerActionMenu(popup)) continue;
        if (VSCheckIfPopupIsPurchasePrompt(popup)) { VSLog(@"Popup mua Pro — dừng"); return VSPopupActionStatusBlockedPurchase; }
        if (VSPopupWasHandled(popup)) { anyHandled = YES; continue; }
        NSDictionary<NSString *, UIButton *> *byTitle = nil;
        NSArray *titles = VSPopupButtonTitles(popup, &byTitle);
        if (titles.count == 0) continue;
        NSString *(^firstMatch)(NSArray *) = ^NSString *(NSArray *names) {
            for (NSString *cand in names) {
                NSString *loc = VSLocalizedString(cand);
                for (NSString *t in titles) {
                    if (VSTitleIsCancelLike(t)) continue;
                    if (VSTitleMatches(t, cand) || VSTitleMatches(t, loc)) return t;
                }
            }
            return nil;
        };
        NSString *hdr = [NSString stringWithFormat:@"%@ %@", [VSSafeValueForKey(popup, @"_title") description] ?: @"", [VSSafeValueForKey(popup, @"_message") description] ?: @""];
        NSString *mT = nil; NSString *reason = nil;
        NSString *mB = firstMatch(matchNames);
        if (mB) { mT = mB; reason = @"trùng khớp"; }
        else if (VSContains(hdr, @"Original Preset Layers") || VSContains(hdr, @"Các lớp Cài đặt sẵn Gốc") || VSContains(hdr, VSLocalizedString(@"Original Preset Layers"))) { mT = firstMatch(okNames); reason = @"thông tin preset"; }
        else if (titles.count == 1) { mT = firstMatch(okNames); reason = @"thông báo 1 nút"; }
        else if (firstMatch(matchFallback) && VSContains(hdr, @"dài hơn")) { mT = firstMatch(matchFallback); reason = @"trùng khớp (dự phòng)"; }
        if (!mT) { VSLog(@"[SmartPopup] popup lạ, KHÔNG bấm: %@", [titles componentsJoinedByString:@" | "]); continue; }
        objc_setAssociatedObject(popup, kVSPopupHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIButton *mBtn = byTitle[mT];
        VSTry(^{
            VSLog(@"[SmartPopup] (%@) nhấn: '%@'", reason, mT);
            if ([popup respondsToSelector:@selector(simulateButtonPressButtonWithTitle:)]) [popup simulateButtonPressButtonWithTitle:mT];
            else if (mBtn) [mBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
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

// ===== LAYER SNAPSHOT =====
typedef NS_ENUM(NSInteger, VSLayerMediaKind) { VSLayerMediaKindUnknown = 0, VSLayerMediaKindImage, VSLayerMediaKindVideo, VSLayerMediaKindEmpty, VSLayerMediaKindOther };
static inline BOOL VSLayerKindIsReplaceable(VSLayerMediaKind k) { return k == VSLayerMediaKindImage || k == VSLayerMediaKindVideo; }
static NSString *VSKindName(VSLayerMediaKind k) {
    switch (k) { case VSLayerMediaKindImage: return @"ẢNH"; case VSLayerMediaKindVideo: return @"VIDEO"; case VSLayerMediaKindEmpty: return @"RỖNG"; case VSLayerMediaKindOther: return @"KHÁC"; default: return @"?"; }
}
@interface VSLayerSnapshot : NSObject
@property (nonatomic, assign) NSInteger layerTypeValue;
@property (nonatomic, assign) NSUInteger layerIndex;
@property (nonatomic, assign) VSLayerMediaKind mediaKind;
@property (nonatomic, strong) id mediaObject;
@property (nonatomic, assign) unsigned int textureID;
@property (nonatomic, copy) NSString *assetInfo;
@property (nonatomic, copy) NSString *signature;
@property (nonatomic, copy) NSString *mediaKey;
@end
@implementation VSLayerSnapshot
@end
static VSLayerSnapshot *VSInspectLayerDetails(id engine, NSUInteger n) {
    if (!engine || ![engine respondsToSelector:@selector(layerAtLayerNum:)]) return nil;
    @autoreleasepool {
        @try {
            id layer = [engine layerAtLayerNum:n];
            if (!layer) return nil;
            VSLayerSnapshot *snap = [VSLayerSnapshot new];
            snap.layerIndex = n; snap.mediaKind = VSLayerMediaKindOther;
            id lt = VSSafeValueForKey(layer, @"layerType");
            snap.layerTypeValue = [lt isKindOfClass:[NSNumber class]] ? [lt integerValue] : -1;
            snap.assetInfo = [VSSafeValueForKey(layer, @"origAssetInfo") description] ?: @"";
            if (VSValueIsTruthy(VSSafeValueForKey(layer, @"isNullLayer"))) { snap.signature = @"null"; return snap; }
            id gen = VSSafeValueForKey(layer, @"imageGenerator");
            if (!gen) { snap.mediaKind = VSLayerMediaKindEmpty; snap.signature = @"nogen"; return snap; }
            for (NSString *k in @[@"layerGIF", @"layerZaps", @"layerDrawing", @"layerOverlay"]) if (VSValueIsTruthy(VSSafeValueForKey(gen, k))) { snap.signature = k; return snap; }
            id asset = VSSafeValueForKey(gen, @"asset");
            BOOL hasV = [asset isKindOfClass:[AVAsset class]];
            id rawImg = VSSafeValueForKey(gen, @"layerImage");
            UIImage *img = [rawImg isKindOfClass:[UIImage class]] ? rawImg : nil;
            BOOL hasI = img && img.size.width > 1.0;
            id tex = VSSafeValueForKey(gen, @"layerImageTextureID");
            snap.textureID = [tex isKindOfClass:[NSNumber class]] ? [tex unsignedIntValue] : 0;
            if (!hasV && (VSValueIsTruthy(VSSafeValueForKey(layer, @"textDictionary")) || VSValueIsTruthy(VSSafeValueForKey(layer, @"particleLabModel")))) { snap.signature = @"text_or_particle"; return snap; }
            NSString *ak = @"";
            if ([asset isKindOfClass:[AVURLAsset class]]) ak = ((AVURLAsset *)asset).URL.absoluteString ?: @"";
            else if (hasV) ak = [NSString stringWithFormat:@"%p", asset];
            else if (hasI) ak = [NSString stringWithFormat:@"%.0fx%.0f", img.size.width, img.size.height];
            if (hasV) { snap.mediaKind = VSLayerMediaKindVideo; snap.mediaObject = asset; }
            else if (hasI) { snap.mediaKind = VSLayerMediaKindImage; snap.mediaObject = img; }
            else { snap.mediaKind = VSLayerMediaKindEmpty; }
            if ([asset isKindOfClass:[AVURLAsset class]]) snap.mediaKey = ak;
            snap.signature = [NSString stringWithFormat:@"%ld|%u|%@|%@", (long)snap.mediaKind, snap.textureID, snap.assetInfo, ak];
            return snap;
        } @catch (NSException *e) { VSLog(@"Inspect layer %lu: %@", (unsigned long)n, e); return nil; }
    }
}
static NSArray<VSLayerSnapshot *> *VSScanLayers(id engine) {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger misses = 0;
    for (NSUInteger i = 0; i < VS_MAX_LAYERS; i++) {
        VSLayerSnapshot *snap = VSInspectLayerDetails(engine, i);
        if (!snap) { if (++misses >= 6) break; continue; }
        misses = 0;
        [out addObject:snap];
    }
    NSMutableArray *desc = [NSMutableArray array];
    for (VSLayerSnapshot *s in out) [desc addObject:[NSString stringWithFormat:@"%lu:%@(type=%ld)", (unsigned long)(s.layerIndex + 1), VSKindName(s.mediaKind), (long)s.layerTypeValue]];
    VSLog(@"[Scan] %lu lớp → %@", (unsigned long)out.count, [desc componentsJoinedByString:@"  "]);
    return out;
}
static VSLayerSnapshot *VSFirstReplaceableLayer(id engine) {
    for (VSLayerSnapshot *s in VSScanLayers(engine)) if (VSLayerKindIsReplaceable(s.mediaKind)) return s;
    return nil;
}
static void VSSelectLayerOnEditor(id editorVC, NSUInteger n, NSUInteger runId, void (^done)(BOOL)) {
    BOOL (^isSel)(void) = ^BOOL{ return [editorVC lastSelectedLayerNum] == (NSInteger)n; };
    BOOL already = NO; @try { already = isSel(); } @catch (...) {}
    BOOL skip = VSSettingBool(kVSSetSkipReselect, NO);
    VSLog(@"[Select] lớp %lu (đã chọn sẵn=%d, skipReselect=%d)", (unsigned long)(n + 1), already, skip);
    if (already && skip) { VSDismissLayerActionMenus(editorVC); done(YES); return; }
    VSTry(^{ if ([editorVC respondsToSelector:@selector(selectLayer:bordered:)]) [editorVC selectLayer:n bordered:NO]; });
    VSSafePoll(runId, 50, 20, isSel, ^(BOOL s) {
        if (s) { VSDismissLayerActionMenus(editorVC); done(YES); return; }
        VSTry(^{ if ([editorVC respondsToSelector:@selector(selectLayerNum:flash:)]) [editorVC selectLayerNum:n flash:NO]; });
        VSSafePoll(runId, 50, 12, isSel, ^(BOOL s2) { VSDismissLayerActionMenus(editorVC); done(s2); });
    });
}
static void VSRefreshEditorAfterReplace(id editorVC, id engine) {
    VSTry(^{ if ([engine respondsToSelector:@selector(reloadLayerEffects)]) [engine reloadLayerEffects]; });
    VSTry(^{ if ([editorVC respondsToSelector:@selector(handleImageGenUpdate)]) [editorVC handleImageGenUpdate]; });
    VSTry(^{ if ([editorVC respondsToSelector:@selector(engineResync)]) [editorVC engineResync]; });
    VSTry(^{ if ([editorVC respondsToSelector:@selector(refreshDisplay)]) [editorVC refreshDisplay]; });
}

// ===== QR STORAGE =====
static NSString *VSGetLastQRCodeStoragePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"VideoStarTool_CachedLastQR.png"];
}
static void VSPersistQRCodeImageData(id raw) {
    if (!raw) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{ @autoreleasepool {
        UIImage *img = nil;
        if ([raw isKindOfClass:[NSData class]]) img = [UIImage imageWithData:raw];
        else if ([raw isKindOfClass:[UIImage class]]) img = raw;
        if (img) { NSData *png = UIImagePNGRepresentation(img); if (png.length) { [png writeToFile:VSGetLastQRCodeStoragePath() atomically:YES]; VSLog(@"Đã lưu QR (%lu bytes)", (unsigned long)png.length); } }
    } });
}
static UIImage *VSReadLastPersistedQRCodeImage(void) {
    NSData *d = [NSData dataWithContentsOfFile:VSGetLastQRCodeStoragePath()];
    return d.length ? [UIImage imageWithData:d] : nil;
}
static NSString *VSDecodeQRCodeMessageFromImage(UIImage *img) {
    if (!img) return nil;
    @autoreleasepool {
        CIImage *ci = img.CGImage ? [CIImage imageWithCGImage:img.CGImage] : nil;
        if (!ci) ci = [[CIImage alloc] initWithImage:img];
        if (!ci) return nil;
        CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
        for (CIFeature *f in [det featuresInImage:ci]) if ([f isKindOfClass:[CIQRCodeFeature class]] && ((CIQRCodeFeature *)f).messageString.length) return ((CIQRCodeFeature *)f).messageString;
        return nil;
    }
}

// ===== HOOKS =====
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
static IMP g_origConfirmAdd4 = NULL;
static IMP g_origConfirmAdd5 = NULL;
static IMP g_origCancelClipPicker = NULL;

static NSUInteger g_presetImportEventCounter = 0;
static void (^g_activeMediaPickedHandler)(id editorVC, id response) = nil;
static void (^g_activeAddCapturedHandler)(id editorVC) = nil;

static BOOL VSRobustSwizzleMethod(NSString *cn, SEL sel, id block, IMP *orig) {
    Class cls = NSClassFromString(cn);
    if (!cls) { VSLog(@"Không tìm thấy class: %@", cn); return NO; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { VSLog(@"Không tìm thấy method: -[%@ %@]", cn, NSStringFromSelector(sel)); return NO; }
    if (*orig != NULL) return YES;
    IMP newImp = imp_implementationWithBlock(block);
    if (class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) *orig = method_getImplementation(m);
    else *orig = method_setImplementation(m, newImp);
    return YES;
}

static void VSInstallCoreHooksOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_activePopupsTable = [NSHashTable weakObjectsHashTable];

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(pickedWithClipPickerResponse:), ^(id self, id resp) {
            if (g_origPickedWithResponse) ((void (*)(id, SEL, id))g_origPickedWithResponse)(self, @selector(pickedWithClipPickerResponse:), resp);
            void (^h)(id, id) = g_activeMediaPickedHandler;
            if (h) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { h(self, resp); } });
        }, &g_origPickedWithResponse);

        VSRobustSwizzleMethod(@"QRCodeManager", @selector(selectedCode:withImageData:), ^(id self, id code, id data) {
            VSPersistQRCodeImageData(data);
            if (g_origSelectedCodeWithImageData) ((void (*)(id, SEL, id, id))g_origSelectedCodeWithImageData)(self, @selector(selectedCode:withImageData:), code, data);
        }, &g_origSelectedCodeWithImageData);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), ^(id self, id p, id a, NSInteger f) {
            if (g_origImportNewPreset) ((void (*)(id, SEL, id, id, NSInteger))g_origImportNewPreset)(self, @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), p, a, f);
            g_presetImportEventCounter++;
        }, &g_origImportNewPreset);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(importOldPreset:), ^(id self, id p) {
            if (g_origImportOldPreset) ((void (*)(id, SEL, id))g_origImportOldPreset)(self, @selector(importOldPreset:), p);
            g_presetImportEventCounter++;
        }, &g_origImportOldPreset);

        VSRobustSwizzleMethod(@"CustomPopup", @selector(didMoveToWindow), ^(id self) {
            if (g_origCustomPopupDidMove) ((void (*)(id, SEL))g_origCustomPopupDidMove)(self, @selector(didMoveToWindow));
            if (![self isKindOfClass:[UIView class]] || !((UIView *)self).window) return;
            [g_activePopupsTable addObject:self];
            if (g_autoConfirmPopups) VSDispatchAfterMS(80, ^{ VSResolvePopupsImmediately(nil); });
        }, &g_origCustomPopupDidMove);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(showLayerActionMenu:newLayer:), ^(id self, NSUInteger n, BOOL isNew) {
            if (g_suppressLayerActionMenu) { VSLog(@"[LayerMenu] chặn showLayerActionMenu (lớp %lu)", (unsigned long)n); return; }
            if (g_origShowLayerActionMenu) ((void (*)(id, SEL, NSUInteger, BOOL))g_origShowLayerActionMenu)(self, @selector(showLayerActionMenu:newLayer:), n, isNew);
        }, &g_origShowLayerActionMenu);

        // Capture confirmAddingLayer
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:), ^(id self, SEL mk, id o1, id o2, id o3, BOOL able) {
            VSCapturedAdd *cap = nil;
            if (g_activeAddCapturedHandler && !g_addReplayInProgress) {
                cap = [VSCapturedAdd new]; cap.makeSelector = mk; cap.object1 = o1; cap.object2 = o2; cap.object3 = o3;
                g_lastCapturedAdd = cap;
                NSInteger ln = -1; @try { ln = [self lastSelectedLayerNum]; } @catch (...) {}
                VSLog(@"[Capture] confirmAddingLayer(%@) lớp=%ld able=%d", mk ? NSStringFromSelector(mk) : @"?", (long)ln + 1, able);
            }
            if (g_origConfirmAdd5) ((void (*)(id, SEL, SEL, id, id, id, BOOL))g_origConfirmAdd5)(self, @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:), mk, o1, o2, o3, able);
            void (^h)(id) = g_activeAddCapturedHandler;
            if (cap && h) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { h(self); } });
        }, &g_origConfirmAdd5);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmAddingLayer:object:object2:object3:), ^(id self, SEL mk, id o1, id o2, id o3) {
            VSCapturedAdd *cap = nil;
            if (g_activeAddCapturedHandler && !g_addReplayInProgress) {
                cap = [VSCapturedAdd new]; cap.makeSelector = mk; cap.object1 = o1; cap.object2 = o2; cap.object3 = o3;
                g_lastCapturedAdd = cap;
                VSLog(@"[Capture] confirmAddingLayer4(%@)", mk ? NSStringFromSelector(mk) : @"?");
            }
            if (g_origConfirmAdd4) ((void (*)(id, SEL, SEL, id, id, id))g_origConfirmAdd4)(self, @selector(confirmAddingLayer:object:object2:object3:), mk, o1, o2, o3);
            void (^h)(id) = g_activeAddCapturedHandler;
            if (cap && h) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { h(self); } });
        }, &g_origConfirmAdd4);

        VSRobustSwizzleMethod(@"_TtC10Video_Star19ClipPickerViewModel", @selector(cancelClipPicker), ^(id self) {
            g_clipPickerCancelHintAt = CFAbsoluteTimeGetCurrent();
            if (g_taskActive) VSLog(@"[Pick] ClipPickerViewModel cancelClipPicker");
            if (g_origCancelClipPicker) ((void (*)(id, SEL))g_origCancelClipPicker)(self, @selector(cancelClipPicker));
        }, &g_origCancelClipPicker);

        BOOL (^isUserTouch)(void) = ^BOOL{
            for (NSString *sym in [NSThread callStackSymbols]) if ([sym containsString:@"sendEvent:"]) return YES;
            return NO;
        };
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(cancel), ^(id self) {
            if (g_guardCancel && !g_createInProgress && !isUserTouch()) {
                NSArray *st = [NSThread callStackSymbols];
                VSLog(@"[Guard] CHẶN -cancel do code gọi. Nguồn:\n%@", [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                return;
            }
            if (g_origEditorCancel) ((void (*)(id, SEL))g_origEditorCancel)(self, @selector(cancel));
        }, &g_origEditorCancel);
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(cancelCreate), ^(id self) {
            if (g_guardCancel && !g_createInProgress && !isUserTouch()) { VSLog(@"[Guard] CHẶN -cancelCreate"); return; }
            if (g_origEditorCancelCreate) ((void (*)(id, SEL))g_origEditorCancelCreate)(self, @selector(cancelCreate));
        }, &g_origEditorCancelCreate);
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(close), ^(id self) {
            if (g_guardCancel && !g_createInProgress && !isUserTouch()) {
                NSArray *st = [NSThread callStackSymbols];
                VSLog(@"[Guard] CHẶN -close do code gọi. Nguồn:\n%@", [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                return;
            }
            if (g_origEditorClose) ((void (*)(id, SEL))g_origEditorClose)(self, @selector(close));
        }, &g_origEditorClose);
        VSRobustSwizzleMethod(@"MultiLayerNavController", @selector(cancel), ^(id self) {
            if (g_guardCancel && !g_createInProgress && !isUserTouch()) {
                NSArray *st = [NSThread callStackSymbols];
                VSLog(@"[Guard] CHẶN Nav -cancel. Nguồn:\n%@", [[st subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, st.count))] componentsJoinedByString:@"\n"]);
                return;
            }
            if (g_taskActive) VSLog(@"[Trace] Nav -cancel");
            if (g_origNavCancel) ((void (*)(id, SEL))g_origNavCancel)(self, @selector(cancel));
        }, &g_origNavCancel);

        void (^traceStack)(NSString *, id) = ^(NSString *what, id obj) {
            NSArray *st = [NSThread callStackSymbols];
            NSUInteger n = MIN((NSUInteger)18, st.count);
            NSUInteger from = st.count > 1 ? 1 : 0;
            VSLog(@"[Trace] %@ trên %@ | nguồn gọi:\n%@", what, NSStringFromClass([obj class]), [[st subarrayWithRange:NSMakeRange(from, n - from)] componentsJoinedByString:@"\n"]);
        };
        BOOL (^involvesEditor)(id) = ^BOOL(id vc) {
            NSString *names = [NSString stringWithFormat:@"%@ %@ %@", NSStringFromClass([vc class]), NSStringFromClass([[vc presentedViewController] class]), NSStringFromClass([[vc presentingViewController] class])];
            return [names containsString:@"MultiLayer"] || [names containsString:@"VideoReview"];
        };

        // ========== DISMISS HOOK: thêm nhánh g_addReplayInProgress ưu tiên cao nhất ==========
        VSRobustSwizzleMethod(@"UIViewController", @selector(dismissViewControllerAnimated:completion:), ^(id self, BOOL animated, id completion) {
            // NHÁNH MỚI: replay confirmAddingLayer → CHẶN TUYỆT ĐỐI
            if (g_addReplayInProgress && !g_createInProgress &&
                (VSSafeIsClass(self, @"MultiLayerWizEffectVC") || VSSafeIsClass(self, @"MultiLayerNavController")) &&
                ![(UIViewController *)self presentedViewController]) {
                VSLog(@"[Replay] CHẶN dismiss lên %@ (đang replay confirmAddingLayer)", NSStringFromClass([self class]));
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ ((void (^)(void))completion)(); });
                return;
            }
            // Nhánh replay pickedWithClipPickerResponse (fallback)
            if (g_replayInProgress && (VSSafeIsClass(self, @"MultiLayerWizEffectVC") || VSSafeIsClass(self, @"MultiLayerNavController")) &&
                ![(UIViewController *)self presentedViewController]) {
                VSLog(@"[Replay] CHẶN dismiss lên %@ (không có bảng chọn đang mở)", NSStringFromClass([self class]));
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ ((void (^)(void))completion)(); });
                return;
            }
            // Nhánh guard ngoài cùng
            if (g_guardCancel && g_taskActive && !g_createInProgress &&
                (VSSafeIsClass(self, @"MultiLayerWizEffectVC") || VSSafeIsClass(self, @"MultiLayerNavController")) &&
                ![(UIViewController *)self presentedViewController] && !isUserTouch()) {
                VSLog(@"❌ [Guard] CHẶN dismiss %@ do code gọi (ngoài replay)", NSStringFromClass([self class]));
                traceStack(@"dismiss bị chặn", self);
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ ((void (^)(void))completion)(); });
                return;
            }
            if (g_taskActive && involvesEditor(self)) traceStack(@"dismissViewControllerAnimated", self);
            if (g_origVCDismiss) ((void (*)(id, SEL, BOOL, id))g_origVCDismiss)(self, @selector(dismissViewControllerAnimated:completion:), animated, completion);
        }, &g_origVCDismiss);

        BOOL (^popWouldCloseEditor)(id, id) = ^BOOL(id nav, id target) {
            if (!VSSafeIsClass(nav, @"MultiLayerNavController")) return NO;
            UIViewController *top = [(UINavigationController *)nav topViewController];
            if (!VSSafeIsClass(top, @"MultiLayerWizEffectVC")) return NO;
            return target != top;
        };
        BOOL (^shouldBlock)(void) = ^BOOL{ return g_replayInProgress || g_addReplayInProgress || (g_guardCancel && !g_createInProgress && !isUserTouch()); };

        VSRobustSwizzleMethod(@"UINavigationController", @selector(popViewControllerAnimated:), ^id(id self, BOOL animated) {
            if (g_taskActive && involvesEditor(self)) {
                if (popWouldCloseEditor(self, nil) && shouldBlock()) { VSLog(@"❌ [Guard] CHẶN popViewControllerAnimated trên %@", NSStringFromClass([self class])); return nil; }
                traceStack(@"popViewControllerAnimated", self);
            }
            return g_origNavPop ? ((id (*)(id, SEL, BOOL))g_origNavPop)(self, @selector(popViewControllerAnimated:), animated) : nil;
        }, &g_origNavPop);

        VSRobustSwizzleMethod(@"UINavigationController", @selector(popToRootViewControllerAnimated:), ^id(id self, BOOL animated) {
            if (g_taskActive && involvesEditor(self)) {
                if (popWouldCloseEditor(self, nil) && shouldBlock()) { VSLog(@"❌ [Guard] CHẶN popToRoot trên %@", NSStringFromClass([self class])); return nil; }
                traceStack(@"popToRootViewControllerAnimated", self);
            }
            return g_origNavPopRoot ? ((id (*)(id, SEL, BOOL))g_origNavPopRoot)(self, @selector(popToRootViewControllerAnimated:), animated) : nil;
        }, &g_origNavPopRoot);

        VSRobustSwizzleMethod(@"UINavigationController", @selector(popToViewController:animated:), ^id(id self, id tgt, BOOL animated) {
            if (g_taskActive && involvesEditor(self)) {
                if (popWouldCloseEditor(self, tgt) && shouldBlock()) { VSLog(@"❌ [Guard] CHẶN popToViewController trên %@", NSStringFromClass([self class])); return nil; }
                traceStack(@"popToViewController", self);
            }
            return g_origNavPopTo ? ((id (*)(id, SEL, id, BOOL))g_origNavPopTo)(self, @selector(popToViewController:animated:), tgt, animated) : nil;
        }, &g_origNavPopTo);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(viewWillDisappear:), ^(id self, BOOL animated) {
            if (g_taskActive) {
                UIViewController *vc = self;
                BOOL closing = vc.isBeingDismissed || vc.isMovingFromParentViewController || vc.navigationController.isBeingDismissed;
                VSLog(@"[Trace] editor viewWillDisappear: closing=%d presented=%@ createInProgress=%d", closing, NSStringFromClass([vc.presentedViewController class]), g_createInProgress);
                if (closing && !g_createInProgress) traceStack(@"EDITOR ĐANG BỊ ĐÓNG (không phải do Tạo)", self);
            }
            if (g_origEditorWillDisappear) ((void (*)(id, SEL, BOOL))g_origEditorWillDisappear)(self, @selector(viewWillDisappear:), animated);
        }, &g_origEditorWillDisappear);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(didReceiveMemoryWarning), ^(id self) {
            VSLog(@"❌ MEMORY WARNING (editor) mem=%.0fMB taskActive=%d", VSAvailableMemoryMB(), g_taskActive);
            if (g_origEditorMemWarn) ((void (*)(id, SEL))g_origEditorMemWarn)(self, @selector(didReceiveMemoryWarning));
        }, &g_origEditorMemWarn);
        VSRobustSwizzleMethod(@"MultiLayerNavController", @selector(didReceiveMemoryWarning), ^(id self) {
            VSLog(@"❌ MEMORY WARNING (nav) mem=%.0fMB taskActive=%d", VSAvailableMemoryMB(), g_taskActive);
            if (g_origNavMemWarn) ((void (*)(id, SEL))g_origNavMemWarn)(self, @selector(didReceiveMemoryWarning));
        }, &g_origNavMemWarn);

        for (NSString *name in @[UIApplicationDidReceiveMemoryWarningNotification, UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification, UIApplicationDidBecomeActiveNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (!g_taskActive) return;
                BOOL isMem = [note.name isEqualToString:UIApplicationDidReceiveMemoryWarningNotification];
                VSLog(@"%@[App] %@ mem=%.0fMB", isMem ? @"❌ " : @"", note.name, VSAvailableMemoryMB());
            }];
        }

        VSLog(@"Hooks installed");
    });
}

static BOOL VSReplayClipPickerResponseOnEditor(id editorVC, id resp) {
    if (!editorVC || !resp || !g_origPickedWithResponse) return NO;
    @autoreleasepool {
        g_replayInProgress = YES;
        @try {
            VSLog(@"[Replay] gọi pickedWithClipPickerResponse (presented=%@)", NSStringFromClass([[(UIViewController *)editorVC presentedViewController] class]));
            ((void (*)(id, SEL, id))g_origPickedWithResponse)(editorVC, @selector(pickedWithClipPickerResponse:), resp);
            g_replayInProgress = NO;
            return YES;
        } @catch (NSException *e) { g_replayInProgress = NO; VSLog(@"❌ Replay exception: %@", e); return NO; }
    }
}

static BOOL VSReplayCapturedAddOnEditor(id editorVC, VSCapturedAdd *cap) {
    if (!editorVC || ![cap isKindOfClass:[VSCapturedAdd class]] || !cap.makeSelector) return NO;
    SEL sel5 = @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:);
    if (!g_origConfirmAdd5 && ![editorVC respondsToSelector:sel5]) return NO;
    @autoreleasepool {
        g_addReplayInProgress = YES;
        @try {
            VSLog(@"[Replay] confirmAddingLayer(%@) NO-menu", NSStringFromSelector(cap.makeSelector));
            if (g_origConfirmAdd5) ((void (*)(id, SEL, SEL, id, id, id, BOOL))g_origConfirmAdd5)(editorVC, sel5, cap.makeSelector, cap.object1, cap.object2, cap.object3, NO);
            else ((void (*)(id, SEL, SEL, id, id, id, BOOL))objc_msgSend)(editorVC, sel5, cap.makeSelector, cap.object1, cap.object2, cap.object3, NO);
            g_addReplayInProgress = NO;
            return YES;
        } @catch (NSException *e) { g_addReplayInProgress = NO; VSLog(@"❌ Replay confirmAddingLayer exception: %@", e); return NO; }
    }
}

// ===== UI CLASSES =====
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
    btn.frame = frame; btn.layer.cornerRadius = 8.0; btn.layer.borderWidth = 1.2; btn.layer.borderColor = VSToolCyanColor().CGColor;
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
    iv.contentMode = UIViewContentModeScaleAspectFit; iv.layer.cornerRadius = 14; iv.clipsToBounds = YES;
    iv.frame = CGRectInset(self.view.bounds, 24, 110);
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:iv];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 56, self.view.bounds.size.width, 32)];
    t.text = @"Code gần nhất đã nhập"; t.textColor = UIColor.whiteColor; t.textAlignment = NSTextAlignmentCenter; t.font = [UIFont boldSystemFontOfSize:18];
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:t];
    CGFloat w = (self.view.bounds.size.width - 48) / 2.0;
    NSArray *titles = @[@"Đóng", @"Chia sẻ / Lưu"];
    for (NSUInteger i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(24 + i * (w + 12), self.view.bounds.size.height - 84, w - 6, 44);
        b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:16]; b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }
}
- (void)tapped:(UIButton *)b {
    if (b.tag == 0) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    if (!self.qrImage) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[self.qrImage] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = b;
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
- (void)importedData:(id)data code:(id)code { void (^b)(id, id) = self.onCodeCapturedBlock; if (b) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { b(data, code); } }); }
- (id)dataToShare { return nil; }
- (void)setActivityiPadPopup:(id)p {}
- (id)qrImage { return nil; }
- (id)qrIcon { return nil; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { NSMethodSignature *s = [super methodSignatureForSelector:sel]; return s ?: [NSMethodSignature signatureWithObjCTypes:"@@:"]; }
- (void)forwardInvocation:(NSInvocation *)inv { void *z = NULL; if (inv.methodSignature.methodReturnLength >= sizeof(void *)) [inv setReturnValue:&z]; }
@end

@interface VSToolLogViewController : UIViewController
@end
@implementation VSToolLogViewController {
    UITextView *_textView; UISegmentedControl *_segment; UIButton *_closeButton, *_copyButton, *_shareButton;
}
- (UIButton *)makeButton:(NSString *)title action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal]; b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b setTitleColor:VSToolCyanColor() forState:UIControlStateNormal];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b]; return b;
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
    _textView = [[UITextView alloc] init]; _textView.editable = NO; _textView.backgroundColor = UIColor.clearColor;
    _textView.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    _textView.font = [UIFont fontWithName:@"Menlo" size:10.5] ?: [UIFont systemFontOfSize:10.5];
    [self.view addSubview:_textView]; [self reload];
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
    NSString *t = nil;
    switch (_segment.selectedSegmentIndex) {
        case 1: t = VSLogTextErrorsLastRun(); break;
        case 2: t = VSLogTextAll(); break;
        default: t = VSLogTextLastRun(); break;
    }
    if (!t.length) t = @"(log trống — chạy một chức năng rồi mở lại)";
    _textView.text = t;
    if (_segment.selectedSegmentIndex == 1) [_textView setContentOffset:CGPointZero animated:NO];
    else [_textView scrollRangeToVisible:NSMakeRange(t.length > 0 ? t.length - 1 : 0, 1)];
}
- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)copyTapped { UIPasteboard.generalPasteboard.string = _textView.text ?: @""; [_copyButton setTitle:@"Đã chép ✓" forState:UIControlStateNormal]; VSDispatchAfterMS(1200, ^{ [self->_copyButton setTitle:@"Sao chép" forState:UIControlStateNormal]; }); }
- (void)shareTapped {
    NSString *path = VSLogWriteFile();
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = _shareButton;
    [self presentViewController:avc animated:YES completion:nil];
}
@end

// ===== VSTOOL INTERFACE =====
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
@property (nonatomic, copy) NSString *currentTaskName;
@property (nonatomic, strong) id savedOriginalQRDelegate;
@property (nonatomic, assign) BOOL savedOriginalQRDelegateValid;
@property (nonatomic, copy) void (^bottomBarConfirmBlock)(void);
@property (nonatomic, copy) void (^bottomBarCancelBlock)(void);
+ (instancetype)shared;
- (void)setupToolInterfaceIfNeeded;
- (void)adjustFloatingButtonBounds;
- (void)restoreOriginalQRCodeDelegate;
- (void)terminateCurrentTaskQuietly;
- (void)handleFabPan:(UIPanGestureRecognizer *)g;
- (void)fabClicked;
- (UIViewController *)topPresenterVC;
- (void)updateStatusHUD:(NSString *)m;
- (void)showNotificationAlert:(NSString *)m title:(NSString *)t;
- (void)dismissBottomActionBar;
- (UIView *)buildCardContainerWithFrame:(CGRect)f title:(NSString *)t subtitle:(NSString *)s;
- (void)displayBottomActionBarWithTitle:(NSString *)t message:(NSString *)m confirmTitle:(NSString *)c onConfirm:(void (^)(void))onC onCancel:(void (^)(void))onX;
- (void)handleBottomBarConfirm;
- (void)handleBottomBarCancel;
- (NSUInteger)startNewTaskWithDescription:(NSString *)n initialStatus:(NSString *)s;
- (void)finalizeTaskWithMessage:(NSString *)m;
- (void)showRunResultAlert:(NSString *)m title:(NSString *)t;
- (void)presentLogViewer;
- (void)showDebugSettings;
- (void)requestUserMediaSelectionOnEditor:(id)e runId:(NSUInteger)r completion:(void (^)(id, VSLayerSnapshot *))d;
- (void)applyMediaResponse:(id)resp toEditor:(id)e skipLayer:(NSInteger)s runId:(NSUInteger)r completion:(void (^)(NSUInteger, NSUInteger, NSUInteger, BOOL))d;
- (void)executeFeature1ReplaceLayers;
- (void)executeFeature2DisplayLastCode;
- (void)executeFeature3AutoSplitBeat;
- (void)validateAndRunBeatSplitting:(id)rv splitView:(id)sv runId:(NSUInteger)r;
- (void)executeFeature4BatchMultiScene;
- (void)parseMergeRangeAndPresentCodePanel:(id)rv runId:(NSUInteger)r originalLastViewed:(NSUInteger)o;
- (NSUInteger)countOfReceivedCodes;
- (void)renderMultiSceneCodeCollectionPanel;
- (void)handleMultiSceneCancel;
- (void)restoreMultiSceneCodePanel;
- (void)handleCodeRowButtonTapped:(UIButton *)b;
- (void)handleMultiSceneProceedWithMedia;
- (void)showProcessingProgressPanel;
- (void)executeBatchProcessingScenesWithResponse:(id)resp runId:(NSUInteger)r;
- (void)openMultiLayerEditorForScene:(NSUInteger)sc reviewVC:(id)rv runId:(NSUInteger)r completion:(void (^)(id))d;
- (void)importPresetPayload:(id)p codeIdentifier:(id)c intoEditor:(id)e runId:(NSUInteger)r completion:(void (^)(NSString *))d;
- (void)waitForEditorSettledThenCreate:(id)e runId:(NSUInteger)r completion:(void (^)(NSString *))d;
- (void)triggerCreateInEditor:(id)e runId:(NSUInteger)r completion:(void (^)(NSString *))d;
@end

@implementation VSToolRootVC
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [VSTool.shared adjustFloatingButtonBounds]; }
@end

@implementation VSTool

+ (instancetype)shared { static VSTool *t; static dispatch_once_t o; dispatch_once(&o, ^{ t = [VSTool new]; }); return t; }

- (void)setupToolInterfaceIfNeeded {
    if (self.window) return;
    static BOOL delayPassed = NO;
    if (!delayPassed) { delayPassed = YES; VSDispatchAfterMS(2500, ^{ [self setupToolInterfaceIfNeeded]; }); return; }
    CGRect b = UIScreen.mainScreen.bounds;
    VSToolPassThroughWindow *w = nil;
    if (@available(iOS 13.0, *)) { for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:[UIWindowScene class]]) { w = [[VSToolPassThroughWindow alloc] initWithWindowScene:(UIWindowScene *)s]; break; } }
    if (!w) w = [[VSToolPassThroughWindow alloc] initWithFrame:b];
    w.frame = b; w.windowLevel = UIWindowLevelAlert + 100; w.backgroundColor = UIColor.clearColor;
    VSToolRootVC *root = [VSToolRootVC new]; root.view.backgroundColor = UIColor.clearColor; w.rootViewController = root;
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(b.size.width - 64, b.size.height * 0.35, 48, 48);
    fab.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.13 alpha:0.85];
    fab.layer.cornerRadius = 24.0; fab.layer.borderWidth = 1.5; fab.layer.borderColor = VSToolCyanColor().CGColor;
    [fab setTitle:@"VS" forState:UIControlStateNormal]; fab.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [fab setTitleColor:VSToolCyanColor() forState:UIControlStateNormal];
    [fab addTarget:self action:@selector(fabClicked) forControlEvents:UIControlEventTouchUpInside];
    [fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleFabPan:)]];
    [root.view addSubview:fab];
    UILabel *hud = [[UILabel alloc] init];
    hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82]; hud.textColor = UIColor.whiteColor;
    hud.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]; hud.textAlignment = NSTextAlignmentCenter; hud.numberOfLines = 2;
    hud.layer.cornerRadius = 10; hud.clipsToBounds = YES; hud.hidden = YES;
    [root.view addSubview:hud];
    self.window = w; self.floatingButton = fab; self.statusHUDLabel = hud;
    self.multiSceneActiveCapturingIndex = -1;
    g_overlayToolWindow = w; w.hidden = NO;
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
- (UIViewController *)topPresenterVC { UIViewController *vc = self.window.rootViewController; while (vc.presentedViewController) vc = vc.presentedViewController; return vc; }
- (void)updateStatusHUD:(NSString *)m {
    if (m.length) VSLog(@"[HUD] %@", m);
    UIView *c = self.window.rootViewController.view;
    self.statusHUDLabel.text = m;
    CGFloat w = MIN(c.bounds.size.width - 32, 440);
    self.statusHUDLabel.frame = CGRectMake((c.bounds.size.width - w) / 2.0, c.safeAreaInsets.top + 8, w, 40);
    self.statusHUDLabel.hidden = (m.length == 0);
}
- (void)showNotificationAlert:(NSString *)m title:(NSString *)t {
    [self updateStatusHUD:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t ?: @"VideoStarTool" message:m preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self topPresenterVC] presentViewController:a animated:YES completion:nil];
}
- (void)dismissBottomActionBar { [self.bottomActionBar removeFromSuperview]; self.bottomActionBar = nil; }
- (UIView *)buildCardContainerWithFrame:(CGRect)f title:(NSString *)t subtitle:(NSString *)s {
    UIView *card = [[UIView alloc] initWithFrame:f];
    card.backgroundColor = VSToolCardBackgroundColor(); card.layer.cornerRadius = 14; card.layer.borderWidth = 1.2; card.layer.borderColor = VSToolCyanColor().CGColor;
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, f.size.width - 32, 24)];
    h.text = t; h.textColor = VSToolCyanColor(); h.font = [UIFont boldSystemFontOfSize:17]; h.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *sb = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, f.size.width - 32, 36)];
    sb.text = s; sb.numberOfLines = 0; sb.textColor = [UIColor colorWithWhite:0.86 alpha:1.0]; sb.font = [UIFont systemFontOfSize:13]; sb.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:h]; [card addSubview:sb]; return card;
}
- (void)displayBottomActionBarWithTitle:(NSString *)t message:(NSString *)m confirmTitle:(NSString *)c onConfirm:(void (^)(void))onC onCancel:(void (^)(void))onX {
    [self dismissBottomActionBar];
    UIView *cc = self.window.rootViewController.view;
    CGFloat w = MIN(cc.bounds.size.width - 24, 460), h = 132;
    UIView *bar = [self buildCardContainerWithFrame:CGRectMake((cc.bounds.size.width - w) / 2.0, cc.bounds.size.height - cc.safeAreaInsets.bottom - h - 70, w, h) title:t subtitle:m];
    self.bottomBarConfirmBlock = onC; self.bottomBarCancelBlock = onX;
    CGFloat bw = (w - 32 - 12) / 2.0;
    UIButton *cb = VSToolCreateOutlineButton(@"Hủy", CGRectMake(16, h - 52, bw, 38));
    cb.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1.0].CGColor;
    [cb setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    UIButton *ok = VSToolCreateOutlineButton(c, CGRectMake(16 + bw + 12, h - 52, bw, 38));
    [cb addTarget:self action:@selector(handleBottomBarCancel) forControlEvents:UIControlEventTouchUpInside];
    [ok addTarget:self action:@selector(handleBottomBarConfirm) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:cb]; [bar addSubview:ok]; [cc addSubview:bar]; self.bottomActionBar = bar;
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
        [[self topPresenterVC] presentViewController:a animated:YES completion:nil]; return;
    }
    UIAlertController *sh = [UIAlertController alertControllerWithTitle:@"VideoStarTool" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sh addAction:[UIAlertAction actionWithTitle:@"1. Auto nhập ảnh vào các lớp" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self executeFeature1ReplaceLayers]; }]];
    [sh addAction:[UIAlertAction actionWithTitle:@"2. Hiển thị code gần nhất" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self executeFeature2DisplayLastCode]; }]];
    [sh addAction:[UIAlertAction actionWithTitle:@"3. Auto chia beat" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self executeFeature3AutoSplitBeat]; }]];
    [sh addAction:[UIAlertAction actionWithTitle:@"4. Auto nhập code + ảnh vào phân cảnh" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self executeFeature4BatchMultiScene]; }]];
    [sh addAction:[UIAlertAction actionWithTitle:@"5. Xem log lần chạy cuối" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self presentLogViewer]; }]];
    [sh addAction:[UIAlertAction actionWithTitle:@"6. Cài đặt gỡ lỗi" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self showDebugSettings]; }]];
    [sh addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    sh.popoverPresentationController.sourceView = self.floatingButton; sh.popoverPresentationController.sourceRect = self.floatingButton.bounds;
    [[self topPresenterVC] presentViewController:sh animated:YES completion:nil];
}

- (NSUInteger)startNewTaskWithDescription:(NSString *)n initialStatus:(NSString *)s {
    if (g_taskActive) VSLog(@"⚠️ Task cũ '%@' chưa kết thúc", self.currentTaskName ?: @"?");
    g_runIdentifier++;
    g_autoConfirmPopups = NO; g_suppressLayerActionMenu = NO; g_dismissLayerMenu = NO; g_guardCancel = NO;
    g_createInProgress = NO; g_replayInProgress = NO; g_addReplayInProgress = NO;
    g_chosenMediaKey = nil; g_lastCapturedAdd = nil; g_lastApplyUnconfirmed = 0; g_clipPickerCancelHintAt = 0;
    g_taskActive = YES;
    VSLogRunStart(n); VSApplySettingsToRun();
    self.currentTaskName = n; self.floatingButton.alpha = 0.55;
    [self updateStatusHUD:s];
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
    g_autoConfirmPopups = NO; g_suppressLayerActionMenu = NO; g_dismissLayerMenu = NO; g_guardCancel = NO;
    g_createInProgress = NO; g_replayInProgress = NO; g_addReplayInProgress = NO; g_taskActive = NO;
    g_activeMediaPickedHandler = nil; g_activeAddCapturedHandler = nil;
    g_lastCapturedAdd = nil; g_chosenMediaKey = nil;
    [self restoreOriginalQRCodeDelegate];
    [self dismissBottomActionBar];
    [self.multiSceneCardView removeFromSuperview]; self.multiSceneCardView = nil;
    self.multiSceneActiveCapturingIndex = -1; self.qrCaptureProxy = nil;
    self.currentTaskName = nil; self.floatingButton.alpha = 1.0;
    [self updateStatusHUD:nil];
}
- (void)finalizeTaskWithMessage:(NSString *)m {
    VSLog(@"KẾT QUẢ: %@", m.length ? m : @"(không có)");
    VSLog(@"[Finish] vc=%@ mem=%.0fMB", VSDescribeVCChain(), VSAvailableMemoryMB());
    [self terminateCurrentTaskQuietly];
    if (m.length) [self showRunResultAlert:m title:@"VideoStarTool"];
}
- (void)showRunResultAlert:(NSString *)m title:(NSString *)t {
    [self updateStatusHUD:nil];
    VSLogWriteFile();
    NSUInteger errs = VSLogErrorCountLastRun();
    NSString *full = errs ? [m stringByAppendingFormat:@"\n\n⚠️ %lu dòng cảnh báo/lỗi trong log", (unsigned long)errs] : m;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t ?: @"VideoStarTool" message:full preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Xem log" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self presentLogViewer]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [[self topPresenterVC] presentViewController:a animated:YES completion:nil];
}
- (void)presentLogViewer { VSToolLogViewController *vc = [VSToolLogViewController new]; vc.modalPresentationStyle = UIModalPresentationFullScreen; [[self topPresenterVC] presentViewController:vc animated:YES completion:nil]; }
- (void)showDebugSettings {
    NSArray *items = @[@[kVSSetSuppressMenu, @"Chặn hẳn menu chọn lớp", @NO], @[kVSSetSkipReselect, @"Bỏ qua chọn lại lớp đang chọn", @NO], @[kVSSetDismissMenu, @"Tự đóng menu chọn lớp", @YES], @[kVSSetGuardCancel, @"Chặn Hủy/Đóng do code", @YES]];
    UIAlertController *sh = [UIAlertController alertControllerWithTitle:@"Cài đặt gỡ lỗi" message:@"Bấm để bật/tắt" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *it in items) {
        BOOL on = VSSettingBool(it[0], [it[2] boolValue]);
        NSString *title = [NSString stringWithFormat:@"%@: %@", it[1], on ? @"BẬT" : @"TẮT"];
        [sh addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { VSSettingSet(it[0], !on); [self showDebugSettings]; }]];
    }
    [sh addAction:[UIAlertAction actionWithTitle:@"Xoá toàn bộ log" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { VSLogClear(); }]];
    [sh addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    sh.popoverPresentationController.sourceView = self.floatingButton; sh.popoverPresentationController.sourceRect = self.floatingButton.bounds;
    [[self topPresenterVC] presentViewController:sh animated:YES completion:nil];
}

// ===== FEATURE 1 =====
- (void)requestUserMediaSelectionOnEditor:(id)e runId:(NSUInteger)r completion:(void (^)(id, VSLayerSnapshot *))d {
    if (!g_origPickedWithResponse && !g_origConfirmAdd5 && !g_origConfirmAdd4) { VSLog(@"❌ Chưa hook được"); d(nil, nil); return; }
    g_chosenMediaKey = nil; g_lastCapturedAdd = nil; g_clipPickerCancelHintAt = 0;
    __block BOOL fin = NO;
    __block id legacy = nil; __block CFAbsoluteTime legacyAt = 0;
    __block NSInteger pLayer = -1; __block NSString *beforeSig = nil;
    void (^cleanup)(void) = ^{ g_activeMediaPickedHandler = nil; g_activeAddCapturedHandler = nil; };
    void (^complete)(id) = ^(id res) {
        if (fin) return; fin = YES; cleanup();
        NSInteger sel = -1; @try { sel = [e lastSelectedLayerNum]; } @catch (...) {}
        NSInteger tgt = sel >= 0 ? sel : pLayer;
        __block VSLayerSnapshot *snap = nil;
        VSLog(@"[Pick] hoàn tất chọn (%@) lớp=%ld", [res isKindOfClass:[VSCapturedAdd class]] ? @"bắt confirmAddingLayer" : @"response cũ", (long)tgt + 1);
        VSLogState(@"ngay sau khi chọn", e);
        VSSafePoll(r, 120, 150, ^BOOL{
            id eng = nil; @try { eng = [e getMultiLayerEngine]; } @catch (...) {}
            if (!eng || tgt < 0) return NO;
            snap = VSInspectLayerDetails(eng, (NSUInteger)tgt);
            if (!snap || !VSLayerKindIsReplaceable(snap.mediaKind)) return NO;
            if (beforeSig.length && [snap.signature ?: @"" isEqualToString:beforeSig]) return NO;
            if (snap.mediaKind == VSLayerMediaKindVideo && !VSLayerAssetLoaded(eng, (NSUInteger)tgt)) return NO;
            return !VSEditorIsBusy(e);
        }, ^(BOOL ok) {
            if (r != g_runIdentifier) return;
            if (!ok) VSLog(@"⚠️ [Pick] lớp %ld chưa đổi sau ~18s", (long)tgt + 1);
            if (snap && snap.mediaKind == VSLayerMediaKindVideo && snap.mediaKey.length) g_chosenMediaKey = snap.mediaKey;
            VSLog(@"[Pick] lớp đầu: %@ key=%@", snap ? VSKindName(snap.mediaKind) : @"nil", g_chosenMediaKey ?: @"-");
            VSLogState(@"lớp đầu đã nhận media", e);
            d(res, snap);
        });
    };
    g_activeMediaPickedHandler = ^(id me, id resp) {
        if (r != g_runIdentifier || me != e || fin) return;
        legacy = resp; legacyAt = CFAbsoluteTimeGetCurrent();
        VSLog(@"[Pick] pickedWithClipPickerResponse type=%@ clipIndex=%@", VSSafeValueForKey(resp, @"clipPickerResponseType") ?: @"?", VSSafeValueForKey(resp, @"clipIndex") ?: @"?");
    };
    g_activeAddCapturedHandler = ^(id me) {
        if (r != g_runIdentifier || me != e || fin) return;
        VSCapturedAdd *cap = g_lastCapturedAdd;
        if (cap) complete(cap);
    };
    VSSafePoll(r, 100, 60, ^BOOL{ return [e isViewLoaded] && [[e view] window] && [e getMultiLayerEngine]; }, ^(BOOL ready) {
        if (r != g_runIdentifier) return;
        if (!ready) { fin = YES; cleanup(); VSLog(@"❌ Editor chưa sẵn sàng"); d(nil, nil); return; }
        VSLayerSnapshot *first = nil; @try { first = VSFirstReplaceableLayer([e getMultiLayerEngine]); } @catch (...) {}
        if (!first) { fin = YES; cleanup(); VSLog(@"❌ Không có lớp"); d(nil, nil); return; }
        pLayer = (NSInteger)first.layerIndex; beforeSig = first.signature ?: @"";
        void (^watch)(void) = ^{
            __block BOOL seen = NO; __block CFAbsoluteTime idle = 0;
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            VSSafePoll(r, 250, 1440, ^BOOL{
                if (fin) return YES;
                UIViewController *vc = e;
                BOOL act = vc.presentedViewController != nil || vc.navigationController.presentedViewController != nil || VSHasAnyActivePopup(e);
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (act) { seen = YES; idle = 0; }
                BOOL haveM = (legacy != nil) || (g_lastCapturedAdd != nil);
                if (legacy && !g_lastCapturedAdd && !act && (now - legacyAt) > 8.0) return YES;
                if (haveM) return NO;
                if (!act && g_clipPickerCancelHintAt > 0 && (now - g_clipPickerCancelHintAt) > 2.5) return YES;
                if (act) return NO;
                if (!seen) return (now - start) > 20.0;
                if (idle == 0) idle = now;
                return (now - idle) > 12.0;
            }, ^(BOOL ended) {
                if (r != g_runIdentifier || fin) return;
                if (legacy && !g_lastCapturedAdd) { VSLog(@"⚠️ [Pick] fallback pickedWithClipPickerResponse"); complete(legacy); return; }
                fin = YES; cleanup();
                VSLog(@"[Pick] %@", ended ? @"huỷ" : @"timeout");
                d(nil, nil);
            });
        };
        void (^openPicker)(void) = ^{ VSDispatchAfterMS(150, ^{ if (r != g_runIdentifier) return; if (!VSTry(^{ [e pickNewContent]; })) { fin = YES; cleanup(); d(nil, nil); return; } watch(); }); };
        VSSelectLayerOnEditor(e, first.layerIndex, r, ^(BOOL sel) {
            if (r != g_runIdentifier) return;
            if (!sel) { fin = YES; cleanup(); VSLog(@"❌ Không chọn được lớp đầu"); d(nil, nil); return; }
            openPicker();
        });
    });
}

- (void)applyMediaResponse:(id)resp toEditor:(id)e skipLayer:(NSInteger)skip runId:(NSUInteger)r completion:(void (^)(NSUInteger, NSUInteger, NSUInteger, BOOL))d {
    g_lastApplyUnconfirmed = 0;
    BOOL useCap = [resp isKindOfClass:[VSCapturedAdd class]];
    VSLog(@"[Apply] phương thức replay: %@", useCap ? @"confirmAddingLayer (bắt được)" : @"pickedWithClipPickerResponse (cũ)");
    __block NSUInteger idleC = 0;
    VSSafePoll(r, 100, 100, ^BOOL{ VSDismissLayerActionMenus(e); idleC = VSEditorIsBusy(e) ? 0 : idleC + 1; return idleC >= 2; }, ^(BOOL idle) {
        if (r != g_runIdentifier) return;
        id eng = nil; @try { eng = [e getMultiLayerEngine]; } @catch (...) {}
        if (!eng) { d(0, 0, 0, NO); return; }
        NSMutableArray *tgt = [NSMutableArray array];
        for (VSLayerSnapshot *s in VSScanLayers(eng)) { if (!VSLayerKindIsReplaceable(s.mediaKind)) continue; if ((NSInteger)s.layerIndex == skip) continue; [tgt addObject:@(s.layerIndex)]; }
        NSUInteger total = tgt.count;
        VSLog(@"[Apply] bắt đầu: %lu lớp (skip=%ld)", (unsigned long)total, (long)skip);
        VSLogState(@"trước khi thay", e);
        if (total == 0) { d(0, 0, 0, NO); return; }
        __block NSUInteger idx = 0, chg = 0, fail = 0;
        __block NSUInteger retried = NSNotFound;
        __block BOOL blocked = NO;
        __block void (^iterate)(void) = nil;
        BOOL (^cancelled)(void) = ^BOOL{ if (r != g_runIdentifier) { iterate = nil; return YES; } return NO; };
        void (^finish)(void) = ^{
            iterate = nil; VSDismissLayerActionMenus(e);
            if (chg > 0) VSRefreshEditorAfterReplace(e, eng);
            NSUInteger notR = (idx < total) ? (total - idx) : 0;
            BOOL alive = VSEditorIsAlive(e);
            VSLog(@"[Apply] kết thúc: confirmed=%lu total=%lu failed=%lu chưaTới=%lu unconfirmed=%lu blocked=%d editorAlive=%d",
                  (unsigned long)chg, (unsigned long)total, (unsigned long)fail, (unsigned long)notR, (unsigned long)g_lastApplyUnconfirmed, blocked, !(!alive));
            VSLogState(@"sau khi thay", e);
            d(chg, total, fail + notR, blocked);
        };
        void (^next)(void) = ^{ VSDispatchAfterMS(30, ^{ if (iterate) iterate(); }); };
        iterate = ^{
            if (cancelled()) return;
            if (idx >= total) { finish(); return; }
            if (!VSEditorIsAlive(e)) { VSLog(@"❌ Editor đã đóng giữa chừng"); finish(); return; }
            VSDismissLayerActionMenus(e);
            NSUInteger wT = g_autoConfirmPopups ? 150 : 1200;
            VSSafePoll(r, 100, wT, ^BOOL{
                if (VSResolvePopupsImmediately(e) == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
                return !VSHasAnyActivePopup(e);
            }, ^(BOOL clear) {
                if (cancelled()) return;
                if (blocked || !clear) { finish(); return; }
                NSUInteger n = [tgt[idx++] unsignedIntegerValue];
                [self updateStatusHUD:[NSString stringWithFormat:@"Đang thay: lớp %lu (%lu/%lu)", (unsigned long)(n + 1), (unsigned long)idx, (unsigned long)total]];
                VSSelectLayerOnEditor(e, n, r, ^(BOOL sel) {
                    if (cancelled()) return;
                    if (!sel) { VSLog(@"❌ layer %lu: chọn lớp thất bại", (unsigned long)n); fail++; next(); return; }
                    VSDispatchAfterMS(40, ^{
                        if (cancelled()) return;
                        VSLayerSnapshot *before = VSInspectLayerDetails(eng, n);
                        if (!before || !VSLayerKindIsReplaceable(before.mediaKind)) { VSLog(@"layer %lu: bỏ qua", (unsigned long)n); next(); return; }
                        if (g_chosenMediaKey.length && before.mediaKind == VSLayerMediaKindVideo && before.mediaKey.length && [before.mediaKey isEqualToString:g_chosenMediaKey]) {
                            VSLog(@"layer %lu: ✅ đã đúng media → bỏ qua", (unsigned long)n); chg++; next(); return;
                        }
                        BOOL wasV = (before.mediaKind == VSLayerMediaKindVideo);
                        NSString *bSig = before.signature ?: @"";
                        VSLogState([NSString stringWithFormat:@"lớp %lu trước replay", (unsigned long)(n + 1)], e);
                        BOOL fired = useCap ? VSReplayCapturedAddOnEditor(e, resp) : VSReplayClipPickerResponseOnEditor(e, resp);
                        if (!fired) { VSLog(@"❌ layer %lu: replay fail", (unsigned long)n); fail++; next(); return; }
                        CFAbsoluteTime rStart = CFAbsoluteTimeGetCurrent();
                        __block BOOL conf = NO, blk = NO, changed = NO;
                        __block CFAbsoluteTime dl = CFAbsoluteTimeGetCurrent() + 8.0;
                        __block CFAbsoluteTime idleDl = 0;
                        NSUInteger cT = g_autoConfirmPopups ? 500 : 2000;
                        VSSafePoll(r, 80, cT, ^BOOL{
                            VSDismissLayerActionMenus(e);
                            if (!VSEditorIsAlive(e)) return YES;
                            if (VSResolvePopupsImmediately(e) == VSPopupActionStatusBlockedPurchase) { blk = YES; return YES; }
                            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                            if (VSHasAnyActivePopup(e)) { dl = MAX(dl, now + 2.5); if (changed) idleDl = MAX(idleDl, now + 4.0); return NO; }
                            if (!changed) {
                                VSLayerSnapshot *cur = VSInspectLayerDetails(eng, n);
                                if (cur && ![cur.signature ?: @"" isEqualToString:bSig]) { changed = YES; conf = YES; idleDl = now + 6.0; }
                                else { return now > dl; }
                            }
                            BOOL load = VSEditorIsBusy(e) || (wasV && !VSLayerAssetLoaded(eng, n));
                            if (load && now < idleDl) return NO;
                            return YES;
                        }, ^(BOOL rr) {
                            if (cancelled()) return;
                            if (blk) { blocked = YES; finish(); return; }
                            if (!VSEditorIsAlive(e)) { VSLog(@"❌ Editor đóng lúc thay lớp %lu", (unsigned long)n); fail++; finish(); return; }
                            if (!conf && retried != n) { retried = n; idx--; VSLog(@"⚠️ layer %lu: chưa xác nhận → thử lại", (unsigned long)n); next(); return; }
                            if (conf) chg++; else g_lastApplyUnconfirmed++;
                            VSLog(@"layer %lu: %@ (%.1fs)", (unsigned long)n, conf ? @"✅" : @"⚠️ chưa xác nhận", CFAbsoluteTimeGetCurrent() - rStart);
                            VSLogState([NSString stringWithFormat:@"lớp %lu sau replay", (unsigned long)(n + 1)], e);
                            next();
                        });
                    });
                });
            });
        };
        VSDispatchAfterMS(200, ^{ if (iterate) iterate(); });
    });
}

- (void)executeFeature1ReplaceLayers {
    id ed = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
    if (!ed) { [self showNotificationAlert:@"Vào màn hình Nhiều lớp trước." title:@"Chưa ở Nhiều lớp"]; return; }
    id eng = nil; @try { eng = [ed getMultiLayerEngine]; } @catch (...) {}
    if (!VSFirstReplaceableLayer(eng)) { [self showNotificationAlert:@"Không có lớp video/ảnh để thay." title:@"Không có lớp"]; return; }
    NSUInteger r = [self startNewTaskWithDescription:@"Auto nhập ảnh" initialStatus:@"Chọn 1 ảnh/video…"];
    [self requestUserMediaSelectionOnEditor:ed runId:r completion:^(id cr, VSLayerSnapshot *first) {
        if (r != g_runIdentifier) return;
        if (!cr) { [self finalizeTaskWithMessage:@"Chưa chọn media (huỷ hoặc quá thời gian)"]; return; }
        if (!first || !VSLayerKindIsReplaceable(first.mediaKind)) { [self finalizeTaskWithMessage:@"Lớp đầu không phải ảnh/video"]; return; }
        [self applyMediaResponse:cr toEditor:ed skipLayer:(NSInteger)first.layerIndex runId:r completion:^(NSUInteger c, NSUInteger t, NSUInteger f, BOOL b) {
            NSUInteger u = g_lastApplyUnconfirmed;
            NSMutableString *msg = [NSMutableString string];
            if (t == 0) [msg appendString:@"Xong lớp đầu, không còn lớp nào khác"];
            else [msg appendFormat:@"Xong lớp đầu + %lu/%lu lớp còn lại", (unsigned long)c, (unsigned long)t];
            if (f) [msg appendFormat:@" (%lu lớp lỗi)", (unsigned long)f];
            if (u) [msg appendFormat:@"\n⚠️ %lu lớp chưa xác nhận — xem log", (unsigned long)u];
            if (b) [msg appendString:@"\nDừng vì popup mua Pro"];
            [self finalizeTaskWithMessage:msg];
        }];
    }];
}

// ===== FEATURE 2 =====
- (void)executeFeature2DisplayLastCode {
    UIImage *img = VSReadLastPersistedQRCodeImage();
    if (!img) { [self showNotificationAlert:@"Chưa có QR nào" title:@"Chưa có"]; return; }
    if (!VSDecodeQRCodeMessageFromImage(img)) { [self showNotificationAlert:@"QR không hợp lệ" title:@"Lỗi"]; return; }
    VSToolQRCodePreviewVC *vc = [VSToolQRCodePreviewVC new];
    vc.qrImage = img; vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [[self topPresenterVC] presentViewController:vc animated:YES completion:nil];
}

// ===== FEATURE 3 =====
- (void)executeFeature3AutoSplitBeat {
    id rv = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!rv) { [self showNotificationAlert:@"Vào màn hình Review trước." title:@"Sai vị trí"]; return; }
    NSUInteger r = [self startNewTaskWithDescription:@"Auto chia beat" initialStatus:@"Chuẩn bị…"];
    id (^fetch)(void) = ^id{ return VSSafeValueForKey(rv, @"splitView"); };
    BOOL (^visible)(void) = ^BOOL{ id sv = fetch(); if (!sv) return NO; UIView *v = [sv isKindOfClass:[UIView class]] ? sv : VSSafeValueForKey(sv, @"splitPanel"); return [v isKindOfClass:[UIView class]] && v.window != nil; };
    if (!visible()) { if (!VSTry(^{ [rv showSplitScene]; })) { [self finalizeTaskWithMessage:@"Không mở được bảng chia"]; return; } }
    VSSafePoll(r, 100, 35, ^BOOL{ return visible(); }, ^(BOOL ok) {
        if (r != g_runIdentifier) return;
        id sv = fetch();
        if (!ok || !sv) { [self finalizeTaskWithMessage:@"Không tìm thấy MultiSplitView"]; return; }
        [self validateAndRunBeatSplitting:rv splitView:sv runId:r];
    });
}
- (void)validateAndRunBeatSplitting:(id)rv splitView:(id)sv runId:(NSUInteger)r {
    __block NSString *err = nil;
    VSTry(^{ id<ProjectInterface> p = [rv project]; NSUInteger s = [rv sceneIndex]; NSUInteger cc = [p clipCountForSceneIndex:s]; if (![rv isEnoughStorageAvailableForSplit]) err = @"Bộ nhớ không đủ"; else if (![p sceneHasAtLeastOneClipWithSceneIndex:s] || cc == 0) err = @"Không có clip"; });
    if (err) { [self finalizeTaskWithMessage:err]; return; }
    id<ProjectInterface> p = [rv project];
    if (!p) { [self finalizeTaskWithMessage:@"Lỗi kiểm tra"]; return; }
    NSUInteger before = [p sceneCount];
    BOOL st = VSTry(^{ if (![sv beatModeOn]) [sv toggleBeatMode]; [sv gotoTime:kCMTimeZero]; });
    if (!st) { [self finalizeTaskWithMessage:@"Không bật Beat Mode"]; return; }
    __block NSUInteger guard = 0, count = 0; __block CMTime last = kCMTimeInvalid; __block void (^step)(void) = nil;
    void (^finish)(void) = ^{
        step = nil;
        if (r != g_runIdentifier) return;
        if (count == 0 && VSCountOf(VSSafeValueForKey(sv, @"splitTimes")) == 0) { [self finalizeTaskWithMessage:@"Không có beat"]; return; }
        if (!VSTry(^{ [sv doSplit]; })) { [self finalizeTaskWithMessage:@"Lỗi chia"]; return; }
        [self updateStatusHUD:@"Đang chia…"];
        VSSafePoll(r, 120, 150, ^BOOL{ return [p sceneCount] > before; }, ^(BOOL ok) {
            if (r != g_runIdentifier) return;
            [self finalizeTaskWithMessage:ok ? [NSString stringWithFormat:@"Xong, +%lu scene", (unsigned long)([p sceneCount] - before)] : @"Chưa xong"];
        });
    };
    step = ^{
        if (r != g_runIdentifier) { step = nil; return; }
        if (++guard >= 2048) { VSLog(@"[Beat] quá 2048 bước"); finish(); return; }
        __block BOOL hasNext = NO; __block CMTime fromT = kCMTimeInvalid;
        BOOL called = VSTry(^{ hasNext = [sv hasNextBeat]; if (hasNext) { fromT = VSSafeCurrentTime(sv); [sv jumpToNextBeat]; } });
        if (!called || !hasNext) { VSLog(@"[Beat] kết thúc: called=%d hasNext=%d count=%lu", called, hasNext, (unsigned long)count); finish(); return; }
        CMTime from = fromT;
        VSSafePoll(r, 16, 60, ^BOOL{ CMTime cur = VSSafeCurrentTime(sv); return CMTIME_IS_VALID(cur) && (CMTIME_IS_INVALID(from) || CMTimeCompare(cur, from) > 0); }, ^(BOOL moved) {
            if (r != g_runIdentifier) { step = nil; return; }
            CMTime cur = VSSafeCurrentTime(sv);
            if (!moved || (CMTIME_IS_VALID(last) && CMTimeCompare(cur, last) <= 0)) { VSLog(@"[Beat] không nhảy"); finish(); return; }
            last = cur;
            if (!VSTry(^{ [sv setSplitPoint]; })) { finish(); return; }
            count++;
            [self updateStatusHUD:[NSString stringWithFormat:@"%lu điểm chia…", (unsigned long)count]];
            VSDispatchAfterMS(20, ^{ if (step) step(); });
        });
    };
    VSDispatchAfterMS(250, ^{ if (step) step(); });
}

// ===== FEATURE 4 =====
- (void)executeFeature4BatchMultiScene {
    id rv = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!rv) { [self showNotificationAlert:@"Vào màn hình phân cảnh trước" title:@"Sai vị trí"]; return; }
    NSUInteger r = [self startNewTaskWithDescription:@"Auto code + ảnh" initialStatus:nil];
    NSUInteger orig = 0; @try { orig = [rv lastViewedSceneIndex]; } @catch (...) {}
    if (!VSTry(^{ [rv showMergeScenes]; })) { [self finalizeTaskWithMessage:@"Không mở được Hợp nhất"]; return; }
    [self displayBottomActionBarWithTitle:@"Chọn phân cảnh" message:@"Chọn đầu và cuối, bấm Bắt đầu" confirmTitle:@"Bắt đầu" onConfirm:^{ [self parseMergeRangeAndPresentCodePanel:rv runId:r originalLastViewed:orig]; } onCancel:^{ VSTry(^{ [rv closeMergePanel]; }); [self terminateCurrentTaskQuietly]; }];
}
- (void)parseMergeRangeAndPresentCodePanel:(id)rv runId:(NSUInteger)r originalLastViewed:(NSUInteger)orig {
    if (r != g_runIdentifier) return;
    id<ProjectInterface> p = nil; @try { p = [rv project]; } @catch (...) {}
    NSInteger total = p ? (NSInteger)[p sceneCount] : 0;
    id sObj = VSSafeValueForKey(rv, @"startScene"), lObj = VSSafeValueForKey(rv, @"lastScene");
    NSInteger s = [sObj respondsToSelector:@selector(integerValue)] ? [sObj integerValue] : -1;
    NSInteger l = [lObj respondsToSelector:@selector(integerValue)] ? [lObj integerValue] : -1;
    VSTry(^{ [rv closeMergePanel]; });
    if (!p || s < 0 || l < s || l >= total) { [self finalizeTaskWithMessage:@"Phạm vi không hợp lệ"]; return; }
    self.multiSceneStart = (NSUInteger)s;
    self.multiSceneCount = (NSUInteger)(l - s + 1);
    self.multiSceneOriginalLastViewed = orig;
    self.multiSceneRunId = r;
    self.multiSceneActiveCapturingIndex = -1;
    self.multiScenePresets = [NSMutableArray array]; self.multiSceneCodes = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.multiSceneCount; i++) { [self.multiScenePresets addObject:[NSNull null]]; [self.multiSceneCodes addObject:[NSNull null]]; }
    [self renderMultiSceneCodeCollectionPanel];
}
- (NSUInteger)countOfReceivedCodes { NSUInteger c = 0; for (id x in self.multiSceneCodes) if (x != [NSNull null]) c++; return c; }
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
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06]; row.layer.cornerRadius = 10; row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 9, row.bounds.size.width - 140, 20)];
        t.text = [NSString stringWithFormat:@"Phân cảnh %lu", (unsigned long)(self.multiSceneStart + i + 1)];
        t.textColor = UIColor.whiteColor; t.font = [UIFont boldSystemFontOfSize:15];
        UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(14, 33, row.bounds.size.width - 140, 16)];
        s.text = has ? @"Đã nhận" : @"Chưa nhập"; s.textColor = has ? VSToolCyanColor() : [UIColor colorWithWhite:0.6 alpha:1.0]; s.font = [UIFont systemFontOfSize:11];
        UIButton *b = VSToolCreateOutlineButton(has ? @"Đổi code" : @"Nhập code", CGRectMake(row.bounds.size.width - 112, 12, 100, 36));
        b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(handleCodeRowButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:t]; [row addSubview:s]; [row addSubview:b]; [sv addSubview:row];
    }
    sv.contentSize = CGSizeMake(sv.bounds.size.width, self.multiSceneCount * 68);
    [card addSubview:sv];
    CGFloat bw = (w - 32 - 12) / 2.0;
    UIButton *cb = VSToolCreateOutlineButton(@"Hủy", CGRectMake(16, h - 52, bw, 38));
    cb.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1.0].CGColor; [cb setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    cb.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [cb addTarget:self action:@selector(handleMultiSceneCancel) forControlEvents:UIControlEventTouchUpInside];
    UIButton *nx = VSToolCreateOutlineButton(@"Chọn ảnh/video", CGRectMake(16 + bw + 12, h - 52, bw, 38));
    nx.autoresizingMask = UIViewAutoresizingFlexibleTopMargin; nx.enabled = (got == self.multiSceneCount);
    [nx addTarget:self action:@selector(handleMultiSceneProceedWithMedia) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cb]; [card addSubview:nx]; [c addSubview:card]; self.multiSceneCardView = card;
}
- (void)handleMultiSceneCancel { [self terminateCurrentTaskQuietly]; }
- (void)restoreMultiSceneCodePanel {
    g_activeMediaPickedHandler = nil; g_activeAddCapturedHandler = nil;
    [self restoreOriginalQRCodeDelegate];
    self.qrCaptureProxy = nil; self.multiSceneActiveCapturingIndex = -1;
    [self updateStatusHUD:nil];
    if (self.multiSceneCardView && self.multiSceneCount > 0) [self renderMultiSceneCodeCollectionPanel];
}
- (void)handleCodeRowButtonTapped:(UIButton *)b {
    NSUInteger off = (NSUInteger)b.tag; if (off >= self.multiSceneCount) return;
    Class qc = NSClassFromString(@"QRCodeManager");
    id qr = [qc respondsToSelector:@selector(sharedInstance)] ? [qc sharedInstance] : nil;
    if (!qr || ![qr respondsToSelector:@selector(startQRImport)]) { [self showNotificationAlert:@"Không có QRCodeManager" title:@"Lỗi"]; return; }
    VSToolQRCodeCaptureProxy *proxy = [VSToolQRCodeCaptureProxy new];
    NSUInteger r = self.multiSceneRunId;
    proxy.onCodeCapturedBlock = ^(id p, id code) {
        if (r != g_runIdentifier || self.multiSceneActiveCapturingIndex != (NSInteger)off) return;
        [self restoreOriginalQRCodeDelegate]; self.qrCaptureProxy = nil; self.multiSceneActiveCapturingIndex = -1;
        if (!p || ![code isKindOfClass:[NSString class]] || ![(NSString *)code length]) { [self renderMultiSceneCodeCollectionPanel]; [self showNotificationAlert:@"QR không hợp lệ" title:@"Lỗi"]; return; }
        self.multiScenePresets[off] = p; self.multiSceneCodes[off] = code;
        [self renderMultiSceneCodeCollectionPanel];
    };
    self.qrCaptureProxy = proxy; self.multiSceneActiveCapturingIndex = (NSInteger)off;
    if (!self.savedOriginalQRDelegateValid) { self.savedOriginalQRDelegate = VSSafeValueForKey(qr, @"delegate"); self.savedOriginalQRDelegateValid = YES; }
    @try { VSSetQRDelegateSafely(qr, proxy); self.multiSceneCardView.hidden = YES; [qr startQRImport]; }
    @catch (NSException *ex) { [self restoreMultiSceneCodePanel]; [self showNotificationAlert:[NSString stringWithFormat:@"Lỗi mở QR: %@", ex.reason ?: ex.name] title:@"Lỗi"]; }
}
- (void)handleMultiSceneProceedWithMedia {
    NSUInteger r = self.multiSceneRunId;
    if (r != g_runIdentifier || [self countOfReceivedCodes] != self.multiSceneCount) return;
    g_autoConfirmPopups = YES;
    self.multiSceneCardView.hidden = YES;
    [self executeBatchProcessingScenesWithResponse:nil runId:r];
}
- (void)showProcessingProgressPanel {
    UIView *c = self.window.rootViewController.view;
    CGFloat w = MIN(c.bounds.size.width - 24, 460), h = 132;
    UIView *card = [self buildCardContainerWithFrame:CGRectMake((c.bounds.size.width - w) / 2.0, c.bounds.size.height - c.safeAreaInsets.bottom - h - 70, w, h) title:@"Đang áp dụng" subtitle:@"Xử lý từng phân cảnh…"];
    UIButton *b = VSToolCreateOutlineButton(@"Đang chạy…", CGRectMake(w - 16 - 130, h - 52, 130, 38)); b.enabled = NO;
    [card addSubview:b]; [c addSubview:card]; self.multiSceneCardView = card;
}
- (void)executeBatchProcessingScenesWithResponse:(id)initialResp runId:(NSUInteger)r {
    NSUInteger start = self.multiSceneStart;
    NSUInteger total = self.multiSceneCount;
    NSUInteger orig = self.multiSceneOriginalLastViewed;
    NSArray *ps = [self.multiScenePresets copy]; NSArray *cs = [self.multiSceneCodes copy];
    __block id resp = initialResp;
    __block NSUInteger off = 0, ok = 0, unc = 0;
    __block void (^step)(void) = nil;
    void (^finish)(NSString *) = ^(NSString *err) {
        step = nil;
        id rv = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        VSTry(^{ [rv setLastViewedSceneIndex:orig]; });
        VSLog(@"[Finish] vc=%@ mem=%.0fMB", VSDescribeVCChain(), VSAvailableMemoryMB());
        [self terminateCurrentTaskQuietly];
        NSMutableString *m = [NSMutableString stringWithFormat:@"Xong %lu/%lu scene", (unsigned long)ok, (unsigned long)total];
        if (unc) [m appendFormat:@"\n⚠️ %lu lớp chưa xác nhận", (unsigned long)unc];
        NSString *full = err ? [err stringByAppendingFormat:@"\n%@", m] : m;
        VSLog(@"KẾT QUẢ: %@", full);
        [self showRunResultAlert:full title:err ? @"Dừng" : @"Thành công"];
    };
    step = ^{
        if (r != g_runIdentifier) { step = nil; return; }
        if (off >= total) { finish(nil); return; }
        NSUInteger o = off++, sc = start + o;
        [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu (%lu/%lu): mở…", (unsigned long)(sc + 1), (unsigned long)(o + 1), (unsigned long)total]];
        id rv = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        [self openMultiLayerEditorForScene:sc reviewVC:rv runId:r completion:^(id ed) {
            if (r != g_runIdentifier) { step = nil; return; }
            if (!ed) { finish([NSString stringWithFormat:@"Không mở được scene %lu", (unsigned long)(sc + 1)]); return; }
            [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: nhập code…", (unsigned long)(sc + 1)]];
            [self importPresetPayload:ps[o] codeIdentifier:cs[o] intoEditor:ed runId:r completion:^(NSString *e1) {
                if (r != g_runIdentifier) { step = nil; return; }
                if (e1) { finish([NSString stringWithFormat:@"Scene %lu: %@", (unsigned long)(sc + 1), e1]); return; }
                [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: đợi ổn định…", (unsigned long)(sc + 1)]];
                VSDispatchAfterMS(500, ^{
                    if (r != g_runIdentifier) { step = nil; return; }
                    void (^applyRest)(NSInteger) = ^(NSInteger sk) {
                        [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: thay media…", (unsigned long)(sc + 1)]];
                        [self applyMediaResponse:resp toEditor:ed skipLayer:sk runId:r completion:^(NSUInteger c, NSUInteger t, NSUInteger f, BOOL b) {
                            if (r != g_runIdentifier) { step = nil; return; }
                            unc += g_lastApplyUnconfirmed;
                            if (b) { finish([NSString stringWithFormat:@"Scene %lu: popup mua Pro", (unsigned long)(sc + 1)]); return; }
                            if (!VSEditorIsAlive(ed)) { finish([NSString stringWithFormat:@"Scene %lu: editor bị đóng trước Tạo", (unsigned long)(sc + 1)]); return; }
                            if (f > 0) { finish([NSString stringWithFormat:@"Scene %lu: còn %lu lớp chưa thay — chưa Tạo", (unsigned long)(sc + 1), (unsigned long)f]); return; }
                            [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: đã thay %lu/%lu, chuẩn bị Tạo…", (unsigned long)(sc + 1), (unsigned long)c, (unsigned long)t]];
                            [self waitForEditorSettledThenCreate:ed runId:r completion:^(NSString *e2) {
                                if (r != g_runIdentifier) { step = nil; return; }
                                if (e2) { finish([NSString stringWithFormat:@"Scene %lu: %@", (unsigned long)(sc + 1), e2]); return; }
                                ok++;
                                VSSafePoll(r, 100, 120, ^BOOL{ return VSFindTopViewControllerNamed(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                                    if (r != g_runIdentifier) { step = nil; return; }
                                    if (!back) { finish(@"Không quay lại được"); return; }
                                    VSDispatchAfterMS(300, ^{ if (step) step(); });
                                });
                            }];
                        }];
                    };
                    if (resp) { applyRest(-1); return; }
                    id eng = nil; @try { eng = [ed getMultiLayerEngine]; } @catch (...) {}
                    if (!VSFirstReplaceableLayer(eng)) { finish([NSString stringWithFormat:@"Scene %lu: preset không có lớp video/ảnh", (unsigned long)(sc + 1)]); return; }
                    [self updateStatusHUD:@"Chọn 1 ảnh/video dùng chung…"];
                    [self requestUserMediaSelectionOnEditor:ed runId:r completion:^(id rr, VSLayerSnapshot *first) {
                        if (r != g_runIdentifier) { step = nil; return; }
                        if (!rr) { finish(@"Chưa chọn media"); return; }
                        if (!first || !VSLayerKindIsReplaceable(first.mediaKind)) { finish(@"Lớp đầu không phải ảnh/video"); return; }
                        resp = rr;
                        [self.multiSceneCardView removeFromSuperview]; self.multiSceneCardView = nil;
                        [self updateStatusHUD:nil]; [self showProcessingProgressPanel];
                        applyRest((NSInteger)first.layerIndex);
                    }];
                });
            }];
        }];
    };
    step();
}
- (void)openMultiLayerEditorForScene:(NSUInteger)sc reviewVC:(id)rv runId:(NSUInteger)r completion:(void (^)(id))d {
    id (^cur)(void) = ^id{
        id ed = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
        if (!ed || ![ed getMultiLayerEngine]) return nil;
        id nav = [ed navigationController];
        BOOL ok = YES;
        if ([nav respondsToSelector:@selector(navSceneIndex)]) ok = ([nav navSceneIndex] == sc);
        return ok ? ed : nil;
    };
    id ex = nil; @try { ex = cur(); } @catch (...) {}
    if (ex) { d(ex); return; }
    if (!rv) { d(nil); return; }
    if (!VSTry(^{ [rv setLastViewedSceneIndex:sc]; [rv showMultiLayer]; })) { d(nil); return; }
    VSSafePoll(r, 80, 100, ^BOOL{ return cur() != nil; }, ^(BOOL ok) { id ed = nil; if (ok) { @try { ed = cur(); } @catch (...) {} } d(ed); });
}
- (void)importPresetPayload:(id)p codeIdentifier:(id)c intoEditor:(id)e runId:(NSUInteger)r completion:(void (^)(NSString *))d {
    if (![e respondsToSelector:@selector(importedData:code:)]) { d(@"Editor không hỗ trợ"); return; }
    NSUInteger before = g_presetImportEventCounter;
    @try { [e importedData:p code:c]; } @catch (NSException *ex) { d([NSString stringWithFormat:@"Lỗi nạp: %@", ex.reason ?: ex.name]); return; }
    __block BOOL blocked = NO;
    VSSafePoll(r, 50, 200, ^BOOL{
        VSPopupActionStatus s = VSResolvePopupsImmediately(e);
        if (s == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
        return g_presetImportEventCounter > before;
    }, ^(BOOL ok) {
        if (r != g_runIdentifier) return;
        if (blocked) { d(@"Popup mua Pro"); return; }
        if (!ok) { d(@"Timeout 10s"); return; }
        VSDispatchAfterMS(500, ^{
            if (r != g_runIdentifier) return;
            id eng = [e getMultiLayerEngine]; __block BOOL pur = NO;
            VSSafePoll(r, 60, 60, ^BOOL{
                if (VSResolvePopupsImmediately(e) == VSPopupActionStatusBlockedPurchase) { pur = YES; return YES; }
                return !VSHasAnyActivePopup(e) && [eng numActiveLayers] > 0;
            }, ^(BOOL ready) {
                if (r != g_runIdentifier) return;
                d(pur ? @"Popup mua Pro" : (ready ? nil : @"Engine chưa sẵn sàng"));
            });
        });
    });
}
- (void)waitForEditorSettledThenCreate:(id)e runId:(NSUInteger)r completion:(void (^)(NSString *))d {
    __block NSUInteger st = 0; __block BOOL pur = NO;
    VSSafePoll(r, 100, 150, ^BOOL{
        if (!VSEditorIsAlive(e)) return YES;
        VSDismissLayerActionMenus(e);
        if (VSResolvePopupsImmediately(e) == VSPopupActionStatusBlockedPurchase) { pur = YES; return YES; }
        BOOL calm = !VSHasAnyActivePopup(e) && !VSEditorIsBusy(e);
        st = calm ? st + 1 : 0;
        return st >= 8;
    }, ^(BOOL ok) {
        if (r != g_runIdentifier) return;
        if (pur) { d(@"Popup mua Pro"); return; }
        if (!VSEditorIsAlive(e)) { d(@"Editor bị đóng trước Tạo"); return; }
        if (!ok) { d(@"Editor chưa ổn định để Tạo"); return; }
        [self triggerCreateInEditor:e runId:r completion:d];
    });
}
- (void)triggerCreateInEditor:(id)e runId:(NSUInteger)r completion:(void (^)(NSString *))d {
    UIBarButtonItem *btn = VSFindCreateButtonOnEditor(e);
    if (!btn) { d(@"Không tìm thấy nút Tạo"); return; }
    VSLog(@"[Create] '%@' action='%@' enabled=%d", btn.title ?: @"?", btn.action ? NSStringFromSelector(btn.action) : @"?", btn.enabled);
    VSLogState(@"ngay trước Tạo", e);
    g_createInProgress = YES;
    __block BOOL fired = NO;
    if (btn.action && btn.target) { if (!VSTry(^{ fired = [UIApplication.sharedApplication sendAction:btn.action to:btn.target from:btn forEvent:nil]; })) { g_createInProgress = NO; d(@"Lỗi nhấn Tạo"); return; } }
    if (!fired && [e respondsToSelector:@selector(create)]) { if (!VSTry(^{ [e create]; fired = YES; })) { g_createInProgress = NO; d(@"Lỗi create"); return; } }
    if (!fired) { g_createInProgress = NO; d(@"Không kích hoạt được"); return; }
    __block BOOL blocked = NO;
    VSSafePoll(r, 100, 600, ^BOOL{
        if (VSResolvePopupsImmediately(e) == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
        return !([e isViewLoaded] && [[e view] window]);
    }, ^(BOOL closed) {
        g_createInProgress = NO;
        VSLog(@"[Create] closed=%d blocked=%d vc=%@", closed, blocked, VSDescribeVCChain());
        if (r != g_runIdentifier) return;
        d(blocked ? @"Tạo yêu cầu Pro" : (closed ? nil : @"Tạo timeout"));
    });
}
@end

// ===== ENTRY =====
static void VSBootstrapAutomation(void) {
    if (!NSClassFromString(@"MultiLayerWizEffectVC")) { VSLog(@"Không phải Video Star"); return; }
    VSRunOnMain(^{ @try { [VSTool.shared setupToolInterfaceIfNeeded]; } @catch (NSException *e) { VSLog(@"Setup error: %@", e); } });
}
__attribute__((constructor)) static void VSToolInitializerEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool {
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { @autoreleasepool { VSBootstrapAutomation(); } }];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) VSBootstrapAutomation();
    } });
}
