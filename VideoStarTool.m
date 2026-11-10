// ============================================================================
// VideoStarTool.m — Video Star 14.3.3 (build 1809)
// LOGIC:
//   1. Video/Image → thay | Rỗng → giữ | Khác (3D/text/color) → giữ
//   2. CN1: mở picker, KHÔNG bấm popup | CN4: mở picker + bấm popup
//   3. Layer 2+ chạy ngầm
// LOG: Ghi ra Documents/VideoStarTool.log — xuất qua menu "📋 Xuất log"
// ============================================================================

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <PhotosUI/PhotosUI.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define VS_MAX_LAYERS 30
#define VS_TAG "[VideoStarTool] "

// ============================================================================
// LOG SYSTEM
// ============================================================================
static NSString *VSLogFilePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"VideoStarTool.log"];
}

static void VSLogFileInternal(NSString *msg) {
    NSLog(@VS_TAG "%@", msg);
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
            NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSString *path = VSLogFilePath();
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
            if (attrs && [attrs fileSize] > 2*1024*1024) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) { @try { [fh seekToEndOfFile]; [fh writeData:d]; } @catch (...) {} [fh closeFile]; }
            else [d writeToFile:path atomically:YES];
        }
    });
}
#define VSLog(fmt, ...) VSLogFileInternal([NSString stringWithFormat:fmt, ##__VA_ARGS__])

// ============================================================================
// PRIVATE API
// ============================================================================
@protocol ProjectInterface <NSObject>
@property (nonatomic, readonly) NSUInteger sceneCount;
- (NSUInteger)clipCountForSceneIndex:(NSUInteger)i;
- (BOOL)sceneHasAtLeastOneClipWithSceneIndex:(NSUInteger)i;
- (id)fileManager;
@end

@interface NSObject (VSPrivate)
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
- (void)setDelegate:(id)d;
- (id)delegate;
- (void)show;
- (void)dismiss;
- (void)simulateButtonPressButtonWithTitle:(id)title;
- (void)cancel;
- (void)cancelCreate;
- (void)close;
- (void)viewDidDisappear:(BOOL)animated;
@end

// ============================================================================
// STATE + UTILITIES
// ============================================================================
static NSUInteger g_runId = 0;
static BOOL g_autoConfirmPopups = NO;
static BOOL g_suppressLayerActionMenu = NO;
static BOOL g_guardCancel = NO;
static BOOL g_createInProgress = NO;
static const void *kPopupHandled = &kPopupHandled;
static NSHashTable *g_popups = nil;
static UIWindow *g_toolWindow = nil;

static inline void VSAfter(int64_t ms, dispatch_block_t b) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ @autoreleasepool { b(); } });
}
static inline void VSMain(dispatch_block_t b) {
    if ([NSThread isMainThread]) { @autoreleasepool { b(); } } else dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { b(); } });
}
static BOOL VSTry(void (^b)(void)) { @try { b(); return YES; } @catch (NSException *e) { VSLog(@"EXCEPTION %@: %@", e.name, e.reason); return NO; } }
static inline BOOL VSContains(NSString *h, NSString *n) { return h.length && n.length && [h rangeOfString:n options:NSCaseInsensitiveSearch].location != NSNotFound; }
static BOOL VSHasIvar(id o, NSString *n) { return o && n.length && class_getInstanceVariable(object_getClass(o), n.UTF8String) != NULL; }

static id VSValue(id o, NSString *k) {
    if (!o || !k.length) return nil;
    @try {
        BOOL ok = [o respondsToSelector:NSSelectorFromString(k)] || VSHasIvar(o, [@"_" stringByAppendingString:k]) || VSHasIvar(o, k);
        return ok ? [o valueForKey:k] : nil;
    } @catch (...) { return nil; }
}
static BOOL VSTruthy(id v) {
    if (!v || v == [NSNull null]) return NO;
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [v length] > 0;
    if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]] || [v isKindOfClass:[NSDictionary class]]) return [v count] > 0;
    return YES;
}
static NSUInteger VSCount(id v) {
    return (v && ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]] || [v isKindOfClass:[NSDictionary class]])) ? [v count] : 0;
}
static CMTime VSTime(id o) {
    if (!o) return kCMTimeInvalid;
    SEL s = @selector(currentTime);
    if (![o respondsToSelector:s]) return kCMTimeInvalid;
    @try { CMTime (*f)(id, SEL) = (CMTime (*)(id, SEL))[o methodForSelector:s]; return f(o, s); } @catch (...) { return kCMTimeInvalid; }
}
static void VSSetQRDelegate(id qr, id d) {
    if (!qr) return;
    SEL s = @selector(setDelegate:);
    if (![qr respondsToSelector:s]) return;
    @try { ((void (*)(id, SEL, id))[qr methodForSelector:s])(qr, s, d); } @catch (...) {}
}

// UIBarButtonItem Tạo (không bao giờ Hủy)
static UIBarButtonItem *VSFindCreateButton(id editor) {
    if (!editor) return nil;
    NSArray *ck = @[@"tạo", @"create", @"done", @"xong", @"save", @"lưu", @"export", @"xuất"];
    NSArray *hk = @[@"hủy", @"huỷ", @"cancel", @"back", @"quay lại", @"dismiss", @"close", @"đóng"];
    id cancelRef = VSValue(editor, @"cancelBarButton");
    BOOL (^isCreate)(UIBarButtonItem *) = ^BOOL(UIBarButtonItem *b) {
        if (!b || b == cancelRef) return NO;
        NSString *t = b.title ?: @"";
        NSString *a = b.action ? [NSStringFromSelector(b.action) stringByReplacingOccurrencesOfString:@"_" withString:@""] : @"";
        for (NSString *k in hk) if (VSContains(t, k) || VSContains(a, k)) return NO;
        for (NSString *k in ck) if (VSContains(t, k) || VSContains(a, k)) return YES;
        return NO;
    };
    id kvc = VSValue(editor, @"createBarButton");
    if ([kvc isKindOfClass:[UIBarButtonItem class]] && kvc != cancelRef) {
        VSLog(@"[CreateButton] KVC: '%@'", ((UIBarButtonItem *)kvc).title ?: @"?");
        return (UIBarButtonItem *)kvc;
    }
    UINavigationController *nav = nil;
    @try { nav = [editor navigationController]; } @catch (...) {}
    if (nav) {
        UINavigationItem *ni = nav.topViewController.navigationItem;
        for (UIBarButtonItem *b in ni.rightBarButtonItems) if (isCreate(b)) return b;
        if (isCreate(ni.rightBarButtonItem)) return ni.rightBarButtonItem;
    }
    return nil;
}

// Poll
static void VSPoll(NSUInteger rid, int64_t ms, NSUInteger tries, BOOL (^cond)(void), void (^done)(BOOL)) {
    if (rid != g_runId) { if (done) done(NO); return; }
    BOOL ok = NO;
    @autoreleasepool { @try { ok = cond(); } @catch (...) { ok = NO; } }
    if (ok) { if (done) done(YES); return; }
    if (tries == 0) { if (done) done(NO); return; }
    VSAfter(ms, ^{ VSPoll(rid, ms, tries-1, cond, done); });
}

// Tìm VC
static UIViewController *VSFindVCRec(UIViewController *vc, Class cls, int depth) {
    if (!vc || depth > 15) return nil;
    if (vc.presentedViewController) { UIViewController *r = VSFindVCRec(vc.presentedViewController, cls, depth+1); if (r) return r; }
    if ([vc isKindOfClass:[UINavigationController class]])
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers.reverseObjectEnumerator) {
            UIViewController *r = VSFindVCRec(c, cls, depth+1); if (r) return r;
        }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *r = VSFindVCRec(((UITabBarController *)vc).selectedViewController, cls, depth+1); if (r) return r;
    }
    for (UIViewController *c in vc.childViewControllers.reverseObjectEnumerator) {
        UIViewController *r = VSFindVCRec(c, cls, depth+1); if (r) return r;
    }
    if ([vc isKindOfClass:cls] && vc.isViewLoaded && vc.view.window) return vc;
    return nil;
}
static UIViewController *VSFindVC(NSString *name) {
    Class c = NSClassFromString(name); if (!c) return nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (w == g_toolWindow || w.hidden || w.alpha <= 0.01) continue;
        UIViewController *r = VSFindVCRec(w.rootViewController, c, 0); if (r) return r;
    }
    return nil;
}

// ============================================================================
// SMART POPUP
// ============================================================================
typedef NS_ENUM(NSInteger, VSPopupStatus) { VSPopupNone = 0, VSPopupHandled, VSPopupBlockedPurchase };

static NSArray *VSVisiblePopups(id editor) {
    NSMutableArray *all = [NSMutableArray array];
    if (editor) for (NSString *k in @[@"ourPopup", @"warningPopup", @"object3DPickerPopup", @"copyLayerPopup"]) {
        id p = VSValue(editor, k); if (p && ![all containsObject:p]) [all addObject:p];
    }
    for (id p in g_popups.allObjects) if (![all containsObject:p]) [all addObject:p];
    NSMutableArray *vis = [NSMutableArray array];
    for (id p in all) {
        if (![p isKindOfClass:NSClassFromString(@"CustomPopup")]) continue;
        UIView *dim = VSValue(p, @"dimView");
        UIView *pv = [p isKindOfClass:[UIView class]] ? p : nil;
        if ((dim && dim.window) || (pv && pv.window)) [vis addObject:p];
    }
    return vis;
}

