//
//  VideoStarTool.m
//  Single-file Objective-C Tweak -> Build ra VideoStarTool.dylib / ZZZZZZVideoStarTool.dylib
//  Target: iOS 14.0+ (arm64), ARC, đã sửa lỗi ARC getter naming (imgCopyBtn)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Helpers & Colors (An toàn iOS 14 - 18)

static inline void VSRunOnMain(dispatch_block_t block) {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static inline UIColor *VSColorCyan(void) {
    return [UIColor colorWithRed:0.18 green:0.78 blue:0.96 alpha:1.0];
}

static inline UIColor *VSColorPurple(void) {
    return [UIColor colorWithRed:0.55 green:0.36 blue:0.98 alpha:1.0];
}

static inline UIColor *VSColorGreen(void) {
    return [UIColor colorWithRed:0.18 green:0.82 blue:0.46 alpha:1.0];
}

static inline UIColor *VSColorRed(void) {
    return [UIColor colorWithRed:0.92 green:0.26 blue:0.32 alpha:1.0];
}

static inline void VSInvokeVoidBlockSafe(id maybeBlock) {
    if (!maybeBlock) return;
    Class blockCls = NSClassFromString(@"NSBlock");
    if (blockCls && ![maybeBlock isKindOfClass:blockCls]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            ((void (^)(void))maybeBlock)();
        } @catch (NSException *ex) {}
    });
}

/// Swizzle an toàn: không ghi đè nhầm hàm của superclass nếu subclass chưa override
static BOOL VSSwizzleMethod(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    IMP oldImp = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (origOut) *origOut = oldImp;

    if (class_addMethod(cls, sel, newImp, types)) {
        return YES;
    } else {
        method_setImplementation(m, newImp);
        return YES;
    }
}

#pragma mark - Enums & Models

typedef NS_ENUM(NSInteger, VSScreenMode) {
    VSScreenModeNone = 0,
    VSScreenModeSplitScene,
    VSScreenModeMultiLayer
};

typedef NS_ENUM(NSInteger, VSF4State) {
    VSF4StateIdle = 0,
    VSF4StatePickingQRs,
    VSF4StateDecodingQRs,
    VSF4StateImportingQR,
    VSF4StatePickingFirstImage,
    VSF4StateBatchFillingLayers,
    VSF4StateCreatingSegment,
    VSF4StateAdvancingSegment
};

@interface VSQRItem : NSObject
@property (nonatomic, copy) NSString *code;
@property (nonatomic, strong, nullable) NSData *jpegData;
@end

@implementation VSQRItem
@end

#pragma mark - Forward Declarations

@class VSContextualBar;

@interface VSToolEngine : NSObject <PHPickerViewControllerDelegate>

@property (nonatomic, assign, readonly) VSF4State state;
@property (nonatomic, assign, readonly) BOOL isFeature4Running;
@property (nonatomic, assign, readonly) NSInteger currentSegmentIndex;
@property (nonatomic, assign, readonly) NSInteger totalSegments;
@property (nonatomic, weak, nullable) UIViewController *activeMultiLayerVC;
@property (nonatomic, strong, nullable) UIImage *cachedFirstSegmentImage;
@property (nonatomic, strong, nullable) UIImage *feature1CopiedImage;

+ (instancetype)shared;
- (BOOL)shouldBypassMatchDialogs;
- (void)startFeature4WithSegmentCount:(NSInteger)count;
- (void)stopFeature4WithMessage:(nullable NSString *)message;
- (void)runSplitSceneFromView:(nullable UIView *)anchorView;
- (void)runFeature1CopyImage;

- (void)onPresetSetupLayerNum:(NSUInteger)layerNum needsMedia:(BOOL)needsMedia;
- (void)onQRImportAppliedOnVC:(UIViewController *)vc;
- (void)onCreateFinishedOnVC:(UIViewController *)vc;
- (void)onMultiLayerAppeared:(UIViewController *)vc;
- (BOOL)interceptPresentedVC:(UIViewController *)vcToPresent;

@end

#pragma mark - Thanh Nút Mini Gọn Gàng Theo Ngữ Cảnh (Không còn Menu 3 Ngón Tay)

@interface VSContextualBar : NSObject

@property (nonatomic, strong) UIView *pillView;
@property (nonatomic, strong) UIButton *minusBtn;
@property (nonatomic, strong) UILabel *countLbl;
@property (nonatomic, strong) UIButton *plusBtn;
@property (nonatomic, strong) UIButton *startBtn;
@property (nonatomic, strong) UIButton *imgCopyBtn;

@property (nonatomic, assign) VSScreenMode mode;
@property (nonatomic, assign) NSInteger selectedSegments;
@property (nonatomic, weak, nullable) UIView *splitAnchorView;
@property (nonatomic, assign) CGPoint savedCenter;
@property (nonatomic, assign) BOOL hasSavedPos;

+ (instancetype)shared;
- (void)showMode:(VSScreenMode)mode inWindow:(nullable UIWindow *)window anchorView:(nullable UIView *)anchorView;
- (void)refreshRunningState;
- (void)hide;

@end

@implementation VSContextualBar

+ (instancetype)shared {
    static VSContextualBar *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VSContextualBar alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = VSScreenModeNone;
        _selectedSegments = 3;
    }
    return self;
}

