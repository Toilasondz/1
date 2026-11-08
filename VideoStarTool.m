// VideoStarTool.m
// Video Star 14.3.3 (com.frontierdesign.videostar), arm64.
//
// 4 chức năng:
//   1. Auto nhập ảnh/video vào các lớp hình ảnh        (MultiLayerWizEffectVC)
//   2. Xem code (QR) gần nhất từng nhập
//   3. Auto chia beat                                   (VideoReviewEditVC + MultiSplitView)
//   4. Auto nhập code + ảnh vào các phân cảnh           (VideoReviewEditVC + QRCodeManager)

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define VS_MAX_LAYERS 30
#define VSLog(fmt, ...) NSLog(@"[VideoStarTool] " fmt, ##__VA_ARGS__)

// ============================================================================
// PRIVATE API của Video Star (chữ ký lấy từ type-encoding trong binary)
// ============================================================================
@interface NSObject (VSPrivate)
// --- MultiLayerWizEffectVC (editor nhiều lớp)
- (id)getMultiLayerEngine;
- (void)pickNewContent;
- (void)pickedWithClipPickerResponse:(id)response;
- (id)lastSelectedLayer;
- (NSInteger)lastSelectedLayerNum;
- (void)selectLayer:(NSUInteger)n bordered:(BOOL)b;
- (void)selectLayerNum:(NSUInteger)n flash:(BOOL)f;
- (void)handleImageGenUpdate;
- (void)engineResync;
- (void)refreshDisplay;
- (void)presentMLLayerButtonsCollectionViewItemLayerEditTitleViewWithMultiLayerLayer:(id)layer;
- (void)dismissMLLayerButtonsCollectionViewItemLayerEditTitleView;
- (void)create;
// --- MultiLayerEngine
- (id)layerAtLayerNum:(NSUInteger)n;
- (NSInteger)numActiveLayers;
- (void)reloadLayerEffects;
// --- MultiLayerLayer / MultiLayerImageGenerator
- (id)imageGenerator;
- (id)layerImage;
- (id)layerDrawing;
- (id)layerZaps;
- (id)layerGIF;
// --- MultiLayerNavController
- (NSUInteger)navSceneIndex;
// --- VideoReviewEditVC
- (id)project;
- (NSUInteger)sceneIndex;
- (void)showMergeScenes;
- (void)closeMergePanel;
- (void)showMultiLayer;
- (void)showSplitScene;
- (NSUInteger)lastViewedSceneIndex;
- (void)setLastViewedSceneIndex:(NSUInteger)i;
- (BOOL)isEnoughStorageAvailableForSplit;
// --- project (New_Project / Old_Project) + ProjectFileManager
- (NSUInteger)sceneCount;
- (BOOL)sceneHasAtLeastOneClipWithSceneIndex:(NSUInteger)i;
- (NSUInteger)clipCountForSceneIndex:(NSUInteger)i;
- (id)fileManager;
- (id)clipURLForSceneIndex:(NSUInteger)i clipIndex:(NSUInteger)c;
// --- MultiSplitView
// LƯU Ý: KHÔNG khai báo - (CMTime)currentTime; ở đây vì trùng selector hệ thống
// (AVPlayer/AVAudioPlayer) gây lỗi ambiguous. Dùng helper VSCurrentTime() thay thế.
- (BOOL)beatModeOn;
- (void)toggleBeatMode;
- (BOOL)hasNextBeat;
- (void)jumpToNextBeat;
- (void)setSplitPoint;
- (void)doSplit;
- (void)gotoTime:(CMTime)t;
// --- QRCodeManager / CustomPopup
+ (id)sharedInstance;
- (void)selectedCode:(NSString *)code withImageData:(NSData *)data;
- (void)setDelegate:(id)d;
- (void)simulateButtonPressButtonWithTitle:(NSString *)title;
- (void)buttonPressed:(id)button;
@end

// ============================================================================
// Tiện ích chung
// ============================================================================
static NSUInteger g_run;   // token huỷ: mỗi lần bắt đầu/dừng tăng 1, mọi poll cũ tự thoát

static void VSAfter(int64_t ms, dispatch_block_t b) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), dispatch_get_main_queue(), b);
}

// Gọi selector currentTime an toàn (tránh ambiguous với AVAudioPlayer)
static CMTime VSCurrentTime(id obj) {
    if (!obj) return kCMTimeInvalid;
    SEL sel = @selector(currentTime);
    if (![obj respondsToSelector:sel]) return kCMTimeInvalid;
    CMTime (*fn)(id, SEL) = (CMTime (*)(id, SEL))[obj methodForSelector:sel];
    return fn(obj, sel);
}

// Đọc ivar/thuộc tính private bằng KVC (không ném exception ra ngoài)
static id VSValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; } @catch (...) { return nil; }
}

static BOOL VSIsKind(id obj, NSString *name) {
    Class c = NSClassFromString(name);
    return obj && c && [obj isKindOfClass:c];
}