static BOOL VSPopupIsPurchase(id p) {
    NSString *s = [NSString stringWithFormat:@" %@ %@ ",
                   [VSValue(p, @"_title") description] ?: @"", [VSValue(p, @"_message") description] ?: @""];
    for (NSString *k in @[@"purchase", @"subscription", @"unlock pro", @"pro pack", @"restore purchase",
                          @"all access", @" pass ", @" buy ", @"upgrade", @"free trial", @"mua gói", @"khôi phục",
                          @"đăng ký", @"nâng cấp", @"dùng thử", @"mở khóa", @"thanh toán"])
        if (VSContains(s, k)) return YES;
    return NO;
}

static BOOL VSTitleMatches(NSString *t, NSString *c) {
    if (!t.length || !c.length) return NO;
    NSString *tr = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return c.length <= 4 ? [tr caseInsensitiveCompare:c] == NSOrderedSame : VSContains(tr, c);
}

static NSArray<NSString *> *VSPopupTitles(id p, NSDictionary<NSString *, UIButton *> **map) {
    NSMutableArray *ts = [NSMutableArray array];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    id ss = VSValue(p, @"_buttonStrings");
    if ([ss isKindOfClass:[NSArray class]]) for (id t in ss) if ([t isKindOfClass:[NSString class]] && [t length]) [ts addObject:t];
    id bs = VSValue(p, @"_buttons");
    if ([bs isKindOfClass:[NSArray class]]) for (id b in bs) {
        if (![b isKindOfClass:[UIButton class]]) continue;
        NSString *t = ((UIButton *)b).currentTitle; if (!t.length) continue;
        m[t] = b; if (![ts containsObject:t]) [ts addObject:t];
    }
    if (map) *map = m;
    return ts;
}

static BOOL VSPopupIsLayerMenu(id p) {
    NSArray *ts = VSPopupTitles(p, NULL);
    if (ts.count < 3) return NO;
    NSArray *known = @[@"Edit Keyframes", @"Biên tập Khung hình chính", @"Add Mask", @"Thêm Mặt nạ",
                       @"Edit Title", @"Sửa tiêu đề", @"Replace Content", @"Thay Nội dung",
                       @"Deactivate", @"Activate", @"Hủy kích hoạt", @"Kích hoạt", @"Delete", @"Xoá", @"Xóa"];
    NSUInteger hits = 0;
    for (NSString *t in ts) for (NSString *k in known) if (VSTitleMatches(t, k)) { hits++; break; }
    return hits >= 3;
}

static void VSDismissLayerMenus(id editor) {
    if (!g_suppressLayerActionMenu) return;
    for (id p in VSVisiblePopups(editor)) if (VSPopupIsLayerMenu(p)) {
        VSTry(^{ if ([p respondsToSelector:@selector(dismiss)]) { VSLog(@"[LayerMenu] dismiss"); [p dismiss]; } });
    }
}

static BOOL VSEditorAlive(id e) {
    if (!e) return NO;
    @try { return [e isViewLoaded] && [[e view] window] != nil; } @catch (...) { return NO; }
}
static BOOL VSEditorBusy(id e) {
    id sp = VSValue(e, @"spinner");
    if ([sp isKindOfClass:[UIActivityIndicatorView class]]) {
        UIActivityIndicatorView *a = sp;
        if (a.isAnimating && a.window && !a.hidden) return YES;
    }
    id la = VSValue(e, @"loadingAlert");
    if ([la isKindOfClass:[UIView class]]) { UIView *v = la; if (v.window && !v.hidden && v.alpha > 0.01) return YES; }
    return NO;
}
static BOOL VSPopupHandled(id p) { return [objc_getAssociatedObject(p, kPopupHandled) boolValue]; }
static BOOL VSCancelLike(NSString *t) {
    for (NSString *k in @[@"hủy", @"huỷ", @"cancel", @"không", @"no", @"back", @"quay lại", @"close", @"đóng", @"dismiss"])
        if (k.length <= 3 ? [t.lowercaseString isEqualToString:k] : VSContains(t, k)) return YES;
    return NO;
}