- (void)setupViewsIfNeeded {
    if (self.pillView) return;

    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 222, 34)];
    pill.backgroundColor = [[UIColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:1.0] colorWithAlphaComponent:0.92];
    pill.layer.cornerRadius = 17.0;
    pill.layer.borderWidth = 1.0;
    pill.layer.borderColor = VSColorPurple().CGColor;
    pill.layer.shadowColor = [UIColor blackColor].CGColor;
    pill.layer.shadowOpacity = 0.35;
    pill.layer.shadowRadius = 4.0;
    pill.layer.shadowOffset = CGSizeMake(0, 2);

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [pill addGestureRecognizer:pan];

    UIButton *minus = [UIButton buttonWithType:UIButtonTypeSystem];
    [minus setTitle:@"−" forState:UIControlStateNormal];
    [minus setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    minus.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [minus addTarget:self action:@selector(onMinus) forControlEvents:UIControlEventTouchUpInside];
    [pill addSubview:minus];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    lbl.textColor = [UIColor whiteColor];
    lbl.textAlignment = NSTextAlignmentCenter;
    [pill addSubview:lbl];

    UIButton *plus = [UIButton buttonWithType:UIButtonTypeSystem];
    [plus setTitle:@"+" forState:UIControlStateNormal];
    [plus setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    plus.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [plus addTarget:self action:@selector(onPlus) forControlEvents:UIControlEventTouchUpInside];
    [pill addSubview:plus];

    UIButton *start = [UIButton buttonWithType:UIButtonTypeSystem];
    start.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [start setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    start.layer.cornerRadius = 12.0;
    start.layer.masksToBounds = YES;
    [start addTarget:self action:@selector(onStartTap) forControlEvents:UIControlEventTouchUpInside];
    [pill addSubview:start];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"📋" forState:UIControlStateNormal];
    copy.titleLabel.font = [UIFont systemFontOfSize:13];
    copy.backgroundColor = [VSColorGreen() colorWithAlphaComponent:0.28];
    copy.layer.cornerRadius = 12.0;
    copy.layer.masksToBounds = YES;
    [copy addTarget:self action:@selector(onCopyTap) forControlEvents:UIControlEventTouchUpInside];
    [pill addSubview:copy];

    self.pillView = pill;
    self.minusBtn = minus;
    self.countLbl = lbl;
    self.plusBtn = plus;
    self.startBtn = start;
    self.imgCopyBtn = copy;
}

- (void)showMode:(VSScreenMode)mode inWindow:(nullable UIWindow *)window anchorView:(nullable UIView *)anchorView {
    VSRunOnMain(^{
        if (mode == VSScreenModeNone || !window) {
            [self hide];
            return;
        }

        [self setupViewsIfNeeded];
        self.mode = mode;
        self.splitAnchorView = anchorView;

        if (self.pillView.superview != window) {
            [self.pillView removeFromSuperview];
            [window addSubview:self.pillView];
        }
        [window bringSubviewToFront:self.pillView];
        self.pillView.hidden = NO;

        CGFloat height = 34.0;
        CGFloat width = 108.0;

        if (mode == VSScreenModeSplitScene) {
            self.minusBtn.hidden = YES;
            self.countLbl.hidden = YES;
            self.plusBtn.hidden = YES;
            self.imgCopyBtn.hidden = YES;

            width = 108.0;
            self.pillView.layer.borderColor = VSColorCyan().CGColor;
            self.startBtn.backgroundColor = [VSColorCyan() colorWithAlphaComponent:0.32];
            [self.startBtn setTitle:@"⚡ Chia đoạn" forState:UIControlStateNormal];
            self.startBtn.frame = CGRectMake(4, 4, width - 8, height - 8);
        } else if (mode == VSScreenModeMultiLayer) {
            self.minusBtn.hidden = NO;
            self.countLbl.hidden = NO;
            self.plusBtn.hidden = NO;
            self.imgCopyBtn.hidden = NO;

            width = 222.0;
            self.minusBtn.frame = CGRectMake(4, 2, 24, 30);
            self.countLbl.frame = CGRectMake(28, 2, 34, 30);
            self.countLbl.text = [NSString stringWithFormat:@"%ldđ", (long)self.selectedSegments];
            self.plusBtn.frame = CGRectMake(62, 2, 24, 30);
            self.startBtn.frame = CGRectMake(88, 4, 96, height - 8);
            self.imgCopyBtn.frame = CGRectMake(188, 4, 30, height - 8);
            [self refreshRunningState];
        }

        self.pillView.bounds = CGRectMake(0, 0, width, height);
        if (self.hasSavedPos) {
            self.pillView.center = [self clampCenter:self.savedCenter inWindow:window];
        } else {
            CGFloat topSafe = window.safeAreaInsets.top;
            self.pillView.center = CGPointMake(window.bounds.size.width - width * 0.5 - 10.0, topSafe + 50.0);
        }
    });
}

- (void)refreshRunningState {
    VSRunOnMain(^{
        if (self.mode != VSScreenModeMultiLayer || !self.pillView) return;
        VSToolEngine *eng = [VSToolEngine shared];
        if (eng.isFeature4Running) {
            self.pillView.layer.borderColor = VSColorRed().CGColor;
            self.startBtn.backgroundColor = VSColorRed();
            NSString *title = (eng.totalSegments > 0)
                ? [NSString stringWithFormat:@"⏹ %ld/%ld", (long)(eng.currentSegmentIndex + 1), (long)eng.totalSegments]
                : @"⏹ Dừng";
            [self.startBtn setTitle:title forState:UIControlStateNormal];
            self.minusBtn.enabled = NO;
            self.plusBtn.enabled = NO;
            self.minusBtn.alpha = 0.4;
            self.plusBtn.alpha = 0.4;
        } else {
            self.pillView.layer.borderColor = VSColorPurple().CGColor;
            self.startBtn.backgroundColor = VSColorPurple();
            [self.startBtn setTitle:@"▶ Chọn QR" forState:UIControlStateNormal];
            self.minusBtn.enabled = YES;
            self.plusBtn.enabled = YES;
            self.minusBtn.alpha = 1.0;
            self.plusBtn.alpha = 1.0;
        }
    });
}

- (void)hide {
    VSRunOnMain(^{
        self.mode = VSScreenModeNone;
        if (self.pillView) self.pillView.hidden = YES;
    });
}

- (CGPoint)clampCenter:(CGPoint)pt inWindow:(UIWindow *)win {
    CGFloat hw = self.pillView.bounds.size.width * 0.5;
    CGFloat hh = self.pillView.bounds.size.height * 0.5;
    UIEdgeInsets s = win.safeAreaInsets;
    return CGPointMake(
        MIN(MAX(pt.x, s.left + hw + 6.0), win.bounds.size.width - s.right - hw - 6.0),
        MIN(MAX(pt.y, s.top + hh + 6.0), win.bounds.size.height - s.bottom - hh - 6.0)
    );
}

- (void)handlePan:(UIPanGestureRecognizer *)gr {
    UIView *sv = self.pillView.superview;
    if (![sv isKindOfClass:[UIWindow class]]) return;
    CGPoint d = [gr translationInView:sv];
    CGPoint next = CGPointMake(self.pillView.center.x + d.x, self.pillView.center.y + d.y);
    self.pillView.center = [self clampCenter:next inWindow:(UIWindow *)sv];
    [gr setTranslation:CGPointZero inView:sv];
    if (gr.state == UIGestureRecognizerStateEnded) {
        self.savedCenter = self.pillView.center;
        self.hasSavedPos = YES;
    }
}

- (void)onMinus {
    if (self.selectedSegments > 1) {
        self.selectedSegments--;
        self.countLbl.text = [NSString stringWithFormat:@"%ldđ", (long)self.selectedSegments];
    }
}

- (void)onPlus {
    if (self.selectedSegments < 50) {
        self.selectedSegments++;
        self.countLbl.text = [NSString stringWithFormat:@"%ldđ", (long)self.selectedSegments];
    }
}

- (void)onStartTap {
    if (self.mode == VSScreenModeSplitScene) {
        [[VSToolEngine shared] runSplitSceneFromView:self.splitAnchorView];
    } else if (self.mode == VSScreenModeMultiLayer) {
        [[VSToolEngine shared] startFeature4WithSegmentCount:self.selectedSegments];
    }
}

- (void)onCopyTap {
    [[VSToolEngine shared] runFeature1CopyImage];
}

@end

#pragma mark - Động Cơ Tự Động Hóa Chức Năng 4, Chia Đoạn & Chức Năng 1

@interface VSToolEngine ()

@property (nonatomic, assign, readwrite) VSF4State state;
@property (nonatomic, assign, readwrite) NSInteger currentSegmentIndex;
@property (nonatomic, copy, nullable) NSArray<VSQRItem *> *qrQueue;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *detectedMediaLayers;
@property (nonatomic, assign) NSUInteger sessionToken;
@property (nonatomic, assign) BOOL pickerForFirstImage;
@property (nonatomic, assign) BOOL presetHandledForSegment;
@property (nonatomic, assign) BOOL createHandledForSegment;
@property (nonatomic, weak) UILabel *toastLabel;

@end

@implementation VSToolEngine

+ (instancetype)shared {
    static VSToolEngine *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VSToolEngine alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = VSF4StateIdle;
        _detectedMediaLayers = [NSMutableSet set];
    }
    return self;
}

- (BOOL)isFeature4Running {
    return self.state != VSF4StateIdle;
}

- (NSInteger)totalSegments {
    return (NSInteger)self.qrQueue.count;
}

- (BOOL)shouldBypassMatchDialogs {
    return self.isFeature4Running &&
           (self.state == VSF4StateImportingQR ||
            self.state == VSF4StatePickingFirstImage ||
            self.state == VSF4StateBatchFillingLayers);
}

#pragma mark - Window, TopVC & Toast

