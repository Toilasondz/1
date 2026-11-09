// VideoStarTool.m
// Video Star 14.3.3 (com.frontierdesign.videostar), arm64.
// Bản Full Fix - Không cần Header, tự động bấm Popup, chống Crash.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define VS_MAX_LAYERS 30
#define VSLog(fmt, ...) NSLog(@"[VideoStarTool] " fmt, ##__VA_ARGS__)

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
- (id)layerAtLayerNum:(NSUInteger)n;
- (NSInteger)numActiveLayers;
- (void)reloadLayerEffects;
- (id)imageGenerator;
- (id)layerImage;
- (id)layerDrawing;
- (id)layerZaps;
- (id)layerGIF;
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
- (NSUInteger)sceneCount;
- (BOOL)sceneHasAtLeastOneClipWithSceneIndex:(NSUInteger)i;
- (NSUInteger)clipCountForSceneIndex:(NSUInteger)i;
- (id)fileManager;
- (id)clipURLForSceneIndex:(NSUInteger)i clipIndex:(NSUInteger)c;
- (BOOL)beatModeOn;
- (void)toggleBeatMode;
- (BOOL)hasNextBeat;
- (void)jumpToNextBeat;
- (void)setSplitPoint;
- (void)doSplit;
- (void)gotoTime:(CMTime)t;
+ (id)sharedInstance;
- (void)selectedCode:(NSString *)code withImageData:(NSData *)data;
- (void)startQRImport;
- (void)importedData:(id)data code:(id)code;
- (void)simulateButtonPressButtonWithTitle:(NSString *)title;
@end

// ============================================================================
// Tiện ích
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

static void VSPoll(NSUInteger rid, int64_t ms, NSUInteger tries, BOOL (^cond)(void), void (^done)(BOOL ok)) {
    if (rid != g_run) return;
    BOOL ok = NO;
    @try { ok = cond(); } @catch (NSException *e) { VSLog(@"poll exception: %@", e.reason ?: e.name); }
    if (ok) { done(YES); return; }
    if (tries == 0) { done(NO); return; }
    VSAfter(ms, ^{ VSPoll(rid, ms, tries - 1, cond, done); });
}

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
    NSArray<UIWindow *> *wins = UIApplication.sharedApplication.windows;
    for (UIWindow *w in wins.reverseObjectEnumerator) {
        if (w == g_toolWindow || w.hidden) continue;
        UIViewController *r = VSFindVCIn(w.rootViewController, cls, 0);
        if (r) return r;
    }
    return nil;
}

// ----------------------------------------------------------------------------
// Xử lý Popup (Tự động bấm "Trùng khớp")
// ----------------------------------------------------------------------------
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
    for (NSString *w in @[@"purchase", @"subscription", @"unlock pro", @"pro pack", @"restore purchase", @"mua gói", @"khôi phục"]) {
        if ([all containsString:w]) return YES;
    }
    return NO;
}

static VSPopupResult VSHandleEditorPopups(id editor) {
    NSArray *prefer = @[@"Trùng khớp", @"Match", @"Original Preset Layers", @"Fit", @"Continue", @"OK", @"Đồng ý", @"Tiếp tục"];
    for (id popup in VSVisiblePopups(editor)) {
        if (VSPopupLooksLikePurchase(popup)) return VSPopupBlocked;
        if (popup == g_lastPressedPopup && CFAbsoluteTimeGetCurrent() - g_lastPressedAt < 0.4) return VSPopupPressed;
        
        NSArray *titles = VSValue(popup, @"_buttonStrings");
        NSArray *buttons = VSValue(popup, @"_buttons");
        for (NSString *en in prefer) {
            NSString *loc = VSL(en);
            NSString *hit = nil;
            for (id t in titles) {
                if ([t isKindOfClass:NSString.class] && ([t localizedCaseInsensitiveContainsString:loc] || [t localizedCaseInsensitiveContainsString:en])) { hit = t; break; }
            }
            if (!hit) for (id b in buttons) {
                NSString *ct = [b isKindOfClass:UIButton.class] ? ((UIButton *)b).currentTitle : nil;
                if (ct && ([ct localizedCaseInsensitiveContainsString:loc] || [ct localizedCaseInsensitiveContainsString:en])) { hit = ct; break; }
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
            } @catch (NSException *e) {}
            return VSPopupPressed;
        }
    }
    return VSPopupNone;
}

static BOOL VSEditorHasVisiblePopup(id editor) { return VSVisiblePopups(editor).count > 0; }

// ----------------------------------------------------------------------------
// Nhận diện Lớp (Bỏ qua 3D, Text, Màu)
// ----------------------------------------------------------------------------
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
        if (VSValue(gen, @"textView") || VSValue(gen, @"fillColor") || VSValue(gen, @"isTextLayer") || VSValue(gen, @"isColorLayer") || VSValue(gen, @"is3DLayer") || VSValue(gen, @"isDrawingLayer")) return nil;

        id asset = [gen respondsToSelector:@selector(asset)] ? [gen asset] : nil;
        if ([asset isKindOfClass:AVAsset.class]) return @{@"layerNum": @(n), @"kind": @"video"};

        UIImage *img = [gen layerImage];
        if ([img isKindOfClass:UIImage.class] && img.size.width > 1) return @{@"layerNum": @(n), @"kind": @"image"};
    } @catch (...) {}
    return nil;
}