static VSPopupStatus VSResolvePopups(id editor) {
    if (!g_autoConfirmPopups) return VSPopupNone;
    NSArray *ps = VSVisiblePopups(editor); if (!ps.count) return VSPopupNone;
    NSArray *matchNames = @[@"Khớp: rút ngắn/giãn", @"Match: shorten/stretch", @"Trùng khớp", @"Match"];
    NSArray *fallbackNames = @[@"Bắt đầu", @"Start", @"Kết thúc", @"End"];
    NSArray *okNames = @[@"OK", @"Đồng ý", @"Xong", @"Done"];
    BOOL anyHandled = NO;
    for (id p in ps) {
        if (VSPopupIsLayerMenu(p)) continue;
        if (VSPopupIsPurchase(p)) { VSLog(@"Popup mua Pro"); return VSPopupBlockedPurchase; }
        if (VSPopupHandled(p)) { anyHandled = YES; continue; }
        NSDictionary *map = nil;
        NSArray *ts = VSPopupTitles(p, &map); if (!ts.count) continue;
        NSString *(^firstMatch)(NSArray *) = ^NSString *(NSArray *names) {
            for (NSString *c in names) { NSString *loc = [NSBundle.mainBundle localizedStringForKey:c value:c table:nil];
                for (NSString *t in ts) { if (VSCancelLike(t)) continue; if (VSTitleMatches(t, c) || VSTitleMatches(t, loc)) return t; } }
            return nil;
        };
        NSString *hdr = [NSString stringWithFormat:@"%@ %@", [VSValue(p, @"_title") description] ?: @"", [VSValue(p, @"_message") description] ?: @""];
        NSString *hit = nil; NSString *reason = nil;
        if ((hit = firstMatch(matchNames))) reason = @"trùng khớp";
        else if (VSContains(hdr, @"Original Preset Layers") || VSContains(hdr, @"Cài đặt sẵn Gốc") ||
                 VSContains(hdr, [NSBundle.mainBundle localizedStringForKey:@"Original Preset Layers" value:@"Original Preset Layers" table:nil])) {
            hit = firstMatch(okNames); reason = @"preset info";
        }
        else if (ts.count == 1) { hit = firstMatch(okNames); reason = @"single-button"; }
        else if (VSContains(hdr, @"dài hơn") && (hit = firstMatch(fallbackNames))) reason = @"mismatch fallback";
        if (!hit) { VSLog(@"[SmartPopup] popup lạ KHÔNG bấm: %@", [ts componentsJoinedByString:@" | "]); continue; }
        objc_setAssociatedObject(p, kPopupHandled, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIButton *btn = map[hit];
        VSTry(^{ VSLog(@"[SmartPopup] (%@) nhấn: '%@'", reason, hit);
            if ([p respondsToSelector:@selector(simulateButtonPressButtonWithTitle:)]) [p simulateButtonPressButtonWithTitle:hit];
            else if (btn) [btn sendActionsForControlEvents:UIControlEventTouchUpInside]; });
        return VSPopupHandled;
    }
    return anyHandled ? VSPopupHandled : VSPopupNone;
}
static BOOL VSHasPopup(id e) {
    for (id p in VSVisiblePopups(e)) {
        if (VSPopupIsLayerMenu(p)) continue;
        if (VSPopupHandled(p) && ((UIView *)p).alpha < 0.05) continue;
        return YES;
    }
    return NO;
}

// ============================================================================
// LAYER CLASSIFICATION
// ============================================================================
typedef NS_ENUM(NSInteger, VSKind) { VSKindUnknown = 0, VSKindImage, VSKindVideo, VSKindEmpty, VSKindOther };
static inline BOOL VSKindReplaceable(VSKind k) { return k == VSKindImage || k == VSKindVideo; }

@interface VSSnap : NSObject
@property (nonatomic, assign) NSUInteger layerIndex;
@property (nonatomic, assign) VSKind mediaKind;
@property (nonatomic, strong) id mediaObject;
@property (nonatomic, assign) unsigned int textureID;
@property (nonatomic, copy) NSString *assetInfo;
@property (nonatomic, copy) NSString *signature;
@end
@implementation VSSnap @end

static VSSnap *VSInspect(id engine, NSUInteger n) {
    if (!engine || ![engine respondsToSelector:@selector(layerAtLayerNum:)]) return nil;
    @autoreleasepool {
        @try {
            id layer = [engine layerAtLayerNum:n]; if (!layer) return nil;
            VSSnap *s = [VSSnap new]; s.layerIndex = n; s.mediaKind = VSKindOther;
            s.assetInfo = [VSValue(layer, @"origAssetInfo") description] ?: @"";
            if (VSTruthy(VSValue(layer, @"isNullLayer"))) { s.signature = @"null"; VSLog(@"[L%lu] NULL", (unsigned long)n); return s; }
            id gen = VSValue(layer, @"imageGenerator");
            if (!gen) { s.mediaKind = VSKindEmpty; s.signature = @"nogen"; VSLog(@"[L%lu] RỖNG (no gen)", (unsigned long)n); return s; }
            id asset = VSValue(gen, @"asset"), rawImg = VSValue(gen, @"layerImage");
            UIImage *img = [rawImg isKindOfClass:[UIImage class]] ? rawImg : nil;
            id tex = VSValue(gen, @"layerImageTextureID");
            unsigned int texID = [tex isKindOfClass:[NSNumber class]] ? [tex unsignedIntValue] : 0;
            id dr = VSValue(gen, @"layerDrawing"), zp = VSValue(gen, @"layerZaps");
            id gif = VSValue(gen, @"layerGIF"), ov = VSValue(gen, @"layerOverlay");
            VSLog(@"[L%lu INSPECT] asset=%@ img=%@(%@) tex=%u dr=%d zp=%d gif=%d ov=%d info='%@'",
                  (unsigned long)n, asset ? NSStringFromClass([asset class]) : @"nil",
                  img ? @"Y" : @"n", img ? NSStringFromCGSize(img.size) : @"", texID,
                  dr != nil, zp != nil, gif != nil, ov != nil, s.assetInfo);
            for (NSString *k in @[@"layerGIF", @"layerZaps", @"layerDrawing", @"layerOverlay"])
                if (VSTruthy(VSValue(gen, k))) { s.signature = k; VSLog(@"[L%lu] OTHER %@", (unsigned long)n, k); return s; }
            BOOL hasVideo = [asset isKindOfClass:[AVAsset class]];
            BOOL hasImage = img && img.size.width > 1.0 && img.size.height > 1.0;
            // Placeholder: có img nhưng chưa có assetInfo và chưa render texture → coi là rỗng
            BOOL placeholder = hasImage && s.assetInfo.length == 0 && texID == 0;
            if (!hasVideo && (VSTruthy(VSValue(layer, @"textDictionary")) || VSTruthy(VSValue(layer, @"particleLabModel")))) {
                s.signature = @"text"; VSLog(@"[L%lu] TEXT/PARTICLE", (unsigned long)n); return s;
            }
            NSString *assetKey = @"";
            if ([asset isKindOfClass:[AVURLAsset class]]) assetKey = ((AVURLAsset *)asset).URL.absoluteString ?: @"";
            else if (hasVideo) assetKey = [NSString stringWithFormat:@"%p", asset];
            else if (hasImage) assetKey = [NSString stringWithFormat:@"%.0fx%.0f", img.size.width, img.size.height];
            if (hasVideo) { s.mediaKind = VSKindVideo; s.mediaObject = asset; s.textureID = texID;
                VSLog(@"[L%lu] ✓ VIDEO", (unsigned long)n); }
            else if (hasImage && !placeholder) { s.mediaKind = VSKindImage; s.mediaObject = img; s.textureID = texID;
                VSLog(@"[L%lu] ✓ IMAGE", (unsigned long)n); }
            else { s.mediaKind = VSKindEmpty;
                VSLog(@"[L%lu] RỖNG%@", (unsigned long)n, placeholder ? @" (placeholder)" : @""); }
            s.signature = [NSString stringWithFormat:@"%ld|%u|%@|%@", (long)s.mediaKind, s.textureID, s.assetInfo, assetKey];
            return s;
        } @catch (NSException *e) { VSLog(@"Inspect L%lu EXC: %@ — %@", (unsigned long)n, e.name, e.reason); return nil; }
    }
}

static NSArray<VSSnap *> *VSScan(id engine) {
    NSMutableArray *out = [NSMutableArray array]; NSUInteger misses = 0;
    for (NSUInteger i = 0; i < VS_MAX_LAYERS; i++) {
        VSSnap *s = VSInspect(engine, i);
        if (!s) { if (++misses >= 3) break; continue; }
        misses = 0; [out addObject:s];
    }
    return out;
}
static VSSnap *VSFirstReplaceable(id engine) {
    for (VSSnap *s in VSScan(engine)) if (VSKindReplaceable(s.mediaKind)) return s;
    return nil;
}

static void VSSelectLayer(id editor, NSUInteger n, NSUInteger rid, void (^done)(BOOL)) {
    BOOL (^isSel)(void) = ^BOOL{ return [editor lastSelectedLayerNum] == (NSInteger)n; };
    BOOL already = NO; @try { already = isSel(); } @catch (...) {}
    if (already) { VSDismissLayerMenus(editor); done(YES); return; }
    VSTry(^{ if ([editor respondsToSelector:@selector(selectLayer:bordered:)]) [editor selectLayer:n bordered:NO]; });
    VSPoll(rid, 50, 20, isSel, ^(BOOL ok) {
        if (ok) { VSDismissLayerMenus(editor); done(YES); return; }
        VSTry(^{ if ([editor respondsToSelector:@selector(selectLayerNum:flash:)]) [editor selectLayerNum:n flash:NO]; });
        VSPoll(rid, 50, 12, isSel, ^(BOOL ok2) { VSDismissLayerMenus(editor); done(ok2); });
    });
}

static void VSRefresh(id editor, id engine) {
    VSTry(^{ if ([engine respondsToSelector:@selector(reloadLayerEffects)]) [engine reloadLayerEffects]; });
    VSTry(^{ if ([editor respondsToSelector:@selector(handleImageGenUpdate)]) [editor handleImageGenUpdate]; });
    VSTry(^{ if ([editor respondsToSelector:@selector(engineResync)]) [editor engineResync]; });
    VSTry(^{ if ([editor respondsToSelector:@selector(refreshDisplay)]) [editor refreshDisplay]; });
}

// ============================================================================
// QR STORAGE
// ============================================================================
static NSString *VSQRPath(void) {
    NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [d stringByAppendingPathComponent:@"VideoStarTool_LastQR.png"];
}
static void VSSaveQR(id data) {
    if (!data) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool {
        UIImage *img = [data isKindOfClass:[NSData class]] ? [UIImage imageWithData:data] : ([data isKindOfClass:[UIImage class]] ? data : nil);
        if (img) { NSData *png = UIImagePNGRepresentation(img); if (png.length) { [png writeToFile:VSQRPath() atomically:YES]; VSLog(@"Saved QR %lu bytes", (unsigned long)png.length); } }
    }});
}
static UIImage *VSLoadQR(void) { NSData *d = [NSData dataWithContentsOfFile:VSQRPath()]; return d.length ? [UIImage imageWithData:d] : nil; }
static NSString *VSDecodeQR(UIImage *img) {
    if (!img) return nil;
    @autoreleasepool {
        CIImage *ci = img.CGImage ? [CIImage imageWithCGImage:img.CGImage] : [[CIImage alloc] initWithImage:img];
        if (!ci) return nil;
        CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
        for (CIFeature *f in [det featuresInImage:ci])
            if ([f isKindOfClass:[CIQRCodeFeature class]] && ((CIQRCodeFeature *)f).messageString.length) return ((CIQRCodeFeature *)f).messageString;
    }
    return nil;
}

// ============================================================================
// HOOKS
// ============================================================================
static IMP g_origPicked, g_origSelectedCode, g_origImportNew, g_origImportOld, g_origPopupMove;
static IMP g_origLayerMenu, g_origCancel, g_origCancelCreate, g_origClose, g_origViewDisappear;
static NSUInteger g_importCount = 0;
static void (^g_pickedHandler)(id, id) = nil;

static BOOL VSSwizzle(NSString *cls, SEL sel, id block, IMP *orig) {
    Class c = NSClassFromString(cls); if (!c) { VSLog(@"Hook miss class %@", cls); return NO; }
    Method m = class_getInstanceMethod(c, sel); if (!m) { VSLog(@"Hook miss -%@ %@", cls, NSStringFromSelector(sel)); return NO; }
    if (*orig) return YES;
    IMP imp = imp_implementationWithBlock(block);
    if (class_addMethod(c, sel, imp, method_getTypeEncoding(m))) *orig = method_getImplementation(m);
    else *orig = method_setImplementation(m, imp);
    return YES;
}