- (nullable UIWindow *)activeWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow && !w.hidden) return w;
                }
                if (ws.windows.firstObject) return ws.windows.firstObject;
            }
        }
    }
    return nil;
}

- (nullable UIViewController *)topMostVC {
    UIViewController *top = [self activeWindow].rootViewController;
    while (top) {
        if (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
            top = top.presentedViewController;
        } else if ([top isKindOfClass:[UINavigationController class]]) {
            UIViewController *vis = ((UINavigationController *)top).visibleViewController;
            if (!vis || vis == top) break;
            top = vis;
        } else if ([top isKindOfClass:[UITabBarController class]]) {
            UIViewController *sel = ((UITabBarController *)top).selectedViewController;
            if (!sel || sel == top) break;
            top = sel;
        } else {
            break;
        }
    }
    return top;
}

- (void)showToast:(NSString *)msg color:(UIColor *)color {
    if (msg.length == 0) return;
    VSRunOnMain(^{
        UIWindow *win = [self activeWindow];
        if (!win) return;
        [self.toastLabel removeFromSuperview];

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = [NSString stringWithFormat:@"  %@  ", msg];
        lbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        lbl.textColor = [UIColor whiteColor];
        lbl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.86];
        lbl.layer.cornerRadius = 14.0;
        lbl.layer.masksToBounds = YES;
        lbl.layer.borderWidth = 1.0;
        lbl.layer.borderColor = (color ?: VSColorCyan()).CGColor;
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.numberOfLines = 2;
        lbl.userInteractionEnabled = NO;

        CGFloat maxW = win.bounds.size.width - 40.0;
        CGSize fit = [lbl sizeThatFits:CGSizeMake(maxW, 56.0)];
        CGFloat w = MIN(maxW, MAX(120.0, fit.width + 20.0));
        CGFloat h = MAX(28.0, fit.height + 10.0);
        lbl.frame = CGRectMake((win.bounds.size.width - w) * 0.5, win.safeAreaInsets.top + 8.0, w, h);
        lbl.alpha = 0.0;
        [win addSubview:lbl];
        self.toastLabel = lbl;

        [UIView animateWithDuration:0.15 animations:^{ lbl.alpha = 1.0; }];

        __weak UILabel *weakLbl = lbl;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UILabel *strongLbl = weakLbl;
            if (!strongLbl) return;
            [UIView animateWithDuration:0.2 animations:^{ strongLbl.alpha = 0.0; } completion:^(BOOL f) {
                [strongLbl removeFromSuperview];
            }];
        });
    });
}

#pragma mark - UI Control Lookup Helpers

- (void)collectViewsFrom:(UIView *)root into:(NSMutableArray<UIView *> *)outArr {
    if (!root || root.hidden || root.alpha < 0.05) return;
    [outArr addObject:root];
    for (UIView *sub in root.subviews) {
        [self collectViewsFrom:sub into:outArr];
    }
}

- (nullable UIControl *)findControlIn:(UIView *)root keywords:(NSArray<NSString *> *)keywords {
    if (!root || keywords.count == 0) return nil;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    [self collectViewsFrom:root into:views];

    for (UIView *v in views) {
        if (![v isKindOfClass:[UIControl class]] || !v.userInteractionEnabled) continue;
        UIControl *ctrl = (UIControl *)v;
        if (!ctrl.enabled) continue;

        NSString *text = nil;
        if ([ctrl isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)ctrl;
            text = b.currentTitle ?: b.titleLabel.text ?: b.accessibilityLabel;
        } else {
            text = ctrl.accessibilityLabel;
            if (text.length == 0) {
                for (UIView *sub in ctrl.subviews) {
                    if ([sub isKindOfClass:[UILabel class]]) {
                        text = ((UILabel *)sub).text;
                        if (text.length > 0) break;
                    }
                }
            }
        }
        if (text.length == 0) continue;
        NSString *lower = [text lowercaseString];
        for (NSString *kw in keywords) {
            if ([lower containsString:[kw lowercaseString]]) return ctrl;
        }
    }
    return nil;
}

- (BOOL)safeTap:(nullable UIControl *)ctrl {
    if (!ctrl || ctrl.hidden || !ctrl.enabled) return NO;
    @try {
        [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    } @catch (NSException *ex) {
        return NO;
    }
}

#pragma mark - Normalize Image & 3-Tier QR Decoder

- (UIImage *)normalizeImage:(UIImage *)img maxDim:(CGFloat)maxDim {
    if (!img || img.size.width <= 0 || img.size.height <= 0) return img;
    CGFloat longest = MAX(img.size.width, img.size.height);
    CGFloat scale = (maxDim > 0 && longest > maxDim) ? (maxDim / longest) : 1.0;
    if (scale == 1.0 && img.imageOrientation == UIImageOrientationUp) return img;

    CGSize sz = CGSizeMake(floor(img.size.width * scale), floor(img.size.height * scale));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    fmt.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    }];
}

- (nullable NSString *)decodeQRCodeFromImage:(UIImage *)image {
    if (!image) return nil;
    static CIContext *ciCtx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ciCtx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @(NO) }];
    });

    @autoreleasepool {
        UIImage *safe = [self normalizeImage:image maxDim:1500.0];
        if (!safe.CGImage) return nil;

        CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                             context:ciCtx
                                             options:@{ CIDetectorAccuracy: CIDetectorAccuracyHigh }];
        if (!det) return nil;

        CIImage *ci = [CIImage imageWithCGImage:safe.CGImage];
        NSString *(^scan)(CIImage *) = ^NSString *(CIImage *target) {
            if (!target) return nil;
            for (CIFeature *f in [det featuresInImage:target]) {
                if ([f isKindOfClass:[CIQRCodeFeature class]]) {
                    NSString *s = [((CIQRCodeFeature *)f).messageString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (s.length > 0) return s;
                }
            }
            return nil;
        };

        // Tầng 1: Quét trực tiếp
        NSString *res = scan(ci);
        if (res.length > 0) return res;

        // Tầng 2: Khử màu + tăng độ tương phản
        CIFilter *flt = [CIFilter filterWithName:@"CIColorControls"];
        if (flt) {
            [flt setValue:ci forKey:kCIInputImageKey];
            [flt setValue:@(0.0) forKey:kCIInputSaturationKey];
            [flt setValue:@(1.85) forKey:kCIInputContrastKey];
            res = scan(flt.outputImage);
            if (res.length > 0) return res;
        }

        // Tầng 3: Crop 5 vùng (giữa + 4 góc)
        CGRect e = ci.extent;
        CGRect boxes[5] = {
            CGRectMake(e.size.width * 0.15, e.size.height * 0.15, e.size.width * 0.70, e.size.height * 0.70),
            CGRectMake(0,                   e.size.height * 0.40, e.size.width * 0.60, e.size.height * 0.60),
            CGRectMake(e.size.width * 0.40, e.size.height * 0.40, e.size.width * 0.60, e.size.height * 0.60),
            CGRectMake(0,                   0,                    e.size.width * 0.60, e.size.height * 0.60),
            CGRectMake(e.size.width * 0.40, 0,                    e.size.width * 0.60, e.size.height * 0.60)
        };
        for (int i = 0; i < 5; i++) {
            @autoreleasepool {
                res = scan([ci imageByCroppingToRect:boxes[i]]);
                if (res.length > 0) return res;
            }
        }
    }
    return nil;
}

#pragma mark - Chức năng Chia Đoạn & Chức năng 1 (Copy Ảnh Gốc)

