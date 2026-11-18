// ============================================================================
// VideoStarTool v6 — viết lại từ đầu
//
//  Chức năng 1: Auto nhập ảnh/video vào các lớp (giữ nguyên logic copy của VSAuto).
//  Chức năng 2: Chia đoạn theo nhịp — nút nhỏ hiện khi mở bảng chia đoạn.
//  Chức năng 4: Nhập QR + media hàng loạt — nút nhỏ hiện khi mở bảng Hợp nhất.
//               Chọn N ảnh QR cùng lúc -> từng phân cảnh nhập preset ->
//               media chọn ở phân cảnh đầu được dùng lại cho các phân cảnh sau ->
//               tự bấm Trùng khớp, tự bấm Tạo, sang phân cảnh tiếp theo.
//  Đã bỏ: menu 3 ngón, xem code gần nhất.
//
// Mọi selector/chữ ký đều lấy từ header dump của app (MultiLayerWizEffectVC,
// MultiLayerEngine, QRCodeManager, VideoReviewEditVC, New_Project).
// Mọi lời gọi tới app đều qua respondsToSelector + @try. Không giữ con trỏ thô.
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
// 1 = các phân cảnh sau dùng lại clip của phân cảnh đầu (thêm clip vào phân cảnh bằng API của project).
// 0 = mỗi phân cảnh luôn mở bảng chọn media.
#define VS_REUSE_MEDIA 1

typedef id (^VSObjProvider)(void);
typedef void (^VSFillCompletion)(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stopReason);

// ============================================================================
// PHẦN 1 — API của app (đã xác minh từ header)
// ============================================================================

@protocol VSProjectAPI <NSObject>
@property (nonatomic, readonly) NSUInteger sceneCount;
@end

@interface NSObject (VSAppAPI)
// MultiLayerWizEffectVC
- (id)getMultiLayerEngine;
- (void)pickNewContent;
- (void)selectLayerNum:(NSUInteger)n flash:(BOOL)flash;
- (NSInteger)lastSelectedLayerNum;
- (void)copyLayer:(NSInteger)n;
- (void)importedData:(id)data code:(id)code;
- (void)create;
- (void)engineResync;
- (void)refreshDisplay;
- (void)handleImageGenUpdate;
- (NSInteger)getSceneIndex;
// MultiLayerEngine
- (int)layerTypeForLayer:(NSUInteger)n;
- (BOOL)assetHasBeenLoadedForLayer:(NSUInteger)n;
- (id)layerAtLayerNum:(NSUInteger)n;
- (NSInteger)numActiveLayers;
- (void)reloadLayerEffects;
- (BOOL)isNullLayer:(NSUInteger)n;
- (BOOL)particlesExistOnLayerNum:(NSUInteger)n;
- (BOOL)drawingExistsOnLayerNum:(NSUInteger)n;
- (BOOL)gifExistsOnLayerNum:(NSUInteger)n;
- (BOOL)overlayObjectExistsOnLayerNum:(NSUInteger)n;
- (BOOL)zapsObjectExistsOnLayerNum:(NSUInteger)n;
// VideoReviewEditVC
- (id)project;
- (NSUInteger)lastViewedSceneIndex;
- (void)setLastViewedSceneIndex:(NSUInteger)i;
- (NSUInteger)sceneIndex;
- (void)showMultiLayer;
- (void)showMergeScenes;
- (void)closeMergePanel;
- (void)showSplitScene;
- (void)closeSplitPanel;
- (BOOL)isEnoughStorageAvailableForSplit;
- (BOOL)isViewLoaded;
- (UIView *)view;
- (UINavigationController *)navigationController;
- (NSUInteger)navSceneIndex;
- (void)setDelegate:(id)delegate;
- (void)selectedCode:(id)code withImageData:(id)data;
+ (id)sharedInstance;
- (void)dismiss;
- (void)simulateButtonPressButtonWithTitle:(id)title;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show removeOverlayBlending:(BOOL)remove;
// Project (New_Project)
- (NSUInteger)clipCountForSceneIndex:(NSUInteger)i;
- (BOOL)sceneHasAtLeastOneClipWithSceneIndex:(NSUInteger)i;
- (NSUInteger)activeClipIndexForSceneIndex:(NSUInteger)i;
- (id)frameTimesForSceneIndex:(NSUInteger)i clipIndex:(NSUInteger)c;
- (BOOL)addNewClipToSceneAtIndex:(NSUInteger)i clipURL:(id)url sourceClipIndex:(NSInteger)src makeActive:(BOOL)active image:(id)image frameTimes:(id)frameTimes;
// MultiSplitView
- (BOOL)beatModeOn;
- (void)toggleBeatMode;
- (BOOL)hasNextBeat;
- (void)jumpToNextBeat;
- (void)setSplitPoint;
- (void)doSplit;
- (void)gotoTime:(CMTime)t;
@end

// ============================================================================
// PHẦN 2 — AN TOÀN & HẸN GIỜ
// ============================================================================

static NSUInteger g_runIdentifier = 0;     // tăng khi bắt đầu/dừng tác vụ, mọi callback cũ tự thoát
static BOOL g_busy = NO;                   // đang có tác vụ
static BOOL g_autoConfirmPopups = NO;      // chỉ bật khi chạy chức năng 4
static BOOL g_suppressLayerActionMenu = NO;
static BOOL g_vsaAutomating = NO;          // đang chép lớp: chặn hộp thoại ghi đè / menu lớp
static BOOL g_dismissLayerMenu = NO;
static NSUInteger g_presetImportEventCounter = 0;
static void (^g_onLayerAddedHandler)(void) = nil;

@class VSBatchJob;
static void VSStopAll(void);
static void VSStatus(NSString *msg);
static void VSEndRun(void);
static UIWindow *g_overlayToolWindowRef(void);
static void VSDismissMenus(id ed);
static void VSCreateAndAdvance(VSBatchJob *job, id ed, NSString *label);
static void VSLoadImages(NSArray<PHPickerResult *> *results, void (^done)(NSArray *images));
static void VSPresent(UIViewController *vc);

static void VSGuard(void (^block)(void)) {
    @try { block(); }
    @catch (NSException *e) {
        VSStopAll();
        NSLog(@"[VSTool] dừng an toàn: %@ %@", e.name, e.reason);
    }
}

static void VSAfterMS(int64_t ms, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ @autoreleasepool { VSGuard(block); } });
}

static BOOL VSTry(void (^block)(void)) {
    @try { block(); return YES; }
    @catch (NSException *__unused e) { return NO; }
}

// Poll điều kiện trên main, dừng khi hết số lần thử hoặc tác vụ đã đổi.
static void VSPoll(NSUInteger runId, int64_t ms, NSUInteger tries, BOOL (^cond)(void), void (^done)(BOOL ok)) {
    if (runId != g_runIdentifier) { if (done) VSGuard(^{ done(NO); }); return; }
    BOOL matched = NO;
    @try { matched = cond(); } @catch (NSException *__unused e) { matched = NO; }
    if (matched) { if (done) VSGuard(^{ done(YES); }); return; }
    if (tries == 0) { if (done) VSGuard(^{ done(NO); }); return; }
    VSAfterMS(ms, ^{ VSPoll(runId, ms, tries - 1, cond, done); });
}

// Poll trên editor: mỗi lần lấy editor lại từ provider, không giữ mạnh.
static void VSPollEditor(NSUInteger runId, int64_t ms, NSUInteger tries, VSObjProvider provider,
                         BOOL (^cond)(id ed), void (^done)(BOOL ok)) {
    if (runId != g_runIdentifier) { if (done) VSGuard(^{ done(NO); }); return; }
    id ed = provider ? provider() : nil;
    if (!ed) { if (done) VSGuard(^{ done(NO); }); return; }
    BOOL matched = NO;
    @try { matched = cond(ed); } @catch (NSException *__unused e) { matched = NO; }
    ed = nil;
    if (matched) { if (done) VSGuard(^{ done(YES); }); return; }
    if (tries == 0) { if (done) VSGuard(^{ done(NO); }); return; }
    VSAfterMS(ms, ^{ VSPollEditor(runId, ms, tries - 1, provider, cond, done); });
}

// ============================================================================
// PHẦN 3 — TIỆN ÍCH
// ============================================================================

static id VSKVC(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        if (![object respondsToSelector:NSSelectorFromString(key)]) return nil;
        return [object valueForKey:key];
    } @catch (NSException *__unused e) { return nil; }
}