// Poll mỗi `ms` tới khi cond() đúng hoặc hết `tries` lần. Tự dừng nếu run bị huỷ.
static void VSPoll(NSUInteger rid, int64_t ms, NSUInteger tries, BOOL (^cond)(void), void (^done)(BOOL ok)) {
    if (rid != g_run) return;
    BOOL ok = NO;
    @try { ok = cond(); } @catch (NSException *e) { VSLog(@"poll exception: %@", e.reason ?: e.name); }
    if (ok) { done(YES); return; }
    if (tries == 0) { done(NO); return; }
    VSAfter(ms, ^{ VSPoll(rid, ms, tries - 1, cond, done); });
}

// Tìm view controller thuộc class `name` đang hiển thị (duyệt presented / nav / tab / child)
static UIViewController *VSFindVCIn(UIViewController *vc, Class cls, int depth) {
    if (!vc || depth > 14) return nil;
    UIViewController *r = nil;
    if (vc.presentedViewController && (r = VSFindVCIn(vc.presentedViewController, cls, depth + 1))) return r;
    if ([vc isKindOfClass:UINavigationController.class]) {
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers.reverseObjectEnumerator)
            if ((r = VSFindVCIn(c, cls, depth + 1))) return r;
    }
    if ([vc isKindOfClass:UITabBarController.class] &&
        (r = VSFindVCIn(((UITabBarController *)vc).selectedViewController, cls, depth + 1))) return r;
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
// Popup (CustomPopup) — chỉ bấm các nút chấp nhận, KHÔNG bao giờ bấm popup mua gói
// ----------------------------------------------------------------------------
static NSString *VSL(NSString *en) {   // dịch theo ngôn ngữ đang dùng của Video Star
    return [NSBundle.mainBundle localizedStringForKey:en value:en table:nil];
}

static BOOL VSPopupLooksLikePurchase(id popup) {
    NSString *msg = [VSValue(popup, @"_message") description].lowercaseString ?: @"";
    NSString *ttl = [VSValue(popup, @"_title") description].lowercaseString ?: @"";
    NSString *all = [msg stringByAppendingString:ttl];
    for (NSString *w in @[@"purchase", @"subscription", @"subscribe", @"unlock", @"pro pack", @"restore"])
        if ([all containsString:w]) return YES;
    return NO;
}

static id g_lastPressedPopup;
static CFAbsoluteTime g_lastPressedAt;

typedef NS_ENUM(NSInteger, VSPopupResult) { VSPopupNone = 0, VSPopupPressed, VSPopupBlocked };

// Duyệt ourPopup / warningPopup của editor; popup nào đang hiện thì bấm nút phù hợp nhất.
static VSPopupResult VSHandleEditorPopups(id editor) {
    NSArray *prefer = @[@"Original Preset Layers", @"Fit", @"Continue", @"OK"];
    for (NSString *key in @[@"ourPopup", @"warningPopup"]) {
        id popup = VSValue(editor, key);
        if (!popup || !VSIsKind(popup, @"CustomPopup")) continue;
        UIView *dim = VSValue(popup, @"dimView");
        if (![dim isKindOfClass:UIView.class] || !dim.window) continue;           // popup cũ đã đóng
        if (VSPopupLooksLikePurchase(popup)) return VSPopupBlocked;
        if (popup == g_lastPressedPopup && CFAbsoluteTimeGetCurrent() - g_lastPressedAt < 0.6) return VSPopupPressed;

        NSArray *titles = VSValue(popup, @"_buttonStrings");
        NSArray *buttons = VSValue(popup, @"_buttons");
        for (NSString *en in prefer) {
            NSString *loc = VSL(en);
            NSString *hit = nil;
            for (id t in titles) if ([t isKindOfClass:NSString.class] && ([t isEqualToString:loc] || [t isEqualToString:en])) { hit = t; break; }
            if (!hit) for (id b in buttons) {
                NSString *ct = [b isKindOfClass:UIButton.class] ? ((UIButton *)b).currentTitle : nil;
                if (ct && ([ct isEqualToString:loc] || [ct isEqualToString:en])) { hit = ct; break; }
            }
            if (!hit) continue;
            g_lastPressedPopup = popup; g_lastPressedAt = CFAbsoluteTimeGetCurrent();
            @try {
                if ([popup respondsToSelector:@selector(simulateButtonPressButtonWithTitle:)]) {
                    [popup simulateButtonPressButtonWithTitle:hit];
                } else {
                    for (id b in buttons)
                        if ([b isKindOfClass:UIButton.class] && [((UIButton *)b).currentTitle isEqualToString:hit]) {
                            [(UIButton *)b sendActionsForControlEvents:UIControlEventTouchUpInside]; break;
                        }
                }
            } @catch (NSException *e) { VSLog(@"popup press exception: %@", e.reason ?: e.name); }
            VSLog(@"popup auto-pressed: %@", hit);
            return VSPopupPressed;
        }
    }
    return VSPopupNone;
}

