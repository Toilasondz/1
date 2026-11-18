#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 0. Khai Báo Giao Thức Private API Của Video Star (Chống Warning Compiler)

@protocol VideoStarPrivateAPIs <NSObject>
@optional
// Engine & Layer APIs
- (id)getMultiLayerEngine;
- (NSInteger)numActiveLayers;
- (id)layerAtLayerNum:(NSInteger)layerNum;
- (BOOL)isNullLayer:(NSInteger)layerNum;
- (BOOL)is3DLayer;
- (NSInteger)layerTypeForLayer:(NSInteger)layerNum;
- (void)setupImage:(UIImage *)image layerNum:(NSInteger)layerNum layerType:(NSInteger)layerType clearMask:(BOOL)clearMask;
- (BOOL)assetHasBeenLoadedForLayer:(NSInteger)layerNum;
- (id)imageGenerator;
- (UIImage *)layerImage;
- (void)setLayerImage:(UIImage *)image;
- (void)loadImageAsset:(UIImage *)image;

// Editor & Overwrite APIs
- (void)confirmOverwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show;
- (void)confirmOverwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show removeOverlayBlending:(BOOL)remove;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show removeOverlayBlending:(BOOL)remove;
- (void)confirmAddingLayer:(id)layer object:(id)obj1 object2:(id)obj2 object3:(id)obj3 isAbleToShowTheLayerActionMenu:(BOOL)show;
- (void)addingLayer:(id)layer object:(id)obj1 object2:(id)obj2 object3:(id)obj3 isAbleToShowTheLayerActionMenu:(BOOL)show;
- (void)selectLayer:(NSInteger)layerNum;
- (void)setCurrentLayerIndex:(NSInteger)layerNum;
- (void)makePhotoLayer:(UIImage *)image;
- (void)confirmAddingLayer:(UIImage *)image;
- (void)importedData:(NSData *)data code:(NSString *)code;
- (void)refreshPreview;
- (void)updateLayerButtons;
- (void)create;
- (void)createButtonPressed:(id)sender;

// Project & Navigation APIs
- (NSInteger)lastViewedSceneIndex;
- (void)setLastViewedSceneIndex:(NSInteger)index;
- (NSInteger)sceneIndex;
- (void)showMultiLayer;
- (void)setClipImage:(UIImage *)image;
- (void)splitScene;
@end

#pragma mark - 1. Per-Class IMP Registry

static NSMutableDictionary<NSString *, NSValue *> *g_origIMPRegistry = nil;

static NSString *VSTKeyForClassAndSelector(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%s::%s", class_getName(cls), sel_getName(sel)];
}