- (void)runSplitSceneFromView:(nullable UIView *)anchorView {
    VSRunOnMain(^{
        UIView *root = anchorView.superview ?: [self topMostVC].view;
        if (!root) return;

        UIControl *btn = [self findControlIn:root keywords:@[@"chia nhanh", @"quick split", @"chia cảnh", @"split", @"chia", @"cắt"]];
        if (btn && [self safeTap:btn]) {
            [self showToast:@"⚡ Đã chạy Chia đoạn" color:VSColorGreen()];
            return;
        }
        UIControl *done = [self findControlIn:root keywords:@[@"xong", @"done", @"ok"]];
        if (done && [self safeTap:done]) {
            [self showToast:@"⚡ Đã xác nhận Chia đoạn" color:VSColorGreen()];
            return;
        }
        [self showToast:@"⚠️ Không tìm thấy nút Chia trên màn hình này" color:[UIColor systemOrangeColor]];
    });
}

- (void)runFeature1CopyImage {
    VSRunOnMain(^{
        UIViewController *mlVC = self.activeMultiLayerVC;
        SEL lastSel = NSSelectorFromString(@"lastSelectedLayerNum");
        SEL copySel = NSSelectorFromString(@"copyLayer:");

        if (mlVC && [mlVC respondsToSelector:lastSel] && [mlVC respondsToSelector:copySel]) {
            @try {
                NSInteger layerIdx = ((NSInteger (*)(id, SEL))objc_msgSend)(mlVC, lastSel);
                if (layerIdx >= 0) {
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(mlVC, copySel, layerIdx);
                    [self showToast:[NSString stringWithFormat:@"📋 Chức năng 1: Đã copy lớp %ld", (long)(layerIdx + 1)]
                              color:VSColorGreen()];
                    return;
                }
            } @catch (NSException *ex) {}
        }

        // Fallback copy ảnh vào Pasteboard
        UIViewController *top = [self topMostVC];
        if (top) {
            NSMutableArray<UIView *> *views = [NSMutableArray array];
            [self collectViewsFrom:top.view into:views];
            UIImage *best = nil;
            CGFloat bestArea = 0;
            for (UIView *v in views) {
                if ([v isKindOfClass:[UIImageView class]]) {
                    UIImage *img = ((UIImageView *)v).image;
                    CGFloat area = v.bounds.size.width * v.bounds.size.height;
                    if (img && img.size.width > 64 && area > bestArea) {
                        bestArea = area;
                        best = img;
                    }
                }
            }
            if (best) {
                self.feature1CopiedImage = best;
                [UIPasteboard generalPasteboard].image = best;
                [self showToast:@"📋 Chức năng 1: Đã copy ảnh vào Clipboard" color:VSColorGreen()];
                return;
            }
        }
        if (self.feature1CopiedImage) {
            [UIPasteboard generalPasteboard].image = self.feature1CopiedImage;
            [self showToast:@"📋 Chức năng 1: Đã dán lại ảnh vào Clipboard" color:VSColorCyan()];
        } else {
            [self showToast:@"⚠️ Chưa có ảnh để copy ở màn hình này" color:[UIColor systemOrangeColor]];
        }
    });
}

#pragma mark - Chức Năng 4: Khởi động -> Chọn Kho Ảnh QR -> Tự Động Vòng Lặp

- (void)startFeature4WithSegmentCount:(NSInteger)count {
    VSRunOnMain(^{
        if (self.isFeature4Running) {
            [self stopFeature4WithMessage:@"⏹ Đã dừng Chức năng 4"];
            return;
        }

        NSInteger safeCount = MAX(1, MIN(50, count));
        self.sessionToken++;
        self.qrQueue = nil;
        self.cachedFirstSegmentImage = nil;
        self.currentSegmentIndex = 0;
        self.presetHandledForSegment = NO;
        self.createHandledForSegment = NO;
        [self.detectedMediaLayers removeAllObjects];

        self.state = VSF4StatePickingQRs;
        self.pickerForFirstImage = NO;
        [[VSContextualBar shared] refreshRunningState];

        [self openPhotoPickerLimit:safeCount
                            prompt:[NSString stringWithFormat:@"📸 Chọn %ld ảnh QR (theo thứ tự đoạn)", (long)safeCount]];
    });
}

- (void)stopFeature4WithMessage:(nullable NSString *)message {
    VSRunOnMain(^{
        self.sessionToken++;
        self.state = VSF4StateIdle;
        self.pickerForFirstImage = NO;
        self.presetHandledForSegment = NO;
        self.createHandledForSegment = NO;
        self.qrQueue = nil;
        self.cachedFirstSegmentImage = nil;
        [self.detectedMediaLayers removeAllObjects];
        [[VSContextualBar shared] refreshRunningState];
        if (message.length > 0) {
            [self showToast:message color:[UIColor systemOrangeColor]];
        }
    });
}

- (void)openPhotoPickerLimit:(NSInteger)limit prompt:(NSString *)prompt {
    UIViewController *presenter = [self topMostVC];
    if (!presenter) {
        [self stopFeature4WithMessage:@"⚠️ Không tìm thấy màn hình để mở Kho ảnh"];
        return;
    }

    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = limit;
        cfg.filter = [PHPickerFilter imagesFilter];

        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        picker.delegate = self;
        picker.modalPresentationStyle = UIModalPresentationPageSheet;

        [self showToast:prompt color:VSColorPurple()];
        [presenter presentViewController:picker animated:YES completion:nil];
    } else {
        [self stopFeature4WithMessage:@"⚠️ Yêu cầu iOS 14+ để mở Kho ảnh"];
    }
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14)) {
    NSUInteger token = self.sessionToken;
    BOOL forFirstImg = self.pickerForFirstImage;

    __weak typeof(self) weakSelf = self;
    [picker dismissViewControllerAnimated:YES completion:^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s.sessionToken != token) return;

        if (results.count == 0) {
            [s stopFeature4WithMessage:@"Đã hủy chọn ảnh"];
            return;
        }

        if (forFirstImg) {
            s.pickerForFirstImage = NO;
            [s handleFirstSegmentPickedImage:results.firstObject token:token];
        } else {
            [s handleBatchQRPickedResults:results token:token];
        }
    }];
}

- (void)handleBatchQRPickedResults:(NSArray<PHPickerResult *> *)results token:(NSUInteger)token API_AVAILABLE(ios(14)) {
    self.state = VSF4StateDecodingQRs;
    [self showToast:[NSString stringWithFormat:@"🔍 Đang giải mã %lu ảnh QR...", (unsigned long)results.count] color:VSColorCyan()];

    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:results.count];
    for (NSUInteger i = 0; i < results.count; i++) [ordered addObject:[NSNull null]];

    dispatch_group_t grp = dispatch_group_create();
    for (NSUInteger i = 0; i < results.count; i++) {
        PHPickerResult *r = results[i];
        if ([r.itemProvider canLoadObjectOfClass:[UIImage class]]) {
            dispatch_group_enter(grp);
            [r.itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading> _Nullable obj, NSError * _Nullable err) {
                if ([obj isKindOfClass:[UIImage class]]) {
                    @synchronized (ordered) { ordered[i] = obj; }
                }
                dispatch_group_leave(grp);
            }];
        }
    }

    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(grp, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s.sessionToken != token) return;

        NSMutableArray<VSQRItem *> *items = [NSMutableArray array];
        NSInteger failed = 0;

        for (id obj in ordered) {
            if (![obj isKindOfClass:[UIImage class]]) continue;
            @autoreleasepool {
                UIImage *img = (UIImage *)obj;
                NSString *code = [s decodeQRCodeFromImage:img];
                if (code.length > 0) {
                    VSQRItem *it = [[VSQRItem alloc] init];
                    it.code = code;
                    UIImage *thumb = [s normalizeImage:img maxDim:512.0];
                    it.jpegData = UIImageJPEGRepresentation(thumb ?: img, 0.72);
                    [items addObject:it];
                } else {
                    failed++;
                }
            }
        }

        VSRunOnMain(^{
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2 || s2.sessionToken != token) return;
            if (items.count == 0) {
                [s2 stopFeature4WithMessage:@"❌ Không đọc được mã QR nào từ ảnh đã chọn"];
                return;
            }

            s2.qrQueue = [items copy];
            s2.currentSegmentIndex = 0;
            [[VSContextualBar shared] refreshRunningState];

            NSString *msg = failed > 0
                ? [NSString stringWithFormat:@"✅ Đọc xong %lu QR (%ld lỗi). Chạy Đoạn 1...", (unsigned long)items.count, (long)failed]
                : [NSString stringWithFormat:@"✅ Đọc xong %lu QR. Chạy Đoạn 1...", (unsigned long)items.count];
            [s2 showToast:msg color:VSColorGreen()];

            [s2 runCurrentSegmentQRWithToken:token];
        });
    });
}