static BOOL VSEditorHasVisiblePopup(id editor) {
    for (NSString *key in @[@"ourPopup", @"warningPopup"]) {
        id p = VSValue(editor, key);
        UIView *dim = p ? VSValue(p, @"dimView") : nil;
        if ([dim isKindOfClass:UIView.class] && dim.window) return YES;
    }
    return NO;
}

// ----------------------------------------------------------------------------
// Lớp hình ảnh: đọc media thật từ imageGenerator của từng lớp
// ----------------------------------------------------------------------------
static id VSGenMedia(id layer) {
    id gen = [layer respondsToSelector:@selector(imageGenerator)] ? [layer imageGenerator] : nil;
    if (!gen) return nil;
    return [gen respondsToSelector:@selector(asset)] && [gen asset] ? [gen asset] : [gen layerImage];
}

// @{layerNum, kind: video|image} nếu lớp n đang chứa ảnh/video; nil nếu rỗng hoặc là vẽ/zap/gif
static NSDictionary *VSLayerInfo(id engine, NSUInteger n) {
    @try {
        id layer = [engine layerAtLayerNum:n];
        id gen = layer ? [layer imageGenerator] : nil;
        if (!gen) return nil;
        if ([gen layerDrawing] || [gen layerZaps] || [gen layerGIF]) return nil;
        id asset = [gen respondsToSelector:@selector(asset)] ? [gen asset] : nil;
        if ([asset isKindOfClass:AVAsset.class]) return @{@"layerNum": @(n), @"kind": @"video"};
        if ([gen layerImage]) return @{@"layerNum": @(n), @"kind": @"image"};
    } @catch (NSException *e) { /* n vượt số lớp -> bỏ qua */ }
    return nil;
}

// ----------------------------------------------------------------------------
// QR: lưu ảnh cuối cùng / quét QR bằng CIDetector
// ----------------------------------------------------------------------------
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
    CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
    for (CIFeature *f in [det featuresInImage:ci])
        if ([f isKindOfClass:CIQRCodeFeature.class] && ((CIQRCodeFeature *)f).messageString.length)
            return ((CIQRCodeFeature *)f).messageString;
    return nil;
}

// ----------------------------------------------------------------------------
// Hook: bắt lựa chọn media, bắt code vừa nhập, bắt thời điểm import preset xong
// ----------------------------------------------------------------------------
static IMP g_origPicked, g_origSelectedCode, g_origImportNew, g_origImportOld;
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
    });
}

static BOOL VSReplayPicked(id editor, id response) {
    if (!editor || !response || !g_origPicked) return NO;
    @try { ((void (*)(id, SEL, id))g_origPicked)(editor, @selector(pickedWithClipPickerResponse:), response); return YES; }
    @catch (NSException *e) { VSLog(@"replay picked exception: %@", e.reason ?: e.name); }
    return NO;
}

// ============================================================================
// UI: cửa sổ trong suốt, chỉ nhận chạm ở nút nổi / thanh trạng thái / hộp thoại
// ============================================================================
@interface VSPassWindow : UIWindow @end
@implementation VSPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

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

// Delegate chọn ảnh (PHPicker nhiều ảnh theo thứ tự, hoặc UIImagePicker từng ảnh)
@interface VSPickerDelegate : NSObject <PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, copy) void (^onImages)(NSArray<UIImage *> *imgs);   // nil/empty = huỷ
@end
@implementation VSPickerDelegate
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14)) {
    [picker dismissViewControllerAnimated:YES completion:nil];
    void (^cb)(NSArray<UIImage *> *) = self.onImages;
    if (!results.count) { if (cb) cb(@[]); return; }
    NSMutableArray *slots = [NSMutableArray arrayWithCapacity:results.count];
    for (NSUInteger i = 0; i < results.count; i++) [slots addObject:NSNull.null];
    dispatch_group_t g = dispatch_group_create();
    [results enumerateObjectsUsingBlock:^(PHPickerResult *r, NSUInteger idx, BOOL *stop) {
        if (![r.itemProvider canLoadObjectOfClass:UIImage.class]) return;
        dispatch_group_enter(g);
        [r.itemProvider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
            if ([obj isKindOfClass:UIImage.class]) @synchronized (slots) { slots[idx] = obj; }
            dispatch_group_leave(g);
        }];
    }];
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        NSMutableArray *out = [NSMutableArray array];
        for (id o in slots) if ([o isKindOfClass:UIImage.class]) [out addObject:o];
        if (cb) cb(out);
    });
}
- (void)imagePickerController:(UIImagePickerController *)p didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [p dismissViewControllerAnimated:YES completion:nil];
    if (self.onImages) self.onImages(img ? @[img] : @[]);
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)p {
    [p dismissViewControllerAnimated:YES completion:nil];
    if (self.onImages) self.onImages(@[]);
}
@end

