// VideoStarTool.m
// Runtime Automation Bot for Video Star 14.3.3 (build 1809)
// Logic: 1-Chạm Thay Media + Nhập QR Hàng loạt + Smart Popup Handler

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define VS_MAX_LAYERS 30
#define VSLog(fmt, ...) NSLog(@"[VideoStarTool] " fmt, ##__VA_ARGS__)

// ============================================================================
// PRIVATE API — đã đối chiếu header CustomPopup/MultiLayerEngine/QRCodeManager
// ============================================================================
@interface NSObject (VSPrivate)
// MultiLayerWizEffectVC
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
// MultiLayerEngine
- (id)layerAtLayerNum:(NSUInteger)n;
- (NSInteger)numActiveLayers;
- (void)reloadLayerEffects;
// MultiLayerLayer
- (id)imageGenerator;
- (id)layerImage;
- (id)asset;
- (id)layerDrawing;
- (id)layerZaps;
- (id)layerGIF;
// VideoReviewEditVC
- (NSUInteger)navSceneIndex;
- (id)project;
- (NSUInteger)sceneIndex;
- (void)showMergeScenes;
- (void)closeMergePanel;
- (void)showMultiLayer;
- (void)showSplitScene;
- (NSUInteger)lastViewedSceneIndex;
- (void)setLastViewedSceneIndex:(NSUInteger)i;
- (BOOL)isEnoughStorageAvailableForSplit;
// project
- (NSUInteger)sceneCount;
- (BOOL)sceneHasAtLeastOneClipWithSceneIndex:(NSUInteger)i;
- (NSUInteger)clipCountForSceneIndex:(NSUInteger)i;
- (id)fileManager;
- (id)clipURLForSceneIndex:(NSUInteger)i clipIndex:(NSUInteger)c;
// MultiSplitView
- (BOOL)beatModeOn;
- (void)toggleBeatMode;
- (BOOL)hasNextBeat;
- (void)jumpToNextBeat;
- (void)setSplitPoint;
- (void)doSplit;
- (void)gotoTime:(CMTime)t;
// QRCodeManager
+ (id)sharedInstance;
- (void)selectedCode:(id)code withImageData:(id)data;
- (void)startQRImport;
// CustomPopup
- (void)simulateButtonPressButtonWithTitle:(id)title;
@end

// ============================================================================
// UTILITIES
// ============================================================================
static NSUInteger g_run;

static void VSAfter(int64_t ms, dispatch_block_t b) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), dispatch_get_main_queue(), b);
}

static CMTime VSCurrentTime(id obj) {
    if (!obj) return kCMTimeInvalid;
    SEL sel = @selector(currentTime);
    if (![obj respondsToSelector:sel]) return kCMTimeInvalid;
    CMTime (*fn)(id, SEL) = (CMTime (*)(id, SEL))[obj methodForSelector:sel];
    return fn(obj, sel);
}

static void VSSetQRDelegate(id qr, id delegate) {
    if (!qr) return;
    SEL sel = @selector(setDelegate:);
    if (![qr respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id))[qr methodForSelector:sel])(qr, sel, delegate);
}

static id VSValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; } @catch (...) { return nil; }
}

static BOOL VSIsKind(id obj, NSString *name) {
    Class c = NSClassFromString(name);
    return obj && c && [obj isKindOfClass:c];
}

// Poll bất đồng bộ — dùng cho mọi bước chờ trạng thái app
static void VSPoll(NSUInteger rid, int64_t ms, NSUInteger tries, BOOL (^cond)(void), void (^done)(BOOL ok)) {
    if (rid != g_run) return;
    BOOL ok = NO;
    @try { ok = cond(); } @catch (NSException *e) { VSLog(@"poll exception: %@", e.reason ?: e.name); }
    if (ok) { done(YES); return; }
    if (tries == 0) { done(NO); return; }
    VSAfter(ms, ^{ VSPoll(rid, ms, tries - 1, cond, done); });
}

// Duyệt VC hierarchy để tìm class theo tên
static UIViewController *VSFindVCIn(UIViewController *vc, Class cls, int depth) {
    if (!vc || depth > 14) return nil;
    UIViewController *r = nil;
    if (vc.presentedViewController && (r = VSFindVCIn(vc.presentedViewController, cls, depth + 1))) return r;
    if ([vc isKindOfClass:UINavigationController.class]) {
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers.reverseObjectEnumerator)
            if ((r = VSFindVCIn(c, cls, depth + 1))) return r;
    }
    if ([vc isKindOfClass:UITabBarController.class] && (r = VSFindVCIn(((UITabBarController *)vc).selectedViewController, cls, depth + 1))) return r;
    for (UIViewController *c in vc.childViewControllers.reverseObjectEnumerator)
        if ((r = VSFindVCIn(c, cls, depth + 1))) return r;
    if ([vc isKindOfClass:cls] && vc.isViewLoaded && vc.view.window) return vc;
    return nil;
}

@class VSTool;
static UIWindow *g_toolWindow;

static UIViewController *VSFindVC(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (w == g_toolWindow || w.hidden) continue;
        UIViewController *r = VSFindVCIn(w.rootViewController, cls, 0);
        if (r) return r;
    }
    return nil;
}

// ============================================================================
// SMART POPUP HANDLER — tự động bấm "Trùng khớp"/"Match" (hỗ trợ cả EN/VI)
// ============================================================================
static NSString *VSL(NSString *en) {
    return [NSBundle.mainBundle localizedStringForKey:en value:en table:nil];
}

static id g_lastPressedPopup;
static CFAbsoluteTime g_lastPressedAt;
typedef NS_ENUM(NSInteger, VSPopupResult) { VSPopupNone = 0, VSPopupPressed, VSPopupBlocked };
static NSHashTable *g_popups;

static NSArray *VSVisiblePopups(id editor) {
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *key in @[@"ourPopup", @"warningPopup"]) { id p = editor ? VSValue(editor, key) : nil; if (p) [all addObject:p]; }
    for (id p in g_popups.allObjects) if (![all containsObject:p]) [all addObject:p];
    NSMutableArray *vis = [NSMutableArray array];
    for (id p in all) {
        if (!VSIsKind(p, @"CustomPopup")) continue;
        UIView *dim = VSValue(p, @"dimView");
        if ([dim isKindOfClass:UIView.class] && dim.window) [vis addObject:p];
    }
    return vis;
}

static BOOL VSPopupLooksLikePurchase(id popup) {
    NSString *msg = [VSValue(popup, @"_message") description].lowercaseString ?: @"";
    NSString *ttl = [VSValue(popup, @"_title") description].lowercaseString ?: @"";
    NSString *all = [msg stringByAppendingString:ttl];
    for (NSString *w in @[@"purchase", @"subscription", @"unlock pro", @"pro pack", @"restore purchase",
                          @"mua gói", @"khôi phục", @"đăng ký", @"nâng cấp"]) {
        if ([all containsString:w]) return YES;
    }
    return NO;
}