static BOOL VSTruthy(id value) {
    if (!value || value == [NSNull null]) return NO;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value boolValue];
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value length] > 0;
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) return [value count] > 0;
    return YES;
}

static BOOL VSContains(NSString *hay, NSString *needle) {
    if (!hay.length || !needle.length) return NO;
    return [hay rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *VSCheapDesc(id obj) {
    if (!obj || obj == [NSNull null]) return @"";
    if ([obj isKindOfClass:[NSString class]]) return obj;
    if ([obj isKindOfClass:[NSURL class]]) return ((NSURL *)obj).absoluteString ?: @"";
    if ([obj isKindOfClass:[NSNumber class]]) return [obj description];
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"%@#%lu", NSStringFromClass([obj class]), (unsigned long)[obj count]];
    }
    return NSStringFromClass([obj class]);
}

static NSArray<UIWindow *> *VSAllWindows(void) {
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        [all addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    return all;
}

// Đọc currentTime của đối tượng (CMTime là struct lớn, lấy IMP để tránh xung đột khai báo với AVFoundation).
static CMTime VSCurrentTime(id obj) {
    SEL sel = @selector(currentTime);
    if (!obj || ![obj respondsToSelector:sel]) return kCMTimeInvalid;
    @try {
        CMTime (*fn)(id, SEL) = (CMTime (*)(id, SEL))[obj methodForSelector:sel];
        return fn(obj, sel);
    } @catch (NSException *__unused e) { return kCMTimeInvalid; }
}

static UIViewController *VSSearchVC(UIViewController *root, Class target, int depth) {
    if (!root || depth > 15) return nil;
    if (root.presentedViewController) {
        UIViewController *r = VSSearchVC(root.presentedViewController, target, depth + 1);
        if (r) return r;
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in ((UINavigationController *)root).viewControllers.reverseObjectEnumerator) {
            UIViewController *r = VSSearchVC(c, target, depth + 1);
            if (r) return r;
        }
    }
    for (UIViewController *c in root.childViewControllers.reverseObjectEnumerator) {
        UIViewController *r = VSSearchVC(c, target, depth + 1);
        if (r) return r;
    }
    if ([root isKindOfClass:target] && root.isViewLoaded && root.view.window) return root;
    return nil;
}

static UIViewController *VSFindVC(NSString *className) {
    Class target = NSClassFromString(className);
    if (!target) return nil;
    for (UIWindow *w in VSAllWindows().reverseObjectEnumerator) {
        if (w.hidden || w.alpha <= 0.01) continue;
        if (w == g_overlayToolWindowRef()) continue;
        UIViewController *found = VSSearchVC(w.rootViewController, target, 0);
        if (found) return found;
    }
    return nil;
}