// ============================================================================
// VSTool — điều phối 4 chức năng
// ============================================================================
@interface VSRootVC : UIViewController @end

@interface VSTool : NSObject
@property (nonatomic, strong) VSPassWindow *window;
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) VSPickerDelegate *pickerDelegate;
@property (nonatomic, copy) NSString *busyName;           // nil = rảnh
@property (nonatomic, strong) id savedQRDelegate;
@property (nonatomic) BOOL savedQRDelegateValid;
@property (nonatomic, copy) void (^barOK)(void);
@property (nonatomic, copy) void (^barCancel)(void);
+ (instancetype)shared;
- (void)installIfNeeded;
- (void)clampFab;
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

// ------------------------------- Dựng UI ------------------------------------
- (void)installIfNeeded {
    if (self.window) return;
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
    fab.layer.borderWidth = 1.5; fab.layer.borderColor = [UIColor colorWithRed:0.35 green:0.85 blue:0.55 alpha:1].CGColor;
    [fab setTitle:@"VS" forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [fab setTitleColor:[UIColor colorWithRed:0.35 green:0.85 blue:0.55 alpha:1] forState:UIControlStateNormal];
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
    g_toolWindow = w;
    w.hidden = NO;
    VSInstallHooks();
    VSLog(@"installed");
}

- (void)clampFab {
    UIView *v = self.window.rootViewController.view;
    UIEdgeInsets in = v.safeAreaInsets;
    CGFloat hw = self.fab.bounds.size.width / 2;
    CGPoint c = self.fab.center;
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

- (void)status:(NSString *)text {
    UIView *root = self.window.rootViewController.view;
    self.statusLabel.text = text;
    CGFloat w = MIN(root.bounds.size.width - 32, 420);
    self.statusLabel.frame = CGRectMake((root.bounds.size.width - w) / 2, root.safeAreaInsets.top + 8, w, 40);
    self.statusLabel.hidden = (text.length == 0);
}

- (void)alert:(NSString *)msg {
    [self status:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"VideoStarTool" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self presenter] presentViewController:a animated:YES completion:nil];
}

- (void)hideBar { [self.bar removeFromSuperview]; self.bar = nil; }

- (void)showBar:(NSString *)msg ok:(NSString *)okTitle onOK:(void (^)(void))onOK onCancel:(void (^)(void))onCancel {
    [self hideBar];
    UIView *root = self.window.rootViewController.view;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(12, root.bounds.size.height - root.safeAreaInsets.bottom - 150, root.bounds.size.width - 24, 138)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    bar.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94]; bar.layer.cornerRadius = 14;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, bar.bounds.size.width - 28, 66)];
    l.numberOfLines = 3; l.text = msg; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:14];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar addSubview:l];
    self.barOK = onOK; self.barCancel = onCancel;
    NSArray *titles = @[okTitle, @"Hủy"];
    for (NSUInteger i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(14 + i * (bar.bounds.size.width - 28) / 2, 84, (bar.bounds.size.width - 28) / 2 - 6, 42);
        b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        b.backgroundColor = i == 0 ? [UIColor colorWithRed:0.20 green:0.65 blue:0.38 alpha:1] : [UIColor colorWithWhite:0.25 alpha:1];
        b.layer.cornerRadius = 10;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [b addTarget:self action:(i == 0 ? @selector(barOKTapped) : @selector(barCancelTapped)) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
    }
    [root addSubview:bar];
    self.bar = bar;
}

- (void)barOKTapped {
    void (^cb)(void) = self.barOK; self.barOK = nil; self.barCancel = nil;
    [self hideBar]; if (cb) cb();
}
- (void)barCancelTapped {
    void (^cb)(void) = self.barCancel; self.barOK = nil; self.barCancel = nil;
    [self hideBar]; if (cb) cb();
}

// ------------------------------ Menu & trạng thái ---------------------------
- (void)fabTapped {
    if (self.busyName) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Đang chạy" message:self.busyName preferredStyle:UIAlertControllerStyleAlert];
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
    @try { [qr setDelegate:self.savedQRDelegate]; } @catch (...) {}
    self.savedQRDelegate = nil; self.savedQRDelegateValid = NO;
}

- (void)stopRunQuiet {
    g_run++;
    g_pickedHandler = nil;
    [self restoreQRDelegate];
    [self hideBar];
    self.busyName = nil; self.fab.alpha = 1;
    [self status:nil];
}

- (void)endRun:(NSString *)message {
    [self stopRunQuiet];
    if (message.length) [self alert:message];
}