static VSPopupResult VSHandleEditorPopups(id editor) {
    // Ưu tiên theo document: "Trùng khớp" / "Match" / "Original Preset Layers"
    NSArray *prefer = @[
        @"Trùng khớp", @"Match",
        @"Original Preset Layers", @"Các lớp cài đặt sẵn gốc",
        @"Fit", @"Vừa khung",
        @"Continue", @"Tiếp tục",
        @"OK", @"Đồng ý"
    ];
    for (id popup in VSVisiblePopups(editor)) {
        if (VSPopupLooksLikePurchase(popup)) return VSPopupBlocked;
        if (popup == g_lastPressedPopup && CFAbsoluteTimeGetCurrent() - g_lastPressedAt < 0.4) return VSPopupPressed;
        
        NSArray *titles = VSValue(popup, @"_buttonStrings");
        NSArray *buttons = VSValue(popup, @"_buttons");
        for (NSString *en in prefer) {
            NSString *loc = VSL(en);
            NSString *hit = nil;
            for (id t in titles)
                if ([t isKindOfClass:NSString.class] && ([t localizedCaseInsensitiveContainsString:loc] || [t localizedCaseInsensitiveContainsString:en]))
                    { hit = t; break; }
            if (!hit) for (id b in buttons) {
                NSString *ct = [b isKindOfClass:UIButton.class] ? ((UIButton *)b).currentTitle : nil;
                if (ct && ([ct localizedCaseInsensitiveContainsString:loc] || [ct localizedCaseInsensitiveContainsString:en]))
                    { hit = ct; break; }
            }
            if (!hit) continue;
            
            g_lastPressedPopup = popup; g_lastPressedAt = CFAbsoluteTimeGetCurrent();
            @try {
                if ([popup respondsToSelector:@selector(simulateButtonPressButtonWithTitle:)]) {
                    [popup simulateButtonPressButtonWithTitle:hit];
                } else {
                    for (id b in buttons)
                        if ([b isKindOfClass:UIButton.class] && [((UIButton *)b).currentTitle localizedCaseInsensitiveContainsString:hit]) {
                            [(UIButton *)b sendActionsForControlEvents:UIControlEventTouchUpInside]; break;
                        }
                }
                VSLog(@"popup pressed: '%@'", hit);
            } @catch (NSException *e) { VSLog(@"popup press exception: %@", e.reason ?: e.name); }
            return VSPopupPressed;
        }
    }
    return VSPopupNone;
}

static BOOL VSEditorHasVisiblePopup(id editor) { return VSVisiblePopups(editor).count > 0; }

// ============================================================================
// LAYER INFO — chỉ chấp nhận lớp ảnh/video (bỏ 3D/text/color/drawing/zap/gif)
// ============================================================================
static id VSGenMedia(id layer) {
    id gen = [layer respondsToSelector:@selector(imageGenerator)] ? [layer imageGenerator] : nil;
    if (!gen) return nil;
    return [gen respondsToSelector:@selector(asset)] && [gen asset] ? [gen asset] : [gen layerImage];
}

static NSDictionary *VSLayerInfo(id engine, NSUInteger n) {
    @try {
        id layer = [engine layerAtLayerNum:n];
        if (!layer) return nil;
        if (VSValue(layer, @"layer3D") || VSValue(layer, @"layer3d")) return nil;
        id gen = [layer respondsToSelector:@selector(imageGenerator)] ? [layer imageGenerator] : nil;
        if (!gen) return nil;
        if ([gen layerDrawing] || [gen layerZaps] || [gen layerGIF]) return nil;
        if (VSValue(gen, @"textView") || VSValue(gen, @"fillColor") ||
            VSValue(gen, @"isTextLayer") || VSValue(gen, @"isColorLayer") ||
            VSValue(gen, @"is3DLayer") || VSValue(gen, @"isDrawingLayer")) return nil;

        id asset = [gen respondsToSelector:@selector(asset)] ? [gen asset] : nil;
        if ([asset isKindOfClass:AVAsset.class]) return @{@"layerNum": @(n), @"kind": @"video"};

        UIImage *img = [gen layerImage];
        if ([img isKindOfClass:UIImage.class] && img.size.width > 1) return @{@"layerNum": @(n), @"kind": @"image"};
    } @catch (...) {}
    return nil;
}

// ============================================================================
// QR — CIDetector độ chính xác cao
// ============================================================================
static NSString *VSLastQRPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"VideoStarTool_LastQR.png"];
}
static void VSRememberLastQR(NSData *data) {
    UIImage *img = [data isKindOfClass:NSData.class] ? [UIImage imageWithData:data] : nil;
    NSData *png = img ? UIImagePNGRepresentation(img) : nil;
    if (png.length) [png writeToFile:VSLastQRPath() atomically:YES];
}
static UIImage *VSLoadLastQR(void) {
    NSData *d = [NSData dataWithContentsOfFile:VSLastQRPath()];
    return d.length ? [UIImage imageWithData:d] : nil;
}
static NSString *VSDecodeQR(UIImage *img) {
    CIImage *ci = img ? [[CIImage alloc] initWithImage:img] : nil;
    if (!ci) return nil;
    CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil
                                         options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
    for (CIFeature *f in [det featuresInImage:ci])
        if ([f isKindOfClass:CIQRCodeFeature.class] && ((CIQRCodeFeature *)f).messageString.length)
            return ((CIQRCodeFeature *)f).messageString;
    return nil;
}

// ============================================================================
// HOOKS — lắng nghe sự kiện chọn media, chọn code, popup
// ============================================================================
static IMP g_origPicked, g_origSelectedCode, g_origImportNew, g_origImportOld, g_origPopupShow;
static NSUInteger g_importCount;
static void (^g_pickedHandler)(id editor, id response);

static BOOL VSSwizzle(NSString *cls, SEL sel, id block, IMP *orig) {
    Class c = NSClassFromString(cls);
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    if (!m) { VSLog(@"hook unavailable: -[%@ %@]", cls, NSStringFromSelector(sel)); return NO; }
    if (*orig) return YES;
    *orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(block));
    return YES;
}