static void VSTHookMethodOnClass(Class cls, SEL sel, IMP newIMP) {
    if (!cls || !sel || !newIMP) return;
    if (!g_origIMPRegistry) {
        g_origIMPRegistry = [NSMutableDictionary dictionary];
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    
    NSString *key = VSTKeyForClassAndSelector(cls, sel);
    if (g_origIMPRegistry[key]) return;
    
    IMP origIMP = method_getImplementation(m);
    if (origIMP == newIMP) return;
    
    const char *types = method_getTypeEncoding(m);
    if (!class_addMethod(cls, sel, newIMP, types)) {
        method_setImplementation(m, newIMP);
    }
    g_origIMPRegistry[key] = [NSValue valueWithPointer:(void *)origIMP];
}

static IMP VSTGetOriginalIMP(id selfObj, SEL sel) {
    if (!selfObj || !sel || !g_origIMPRegistry) return NULL;
    Class cls = object_getClass(selfObj);
    while (cls) {
        NSString *key = VSTKeyForClassAndSelector(cls, sel);
        NSValue *val = g_origIMPRegistry[key];
        if (val) {
            return (IMP)[val pointerValue];
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

#pragma mark - 2. VSQRCodeDecoder: Giải Mã QR 3 Tầng (Chuẩn Hóa EXIF + CIDetector + Vision + CIFilter)

@interface VSQRCodeDecoder : NSObject
+ (nullable NSString *)decodeQRFromImage:(UIImage *)image;
+ (nullable NSData *)extractRawQRPayloadFromString:(NSString *)qrString;
@end

@implementation VSQRCodeDecoder

+ (UIImage *)normalizedUpImage:(UIImage *)image {
    if (!image) return nil;
    if (image.imageOrientation == UIImageOrientationUp && image.CGImage != NULL) {
        return image;
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
        [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    }];
}

+ (nullable NSString *)decodeQRFromImage:(UIImage *)rawImage {
    if (!rawImage) return nil;
    
    UIImage *normalizedImg = [self normalizedUpImage:rawImage];
    CGImageRef cgImg = normalizedImg.CGImage ?: rawImage.CGImage;
    if (!cgImg) return nil;
    
    // Tầng 1: CIDetector với initWithCGImage:
    CIImage *ciImage = [CIImage imageWithCGImage:cgImg];
    if (ciImage) {
        NSString *res1 = [self decodeWithCIDetector:ciImage];
        if (res1.length > 0) return res1;
    }
    
    // Tầng 2: Vision Framework (VNDetectBarcodesRequest)
    NSString *res2 = [self decodeWithVisionCGImage:cgImg];
    if (res2.length > 0) return res2;
    
    // Tầng 3: Tăng tương phản + khử màu cho QR mờ/nhỏ
    if (ciImage) {
        CIFilter *colorCtrl = [CIFilter filterWithName:@"CIColorControls"];
        [colorCtrl setValue:ciImage forKey:kCIInputImageKey];
        [colorCtrl setValue:@(0.0) forKey:kCIInputSaturationKey];
        [colorCtrl setValue:@(1.85) forKey:kCIInputContrastKey];
        CIImage *filtered = colorCtrl.outputImage;
        if (filtered) {
            NSString *res3 = [self decodeWithCIDetector:filtered];
            if (res3.length > 0) return res3;
            
            CIContext *ctx = [CIContext contextWithOptions:nil];
            CGImageRef enhancedCG = [ctx createCGImage:filtered fromRect:filtered.extent];
            if (enhancedCG) {
                NSString *res4 = [self decodeWithVisionCGImage:enhancedCG];
                CGImageRelease(enhancedCG);
                if (res4.length > 0) return res4;
            }
        }
    }
    return nil;
}

+ (nullable NSString *)decodeWithCIDetector:(CIImage *)ciImage {
    @try {
        CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                                  context:nil
                                                  options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
        NSArray<CIFeature *> *features = [detector featuresInImage:ciImage];
        for (CIFeature *f in features) {
            if ([f isKindOfClass:[CIQRCodeFeature class]]) {
                NSString *msg = [(CIQRCodeFeature *)f messageString];
                if (msg.length > 0) return msg;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

+ (nullable NSString *)decodeWithVisionCGImage:(CGImageRef)cgImage {
    __block NSString *decoded = nil;
    @try {
        VNDetectBarcodesRequest *req = [[VNDetectBarcodesRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
            for (id obs in request.results) {
                if ([obs isKindOfClass:[VNBarcodeObservation class]]) {
                    VNBarcodeObservation *barcode = (VNBarcodeObservation *)obs;
                    if (barcode.payloadStringValue.length > 0) {
                        decoded = [barcode.payloadStringValue copy];
                        break;
                    }
                }
            }
        }];
        req.symbologies = @[VNBarcodeSymbologyQR];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
        [handler performRequests:@[req] error:nil];
    } @catch (NSException *e) {}
    return decoded;
}

+ (nullable NSData *)extractRawQRPayloadFromString:(NSString *)qrString {
    if (qrString.length == 0) return nil;
    NSData *base64Data = [[NSData alloc] initWithBase64EncodedString:qrString options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (base64Data.length > 0) return base64Data;
    return [qrString dataUsingEncoding:NSUTF8StringEncoding];
}

@end

#pragma mark - 3. VSBatchLayerFiller: Ghi Ảnh Thật Vào Engine

@interface VSBatchLayerFiller : NSObject
+ (nullable id)multiLayerEngineFromEditor:(id)editorVC;
+ (NSArray<NSNumber *> *)eligibleLayerNumsFromEngine:(id)engine;
+ (BOOL)fillAllActiveLayersInEditor:(id)editorVC withImage:(UIImage *)image;
+ (nullable UIImage *)extractFirstLayerImageFromEditor:(id)editorVC;
@end

@implementation VSBatchLayerFiller

+ (nullable id)multiLayerEngineFromEditor:(id)editorVC {
    if (!editorVC) return nil;
    @try {
        if ([editorVC respondsToSelector:@selector(getMultiLayerEngine)]) {
            id eng = ((id (*)(id, SEL))objc_msgSend)(editorVC, @selector(getMultiLayerEngine));
            if (eng) return eng;
        }
        
        NSArray<NSString *> *ivarNames = @[@"_multiLayerEngine", @"multiLayerEngine", @"_engine", @"engine"];
        for (NSString *key in ivarNames) {
            Ivar ivar = class_getInstanceVariable([editorVC class], [key UTF8String]);
            if (!ivar) continue;
            
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            
            id val = object_getIvar(editorVC, ivar);
            if (val && [val respondsToSelector:@selector(layerAtLayerNum:)]) {
                return val;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

+ (NSArray<NSNumber *> *)eligibleLayerNumsFromEngine:(id)engine {
    NSMutableArray<NSNumber *> *targets = [NSMutableArray array];
    if (!engine) return targets;
    
    SEL countSel = @selector(numActiveLayers);
    if (![engine respondsToSelector:countSel]) return targets;
    
    NSInteger count = 0;
    @try {
        count = ((NSInteger (*)(id, SEL))objc_msgSend)(engine, countSel);
    } @catch (NSException *e) {
        return targets;
    }
    if (count <= 0) return targets;
    
    SEL layerAtSel = @selector(layerAtLayerNum:);
    SEL isNullSel = @selector(isNullLayer:);
    
    for (NSInteger i = 0; i < count; i++) {
        if ([engine respondsToSelector:isNullSel]) {
            @try {
                if (((BOOL (*)(id, SEL, NSInteger))objc_msgSend)(engine, isNullSel, i)) continue;
            } @catch (NSException *e) {}
        }
        
        if ([engine respondsToSelector:layerAtSel]) {
            id layer = nil;
            @try {
                layer = ((id (*)(id, SEL, NSInteger))objc_msgSend)(engine, layerAtSel, i);
            } @catch (NSException *e) {}
            if (!layer) continue;
            
            if ([layer respondsToSelector:@selector(is3DLayer)]) {
                @try {
                    if (((BOOL (*)(id, SEL))objc_msgSend)(layer, @selector(is3DLayer))) continue;
                } @catch (NSException *e) {}
            }
            
            if ([layer respondsToSelector:@selector(valueForKey:)]) {
                @try {
                    if ([layer valueForKey:@"textDictionary"] != nil) continue;
                } @catch (NSException *e) {}
            }
        }
        
        [targets addObject:@(i)];
    }
    return targets;
}

+ (BOOL)verifyLayerFilled:(NSInteger)layerNum engine:(id)engine {
    if (!engine) return NO;
    SEL verifySel = @selector(assetHasBeenLoadedForLayer:);
    if ([engine respondsToSelector:verifySel]) {
        @try {
            return ((BOOL (*)(id, SEL, NSInteger))objc_msgSend)(engine, verifySel, layerNum);
        } @catch (NSException *e) {}
    }
    return NO;
}

+ (void)injectViaMakePhotoLayer:(UIImage *)image layerNum:(NSInteger)layerNum editor:(id)editorVC {
    if (!editorVC || !image) return;
    @try {
        if ([editorVC respondsToSelector:@selector(selectLayer:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(editorVC, @selector(selectLayer:), layerNum);
        } else if ([editorVC respondsToSelector:@selector(setCurrentLayerIndex:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(editorVC, @selector(setCurrentLayerIndex:), layerNum);
        }
        
        if ([editorVC respondsToSelector:@selector(makePhotoLayer:)]) {
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(editorVC, @selector(makePhotoLayer:), image);
        } else if ([editorVC respondsToSelector:@selector(confirmAddingLayer:)]) {
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(editorVC, @selector(confirmAddingLayer:), image);
        }
    } @catch (NSException *e) {}
}

+ (void)refreshEditorPreview:(id)editorVC {
    if (!editorVC) return;
    @try {
        if ([editorVC respondsToSelector:@selector(refreshPreview)]) {
            ((void (*)(id, SEL))objc_msgSend)(editorVC, @selector(refreshPreview));
        }
        if ([editorVC respondsToSelector:@selector(updateLayerButtons)]) {
            ((void (*)(id, SEL))objc_msgSend)(editorVC, @selector(updateLayerButtons));
        }
    } @catch (NSException *e) {}
}

+ (BOOL)fillAllActiveLayersInEditor:(id)editorVC withImage:(UIImage *)image {
    if (!editorVC || !image) return NO;
    
    id engine = [self multiLayerEngineFromEditor:editorVC];
    if (!engine) return NO;
    
    NSArray<NSNumber *> *eligibleLayers = [self eligibleLayerNumsFromEngine:engine];
    if (eligibleLayers.count == 0) return NO;
    
    BOOL anySuccess = NO;
    SEL typeSel = @selector(layerTypeForLayer:);
    SEL setupSel = @selector(setupImage:layerNum:layerType:clearMask:);
    
    for (NSNumber *layerNumObj in eligibleLayers) {
        NSInteger layerNum = layerNumObj.integerValue;
        
        NSInteger layerType = 2;
        if ([engine respondsToSelector:typeSel]) {
            @try {
                layerType = ((NSInteger (*)(id, SEL, NSInteger))objc_msgSend)(engine, typeSel, layerNum);
            } @catch (NSException *e) {}
        }
        
        if ([engine respondsToSelector:setupSel]) {
            @try {
                ((void (*)(id, SEL, UIImage *, NSInteger, NSInteger, BOOL))objc_msgSend)(engine, setupSel, image, layerNum, layerType, YES);
                anySuccess = YES;
            } @catch (NSException *e) {}
        }
        
        if (![self verifyLayerFilled:layerNum engine:engine]) {
            [self injectViaMakePhotoLayer:image layerNum:layerNum editor:editorVC];
            if ([self verifyLayerFilled:layerNum engine:engine]) {
                anySuccess = YES;
            }
        }
    }
    
    [self refreshEditorPreview:editorVC];
    return anySuccess;
}

+ (nullable UIImage *)extractFirstLayerImageFromEditor:(id)editorVC {
    if (!editorVC) return nil;
    @try {
        id engine = [self multiLayerEngineFromEditor:editorVC];
        if (!engine) return nil;
        
        NSArray<NSNumber *> *eligible = [self eligibleLayerNumsFromEngine:engine];
        SEL layerAtSel = @selector(layerAtLayerNum:);
        if (![engine respondsToSelector:layerAtSel]) return nil;
        
        for (NSNumber *num in eligible) {
            id layer = ((id (*)(id, SEL, NSInteger))objc_msgSend)(engine, layerAtSel, num.integerValue);
            if (!layer) continue;
            
            if ([layer respondsToSelector:@selector(imageGenerator)]) {
                id gen = ((id (*)(id, SEL))objc_msgSend)(layer, @selector(imageGenerator));
                if (gen && [gen respondsToSelector:@selector(layerImage)]) {
                    UIImage *img = ((UIImage * (*)(id, SEL))objc_msgSend)(gen, @selector(layerImage));
                    if ([img isKindOfClass:[UIImage class]]) return img;
                }
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

@end

#pragma mark - 4. VSAutoCoordinator: Điều Phối Tự Động Hóa & State Machine

typedef NS_ENUM(NSInteger, VSTContextType) {
    VSTContextTypeHidden = 0,
    VSTContextTypeSplitScene = 1,
    VSTContextTypeMultiLayer = 2
};

typedef NS_ENUM(NSInteger, VSTBatchPhase) {
    VSTBatchPhaseIdle = 0,
    VSTBatchPhasePickingQRCodes,
    VSTBatchPhaseInjectingQR,
    VSTBatchPhaseWaitingSegment1Image,
    VSTBatchPhaseFillingAllLayers,
    VSTBatchPhaseCreatingScene,
    VSTBatchPhaseAdvancingScene
};

@interface VSAutoCoordinator : NSObject <PHPickerViewControllerDelegate, UINavigationControllerDelegate, UIImagePickerControllerDelegate>

@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, assign) VSTContextType currentContext;
@property (nonatomic, assign) VSTBatchPhase batchPhase;

@property (nonatomic, weak) UIViewController *activeSplitVC;
@property (nonatomic, weak) UIViewController *activeMultiLayerVC;
@property (nonatomic, strong) UIViewController *batchActiveEditor;
@property (nonatomic, weak) id activeProjectInstance;

@property (nonatomic, assign) NSInteger targetSegmentCount;
@property (nonatomic, assign) NSInteger currentSegmentIdx;
@property (nonatomic, assign) NSInteger startingSceneIndex;
@property (nonatomic, strong) NSMutableArray<UIImage *> *qrImagesQueue;
@property (nonatomic, strong) NSMutableArray<NSString *> *qrStringsQueue;
@property (nonatomic, strong) UIImage *cachedFirstSegmentImage;
@property (nonatomic, assign) BOOL suppressAllOverwriteDialogs;

+ (instancetype)shared;
- (void)installHooks;
- (void)evaluateViewControllerContext:(UIViewController *)vc appearing:(BOOL)appearing;
- (void)onInterceptedUserSelectedImage:(UIImage *)image inEditor:(id)editor;

@end

@implementation VSAutoCoordinator

+ (instancetype)shared {
    static VSAutoCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VSAutoCoordinator alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _qrImagesQueue = [NSMutableArray array];
        _qrStringsQueue = [NSMutableArray array];
        _currentContext = VSTContextTypeHidden;
        _batchPhase = VSTBatchPhaseIdle;
        _suppressAllOverwriteDialogs = NO;
    }
    return self;
}

#pragma mark - Quản Lý Cửa Sổ & Tìm Kiếm ViewController

- (UIWindow *)mainWindow {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
}

- (nullable UIViewController *)findViewControllerNamed:(NSString *)partialClassName {
    UIWindow *win = [self mainWindow];
    if (!win || !win.rootViewController) return nil;
    return [self searchVC:win.rootViewController matching:partialClassName];
}

- (nullable UIViewController *)searchVC:(UIViewController *)root matching:(NSString *)name {
    if (!root) return nil;
    if ([NSStringFromClass([root class]) containsString:name]) {
        return root;
    }
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = [self searchVC:child matching:name];
        if (found) return found;
    }
    if (root.presentedViewController) {
        UIViewController *found = [self searchVC:root.presentedViewController matching:name];
        if (found) return found;
    }
    return nil;
}

#pragma mark - Nút Nhỏ Gọn Theo Màn Hình (Thay Thế 3 Ngón Tay)

- (void)ensureActionButtonCreated {
    if (self.actionButton) return;
    
    self.actionButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.actionButton.frame = CGRectMake(16, 108, 104, 32);
    self.actionButton.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.14 alpha:0.92];
    self.actionButton.layer.cornerRadius = 16.0;
    self.actionButton.layer.borderWidth = 1.25;
    self.actionButton.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
    [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.actionButton.hidden = YES;
    self.actionButton.layer.zPosition = 10000;
    
    [self.actionButton addTarget:self action:@selector(handleActionButtonTap) forControlEvents:UIControlEventTouchUpInside];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleButtonDrag:)];
    [self.actionButton addGestureRecognizer:pan];
}

- (void)handleButtonDrag:(UIPanGestureRecognizer *)pan {
    UIWindow *win = [self mainWindow];
    if (!win) return;
    CGPoint delta = [pan translationInView:win];
    CGPoint c = pan.view.center;
    c.x = MAX(55, MIN(win.bounds.size.width - 55, c.x + delta.x));
    c.y = MAX(55, MIN(win.bounds.size.height - 55, c.y + delta.y));
    pan.view.center = c;
    [pan setTranslation:CGPointZero inView:win];
}

- (void)refreshActionButtonUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureActionButtonCreated];
        UIWindow *win = [self mainWindow];
        if (!win) return;
        
        if (self.actionButton.superview != win) {
            [self.actionButton removeFromSuperview];
            [win addSubview:self.actionButton];
        }
        
        if (self.currentContext == VSTContextTypeSplitScene) {
            [self.actionButton setTitle:@"⚡ Chia Đoạn" forState:UIControlStateNormal];
            self.actionButton.layer.borderColor = [UIColor systemGreenColor].CGColor;
            self.actionButton.hidden = NO;
            [win bringSubviewToFront:self.actionButton];
        } else if (self.currentContext == VSTContextTypeMultiLayer) {
            if (self.batchPhase != VSTBatchPhaseIdle) {
                NSString *status = [NSString stringWithFormat:@"⏳ Đoạn %ld/%ld", (long)(self.currentSegmentIdx + 1), (long)self.targetSegmentCount];
                [self.actionButton setTitle:status forState:UIControlStateNormal];
                self.actionButton.layer.borderColor = [UIColor systemOrangeColor].CGColor;
            } else {
                [self.actionButton setTitle:@"⚡ Kết Hợp" forState:UIControlStateNormal];
                // Màu Cyan RGB tương thích iOS 14.0+ (không gây lỗi -Wunguarded-availability-new)
                self.actionButton.layer.borderColor = [UIColor colorWithRed:0.00 green:0.80 blue:1.00 alpha:1.0].CGColor;
            }
            self.actionButton.hidden = NO;
            [win bringSubviewToFront:self.actionButton];
        } else {
            self.actionButton.hidden = YES;
        }
    });
}

- (void)evaluateViewControllerContext:(UIViewController *)vc appearing:(BOOL)appearing {
    if (!vc) return;
    NSString *clsName = NSStringFromClass([vc class]);
    
    if ([vc isKindOfClass:[UIAlertController class]] ||
        [vc isKindOfClass:[UINavigationController class]] ||
        [vc isKindOfClass:[UIImagePickerController class]] ||
        [clsName containsString:@"PHPicker"]) {
        return;
    }
    
    if ([clsName containsString:@"New_Project"] || [clsName containsString:@"Old_Project"]) {
        self.activeProjectInstance = vc;
    }
    
    if ([clsName containsString:@"SceneSplitter"] || [clsName containsString:@"SplitScene"]) {
        if (appearing) {
            self.activeSplitVC = vc;
            self.currentContext = VSTContextTypeSplitScene;
        } else if (self.activeSplitVC == vc) {
            self.currentContext = VSTContextTypeHidden;
        }
        [self refreshActionButtonUI];
        return;
    }
    
    if ([clsName containsString:@"MultiLayer"] || [clsName containsString:@"KeyframeEditor"] || [clsName containsString:@"MLLayer"]) {
        if (appearing) {
            self.activeMultiLayerVC = vc;
            self.batchActiveEditor = vc;
            self.currentContext = VSTContextTypeMultiLayer;
        } else if (self.activeMultiLayerVC == vc && self.batchPhase == VSTBatchPhaseIdle) {
            self.currentContext = VSTContextTypeHidden;
        }
        [self refreshActionButtonUI];
        return;
    }
}

#pragma mark - Sự Kiện Ấn Nút & Reset State Machine

- (void)handleActionButtonTap {
    if (self.currentContext == VSTContextTypeSplitScene) {
        [self executeFunction1_SplitScene];
    } else if (self.currentContext == VSTContextTypeMultiLayer) {
        if (self.batchPhase != VSTBatchPhaseIdle) {
            [self resetBatchState];
            return;
        }
        [self startFunction4_PromptSegmentCount];
    }
}

- (void)resetBatchState {
    self.batchPhase = VSTBatchPhaseIdle;
    self.suppressAllOverwriteDialogs = NO;
    self.cachedFirstSegmentImage = nil;
    self.batchActiveEditor = nil;
    [self.qrImagesQueue removeAllObjects];
    [self.qrStringsQueue removeAllObjects];
    [self refreshActionButtonUI];
}

#pragma mark - CHỨC NĂNG 1: Giữ Nguyên Logic Copy Ảnh & Chia Đoạn

- (void)executeFunction1_SplitScene {
    @try {
        UIViewController *splitVC = self.activeSplitVC;
        if (!splitVC) return;
        
        UIImage *pasteImg = [UIPasteboard generalPasteboard].image;
        if (pasteImg && [splitVC respondsToSelector:@selector(setClipImage:)]) {
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(splitVC, @selector(setClipImage:), pasteImg);
        }
        
        NSArray<NSString *> *splitSelectors = @[@"splitScene", @"performSplit", @"splitButtonPressed:", @"doneButtonPressed:", @"done:"];
        for (NSString *selName in splitSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([splitVC respondsToSelector:sel]) {
                if ([selName hasSuffix:@":"]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(splitVC, sel, nil);
                } else {
                    ((void (*)(id, SEL))objc_msgSend)(splitVC, sel);
                }
                break;
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - CHỨC NĂNG 4: Nhập Số Đoạn -> Mở Kho Ảnh Chọn Các Code

- (void)startFunction4_PromptSegmentCount {
    UIViewController *presenter = self.activeMultiLayerVC ?: [self mainWindow].rootViewController;
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    if (!presenter) return;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Auto Kết Hợp"
                                                                   message:@"Nhập số phân đoạn cần chạy:"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Số phân đoạn (VD: 5)";
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.textAlignment = NSTextAlignmentCenter;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Chọn Ảnh Code" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSInteger count = [alert.textFields.firstObject.text integerValue];
        if (count <= 0) count = 1;
        
        self.targetSegmentCount = count;
        self.currentSegmentIdx = 0;
        self.cachedFirstSegmentImage = nil;
        [self.qrImagesQueue removeAllObjects];
        [self.qrStringsQueue removeAllObjects];
        
        [self presentBatchQRPhotoPickerFrom:presenter limit:count];
    }]];
    
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)presentBatchQRPhotoPickerFrom:(UIViewController *)presenter limit:(NSInteger)limit {
    self.batchPhase = VSTBatchPhasePickingQRCodes;
    
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.selectionLimit = limit;
        config.filter = [PHPickerFilter imagesFilter];
        config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
        
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;
        [presenter presentViewController:picker animated:YES completion:nil];
    } else {
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.delegate = self;
        [presenter presentViewController:picker animated:YES completion:nil];
    }
}

#pragma mark - PHPicker & UIImagePicker Delegate

- (NSInteger)determineSafeStartingSceneIndex {
    NSInteger currentIdx = [self readCurrentSceneIndexFromProject];
    if (currentIdx == NSNotFound) {
        UIViewController *editor = self.activeMultiLayerVC ?: self.batchActiveEditor;
        if (editor && [editor respondsToSelector:@selector(sceneIndex)]) {
            @try {
                currentIdx = ((NSInteger (*)(id, SEL))objc_msgSend)(editor, @selector(sceneIndex));
            } @catch (NSException *e) {}
        }
    }
    if (currentIdx == NSNotFound) {
        UIViewController *reviewVC = [self findViewControllerNamed:@"VideoReviewEditVC"];
        if (reviewVC && [reviewVC respondsToSelector:@selector(sceneIndex)]) {
            @try {
                currentIdx = ((NSInteger (*)(id, SEL))objc_msgSend)(reviewVC, @selector(sceneIndex));
            } @catch (NSException *e) {}
        }
    }
    if (currentIdx == NSNotFound || currentIdx < 0) {
        currentIdx = 0;
    }
    return currentIdx;
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    [picker dismissViewControllerAnimated:YES completion:^{
        if (results.count == 0) {
            [self resetBatchState];
            return;
        }
        
        dispatch_group_t group = dispatch_group_create();
        NSMutableArray *orderedImages = [NSMutableArray arrayWithCapacity:results.count];
        for (NSUInteger i = 0; i < results.count; i++) {
            [orderedImages addObject:[NSNull null]];
        }
        
        [results enumerateObjectsUsingBlock:^(PHPickerResult * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([obj.itemProvider canLoadObjectOfClass:[UIImage class]]) {
                dispatch_group_enter(group);
                [obj.itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading>  _Nullable object, NSError * _Nullable error) {
                    if ([object isKindOfClass:[UIImage class]]) {
                        @synchronized (orderedImages) {
                            orderedImages[idx] = object;
                        }
                    }
                    dispatch_group_leave(group);
                }];
            }
        }];
        
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [self.qrImagesQueue removeAllObjects];
            [self.qrStringsQueue removeAllObjects];
            
            for (id item in orderedImages) {
                if ([item isKindOfClass:[UIImage class]]) {
                    UIImage *img = (UIImage *)item;
                    NSString *decoded = [VSQRCodeDecoder decodeQRFromImage:img];
                    if (decoded.length > 0) {
                        [self.qrImagesQueue addObject:img];
                        [self.qrStringsQueue addObject:decoded];
                    }
                }
            }
            
            if (self.qrStringsQueue.count == 0) {
                [self resetBatchState];
                return;
            }
            
            self.targetSegmentCount = MIN(self.targetSegmentCount, self.qrStringsQueue.count);
            self.currentSegmentIdx = 0;
            self.startingSceneIndex = [self determineSafeStartingSceneIndex];
            self.suppressAllOverwriteDialogs = YES;
            [self refreshActionButtonUI];
            
            [self executeCurrentSegmentStep];
        });
    }];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!img) {
            [self resetBatchState];
            return;
        }
        if (self.batchPhase == VSTBatchPhasePickingQRCodes) {
            NSString *decoded = [VSQRCodeDecoder decodeQRFromImage:img];
            if (decoded.length > 0) {
                [self.qrImagesQueue addObject:img];
                [self.qrStringsQueue addObject:decoded];
                self.targetSegmentCount = 1;
                self.currentSegmentIdx = 0;
                self.startingSceneIndex = [self determineSafeStartingSceneIndex];
                self.suppressAllOverwriteDialogs = YES;
                [self executeCurrentSegmentStep];
            } else {
                [self resetBatchState];
            }
        } else if (self.batchPhase == VSTBatchPhaseWaitingSegment1Image) {
            [self onInterceptedUserSelectedImage:img inEditor:(self.batchActiveEditor ?: self.activeMultiLayerVC)];
        }
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:^{
        [self resetBatchState];
    }];
}

#pragma mark - Chu Trình Thực Thi Từng Phân Đoạn

- (void)executeCurrentSegmentStep {
    if (self.currentSegmentIdx >= self.targetSegmentCount || self.currentSegmentIdx >= self.qrStringsQueue.count) {
        [self resetBatchState];
        return;
    }
    
    self.batchActiveEditor = self.activeMultiLayerVC ?: self.batchActiveEditor;
    if (!self.batchActiveEditor) {
        [self resetBatchState];
        return;
    }
    
    [self refreshActionButtonUI];
    self.batchPhase = VSTBatchPhaseInjectingQR;
    self.suppressAllOverwriteDialogs = YES;
    
    NSString *qrCodeString = self.qrStringsQueue[self.currentSegmentIdx];
    UIImage *qrCodeImage = self.qrImagesQueue[self.currentSegmentIdx];
    
    // Bước 1: Nạp mã QR trực tiếp vào Editor
    [self injectQRIntoActiveEditor:self.batchActiveEditor withString:qrCodeString image:qrCodeImage];
    
    // Bước 2: Sau khi nạp QR hoàn tất
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.currentSegmentIdx == 0 && !self.cachedFirstSegmentImage) {
            // Đoạn 1: Hiện bảng chọn hình ảnh cho đoạn đầu tiên
            self.batchPhase = VSTBatchPhaseWaitingSegment1Image;
            [self openFirstSegmentContentImagePicker];
        } else {
            // Đoạn 2..N: Tự động điền luôn ảnh đã lưu từ Đoạn 1 vào tất cả các lớp
            self.batchPhase = VSTBatchPhaseFillingAllLayers;
            [self fillAllLayersAndAutoCreateWithImage:self.cachedFirstSegmentImage];
        }
    });
}

- (void)injectQRIntoActiveEditor:(id)editor withString:(NSString *)qrString image:(UIImage *)qrImage {
    if (!editor) return;
    @try {
        NSData *qrData = [VSQRCodeDecoder extractRawQRPayloadFromString:qrString];
        
        if ([editor respondsToSelector:@selector(importedData:code:)] && qrData) {
            ((void (*)(id, SEL, NSData *, NSString *))objc_msgSend)(editor, @selector(importedData:code:), qrData, qrString);
            return;
        }
        
        NSArray<NSString *> *stringSelectors = @[@"importQRCodeString:", @"handleQRCodeString:", @"processQRCode:"];
        for (NSString *sName in stringSelectors) {
            SEL sel = NSSelectorFromString(sName);
            if ([editor respondsToSelector:sel]) {
                ((void (*)(id, SEL, NSString *))objc_msgSend)(editor, sel, qrString);
                return;
            }
        }
        
        NSArray<NSString *> *imageSelectors = @[@"importQRImage:", @"decodeAndApplyQRImage:"];
        for (NSString *sName in imageSelectors) {
            SEL sel = NSSelectorFromString(sName);
            if ([editor respondsToSelector:sel] && qrImage) {
                ((void (*)(id, SEL, UIImage *))objc_msgSend)(editor, sel, qrImage);
                return;
            }
        }
    } @catch (NSException *e) {}
}

- (void)openFirstSegmentContentImagePicker {
    UIViewController *editor = self.batchActiveEditor ?: self.activeMultiLayerVC;
    if (!editor) {
        [self resetBatchState];
        return;
    }
    @try {
        if (!editor.presentedViewController) {
            UIImagePickerController *picker = [[UIImagePickerController alloc] init];
            picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            picker.delegate = self;
            [editor presentViewController:picker animated:YES completion:nil];
        }
    } @catch (NSException *e) {}
}

- (void)onInterceptedUserSelectedImage:(UIImage *)image inEditor:(id)editor {
    if (!image || ![image isKindOfClass:[UIImage class]]) return;
    if (self.batchPhase != VSTBatchPhaseWaitingSegment1Image) return;
    
    self.cachedFirstSegmentImage = image;
    self.batchPhase = VSTBatchPhaseFillingAllLayers;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self fillAllLayersAndAutoCreateWithImage:self.cachedFirstSegmentImage];
    });
}

- (void)fillAllLayersAndAutoCreateWithImage:(UIImage *)image {
    UIViewController *editor = self.batchActiveEditor ?: self.activeMultiLayerVC;
    if (!editor || !image) {
        [self resetBatchState];
        return;
    }
    
    // Điền ảnh cho tất cả các lớp hợp lệ trong phân đoạn hiện tại
    [VSBatchLayerFiller fillAllActiveLayersInEditor:editor withImage:image];
    
    // Tự động ấn Tạo (Create)
    self.batchPhase = VSTBatchPhaseCreatingScene;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self triggerCreateOnEditor:editor];
        
        UIViewController *previousEditor = editor;
        self.batchActiveEditor = nil;
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.currentSegmentIdx++;
            if (self.currentSegmentIdx < self.targetSegmentCount) {
                self.batchPhase = VSTBatchPhaseAdvancingScene;
                [self advanceProjectToNextSceneAndOpenMultiLayerFromPreviousEditor:previousEditor];
            } else {
                [self resetBatchState];
            }
        });
    });
}