// ============================================================================
// CHỨC NĂNG 1 — Auto nhập ảnh vào các lớp hình ảnh
// ============================================================================
- (void)pickMediaOnEditor:(id)editor rid:(NSUInteger)rid completion:(void (^)(id resp, NSDictionary *info))done {
    if (!g_origPicked) { done(nil, nil); return; }
    g_pickedHandler = ^(id me, id resp) {
        if (rid != g_run || me != editor) return;
        g_pickedHandler = nil;
        __block NSDictionary *found = nil;
        VSPoll(rid, 120, 25, ^BOOL{
            id eng = [me getMultiLayerEngine]; NSInteger n = [me lastSelectedLayerNum];
            if (!eng || n < 0) return NO;
            found = VSLayerInfo(eng, (NSUInteger)n);
            return found != nil;
        }, ^(BOOL ok) { done(ok ? resp : nil, found); });
    };
    VSPoll(rid, 100, 60, ^BOOL{
        return [editor isViewLoaded] && [[editor view] window] && [editor getMultiLayerEngine];
    }, ^(BOOL ok) {
        if (!ok) { g_pickedHandler = nil; done(nil, nil); return; }
        VSAfter(80, ^{
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
        @try {
            [editor selectLayer:n bordered:NO];
            if ([editor lastSelectedLayerNum] != (NSInteger)n) [editor selectLayerNum:n flash:NO];
        } @catch (NSException *e) { VSLog(@"select layer %lu exception: %@", (unsigned long)n, e.reason ?: e.name); step(); return; }
        VSAfter(40, ^{
            if (rid != g_run) { step = nil; return; }
            id layer = [engine layerAtLayerNum:n];
            if (!layer) { step(); return; }
            id before = VSGenMedia(layer);
            @try { [editor presentMLLayerButtonsCollectionViewItemLayerEditTitleViewWithMultiLayerLayer:layer]; } @catch (...) {}
            VSReplayPicked(editor, resp);
            VSPoll(rid, 45, 24, ^BOOL{
                id now = VSGenMedia([engine layerAtLayerNum:n]);
                return now && now != before;
            }, ^(BOOL ok) {
                if (ok) changed++; else VSLog(@"layer %lu: media chưa xác minh được", (unsigned long)n);
                @try { [editor dismissMLLayerButtonsCollectionViewItemLayerEditTitleView]; } @catch (...) {}
                VSAfter(15, ^{ step(); });
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
        if (!resp) { [self endRun:@"Video Star đã nhận lựa chọn nhưng không lấy được media từ lớp vừa chọn."]; return; }
        [self applyResponse:resp toEditor:editor kind:info[@"kind"] skip:[info[@"layerNum"] integerValue] rid:rid
                 completion:^(NSUInteger changed, NSUInteger total) {
            [self endRun:total == 0 ? @"Không có lớp nào khác cùng loại để thay."
                                    : [NSString stringWithFormat:@"Đã thay media ở %lu/%lu lớp.", (unsigned long)changed, (unsigned long)total]];
        }];
    }];
}

// ============================================================================
// CHỨC NĂNG 2 — Hiển thị code gần nhất từng nhập
// ============================================================================
- (void)runLastCode {
    UIImage *img = VSLoadLastQR();
    if (img) { [self showCodeImage:img]; return; }
    [self status:@"Đang tìm ảnh code gần nhất…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *home = NSHomeDirectory();
        NSArray *roots = @[[home stringByAppendingPathComponent:@"Library/Caches"],
                           [home stringByAppendingPathComponent:@"Library/Application Support"],
                           [home stringByAppendingPathComponent:@"Documents"]];
        NSSet *exts = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"heic"]];
        NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
        for (NSString *root in roots) {
            NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root]
                includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLIsDirectoryKey]
                                   options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
            for (NSURL *u in en) {
                NSNumber *isDir; [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
                if (isDir.boolValue || ![exts containsObject:u.pathExtension.lowercaseString]) continue;
                NSDate *mod; [u getResourceValue:&mod forKey:NSURLContentModificationDateKey error:nil];
                [files addObject:@{@"url": u, @"date": mod ?: NSDate.distantPast}];
                if (files.count >= 300) break;
            }
            if (files.count >= 300) break;
        }
        [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"date"] compare:a[@"date"]]; }];
        UIImage *found = nil;
        for (NSDictionary *f in files) {
            UIImage *im = [UIImage imageWithContentsOfFile:[(NSURL *)f[@"url"] path]];
            if (VSDecodeQR(im)) { found = im; break; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self status:nil];
            if (!found) { [self alert:@"Không tìm thấy ảnh code đã nhập gần nhất."]; return; }
            VSRememberLastQR(UIImagePNGRepresentation(found));
            [self showCodeImage:found];
        });
    });
}

- (void)showCodeImage:(UIImage *)img {
    VSImageVC *vc = [VSImageVC new];
    vc.image = img;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    [[self presenter] presentViewController:vc animated:YES completion:nil];
}