static void VSInstallHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_popups = [NSHashTable weakObjectsHashTable];

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(pickedWithClipPickerResponse:), ^(id me, id resp) {
            if (g_origPicked) ((void (*)(id, SEL, id))g_origPicked)(me, @selector(pickedWithClipPickerResponse:), resp);
            void (^h)(id, id) = g_pickedHandler;
            if (h) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { h(me, resp); } });
        }, &g_origPicked);

        VSSwizzle(@"QRCodeManager", @selector(selectedCode:withImageData:), ^(id me, id code, id data) {
            VSSaveQR(data);
            if (g_origSelectedCode) ((void (*)(id, SEL, id, id))g_origSelectedCode)(me, @selector(selectedCode:withImageData:), code, data);
        }, &g_origSelectedCode);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), ^(id me, id a, id b, NSInteger f) {
            if (g_origImportNew) ((void (*)(id, SEL, id, id, NSInteger))g_origImportNew)(me, @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), a, b, f);
            g_importCount++;
        }, &g_origImportNew);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(importOldPreset:), ^(id me, id a) {
            if (g_origImportOld) ((void (*)(id, SEL, id))g_origImportOld)(me, @selector(importOldPreset:), a);
            g_importCount++;
        }, &g_origImportOld);

        VSSwizzle(@"CustomPopup", @selector(didMoveToWindow), ^(id me) {
            if (g_origPopupMove) ((void (*)(id, SEL))g_origPopupMove)(me, @selector(didMoveToWindow));
            if (![me isKindOfClass:[UIView class]] || !((UIView *)me).window) return;
            [g_popups addObject:me];
            if (g_autoConfirmPopups) VSAfter(80, ^{ VSResolvePopups(nil); });
        }, &g_origPopupMove);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(showLayerActionMenu:newLayer:), ^(id me, NSUInteger n, BOOL isNew) {
            if (g_suppressLayerActionMenu) { VSLog(@"[LayerMenu] CHẶN show L%lu", (unsigned long)n); return; }
            if (g_origLayerMenu) ((void (*)(id, SEL, NSUInteger, BOOL))g_origLayerMenu)(me, @selector(showLayerActionMenu:newLayer:), n, isNew);
        }, &g_origLayerMenu);

        // Close hooks
        void (^logClose)(NSString *, id) = ^(NSString *ev, id me) {
            NSArray *st = [NSThread callStackSymbols];
            BOOL userTouch = NO;
            for (NSString *s in st) if ([s containsString:@"sendEvent:"] || [s containsString:@"UIGestureRecognizer"] || [s containsString:@"_UIApplicationHandleEvent"]) { userTouch = YES; break; }
            VSLog(@"[CLOSE] %@ guard=%d create=%d userTouch=%d caller=%@", ev, g_guardCancel, g_createInProgress, userTouch, st.count > 1 ? st[1] : @"");
        };
        VSSwizzle(@"MultiLayerWizEffectVC", @selector(cancel), ^(id me) {
            logClose(@"cancel", me);
            if (g_guardCancel && !g_createInProgress) {
                BOOL ut = NO; for (NSString *s in [NSThread callStackSymbols]) if ([s containsString:@"sendEvent:"] || [s containsString:@"UIGestureRecognizer"]) { ut = YES; break; }
                if (!ut) { VSLog(@"[Guard] CHẶN cancel"); return; }
            }
            if (g_origCancel) ((void (*)(id, SEL))g_origCancel)(me, @selector(cancel));
        }, &g_origCancel);
        VSSwizzle(@"MultiLayerWizEffectVC", @selector(cancelCreate), ^(id me) {
            logClose(@"cancelCreate", me);
            if (g_guardCancel && !g_createInProgress) {
                BOOL ut = NO; for (NSString *s in [NSThread callStackSymbols]) if ([s containsString:@"sendEvent:"] || [s containsString:@"UIGestureRecognizer"]) { ut = YES; break; }
                if (!ut) { VSLog(@"[Guard] CHẶN cancelCreate"); return; }
            }
            if (g_origCancelCreate) ((void (*)(id, SEL))g_origCancelCreate)(me, @selector(cancelCreate));
        }, &g_origCancelCreate);
        VSSwizzle(@"MultiLayerWizEffectVC", @selector(close), ^(id me) {
            logClose(@"close", me);
            if (g_guardCancel && !g_createInProgress) {
                BOOL ut = NO; for (NSString *s in [NSThread callStackSymbols]) if ([s containsString:@"sendEvent:"] || [s containsString:@"UIGestureRecognizer"]) { ut = YES; break; }
                if (!ut) { VSLog(@"[Guard] CHẶN close"); return; }
            }
            if (g_origClose) ((void (*)(id, SEL))g_origClose)(me, @selector(close));
        }, &g_origClose);
        VSSwizzle(@"MultiLayerWizEffectVC", @selector(viewDidDisappear:), ^(id me, BOOL anim) {
            logClose(@"viewDidDisappear", me);
            if (g_origViewDisappear) ((void (*)(id, SEL, BOOL))g_origViewDisappear)(me, @selector(viewDidDisappear:), anim);
        }, &g_origViewDisappear);

        VSLog(@"Hooks installed");
    });
}

static BOOL VSReplayPicked(id editor, id resp) {
    if (!editor || !resp || !g_origPicked) return NO;
    @autoreleasepool {
        @try { ((void (*)(id, SEL, id))g_origPicked)(editor, @selector(pickedWithClipPickerResponse:), resp); return YES; }
        @catch (NSException *e) { VSLog(@"Replay EXC: %@", e); return NO; }
    }
}

// ============================================================================
// UI
// ============================================================================
@interface VSPassWindow : UIWindow @end
@implementation VSPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { UIView *v = [super hitTest:p withEvent:e]; return (v == self || v == self.rootViewController.view) ? nil : v; }
@end

static UIColor *VSCyan(void) { return [UIColor colorWithRed:0.25 green:0.85 blue:0.96 alpha:1]; }
static UIColor *VSCardBG(void) { return [UIColor colorWithRed:0.03 green:0.08 blue:0.12 alpha:0.96]; }
static UIButton *VSButton(NSString *title, CGRect f) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = f; b.layer.cornerRadius = 8; b.layer.borderWidth = 1.2; b.layer.borderColor = VSCyan().CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:VSCyan() forState:UIControlStateNormal];
    [b setTitleColor:[VSCyan() colorWithAlphaComponent:0.35] forState:UIControlStateDisabled];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    return b;
}

@interface VSQRPreviewVC : UIViewController
@property (nonatomic, strong) UIImage *image;
@end
@implementation VSQRPreviewVC
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.9];
    UIImageView *iv = [[UIImageView alloc] initWithImage:self.image];
    iv.contentMode = UIViewContentModeScaleAspectFit; iv.layer.cornerRadius = 14; iv.clipsToBounds = YES;
    iv.frame = CGRectInset(self.view.bounds, 24, 110);
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:iv];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 56, self.view.bounds.size.width, 32)];
    t.text = @"Code gần nhất"; t.textColor = UIColor.whiteColor; t.textAlignment = NSTextAlignmentCenter;
    t.font = [UIFont boldSystemFontOfSize:18]; t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:t];
    CGFloat w = (self.view.bounds.size.width - 48) / 2.0;
    NSArray *ts = @[@"Đóng", @"Chia sẻ"];
    for (NSUInteger i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(24 + i * (w + 12), self.view.bounds.size.height - 84, w - 6, 44);
        b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
        [b setTitle:ts[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:16]; b.tag = i;
        [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }
}
- (void)tap:(UIButton *)b {
    if (b.tag == 0) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[self.image] applicationActivities:nil];
    a.popoverPresentationController.sourceView = b; [self presentViewController:a animated:YES completion:nil];
}
@end

@interface VSQRProxy : NSObject
@property (nonatomic, copy) void (^onCode)(id preset, id code);
@end
@implementation VSQRProxy
- (NSString *)qrLabel { return @"Multi-Layer"; }
- (NSString *)qrSetupLabel { return @""; }
- (NSString *)codePrefix { return @"n"; }
- (BOOL)validCode:(NSString *)c { return [c isKindOfClass:[NSString class]] && ([c hasPrefix:@"m"] || [c hasPrefix:@"n"]); }
- (void)importedData:(id)d code:(id)c { void (^b)(id,id) = self.onCode; if (b) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { b(d, c); } }); }
- (id)dataToShare { return nil; }
- (void)setActivityiPadPopup:(id)p {}
- (id)qrImage { return nil; } - (id)qrIcon { return nil; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
    return [super methodSignatureForSelector:s] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSUInteger len = inv.methodSignature.methodReturnLength;
    if (len == 0) return;
    char buf[32] = {0};
    if (len <= sizeof(buf)) [inv setReturnValue:buf];
}
@end

// ============================================================================
// VSTOOL
// ============================================================================
@interface VSRootVC : UIViewController @end

@interface VSTool : NSObject
@property (nonatomic, strong) VSPassWindow *window;
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UILabel *hud;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) VSQRProxy *qrProxy;
@property (nonatomic, strong) NSMutableArray *msPresets, *msCodes;
@property (nonatomic, assign) NSUInteger msStart, msCount, msOrigLast, msRunId;
@property (nonatomic, assign) NSInteger msCapturing;
@property (nonatomic, strong) UIView *msCard;
@property (nonatomic, copy) NSString *busyName;
@property (nonatomic, strong) id savedQRDel;
@property (nonatomic, assign) BOOL savedQRDelValid;
@property (nonatomic, copy) void (^barOK)(void);
@property (nonatomic, copy) void (^barCancel)(void);
+ (instancetype)shared;
- (void)install;
- (void)clampFab;
- (void)exportLog;
@end

@implementation VSRootVC
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [VSTool.shared clampFab]; }
@end

@implementation VSTool

+ (instancetype)shared {
    static VSTool *t; static dispatch_once_t o;
    dispatch_once(&o, ^{ t = [VSTool new]; });
    return t;
}

- (void)install {
    if (self.window) return;
    static BOOL delayed = NO;
    if (!delayed) { delayed = YES; VSAfter(2500, ^{ [self install]; }); return; }

    CGRect b = UIScreen.mainScreen.bounds;
    VSPassWindow *w = nil;
    if (@available(iOS 13.0, *)) for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) { w = [[VSPassWindow alloc] initWithWindowScene:(UIWindowScene *)s]; break; }
    if (!w) w = [[VSPassWindow alloc] initWithFrame:b];
    w.frame = b; w.windowLevel = UIWindowLevelAlert + 100; w.backgroundColor = UIColor.clearColor;

    VSRootVC *root = [VSRootVC new]; root.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = root;

    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(b.size.width - 64, b.size.height * 0.35, 48, 48);
    fab.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.13 alpha:0.85];
    fab.layer.cornerRadius = 24; fab.layer.borderWidth = 1.5; fab.layer.borderColor = VSCyan().CGColor;
    [fab setTitle:@"VS" forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [fab setTitleColor:VSCyan() forState:UIControlStateNormal];
    [fab addTarget:self action:@selector(fabTap) forControlEvents:UIControlEventTouchUpInside];
    [fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fabPan:)]];
    [root.view addSubview:fab];

    UILabel *hud = [UILabel new];
    hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    hud.textColor = UIColor.whiteColor; hud.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    hud.textAlignment = NSTextAlignmentCenter; hud.numberOfLines = 2;
    hud.layer.cornerRadius = 10; hud.clipsToBounds = YES; hud.hidden = YES;
    [root.view addSubview:hud];

    self.window = w; self.fab = fab; self.hud = hud;
    self.msCapturing = -1;
    g_toolWindow = w;
    w.hidden = NO;
    VSInstallHooks();
    VSLog(@"=== Tool installed ===");
}