static UIViewController *VSTopVC(void) {
    UIViewController *vc = nil;
    for (UIWindow *w in VSAllWindows().reverseObjectEnumerator) {
        if (w == g_overlayToolWindowRef() || w.hidden) continue;
        vc = w.rootViewController;
        break;
    }
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

static void VSAlert(NSString *title, NSString *msg) {
    UIViewController *top = VSTopVC();
    if (!top) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}

static BOOL VSEditorAlive(id ed) {
    if (!ed) return NO;
    @try {
        UIViewController *vc = (UIViewController *)ed;
        if (vc.isBeingDismissed) return NO;
        if (vc.isViewLoaded && vc.view.window) return YES;
        if (vc.presentedViewController) return YES;
        return NO;
    } @catch (NSException *__unused e) { return NO; }
}

static BOOL VSEditorBusy(id ed) {
    id spinner = VSKVC(ed, @"spinner");
    if ([spinner isKindOfClass:[UIActivityIndicatorView class]]) {
        UIActivityIndicatorView *sp = spinner;
        if (sp.isAnimating && sp.window && !sp.hidden) return YES;
    }
    id alert = VSKVC(ed, @"loadingAlert");
    if ([alert isKindOfClass:[UIView class]]) {
        UIView *v = alert;
        if (v.window && !v.hidden && v.alpha > 0.01) return YES;
    }
    return NO;
}

// ============================================================================
// PHẦN 4 — LỚP: NHẬN DIỆN, CHỮ KÝ, ASSET, SAO CHÉP (VSAuto)
// ============================================================================

static BOOL VSLayerLoaded(id engine, NSUInteger n) {
    if (!engine || ![engine respondsToSelector:@selector(assetHasBeenLoadedForLayer:)]) return YES;
    @try { return [engine assetHasBeenLoadedForLayer:n]; } @catch (NSException *__unused e) { return YES; }
}

static BOOL VSEngineFlag(id engine, SEL sel, NSUInteger n) {
    if (!engine || ![engine respondsToSelector:sel]) return NO;
    @try { return ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(engine, sel, n); }
    @catch (NSException *__unused e) { return NO; }
}

// Chữ ký ổn định của lớp (không đọc layerImage vì quá nặng).
static NSString *VSLayerSignature(id engine, NSUInteger n) {
    if (!engine || ![engine respondsToSelector:@selector(layerAtLayerNum:)]) return nil;
    __block NSString *sig = nil;
    VSTry(^{
        id layer = [engine layerAtLayerNum:n];
        if (!layer) return;
        id gen = VSKVC(layer, @"imageGenerator");
        id asset = VSKVC(gen, @"asset");
        NSString *url = [asset isKindOfClass:[AVURLAsset class]] ? (((AVURLAsset *)asset).URL.absoluteString ?: @"") : @"";
        id tex = VSKVC(gen, @"layerImageTextureID");
        NSString *texKey = [tex isKindOfClass:[NSNumber class]] ? [tex description] : @"";
        sig = [NSString stringWithFormat:@"%@|%@|%@", url, texKey, VSCheapDesc(VSKVC(layer, @"origAssetInfo"))];
    });
    return sig;
}

// URL file của media trên lớp (chỉ có với video/asset có URL).
static NSURL *VSLayerAssetURL(id engine, NSUInteger n) {
    if (!engine || ![engine respondsToSelector:@selector(layerAtLayerNum:)]) return nil;
    __block NSURL *u = nil;
    VSTry(^{
        id layer = [engine layerAtLayerNum:n];
        id gen = VSKVC(layer, @"imageGenerator");
        id asset = VSKVC(gen, @"asset");
        if ([asset isKindOfClass:[AVURLAsset class]]) u = ((AVURLAsset *)asset).URL;
    });
    return u;
}

// Lớp có thể thay media: Video (1) hoặc Photo (4), bỏ 3D/Text/Null/GIF/Overlay/Zaps/Particle/Drawing.
static NSArray<NSNumber *> *VSFillableLayers(id engine, BOOL includeEmpty) {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    if (!engine) return out;
    for (NSUInteger i = 0; i < VS_MAX_LAYERS; i++) {
        __block BOOL ok = NO;
        VSTry(^{
            if (!includeEmpty && !VSLayerLoaded(engine, i)) return;
            if (![engine respondsToSelector:@selector(layerTypeForLayer:)]) return;
            int type = [engine layerTypeForLayer:i];
            if (type != 1 && type != 4) return;
            if (VSEngineFlag(engine, @selector(isNullLayer:), i)) return;
            if (VSEngineFlag(engine, @selector(particlesExistOnLayerNum:), i)) return;
            if (VSEngineFlag(engine, @selector(drawingExistsOnLayerNum:), i)) return;
            if (VSEngineFlag(engine, @selector(gifExistsOnLayerNum:), i)) return;
            if (VSEngineFlag(engine, @selector(overlayObjectExistsOnLayerNum:), i)) return;
            if (VSEngineFlag(engine, @selector(zapsObjectExistsOnLayerNum:), i)) return;
            id layer = [engine layerAtLayerNum:i];
            if (!layer) return;
            if (VSTruthy(VSKVC(layer, @"is3DLayer"))) return;
            if (VSTruthy(VSKVC(layer, @"textDictionary"))) return;
            ok = YES;
        });
        if (ok) [out addObject:@(i)];
    }
    return out;
}

static BOOL VSFireCopy(id editor, id engine, NSUInteger src) {
    SEL s = @selector(copyLayer:);
    id receiver = nil;
    if ([editor respondsToSelector:s]) receiver = editor;
    else if ([engine respondsToSelector:s]) receiver = engine;
    if (!receiver) return NO;
    @try {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(receiver, s, (NSInteger)src);
        return YES;
    } @catch (NSException *__unused e) { return NO; }
}

// ============================================================================
// PHẦN 5 — POPUP: TỰ BẤM "TRÙNG KHỚP" (CHỈ POPUP ĐÃ BIẾT), DỪNG KHI LÀ POPUP MUA PRO
// ============================================================================

static const void *kVSPopupHandledKey = &kVSPopupHandledKey;
static NSHashTable *g_popupTable = nil;

static BOOL VSIsPurchasePopup(id popup) {
    NSString *msg = [VSKVC(popup, @"_message") description] ?: @"";
    NSString *title = [VSKVC(popup, @"_title") description] ?: @"";
    NSString *all = [NSString stringWithFormat:@" %@ %@ ", title, msg];
    NSArray *kw = @[@"purchase", @"subscription", @"unlock pro", @"pro pack", @"restore purchase",
                    @"all access", @" buy ", @"upgrade", @"free trial", @"mua gói", @"khôi phục",
                    @"đăng ký", @"nâng cấp", @"dùng thử", @"mở khóa", @"thanh toán"];
    for (NSString *k in kw) if (VSContains(all, k)) return YES;
    return NO;
}

static NSArray *VSVisiblePopups(void) {
    NSMutableArray *out = [NSMutableArray array];
    if (!g_popupTable) return out;
    for (id p in g_popupTable.allObjects) {
        if (!p || !NSClassFromString(@"CustomPopup") || ![p isKindOfClass:NSClassFromString(@"CustomPopup")]) continue;
        UIView *v = (UIView *)p;
        if (v.window && !v.hidden && v.alpha > 0.05) [out addObject:p];
    }
    return out;
}

static NSArray<NSString *> *VSPopupTitles(id popup, NSMutableDictionary<NSString *, UIButton *> *map) {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    id buttons = VSKVC(popup, @"_buttons");
    if ([buttons isKindOfClass:[NSArray class]]) {
        for (id b in (NSArray *)buttons) {
            if (![b isKindOfClass:[UIButton class]]) continue;
            NSString *t = ((UIButton *)b).currentTitle;
            if (!t.length) continue;
            if (map) map[t] = b;
            [titles addObject:t];
        }
    }
    return titles;
}

static BOOL VSTitleIs(NSString *title, NSString *candidate) {
    if (!title.length || !candidate.length) return NO;
    NSString *t = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (candidate.length <= 4) return [t caseInsensitiveCompare:candidate] == NSOrderedSame;
    return VSContains(t, candidate);
}

// Trả về YES nếu đã xử lý popup (hoặc phát hiện popup mua Pro -> *purchase = YES).
static BOOL VSAutoResolvePopups(BOOL *purchase) {
    if (purchase) *purchase = NO;
    if (!g_autoConfirmPopups) return NO;
    for (id popup in VSVisiblePopups()) {
        if (VSIsPurchasePopup(popup)) { if (purchase) *purchase = YES; return YES; }
        if (objc_getAssociatedObject(popup, kVSPopupHandledKey)) continue;
        NSMutableDictionary<NSString *, UIButton *> *map = [NSMutableDictionary dictionary];
        NSArray<NSString *> *titles = VSPopupTitles(popup, map);
        if (titles.count == 0) continue;
        NSString *header = [NSString stringWithFormat:@"%@ %@", [VSKVC(popup, @"_title") description] ?: @"", [VSKVC(popup, @"_message") description] ?: @""];
        NSString *pick = nil;
        NSArray *match = @[@"Trùng khớp", @"Khớp: rút ngắn/giãn", @"Match: shorten/stretch", @"Match"];
        for (NSString *c in match) { for (NSString *t in titles) if (!pick && VSTitleIs(t, c)) pick = t; }
        if (!pick && (VSContains(header, @"dài hơn") || VSContains(header, @"Original Preset Layers") || VSContains(header, @"Các lớp Cài đặt sẵn Gốc"))) {
            for (NSString *c in @[@"OK", @"Đồng ý", @"Xong", @"Done"]) { for (NSString *t in titles) if (!pick && VSTitleIs(t, c)) pick = t; }
        }
        if (!pick) continue;
        objc_setAssociatedObject(popup, kVSPopupHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIButton *btn = map[pick];
        VSTry(^{
            if ([popup respondsToSelector:@selector(simulateButtonPressButtonWithTitle:)]) [popup simulateButtonPressButtonWithTitle:pick];
            else if (btn) [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        });
        return YES;
    }
    return NO;
}

static BOOL VSPurchasePopupShowing(void) {
    for (id p in VSVisiblePopups()) if (VSIsPurchasePopup(p)) return YES;
    return NO;
}

// ============================================================================
// PHẦN 6 — BỘ ĐIỀN LỚP (chức năng 1: VSAuto copy; chức năng 4: chọn media ở phân cảnh đầu)
// ============================================================================

static void VSSetRunFlags(BOOL automating) {
    g_vsaAutomating = automating;
    g_suppressLayerActionMenu = automating;
    g_dismissLayerMenu = automating;
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
@property (nonatomic, assign) BOOL requirePicker;
@property (nonatomic, copy) NSString *beforeSig;
@property (nonatomic, assign) BOOL pickerOpened;
@property (nonatomic, assign) BOOL pickerConfirmed;
@property (nonatomic, assign) CFAbsoluteTime pickerClosedAt;
@property (nonatomic, assign) NSInteger pickOutcome; // 0 chờ, 1 đã chọn, 2 huỷ, 3 popup Pro
+ (void)fillLayers:(NSArray<NSNumber *> *)layers editor:(id)editor runId:(NSUInteger)runId requirePicker:(BOOL)requirePicker completion:(VSFillCompletion)completion;
@end

static VSLayerFiller *g_activeFiller = nil;

@implementation VSLayerFiller

+ (void)fillLayers:(NSArray<NSNumber *> *)layers editor:(id)editor runId:(NSUInteger)runId requirePicker:(BOOL)requirePicker completion:(VSFillCompletion)completion {
    if (layers.count == 0) { if (completion) completion(0, 0, @[], @"Không có lớp để điền"); return; }
    VSLayerFiller *f = [VSLayerFiller new];
    f.editor = editor;
    f.runId = runId;
    f.layers = layers;
    f.completion = completion;
    f.unconfirmed = [NSMutableArray array];
    f.source = layers.firstObject.unsignedIntegerValue;
    f.nextIndex = 1;
    f.requirePicker = requirePicker;
    g_activeFiller = f;
    VSSetRunFlags(YES);
    [f selectSourceAndPick];
}

- (BOOL)alive { return !self.finished && self.runId == g_runIdentifier; }

- (VSObjProvider)provider {
    __weak VSLayerFiller *w = self;
    return ^id{ return w.editor; };
}

- (void)finishWithStop:(NSString *)reason {
    if (self.finished) return;
    self.finished = YES;
    g_onLayerAddedHandler = nil;
    VSSetRunFlags(NO);
    BOOL live = (self.runId == g_runIdentifier);
    VSFillCompletion cb = self.completion;
    self.completion = nil;
    if (g_activeFiller == self) g_activeFiller = nil;
    if (live && cb) {
        NSUInteger targets = self.layers.count > 0 ? self.layers.count - 1 : 0;
        cb(self.copied, targets, [self.unconfirmed copy], reason);
    }
}

- (void)selectLayer:(NSUInteger)n then:(void (^)(BOOL ok))next {
    id ed = self.editor;
    if (!ed) { next(NO); return; }
    if ([ed respondsToSelector:@selector(selectLayerNum:flash:)]) {
        VSTry(^{ [ed selectLayerNum:n flash:NO]; });
    }
    if (![ed respondsToSelector:@selector(lastSelectedLayerNum)]) {
        VSAfterMS(300, ^{ next(YES); });
        return;
    }
    VSPollEditor(self.runId, 50, 80, [self provider], ^BOOL(id e) {
        return [e lastSelectedLayerNum] == (NSInteger)n;
    }, ^(BOOL ok) { next(ok); });
}

- (void)selectSourceAndPick {
    [self selectLayer:self.source then:^(BOOL ok) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!ok) { [self finishWithStop:@"Không chọn được lớp nguồn"]; return; }
        VSAfterMS(250, ^{ [self openPicker]; });
    }];
}

- (void)openPicker {
    if (![self alive]) { [self finishWithStop:nil]; return; }
    id ed = self.editor;
    if (!VSEditorAlive(ed)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }
    if (![ed respondsToSelector:@selector(pickNewContent)]) { [self finishWithStop:@"Không tìm thấy bảng chọn media"]; return; }

    self.beforeSig = VSLayerSignature(ed, self.source) ?: @"";
    self.pickerOpened = NO;
    self.pickerConfirmed = NO;
    self.pickerClosedAt = 0;
    self.pickOutcome = 0;

    __weak VSLayerFiller *w = self;
    g_onLayerAddedHandler = ^{
        VSLayerFiller *s = w;
        if (s) s.pickerConfirmed = YES;
    };

    BOOL opened = VSTry(^{ [ed pickNewContent]; });
    if (!opened) { [self finishWithStop:@"Không mở được bảng chọn media"]; return; }

    VSPollEditor(self.runId, 200, 900, [self provider], ^BOOL(id e) {
        return [self pickCondition:e];
    }, ^(BOOL ok) {
        [self afterPick];
    });
}

// Chấp nhận lựa chọn khi: bảng chọn đã mở rồi đóng lại, và lớp nguồn có thay đổi (hoặc app báo đã thêm lớp).
- (BOOL)pickCondition:(id)ed {
    UIViewController *vc = (UIViewController *)ed;
    BOOL open = vc.presentedViewController != nil || vc.navigationController.presentedViewController != nil;
    if (open) {
        self.pickerOpened = YES;
        self.pickerClosedAt = 0;
        return NO;
    }
    BOOL purchase = NO;
    if (VSPurchasePopupShowing()) { self.pickOutcome = 3; return YES; }
    (void)purchase;

    id engine = [ed getMultiLayerEngine];
    NSString *sig = VSLayerSignature(engine, self.source) ?: @"";
    BOOL changed = sig.length > 0 && ![sig isEqualToString:(self.beforeSig ?: @"")];
    BOOL signal = self.pickerConfirmed || changed;
    BOOL pickerOK = !self.requirePicker || self.pickerOpened;

    if (signal && pickerOK && VSLayerLoaded(engine, self.source) && !VSEditorBusy(ed)) {
        self.pickOutcome = 1;
        return YES;
    }
    if (self.pickerOpened) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (self.pickerClosedAt == 0) self.pickerClosedAt = now;
        if (now - self.pickerClosedAt > 2.5) { self.pickOutcome = 2; return YES; }
    }
    return NO;
}

- (void)afterPick {
    g_onLayerAddedHandler = nil;
    if (![self alive]) { [self finishWithStop:nil]; return; }
    switch (self.pickOutcome) {
        case 1: [self copyNext]; break;
        case 2: [self finishWithStop:@"Đã huỷ (chưa chọn media)"]; break;
        case 3: [self finishWithStop:@"Popup mua Pro"]; break;
        default: [self finishWithStop:@"Quá thời gian chọn media"]; break;
    }
}

- (void)advance {
    self.nextIndex += 1;
    VSAfterMS(150, ^{ [self copyNext]; });
}

- (void)skipTarget:(NSUInteger)target {
    [self.unconfirmed addObject:@(target)];
    [self advance];
}

- (void)copyNext {
    if (![self alive]) { [self finishWithStop:nil]; return; }
    id ed = self.editor;
    if (!VSEditorAlive(ed)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }
    if (VSPurchasePopupShowing()) { [self finishWithStop:@"Popup mua Pro"]; return; }
    if (self.nextIndex >= self.layers.count) {
        [self selectLayer:self.source then:^(BOOL ok) { [self finishWithStop:nil]; }];
        return;
    }
    NSUInteger target = [self.layers[self.nextIndex] unsignedIntegerValue];
    VSStatus([NSString stringWithFormat:@"Chép sang lớp %lu (%lu/%lu)…", (unsigned long)target + 1,
              (unsigned long)self.nextIndex, (unsigned long)(self.layers.count - 1)]);
    VSDismissMenus(ed);
    [self copyToTarget:target];
}

- (void)copyToTarget:(NSUInteger)target {
    [self selectLayer:target then:^(BOOL selected) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!selected || !VSEditorAlive(self.editor)) { [self skipTarget:target]; return; }
        VSAfterMS(120, ^{
            if (![self alive]) { [self finishWithStop:nil]; return; }
            id e2 = self.editor;
            if (!VSEditorAlive(e2)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }
            NSString *before = VSLayerSignature(e2, target) ?: @"";
            if (!VSFireCopy(e2, [e2 getMultiLayerEngine], self.source)) { [self skipTarget:target]; return; }
            [self waitCopyConfirm:target before:before];
        });
    }];
}