// ============================================================================
// CHỨC NĂNG 3 — Auto chia beat
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
        if (!ok || !sv) { [self endRun:@"Không tìm thấy chức năng chia beat gốc của Video Star."]; return; }
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
            bad = @"Phân cảnh chưa có clip hợp lệ hoặc bộ nhớ không đủ để chia.";
        id fm = [project fileManager];
        for (NSUInteger i = 0; !bad && fm && i < clips; i++) {
            NSURL *u = [fm clipURLForSceneIndex:scene clipIndex:i];
            if (![u isKindOfClass:NSURL.class] || ![NSFileManager.defaultManager fileExistsAtPath:u.path]) { bad = @"Tất cả clip trong phân cảnh phải hợp lệ trước khi chia."; break; }
            AVURLAsset *a = [AVURLAsset URLAssetWithURL:u options:nil];
            if ([a tracksWithMediaType:AVMediaTypeVideo].count == 0 || CMTIME_IS_INVALID(a.duration)) bad = @"Tất cả clip trong phân cảnh phải hợp lệ trước khi chia.";
        }
    } @catch (NSException *e) { bad = [NSString stringWithFormat:@"Video Star gặp lỗi khi chuẩn bị chia beat: %@", e.reason ?: e.name]; }
    if (bad) { [self endRun:bad]; return; }

    id project = [vc project];
    NSUInteger sceneBefore = [project sceneCount];
    @try {
        if (![sv beatModeOn]) [sv toggleBeatMode];
        [sv gotoTime:kCMTimeZero];                       // bắt đầu từ đầu phân cảnh
    } @catch (NSException *e) { [self endRun:[NSString stringWithFormat:@"Không bật được chế độ beat: %@", e.reason ?: e.name]]; return; }

    __block NSUInteger guard = 0, queued = 0;
    __block CMTime last = kCMTimeInvalid;
    __block void (^step)(void) = nil;

    void (^finish)(void) = ^{
        step = nil;
        if (rid != g_run) return;
        NSUInteger have = [VSValue(sv, @"splitTimes") count];
        if (queued == 0 && have == 0) { [self endRun:@"Không còn beat nào để chia trong phân cảnh hiện tại."]; return; }
        @try { [sv doSplit]; } @catch (NSException *e) { [self endRun:[NSString stringWithFormat:@"Không thể chia beat: %@", e.reason ?: e.name]]; return; }
        [self status:@"Đang chia phân cảnh…"];
        VSPoll(rid, 100, 150, ^BOOL{ return [project sceneCount] > sceneBefore; }, ^(BOOL ok) {
            [self endRun:ok ? [NSString stringWithFormat:@"Chia beat thành công: thêm %lu phân cảnh.", (unsigned long)([project sceneCount] - sceneBefore)]
                            : @"Video Star chưa hoàn tất thao tác chia. Hãy kiểm tra lại phân cảnh (có thể đang chờ bạn xác nhận)."];
        });
    };

    step = ^{
        if (rid != g_run) { step = nil; return; }
        if (++guard >= 4096 || ![sv hasNextBeat]) { finish(); return; }
        CMTime from = VSCurrentTime(sv);                 // ✅ đã fix
        [sv jumpToNextBeat];
        VSPoll(rid, 12, 100, ^BOOL{
            CMTime cur = VSCurrentTime(sv);              // ✅ đã fix
            return CMTIME_IS_VALID(cur) && (CMTIME_IS_INVALID(from) || CMTimeCompare(cur, from) > 0);
        }, ^(BOOL moved) {
            CMTime cur = VSCurrentTime(sv);              // ✅ đã fix
            if (!moved || (CMTIME_IS_VALID(last) && CMTimeCompare(cur, last) <= 0)) { finish(); return; }   // hết beat
            last = cur;
            [sv setSplitPoint];
            queued++;
            [self status:[NSString stringWithFormat:@"Đã đặt %lu điểm chia theo beat…", (unsigned long)queued]];
            VSAfter(15, ^{ step(); });
        });
    };
    VSAfter(220, ^{ step(); });   // chờ UI beat bật xong
}