- (void)clampFab {
    UIView *v = self.window.rootViewController.view; UIEdgeInsets in = v.safeAreaInsets;
    CGFloat hw = self.fab.bounds.size.width / 2; CGPoint c = self.fab.center;
    c.x = MIN(MAX(c.x, hw + 4), v.bounds.size.width - hw - 4);
    c.y = MIN(MAX(c.y, in.top + hw + 4), v.bounds.size.height - in.bottom - hw - 4);
    self.fab.center = c;
}
- (void)fabPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.fab.superview];
    self.fab.center = CGPointMake(self.fab.center.x + t.x, self.fab.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.fab.superview];
    if (g.state == UIGestureRecognizerStateEnded) [self clampFab];
}
- (UIViewController *)presenter {
    UIViewController *p = self.window.rootViewController;
    while (p.presentedViewController) p = p.presentedViewController;
    return p;
}
- (void)status:(NSString *)t {
    UIView *r = self.window.rootViewController.view;
    self.hud.text = t; CGFloat w = MIN(r.bounds.size.width - 32, 440);
    self.hud.frame = CGRectMake((r.bounds.size.width - w) / 2, r.safeAreaInsets.top + 8, w, 40);
    self.hud.hidden = (t.length == 0);
}
- (void)alert:(NSString *)m title:(NSString *)t {
    [self status:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t ?: @"VideoStarTool" message:m preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self presenter] presentViewController:a animated:YES completion:nil];
}
- (void)hideBar { [self.bar removeFromSuperview]; self.bar = nil; }

- (UIView *)card:(CGRect)f title:(NSString *)t sub:(NSString *)s {
    UIView *c = [[UIView alloc] initWithFrame:f];
    c.backgroundColor = VSCardBG(); c.layer.cornerRadius = 14; c.layer.borderWidth = 1.2; c.layer.borderColor = VSCyan().CGColor;
    c.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, f.size.width - 32, 24)];
    h.text = t; h.textColor = VSCyan(); h.font = [UIFont boldSystemFontOfSize:17]; h.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *ss = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, f.size.width - 32, 36)];
    ss.text = s; ss.numberOfLines = 0; ss.textColor = [UIColor colorWithWhite:0.86 alpha:1]; ss.font = [UIFont systemFontOfSize:13]; ss.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [c addSubview:h]; [c addSubview:ss];
    return c;
}
- (void)showBar:(NSString *)t msg:(NSString *)m ok:(NSString *)okTitle onOK:(void (^)(void))onOK onCancel:(void (^)(void))onCancel {
    [self hideBar];
    UIView *r = self.window.rootViewController.view;
    CGFloat w = MIN(r.bounds.size.width - 24, 460), h = 132;
    UIView *bar = [self card:CGRectMake((r.bounds.size.width - w) / 2, r.bounds.size.height - r.safeAreaInsets.bottom - h - 70, w, h) title:t sub:m];
    self.barOK = onOK; self.barCancel = onCancel;
    CGFloat bw = (w - 32 - 12) / 2;
    UIButton *cb = VSButton(@"Hủy", CGRectMake(16, h - 52, bw, 38));
    cb.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1].CGColor;
    [cb setTitleColor:[UIColor colorWithWhite:0.78 alpha:1] forState:UIControlStateNormal];
    UIButton *ok = VSButton(okTitle, CGRectMake(16 + bw + 12, h - 52, bw, 38));
    [cb addTarget:self action:@selector(barCancelTap) forControlEvents:UIControlEventTouchUpInside];
    [ok addTarget:self action:@selector(barOKTap) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:cb]; [bar addSubview:ok];
    [r addSubview:bar]; self.bar = bar;
}
- (void)barOKTap { void (^c)(void) = self.barOK; self.barOK = nil; self.barCancel = nil; [self hideBar]; if (c) c(); }
- (void)barCancelTap { void (^c)(void) = self.barCancel; self.barOK = nil; self.barCancel = nil; [self hideBar]; if (c) c(); }

- (void)fabTap {
    if (self.busyName) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Đang chạy" message:self.busyName preferredStyle:UIAlertControllerStyleAlert];
        if (self.msCard && self.msCard.hidden)
            [a addAction:[UIAlertAction actionWithTitle:@"Mở lại bảng QR" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self restoreCodePanel]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Dừng" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [self stop]; [self alert:@"Đã dừng" title:@"Dừng"]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Tiếp tục" style:UIAlertActionStyleCancel handler:nil]];
        [[self presenter] presentViewController:a animated:YES completion:nil];
        return;
    }
    UIAlertController *m = [UIAlertController alertControllerWithTitle:@"VideoStarTool" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [m addAction:[UIAlertAction actionWithTitle:@"1. Auto nhập ảnh vào các lớp" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self runF1]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"2. Xem code gần nhất" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self runF2]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"3. Auto chia beat" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self runF3]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"4. Auto code + ảnh vào phân cảnh" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self runF4]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"📋 Xuất log (gửi dev)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self exportLog]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    m.popoverPresentationController.sourceView = self.fab;
    m.popoverPresentationController.sourceRect = self.fab.bounds;
    [[self presenter] presentViewController:m animated:YES completion:nil];
}

- (void)exportLog {
    NSString *path = VSLogFilePath();
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d.length) { [self alert:@"Chưa có log" title:@"Không có log"]; return; }
    NSString *txt = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Log VideoStarTool" message:[NSString stringWithFormat:@"%lu bytes", (unsigned long)d.length] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [UIPasteboard.generalPasteboard setString:txt]; [self alert:@"Đã copy log" title:@"OK"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Chia sẻ file" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        avc.popoverPresentationController.sourceView = self.fab;
        [[self presenter] presentViewController:avc animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Xóa log" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [[self presenter] presentViewController:a animated:YES completion:nil];
}

- (NSUInteger)begin:(NSString *)name status:(NSString *)s {
    g_runId++; g_autoConfirmPopups = NO; g_suppressLayerActionMenu = NO; g_guardCancel = NO; g_createInProgress = NO;
    self.busyName = name; self.fab.alpha = 0.55; [self status:s];
    VSLog(@"=== BEGIN %@ (run=%lu) ===", name, (unsigned long)g_runId);
    return g_runId;
}
- (void)restoreQRDel {
    if (!self.savedQRDelValid) return;
    id qr = [NSClassFromString(@"QRCodeManager") respondsToSelector:@selector(sharedInstance)] ? [NSClassFromString(@"QRCodeManager") sharedInstance] : nil;
    if (qr) VSSetQRDelegate(qr, self.savedQRDel);
    self.savedQRDel = nil; self.savedQRDelValid = NO;
}
- (void)stop {
    g_runId++; g_autoConfirmPopups = NO; g_suppressLayerActionMenu = NO; g_guardCancel = NO; g_createInProgress = NO;
    g_pickedHandler = nil; [self restoreQRDel]; [self hideBar];
    [self.msCard removeFromSuperview]; self.msCard = nil; self.msCapturing = -1; self.qrProxy = nil;
    self.busyName = nil; self.fab.alpha = 1; [self status:nil];
    VSLog(@"=== STOP ===");
}
- (void)end:(NSString *)msg {
    VSLog(@"=== END: %@ ===", msg);
    [self stop];
    if (msg.length) [self alert:msg title:@"VideoStarTool"];
}

// ============================================================================
// FEATURE 1
// ============================================================================
- (void)requestPicker:(id)editor runId:(NSUInteger)rid completion:(void (^)(id resp, VSSnap *first))done {
    if (!g_origPicked) { done(nil, nil); return; }
    g_pickedHandler = ^(id me, id resp) {
        if (rid != g_runId || me != editor) return;
        g_pickedHandler = nil;
        __block VSSnap *snap = nil;
        VSPoll(rid, 120, 100, ^BOOL{
            id eng = [me getMultiLayerEngine]; NSInteger n = [me lastSelectedLayerNum];
            if (!eng || n < 0) return NO;
            snap = VSInspect(eng, (NSUInteger)n);
            return snap && VSKindReplaceable(snap.mediaKind);
        }, ^(BOOL ok) { done(resp, snap); });
    };
    VSPoll(rid, 100, 60, ^BOOL{ return [editor isViewLoaded] && [[editor view] window] && [editor getMultiLayerEngine]; }, ^(BOOL ok) {
        if (!ok) { g_pickedHandler = nil; done(nil, nil); return; }
        void (^pick)(void) = ^{ VSAfter(150, ^{
            if (rid != g_runId) return;
            if (!VSTry(^{ [editor pickNewContent]; })) { g_pickedHandler = nil; done(nil, nil); }
        }); };
        VSSnap *first = nil;
        @try { first = VSFirstReplaceable([editor getMultiLayerEngine]); } @catch (...) {}
        if (!first) { pick(); return; }
        VSSelectLayer(editor, first.layerIndex, rid, ^(BOOL sel) {
            if (!sel) { g_pickedHandler = nil; done(nil, nil); return; }
            pick();
        });
    });
}