#pragma mark - Nhập QR -> Tự bỏ qua Trùng khớp -> Nạp Tất Cả Lớp -> Tự Ấn Tạo

- (void)runCurrentSegmentQRWithToken:(NSUInteger)token {
    if (token != self.sessionToken || !self.isFeature4Running) return;

    if (self.currentSegmentIndex >= (NSInteger)self.qrQueue.count) {
        [self stopFeature4WithMessage:[NSString stringWithFormat:@"🎉 Hoàn thành tất cả %lu đoạn!", (unsigned long)self.qrQueue.count]];
        return;
    }

    UIViewController *mlVC = self.activeMultiLayerVC;
    if (!mlVC) {
        self.state = VSF4StateAdvancingSegment;
        [[VSContextualBar shared] refreshRunningState];
        [self showToast:[NSString stringWithFormat:@"➡️ Vào Kết hợp Đoạn %ld/%lu để tự chạy tiếp",
                         (long)(self.currentSegmentIndex + 1), (unsigned long)self.qrQueue.count]
                  color:VSColorPurple()];
        return;
    }

    VSQRItem *item = self.qrQueue[self.currentSegmentIndex];
    self.state = VSF4StateImportingQR;
    self.presetHandledForSegment = NO;
    self.createHandledForSegment = NO;
    [self.detectedMediaLayers removeAllObjects];
    [[VSContextualBar shared] refreshRunningState];

    [self showToast:[NSString stringWithFormat:@"⚙️ Đoạn %ld/%lu: Đang nhập QR...",
                     (long)(self.currentSegmentIndex + 1), (unsigned long)self.qrQueue.count]
              color:VSColorCyan()];

    BOOL sent = NO;
    Class qrCls = objc_getClass("QRCodeManager");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    SEL selectSel = NSSelectorFromString(@"selectedCode:withImageData:");
    SEL setDelSel = NSSelectorFromString(@"setDelegate:");

    if (qrCls && [qrCls respondsToSelector:sharedSel]) {
        id qrMgr = ((id (*)(id, SEL))objc_msgSend)(qrCls, sharedSel);
        if (qrMgr && [qrMgr respondsToSelector:selectSel]) {
            @try {
                if ([qrMgr respondsToSelector:setDelSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(qrMgr, setDelSel, mlVC);
                }
                ((void (*)(id, SEL, id, id))objc_msgSend)(qrMgr, selectSel, item.code, item.jpegData);
                sent = YES;
            } @catch (NSException *ex) { sent = NO; }
        }
    }

    SEL importedSel = NSSelectorFromString(@"importedData:code:");
    if (!sent && [mlVC respondsToSelector:importedSel]) {
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(mlVC, importedSel, item.jpegData, item.code);
            sent = YES;
        } @catch (NSException *ex) {}
    }

    if (!sent) {
        [self stopFeature4WithMessage:@"❌ Không gọi được hàm nhập QR gốc"];
        return;
    }

    // Watchdog 1.2s chống kẹt nếu Video Star không gọi lại importNewPreset
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s.sessionToken != token) return;
        if (s.state == VSF4StateImportingQR && !s.presetHandledForSegment && s.activeMultiLayerVC) {
            [s onQRImportAppliedOnVC:s.activeMultiLayerVC];
        }
    });
}

- (void)onPresetSetupLayerNum:(NSUInteger)layerNum needsMedia:(BOOL)needsMedia {
    if (self.state != VSF4StateImportingQR) return;
    if (needsMedia) {
        [self.detectedMediaLayers addObject:@(layerNum)];
    }
}

- (void)onQRImportAppliedOnVC:(UIViewController *)vc {
    VSRunOnMain(^{
        if (self.state != VSF4StateImportingQR || self.presetHandledForSegment) return;
        self.presetHandledForSegment = YES;
        self.activeMultiLayerVC = vc;
        NSUInteger token = self.sessionToken;

        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || s.sessionToken != token) return;

            if (s.detectedMediaLayers.count == 0 && s.activeMultiLayerVC) {
                int count = 1;
                SEL activeSel = NSSelectorFromString(@"activeLayers");
                if ([s.activeMultiLayerVC respondsToSelector:activeSel]) {
                    count = MAX(1, ((int (*)(id, SEL))objc_msgSend)(s.activeMultiLayerVC, activeSel));
                }
                for (int i = 0; i < count; i++) {
                    [s.detectedMediaLayers addObject:@(i)];
                }
            }

            if (s.currentSegmentIndex == 0 && !s.cachedFirstSegmentImage) {
                // ĐOẠN 1: Hiện thẳng bảng chọn hình ảnh 1 lần duy nhất
                s.state = VSF4StatePickingFirstImage;
                s.pickerForFirstImage = YES;
                [s openPhotoPickerLimit:1 prompt:@"🖼 Đoạn 1: Chọn 1 ảnh cho tất cả lớp & đoạn sau"];
            } else {
                // ĐOẠN 2..N: Tự động dùng luôn ảnh Đoạn 1, không hiện lại bảng chọn ảnh
                [s batchFillAllLayersWithToken:token];
            }
        });
    });
}

- (void)handleFirstSegmentPickedImage:(nullable PHPickerResult *)res token:(NSUInteger)token API_AVAILABLE(ios(14)) {
    if (!res || ![res.itemProvider canLoadObjectOfClass:[UIImage class]]) {
        [self stopFeature4WithMessage:@"❌ Không thể tải ảnh đã chọn"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [res.itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading> _Nullable obj, NSError * _Nullable err) {
        VSRunOnMain(^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || s.sessionToken != token) return;
            if (![obj isKindOfClass:[UIImage class]]) {
                [s stopFeature4WithMessage:@"❌ Lỗi đọc ảnh nguồn"];
                return;
            }
            s.cachedFirstSegmentImage = [s normalizeImage:(UIImage *)obj maxDim:2160.0];
            [s batchFillAllLayersWithToken:token];
        });
    }];
}