- (void)triggerCreateOnEditor:(id)editor {
    if (!editor) return;
    @try {
        NSArray<NSString *> *createSelectors = @[@"create", @"createButtonPressed:", @"onCreateTapped:", @"done:", @"finishEditing"];
        for (NSString *selName in createSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([editor respondsToSelector:sel]) {
                if ([selName hasSuffix:@":"]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(editor, sel, nil);
                } else {
                    ((void (*)(id, SEL))objc_msgSend)(editor, sel);
                }
                return;
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - Chuyển Phân Đoạn Trên Project & Mở Multi-Layer Trên VideoReviewEditVC

- (id)resolveActiveProject {
    if (self.activeProjectInstance) return self.activeProjectInstance;
    @try {
        Class pmCls = NSClassFromString(@"_TtC10Video_Star14ProjectManager") ?: NSClassFromString(@"ProjectManager");
        if (pmCls) {
            SEL sharedSel = NSSelectorFromString(@"sharedInstance");
            if (![pmCls respondsToSelector:sharedSel]) {
                sharedSel = NSSelectorFromString(@"shared");
            }
            if ([pmCls respondsToSelector:sharedSel]) {
                id pm = ((id (*)(id, SEL))objc_msgSend)(pmCls, sharedSel);
                SEL currProjSel = NSSelectorFromString(@"currentProject");
                if (pm && [pm respondsToSelector:currProjSel]) {
                    return ((id (*)(id, SEL))objc_msgSend)(pm, currProjSel);
                }
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

- (NSInteger)readCurrentSceneIndexFromProject {
    @try {
        id proj = [self resolveActiveProject];
        if (proj && [proj respondsToSelector:@selector(lastViewedSceneIndex)]) {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(proj, @selector(lastViewedSceneIndex));
        }
    } @catch (NSException *e) {}
    return NSNotFound;
}

- (void)advanceProjectToNextSceneAndOpenMultiLayerFromPreviousEditor:(UIViewController *)previousEditor {
    // 1. Cập nhật lastViewedSceneIndex trên Project
    id proj = [self resolveActiveProject];
    NSInteger targetSceneIdx = self.startingSceneIndex + self.currentSegmentIdx;
    if (proj && [proj respondsToSelector:@selector(setLastViewedSceneIndex:)]) {
        @try {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(proj, @selector(setLastViewedSceneIndex:), targetSceneIdx);
        } @catch (NSException *e) {}
    }
    
    // 2. Tìm VideoReviewEditVC để gọi showMultiLayer
    UIViewController *reviewVC = [self findViewControllerNamed:@"VideoReviewEditVC"];
    if (reviewVC && [reviewVC respondsToSelector:@selector(showMultiLayer)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(reviewVC, @selector(showMultiLayer));
        } @catch (NSException *e) {}
    }
    
    // 3. Poll chờ MultiLayer VC của phân đoạn mới xuất hiện (Không dùng self-capturing block để tránh -Warc-retain-cycles)
    self.batchPhase = VSTBatchPhaseAdvancingScene;
    [self pollForNextMultiLayerEditorWithPreviousEditor:previousEditor attempt:0];
}

- (void)pollForNextMultiLayerEditorWithPreviousEditor:(UIViewController *)previousEditor attempt:(NSInteger)tries {
    if (self.batchPhase != VSTBatchPhaseAdvancingScene) return;
    if (tries > 100) {
        [self resetBatchState];
        return;
    }
    
    if (tries == 10 && (!self.activeMultiLayerVC || self.activeMultiLayerVC == previousEditor)) {
        UIViewController *rev = [self findViewControllerNamed:@"VideoReviewEditVC"];
        if (rev && [rev respondsToSelector:@selector(showMultiLayer)]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(rev, @selector(showMultiLayer));
            } @catch (NSException *e) {}
        }
    }
    
    if (self.activeMultiLayerVC &&
        self.activeMultiLayerVC.isViewLoaded &&
        self.activeMultiLayerVC.view.window != nil) {
        self.batchActiveEditor = self.activeMultiLayerVC;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf executeCurrentSegmentStep];
        });
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf pollForNextMultiLayerEditorWithPreviousEditor:previousEditor attempt:(tries + 1)];
    });
}

#pragma mark - 5. Các Hàm Hook C-Function

static void vs_hooked_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    IMP orig = VSTGetOriginalIMP(self, _cmd);
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, animated);
    [[VSAutoCoordinator shared] evaluateViewControllerContext:self appearing:YES];
}