- (void)applyResponse:(id)resp toEditor:(id)editor skip:(NSInteger)skip runId:(NSUInteger)rid completion:(void (^)(NSUInteger ok, NSUInteger total, NSUInteger fail, BOOL blocked))done {
    __block NSUInteger idle = 0;
    VSPoll(rid, 100, 100, ^BOOL{
        VSDismissLayerMenus(editor);
        idle = VSEditorBusy(editor) ? 0 : idle + 1;
        return idle >= 2;
    }, ^(BOOL ready) {
        if (rid != g_runId) return;
        id engine = nil; @try { engine = [editor getMultiLayerEngine]; } @catch (...) {}
        if (!engine) { done(0, 0, 0, NO); return; }

        NSMutableArray<NSNumber *> *targets = [NSMutableArray array];
        for (VSSnap *s in VSScan(engine)) {
            if (!VSKindReplaceable(s.mediaKind)) continue;
            if ((NSInteger)s.layerIndex == skip) continue;
            [targets addObject:@(s.layerIndex)];
        }
        NSUInteger total = targets.count;
        if (total == 0) { done(0, 0, 0, NO); return; }

        __block NSUInteger idx = 0, ok = 0, fail = 0;
        __block BOOL blocked = NO;
        __block void (^step)(void) = nil;

        void (^finish)(void) = ^{
            step = nil;
            VSDismissLayerMenus(editor);
            if (ok > 0) VSRefresh(editor, engine);
            NSUInteger notReached = idx < total ? (total - idx) : 0;
            done(ok, total, fail + notReached, blocked);
        };
        void (^next)(void) = ^{ VSAfter(30, ^{ if (step) step(); }); };

        step = ^{
            if (rid != g_runId) { step = nil; return; }
            if (idx >= total) { finish(); return; }
            if (!VSEditorAlive(editor)) { VSLog(@"[apply] editor DEAD at idx=%lu/%lu", (unsigned long)idx, (unsigned long)total); finish(); return; }
            VSDismissLayerMenus(editor);

            NSUInteger waitTries = g_autoConfirmPopups ? 150 : 300;
            VSPoll(rid, 100, waitTries, ^BOOL{
                if (VSResolvePopups(editor) == VSPopupBlockedPurchase) { blocked = YES; return YES; }
                return !VSHasPopup(editor);
            }, ^(BOOL clear) {
                if (rid != g_runId) return;
                if (blocked) { VSLog(@"[apply] BLOCKED PURCHASE"); finish(); return; }
                if (!clear) {
                    NSArray *ps = VSVisiblePopups(editor);
                    VSLog(@"[apply] POPUP TIMEOUT — %lu popup(s) remaining", (unsigned long)ps.count);
                    for (id p in ps) VSLog(@"[apply]   %@", [VSPopupTitles(p, NULL) componentsJoinedByString:@" | "]);
                    finish(); return;
                }
                NSUInteger n = targets[idx++].unsignedIntegerValue;
                [self status:[NSString stringWithFormat:@"Đang thay: L%lu (%lu/%lu)", (unsigned long)(n + 1), (unsigned long)idx, (unsigned long)total]];
                VSLog(@"[apply] Layer %lu/%lu idx=%lu", (unsigned long)n, (unsigned long)total, (unsigned long)idx);

                VSSelectLayer(editor, n, rid, ^(BOOL sel) {
                    if (rid != g_runId) return;
                    if (!sel) { VSLog(@"[apply] L%lu select FAIL", (unsigned long)n); fail++; next(); return; }
                    VSAfter(40, ^{
                        if (rid != g_runId) return;
                        VSSnap *before = VSInspect(engine, n);
                        if (!before || !VSKindReplaceable(before.mediaKind)) { next(); return; }
                        NSString *beforeSig = before.signature ?: @"";
                        if (!VSReplayPicked(editor, resp)) { fail++; next(); return; }

                        __block BOOL confirmed = NO, blocked2 = NO, changedSeen = NO;
                        __block CFAbsoluteTime dl = CFAbsoluteTimeGetCurrent() + 8;
                        __block CFAbsoluteTime idleDl = 0;
                        NSUInteger tries = g_autoConfirmPopups ? 500 : 2000;
                        VSPoll(rid, 80, tries, ^BOOL{
                            VSDismissLayerMenus(editor);
                            if (!VSEditorAlive(editor)) return YES;
                            if (VSResolvePopups(editor) == VSPopupBlockedPurchase) { blocked2 = YES; return YES; }
                            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                            if (VSHasPopup(editor)) { dl = MAX(dl, now + 2.5); if (changedSeen) idleDl = MAX(idleDl, now + 4); return NO; }
                            if (!changedSeen) {
                                VSSnap *cur = VSInspect(engine, n);
                                if (cur && ![cur.signature ?: @"" isEqualToString:beforeSig]) { changedSeen = YES; confirmed = YES; idleDl = now + 6; }
                                else return now > dl;
                            }
                            if (VSEditorBusy(editor) && now < idleDl) return NO;
                            return YES;
                        }, ^(BOOL r) {
                            if (rid != g_runId) return;
                            if (blocked2) { blocked = YES; finish(); return; }
                            if (!VSEditorAlive(editor)) { fail++; finish(); return; }
                            if (confirmed) ok++; else fail++;
                            VSLog(@"[apply] L%lu: %@", (unsigned long)n, confirmed ? @"✅" : @"⚠️ timeout");
                            next();
                        });
                    });
                });
            });
        };
        VSAfter(200, ^{ if (step) step(); });
    });
}

- (void)runF1 {
    id editor = VSFindVC(@"MultiLayerWizEffectVC");
    if (!editor) { [self alert:@"Vào Nhiều lớp trước" title:@"Chưa ở Nhiều lớp"]; return; }
    id engine = nil; @try { engine = [editor getMultiLayerEngine]; } @catch (...) {}
    if (!VSFirstReplaceable(engine)) { [self alert:@"Không có lớp ảnh/video" title:@"Không có lớp"]; return; }

    NSUInteger rid = [self begin:@"Auto nhập ảnh" status:@"Chọn media…"];
    g_suppressLayerActionMenu = YES;
    g_guardCancel = YES;
    [self requestPicker:editor runId:rid completion:^(id resp, VSSnap *first) {
        if (rid != g_runId) return;
        if (!resp) { [self end:@"Không nhận được media"]; return; }
        if (!first || !VSKindReplaceable(first.mediaKind)) { [self end:@"Lớp đầu không phải ảnh/video"]; return; }
        [self applyResponse:resp toEditor:editor skip:(NSInteger)first.layerIndex runId:rid completion:^(NSUInteger ok, NSUInteger total, NSUInteger fail, BOOL blocked) {
            NSString *msg = total == 0 ? @"Xong lớp đầu, không còn lớp khác" :
                [NSString stringWithFormat:@"Xong lớp đầu + %lu/%lu lớp còn lại%@", (unsigned long)ok, (unsigned long)total,
                 fail ? [NSString stringWithFormat:@" (%lu lớp lỗi)", (unsigned long)fail] : @""];
            [self end:blocked ? [msg stringByAppendingString:@"\nDừng vì popup mua Pro"] : msg];
        }];
    }];
}

// ============================================================================
// FEATURE 2
// ============================================================================
- (void)runF2 {
    UIImage *img = VSLoadQR();
    if (!img) { [self alert:@"Chưa có QR nào" title:@"Chưa có"]; return; }
    if (!VSDecodeQR(img)) { [self alert:@"QR không hợp lệ" title:@"Lỗi"]; return; }
    VSQRPreviewVC *vc = [VSQRPreviewVC new]; vc.image = img;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [[self presenter] presentViewController:vc animated:YES completion:nil];
}

// ============================================================================
// FEATURE 3
// ============================================================================
- (void)runF3 {
    id rvc = VSFindVC(@"VideoReviewEditVC");
    if (!rvc) { [self alert:@"Vào màn hình Review" title:@"Sai vị trí"]; return; }
    NSUInteger rid = [self begin:@"Auto chia beat" status:@"Chuẩn bị…"];

    id (^fetchSV)(void) = ^id{ return VSValue(rvc, @"splitView"); };
    BOOL (^visible)(void) = ^BOOL{
        id sv = fetchSV(); if (!sv) return NO;
        UIView *v = [sv isKindOfClass:[UIView class]] ? sv : VSValue(sv, @"splitPanel");
        return [v isKindOfClass:[UIView class]] && v.window != nil;
    };
    if (!visible()) { if (!VSTry(^{ [rvc showSplitScene]; })) { [self end:@"Không mở bảng chia"]; return; } }
    VSPoll(rid, 100, 35, ^BOOL{ return visible(); }, ^(BOOL ok) {
        if (rid != g_runId) return;
        id sv = fetchSV(); if (!ok || !sv) { [self end:@"Không có MultiSplitView"]; return; }
        [self beatSplit:rvc splitView:sv runId:rid];
    });
}