- (void)batchFillAllLayersWithToken:(NSUInteger)token {
    if (token != self.sessionToken) return;
    UIViewController *mlVC = self.activeMultiLayerVC;
    UIImage *img = self.cachedFirstSegmentImage;
    if (!mlVC || !img) {
        [self stopFeature4WithMessage:@"⚠️ Thiếu ảnh nguồn hoặc màn hình Kết hợp"];
        return;
    }

    self.state = VSF4StateBatchFillingLayers;
    NSArray<NSNumber *> *sortedLayers = [[self.detectedMediaLayers allObjects]
                                         sortedArrayUsingSelector:@selector(compare:)];

    [self showToast:[NSString stringWithFormat:@"⚡ Đoạn %ld/%lu: Nạp 1 lần vào %lu lớp...",
                     (long)(self.currentSegmentIndex + 1),
                     (unsigned long)self.qrQueue.count,
                     (unsigned long)sortedLayers.count]
              color:VSColorCyan()];

    [self fillLayerAtStep:0 inLayers:sortedLayers onVC:mlVC image:img token:token];
}

- (void)fillLayerAtStep:(NSInteger)step
               inLayers:(NSArray<NSNumber *> *)layers
                   onVC:(UIViewController *)mlVC
                  image:(UIImage *)img
                  token:(NSUInteger)token {
    if (token != self.sessionToken || !mlVC) return;

    if (step >= (NSInteger)layers.count) {
        SEL refreshSel = NSSelectorFromString(@"refreshDisplay");
        if ([mlVC respondsToSelector:refreshSel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(mlVC, refreshSel); } @catch (NSException *ex) {}
        }

        __weak typeof(self) weakSelf = self;
        __weak UIViewController *weakVC = mlVC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            UIViewController *strongVC = weakVC;
            if (!s || !strongVC || s.sessionToken != token) return;
            [s triggerCreateOnVC:strongVC token:token];
        });
        return;
    }

    NSUInteger layerNum = [layers[step] unsignedIntegerValue];
    SEL selectSel = NSSelectorFromString(@"selectLayer:bordered:");
    SEL photoSel  = NSSelectorFromString(@"makePhotoLayer:");

    @try {
        if ([mlVC respondsToSelector:selectSel]) {
            ((void (*)(id, SEL, NSUInteger, BOOL))objc_msgSend)(mlVC, selectSel, layerNum, YES);
        }
        if ([mlVC respondsToSelector:photoSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(mlVC, photoSel, img);
        }
    } @catch (NSException *ex) {}

    __weak typeof(self) weakSelf = self;
    __weak UIViewController *weakVC = mlVC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        UIViewController *strongVC = weakVC;
        if (!s || !strongVC || s.sessionToken != token) return;
        [s fillLayerAtStep:(step + 1) inLayers:layers onVC:strongVC image:img token:token];
    });
}

- (void)triggerCreateOnVC:(UIViewController *)mlVC token:(NSUInteger)token {
    if (token != self.sessionToken || !mlVC) return;

    self.state = VSF4StateCreatingSegment;
    self.createHandledForSegment = NO;
    [self showToast:[NSString stringWithFormat:@"🎬 Đang tạo Đoạn %ld/%lu...",
                     (long)(self.currentSegmentIndex + 1), (unsigned long)self.qrQueue.count]
              color:VSColorPurple()];

    SEL createSel = NSSelectorFromString(@"create");
    SEL startCreateSel = NSSelectorFromString(@"startCreate");
    @try {
        if ([mlVC respondsToSelector:createSel]) {
            ((void (*)(id, SEL))objc_msgSend)(mlVC, createSel);
        } else if ([mlVC respondsToSelector:startCreateSel]) {
            ((void (*)(id, SEL))objc_msgSend)(mlVC, startCreateSel);
        } else {
            [self stopFeature4WithMessage:@"❌ Không tìm thấy nút Tạo"];
        }
    } @catch (NSException *ex) {
        [self stopFeature4WithMessage:@"❌ Lỗi khi nhấn Tạo"];
    }
}

- (void)onCreateFinishedOnVC:(UIViewController *)vc {
    VSRunOnMain(^{
        if (self.state != VSF4StateCreatingSegment || self.createHandledForSegment) return;
        self.createHandledForSegment = YES;

        NSUInteger token = self.sessionToken;
        self.currentSegmentIndex++;

        if (self.currentSegmentIndex >= (NSInteger)self.qrQueue.count) {
            [self stopFeature4WithMessage:[NSString stringWithFormat:@"🎉 Hoàn tất toàn bộ %lu đoạn!",
                                           (unsigned long)self.qrQueue.count]];
            return;
        }

        self.state = VSF4StateAdvancingSegment;
        [[VSContextualBar shared] refreshRunningState];

        // Tự động tìm nút Xong/Done ở Preview (nếu hiện) rồi chờ/mở Kết hợp đoạn kế tiếp
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || s.sessionToken != token || s.state != VSF4StateAdvancingSegment) return;
            [s tryAdvanceNextSegmentWithToken:token];
        });
    });
}

- (void)tryAdvanceNextSegmentWithToken:(NSUInteger)token {
    if (token != self.sessionToken || self.state != VSF4StateAdvancingSegment) return;
    UIViewController *top = [self topMostVC];
    if (!top) return;

    UIControl *doneBtn = [self findControlIn:top.view keywords:@[@"xong", @"done"]];
    if (doneBtn && [self safeTap:doneBtn]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || s.sessionToken != token) return;
            [s tryAdvanceNextSegmentWithToken:token];
        });
        return;
    }

    UIControl *nextBtn = [self findControlIn:top.view keywords:@[@"kế tiếp", @"tiếp", @"next", @">"]];
    if (nextBtn) [self safeTap:nextBtn];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s.sessionToken != token || s.state != VSF4StateAdvancingSegment) return;
        UIViewController *cur = [s topMostVC];
        UIControl *mlBtn = [s findControlIn:cur.view keywords:@[@"kết hợp", @"nhiều lớp", @"multi-layer", @"multilayer"]];
        if (!mlBtn || ![s safeTap:mlBtn]) {
            [s showToast:[NSString stringWithFormat:@"➡️ Sẵn sàng Đoạn %ld/%lu: Mở Kết hợp để tự chạy tiếp",
                          (long)(s.currentSegmentIndex + 1), (unsigned long)s.qrQueue.count]
                   color:VSColorPurple()];
        }
    });
}

- (void)onMultiLayerAppeared:(UIViewController *)vc {
    VSRunOnMain(^{
        self.activeMultiLayerVC = vc;
        if (self.state == VSF4StateAdvancingSegment &&
            self.currentSegmentIndex < (NSInteger)self.qrQueue.count) {
            NSUInteger token = self.sessionToken;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s || s.sessionToken != token) return;
                if (s.state == VSF4StateAdvancingSegment) {
                    [s runCurrentSegmentQRWithToken:token];
                }
            });
        }
    });
}

- (BOOL)interceptPresentedVC:(UIViewController *)vcToPresent {
    if (!self.shouldBypassMatchDialogs) return NO;
    if (![vcToPresent isKindOfClass:[UIAlertController class]]) return NO;

    UIAlertController *alert = (UIAlertController *)vcToPresent;
    NSString *txt = [[NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""] lowercaseString];
    NSArray<NSString *> *kws = @[
        @"trùng khớp", @"trung khop", @"match", @"khớp", @"tỉ lệ", @"tỷ lệ",
        @"ghi đè", @"overwrite", @"xác nhận", @"confirm", @"nhập", @"import"
    ];

    BOOL matched = NO;
    for (NSString *kw in kws) {
        if ([txt containsString:kw]) { matched = YES; break; }
    }
    if (!matched) return NO;

    for (UIAlertAction *act in alert.actions) {
        if (act.style != UIAlertActionStyleCancel) {
            @try {
                id handler = [act valueForKey:@"handler"];
                if (handler) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (^)(UIAlertAction *))handler)(act);
                    });
                }
            } @catch (NSException *ex) {}
            return YES;
        }
    }
    return NO;
}