static void vs_hooked_viewWillDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
    IMP orig = VSTGetOriginalIMP(self, _cmd);
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, animated);
    [[VSAutoCoordinator shared] evaluateViewControllerContext:self appearing:NO];
}

static void vs_hooked_presentVC(UIViewController *self, SEL _cmd, UIViewController *vcToPresent, BOOL flag, void (^completion)(void)) {
    if ([VSAutoCoordinator shared].suppressAllOverwriteDialogs &&
        [vcToPresent isKindOfClass:[UIAlertController class]]) {
        
        UIAlertController *alert = (UIAlertController *)vcToPresent;
        NSString *title = alert.title ?: @"";
        NSString *msg = alert.message ?: @"";
        NSString *combined = [NSString stringWithFormat:@" %@ %@ ", title, msg];
        NSString *lower = combined.lowercaseString;
        
        NSArray<NSString *> *matchKeywords = @[
            @"trùng khớp",
            @"match: shorten",
            @"match: stretch",
            @"original preset layers",
            @"các lớp cài đặt sẵn gốc",
            @"shorten/stretch"
        ];
        
        BOOL isMatchDialog = NO;
        for (NSString *kw in matchKeywords) {
            if ([lower containsString:kw]) {
                isMatchDialog = YES;
                break;
            }
        }
        
        NSArray<NSString *> *neverSuppress = @[
            @"purchase", @"pro", @"mua", @"subscription",
            @"error", @"lỗi", @"memory", @"bộ nhớ",
            @"insufficient", @"không đủ", @"delete", @"xoá", @"xóa"
        ];
        for (NSString *kw in neverSuppress) {
            if ([lower containsString:kw]) {
                isMatchDialog = NO;
                break;
            }
        }
        
        if (isMatchDialog) {
            if (completion) completion();
            return;
        }
    }
    
    IMP orig = VSTGetOriginalIMP(self, _cmd);
    if (orig) ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))orig)(self, _cmd, vcToPresent, flag, completion);
}