- (void)beatSplit:(id)rvc splitView:(id)sv runId:(NSUInteger)rid {
    __block NSString *err = nil;
    VSTry(^{
        id<ProjectInterface> p = [rvc project]; NSUInteger s = [rvc sceneIndex]; NSUInteger cc = [p clipCountForSceneIndex:s];
        if (![rvc isEnoughStorageAvailableForSplit]) err = @"Bộ nhớ không đủ";
        else if (![p sceneHasAtLeastOneClipWithSceneIndex:s] || cc == 0) err = @"Không có clip";
    });
    if (err) { [self end:err]; return; }

    id<ProjectInterface> p = [rvc project]; if (!p) { [self end:@"Lỗi project"]; return; }
    NSUInteger before = [p sceneCount];
    if (!VSTry(^{ if (![sv beatModeOn]) [sv toggleBeatMode]; [sv gotoTime:kCMTimeZero]; })) { [self end:@"Không bật Beat"]; return; }

    __block NSUInteger guard = 0, count = 0;
    __block CMTime last = kCMTimeInvalid;
    __block void (^step)(void) = nil;
    void (^finish)(void) = ^{
        step = nil;
        if (rid != g_runId) return;
        if (count == 0 && VSCount(VSValue(sv, @"splitTimes")) == 0) { [self end:@"Không có beat"]; return; }
        if (!VSTry(^{ [sv doSplit]; })) { [self end:@"Lỗi chia"]; return; }
        VSPoll(rid, 120, 150, ^BOOL{ return [p sceneCount] > before; }, ^(BOOL ok) {
            [self end:ok ? [NSString stringWithFormat:@"Xong +%lu scene", (unsigned long)([p sceneCount] - before)] : @"Chưa xong"];
        });
    };
    step = ^{
        if (rid != g_runId) { step = nil; return; }
        if (++guard >= 2048) { finish(); return; }
        __block BOOL hasNext = NO; __block CMTime from = kCMTimeInvalid;
        if (!VSTry(^{ hasNext = [sv hasNextBeat]; if (hasNext) { from = VSTime(sv); [sv jumpToNextBeat]; } })) { finish(); return; }
        if (!hasNext) { finish(); return; }
        CMTime f = from;
        VSPoll(rid, 16, 60, ^BOOL{ CMTime c = VSTime(sv); return CMTIME_IS_VALID(c) && (CMTIME_IS_INVALID(f) || CMTimeCompare(c, f) > 0); }, ^(BOOL moved) {
            if (rid != g_runId) { step = nil; return; }
            CMTime c = VSTime(sv);
            if (!moved || (CMTIME_IS_VALID(last) && CMTimeCompare(c, last) <= 0)) { finish(); return; }
            last = c;
            if (!VSTry(^{ [sv setSplitPoint]; })) { finish(); return; }
            count++; [self status:[NSString stringWithFormat:@"%lu điểm", (unsigned long)count]];
            VSAfter(20, ^{ if (step) step(); });
        });
    };
    VSAfter(250, ^{ if (step) step(); });
}

// ============================================================================
// FEATURE 4
// ============================================================================
- (void)runF4 {
    id rvc = VSFindVC(@"VideoReviewEditVC");
    if (!rvc) { [self alert:@"Vào màn hình phân cảnh" title:@"Sai vị trí"]; return; }
    NSUInteger rid = [self begin:@"Auto code + ảnh" status:nil];
    g_suppressLayerActionMenu = YES;
    g_guardCancel = YES;
    NSUInteger orig = 0; @try { orig = [rvc lastViewedSceneIndex]; } @catch (...) {}
    if (!VSTry(^{ [rvc showMergeScenes]; })) { [self end:@"Không mở Hợp nhất"]; return; }
    [self showBar:@"Chọn phân cảnh" msg:@"Chọn đầu/cuối rồi Bắt đầu" ok:@"Bắt đầu" onOK:^{ [self parseRange:rvc rid:rid orig:orig]; } onCancel:^{ VSTry(^{ [rvc closeMergePanel]; }); [self stop]; }];
}

- (void)parseRange:(id)rvc rid:(NSUInteger)rid orig:(NSUInteger)orig {
    if (rid != g_runId) return;
    id<ProjectInterface> p = nil; @try { p = [rvc project]; } @catch (...) {}
    NSInteger total = p ? (NSInteger)[p sceneCount] : 0;
    id so = VSValue(rvc, @"startScene"), lo = VSValue(rvc, @"lastScene");
    NSInteger s = [so respondsToSelector:@selector(integerValue)] ? [so integerValue] : -1;
    NSInteger l = [lo respondsToSelector:@selector(integerValue)] ? [lo integerValue] : -1;
    VSTry(^{ [rvc closeMergePanel]; });
    if (!p || s < 0 || l < s || l >= total) { [self end:@"Phạm vi không hợp lệ"]; return; }
    self.msStart = s; self.msCount = l - s + 1; self.msOrigLast = orig; self.msRunId = rid; self.msCapturing = -1;
    self.msPresets = [NSMutableArray array]; self.msCodes = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.msCount; i++) { [self.msPresets addObject:[NSNull null]]; [self.msCodes addObject:[NSNull null]]; }
    [self renderCodePanel];
}

- (NSUInteger)gotCount { NSUInteger c = 0; for (id x in self.msCodes) if (x != [NSNull null]) c++; return c; }

- (void)renderCodePanel {
    if (self.msRunId != g_runId) return;
    [self.msCard removeFromSuperview];
    UIView *c = self.window.rootViewController.view; UIEdgeInsets in = c.safeAreaInsets;
    CGFloat w = MIN(c.bounds.size.width - 24, 460), top = in.top + 28, h = c.bounds.size.height - top - in.bottom - 84;
    NSUInteger got = [self gotCount];
    UIView *card = [self card:CGRectMake((c.bounds.size.width - w) / 2, top, w, h) title:@"Nhập QR" sub:[NSString stringWithFormat:@"%lu/%lu", (unsigned long)got, (unsigned long)self.msCount]];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 70, w - 24, h - 70 - 66)];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    for (NSUInteger i = 0; i < self.msCount; i++) {
        BOOL has = self.msCodes[i] != [NSNull null];
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, i * 68, sv.bounds.size.width, 60)];
        row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06]; row.layer.cornerRadius = 10;
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 9, row.bounds.size.width - 140, 20)];
        t.text = [NSString stringWithFormat:@"Scene %lu", (unsigned long)(self.msStart + i + 1)];
        t.textColor = UIColor.whiteColor; t.font = [UIFont boldSystemFontOfSize:15];
        UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(14, 33, row.bounds.size.width - 140, 16)];
        s.text = has ? @"Đã nhận" : @"Chưa";
        s.textColor = has ? VSCyan() : [UIColor colorWithWhite:0.6 alpha:1]; s.font = [UIFont systemFontOfSize:11];
        UIButton *b = VSButton(has ? @"Đổi" : @"Nhập", CGRectMake(row.bounds.size.width - 112, 12, 100, 36));
        b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; b.tag = i;
        [b addTarget:self action:@selector(codeTap:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:t]; [row addSubview:s]; [row addSubview:b]; [sv addSubview:row];
    }
    sv.contentSize = CGSizeMake(sv.bounds.size.width, self.msCount * 68);
    [card addSubview:sv];
    CGFloat bw = (w - 32 - 12) / 2;
    UIButton *cb = VSButton(@"Hủy", CGRectMake(16, h - 52, bw, 38));
    cb.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1].CGColor;
    [cb setTitleColor:[UIColor colorWithWhite:0.78 alpha:1] forState:UIControlStateNormal];
    cb.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [cb addTarget:self action:@selector(msCancel) forControlEvents:UIControlEventTouchUpInside];
    UIButton *nx = VSButton(@"Chọn media", CGRectMake(16 + bw + 12, h - 52, bw, 38));
    nx.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    nx.enabled = (got == self.msCount);
    [nx addTarget:self action:@selector(msProceed) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cb]; [card addSubview:nx];
    [c addSubview:card]; self.msCard = card;
}

- (void)msCancel { [self stop]; }
- (void)restoreCodePanel {
    g_pickedHandler = nil; [self restoreQRDel]; self.qrProxy = nil; self.msCapturing = -1; [self status:nil];
    if (self.msCard && self.msCount > 0) [self renderCodePanel];
}
- (void)codeTap:(UIButton *)b {
    NSUInteger off = b.tag;
    id qr = [NSClassFromString(@"QRCodeManager") respondsToSelector:@selector(sharedInstance)] ? [NSClassFromString(@"QRCodeManager") sharedInstance] : nil;
    if (!qr || ![qr respondsToSelector:@selector(startQRImport)]) { [self alert:@"Không có QRCodeManager" title:@"Lỗi"]; return; }
    VSQRProxy *proxy = [VSQRProxy new]; NSUInteger rid = self.msRunId;
    proxy.onCode = ^(id preset, id code) {
        if (rid != g_runId || self.msCapturing != (NSInteger)off) return;
        [self restoreQRDel]; self.qrProxy = nil; self.msCapturing = -1;
        if (!preset || ![code isKindOfClass:[NSString class]] || ![(NSString *)code length]) {
            [self renderCodePanel]; [self alert:@"QR không hợp lệ" title:@"Lỗi"]; return;
        }
        self.msPresets[off] = preset; self.msCodes[off] = code; [self renderCodePanel];
    };
    self.qrProxy = proxy; self.msCapturing = (NSInteger)off;
    if (!self.savedQRDelValid) { self.savedQRDel = VSValue(qr, @"delegate"); self.savedQRDelValid = YES; }
    @try { VSSetQRDelegate(qr, proxy); self.msCard.hidden = YES; [qr startQRImport]; }
    @catch (NSException *e) { [self restoreCodePanel]; [self alert:[NSString stringWithFormat:@"Lỗi QR: %@", e.reason ?: e.name] title:@"Lỗi"]; }
}

- (void)msProceed {
    NSUInteger rid = self.msRunId;
    if (rid != g_runId || [self gotCount] != self.msCount) return;
    g_autoConfirmPopups = YES;
    self.msCard.hidden = YES;
    [self status:@"Mở Nhiều lớp…"];
    id rvc = VSFindVC(@"VideoReviewEditVC");
    [self openEditor:self.msStart rvc:rvc rid:rid done:^(id editor) {
        if (rid != g_runId) return;
        if (!editor) { [self end:@"Không mở Nhiều lớp"]; return; }
        [self status:@"Chọn media chung…"];
        [self requestPicker:editor runId:rid completion:^(id resp, VSSnap *first) {
            if (rid != gRun_id_safe()) return;
            if (!resp) { [self end:@"Không có media"]; return; }
            if (!first || !VSKindReplaceable(first.mediaKind)) { [self end:@"Lớp đầu không phải ảnh/video"]; return; }
            [self.msCard removeFromSuperview]; self.msCard = nil;
            [self status:nil];
            [self showProgress];
            [self runBatch:resp rid:rid];
        }];
    }];
}