- (void)waitCopyConfirm:(NSUInteger)target before:(NSString *)before {
    NSUInteger tries = (NSUInteger)(VS_COPY_CONFIRM_TIMEOUT * 1000.0 / 150.0);
    VSPollEditor(self.runId, 150, tries, [self provider], ^BOOL(id e) {
        if (VSPurchasePopupShowing()) return YES;
        if (VSEditorBusy(e)) return NO;
        id engine = [e getMultiLayerEngine];
        NSString *now = VSLayerSignature(engine, target) ?: @"";
        return VSLayerLoaded(engine, target) && now.length > 0 && ![now isEqualToString:before];
    }, ^(BOOL ok) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (VSPurchasePopupShowing()) { [self finishWithStop:@"Popup mua Pro"]; return; }
        if (ok) self.copied += 1; else [self.unconfirmed addObject:@(target)];
        [self advance];
    });
}

@end

// Ẩn menu chọn lớp nếu nó hiện (chỉ khi đang tự động).
static void VSDismissMenus(id ed) {
    if (!g_dismissLayerMenu) return;
    for (id p in VSVisiblePopups()) {
        if (!VSIsPurchasePopup(p)) {
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            NSArray *t = VSPopupTitles(p, m);
            BOOL isMenu = NO;
            int hits = 0;
            for (NSString *x in t) if (VSContains(x, @"Keyframes") || VSContains(x, @"Mask") || VSContains(x, @"Mặt nạ") || VSContains(x, @"Xoá") || VSContains(x, @"Xóa") || VSContains(x, @"Delete") || VSContains(x, @"Replace") || VSContains(x, @"Thay")) hits++;
            isMenu = hits >= 3;
            if (isMenu && !objc_getAssociatedObject(p, kVSPopupHandledKey)) {
                objc_setAssociatedObject(p, kVSPopupHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                VSTry(^{ if ([p respondsToSelector:@selector(dismiss)]) [p dismiss]; });
            }
        }
    }
    (void)ed;
}

// ============================================================================
// PHẦN 7 — QR: GIẢI MÃ ẢNH VÀ NHẬP CODE QUA APP
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

static NSString *VSDecodeQR(UIImage *image) {
    if (!image) return nil;
    CIImage *base = [[CIImage alloc] initWithImage:image];
    if (!base && image.CGImage) base = [CIImage imageWithCGImage:image.CGImage];
    if (!base) return nil;
    NSString *result = nil;
    @autoreleasepool {
        CIDetector *d = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
        if (!d) return nil;
        CGFloat scales[] = {1.0, 0.5, 2.0};
        for (NSUInteger i = 0; i < 3 && !result; i++) {
            CIImage *img = (scales[i] == 1.0) ? base : [base imageByApplyingTransform:CGAffineTransformMakeScale(scales[i], scales[i])];
            result = VSFirstQRMessage([d featuresInImage:img]);
            if (result) break;
            CIFilter *f = [CIFilter filterWithName:@"CIColorControls"];
            if (!f) continue;
            [f setValue:img forKey:kCIInputImageKey];
            [f setValue:@0.0 forKey:kCIInputSaturationKey];
            [f setValue:@1.6 forKey:kCIInputContrastKey];
            if (f.outputImage) result = VSFirstQRMessage([d featuresInImage:f.outputImage]);
        }
    }
    return result;
}

static UIImage *VSDownscale(UIImage *image, CGFloat maxSide) {
    if (!image) return nil;
    CGFloat longest = MAX(image.size.width, image.size.height);
    if (longest <= maxSide) return image;
    CGFloat k = maxSide / longest;
    CGSize sz = CGSizeMake(floor(image.size.width * k), floor(image.size.height * k));
    UIGraphicsBeginImageContextWithOptions(sz, NO, 1.0);
    [image drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: image;
}

@interface VSQRProxy : NSObject
@property (nonatomic, copy) void (^onCode)(id preset, id code);
@end
@implementation VSQRProxy
- (NSString *)qrLabel { return @"Multi-Layer"; }
- (NSString *)qrSetupLabel { return @""; }
- (NSString *)codePrefix { return @"n"; }
- (BOOL)validCode:(NSString *)code { return [code isKindOfClass:[NSString class]] && ([code hasPrefix:@"m"] || [code hasPrefix:@"n"]); }
- (void)importedData:(id)data code:(id)code {
    void (^b)(id, id) = self.onCode;
    if (b) dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { VSGuard(^{ b(data, code); }); } });
}
- (id)dataToShare { return nil; }
- (void)setActivityiPadPopup:(id)popup {}
- (id)qrImage { return nil; }
- (id)qrIcon { return nil; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *s = [super methodSignatureForSelector:sel];
    return s ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSUInteger len = inv.methodSignature.methodReturnLength;
    if (len == 0) return;
    void *zero = calloc(1, len);
    [inv setReturnValue:zero];
    free(zero);
}
@end