static void vs_hooked_confirmOverwrite_1(id self, SEL _cmd, id object, BOOL show) {
    if ([VSAutoCoordinator shared].suppressAllOverwriteDialogs) {
        SEL overwriteSel = @selector(overwrite:isAbleToShowTheLayerActionMenu:);
        if ([self respondsToSelector:overwriteSel]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(self, overwriteSel, object, NO);
            return;
        }
    }
    IMP orig = VSTGetOriginalIMP(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, BOOL))orig)(self, _cmd, object, show);
}

static void vs_hooked_confirmOverwrite_2(id self, SEL _cmd, id object, BOOL show, BOOL remove) {
    if ([VSAutoCoordinator shared].suppressAllOverwriteDialogs) {
        SEL overwriteSel = @selector(overwrite:isAbleToShowTheLayerActionMenu:removeOverlayBlending:);
        if ([self respondsToSelector:overwriteSel]) {
            ((void (*)(id, SEL, id, BOOL, BOOL))objc_msgSend)(self, overwriteSel, object, NO, remove);
            return;
        }
    }
    IMP orig = VSTGetOriginalIMP(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, BOOL, BOOL))orig)(self, _cmd, object, show, remove);
}

static void vs_hooked_confirmAddingLayer_5(id self, SEL _cmd, id layer, id obj1, id obj2, id obj3, BOOL show) {
    if ([VSAutoCoordinator shared].suppressAllOverwriteDialogs) {
        SEL directSel = @selector(addingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:);
        if ([self respondsToSelector:directSel]) {
            ((void (*)(id, SEL, id, id, id, id, BOOL))objc_msgSend)(self, directSel, layer, obj1, obj2, obj3, NO);
            return;
        }
        IMP orig = VSTGetOriginalIMP(self, _cmd);
        if (orig) {
            ((void (*)(id, SEL, id, id, id, id, BOOL))orig)(self, _cmd, layer, obj1, obj2, obj3, NO);
            return;
        }
    }
    IMP orig = VSTGetOriginalIMP(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id, id, id, BOOL))orig)(self, _cmd, layer, obj1, obj2, obj3, show);
}