static void VSInstallHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_popups = [NSHashTable weakObjectsHashTable];

        // Hook chọn media (cho feature 1)
        VSSwizzle(@"MultiLayerWizEffectVC", @selector(pickedWithClipPickerResponse:), ^(id me, id resp) {
            ((void (*)(id, SEL, id))g_origPicked)(me, @selector(pickedWithClipPickerResponse:), resp);
            void (^h)(id, id) = g_pickedHandler;
            if (h) dispatch_async(dispatch_get_main_queue(), ^{ h(me, resp); });
        }, &g_origPicked);

        // Hook chọn code (lưu QR)
        VSSwizzle(@"QRCodeManager", @selector(selectedCode:withImageData:), ^(id me, id code, id data) {
            VSRememberLastQR(data);
            ((void (*)(id, SEL, id, id))g_origSelectedCode)(me, @selector(selectedCode:withImageData:), code, data);
        }, &g_origSelectedCode);

        // Đếm số lần import preset (cho feature 4)
        VSSwizzle(@"MultiLayerWizEffectVC", @selector(importNewPreset:keyFrameAction:qrDurationInFrames:),
                  ^(id me, id a, id b, NSInteger frames) {
            ((void (*)(id, SEL, id, id, NSInteger))g_origImportNew)(me, @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), a, b, frames);
            g_importCount++;
        }, &g_origImportNew);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(importOldPreset:), ^(id me, id a) {
            ((void (*)(id, SEL, id))g_origImportOld)(me, @selector(importOldPreset:), a);
            g_importCount++;
        }, &g_origImportOld);

        // Hook popup để tự bấm "Trùng khớp" ngay khi hiện
        VSSwizzle(@"CustomPopup", @selector(show), ^(id me) {
            ((void (*)(id, SEL))g_origPopupShow)(me, @selector(show));
            [g_popups addObject:me];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                VSHandleEditorPopups(nil);
            });
        }, &g_origPopupShow);

        VSLog(@"hooks installed");
    });
}

static BOOL VSReplayPicked(id editor, id response) {
    if (!editor || !response || !g_origPicked) return NO;
    @try { ((void (*)(id, SEL, id))g_origPicked)(editor, @selector(pickedWithClipPickerResponse:), response); return YES; }
    @catch (NSException *e) { VSLog(@"replay picked exception: %@", e.reason ?: e.name); }
    return NO;
}

// ============================================================================
// UI — VSPassWindow nổi, VSImageVC xem QR, VSQRCaptureDelegate
// ============================================================================
@interface VSPassWindow : UIWindow @end
@implementation VSPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

static UIColor *VSCyan(void) { return [UIColor colorWithRed:0.25 green:0.85 blue:0.96 alpha:1]; }
static UIColor *VSCardBG(void) { return [UIColor colorWithRed:0.02 green:0.09 blue:0.12 alpha:0.96]; }
static UIButton *VSOutlineButton(NSString *title, CGRect f) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = f; b.layer.cornerRadius = 8; b.layer.borderWidth = 1.2; b.layer.borderColor = VSCyan().CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:VSCyan() forState:UIControlStateNormal];
    [b setTitleColor:[VSCyan() colorWithAlphaComponent:0.35] forState:UIControlStateDisabled];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    return b;
}

@interface VSImageVC : UIViewController
@property (nonatomic, strong) UIImage *image;
@end
@implementation VSImageVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.88];
    UIImageView *iv = [[UIImageView alloc] initWithImage:self.image];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 12; iv.clipsToBounds = YES;
    iv.frame = CGRectInset(self.view.bounds, 24, 110);
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:iv];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 60, self.view.bounds.size.width, 30)];
    t.text = @"Code gần nhất đã nhập"; t.textColor = UIColor.whiteColor; t.textAlignment = NSTextAlignmentCenter;
    t.font = [UIFont boldSystemFontOfSize:18]; t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:t];
    NSArray *titles = @[@"Đóng", @"Chia sẻ / Lưu"];
    for (NSUInteger i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(24 + i * (self.view.bounds.size.width - 48) / 2, self.view.bounds.size.height - 90,
                             (self.view.bounds.size.width - 48) / 2, 44);
        b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }
}
- (void)tapped:(UIButton *)b {
    if (b.tag == 0) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[self.image] applicationActivities:nil];
    a.popoverPresentationController.sourceView = b;
    [self presentViewController:a animated:YES completion:nil];
}
@end

// Delegate giả cho QRCodeManager — chỉ nghe code, không tự nhập
@interface VSQRCaptureDelegate : NSObject
@property (nonatomic, copy) void (^onCode)(id preset, id code);
@end
@implementation VSQRCaptureDelegate
- (NSString *)qrLabel { return VSL(@"Multi-Layer"); }
- (NSString *)qrSetupLabel { return @""; }
- (NSString *)codePrefix { return @"n"; }
- (BOOL)validCode:(NSString *)code {
    return [code isKindOfClass:NSString.class] && ([code hasPrefix:@"m"] || [code hasPrefix:@"n"]);
}
- (void)importedData:(id)data code:(id)code {
    void (^cb)(id, id) = self.onCode;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(data, code); });
}
- (id)dataToShare { return nil; }
- (void)setActivityiPadPopup:(id)popup {}
- (id)qrImage { return nil; }
- (id)qrIcon { return nil; }
@end

// ============================================================================
// VSTOOL — điều phối 4 chức năng
// ============================================================================
@interface VSRootVC : UIViewController @end

@interface VSTool : NSObject
@property (nonatomic, strong) VSPassWindow *window;
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) VSQRCaptureDelegate *qrCapture;
@property (nonatomic, strong) NSMutableArray *msPresets;
@property (nonatomic, strong) NSMutableArray *msCodes;
@property (nonatomic) NSUInteger msStart, msCount, msOrigLast, msRid;
@property (nonatomic) NSInteger msCapturing;
@property (nonatomic, strong) UIView *msCard;
@property (nonatomic, copy) NSString *busyName;
@property (nonatomic, strong) id savedQRDelegate;
@property (nonatomic) BOOL savedQRDelegateValid;
@property (nonatomic, copy) void (^barOK)(void);
@property (nonatomic, copy) void (^barCancel)(void);
+ (instancetype)shared;
- (void)installIfNeeded;
- (void)clampFab;
- (void)msBackToCodePanel;
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

- (void)installIfNeeded {
    if (self.window) return;
    static BOOL didDelay = NO;
    if (!didDelay) {
        didDelay = YES;
        VSAfter(3000, ^{ [self installIfNeeded]; }); // chờ patch Pro kịp chạy
        return;
    }
    CGRect b = UIScreen.mainScreen.bounds;
    VSPassWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class]) { w = [[VSPassWindow alloc] initWithWindowScene:(UIWindowScene *)s]; break; }
    }
    if (!w) w = [[VSPassWindow alloc] initWithFrame:b];
    w.frame = b; w.windowLevel = UIWindowLevelAlert + 100; w.backgroundColor = UIColor.clearColor;
    VSRootVC *root = [VSRootVC new];
    root.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = root;

    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(b.size.width - 64, b.size.height * 0.35, 48, 48);
    fab.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:0.82];
    fab.layer.cornerRadius = 24;
    fab.layer.borderWidth = 1.5; fab.layer.borderColor = VSCyan().CGColor;
    [fab setTitle:@"VS" forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [fab setTitleColor:VSCyan() forState:UIControlStateNormal];
    [fab addTarget:self action:@selector(fabTapped) forControlEvents:UIControlEventTouchUpInside];
    [fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fabPan:)]];
    [root.view addSubview:fab];

    UILabel *st = [[UILabel alloc] init];
    st.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    st.textColor = UIColor.whiteColor; st.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    st.textAlignment = NSTextAlignmentCenter; st.numberOfLines = 2;
    st.layer.cornerRadius = 10; st.clipsToBounds = YES; st.hidden = YES;
    [root.view addSubview:st];

    self.window = w; self.fab = fab; self.statusLabel = st;
    self.msCapturing = -1;
    g_toolWindow = w;
    w.hidden = NO;
    VSInstallHooks();
    VSLog(@"installed");
}