static void VSSetQRDelegate(id qr, id delegate) {
    if (!qr || ![qr respondsToSelector:@selector(setDelegate:)]) return;
    VSTry(^{ [qr setDelegate:delegate]; });
}

// Gửi lần lượt từng ảnh QR vào app. done(presets, codes) khi xong, done(nil, nil) nếu lỗi.
static void VSCollectCodes(NSArray *images, NSUInteger runId, void (^done)(NSArray *presets, NSArray *codes, NSString *err)) {
    NSUInteger n = images.count;
    NSMutableArray *presets = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *codes = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) { [presets addObject:[NSNull null]]; [codes addObject:[NSNull null]]; }
    __block NSUInteger idx = 0;
    __block void (^step)(void) = nil;
    step = ^{
        if (runId != g_runIdentifier) { step = nil; return; }
        if (idx >= n) { step = nil; done(presets, codes, nil); return; }
        NSUInteger i = idx;
        id item = images[i];
        NSString *code = [item isKindOfClass:[UIImage class]] ? VSDecodeQR((UIImage *)item) : nil;
        if (!code.length || !([code hasPrefix:@"m"] || [code hasPrefix:@"n"])) {
            step = nil;
            done(nil, nil, [NSString stringWithFormat:@"Ảnh thứ %lu không đọc được mã QR của Video Star", (unsigned long)(i + 1)]);
            return;
        }
        Class qc = NSClassFromString(@"QRCodeManager");
        id qr = [qc respondsToSelector:@selector(sharedInstance)] ? [qc sharedInstance] : nil;
        if (!qr || ![qr respondsToSelector:@selector(selectedCode:withImageData:)]) {
            step = nil;
            done(nil, nil, @"Không tìm thấy QRCodeManager");
            return;
        }
        VSStatus([NSString stringWithFormat:@"Nhập code %lu/%lu…", (unsigned long)(i + 1), (unsigned long)n]);
        __block BOOL got = NO;
        VSQRProxy *proxy = [VSQRProxy new];
        proxy.onCode = ^(id preset, id codeId) {
            if (got || runId != g_runIdentifier) return;
            if (!preset || ![codeId isKindOfClass:[NSString class]]) return;
            got = YES;
            presets[i] = preset;
            codes[i] = codeId;
            idx = i + 1;
            VSAfterMS(300, ^{ if (step) step(); });
        };
        VSSetQRDelegate(qr, proxy);
        NSData *png = UIImagePNGRepresentation(VSDownscale((UIImage *)item, 1024.0));
        VSTry(^{ [qr selectedCode:code withImageData:png]; });
        VSAfterMS(6000, ^{
            if (got || runId != g_runIdentifier) return;
            got = YES;
            step = nil;
            done(nil, nil, [NSString stringWithFormat:@"App không nhận được mã của ảnh thứ %lu", (unsigned long)(i + 1)]);
        });
    };
    step();
}

// ============================================================================
// PHẦN 8 — ĐIỀU KHIỂN PHÂN CẢNH: NHẬP PRESET, MỞ EDITOR, TẠO
// ============================================================================


// Mở editor của phân cảnh sc (qua màn hình đánh giá). done(editor) hoặc done(nil).
static void VSOpenScene(NSUInteger sc, id reviewVC, NSUInteger runId, void (^done)(id editor)) {
    id (^current)(void) = ^id{
        __block id ed = nil;
        VSTry(^{
            id candidate = VSFindVC(@"MultiLayerWizEffectVC");
            if (!candidate || ![candidate getMultiLayerEngine]) return;
            id nav = [candidate navigationController];
            BOOL ok = YES;
            if ([nav respondsToSelector:@selector(navSceneIndex)]) ok = ([nav navSceneIndex] == sc);
            if (ok) ed = candidate;
        });
        return ed;
    };
    id existing = current();
    if (existing) { done(existing); return; }
    if (!reviewVC) { done(nil); return; }
    if (!VSTry(^{ [reviewVC setLastViewedSceneIndex:sc]; [reviewVC showMultiLayer]; })) { done(nil); return; }
    VSPoll(runId, 80, 100, ^BOOL{ return current() != nil; }, ^(BOOL ok) { done(ok ? current() : nil); });
}

// Nhập preset (code) vào editor. Chờ app báo đã nạp xong, tự bấm Trùng khớp.
static void VSImportPreset(id editor, id preset, id code, NSUInteger runId, void (^done)(NSString *err)) {
    if (![editor respondsToSelector:@selector(importedData:code:)]) { done(@"Editor không hỗ trợ nạp preset"); return; }
    NSUInteger before = g_presetImportEventCounter;
    BOOL ok = VSTry(^{ [editor importedData:preset code:code]; });
    if (!ok) { done(@"Lỗi nạp preset"); return; }
    __weak id w = editor;
    VSPollEditor(runId, 50, 200, ^id{ return w; }, ^BOOL(id ed) {
        BOOL purchase = NO;
        VSAutoResolvePopups(&purchase);
        if (purchase) return YES;
        return g_presetImportEventCounter > before;
    }, ^(BOOL loaded) {
        if (runId != g_runIdentifier) return;
        if (VSPurchasePopupShowing()) { done(@"Popup mua Pro"); return; }
        if (!loaded) { done(@"Hết thời gian nạp preset"); return; }
        done(nil);
    });
}

// Chờ editor ổn định rồi bấm Tạo.
static void VSWaitAndCreate(id editor, NSUInteger runId, void (^done)(NSString *err)) {
    __weak id w = editor;
    __block NSUInteger calm = 0;
    VSPollEditor(runId, 100, 150, ^id{ return w; }, ^BOOL(id ed) {
        if (!VSEditorAlive(ed)) return YES;
        VSDismissMenus(ed);
        BOOL purchase = NO;
        VSAutoResolvePopups(&purchase);
        if (purchase) return YES;
        BOOL quiet = !VSPurchasePopupShowing() && !VSEditorBusy(ed);
        calm = quiet ? calm + 1 : 0;
        return calm >= 8;
    }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        if (VSPurchasePopupShowing()) { done(@"Popup mua Pro"); return; }
        id ed = w;
        if (!VSEditorAlive(ed)) { done(@"Editor bị đóng trước khi Tạo"); return; }
        if (!ok) { done(@"Editor chưa ổn định để Tạo"); return; }
        UIBarButtonItem *btn = nil;
        id cancel = VSKVC(ed, @"cancelBarButton");
        id kvc = VSKVC(ed, @"createBarButton");
        if ([kvc isKindOfClass:[UIBarButtonItem class]] && kvc != cancel) btn = kvc;
        BOOL fired = NO;
        if (btn && btn.action && btn.target) {
            fired = VSTry(^{ [[UIApplication sharedApplication] sendAction:btn.action to:btn.target from:btn forEvent:nil]; });
        }
        if (!fired && [ed respondsToSelector:@selector(create)]) {
            fired = VSTry(^{ [ed create]; });
        }
        if (!fired) { done(@"Không bấm được nút Tạo"); return; }
        VSPollEditor(runId, 100, 600, ^id{ return w; }, ^BOOL(id e) {
            return !(e && [e isViewLoaded] && [[e view] window]);
        }, ^(BOOL closed) {
            if (runId != g_runIdentifier) return;
            done((closed || w == nil) ? nil : @"Tạo chưa hoàn tất");
        });
    });
}

// ============================================================================
// PHẦN 9 — CHỨC NĂNG 4: JOB HÀNG LOẠT
// ============================================================================