// ----------------------------------------------------------------------------
// QR Code
// ----------------------------------------------------------------------------
static NSString *VSLastQRPath(void) { return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"VideoStarTool_LastQR.png"]; }
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
    CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
    for (CIFeature *f in [det featuresInImage:ci])
        if ([f isKindOfClass:CIQRCodeFeature.class] && ((CIQRCodeFeature *)f).messageString.length) return ((CIQRCodeFeature *)f).messageString;
    return nil;
}

// ----------------------------------------------------------------------------
// Hook
// ----------------------------------------------------------------------------
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
        VSSwizzle(@"MultiLayerWizEffectVC", @selector(pickedWithClipPickerResponse:), ^(id me, id resp) {
            ((void (*)(id, SEL, id))g_origPicked)(me, @selector(pickedWithClipPickerResponse:), resp);
            void (^h)(id, id) = g_pickedHandler;
            if (h) dispatch_async(dispatch_get_main_queue(), ^{ h(me, resp); });
        }, &g_origPicked);

        VSSwizzle(@"QRCodeManager", @selector(selectedCode:withImageData:), ^(id me, id code, id data) {
            VSRememberLastQR(data);
            ((void (*)(id, SEL, id, id))g_origSelectedCode)(me, @selector(selectedCode:withImageData:), code, data);
        }, &g_origSelectedCode);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), ^(id me, id a, id b, NSInteger frames) {
            ((void (*)(id, SEL, id, id, NSInteger))g_origImportNew)(me, @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), a, b, frames);
            g_importCount++;
        }, &g_origImportNew);

        VSSwizzle(@"MultiLayerWizEffectVC", @selector(importOldPreset:), ^(id me, id a) {
            ((void (*)(id, SEL, id))g_origImportOld)(me, @selector(importOldPreset:), a);
            g_importCount++;
        }, &g_origImportOld);

        VSSwizzle(@"CustomPopup", @selector(show), ^(id me) {
            ((void (*)(id, SEL))g_origPopupShow)(me, @selector(show));
            [g_popups addObject:me];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                VSHandleEditorPopups(nil);
            });
        }, &g_origPopupShow);
    });
}

static BOOL VSReplayPicked(id editor, id response) {
    if (!editor || !response || !g_origPicked) return NO;
    @try { ((void (*)(id, SEL, id))g_origPicked)(editor, @selector(pickedWithClipPickerResponse:), response); return YES; }
    @catch (NSException *e) { VSLog(@"replay picked exception: %@", e.reason ?: e.name); }
    return NO;
}

// ============================================================================
// UI
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

@interface VSQRCaptureDelegate : NSObject
@property (nonatomic, copy) void (^onCode)(id preset, id code);
@end
@implementation VSQRCaptureDelegate
- (NSString *)qrLabel { return VSL(@"Multi-Layer"); }
- (NSString *)qrSetupLabel { return @""; }
- (NSString *)codePrefix { return @"n"; }
- (BOOL)validCode:(NSString *)code { return [code isKindOfClass:NSString.class] && ([code hasPrefix:@"m"] || [code hasPrefix:@"n"]); }
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
// VSTool
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
        VSAfter(3000, ^{ [self installIfNeeded]; });
        return;
    }

    CGRect b = UIScreen.mainScreen.bounds;
    VSPassWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class]) { w = [[VSPassWindow alloc] initWithWindowScene:(UIWindowScene *)s]; break; }
    }
    if (!w) w = [[VSPassWindow alloc] initWithFrame:b];
    w.frame = b;
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = UIColor.clearColor;
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
// CHỨC NĂNG 1 & 4
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
                if (changed) { [engine reloadLayerEffects]; [editor handleImageGenUpdate]; [editor engineResync]; [editor refreshDisplay]; }
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
                    if (ok) changed++; else VSLog(@"layer %lu: media chưa xác minh được", (unsigned long)n);
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
            [self endRun:[NSString stringWithFormat:@"Đã hoàn thành! Đã thay thế thành công %lu/%lu lớp.", (unsigned long)changed, (unsigned long)total]];
        }];
    }];
}

- (void)runLastCode {
    UIImage *img = VSLoadLastQR();
    if (!img) { [self alert:@"Chưa có mã QR / code nào được ghi lại."]; return; }
    VSImageVC *vc = [VSImageVC new];
    vc.image = img;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [[self presenter] presentViewController:vc animated:YES completion:nil];
}

- (void)runBeatSplit {
    [self alert:@"Tính năng Auto chia beat đang cập nhật."];
}

- (void)runMultiScene {
    [self alert:@"Tính năng Auto nhập code + ảnh vào phân cảnh đang cập nhật."];
}

@end

__attribute__((constructor)) static void VSToolInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [VSTool.shared installIfNeeded]; }];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [VSTool.shared installIfNeeded];
    });
}