static void vs_hooked_makePhotoLayer(id self, SEL _cmd, UIImage *image) {
    IMP orig = VSTGetOriginalIMP(self, _cmd);
    if (orig) ((void (*)(id, SEL, UIImage *))orig)(self, _cmd, image);
    
    if ([VSAutoCoordinator shared].batchPhase == VSTBatchPhaseWaitingSegment1Image &&
        [image isKindOfClass:[UIImage class]]) {
        [[VSAutoCoordinator shared] onInterceptedUserSelectedImage:image inEditor:self];
    }
}

#pragma mark - Cài Đặt Toàn Bộ Hook Qua Per-Class Registry

- (void)installHooks {
    VSTHookMethodOnClass([UIViewController class], @selector(viewDidAppear:), (IMP)vs_hooked_viewDidAppear);
    VSTHookMethodOnClass([UIViewController class], @selector(viewWillDisappear:), (IMP)vs_hooked_viewWillDisappear);
    VSTHookMethodOnClass([UIViewController class], @selector(presentViewController:animated:completion:), (IMP)vs_hooked_presentVC);
    
    SEL selOverwrite1 = @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:);
    SEL selOverwrite2 = @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:removeOverlayBlending:);
    SEL selConfirmAdd5 = @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:);
    SEL selMakePhoto = @selector(makePhotoLayer:);
    
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        
        for (int i = 0; i < numClasses; i++) {
            Class cls = classes[i];
            const char *cName = class_getName(cls);
            if (!cName) continue;
            
            if (strstr(cName, "MultiLayer") != NULL ||
                strstr(cName, "KeyframeEditor") != NULL ||
                strstr(cName, "MLLayer") != NULL) {
                
                if (class_getInstanceMethod(cls, selOverwrite1)) {
                    VSTHookMethodOnClass(cls, selOverwrite1, (IMP)vs_hooked_confirmOverwrite_1);
                }
                if (class_getInstanceMethod(cls, selOverwrite2)) {
                    VSTHookMethodOnClass(cls, selOverwrite2, (IMP)vs_hooked_confirmOverwrite_2);
                }
                if (class_getInstanceMethod(cls, selConfirmAdd5)) {
                    VSTHookMethodOnClass(cls, selConfirmAdd5, (IMP)vs_hooked_confirmAddingLayer_5);
                }
                if (class_getInstanceMethod(cls, selMakePhoto)) {
                    VSTHookMethodOnClass(cls, selMakePhoto, (IMP)vs_hooked_makePhotoLayer);
                }
            }
        }
        free(classes);
    }
}

@end

#pragma mark - 6. Constructor Khởi Chạy Dylib

__attribute__((constructor))
static void initVideoStarPerfectTool(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VSAutoCoordinator shared] installHooks];
    });
}