@interface VSBatchJob : NSObject
@property (nonatomic, copy) NSArray *presets;
@property (nonatomic, copy) NSArray *codes;
@property (nonatomic, assign) NSUInteger startScene;
@property (nonatomic, assign) NSUInteger total;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, assign) NSUInteger okCount;
@property (nonatomic, assign) NSUInteger origScene;
@property (nonatomic, assign) NSUInteger runId;
@property (nonatomic, weak) id reviewVC;
@property (nonatomic, strong) NSURL *reuseURL;
@property (nonatomic, strong) id reuseFrameTimes;
@property (nonatomic, assign) BOOL reusedThisScene;
@property (nonatomic, assign) BOOL finished;
@end
@implementation VSBatchJob
@end

static void VSJobStep(VSBatchJob *job);

static void VSJobFinish(VSBatchJob *job, NSString *err) {
    if (job.finished) return;
    job.finished = YES;
    if (job.runId != g_runIdentifier) return;
    id rvc = job.reviewVC;
    VSTry(^{ [rvc setLastViewedSceneIndex:job.origScene]; });
    VSEndRun();
    NSString *msg = [NSString stringWithFormat:@"Xong %lu/%lu phân cảnh", (unsigned long)job.okCount, (unsigned long)job.total];
    if (err) msg = [err stringByAppendingFormat:@"\n%@", msg];
    VSAlert(err ? @"Dừng" : @"Thành công", msg);
}

// Thêm clip đã dùng ở phân cảnh đầu vào phân cảnh sc. Trả về YES nếu app nhận.
static BOOL VSAddReuseClip(VSBatchJob *job, NSUInteger sc) {
    if (!job.reuseURL) return NO;
    id rvc = job.reviewVC;
    __block id proj = nil;
    VSTry(^{ proj = [rvc project]; });
    if (!proj || ![proj respondsToSelector:@selector(addNewClipToSceneAtIndex:clipURL:sourceClipIndex:makeActive:image:frameTimes:)]) return NO;
    __block BOOL ok = NO;
    BOOL called = VSTry(^{
        ok = [proj addNewClipToSceneAtIndex:sc clipURL:job.reuseURL sourceClipIndex:-1 makeActive:YES image:nil frameTimes:job.reuseFrameTimes];
    });
    return called && ok;
}

// Lấy frame times của clip đang hoạt động ở phân cảnh sc (dùng cho lần thêm clip sau).
static void VSCaptureFrameTimes(VSBatchJob *job, NSUInteger sc) {
    id rvc = job.reviewVC;
    __block id proj = nil;
    VSTry(^{ proj = [rvc project]; });
    if (!proj) return;
    VSTry(^{
        NSUInteger active = [proj activeClipIndexForSceneIndex:sc];
        job.reuseFrameTimes = [proj frameTimesForSceneIndex:sc clipIndex:active];
    });
}

static void VSJobStep(VSBatchJob *job) {
    if (job.finished) return;
    if (job.runId != g_runIdentifier) { job.finished = YES; return; }
    if (job.index >= job.total) { VSJobFinish(job, nil); return; }

    NSUInteger o = job.index;
    NSUInteger sc = job.startScene + o;
    NSString *label = [NSString stringWithFormat:@"Phân cảnh %lu", (unsigned long)(sc + 1)];
    VSStatus([NSString stringWithFormat:@"%@ (%lu/%lu): mở…", label, (unsigned long)(o + 1), (unsigned long)job.total]);

    job.reusedThisScene = NO;
    if (o > 0 && VS_REUSE_MEDIA && job.reuseURL) {
        job.reusedThisScene = VSAddReuseClip(job, sc);
    }

    VSOpenScene(sc, job.reviewVC, job.runId, ^(id editor) {
        if (job.runId != g_runIdentifier) { job.finished = YES; return; }
        if (!editor) { VSJobFinish(job, [label stringByAppendingString:@": không mở được editor"]); return; }
        __weak id wEd = editor;
        VSStatus([label stringByAppendingString:@": nhập preset…"]);
        VSImportPreset(editor, job.presets[o], job.codes[o], job.runId, ^(NSString *err) {
            if (job.runId != g_runIdentifier) { job.finished = YES; return; }
            if (err) { VSJobFinish(job, [NSString stringWithFormat:@"%@: %@", label, err]); return; }
            VSAfterMS(500, ^{
                if (job.runId != g_runIdentifier) { job.finished = YES; return; }
                id ed = wEd;
                if (!VSEditorAlive(ed)) { VSJobFinish(job, [label stringByAppendingString:@": editor đã bị đóng"]); return; }
                id engine = [ed getMultiLayerEngine];
                NSArray<NSNumber *> *layers = VSFillableLayers(engine, YES);
                if (layers.count == 0) { VSJobFinish(job, [label stringByAppendingString:@": preset không có lớp video/ảnh"]); return; }

                BOOL allLoaded = YES;
                for (NSNumber *n in layers) if (!VSLayerLoaded(engine, n.unsignedIntegerValue)) { allLoaded = NO; break; }

                // Phân cảnh sau đã được điền từ clip đã thêm: không mở bảng chọn nữa.
                if (job.reusedThisScene && allLoaded) {
                    VSCreateAndAdvance(job, ed, label);
                    return;
                }

                VSStatus([label stringByAppendingString:@": chọn ảnh/video…"]);
                BOOL firstScene = (o == 0);
                [VSLayerFiller fillLayers:layers editor:ed runId:job.runId requirePicker:YES completion:^(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stop) {
                    if (job.runId != g_runIdentifier) { job.finished = YES; return; }
                    if (stop) { VSJobFinish(job, [NSString stringWithFormat:@"%@: %@", label, stop]); return; }
                    if (unconfirmed.count) { VSJobFinish(job, [NSString stringWithFormat:@"%@: còn %lu lớp chưa xác nhận", label, (unsigned long)unconfirmed.count]); return; }
                    if (firstScene && VS_REUSE_MEDIA && !job.reuseURL) {
                        NSURL *u = VSLayerAssetURL([wEd getMultiLayerEngine], layers.firstObject.unsignedIntegerValue);
                        if (u) {
                            job.reuseURL = u;
                            VSCaptureFrameTimes(job, sc);
                        }
                    }
                    id edDone = wEd;
                    if (!VSEditorAlive(edDone)) { VSJobFinish(job, [label stringByAppendingString:@": editor bị đóng trước khi Tạo"]); return; }
                    VSCreateAndAdvance(job, edDone, label);
                }];
            });
        });
    });
}

static void VSCreateAndAdvance(VSBatchJob *job, id ed, NSString *label) {
    VSStatus([label stringByAppendingString:@": đang Tạo…"]);
    VSWaitAndCreate(ed, job.runId, ^(NSString *err) {
        if (job.runId != g_runIdentifier) { job.finished = YES; return; }
        if (err) { VSJobFinish(job, [NSString stringWithFormat:@"%@: %@", label, err]); return; }
        job.okCount += 1;
        VSPoll(job.runId, 100, 120, ^BOOL{ return VSFindVC(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
            if (job.runId != g_runIdentifier) { job.finished = YES; return; }
            if (!back) { VSJobFinish(job, @"Không quay lại được màn hình phân cảnh"); return; }
            job.index += 1;
            VSAfterMS(300, ^{ VSJobStep(job); });
        });
    });
}

// ============================================================================
// PHẦN 10 — TRẠNG THÁI, HUD, NÚT NỔI
// ============================================================================

@interface VSOverlayWindow : UIWindow
@end
@implementation VSOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

static UIWindow *g_overlayWindow = nil;
static UILabel *g_hud = nil;
static UIButton *g_beatButton = nil;
static UIButton *g_mergeButton = nil;

static UIWindow *g_overlayToolWindowRef(void) { return g_overlayWindow; }

static void VSStatus(NSString *msg) {
    if (!g_hud) return;
    g_hud.text = msg ?: @"";
    g_hud.hidden = (msg.length == 0);
}

static void VSStopAll(void) {
    g_runIdentifier++;
    g_busy = NO;
    g_autoConfirmPopups = NO;
    g_onLayerAddedHandler = nil;
    g_activeFiller = nil;
    VSSetRunFlags(NO);
    VSStatus(nil);
}

static void VSEndRun(void) {
    g_runIdentifier++;
    g_busy = NO;
    g_autoConfirmPopups = NO;
    g_onLayerAddedHandler = nil;
    g_activeFiller = nil;
    VSSetRunFlags(NO);
    VSStatus(nil);
}

static UIButton *VSMakeButton(NSString *title, SEL action, id target) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.backgroundColor = [UIColor colorWithRed:0.10 green:0.08 blue:0.05 alpha:0.92];
    b.layer.cornerRadius = 14;
    b.layer.borderWidth = 1.2;
    b.layer.borderColor = [UIColor colorWithRed:0.86 green:0.71 blue:0.42 alpha:1.0].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithRed:0.86 green:0.71 blue:0.42 alpha:1.0] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    b.hidden = YES;
    return b;
}