// ============================================================================
// CHỨC NĂNG 4 — Auto nhập code + ảnh vào các phân cảnh
// ============================================================================
- (void)runMultiScene {
    id vc = VSFindVC(@"VideoReviewEditVC");
    if (!vc) { [self alert:@"Bạn chưa ở trong phần chia phân cảnh."]; return; }
    NSUInteger rid = [self beginRun:@"Auto nhập code + ảnh vào phân cảnh" status:nil];
    NSUInteger origLast = [vc lastViewedSceneIndex];
    @try { [vc showMergeScenes]; } @catch (NSException *e) { [self endRun:[NSString stringWithFormat:@"Không mở được Hợp nhất phân cảnh: %@", e.reason ?: e.name]]; return; }
    [self showBar:@"Chọn phân cảnh ĐẦU và CUỐI trong bảng Hợp nhất phân cảnh, rồi bấm Bắt đầu."
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
        [self endRun:@"Chưa chọn được phạm vi hợp lệ. Hãy chọn lại trong Hợp nhất phân cảnh."];
        @try { [vc closeMergePanel]; } @catch (...) {}
        return;
    }
    @try { [vc closeMergePanel]; } @catch (...) {}
    NSUInteger count = (NSUInteger)(last - start + 1);
    [self status:[NSString stringWithFormat:@"Chọn ảnh QR (%lu phân cảnh). Chọn 1 ảnh = dùng cho tất cả; hoặc chọn đủ %lu ảnh theo thứ tự.", (unsigned long)count, (unsigned long)count]];
    [self pickImagesMax:count rid:rid completion:^(NSArray<UIImage *> *imgs) {
        if (rid != g_run) return;
        if (!imgs.count) { [self endRun:nil]; return; }
        if (imgs.count != 1 && imgs.count != count) {
            [self endRun:[NSString stringWithFormat:@"Cần 1 ảnh hoặc đúng %lu ảnh, bạn chọn %lu.", (unsigned long)count, (unsigned long)imgs.count]]; return;
        }
        NSMutableArray<NSString *> *codes = [NSMutableArray array];
        NSMutableArray<NSData *> *datas = [NSMutableArray array];
        for (NSUInteger i = 0; i < imgs.count; i++) {
            NSString *code = VSDecodeQR(imgs[i]);
            if (!code.length) { [self endRun:[NSString stringWithFormat:@"Ảnh thứ %lu không đọc được mã QR.", (unsigned long)(i + 1)]]; return; }
            [codes addObject:code]; [datas addObject:UIImagePNGRepresentation(imgs[i]) ?: NSData.data];
        }
        [self msPickMediaAndRun:vc start:(NSUInteger)start count:count codes:codes datas:datas rid:rid origLast:origLast];
    }];
}

- (void)msPickMediaAndRun:(id)vc start:(NSUInteger)start count:(NSUInteger)count codes:(NSArray<NSString *> *)codes
                    datas:(NSArray<NSData *> *)datas rid:(NSUInteger)rid origLast:(NSUInteger)origLast {
    [self status:@"Đang mở Nhiều lớp ở phân cảnh đầu…"];
    [self openEditorForScene:start review:vc rid:rid completion:^(id editor) {
        if (!editor) { [self endRun:@"Không mở được phần Nhiều lớp của Video Star."]; return; }
        [self status:@"Chọn 1 ảnh/video dùng chung trong bộ chọn của Video Star…"];
        [self pickMediaOnEditor:editor rid:rid completion:^(id resp, NSDictionary *info) {
            if (!resp) { [self endRun:@"Không lấy được ảnh/video vừa chọn."]; return; }
            [self msRunScenes:start count:count codes:codes datas:datas resp:resp rid:rid origLast:origLast];
        }];
    }];
}