- (void)clampFab {
    UIView *v = self.window.rootViewController.view;
    UIEdgeInsets ins = v.safeAreaInsets;
    CGFloat hw = self.fab.bounds.size.width / 2;
    CGPoint c = self.fab.center;
    c.x = MIN(MAX(c.x, hw + 4), v.bounds.size.width - hw - 4);
    c.y = MIN(MAX(c.y, ins.top + hw + 4), v.bounds.size.height - ins.bottom - hw - 4);
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

- (void)status:(NSString *)text {
    UIView *root = self.window.rootViewController.view;
    self.statusLabel.text = text;
    CGFloat w = MIN(root.bounds.size.width - 32, 420);
    self.statusLabel.frame = CGRectMake((root.bounds.size.width - w) / 2, root.safeAreaInsets.top + 8, w, 40);
    self.statusLabel.hidden = (text.length == 0);
}

- (void)alert:(NSString *)msg { [self alert:msg title:@"VideoStarTool"]; }
- (void)alert:(NSString *)msg title:(NSString *)title {
    [self status:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self presenter] presentViewController:a animated:YES completion:nil];
}

- (void)hideBar { [self.bar removeFromSuperview]; self.bar = nil; }

- (UIView *)cardWithFrame:(CGRect)f title:(NSString *)title message:(NSString *)msg {
    UIView *card = [[UIView alloc] initWithFrame:f];
    card.backgroundColor = VSCardBG();
    card.layer.cornerRadius = 14; card.layer.borderWidth = 1.2; card.layer.borderColor = VSCyan().CGColor;
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, f.size.width - 32, 24)];
    t.text = title; t.textColor = VSCyan(); t.font = [UIFont boldSystemFontOfSize:17];
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, f.size.width - 32, 34)];
    m.text = msg; m.numberOfLines = 0; m.textColor = [UIColor colorWithWhite:0.85 alpha:1]; m.font = [UIFont systemFontOfSize:13];
    m.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:t]; [card addSubview:m];
    return card;
}

- (void)showBar:(NSString *)title message:(NSString *)msg ok:(NSString *)okTitle onOK:(void (^)(void))onOK onCancel:(void (^)(void))onCancel {
    [self hideBar];
    UIView *root = self.window.rootViewController.view;
    CGFloat w = MIN(root.bounds.size.width - 24, 460), h = 132;
    UIView *bar = [self cardWithFrame:CGRectMake((root.bounds.size.width - w) / 2, root.bounds.size.height - root.safeAreaInsets.bottom - h - 70, w, h) title:title message:msg];
    self.barOK = onOK; self.barCancel = onCancel;
    CGFloat bw = (w - 32 - 12) / 2;
    UIButton *c = VSOutlineButton(@"Hủy", CGRectMake(16, h - 52, bw, 38));
    c.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1].CGColor;
    [c setTitleColor:[UIColor colorWithWhite:0.78 alpha:1] forState:UIControlStateNormal];
    UIButton *o = VSOutlineButton(okTitle, CGRectMake(16 + bw + 12, h - 52, bw, 38));
    [c addTarget:self action:@selector(barCancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [o addTarget:self action:@selector(barOKTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:c]; [bar addSubview:o];
    [root addSubview:bar];
    self.bar = bar;
}

- (void)barOKTapped { void (^cb)(void) = self.barOK; self.barOK = nil; self.barCancel = nil; [self hideBar]; if (cb) cb(); }
- (void)barCancelTapped { void (^cb)(void) = self.barCancel; self.barOK = nil; self.barCancel = nil; [self hideBar]; if (cb) cb(); }

- (void)fabTapped {
    if (self.busyName) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Đang chạy" message:self.busyName preferredStyle:UIAlertControllerStyleAlert];
        if (self.msCard && self.msCard.hidden)
            [a addAction:[UIAlertAction actionWithTitle:@"Quay lại bảng nhập code" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self msBackToCodePanel]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Dừng" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [self stopRunQuiet]; [self alert:@"Đã dừng."]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Tiếp tục chạy" style:UIAlertActionStyleCancel handler:nil]];
        [[self presenter] presentViewController:a animated:YES completion:nil];
        return;
    }
    UIAlertController *m = [UIAlertController alertControllerWithTitle:@"VideoStarTool" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [m addAction:[UIAlertAction actionWithTitle:@"1. Auto nhập ảnh vào các lớp" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self runReplaceLayers]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"2. Hiển thị code gần nhất" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self runLastCode]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"3. Auto chia beat" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self runBeatSplit]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"4. Auto nhập code + ảnh vào phân cảnh" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self runMultiScene]; }]];
    [m addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    m.popoverPresentationController.sourceView = self.fab;
    m.popoverPresentationController.sourceRect = self.fab.bounds;
    [[self presenter] presentViewController:m animated:YES completion:nil];
}

- (NSUInteger)beginRun:(NSString *)name status:(NSString *)text {
    g_run++;
    self.busyName = name;
    self.fab.alpha = 0.6;
    [self status:text];
    return g_run;
}

- (void)restoreQRDelegate {
    if (!self.savedQRDelegateValid) return;
    id qr = [NSClassFromString(@"QRCodeManager") respondsToSelector:@selector(sharedInstance)] ? [NSClassFromString(@"QRCodeManager") sharedInstance] : nil;
    VSSetQRDelegate(qr, self.savedQRDelegate);
    self.savedQRDelegate = nil; self.savedQRDelegateValid = NO;
}

- (void)stopRunQuiet {
    g_run++;
    g_pickedHandler = nil;
    [self restoreQRDelegate];
    [self hideBar];
    [self.msCard removeFromSuperview]; self.msCard = nil; self.msCapturing = -1; self.qrCapture = nil;
    self.busyName = nil; self.fab.alpha = 1;
    [self status:nil];
}

- (void)endRun:(NSString *)message {
    [self stopRunQuiet];
    if (message.length) [self alert:message];
}