@end

#pragma mark - Runtime Hooks (QRCodeManager, MultiLayerWizEffectVC, SplitPreview, UIViewController)

// --- 1. QRCodeManager Hooks (Tự động bỏ qua bảng Trùng khớp...) ---
static void (*orig_QR_showImportWarning)(id, SEL) = NULL;
static void (*orig_QR_scalePaste1)(id, SEL, NSInteger, NSInteger, NSInteger, id, id, id) = NULL;
static void (*orig_QR_scale1)(id, SEL, NSInteger, NSInteger, NSInteger, id, id, id) = NULL;
static void (*orig_QR_scale2)(id, SEL, NSInteger, NSInteger, NSInteger, NSInteger, NSInteger, id, id, id, BOOL) = NULL;
static void (*orig_QR_scalePasteDur)(id, SEL, NSInteger, float, float, float, float, id, id, id) = NULL;
static void (*orig_QR_scaleDur1)(id, SEL, NSInteger, float, float, float, float, id, id, id) = NULL;
static void (*orig_QR_scaleDur2)(id, SEL, NSInteger, float, float, float, float, id, id, id, BOOL) = NULL;

static void hook_QR_showImportWarning(id self, SEL _cmd) {
    if ([VSToolEngine shared].shouldBypassMatchDialogs) return;
    if (orig_QR_showImportWarning) orig_QR_showImportWarning(self, _cmd);
}

static void hook_QR_scalePaste1(id self, SEL _cmd, NSInteger a0, NSInteger a1, NSInteger a2, id sb, id fb, id eb) {
    if ([VSToolEngine shared].shouldBypassMatchDialogs) { VSInvokeVoidBlockSafe(fb ?: sb); return; }
    if (orig_QR_scalePaste1) orig_QR_scalePaste1(self, _cmd, a0, a1, a2, sb, fb, eb);
}

static void hook_QR_scale1(id self, SEL _cmd, NSInteger a0, NSInteger a1, NSInteger a2, id sb, id fb, id eb) {
    if ([VSToolEngine shared].shouldBypassMatchDialogs) { VSInvokeVoidBlockSafe(fb ?: sb); return; }
    if (orig_QR_scale1) orig_QR_scale1(self, _cmd, a0, a1, a2, sb, fb, eb);
}

static void hook_QR_scale2(id self, SEL _cmd, NSInteger a0, NSInteger a1, NSInteger a2, NSInteger a3, NSInteger a4, id sb, id fb, id eb, BOOL fp) {
    if ([VSToolEngine shared].shouldBypassMatchDialogs) { VSInvokeVoidBlockSafe(fb ?: sb); return; }
    if (orig_QR_scale2) orig_QR_scale2(self, _cmd, a0, a1, a2, a3, a4, sb, fb, eb, fp);
}

static void hook_QR_scalePasteDur(id self, SEL _cmd, NSInteger a0, float a1, float a2, float a3, float a4, id sb, id fb, id eb) {
    if ([VSToolEngine shared].shouldBypassMatchDialogs) { VSInvokeVoidBlockSafe(fb ?: sb); return; }
    if (orig_QR_scalePasteDur) orig_QR_scalePasteDur(self, _cmd, a0, a1, a2, a3, a4, sb, fb, eb);
}

static void hook_QR_scaleDur1(id self, SEL _cmd, NSInteger a0, float a1, float a2, float a3, float a4, id sb, id fb, id eb) {
    if ([VSToolEngine shared].shouldBypassMatchDialogs) { VSInvokeVoidBlockSafe(fb ?: sb); return; }
    if (orig_QR_scaleDur1) orig_QR_scaleDur1(self, _cmd, a0, a1, a2, a3, a4, sb, fb, eb);
}

static void hook_QR_scaleDur2(id self, SEL _cmd, NSInteger a0, float a1, float a2, float a3, float a4, id sb, id fb, id eb, BOOL fp) {
    if ([VSToolEngine shared].shouldBypassMatchDialogs) { VSInvokeVoidBlockSafe(fb ?: sb); return; }
    if (orig_QR_scaleDur2) orig_QR_scaleDur2(self, _cmd, a0, a1, a2, a3, a4, sb, fb, eb, fp);
}

// --- 2. MultiLayerWizEffectVC Hooks (Hiện nút Kết hợp & chạy Chức năng 4) ---
static void (*orig_ML_viewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static void (*orig_ML_viewWillDisappear)(UIViewController *, SEL, BOOL) = NULL;
static BOOL (*orig_ML_showImportConfirmation)(id, SEL) = NULL;
static id   (*orig_ML_setupPresetLayer)(id, SEL, NSUInteger, id, id, id, id, id, int, id) = NULL;
static id   (*orig_ML_setupOldPresetLayer)(id, SEL, NSUInteger) = NULL;
static void (*orig_ML_importNewPreset)(id, SEL, id, id, NSInteger) = NULL;
static void (*orig_ML_importOldPreset)(id, SEL, id) = NULL;
static void (*orig_ML_closeLoadingProgressView)(id, SEL) = NULL;

static void hook_ML_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_ML_viewDidAppear) orig_ML_viewDidAppear(self, _cmd, animated);
    [[VSContextualBar shared] showMode:VSScreenModeMultiLayer inWindow:self.view.window anchorView:nil];
    [[VSToolEngine shared] onMultiLayerAppeared:self];
}

static void hook_ML_viewWillDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_ML_viewWillDisappear) orig_ML_viewWillDisappear(self, _cmd, animated);
    if (!self.presentedViewController) {
        [[VSContextualBar shared] hide];
    }
}

static BOOL hook_ML_showImportConfirmation(id self, SEL _cmd) {
    if ([VSToolEngine shared].shouldBypassMatchDialogs) return NO;
    return orig_ML_showImportConfirmation ? orig_ML_showImportConfirmation(self, _cmd) : NO;
}

static id hook_ML_setupPresetLayer(id self, SEL _cmd, NSUInteger layerNum, id preset, id textStyle, id zap, id gif, id overlay, int layerType, id placeHolder) {
    id res = orig_ML_setupPresetLayer ? orig_ML_setupPresetLayer(self, _cmd, layerNum, preset, textStyle, zap, gif, overlay, layerType, placeHolder) : nil;
    BOOL isStatic = (textStyle != nil || zap != nil || gif != nil || overlay != nil);
    BOOL needsMedia = (!isStatic || placeHolder != nil);
    [[VSToolEngine shared] onPresetSetupLayerNum:layerNum needsMedia:needsMedia];
    return res;
}

static id hook_ML_setupOldPresetLayer(id self, SEL _cmd, NSUInteger layerNum) {
    id res = orig_ML_setupOldPresetLayer ? orig_ML_setupOldPresetLayer(self, _cmd, layerNum) : nil;
    [[VSToolEngine shared] onPresetSetupLayerNum:layerNum needsMedia:YES];
    return res;
}

static void hook_ML_importNewPreset(id self, SEL _cmd, id preset, id kfAction, NSInteger frames) {
    if (orig_ML_importNewPreset) orig_ML_importNewPreset(self, _cmd, preset, kfAction, frames);
    [[VSToolEngine shared] onQRImportAppliedOnVC:(UIViewController *)self];
}

static void hook_ML_importOldPreset(id self, SEL _cmd, id preset) {
    if (orig_ML_importOldPreset) orig_ML_importOldPreset(self, _cmd, preset);
    [[VSToolEngine shared] onQRImportAppliedOnVC:(UIViewController *)self];
}