- (void)msRunScenes:(NSUInteger)start count:(NSUInteger)count codes:(NSArray<NSString *> *)codes datas:(NSArray<NSData *> *)datas
               resp:(id)resp rid:(NSUInteger)rid origLast:(NSUInteger)origLast {
    __block NSUInteger offset = 0, okCount = 0;
    __block void (^sceneStep)(void) = nil;
    void (^finish)(NSString *) = ^(NSString *err) {
        sceneStep = nil;
        id rvc = VSFindVC(@"VideoReviewEditVC");
        @try { [rvc setLastViewedSceneIndex:origLast]; } @catch (...) {}
        NSString *msg = [NSString stringWithFormat:@"Đã áp dụng code + ảnh cho %lu/%lu phân cảnh.", (unsigned long)okCount, (unsigned long)count];
        [self endRun:err ? [err stringByAppendingFormat:@"\n%@", msg] : msg];
    };
    sceneStep = ^{
        if (rid != g_run) { sceneStep = nil; return; }
        if (offset >= count) { finish(nil); return; }
        NSUInteger off = offset++;
        NSUInteger scene = start + off;
        NSUInteger ci = codes.count == 1 ? 0 : off;
        [self status:[NSString stringWithFormat:@"Phân cảnh %lu (%lu/%lu): nhập code…", (unsigned long)(scene + 1), (unsigned long)(off + 1), (unsigned long)count]];
        id rvc = VSFindVC(@"VideoReviewEditVC");
        [self openEditorForScene:scene review:rvc rid:rid completion:^(id editor) {
            if (!editor) { finish([NSString stringWithFormat:@"Không mở được Nhiều lớp ở phân cảnh %lu.", (unsigned long)(scene + 1)]); return; }
            [self importCode:codes[ci] data:datas[ci] intoEditor:editor rid:rid completion:^(NSString *err) {
                if (err) { finish([NSString stringWithFormat:@"Phân cảnh %lu: %@", (unsigned long)(scene + 1), err]); return; }
                [self status:[NSString stringWithFormat:@"Phân cảnh %lu: thay ảnh/video…", (unsigned long)(scene + 1)]];
                [self applyResponse:resp toEditor:editor kind:nil skip:-1 rid:rid completion:^(NSUInteger changed, NSUInteger total) {
                    [self status:[NSString stringWithFormat:@"Phân cảnh %lu: đang Create…", (unsigned long)(scene + 1)]];
                    [self createInEditor:editor rid:rid completion:^(NSString *cerr) {
                        if (cerr) { finish([NSString stringWithFormat:@"Phân cảnh %lu: %@", (unsigned long)(scene + 1), cerr]); return; }
                        okCount++;
                        VSPoll(rid, 100, 100, ^BOOL{ return VSFindVC(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                            if (!back) { finish(@"Không quay lại được màn hình phân cảnh."); return; }
                            VSAfter(150, ^{ sceneStep(); });
                        });
                    }];
                }];
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

- (void)importCode:(NSString *)code data:(NSData *)data intoEditor:(id)editor rid:(NSUInteger)rid completion:(void (^)(NSString *err))done {
    id qr = [NSClassFromString(@"QRCodeManager") respondsToSelector:@selector(sharedInstance)] ? [NSClassFromString(@"QRCodeManager") sharedInstance] : nil;
    if (!qr || ![qr respondsToSelector:@selector(selectedCode:withImageData:)]) { done(@"Không tìm thấy bộ xử lý code của Video Star."); return; }
    if (!self.savedQRDelegateValid) { self.savedQRDelegate = VSValue(qr, @"delegate"); self.savedQRDelegateValid = YES; }
    NSUInteger snap = g_importCount;
    @try {
        [qr setDelegate:editor];
        [qr selectedCode:code withImageData:data];
    } @catch (NSException *e) { [self restoreQRDelegate]; done([NSString stringWithFormat:@"Không nhập được code: %@", e.reason ?: e.name]); return; }

    __block BOOL blocked = NO;
    VSPoll(rid, 40, 250, ^BOOL{
        VSPopupResult r = VSHandleEditorPopups(editor);
        if (r == VSPopupBlocked) { blocked = YES; return YES; }
        return g_importCount > snap;
    }, ^(BOOL ok) {
        if (blocked) { [self restoreQRDelegate]; done(@"Video Star hiện popup yêu cầu mua gói — tool không tự bấm. Dừng."); return; }
        if (!ok) { [self restoreQRDelegate]; done(@"Code chưa được Video Star nhập xong (hết thời gian chờ)."); return; }
        VSAfter(700, ^{
            id engine = [editor getMultiLayerEngine];
            VSPoll(rid, 60, 80, ^BOOL{
                VSHandleEditorPopups(editor);
                return !VSEditorHasVisiblePopup(editor) && [engine numActiveLayers] > 0;
            }, ^(BOOL ready) {
                [self restoreQRDelegate];
                done(ready ? nil : @"Code đã nhập nhưng phần Nhiều lớp chưa sẵn sàng.");
            });
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
    } @catch (NSException *e) { done([NSString stringWithFormat:@"Không bấm được Create: %@", e.reason ?: e.name]); return; }
    if (!fired) { done(@"Không tìm thấy nút Create của Video Star."); return; }
    __block BOOL blocked = NO;
    VSPoll(rid, 100, 600, ^BOOL{
        if (VSHandleEditorPopups(editor) == VSPopupBlocked) { blocked = YES; return YES; }
        return !([editor isViewLoaded] && [[editor view] window]);
    }, ^(BOOL closed) {
        done(blocked ? @"Create yêu cầu mua gói — tool không tự bấm. Dừng."
                     : (closed ? nil : @"Create chưa hoàn tất (hết thời gian chờ)."));
    });
}

- (void)pickImagesMax:(NSUInteger)maxCount rid:(NSUInteger)rid completion:(void (^)(NSArray<UIImage *> *))done {
    VSPickerDelegate *d = [VSPickerDelegate new];
    self.pickerDelegate = d;
    d.onImages = ^(NSArray<UIImage *> *imgs) { self.pickerDelegate = nil; done(imgs); };
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.filter = [PHPickerFilter imagesFilter];
        cfg.selectionLimit = (NSInteger)maxCount;
        if (@available(iOS 15.0, *)) cfg.selection = PHPickerConfigurationSelectionOrdered;
        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        pk.delegate = d;
        [[self presenter] presentViewController:pk animated:YES completion:nil];
    } else {
        UIImagePickerController *pk = [UIImagePickerController new];
        pk.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        pk.delegate = d;
        [[self presenter] presentViewController:pk animated:YES completion:nil];
    }
}

@end

// ============================================================================
// Entry point
// ============================================================================
static void VSBootstrap(void) {
    if (!NSClassFromString(@"MultiLayerWizEffectVC")) { VSLog(@"không phải Video Star, bỏ qua"); return; }
    [VSTool.shared installIfNeeded];
}

__attribute__((constructor)) static void VSToolInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { VSBootstrap(); }];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) VSBootstrap();
    });
}