// ============================================================================
// FEATURE 1 — 1-Chạm Thay Media (theo logic doc)
// ============================================================================
- (void)pickMediaOnEditor:(id)editor rid:(NSUInteger)rid completion:(void (^)(id resp, NSDictionary *info))done {
    if (!g_origPicked) { done(nil, nil); return; }
    g_pickedHandler = ^(id me, id resp) {
        if (rid != g_run || me != editor) return;
        g_pickedHandler = nil;
        __block NSDictionary *found = nil;
        VSPoll(rid, 150, 40, ^BOOL{
            id eng = [me getMultiLayerEngine]; NSInteger n = [me lastSelectedLayerNum];
            if (!eng || n < 0) return NO;
            found = VSLayerInfo(eng, (NSUInteger)n);
            return found != nil;
        }, ^(BOOL ok) { done(ok ? resp : nil, found); });
    };
    VSPoll(rid, 100, 80, ^BOOL{
        return [editor isViewLoaded] && [[editor view] window] && [editor getMultiLayerEngine];
    }, ^(BOOL ok) {
        if (!ok) { g_pickedHandler = nil; done(nil, nil); return; }
        VSAfter(150, ^{
            if (rid != g_run) return;
            @try { [editor pickNewContent]; }
            @catch (NSException *e) { g_pickedHandler = nil; VSLog(@"pickNewContent exception: %@", e.reason ?: e.name); done(nil, nil); }
        });
    });
}

// Sequential loop: chọn lớp → replay → poll verify → tiếp
- (void)applyResponse:(id)resp toEditor:(id)editor kind:(NSString *)kind skip:(NSInteger)skip rid:(NSUInteger)rid
           completion:(void (^)(NSUInteger changed, NSUInteger total))done {
    id engine = [editor getMultiLayerEngine];
    NSMutableArray<NSNumber *> *targets = [NSMutableArray array];
    for (NSUInteger n = 0; n < VS_MAX_LAYERS; n++) {
        NSDictionary *i = VSLayerInfo(engine, n);
        if (!i || (NSInteger)n == skip) continue;
        if (kind && ![i[@"kind"] isEqualToString:kind]) continue;
        [targets addObject:@(n)];
    }
    NSUInteger total = targets.count;
    if (!total) { done(0, 0); return; }

    __block NSUInteger idx = 0, changed = 0;
    __block void (^step)(void) = nil;
    step = ^{
        if (rid != g_run) { step = nil; return; }
        VSHandleEditorPopups(editor);
        if (idx >= total) {
            @try {
                if (changed) {
                    [engine reloadLayerEffects];
                    [editor handleImageGenUpdate];
                    [editor engineResync];
                    [editor refreshDisplay];
                }
            } @catch (NSException *e) { VSLog(@"refresh exception: %@", e.reason ?: e.name); }
            step = nil;
            done(changed, total);
            return;
        }
        NSUInteger n = targets[idx++].unsignedIntegerValue;
        [self status:[NSString stringWithFormat:@"Đang thay media: lớp %lu (%lu/%lu)", (unsigned long)(n + 1), (unsigned long)idx, (unsigned long)total]];
        @try { [editor selectLayer:n bordered:NO]; }
        @catch (NSException *e) { VSLog(@"select layer %lu exception: %@", (unsigned long)n, e.reason ?: e.name); step(); return; }
        VSPoll(rid, 40, 15, ^BOOL{ return [editor lastSelectedLayerNum] == (NSInteger)n; }, ^(BOOL selected) {
            if (!selected) { @try { [editor selectLayerNum:n flash:NO]; } @catch (...) {} }
            VSAfter(selected ? 30 : 120, ^{
                if (rid != g_run) { step = nil; return; }
                id layer = [engine layerAtLayerNum:n];
                if (!layer || [editor lastSelectedLayerNum] != (NSInteger)n) { VSLog(@"layer %lu: không chọn được", (unsigned long)n); step(); return; }
                id before = VSGenMedia(layer);
                VSReplayPicked(editor, resp);
                VSPoll(rid, 100, 40, ^BOOL{
                    VSHandleEditorPopups(editor);
                    id now = VSGenMedia([engine layerAtLayerNum:n]);
                    return now && now != before;
                }, ^(BOOL ok) {
                    if (ok) { changed++; VSLog(@"layer %lu: ✅", (unsigned long)n); }
                    else VSLog(@"layer %lu: ❌ chưa đổi", (unsigned long)n);
                    VSAfter(20, ^{ step(); });
                });
            });
        });
    };
    step();
}

- (void)runReplaceLayers {
    id editor = VSFindVC(@"MultiLayerWizEffectVC");
    if (!editor) { [self alert:@"Bạn chưa ở trong phần Nhiều lớp hình ảnh."]; return; }
    NSUInteger rid = [self beginRun:@"Auto nhập ảnh vào các lớp" status:@"Chọn 1 ảnh/video trong bộ chọn của Video Star…"];
    [self pickMediaOnEditor:editor rid:rid completion:^(id resp, NSDictionary *info) {
        if (!resp) { [self endRun:@"Video Star đã nhận lựa chọn nhưng không lấy được media."]; return; }
        [self applyResponse:resp toEditor:editor kind:info[@"kind"] skip:[info[@"layerNum"] integerValue] rid:rid
                 completion:^(NSUInteger changed, NSUInteger total) {
            [self endRun:[NSString stringWithFormat:@"Đã hoàn thành! Thay thành công %lu/%lu lớp.", (unsigned long)changed, (unsigned long)total]];
        }];
    }];
}

// ============================================================================
// FEATURE 2 — Xem QR gần nhất
// ============================================================================
- (void)runLastCode {
    UIImage *img = VSLoadLastQR();
    if (!img) { [self alert:@"Chưa có mã QR / code nào được ghi lại."]; return; }
    if (!VSDecodeQR(img)) { [self alert:@"Ảnh lưu không chứa mã QR hợp lệ."]; return; }
    VSImageVC *vc = [VSImageVC new];
    vc.image = img;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [[self presenter] presentViewController:vc animated:YES completion:nil];
}

// ============================================================================
// FEATURE 3 — Auto chia beat
// ============================================================================
- (void)runBeatSplit {
    id vc = VSFindVC(@"VideoReviewEditVC");
    if (!vc) { [self alert:@"Bạn chưa ở trong phần chia phân cảnh."]; return; }
    NSUInteger rid = [self beginRun:@"Auto chia beat" status:@"Đang chuẩn bị chia beat…"];
    id (^splitViewNow)(void) = ^id{ return VSValue(vc, @"splitView"); };
    BOOL (^panelVisible)(void) = ^BOOL{
        id sv = splitViewNow(); if (!sv) return NO;
        UIView *v = [sv isKindOfClass:UIView.class] ? sv : VSValue(sv, @"splitPanel");
        return [v isKindOfClass:UIView.class] && v.window != nil;
    };
    if (!panelVisible()) { @try { [vc showSplitScene]; } @catch (NSException *e) { [self endRun:[NSString stringWithFormat:@"Không mở được phần chia: %@", e.reason ?: e.name]]; return; } }
    VSPoll(rid, 100, 30, ^BOOL{ return panelVisible(); }, ^(BOOL ok) {
        id sv = splitViewNow();
        if (!ok || !sv) { [self endRun:@"Không tìm thấy chức năng chia beat gốc."]; return; }
        [self beatSplitValidateAndStart:vc splitView:sv rid:rid];
    });
}