@interface VSButtonTarget : NSObject
- (void)beatTapped;
- (void)mergeTapped;
@end

static VSButtonTarget *g_buttonTarget = nil;

// ============================================================================
// PHẦN 11 — CHỨC NĂNG 2: CHIA ĐOẠN THEO NHỊP
// ============================================================================

static void VSRunBeatSplit(void) {
    if (g_busy) { VSAlert(@"Đang chạy", @"Đợi tác vụ hiện tại xong."); return; }
    id rvc = VSFindVC(@"VideoReviewEditVC");
    if (!rvc) { VSAlert(@"Sai vị trí", @"Mở bảng chia đoạn trước."); return; }
    id sv = VSKVC(rvc, @"splitView");
    if (!sv) { VSAlert(@"Không tìm thấy", @"Không tìm thấy bảng chia đoạn."); return; }

    g_runIdentifier++;
    NSUInteger runId = g_runIdentifier;
    g_busy = YES;
    VSStatus(@"Đang chia theo nhịp…");

    __block NSUInteger count = 0;
    __block CMTime last = kCMTimeInvalid;
    __block BOOL goOn = YES;
    __weak id wSv = sv;
    __block void (^step)(void) = nil;

    void (^finish)(NSString *) = ^(NSString *msg) {
        goOn = NO;
        step = nil;
        if (runId != g_runIdentifier) return;
        VSEndRun();
        VSAlert(@"Chia đoạn", msg);
    };

    if (!VSTry(^{ if (![wSv beatModeOn]) [wSv toggleBeatMode]; [wSv gotoTime:kCMTimeZero]; })) {
        finish(@"Không bật được chế độ nhịp");
        return;
    }

    step = ^{
        if (!goOn || runId != g_runIdentifier) { step = nil; return; }
        id s = wSv;
        if (!s) { finish(@"Mất bảng chia đoạn"); return; }
        __block BOOL hasNext = NO;
        BOOL ok = VSTry(^{ hasNext = [s hasNextBeat]; if (hasNext) [s jumpToNextBeat]; });
        if (!ok || !hasNext) {
            if (count == 0) { finish(@"Không có nhịp nào"); return; }
            VSAfterMS(200, ^{
                if (runId != g_runIdentifier) return;
                BOOL done = VSTry(^{ [wSv doSplit]; });
                finish(done ? [NSString stringWithFormat:@"Đã chia %lu điểm", (unsigned long)count] : @"Lỗi khi chia");
            });
            return;
        }
        VSAfterMS(60, ^{
            if (runId != g_runIdentifier) { step = nil; return; }
            __block CMTime cur = kCMTimeInvalid;
            id s2 = wSv;
            if (s2) cur = VSCurrentTime(s2);
            if (CMTIME_IS_VALID(cur) && (CMTIME_IS_INVALID(last) || CMTimeCompare(cur, last) > 0)) {
                VSTry(^{ [s2 setSplitPoint]; });
                last = cur;
                count++;
                VSStatus([NSString stringWithFormat:@"%lu điểm chia…", (unsigned long)count]);
            }
            if (step) step();
        });
    };
    step();
}

// ============================================================================
// PHẦN 12 — CHỨC NĂNG 4: NÚT TRONG BẢNG HỢP NHẤT
// ============================================================================

API_AVAILABLE(ios(14.0))
@interface VSPickerDelegate : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, copy) void (^onPicked)(NSArray<PHPickerResult *> *results);
@property (nonatomic, assign) NSUInteger count;
@end
API_AVAILABLE(ios(14.0))
@implementation VSPickerDelegate
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    void (^cb)(NSArray<PHPickerResult *> *) = self.onPicked;
    self.onPicked = nil;
    if (cb) cb(results);
}
@end

static id g_pickerDelegate = nil;

static void VSStartMergeBatch(void) {
    if (g_busy) { VSAlert(@"Đang chạy", @"Đợi tác vụ hiện tại xong."); return; }
    id rvc = VSFindVC(@"VideoReviewEditVC");
    if (!rvc) { VSAlert(@"Sai vị trí", @"Mở bảng Hợp nhất / phân cảnh trước."); return; }

    // Số phân cảnh lấy từ khoảng đã chọn trong bảng Hợp nhất.
    NSInteger start = -1, last = -1;
    id so = VSKVC(rvc, @"startScene");
    id lo = VSKVC(rvc, @"lastScene");
    if ([so respondsToSelector:@selector(integerValue)]) start = [so integerValue];
    if ([lo respondsToSelector:@selector(integerValue)]) last = [lo integerValue];
    if (start < 0 || last < start) {
        VSAlert(@"Chưa chọn đoạn", @"Chọn phân cảnh đầu và cuối trong bảng Hợp nhất, rồi bấm nút này.");
        return;
    }
    NSUInteger count = (NSUInteger)(last - start + 1);

    g_runIdentifier++;
    NSUInteger runId = g_runIdentifier;
    g_busy = YES;
    __block NSUInteger origScene = 0;
    VSTry(^{ origScene = [rvc lastViewedSceneIndex]; });

    NSString *msg = [NSString stringWithFormat:@"Chọn đúng %lu ảnh QR (phân cảnh %ld đến %ld). Ảnh được chọn theo thứ tự.", (unsigned long)count, (long)(start + 1), (long)(last + 1)];
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = (NSInteger)count;
        cfg.filter = [PHPickerFilter imagesFilter];
        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        VSPickerDelegate *del = [VSPickerDelegate new];
        del.count = count;
        del.onPicked = ^(NSArray<PHPickerResult *> *results) {
            g_pickerDelegate = nil;
            if (runId != g_runIdentifier) return;
            if (results.count != count) {
                VSEndRun();
                VSAlert(@"Sai số lượng", [NSString stringWithFormat:@"Cần đúng %lu ảnh, bạn chọn %lu.", (unsigned long)count, (unsigned long)results.count]);
                return;
            }
            VSLoadImages(results, ^(NSArray *images) {
                VSCollectCodes(images, runId, ^(NSArray *presets, NSArray *codes, NSString *err) {
                    if (runId != g_runIdentifier) return;
                    if (err) { VSEndRun(); VSAlert(@"Lỗi QR", err); return; }
                    VSTry(^{ [rvc closeMergePanel]; });
                    VSBatchJob *job = [VSBatchJob new];
                    job.presets = presets;
                    job.codes = codes;
                    job.startScene = (NSUInteger)start;
                    job.total = count;
                    job.index = 0;
                    job.okCount = 0;
                    job.origScene = origScene;
                    job.runId = runId;
                    job.reviewVC = rvc;
                    g_autoConfirmPopups = YES;
                    VSJobStep(job);
                });
            });
        };
        g_pickerDelegate = del;
        pk.delegate = del;
        VSPresent(pk);
    } else {
        VSEndRun();
        VSAlert(@"Thiếu iOS", @"Cần iOS 14 trở lên để chọn nhiều ảnh QR.");
    }
    VSStatus(msg);
}

static void VSPresent(UIViewController *vc) {
    UIViewController *top = VSTopVC();
    if (!top) return;
    [top presentViewController:vc animated:YES completion:nil];
}

static void VSLoadImages(NSArray<PHPickerResult *> *results, void (^done)(NSArray *images)) {
    if (@available(iOS 14.0, *)) {
        NSMutableArray *images = [NSMutableArray arrayWithCapacity:results.count];
        for (NSUInteger i = 0; i < results.count; i++) [images addObject:[NSNull null]];
        dispatch_group_t group = dispatch_group_create();
        for (NSUInteger i = 0; i < results.count; i++) {
            NSItemProvider *p = results[i].itemProvider;
            if (![p canLoadObjectOfClass:[UIImage class]]) continue;
            dispatch_group_enter(group);
            [p loadObjectOfClass:[UIImage class] completionHandler:^(id obj, NSError *err) {
                @synchronized (images) {
                    images[i] = [obj isKindOfClass:[UIImage class]] ? obj : [NSNull null];
                }
                dispatch_group_leave(group);
            }];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{ done([images copy]); });
    }
}