// Helper tránh lỗi typo
static inline NSUInteger gRun_id_safe(void) { return g_runId; }

- (void)showProgress {
    UIView *c = self.window.rootViewController.view;
    CGFloat w = MIN(c.bounds.size.width - 24, 460), h = 132;
    UIView *card = [self card:CGRectMake((c.bounds.size.width - w) / 2, c.bounds.size.height - c.safeAreaInsets.bottom - h - 70, w, h) title:@"Đang áp dụng" sub:@"Xử lý từng scene…"];
    UIButton *b = VSButton(@"Đang chạy…", CGRectMake(w - 146, h - 52, 130, 38)); b.enabled = NO;
    [card addSubview:b]; [c addSubview:card];
    self.msCard = card;
}

- (void)runBatch:(id)resp rid:(NSUInteger)rid {
    NSUInteger start = self.msStart, total = self.msCount, orig = self.msOrigLast;
    NSArray *presets = [self.msPresets copy], *codes = [self.msCodes copy];
    __block NSUInteger offset = 0, ok = 0;
    __block void (^step)(void) = nil;
    void (^finish)(NSString *) = ^(NSString *err) {
        step = nil;
        id rvc = VSFindVC(@"VideoReviewEditVC");
        VSTry(^{ [rvc setLastViewedSceneIndex:orig]; });
        [self end:err ? [err stringByAppendingFormat:@"\nXong %lu/%lu", (unsigned long)ok, (unsigned long)total] : [NSString stringWithFormat:@"Xong %lu/%lu", (unsigned long)ok, (unsigned long)total]];
    };
    step = ^{
        if (rid != g_runId) { step = nil; return; }
        if (offset >= total) { finish(nil); return; }
        NSUInteger o = offset++, sc = start + o;
        [self status:[NSString stringWithFormat:@"Scene %lu/%lu: mở", (unsigned long)(sc + 1), (unsigned long)total]];
        id rvc = VSFindVC(@"VideoReviewEditVC");
        [self openEditor:sc rvc:rvc rid:rid done:^(id editor) {
            if (rid != g_runId) { step = nil; return; }
            if (!editor) { finish([NSString stringWithFormat:@"Không mở scene %lu", (unsigned long)(sc + 1)]); return; }
            [self status:[NSString stringWithFormat:@"Scene %lu: code", (unsigned long)(sc + 1)]];
            [self importPreset:presets[o] code:codes[o] editor:editor rid:rid done:^(NSString *e1) {
                if (rid != g_runId) { step = nil; return; }
                if (e1) { finish([NSString stringWithFormat:@"Scene %lu: %@", (unsigned long)(sc + 1), e1]); return; }
                VSAfter(500, ^{
                    if (rid != g_runId) { step = nil; return; }
                    [self status:[NSString stringWithFormat:@"Scene %lu: media", (unsigned long)(sc + 1)]];
                    [self applyResponse:resp toEditor:editor skip:-1 runId:rid completion:^(NSUInteger c, NSUInteger t, NSUInteger f, BOOL blocked) {
                        if (rid != g_runId) { step = nil; return; }
                        if (blocked) { finish([NSString stringWithFormat:@"Scene %lu: Pro", (unsigned long)(sc + 1)]); return; }
                        if (!VSEditorAlive(editor)) { finish([NSString stringWithFormat:@"Scene %lu: editor đóng trước Tạo", (unsigned long)(sc + 1)]); return; }
                        if (f > 0) { finish([NSString stringWithFormat:@"Scene %lu: %lu lớp chưa thay — chưa Tạo", (unsigned long)(sc + 1), (unsigned long)f]); return; }
                        [self waitSettled:editor rid:rid done:^(NSString *e2) {
                            if (rid != g_runId) { step = nil; return; }
                            if (e2) { finish([NSString stringWithFormat:@"Scene %lu: %@", (unsigned long)(sc + 1), e2]); return; }
                            ok++;
                            VSPoll(rid, 100, 120, ^BOOL{ return VSFindVC(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                                if (rid != g_runId) { step = nil; return; }
                                if (!back) { finish(@"Không quay lại"); return; }
                                VSAfter(300, ^{ if (step) step(); });
                            });
                        }];
                    }];
                });
            }];
        }];
    };
    step();
}

- (void)openEditor:(NSUInteger)scene rvc:(id)rvc rid:(NSUInteger)rid done:(void (^)(id))done {
    id (^cur)(void) = ^id{
        id ed = VSFindVC(@"MultiLayerWizEffectVC");
        if (!ed || ![ed getMultiLayerEngine]) return nil;
        id nav = [ed navigationController];
        BOOL match = YES;
        if ([nav respondsToSelector:@selector(navSceneIndex)]) match = ([nav navSceneIndex] == scene);
        return match ? ed : nil;
    };
    id e = nil; @try { e = cur(); } @catch (...) {}
    if (e) { done(e); return; }
    if (!rvc) { done(nil); return; }
    if (!VSTry(^{ [rvc setLastViewedSceneIndex:scene]; [rvc showMultiLayer]; })) { done(nil); return; }
    VSPoll(rid, 80, 100, ^BOOL{ return cur() != nil; }, ^(BOOL ok) { id x = nil; if (ok) @try { x = cur(); } @catch (...) {} done(x); });
}

- (void)importPreset:(id)preset code:(id)code editor:(id)editor rid:(NSUInteger)rid done:(void (^)(NSString *))done {
    if (![editor respondsToSelector:@selector(importedData:code:)]) { done(@"Editor không hỗ trợ"); return; }
    NSUInteger before = g_importCount;
    @try { [editor importedData:preset code:code]; } @catch (NSException *e) { done([NSString stringWithFormat:@"Lỗi: %@", e.reason ?: e.name]); return; }
    __block BOOL blocked = NO;
    VSPoll(rid, 50, 200, ^BOOL{
        VSPopupStatus s = VSResolvePopups(editor);
        if (s == VSPopupBlockedPurchase) { blocked = YES; return YES; }
        return g_importCount > before;
    }, ^(BOOL ok) {
        if (rid != g_runId) return;
        if (blocked) { done(@"Pro popup"); return; }
        if (!ok) { done(@"Timeout 10s"); return; }
        VSAfter(500, ^{
            if (rid != g_runId) return;
            id eng = [editor getMultiLayerEngine];
            __block BOOL purchase = NO;
            VSPoll(rid, 60, 60, ^BOOL{
                if (VSResolvePopups(editor) == VSPopupBlockedPurchase) { purchase = YES; return YES; }
                return !VSHasPopup(editor) && [eng numActiveLayers] > 0;
            }, ^(BOOL ready) { done(purchase ? @"Pro popup" : (ready ? nil : @"Engine chưa sẵn sàng")); });
        });
    });
}

- (void)waitSettled:(id)editor rid:(NSUInteger)rid done:(void (^)(NSString *))done {
    __block NSUInteger stable = 0; __block BOOL purchase = NO;
    VSPoll(rid, 100, 150, ^BOOL{
        if (!VSEditorAlive(editor)) return YES;
        VSDismissLayerMenus(editor);
        if (VSResolvePopups(editor) == VSPopupBlockedPurchase) { purchase = YES; return YES; }
        stable = (!VSHasPopup(editor) && !VSEditorBusy(editor)) ? stable + 1 : 0;
        return stable >= 8;
    }, ^(BOOL ok) {
        if (rid != g_runId) return;
        if (purchase) { done(@"Pro popup"); return; }
        if (!VSEditorAlive(editor)) { done(@"Editor đóng"); return; }
        if (!ok) { done(@"Editor chưa ổn định"); return; }
        [self doCreate:editor rid:rid done:done];
    });
}

- (void)doCreate:(id)editor rid:(NSUInteger)rid done:(void (^)(NSString *))done {
    UIBarButtonItem *btn = VSFindCreateButton(editor);
    if (!btn) { done(@"Không có nút Tạo"); return; }
    VSLog(@"[Create] '%@' action='%@'", btn.title ?: @"?", btn.action ? NSStringFromSelector(btn.action) : @"?");
    g_createInProgress = YES;
    __block BOOL fired = NO;
    if (btn.action && btn.target) {
        if (!VSTry(^{ fired = [UIApplication.sharedApplication sendAction:btn.action to:btn.target from:btn forEvent:nil]; })) { g_createInProgress = NO; done(@"Lỗi nhấn"); return; }
    }
    if (!fired && [editor respondsToSelector:@selector(create)]) {
        if (!VSTry(^{ [editor create]; fired = YES; })) { g_createInProgress = NO; done(@"Lỗi create"); return; }
    }
    if (!fired) { g_createInProgress = NO; done(@"Không kích hoạt"); return; }
    __block BOOL blocked = NO;
    VSPoll(rid, 100, 600, ^BOOL{
        if (VSResolvePopups(editor) == VSPopupBlockedPurchase) { blocked = YES; return YES; }
        return !([editor isViewLoaded] && [[editor view] window]);
    }, ^(BOOL closed) {
        g_createInProgress = NO;
        if (rid != g_runId) return;
        done(blocked ? @"Pro popup" : (closed ? nil : @"Tạo timeout"));
    });
}

@end

// ============================================================================
// ENTRY
// ============================================================================
static void VSBoot(void) {
    if (!NSClassFromString(@"MultiLayerWizEffectVC")) { VSLog(@"Not Video Star"); return; }
    VSMain(^{ @try { [VSTool.shared install]; } @catch (NSException *e) { VSLog(@"Boot error: %@", e); } });
}

__attribute__((constructor)) static void VSToolInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                    @autoreleasepool { VSBoot(); }
                }];
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) VSBoot();
        }
    });
}