- (void)beatSplitValidateAndStart:(id)vc splitView:(id)sv rid:(NSUInteger)rid {
    NSString *bad = nil;
    @try {
        id project = [vc project];
        NSUInteger scene = [vc sceneIndex];
        NSUInteger clips = [project clipCountForSceneIndex:scene];
        if (![vc isEnoughStorageAvailableForSplit] || ![project sceneHasAtLeastOneClipWithSceneIndex:scene] || clips == 0)
            bad = @"Phân cảnh chưa có clip hợp lệ hoặc bộ nhớ không đủ.";
        id fm = [project fileManager];
        for (NSUInteger i = 0; !bad && fm && i < clips; i++) {
            NSURL *u = [fm clipURLForSceneIndex:scene clipIndex:i];
            if (![u isKindOfClass:NSURL.class] || ![NSFileManager.defaultManager fileExistsAtPath:u.path]) { bad = @"Clip không hợp lệ."; break; }
            AVURLAsset *a = [AVURLAsset URLAssetWithURL:u options:nil];
            if ([a tracksWithMediaType:AVMediaTypeVideo].count == 0 || CMTIME_IS_INVALID(a.duration)) bad = @"Clip không hợp lệ.";
        }
    } @catch (NSException *e) { bad = [NSString stringWithFormat:@"Lỗi chuẩn bị: %@", e.reason ?: e.name]; }
    if (bad) { [self endRun:bad]; return; }

    id project = [vc project];
    NSUInteger sceneBefore = [project sceneCount];
    @try {
        if (![sv beatModeOn]) [sv toggleBeatMode];
        [sv gotoTime:kCMTimeZero];
    } @catch (NSException *e) { [self endRun:[NSString stringWithFormat:@"Không bật được chế độ beat: %@", e.reason ?: e.name]]; return; }

    __block NSUInteger guard = 0, queued = 0;
    __block CMTime last = kCMTimeInvalid;
    __block void (^step)(void) = nil;
    void (^finish)(void) = ^{
        step = nil;
        if (rid != g_run) return;
        NSUInteger have = [VSValue(sv, @"splitTimes") count];
        if (queued == 0 && have == 0) { [self endRun:@"Không còn beat nào để chia."]; return; }
        @try { [sv doSplit]; } @catch (NSException *e) { [self endRun:[NSString stringWithFormat:@"Không thể chia: %@", e.reason ?: e.name]]; return; }
        [self status:@"Đang chia phân cảnh…"];
        VSPoll(rid, 100, 150, ^BOOL{ return [project sceneCount] > sceneBefore; }, ^(BOOL ok) {
            [self endRun:ok ? [NSString stringWithFormat:@"Chia beat thành công: thêm %lu phân cảnh.", (unsigned long)([project sceneCount] - sceneBefore)]
                            : @"Video Star chưa hoàn tất chia."];
        });
    };
    step = ^{
        if (rid != g_run) { step = nil; return; }
        if (++guard >= 4096 || ![sv hasNextBeat]) { finish(); return; }
        CMTime from = VSCurrentTime(sv);
        [sv jumpToNextBeat];
        VSPoll(rid, 12, 100, ^BOOL{
            CMTime cur = VSCurrentTime(sv);
            return CMTIME_IS_VALID(cur) && (CMTIME_IS_INVALID(from) || CMTimeCompare(cur, from) > 0);
        }, ^(BOOL moved) {
            CMTime cur = VSCurrentTime(sv);
            if (!moved || (CMTIME_IS_VALID(last) && CMTimeCompare(cur, last) <= 0)) { finish(); return; }
            last = cur;
            [sv setSplitPoint];
            queued++;
            [self status:[NSString stringWithFormat:@"Đã đặt %lu điểm chia…", (unsigned long)queued]];
            VSAfter(15, ^{ step(); });
        });
    };
    VSAfter(220, ^{ step(); });
}

// ============================================================================
// FEATURE 4 — Batch QR Import (theo logic doc)
// ============================================================================
- (void)runMultiScene {
    id vc = VSFindVC(@"VideoReviewEditVC");
    if (!vc) { [self alert:@"Bạn chưa trong phần chia phân cảnh."]; return; }
    NSUInteger rid = [self beginRun:@"Auto nhập code + ảnh vào phân cảnh" status:nil];
    NSUInteger origLast = [vc lastViewedSceneIndex];
    @try { [vc showMergeScenes]; }
    @catch (NSException *e) { [self endRun:[NSString stringWithFormat:@"Không mở được Hợp nhất: %@", e.reason ?: e.name]]; return; }
    [self showBar:@"Chọn phân cảnh"
          message:@"Chọn điểm đầu và cuối trong Hợp nhất, rồi bấm Bắt đầu."
               ok:@"Bắt đầu"
             onOK:^{ [self msReadRange:vc rid:rid origLast:origLast]; }
         onCancel:^{ @try { [vc closeMergePanel]; } @catch (...) {} [self stopRunQuiet]; }];
}

- (void)msReadRange:(id)vc rid:(NSUInteger)rid origLast:(NSUInteger)origLast {
    if (rid != g_run) return;
    id project = [vc project];
    NSInteger total = (NSInteger)[project sceneCount];
    NSInteger start = [VSValue(vc, @"startScene") integerValue];
    NSInteger last  = [VSValue(vc, @"lastScene") integerValue];
    if (!project || start < 0 || last < start || last >= total) {
        @try { [vc closeMergePanel]; } @catch (...) {}
        [self endRun:@"Chưa chọn được phạm vi hợp lệ."];
        return;
    }
    @try { [vc closeMergePanel]; } @catch (...) {}
    self.msStart = (NSUInteger)start; self.msCount = (NSUInteger)(last - start + 1);
    self.msOrigLast = origLast; self.msRid = rid; self.msCapturing = -1;
    self.msPresets = [NSMutableArray array]; self.msCodes = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.msCount; i++) { [self.msPresets addObject:NSNull.null]; [self.msCodes addObject:NSNull.null]; }
    [self msShowCodePanel];
}

- (NSUInteger)msGotCount {
    NSUInteger got = 0;
    for (id c in self.msCodes) if (c != NSNull.null) got++;
    return got;
}