// ============================================================================
// PHẦN 13 — HOOK: CHỈ ĐỂ HIỆN/ẨN NÚT VÀ CHẶN HỘP THOẠI KHI TỰ CHẠY
// ============================================================================

static IMP g_origShowSplit = NULL, g_origCloseSplit = NULL, g_origShowMerge = NULL, g_origCloseMerge = NULL;
static IMP g_origConfirmAdd5 = NULL, g_origConfirmAdd4 = NULL;
static IMP g_origShowImportConfirm = NULL, g_origOverwrite1 = NULL, g_origShowLayerMenu = NULL;
static IMP g_origImportNew = NULL, g_origImportOld = NULL, g_origPopupMove = NULL;

static BOOL VSSwizzle(NSString *cls, SEL sel, id block, IMP *orig) {
    Class c = NSClassFromString(cls);
    if (!c || *orig != NULL) return *orig != NULL;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    IMP newImp = imp_implementationWithBlock(block);
    if (class_addMethod(c, sel, newImp, method_getTypeEncoding(m))) *orig = method_getImplementation(m);
    else *orig = method_setImplementation(m, newImp);
    return YES;
}

static void VSShowButtonLater(UIButton *b, BOOL show) {
    if (!b) return;
    VSAfterMS(show ? 600 : 0, ^{ b.hidden = !show; });
}

static void VSInstallHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_popupTable = [NSHashTable weakObjectsHashTable];

        VSSwizzle(@"CustomPopup", @selector(didMoveToWindow), ^(id selfObj) {
            if (g_origPopupMove) ((void (*)(id, SEL))g_origPopupMove)(selfObj, @selector(didMoveToWindow));
            if ([selfObj isKindOfClass:[UIView class]] && ((UIView *)selfObj).window) [g_popupTable addObject:selfObj];
        }, &g_origPopupMove);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), ^(id selfObj, id preset, id action, NSInteger frames) {
            if (g_origImportNew) ((void (*)(id, SEL, id, id, NSInteger))g_origImportNew)(selfObj, @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), preset, action, frames);
            g_presetImportEventCounter++;
        }, &g_origImportNew);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(importOldPreset:), ^(id selfObj, id preset) {
            if (g_origImportOld) ((void (*)(id, SEL, id))g_origImportOld)(selfObj, @selector(importOldPreset:), preset);
            g_presetImportEventCounter++;
        }, &g_origImportOld);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(showLayerActionMenu:newLayer:), ^(id selfObj, NSUInteger n, BOOL isNew) {
            if (g_suppressLayerActionMenu) return;
            if (g_origShowLayerMenu) ((void (*)(id, SEL, NSUInteger, BOOL))g_origShowLayerMenu)(selfObj, @selector(showLayerActionMenu:newLayer:), n, isNew);
        }, &g_origShowLayerMenu);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(showImportConfirmation), ^BOOL(id selfObj) {
            if (g_vsaAutomating) return NO;
            if (g_origShowImportConfirm) return ((BOOL (*)(id, SEL))g_origShowImportConfirm)(selfObj, @selector(showImportConfirmation));
            return NO;
        }, &g_origShowImportConfirm);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:), ^(id selfObj, id object, BOOL show) {
            if (g_vsaAutomating && [selfObj respondsToSelector:@selector(overwrite:isAbleToShowTheLayerActionMenu:)]) {
                [selfObj overwrite:object isAbleToShowTheLayerActionMenu:NO];
                return;
            }
            if (g_origOverwrite1) ((void (*)(id, SEL, id, BOOL))g_origOverwrite1)(selfObj, @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:), object, show);
        }, &g_origOverwrite1);

        // Chỉ báo tín hiệu "đã thêm lớp". Không truyền / lưu tham số nào (tham số đầu là SEL).
        VSSwizzle(@"MultiLayerWizEffectVC", @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:), ^(id selfObj, SEL makeSel, id o1, id o2, id o3, BOOL able) {
            if (g_origConfirmAdd5) ((void (*)(id, SEL, SEL, id, id, id, BOOL))g_origConfirmAdd5)(selfObj, @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:), makeSel, o1, o2, o3, able);
            void (^h)(void) = g_onLayerAddedHandler;
            if (h) VSGuard(^{ h(); });
        }, &g_origConfirmAdd5);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(confirmAddingLayer:object:object2:object3:), ^(id selfObj, SEL makeSel, id o1, id o2, id o3) {
            if (g_origConfirmAdd4) ((void (*)(id, SEL, SEL, id, id, id))g_origConfirmAdd4)(selfObj, @selector(confirmAddingLayer:object:object2:object3:), makeSel, o1, o2, o3);
            void (^h)(void) = g_onLayerAddedHandler;
            if (h) VSGuard(^{ h(); });
        }, &g_origConfirmAdd4);

        VSSwizzle(@"VideoReviewEditVC", @selector(showSplitScene), ^(id selfObj) {
            if (g_origShowSplit) ((void (*)(id, SEL))g_origShowSplit)(selfObj, @selector(showSplitScene));
            VSShowButtonLater(g_beatButton, YES);
        }, &g_origShowSplit);

        VSSwizzle(@"VideoReviewEditVC", @selector(closeSplitPanel), ^(id selfObj) {
            VSShowButtonLater(g_beatButton, NO);
            if (g_origCloseSplit) ((void (*)(id, SEL))g_origCloseSplit)(selfObj, @selector(closeSplitPanel));
        }, &g_origCloseSplit);

        VSSwizzle(@"VideoReviewEditVC", @selector(showMergeScenes), ^(id selfObj) {
            if (g_origShowMerge) ((void (*)(id, SEL))g_origShowMerge)(selfObj, @selector(showMergeScenes));
            VSShowButtonLater(g_mergeButton, YES);
        }, &g_origShowMerge);

        VSSwizzle(@"VideoReviewEditVC", @selector(closeMergePanel), ^(id selfObj) {
            VSShowButtonLater(g_mergeButton, NO);
            if (g_origCloseMerge) ((void (*)(id, SEL))g_origCloseMerge)(selfObj, @selector(closeMergePanel));
        }, &g_origCloseMerge);
    });
}

@implementation VSButtonTarget
- (void)beatTapped { VSRunBeatSplit(); }
- (void)mergeTapped { VSStartMergeBatch(); }
@end

// ============================================================================
// PHẦN 14 — KHỞI TẠO
// ============================================================================

static void VSSetupOverlay(void) {
    if (g_overlayWindow) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    CGRect bounds = UIScreen.mainScreen.bounds;
    VSOverlayWindow *w = scene ? [[VSOverlayWindow alloc] initWithWindowScene:scene] : [[VSOverlayWindow alloc] initWithFrame:bounds];
    w.frame = bounds;
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = root;

    g_hud = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, bounds.size.width - 32, 32)];
    g_hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    g_hud.textColor = UIColor.whiteColor;
    g_hud.textAlignment = NSTextAlignmentCenter;
    g_hud.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    g_hud.layer.cornerRadius = 10;
    g_hud.clipsToBounds = YES;
    g_hud.hidden = YES;
    g_hud.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [root.view addSubview:g_hud];

    g_buttonTarget = [VSButtonTarget new];
    g_beatButton = VSMakeButton(@"★ Chia nhịp", @selector(beatTapped), g_buttonTarget);
    g_beatButton.frame = CGRectMake(bounds.size.width - 150, bounds.size.height - 230, 130, 36);
    g_beatButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [root.view addSubview:g_beatButton];

    g_mergeButton = VSMakeButton(@"★ Nhập QR + ảnh", @selector(mergeTapped), g_buttonTarget);
    g_mergeButton.frame = CGRectMake((bounds.size.width - 180) / 2.0, bounds.size.height - 230, 180, 36);
    g_mergeButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    [root.view addSubview:g_mergeButton];

    w.hidden = NO;
    g_overlayWindow = w;
}

__attribute__((constructor)) static void VSToolInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) {
                @autoreleasepool {
                    if (!NSClassFromString(@"MultiLayerWizEffectVC")) return;
                    VSGuard(^{
                        VSInstallHooks();
                        VSSetupOverlay();
                    });
                }
            }];
        }
    });
}