static void hook_ML_closeLoadingProgressView(id self, SEL _cmd) {
    if (orig_ML_closeLoadingProgressView) orig_ML_closeLoadingProgressView(self, _cmd);
    [[VSToolEngine shared] onCreateFinishedOnVC:(UIViewController *)self];
}

// --- 3. SplitPreview Hooks (Hiện nút Chia đoạn) ---
static void (*orig_Split_didMoveToWindow)(UIView *, SEL) = NULL;

static void hook_Split_didMoveToWindow(UIView *self, SEL _cmd) {
    if (orig_Split_didMoveToWindow) orig_Split_didMoveToWindow(self, _cmd);
    if (self.window) {
        [[VSContextualBar shared] showMode:VSScreenModeSplitScene inWindow:self.window anchorView:self];
    } else {
        [[VSContextualBar shared] hide];
    }
}

// --- 4. UIViewController Hooks (Ẩn nút khi về Project & Chặn Alert Trùng khớp) ---
static void (*orig_VC_viewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static void (*orig_VC_presentVC)(UIViewController *, SEL, UIViewController *, BOOL, void (^)(void)) = NULL;

static void hook_VC_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_VC_viewDidAppear) orig_VC_viewDidAppear(self, _cmd, animated);
    NSString *cls = NSStringFromClass([self class]);
    if (!cls || [cls hasPrefix:@"UI"] || [cls hasPrefix:@"_UI"] ||
        [cls hasPrefix:@"PH"] || [cls hasPrefix:@"PU"] ||
        [cls isEqualToString:@"MultiLayerWizEffectVC"]) {
        return;
    }

    if ([cls rangeOfString:@"Split" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [[VSContextualBar shared] showMode:VSScreenModeSplitScene inWindow:self.view.window anchorView:self.view];
    } else if ([cls rangeOfString:@"Project" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [[VSContextualBar shared] hide];
    }
}

static void hook_VC_presentVC(UIViewController *self, SEL _cmd, UIViewController *vcToPresent, BOOL flag, void (^completion)(void)) {
    if ([[VSToolEngine shared] interceptPresentedVC:vcToPresent]) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    if (orig_VC_presentVC) orig_VC_presentVC(self, _cmd, vcToPresent, flag, completion);
}

#pragma mark - Installer & Entry Point

static BOOL s_installedQR = NO;
static BOOL s_installedML = NO;
static BOOL s_installedSplit = NO;
static BOOL s_installedVC = NO;

static void VSInstallAllHooks(void) {
    if (!s_installedVC) {
        VSSwizzleMethod([UIViewController class], @selector(viewDidAppear:), (IMP)hook_VC_viewDidAppear, (IMP *)&orig_VC_viewDidAppear);
        VSSwizzleMethod([UIViewController class], @selector(presentViewController:animated:completion:), (IMP)hook_VC_presentVC, (IMP *)&orig_VC_presentVC);
        s_installedVC = YES;
    }

    if (!s_installedQR) {
        Class qrCls = objc_getClass("QRCodeManager");
        if (qrCls) {
            VSSwizzleMethod(qrCls, NSSelectorFromString(@"showImportWarning"), (IMP)hook_QR_showImportWarning, (IMP *)&orig_QR_showImportWarning);
            VSSwizzleMethod(qrCls, NSSelectorFromString(@"showScalingPopupForPaste:sceneInput:qrInput:startBlock:fitBlock:endBlock:"), (IMP)hook_QR_scalePaste1, (IMP *)&orig_QR_scalePaste1);
            VSSwizzleMethod(qrCls, NSSelectorFromString(@"showScalingPopup:sceneInput:qrInput:startBlock:fitBlock:endBlock:"), (IMP)hook_QR_scale1, (IMP *)&orig_QR_scale1);
            VSSwizzleMethod(qrCls, NSSelectorFromString(@"showScalingPopup:sceneInput:sceneOutput:qrInput:qrOutput:startBlock:fitBlock:endBlock:forPaste:"), (IMP)hook_QR_scale2, (IMP *)&orig_QR_scale2);
            VSSwizzleMethod(qrCls, NSSelectorFromString(@"showScalingPopupForPaste:sceneInputDuration:sceneOutputDuration:qrInputDuration:qrOutputDuration:startBlock:fitBlock:endBlock:"), (IMP)hook_QR_scalePasteDur, (IMP *)&orig_QR_scalePasteDur);
            VSSwizzleMethod(qrCls, NSSelectorFromString(@"showScalingPopup:sceneInputDuration:sceneOutputDuration:qrInputDuration:qrOutputDuration:startBlock:fitBlock:endBlock:"), (IMP)hook_QR_scaleDur1, (IMP *)&orig_QR_scaleDur1);
            VSSwizzleMethod(qrCls, NSSelectorFromString(@"showScalingPopup:sceneInputDuration:sceneOutputDuration:qrInputDuration:qrOutputDuration:startBlock:fitBlock:endBlock:forPaste:"), (IMP)hook_QR_scaleDur2, (IMP *)&orig_QR_scaleDur2);
            s_installedQR = YES;
        }
    }

    if (!s_installedML) {
        Class mlCls = objc_getClass("MultiLayerWizEffectVC");
        if (mlCls) {
            VSSwizzleMethod(mlCls, @selector(viewDidAppear:), (IMP)hook_ML_viewDidAppear, (IMP *)&orig_ML_viewDidAppear);
            VSSwizzleMethod(mlCls, @selector(viewWillDisappear:), (IMP)hook_ML_viewWillDisappear, (IMP *)&orig_ML_viewWillDisappear);
            VSSwizzleMethod(mlCls, NSSelectorFromString(@"showImportConfirmation"), (IMP)hook_ML_showImportConfirmation, (IMP *)&orig_ML_showImportConfirmation);
            VSSwizzleMethod(mlCls, NSSelectorFromString(@"setupPresetLayerNum:layerPreset:textStyle:zapSettings:gifSettings:overlaySettings:layerType:placeHolder:"), (IMP)hook_ML_setupPresetLayer, (IMP *)&orig_ML_setupPresetLayer);
            VSSwizzleMethod(mlCls, NSSelectorFromString(@"setupOldPresetLayerNum:"), (IMP)hook_ML_setupOldPresetLayer, (IMP *)&orig_ML_setupOldPresetLayer);
            VSSwizzleMethod(mlCls, NSSelectorFromString(@"importNewPreset:keyFrameAction:qrDurationInFrames:"), (IMP)hook_ML_importNewPreset, (IMP *)&orig_ML_importNewPreset);
            VSSwizzleMethod(mlCls, NSSelectorFromString(@"importOldPreset:"), (IMP)hook_ML_importOldPreset, (IMP *)&orig_ML_importOldPreset);
            VSSwizzleMethod(mlCls, NSSelectorFromString(@"closeLoadingProgressView"), (IMP)hook_ML_closeLoadingProgressView, (IMP *)&orig_ML_closeLoadingProgressView);
            s_installedML = YES;
        }
    }

    if (!s_installedSplit) {
        Class splitCls = objc_getClass("_TtC10Video_Star12SplitPreview");
        if (splitCls) {
            VSSwizzleMethod(splitCls, @selector(didMoveToWindow), (IMP)hook_Split_didMoveToWindow, (IMP *)&orig_Split_didMoveToWindow);
            s_installedSplit = YES;
        }
    }
}

__attribute__((constructor))
static void VideoStarTool_Entry(void) {
    @autoreleasepool {
        [VSToolEngine shared];
        VSInstallAllHooks();

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            VSInstallAllHooks();
        }];
    }
}