- (void)msShowCodePanel {
    if (self.msRid != g_run) return;
    [self.msCard removeFromSuperview];
    UIView *root = self.window.rootViewController.view;
    UIEdgeInsets ins = root.safeAreaInsets;
    CGFloat w = MIN(root.bounds.size.width - 24, 460);
    CGFloat top = ins.top + 28, h = root.bounds.size.height - top - ins.bottom - 84;
    NSUInteger got = [self msGotCount];
    UIView *card = [self cardWithFrame:CGRectMake((root.bounds.size.width - w) / 2, top, w, h)
                                 title:@"Nhập code"
                               message:[NSString stringWithFormat:@"Đã nhận %lu/%lu code.", (unsigned long)got, (unsigned long)self.msCount]];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 70, w - 24, h - 70 - 66)];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    for (NSUInteger i = 0; i < self.msCount; i++) {
        BOOL has = self.msCodes[i] != NSNull.null;
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, i * 68, sv.bounds.size.width, 60)];
        row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06]; row.layer.cornerRadius = 10;
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UILabel *n = [[UILabel alloc] initWithFrame:CGRectMake(14, 9, row.bounds.size.width - 140, 20)];
        n.text = [NSString stringWithFormat:@"Phân cảnh %lu", (unsigned long)(self.msStart + i + 1)];
        n.textColor = UIColor.whiteColor; n.font = [UIFont boldSystemFontOfSize:15];
        UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(14, 33, row.bounds.size.width - 140, 16)];
        st.text = has ? @"Đã nhận code" : @"Chưa nhập code";
        st.textColor = has ? VSCyan() : [UIColor colorWithWhite:0.6 alpha:1]; st.font = [UIFont systemFontOfSize:11];
        UIButton *b = VSOutlineButton(has ? @"Đổi code" : @"Nhập code", CGRectMake(row.bounds.size.width - 112, 12, 100, 36));
        b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(codeButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:n]; [row addSubview:st]; [row addSubview:b];
        [sv addSubview:row];
    }
    sv.contentSize = CGSizeMake(sv.bounds.size.width, self.msCount * 68);
    [card addSubview:sv];

    CGFloat bw = (w - 32 - 12) / 2;
    UIButton *cancel = VSOutlineButton(@"Hủy", CGRectMake(16, h - 52, bw, 38));
    cancel.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1].CGColor;
    [cancel setTitleColor:[UIColor colorWithWhite:0.78 alpha:1] forState:UIControlStateNormal];
    cancel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [cancel addTarget:self action:@selector(msCancelTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *next = VSOutlineButton(@"Chọn ảnh/video", CGRectMake(16 + bw + 12, h - 52, bw, 38));
    next.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    next.enabled = (got == self.msCount);
    [next addTarget:self action:@selector(msChooseMediaTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancel]; [card addSubview:next];
    [root addSubview:card];
    self.msCard = card;
}

- (void)msCancelTapped { [self stopRunQuiet]; }

- (void)msBackToCodePanel {
    g_pickedHandler = nil;
    [self restoreQRDelegate];
    self.qrCapture = nil; self.msCapturing = -1;
    [self status:nil];
    if (self.msCard && self.msCount) [self msShowCodePanel];
}

- (void)codeButtonTapped:(UIButton *)b {
    NSUInteger idx = (NSUInteger)b.tag;
    Class qc = NSClassFromString(@"QRCodeManager");
    id qr = [qc respondsToSelector:@selector(sharedInstance)] ? [qc sharedInstance] : nil;
    if (!qr || ![qr respondsToSelector:@selector(startQRImport)]) { [self alert:@"Không tìm thấy bộ nhập code."]; return; }
    VSQRCaptureDelegate *cap = [VSQRCaptureDelegate new];
    NSUInteger rid = self.msRid;
    cap.onCode = ^(id preset, id code) {
        if (rid != g_run || self.msCapturing != (NSInteger)idx) return;
        [self restoreQRDelegate];
        self.qrCapture = nil; self.msCapturing = -1;
        if (!preset || ![code isKindOfClass:NSString.class] || ![(NSString *)code length]) {
            [self msShowCodePanel];
            [self alert:@"Video Star không trả về code hợp lệ."]; return;
        }
        self.msPresets[idx] = preset; self.msCodes[idx] = code;
        [self msShowCodePanel];
    };
    self.qrCapture = cap; self.msCapturing = (NSInteger)idx;
    if (!self.savedQRDelegateValid) { self.savedQRDelegate = VSValue(qr, @"delegate"); self.savedQRDelegateValid = YES; }
    @try {
        VSSetQRDelegate(qr, cap);
        self.msCard.hidden = YES;
        [qr startQRImport];
    } @catch (NSException *e) {
        [self msBackToCodePanel];
        [self alert:[NSString stringWithFormat:@"Không mở được bộ chọn code: %@", e.reason ?: e.name]];
    }
}

- (void)msChooseMediaTapped {
    NSUInteger rid = self.msRid;
    if (rid != g_run || [self msGotCount] != self.msCount) return;
    self.msCard.hidden = YES;
    [self status:@"Đang mở Nhiều lớp ở phân cảnh đầu…"];
    id rvc = VSFindVC(@"VideoReviewEditVC");
    [self openEditorForScene:self.msStart review:rvc rid:rid completion:^(id editor) {
        if (!editor) { [self endRun:@"Không mở được phần Nhiều lớp."]; return; }
        [self status:@"Chọn 1 ảnh/video trong bộ chọn…"];
        [self pickMediaOnEditor:editor rid:rid completion:^(id resp, NSDictionary *info) {
            if (!resp) { [self endRun:@"Không lấy được ảnh/video."]; return; }
            [self.msCard removeFromSuperview]; self.msCard = nil;
            [self status:nil];
            [self msShowApplyPanel];
            [self msRunScenesWithResponse:resp rid:rid];
        }];
    }];
}

- (void)msShowApplyPanel {
    UIView *root = self.window.rootViewController.view;
    CGFloat w = MIN(root.bounds.size.width - 24, 460), h = 132;
    UIView *card = [self cardWithFrame:CGRectMake((root.bounds.size.width - w) / 2, root.bounds.size.height - root.safeAreaInsets.bottom - h - 70, w, h)
                                 title:@"Đang áp dụng"
                               message:@"Đang mở từng phân cảnh, nhập code và thay media..."];
    UIButton *b = VSOutlineButton(@"Đang xử lý…", CGRectMake(w - 16 - 130, h - 52, 130, 38));
    b.enabled = NO;
    [card addSubview:b];
    [root addSubview:card];
    self.msCard = card;
}

// Sequential scene loop: mở scene → import code → thay media → create → scene kế
- (void)msRunScenesWithResponse:(id)resp rid:(NSUInteger)rid {
    NSUInteger start = self.msStart, count = self.msCount, origLast = self.msOrigLast;
    NSArray *presets = [self.msPresets copy], *codes = [self.msCodes copy];
    __block NSUInteger offset = 0, okCount = 0;
    __block void (^sceneStep)(void) = nil;
    void (^finish)(NSString *) = ^(NSString *err) {
        sceneStep = nil;
        id rvc = VSFindVC(@"VideoReviewEditVC");
        @try { [rvc setLastViewedSceneIndex:origLast]; } @catch (...) {}
        [self stopRunQuiet];
        NSString *summary = [NSString stringWithFormat:@"Đã áp dụng %lu code cho %lu phân cảnh.", (unsigned long)okCount, (unsigned long)count];
        if (err) [self alert:[err stringByAppendingFormat:@"\n%@", summary] title:@"Dừng giữa chừng"];
        else [self alert:summary title:@"Áp dụng thành công"];
    };
    sceneStep = ^{
        if (rid != g_run) { sceneStep = nil; return; }
        if (offset >= count) { finish(nil); return; }
        NSUInteger off = offset++, scene = start + off;
        [self status:[NSString stringWithFormat:@"Phân cảnh %lu (%lu/%lu): nhập code…", (unsigned long)(scene + 1), (unsigned long)(off + 1), (unsigned long)count]];
        id rvc = VSFindVC(@"VideoReviewEditVC");
        [self openEditorForScene:scene review:rvc rid:rid completion:^(id editor) {
            if (!editor) { finish([NSString stringWithFormat:@"Không mở được Nhiều lớp ở phân cảnh %lu.", (unsigned long)(scene + 1)]); return; }
            [self importPreset:presets[off] code:codes[off] intoEditor:editor rid:rid completion:^(NSString *err) {
                if (err) { finish([NSString stringWithFormat:@"Phân cảnh %lu: %@", (unsigned long)(scene + 1), err]); return; }
                if (rid != g_run) { sceneStep = nil; return; }
                [self status:[NSString stringWithFormat:@"Phân cảnh %lu: đợi preset ổn định…", (unsigned long)(scene + 1)]];
                VSAfter(1000, ^{
                    if (rid != g_run) { sceneStep = nil; return; }
                    [self status:[NSString stringWithFormat:@"Phân cảnh %lu: thay ảnh/video…", (unsigned long)(scene + 1)]];
                    [self applyResponse:resp toEditor:editor kind:nil skip:-1 rid:rid completion:^(NSUInteger changed, NSUInteger total) {
                        if (rid != g_run) { sceneStep = nil; return; }
                        [self status:[NSString stringWithFormat:@"Phân cảnh %lu: đang Create…", (unsigned long)(scene + 1)]];
                        [self createInEditor:editor rid:rid completion:^(NSString *cerr) {
                            if (cerr) { finish([NSString stringWithFormat:@"Phân cảnh %lu: %@", (unsigned long)(scene + 1), cerr]); return; }
                            okCount++;
                            VSPoll(rid, 100, 100, ^BOOL{ return VSFindVC(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                                if (!back) { finish(@"Không quay lại được màn hình phân cảnh."); return; }
                                VSAfter(300, ^{ sceneStep(); });
                            });
                        }];
                    }];
                });
            }];
        }];
    };
    sceneStep();
}

- (void)openEditorForScene:(NSUInteger)scene review:(id)rvc rid:(NSUInteger)rid completion:(void (^)(id editor))done {
    id (^current)(void) = ^id{
        id ed = VSFindVC(@"MultiLayerWizEffectVC");
        if (!ed || ![ed getMultiLayerEngine]) return nil;
        id nav = [ed navigationController];
        BOOL sceneOK = [nav respondsToSelector:@selector(navSceneIndex)] ? ([nav navSceneIndex] == scene) : YES;
        return sceneOK ? ed : nil;
    };
    if (current()) { done(current()); return; }
    if (!rvc) { done(nil); return; }
    @try { [rvc setLastViewedSceneIndex:scene]; [rvc showMultiLayer]; }
    @catch (NSException *e) { VSLog(@"showMultiLayer exception: %@", e.reason ?: e.name); done(nil); return; }
    VSPoll(rid, 80, 100, ^BOOL{ return current() != nil; }, ^(BOOL ok) { done(ok ? current() : nil); });
}

// Import preset — kiểm tra g_importCount tăng + engine có layer + không popup
- (void)importPreset:(id)preset code:(id)code intoEditor:(id)editor rid:(NSUInteger)rid completion:(void (^)(NSString *err))done {
    if (![editor respondsToSelector:@selector(importedData:code:)]) { done(@"Editor không có hàm nhập code."); return; }
    NSUInteger snap = g_importCount;
    @try { [editor importedData:preset code:code]; }
    @catch (NSException *e) { done([NSString stringWithFormat:@"Không nhập được code: %@", e.reason ?: e.name]); return; }

    __block BOOL blocked = NO;
    VSPoll(rid, 40, 250, ^BOOL{
        VSPopupResult r = VSHandleEditorPopups(editor);
        if (r == VSPopupBlocked) { blocked = YES; return YES; }
        return g_importCount > snap;
    }, ^(BOOL ok) {
        if (blocked) { done(@"Video Star hiện popup mua gói — Dừng."); return; }
        if (!ok) { done(@"Code chưa nhập xong (timeout 10s)."); return; }
        VSAfter(700, ^{
            id engine = [editor getMultiLayerEngine];
            VSPoll(rid, 60, 80, ^BOOL{
                VSHandleEditorPopups(editor);
                return !VSEditorHasVisiblePopup(editor) && [engine numActiveLayers] > 0;
            }, ^(BOOL ready) { done(ready ? nil : @"Code đã nhập nhưng Nhiều lớp chưa sẵn sàng."); });
        });
    });
}

- (void)createInEditor:(id)editor rid:(NSUInteger)rid completion:(void (^)(NSString *err))done {
    BOOL fired = NO;
    id item = VSValue(editor, @"createBarButton");
    @try {
        if ([item isKindOfClass:UIBarButtonItem.class] && ((UIBarButtonItem *)item).action) {
            UIBarButtonItem *b = item;
            fired = [UIApplication.sharedApplication sendAction:b.action to:b.target from:b forEvent:nil];
        } else if ([item isKindOfClass:UIControl.class]) {
            [(UIControl *)item sendActionsForControlEvents:UIControlEventTouchUpInside]; fired = YES;
        }
        if (!fired && [editor respondsToSelector:@selector(create)]) { [editor create]; fired = YES; }
    } @catch (NSException *e) { done([NSString stringWithFormat:@"Không bấm được Tạo: %@", e.reason ?: e.name]); return; }
    if (!fired) { done(@"Không tìm thấy nút Tạo."); return; }
    __block BOOL blocked = NO;
    VSPoll(rid, 100, 600, ^BOOL{
        if (VSHandleEditorPopups(editor) == VSPopupBlocked) { blocked = YES; return YES; }
        return !([editor isViewLoaded] && [[editor view] window]);
    }, ^(BOOL closed) {
        done(blocked ? @"Tạo yêu cầu mua gói — Dừng." : (closed ? nil : @"Tạo chưa hoàn tất."));
    });
}

@end

// ============================================================================
// ENTRY
// ============================================================================
static void VSBootstrap(void) {
    if (!NSClassFromString(@"MultiLayerWizEffectVC")) { VSLog(@"không phải Video Star"); return; }
    [VSTool.shared installIfNeeded];
}

__attribute__((constructor)) static void VSToolInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(NSNotification *n) { VSBootstrap(); }];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) VSBootstrap();
    });
}
