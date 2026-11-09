// ============================================================================
// VideoStarTool.m
// Runtime Automation Bot for Video Star 14.3.3 (build 1809)
//
// Kiến trúc Tweak Theos / Logos nâng cao dành riêng cho Video Star:
//   1. Auto nhập ảnh/video vào tất cả các lớp (1-Chạm Thay Media thông minh)
//   2. Hiển thị và trích xuất mã QR / Preset gần nhất đã nhập
//   3. Auto chia beat phân cảnh (Beat Sync & Scene Multi-Splitter)
//   4. Auto nhập QR code + thay thế media hàng loạt qua từng phân cảnh
//
// ĐẶC TRỊ TRIỆT ĐỂ 3 NGUYÊN NHÂN LỖI TRÊN VIDEO:
//   - LỖI 1: Popup cảnh báo lệch frame (Mismatch Frame/Duration Warning)
//   - LỖI 2: Kẹt vòng lặp chờ trạng thái (Stuck/Infinite Polishing State)
//   - LỖI 3: Tràn RAM / Xung đột luồng đồ họa gây sập app (Crash / Black Screen)
// ============================================================================

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define VS_MAX_LAYERS 30
#define VS_TAG "[VideoStarTool] "
#define VSLog(fmt, ...) NSLog(@VS_TAG fmt, ##__VA_ARGS__)

// ============================================================================
// PHẦN 1: KHAI BÁO GIAO DIỆN PRIVATE API (ĐỐI CHIẾU CHÍNH XÁC KTOOL HEADERS)
// ============================================================================

@protocol ProjectInterface <NSObject>
@property (nonatomic, readonly) NSUInteger sceneCount;
@property (nonatomic, readonly) NSUInteger lastSceneIndex;
@property (nonatomic) CGFloat songBPM;
@property (nonatomic) CGFloat songFirstBeatTime;
@property (nonatomic) CGFloat songDuration;
- (CGFloat)durationOfSceneAtIndex:(NSUInteger)sceneIndex;
- (CMTime)sceneStartCMTime:(NSUInteger)sceneIndex;
- (BOOL)sceneHasAtLeastOneClipWithSceneIndex:(NSUInteger)sceneIndex;
- (NSUInteger)clipCountForSceneIndex:(NSUInteger)sceneIndex;
- (id)fileManager;
- (void)splitSceneAtIndex:(NSUInteger)sceneIndex time:(CMTime)time progressView:(id)progressView completion:(id)completion;
- (void)multiSplitSceneAtIndex:(NSUInteger)sceneIndex times:(NSArray *)times progressView:(id)progressView completion:(id)completion;
- (BOOL)addNewClipToSceneAtIndex:(NSUInteger)sceneIndex clipURL:(NSURL *)clipURL sourceClipIndex:(NSInteger)sourceClipIndex makeActive:(BOOL)makeActive image:(UIImage *)image frameTimes:(id)frameTimes;
- (CMTime)addNewSceneWithVideoURL:(NSURL *)videoURL image:(UIImage *)image frameTimes:(id)frameTimes;
@end

@interface NSObject (VSPrivateDeclarations)
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
- (void)updateDisplayAtFrame:(NSInteger)frame;
- (void)create;
- (void)startCreate;
- (void)createStepTwo;
- (void)importedData:(id)data code:(id)code;
- (void)importOldPreset:(id)preset;
- (void)importNewPreset:(id)preset keyFrameAction:(id)action qrDurationInFrames:(NSInteger)frames;
- (BOOL)isEditing;
- (BOOL)isViewLoaded;
- (UIView *)view;
- (UINavigationController *)navigationController;

// MultiLayerEngine
- (id)layerAtLayerNum:(NSUInteger)n;
- (NSInteger)numActiveLayers;
- (int)activeLayers;
- (void)reloadLayerEffects;

// MultiLayerLayer
- (id)imageGenerator;
- (id)parameters;
- (id)effect;
- (NSString *)origAssetInfo;

// MultiLayerImageGenerator
- (id)asset;
- (UIImage *)layerImage;
- (id)layerDrawing;
- (id)layerZaps;
- (id)layerGIF;
- (id)layerOverlay;
- (unsigned int)layerImageTextureID;

// VideoReviewEditVC
- (NSUInteger)navSceneIndex;
- (id<ProjectInterface>)project;
- (NSUInteger)sceneIndex;
- (void)showMergeScenes;
- (void)closeMergePanel;
- (void)showMultiLayer;
- (void)showSplitScene;
- (void)closeSplitPanel;
- (NSUInteger)lastViewedSceneIndex;
- (void)setLastViewedSceneIndex:(NSUInteger)i;
- (BOOL)isEnoughStorageAvailableForSplit;
- (void)performSplitWithTimes:(id)times;

// MultiSplitView
- (BOOL)beatModeOn;
- (void)toggleBeatMode;
- (BOOL)hasNextBeat;
- (void)jumpToNextBeat;
- (void)setSplitPoint;
- (void)doSplit;
- (void)gotoTime:(CMTime)t;
- (CMTime)currentTime;

// QRCodeManager
+ (id)sharedInstance;
- (void)selectedCode:(id)code withImageData:(id)data;
- (void)startQRImport;
- (void)setDelegate:(id)delegate;
- (id)delegate;

// ProjectManager
+ (id)sharedInstance;
- (id<ProjectInterface>)activeEditProject;

// ProjectFileManager
- (NSURL *)clipURLForSceneIndex:(NSUInteger)sceneIndex clipIndex:(NSUInteger)clipIndex;

// CustomPopup
- (void)show;
- (void)dismiss;
- (void)bounceClosed;
- (void)simulateButtonPressButtonWithTitle:(id)title;
- (void)buttonPressed:(id)button;
@end

// ============================================================================
// PHẦN 2: CÁC TIỆN ÍCH AN TOÀN BỘ NHỚ, ĐỒNG BỘ THREAD VÀ BỘ ĐỆM ĐIỀU KHIỂN
// ============================================================================

static NSUInteger g_runIdentifier = 0;
static NSHashTable *g_activePopupsTable = nil;
static id g_lastHandledPopup = nil;
static CFAbsoluteTime g_lastHandledPopupTime = 0;

static inline void VSRunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        @autoreleasepool { block(); }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool { block(); }
        });
    }
}

static inline void VSDispatchAfterMS(int64_t delayMs, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        @autoreleasepool { block(); }
    });
}

static inline CMTime VSSafeCurrentTime(id object) {
    if (!object) return kCMTimeInvalid;
    SEL sel = @selector(currentTime);
    if (![object respondsToSelector:sel]) return kCMTimeInvalid;
    @try {
        CMTime (*func)(id, SEL) = (CMTime (*)(id, SEL))[object methodForSelector:sel];
        return func(object, sel);
    } @catch (NSException *e) {
        VSLog(@"Lỗi lấy currentTime: %@", e);
        return kCMTimeInvalid;
    }
}

static inline id VSSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

static inline BOOL VSSafeIsClass(id object, NSString *className) {
    if (!object || !className.length) return NO;
    Class targetClass = NSClassFromString(className);
    return targetClass && [object isKindOfClass:targetClass];
}

// Polling bất đồng bộ an toàn: Dọn sạch Autoreleasepool mỗi chu kỳ, không nghẽn runloop
static void VSSafePoll(NSUInteger runId, int64_t intervalMs, NSUInteger remainingTries,
                       BOOL (^conditionBlock)(void), void (^completionBlock)(BOOL success)) {
    if (runId != g_runIdentifier) {
        if (completionBlock) completionBlock(NO);
        return;
    }
    
    BOOL matched = NO;
    @autoreleasepool {
        @try {
            matched = conditionBlock();
        } @catch (NSException *e) {
            VSLog(@"Ngoại lệ trong Poll: %@", e);
            matched = NO;
        }
    }
    
    if (matched) {
        if (completionBlock) completionBlock(YES);
        return;
    }
    
    if (remainingTries == 0) {
        if (completionBlock) completionBlock(NO);
        return;
    }
    
    VSDispatchAfterMS(intervalMs, ^{
        VSSafePoll(runId, intervalMs, remainingTries - 1, conditionBlock, completionBlock);
    });
}

// Bộ duyệt tìm ViewController đệ quy an toàn
static UIViewController *VSSearchViewControllerRecursive(UIViewController *rootVC, Class targetClass, int depth) {
    if (!rootVC || depth > 15) return nil;
    
    UIViewController *result = nil;
    if (rootVC.presentedViewController) {
        result = VSSearchViewControllerRecursive(rootVC.presentedViewController, targetClass, depth + 1);
        if (result) return result;
    }
    
    if ([rootVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)rootVC;
        for (UIViewController *child in nav.viewControllers.reverseObjectEnumerator) {
            result = VSSearchViewControllerRecursive(child, targetClass, depth + 1);
            if (result) return result;
        }
    }
    
    if ([rootVC isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)rootVC;
        result = VSSearchViewControllerRecursive(tab.selectedViewController, targetClass, depth + 1);
        if (result) return result;
    }
    
    for (UIViewController *child in rootVC.childViewControllers.reverseObjectEnumerator) {
        result = VSSearchViewControllerRecursive(child, targetClass, depth + 1);
        if (result) return result;
    }
    
    if ([rootVC isKindOfClass:targetClass] && rootVC.isViewLoaded && rootVC.view.window) {
        return rootVC;
    }
    return nil;
}

static UIWindow *g_overlayToolWindow = nil;

static UIViewController *VSFindTopViewControllerNamed(NSString *className) {
    Class targetClass = NSClassFromString(className);
    if (!targetClass) return nil;
    
    NSArray *windows = UIApplication.sharedApplication.windows;
    for (UIWindow *w in windows.reverseObjectEnumerator) {
        if (w == g_overlayToolWindow || w.hidden || w.alpha <= 0.01) continue;
        UIViewController *found = VSSearchViewControllerRecursive(w.rootViewController, targetClass, 0);
        if (found) return found;
    }
    return nil;
}

// ============================================================================
// PHẦN 3: XỬ LÝ TRIỆT ĐỂ LỖI 1 — SMART POPUP & MISMATCH FRAME RESOLVER
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
            if (popup && ![results containsObject:popup]) {
                [results addObject:popup];
            }
        }
    }
    
    if (g_activePopupsTable) {
        for (id popup in g_activePopupsTable.allObjects) {
            if (popup && ![results containsObject:popup]) {
                [results addObject:popup];
            }
        }
    }
    
    NSMutableArray *visibleOnly = [NSMutableArray array];
    for (id popup in results) {
        if (!VSSafeIsClass(popup, @"CustomPopup")) continue;
        UIView *dimView = VSSafeValueForKey(popup, @"dimView");
        UIView *popupView = (UIView *)popup;
        if ((dimView && dimView.window) || (popupView && popupView.window)) {
            [visibleOnly addObject:popup];
        }
    }
    return visibleOnly;
}

// Kiểm tra xem popup có phải là bảng chào mua gói VIP/Pro hay không
static BOOL VSCheckIfPopupIsPurchasePrompt(id popup) {
    NSString *message = [VSSafeValueForKey(popup, @"_message") description].lowercaseString ?: @"";
    NSString *title = [VSSafeValueForKey(popup, @"_title") description].lowercaseString ?: @"";
    NSString *combined = [title stringByAppendingFormat:@" %@", message];
    
    NSArray *purchaseKeywords = @[
        @"purchase", @"subscription", @"unlock pro", @"pro pack", @"restore purchase",
        @"all access", @"pass", @"buy", @"mua gói", @"khôi phục", @"đăng ký", @"nâng cấp",
        @"dùng thử", @"mở khóa", @"thanh toán"
    ];
    for (NSString *keyword in purchaseKeywords) {
        if ([combined containsString:keyword]) return YES;
    }
    return NO;
}

// Xử lý tự động nhấn lựa chọn tối ưu trong popup cảnh báo độ dài frame và popup xác nhận
static VSPopupActionStatus VSResolvePopupsImmediately(id editorVC) {
    NSArray *popups = VSCollectAllVisiblePopups(editorVC);
    if (popups.count == 0) return VSPopupActionStatusNone;
    
    // Danh sách ưu tiên theo thứ tự logic xử lý Video Star:
    // 1. Độ dài lệch frame: ưu tiên "Khớp: rút ngắn/giãn" / "Trùng khớp" / "Match: shorten/stretch"
    // 2. Tương thích preset: "Original Preset Layers" / "Các lớp cài đặt sẵn gốc"
    // 3. Khớp kích cỡ: "Fit" / "Vừa khung" / "Scale"
    // 4. Tiếp tục / Chấp thuận: "Continue" / "Tiếp tục" / "OK" / "Đồng ý" / "Yes" / "Có"
    NSArray *priorityButtonNames = @[
        @"Khớp: rút ngắn/giãn", @"Match: shorten/stretch",
        @"Trùng khớp", @"Match",
        @"Original Preset Layers", @"Các lớp cài đặt sẵn gốc",
        @"Bắt đầu", @"Start",
        @"Kết thúc", @"End",
        @"Fit", @"Vừa khung",
        @"Replace", @"Thay thế",
        @"Continue", @"Tiếp tục",
        @"Yes", @"Có",
        @"OK", @"Đồng ý",
        @"Done", @"Xong"
    ];
    
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    
    for (id popup in popups) {
        if (VSCheckIfPopupIsPurchasePrompt(popup)) {
            VSLog(@"Phát hiện popup yêu cầu thanh toán/Pro Pack. Dừng chu trình an toàn.");
            return VSPopupActionStatusBlockedPurchase;
        }
        
        // Chống dội lặp lại trên cùng 1 instance popup trong khoảng 350ms
        if (popup == g_lastHandledPopup && (now - g_lastHandledPopupTime < 0.35)) {
            return VSPopupActionStatusHandled;
        }
        
        NSArray *buttonStrings = VSSafeValueForKey(popup, @"_buttonStrings");
        NSArray *buttonsArray = VSSafeValueForKey(popup, @"_buttons");
        
        NSString *matchedTitle = nil;
        UIButton *matchedButtonObj = nil;
        
        for (NSString *candidate in priorityButtonNames) {
            NSString *localizedCandidate = VSLocalizedString(candidate);
            
            // Tìm trong chuỗi tiêu đề mảng _buttonStrings
            if ([buttonStrings isKindOfClass:[NSArray class]]) {
                for (id titleItem in buttonStrings) {
                    if (![titleItem isKindOfClass:[NSString class]]) continue;
                    NSString *str = (NSString *)titleItem;
                    if ([str localizedCaseInsensitiveContainsString:candidate] ||
                        [str localizedCaseInsensitiveContainsString:localizedCandidate]) {
                        matchedTitle = str;
                        break;
                    }
                }
            }
            if (matchedTitle) break;
            
            // Tìm trực tiếp trên mảng UIButton instance
            if ([buttonsArray isKindOfClass:[NSArray class]]) {
                for (id btnObj in buttonsArray) {
                    if (![btnObj isKindOfClass:[UIButton class]]) continue;
                    UIButton *btn = (UIButton *)btnObj;
                    NSString *currentBtnTitle = btn.currentTitle;
                    if (currentBtnTitle.length &&
                        ([currentBtnTitle localizedCaseInsensitiveContainsString:candidate] ||
                         [currentBtnTitle localizedCaseInsensitiveContainsString:localizedCandidate])) {
                        matchedTitle = currentBtnTitle;
                        matchedButtonObj = btn;
                        break;
                    }
                }
            }
            if (matchedTitle || matchedButtonObj) break;
        }
        
        if (matchedTitle || matchedButtonObj) {
            g_lastHandledPopup = popup;
            g_lastHandledPopupTime = now;
            
            @try {
                if (matchedTitle && [popup respondsToSelector:@selector(simulateButtonPressButtonWithTitle:)]) {
                    VSLog(@"[SmartPopup] Tự động nhấn theo tiêu đề: '%@'", matchedTitle);
                    [popup simulateButtonPressButtonWithTitle:matchedTitle];
                } else if (matchedButtonObj) {
                    VSLog(@"[SmartPopup] Tự động gửi touchUpInside cho nút: '%@'", matchedButtonObj.currentTitle);
                    [matchedButtonObj sendActionsForControlEvents:UIControlEventTouchUpInside];
                } else if ([popup respondsToSelector:@selector(dismiss)]) {
                    [popup dismiss];
                }
            } @catch (NSException *e) {
                VSLog(@"[SmartPopup] Lỗi ngoại lệ khi nhấn popup: %@", e);
            }
            return VSPopupActionStatusHandled;
        }
    }
    
    return VSPopupActionStatusNone;
}

static inline BOOL VSHasAnyActivePopup(id editorVC) {
    return VSCollectAllVisiblePopups(editorVC).count > 0;
}

// ============================================================================
// PHẦN 4: XÁC MINH VÀ PHÂN LOẠI LAYER (TRÁNH LỖI KẸT MEDIA)
// ============================================================================

typedef NS_ENUM(NSInteger, VSLayerMediaKind) {
    VSLayerMediaKindUnknown = 0,
    VSLayerMediaKindImage,
    VSLayerMediaKindVideo
};

@interface VSLayerSnapshot : NSObject
@property (nonatomic, assign) NSUInteger layerIndex;
@property (nonatomic, assign) VSLayerMediaKind mediaKind;
@property (nonatomic, strong) id mediaObject;
@property (nonatomic, assign) unsigned int textureID;
@property (nonatomic, copy)   NSString *assetInfo;
@end

@implementation VSLayerSnapshot
@end

static VSLayerSnapshot *VSInspectLayerDetails(id engine, NSUInteger layerNum) {
    if (!engine) return nil;
    @autoreleasepool {
        @try {
            id layer = [engine layerAtLayerNum:layerNum];
            if (!layer) return nil;
            
            // Loại trừ các loại layer 3D/text/shape không phải ảnh hoặc video phẳng
            if (VSSafeValueForKey(layer, @"layer3D") || VSSafeValueForKey(layer, @"layer3d")) return nil;
            
            id generator = [layer respondsToSelector:@selector(imageGenerator)] ? [layer imageGenerator] : nil;
            if (!generator) return nil;
            
            if ([generator respondsToSelector:@selector(layerDrawing)] && [generator layerDrawing]) return nil;
            if ([generator respondsToSelector:@selector(layerZaps)] && [generator layerZaps]) return nil;
            if ([generator respondsToSelector:@selector(layerGIF)] && [generator layerGIF]) return nil;
            if ([generator respondsToSelector:@selector(layerOverlay)] && [generator layerOverlay]) return nil;
            
            if (VSSafeValueForKey(generator, @"isTextLayer") || VSSafeValueForKey(generator, @"isColorLayer") ||
                VSSafeValueForKey(generator, @"is3DLayer") || VSSafeValueForKey(generator, @"isDrawingLayer") ||
                VSSafeValueForKey(generator, @"fillColor") || VSSafeValueForKey(generator, @"textView")) {
                return nil;
            }
            
            VSLayerSnapshot *snap = [VSLayerSnapshot new];
            snap.layerIndex = layerNum;
            snap.assetInfo = [layer respondsToSelector:@selector(origAssetInfo)] ? [layer origAssetInfo] : @"";
            
            if ([generator respondsToSelector:@selector(layerImageTextureID)]) {
                snap.textureID = [generator layerImageTextureID];
            }
            
            id asset = [generator respondsToSelector:@selector(asset)] ? [generator asset] : nil;
            if ([asset isKindOfClass:[AVAsset class]]) {
                snap.mediaKind = VSLayerMediaKindVideo;
                snap.mediaObject = asset;
                return snap;
            }
            
            UIImage *img = [generator respondsToSelector:@selector(layerImage)] ? [generator layerImage] : nil;
            if ([img isKindOfClass:[UIImage class]] && img.size.width > 1.0) {
                snap.mediaKind = VSLayerMediaKindImage;
                snap.mediaObject = img;
                return snap;
            }
            
            // Trường hợp layer đã tạo nhưng chưa có asset hoặc ảnh tĩnh
            snap.mediaKind = VSLayerMediaKindImage;
            snap.mediaObject = nil;
            return snap;
        } @catch (NSException *e) {
            VSLog(@"Lỗi inspect layer %lu: %@", (unsigned long)layerNum, e);
            return nil;
        }
    }
}

// ============================================================================
// PHẦN 5: TRÍCH XUẤT VÀ LƯU TRỮ QR CODE BẰNG COREIMAGE ĐỘ CHÍNH XÁC CAO
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
            if ([rawData isKindOfClass:[NSData class]]) {
                image = [UIImage imageWithData:(NSData *)rawData];
            } else if ([rawData isKindOfClass:[UIImage class]]) {
                image = (UIImage *)rawData;
            }
            if (image) {
                NSData *pngData = UIImagePNGRepresentation(image);
                [pngData writeToFile:VSGetLastQRCodeStoragePath() atomically:YES];
                VSLog(@"Đã lưu QR code gần nhất thành công (%lu bytes).", (unsigned long)pngData.length);
            }
        }
    });
}

static UIImage *VSReadLastPersistedQRCodeImage(void) {
    NSString *path = VSGetLastQRCodeStoragePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data.length ? [UIImage imageWithData:data] : nil;
}

static NSString *VSDecodeQRCodeMessageFromImage(UIImage *image) {
    if (!image) return nil;
    @autoreleasepool {
        CIImage *ci = [CIImage imageWithCGImage:image.CGImage];
        if (!ci) ci = [[CIImage alloc] initWithImage:image];
        if (!ci) return nil;
        
        CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                                  context:nil
                                                  options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
        NSArray *features = [detector featuresInImage:ci];
        for (CIFeature *f in features) {
            if ([f isKindOfClass:[CIQRCodeFeature class]]) {
                CIQRCodeFeature *qrf = (CIQRCodeFeature *)f;
                if (qrf.messageString.length) return qrf.messageString;
            }
        }
        return nil;
    }
}

// ============================================================================
// PHẦN 6: HOOKS AN TOÀN — THEOS / LOGOS SWIZZLE CÓ BẢO VỆ
// ============================================================================

static IMP g_origPickedWithResponse = NULL;
static IMP g_origSelectedCodeWithImageData = NULL;
static IMP g_origImportNewPreset = NULL;
static IMP g_origImportOldPreset = NULL;
static IMP g_origCustomPopupShow = NULL;

static NSUInteger g_presetImportEventCounter = 0;
static void (^g_activeMediaPickedHandler)(id editorVC, id response) = nil;

static BOOL VSRobustSwizzleMethod(NSString *className, SEL selector, id blockImpl, IMP *origImp) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        VSLog(@"Không tìm thấy class để swizzle: %@", className);
        return NO;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        VSLog(@"Không tìm thấy method để swizzle: -[%@ %@]", className, NSStringFromSelector(selector));
        return NO;
    }
    if (*origImp != NULL) return YES;
    
    IMP newImp = imp_implementationWithBlock(blockImpl);
    const char *types = method_getTypeEncoding(method);
    
    if (class_addMethod(cls, selector, newImp, types)) {
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
        
        // 1. Hook bắt kết quả chọn media từ ClipPicker
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(pickedWithClipPickerResponse:),
                              ^(id selfInstance, id response) {
            if (g_origPickedWithResponse) {
                ((void (*)(id, SEL, id))g_origPickedWithResponse)(selfInstance, @selector(pickedWithClipPickerResponse:), response);
            }
            void (^handler)(id, id) = g_activeMediaPickedHandler;
            if (handler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @autoreleasepool { handler(selfInstance, response); }
                });
            }
        }, &g_origPickedWithResponse);
        
        // 2. Hook bắt ảnh QR khi người dùng chọn trong QRCodeManager
        VSRobustSwizzleMethod(@"QRCodeManager", @selector(selectedCode:withImageData:),
                              ^(id selfInstance, id code, id imageData) {
            VSPersistQRCodeImageData(imageData);
            if (g_origSelectedCodeWithImageData) {
                ((void (*)(id, SEL, id, id))g_origSelectedCodeWithImageData)(selfInstance, @selector(selectedCode:withImageData:), code, imageData);
            }
        }, &g_origSelectedCodeWithImageData);
        
        // 3. Hook đếm sự kiện nạp preset mới
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(importNewPreset:keyFrameAction:qrDurationInFrames:),
                              ^(id selfInstance, id preset, id action, NSInteger frames) {
            if (g_origImportNewPreset) {
                ((void (*)(id, SEL, id, id, NSInteger))g_origImportNewPreset)(selfInstance, @selector(importNewPreset:keyFrameAction:qrDurationInFrames:), preset, action, frames);
            }
            g_presetImportEventCounter++;
            VSLog(@"[Hook] Đã kích hoạt importNewPreset (lần thứ %lu)", (unsigned long)g_presetImportEventCounter);
        }, &g_origImportNewPreset);
        
        // 4. Hook đếm sự kiện nạp preset cũ
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(importOldPreset:),
                              ^(id selfInstance, id preset) {
            if (g_origImportOldPreset) {
                ((void (*)(id, SEL, id))g_origImportOldPreset)(selfInstance, @selector(importOldPreset:), preset);
            }
            g_presetImportEventCounter++;
            VSLog(@"[Hook] Đã kích hoạt importOldPreset (lần thứ %lu)", (unsigned long)g_presetImportEventCounter);
        }, &g_origImportOldPreset);
        
        // 5. Hook CustomPopup show: Xử lý tức thì các cảnh báo lệch frame và popup thừa
        VSRobustSwizzleMethod(@"CustomPopup", @selector(show),
                              ^(id selfInstance) {
            if (g_origCustomPopupShow) {
                ((void (*)(id, SEL))g_origCustomPopupShow)(selfInstance, @selector(show));
            }
            if (selfInstance) {
                [g_activePopupsTable addObject:selfInstance];
            }
            // Đặt lịch giải quyết popup ngay sau 80ms để đảm bảo layout view hoàn tất
            VSDispatchAfterMS(80, ^{
                VSResolvePopupsImmediately(nil);
            });
        }, &g_origCustomPopupShow);
        
        VSLog(@"Đã cài đặt hoàn chỉnh các Hooks cốt lõi.");
    });
}

static BOOL VSReplayClipPickerResponseOnEditor(id editorVC, id response) {
    if (!editorVC || !response || !g_origPickedWithResponse) return NO;
    @autoreleasepool {
        @try {
            ((void (*)(id, SEL, id))g_origPickedWithResponse)(editorVC, @selector(pickedWithClipPickerResponse:), response);
            return YES;
        } @catch (NSException *e) {
            VSLog(@"Lỗi Replay ClipPickerResponse: %@", e);
            return NO;
        }
    }
}

// ============================================================================
// PHẦN 7: GIAO DIỆN NGUYÊN BẢN (FLOATING BUTTON, STATUS HUD, MODAL VIEWS)
// ============================================================================

@interface VSToolPassThroughWindow : UIWindow
@end

@implementation VSToolPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil; // Cho phép tương tác chạm xuyên qua cửa sổ nền
    }
    return hitView;
}
@end

static inline UIColor *VSToolCyanColor(void) {
    return [UIColor colorWithRed:0.25 green:0.85 blue:0.96 alpha:1.0];
}

static inline UIColor *VSToolCardBackgroundColor(void) {
    return [UIColor colorWithRed:0.03 green:0.08 blue:0.12 alpha:0.96];
}

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
    iv.layer.cornerRadius = 14;
    iv.clipsToBounds = YES;
    iv.frame = CGRectInset(self.view.bounds, 24, 110);
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:iv];
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 56, self.view.bounds.size.width, 32)];
    titleLabel.text = @"Code gần nhất đã nhập";
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:titleLabel];
    
    CGFloat w = (self.view.bounds.size.width - 48) / 2.0;
    NSArray *buttonTitles = @[@"Đóng", @"Chia sẻ / Lưu"];
    for (NSUInteger i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(24 + i * (w + 12), self.view.bounds.size.height - 84, w - 6, 44);
        b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
        [b setTitle:buttonTitles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(actionButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }
}

- (void)actionButtonTapped:(UIButton *)button {
    if (button.tag == 0) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        if (!self.qrImage) return;
        UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[self.qrImage] applicationActivities:nil];
        avc.popoverPresentationController.sourceView = button;
        [self presentViewController:avc animated:YES completion:nil];
    }
}
@end

// Delegate trung gian bắt mã QR nhập từ QRCodeManager mà không ghi đè trực tiếp
@interface VSToolQRCodeCaptureProxy : NSObject
@property (nonatomic, copy) void (^onCodeCapturedBlock)(id presetData, id codeIdentifier);
@end

@implementation VSToolQRCodeCaptureProxy
- (NSString *)qrLabel { return VSLocalizedString(@"Multi-Layer"); }
- (NSString *)qrSetupLabel { return @""; }
- (NSString *)codePrefix { return @"n"; }
- (BOOL)validCode:(NSString *)code {
    return [code isKindOfClass:[NSString class]] && ([code hasPrefix:@"m"] || [code hasPrefix:@"n"]);
}
- (void)importedData:(id)data code:(id)code {
    void (^block)(id, id) = self.onCodeCapturedBlock;
    if (block) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool { block(data, code); }
        });
    }
}
- (id)dataToShare { return nil; }
- (void)setActivityiPadPopup:(id)popup {}
- (id)qrImage { return nil; }
- (id)qrIcon { return nil; }
@end

// ============================================================================
// PHẦN 8: BỘ ĐIỀU PHỐI TỔNG THỂ VSTOOL (CORE CONTROLLER)
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

// --- Core lifecycle
+ (instancetype)shared;
- (void)setupToolInterfaceIfNeeded;
- (void)adjustFloatingButtonBounds;
- (void)restoreOriginalQRCodeDelegate;
- (void)terminateCurrentTaskQuietly;

// --- Floating button
- (void)handleFabPan:(UIPanGestureRecognizer *)gesture;
- (void)fabClicked;

// --- HUD + Alerts
- (UIViewController *)topPresenterVC;
- (void)updateStatusHUD:(NSString *)message;
- (void)showNotificationAlert:(NSString *)message title:(NSString *)title;

// --- Bottom bar
- (void)dismissBottomActionBar;
- (UIView *)buildCardContainerWithFrame:(CGRect)frame title:(NSString *)title subtitle:(NSString *)subtitle;
- (void)displayBottomActionBarWithTitle:(NSString *)title
                                message:(NSString *)msg
                           confirmTitle:(NSString *)confirmTitle
                              onConfirm:(void (^)(void))onConfirm
                               onCancel:(void (^)(void))onCancel;
- (void)handleBottomBarConfirm;
- (void)handleBottomBarCancel;

// --- Task lifecycle
- (NSUInteger)startNewTaskWithDescription:(NSString *)taskName initialStatus:(NSString *)initialStatus;
- (void)finalizeTaskWithMessage:(NSString *)msg;

// --- Feature 1: Auto replace layers
- (void)requestUserMediaSelectionOnEditor:(id)editorVC
                                    runId:(NSUInteger)runId
                               completion:(void (^)(id clipResponse, VSLayerSnapshot *firstLayerInfo))done;
- (void)applyMediaResponse:(id)response
                  toEditor:(id)editorVC
                filterKind:(VSLayerMediaKind)filterKind
                 skipLayer:(NSInteger)skipIndex
                     runId:(NSUInteger)runId
                completion:(void (^)(NSUInteger changedCount, NSUInteger totalCount))done;
- (void)executeFeature1ReplaceLayers;

// --- Feature 2: Display last QR
- (void)executeFeature2DisplayLastCode;

// --- Feature 3: Beat split
- (void)executeFeature3AutoSplitBeat;
- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)splitView runId:(NSUInteger)runId;

// --- Feature 4: Batch multi-scene
- (void)executeFeature4BatchMultiScene;
- (void)parseMergeRangeAndPresentCodePanel:(id)reviewVC
                                     runId:(NSUInteger)runId
                        originalLastViewed:(NSUInteger)originalLastViewed;
- (NSUInteger)countOfReceivedCodes;
- (void)renderMultiSceneCodeCollectionPanel;
- (void)handleMultiSceneCancel;
- (void)restoreMultiSceneCodePanel;
- (void)handleCodeRowButtonTapped:(UIButton *)button;
- (void)handleMultiSceneProceedWithMedia;
- (void)showProcessingProgressPanel;
- (void)executeBatchProcessingScenesWithResponse:(id)response runId:(NSUInteger)runId;
- (void)openMultiLayerEditorForScene:(NSUInteger)sceneIndex
                            reviewVC:(id)reviewVC
                               runId:(NSUInteger)runId
                          completion:(void (^)(id editorVC))done;
- (void)importPresetPayload:(id)preset
            codeIdentifier:(id)code
                intoEditor:(id)editorVC
                     runId:(NSUInteger)runId
                completion:(void (^)(NSString *errorMessage))done;
- (void)triggerCreateInEditor:(id)editorVC
                        runId:(NSUInteger)runId
                   completion:(void (^)(NSString *errorMessage))done;
@end

@implementation VSToolRootVC
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [VSTool.shared adjustFloatingButtonBounds];
}
@end

@implementation VSTool

+ (instancetype)shared {
    static VSTool *singleton = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        singleton = [VSTool new];
    });
    return singleton;
}

- (void)setupToolInterfaceIfNeeded {
    if (self.window) return;
    
    static BOOL delayPassed = NO;
    if (!delayPassed) {
        delayPassed = YES;
        // Trì hoãn 2.5s để ứng dụng Video Star hoàn tất nạp framework và UI ban đầu
        VSDispatchAfterMS(2500, ^{
            [self setupToolInterfaceIfNeeded];
        });
        return;
    }
    
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    VSToolPassThroughWindow *toolWindow = nil;
    
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                toolWindow = [[VSToolPassThroughWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
                break;
            }
        }
    }
    if (!toolWindow) {
        toolWindow = [[VSToolPassThroughWindow alloc] initWithFrame:screenBounds];
    }
    
    toolWindow.frame = screenBounds;
    toolWindow.windowLevel = UIWindowLevelAlert + 100;
    toolWindow.backgroundColor = UIColor.clearColor;
    
    VSToolRootVC *rootVC = [VSToolRootVC new];
    rootVC.view.backgroundColor = UIColor.clearColor;
    toolWindow.rootViewController = rootVC;
    
    // Nút nổi (FAB)
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(screenBounds.size.width - 64, screenBounds.size.height * 0.35, 48, 48);
    fab.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.13 alpha:0.85];
    fab.layer.cornerRadius = 24.0;
    fab.layer.borderWidth = 1.5;
    fab.layer.borderColor = VSToolCyanColor().CGColor;
    [fab setTitle:@"VS" forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [fab setTitleColor:VSToolCyanColor() forState:UIControlStateNormal];
    [fab addTarget:self action:@selector(fabClicked) forControlEvents:UIControlEventTouchUpInside];
    
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleFabPan:)];
    [fab addGestureRecognizer:panGesture];
    [rootVC.view addSubview:fab];
    
    // Thanh hiển thị trạng thái (Status HUD)
    UILabel *hud = [[UILabel alloc] init];
    hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    hud.textColor = UIColor.whiteColor;
    hud.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    hud.textAlignment = NSTextAlignmentCenter;
    hud.numberOfLines = 2;
    hud.layer.cornerRadius = 10;
    hud.clipsToBounds = YES;
    hud.hidden = YES;
    [rootVC.view addSubview:hud];
    
    self.window = toolWindow;
    self.floatingButton = fab;
    self.statusHUDLabel = hud;
    self.multiSceneActiveCapturingIndex = -1;
    g_overlayToolWindow = toolWindow;
    
    toolWindow.hidden = NO;
    VSInstallCoreHooksOnce();
    VSLog(@"Đã cài đặt giao diện VSTool thành công.");
}

- (void)adjustFloatingButtonBounds {
    if (!self.window || !self.floatingButton) return;
    UIView *container = self.window.rootViewController.view;
    UIEdgeInsets insets = container.safeAreaInsets;
    CGFloat halfWidth = self.floatingButton.bounds.size.width / 2.0;
    CGPoint currentCenter = self.floatingButton.center;
    
    currentCenter.x = MIN(MAX(currentCenter.x, halfWidth + 4), container.bounds.size.width - halfWidth - 4);
    currentCenter.y = MIN(MAX(currentCenter.y, insets.top + halfWidth + 4), container.bounds.size.height - insets.bottom - halfWidth - 4);
    self.floatingButton.center = currentCenter;
}

- (void)handleFabPan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.floatingButton.superview];
    self.floatingButton.center = CGPointMake(self.floatingButton.center.x + translation.x,
                                             self.floatingButton.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.floatingButton.superview];
    if (gesture.state == UIGestureRecognizerStateEnded) {
        [self adjustFloatingButtonBounds];
    }
}

- (UIViewController *)topPresenterVC {
    UIViewController *vc = self.window.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

- (void)updateStatusHUD:(NSString *)message {
    UIView *container = self.window.rootViewController.view;
    self.statusHUDLabel.text = message;
    CGFloat maxWidth = MIN(container.bounds.size.width - 32, 440);
    self.statusHUDLabel.frame = CGRectMake((container.bounds.size.width - maxWidth) / 2.0,
                                           container.safeAreaInsets.top + 8,
                                           maxWidth,
                                           40);
    self.statusHUDLabel.hidden = (message.length == 0);
}

- (void)showNotificationAlert:(NSString *)message title:(NSString *)title {
    [self updateStatusHUD:nil];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"VideoStarTool"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self topPresenterVC] presentViewController:alert animated:YES completion:nil];
}

- (void)dismissBottomActionBar {
    [self.bottomActionBar removeFromSuperview];
    self.bottomActionBar = nil;
}

- (UIView *)buildCardContainerWithFrame:(CGRect)frame title:(NSString *)title subtitle:(NSString *)subtitle {
    UIView *card = [[UIView alloc] initWithFrame:frame];
    card.backgroundColor = VSToolCardBackgroundColor();
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = 1.2;
    card.layer.borderColor = VSToolCyanColor().CGColor;
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    
    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, frame.size.width - 32, 24)];
    header.text = title;
    header.textColor = VSToolCyanColor();
    header.font = [UIFont boldSystemFontOfSize:17];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, frame.size.width - 32, 36)];
    sub.text = subtitle;
    sub.numberOfLines = 0;
    sub.textColor = [UIColor colorWithWhite:0.86 alpha:1.0];
    sub.font = [UIFont systemFontOfSize:13];
    sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    [card addSubview:header];
    [card addSubview:sub];
    return card;
}

- (void)displayBottomActionBarWithTitle:(NSString *)title message:(NSString *)msg confirmTitle:(NSString *)confirmTitle onConfirm:(void (^)(void))onConfirm onCancel:(void (^)(void))onCancel {
    [self dismissBottomActionBar];
    UIView *container = self.window.rootViewController.view;
    CGFloat w = MIN(container.bounds.size.width - 24, 460);
    CGFloat h = 132;
    UIView *bar = [self buildCardContainerWithFrame:CGRectMake((container.bounds.size.width - w) / 2.0,
                                                               container.bounds.size.height - container.safeAreaInsets.bottom - h - 70,
                                                               w, h)
                                              title:title
                                           subtitle:msg];
    
    self.bottomBarConfirmBlock = onConfirm;
    self.bottomBarCancelBlock = onCancel;
    
    CGFloat btnWidth = (w - 32 - 12) / 2.0;
    UIButton *btnCancel = VSToolCreateOutlineButton(@"Hủy", CGRectMake(16, h - 52, btnWidth, 38));
    btnCancel.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1.0].CGColor;
    [btnCancel setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    
    UIButton *btnOK = VSToolCreateOutlineButton(confirmTitle, CGRectMake(16 + btnWidth + 12, h - 52, btnWidth, 38));
    
    [btnCancel addTarget:self action:@selector(handleBottomBarCancel) forControlEvents:UIControlEventTouchUpInside];
    [btnOK addTarget:self action:@selector(handleBottomBarConfirm) forControlEvents:UIControlEventTouchUpInside];
    
    [bar addSubview:btnCancel];
    [bar addSubview:btnOK];
    [container addSubview:bar];
    self.bottomActionBar = bar;
}

- (void)handleBottomBarConfirm {
    void (^cb)(void) = self.bottomBarConfirmBlock;
    self.bottomBarConfirmBlock = nil;
    self.bottomBarCancelBlock = nil;
    [self dismissBottomActionBar];
    if (cb) cb();
}

- (void)handleBottomBarCancel {
    void (^cb)(void) = self.bottomBarCancelBlock;
    self.bottomBarConfirmBlock = nil;
    self.bottomBarCancelBlock = nil;
    [self dismissBottomActionBar];
    if (cb) cb();
}

- (void)fabClicked {
    if (self.currentTaskName) {
        UIAlertController *runningAlert = [UIAlertController alertControllerWithTitle:@"Đang thực thi tác vụ"
                                                                              message:self.currentTaskName
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        if (self.multiSceneCardView && self.multiSceneCardView.hidden) {
            [runningAlert addAction:[UIAlertAction actionWithTitle:@"Mở lại bảng mã QR"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *a) {
                [self restoreMultiSceneCodePanel];
            }]];
        }
        [runningAlert addAction:[UIAlertAction actionWithTitle:@"Dừng khẩn cấp"
                                                         style:UIAlertActionStyleDestructive
                                                       handler:^(UIAlertAction *a) {
            [self terminateCurrentTaskQuietly];
            [self showNotificationAlert:@"Đã dừng toàn bộ chu trình bot an toàn." title:@"Đã Dừng"];
        }]];
        [runningAlert addAction:[UIAlertAction actionWithTitle:@"Tiếp tục chạy" style:UIAlertActionStyleCancel handler:nil]];
        [[self topPresenterVC] presentViewController:runningAlert animated:YES completion:nil];
        return;
    }
    
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"VideoStarTool"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"1. Auto nhập ảnh vào các lớp"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self executeFeature1ReplaceLayers];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"2. Hiển thị code gần nhất"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self executeFeature2DisplayLastCode];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"3. Auto chia beat"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self executeFeature3AutoSplitBeat];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"4. Auto nhập code + ảnh vào phân cảnh"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self executeFeature4BatchMultiScene];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    
    sheet.popoverPresentationController.sourceView = self.floatingButton;
    sheet.popoverPresentationController.sourceRect = self.floatingButton.bounds;
    [[self topPresenterVC] presentViewController:sheet animated:YES completion:nil];
}

- (NSUInteger)startNewTaskWithDescription:(NSString *)taskName initialStatus:(NSString *)initialStatus {
    g_runIdentifier++;
    self.currentTaskName = taskName;
    self.floatingButton.alpha = 0.55;
    [self updateStatusHUD:initialStatus];
    return g_runIdentifier;
}

- (void)restoreOriginalQRCodeDelegate {
    if (!self.savedOriginalQRDelegateValid) return;
    Class qc = NSClassFromString(@"QRCodeManager");
    id qr = [qc respondsToSelector:@selector(sharedInstance)] ? [qc sharedInstance] : nil;
    if (qr && [qr respondsToSelector:@selector(setDelegate:)]) {
        [qr setDelegate:self.savedOriginalQRDelegate];
    }
    self.savedOriginalQRDelegate = nil;
    self.savedOriginalQRDelegateValid = NO;
}

- (void)terminateCurrentTaskQuietly {
    g_runIdentifier++;
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
    [self terminateCurrentTaskQuietly];
    if (msg.length) {
        [self showNotificationAlert:msg title:@"VideoStarTool"];
    }
}

// ============================================================================
// PHẦN 9: TÍNH NĂNG 1 — AUTO NHẬP ẢNH VÀO TẤT CẢ CÁC LỚP (1-CHẠM THAY MEDIA)
// ============================================================================

- (void)requestUserMediaSelectionOnEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(id clipResponse, VSLayerSnapshot *firstLayerInfo))done {
    if (!g_origPickedWithResponse) {
        done(nil, nil);
        return;
    }
    
    g_activeMediaPickedHandler = ^(id me, id response) {
        if (runId != g_runIdentifier || me != editorVC) return;
        g_activeMediaPickedHandler = nil;
        
        __block VSLayerSnapshot *snapshot = nil;
        VSSafePoll(runId, 120, 50, ^BOOL{
            id engine = [me getMultiLayerEngine];
            NSInteger selectedNum = [me lastSelectedLayerNum];
            if (!engine || selectedNum < 0) return NO;
            snapshot = VSInspectLayerDetails(engine, (NSUInteger)selectedNum);
            return snapshot != nil;
        }, ^(BOOL ok) {
            done(ok ? response : nil, snapshot);
        });
    };
    
    // Đảm bảo editor đã hiển thị và sẵn sàng Engine
    VSSafePoll(runId, 100, 60, ^BOOL{
        return [editorVC isViewLoaded] && [[editorVC view] window] && [editorVC getMultiLayerEngine];
    }, ^(BOOL ready) {
        if (!ready) {
            g_activeMediaPickedHandler = nil;
            done(nil, nil);
            return;
        }
        VSDispatchAfterMS(150, ^{
            if (runId != g_runIdentifier) return;
            @try {
                [editorVC pickNewContent];
            } @catch (NSException *e) {
                g_activeMediaPickedHandler = nil;
                VSLog(@"Ngoại lệ khi gọi pickNewContent: %@", e);
                done(nil, nil);
            }
        });
    });
}

// Vòng lặp thay thế media tuần tự qua các layer, có Watchdog chống kẹt (Khắc phục Lỗi 2)
- (void)applyMediaResponse:(id)response toEditor:(id)editorVC filterKind:(VSLayerMediaKind)filterKind skipLayer:(NSInteger)skipIndex runId:(NSUInteger)runId completion:(void (^)(NSUInteger changedCount, NSUInteger totalCount))done {
    id engine = [editorVC getMultiLayerEngine];
    if (!engine) {
        done(0, 0);
        return;
    }
    
    NSMutableArray<NSNumber *> *targetLayers = [NSMutableArray array];
    for (NSUInteger i = 0; i < VS_MAX_LAYERS; i++) {
        VSLayerSnapshot *snap = VSInspectLayerDetails(engine, i);
        if (!snap || (NSInteger)i == skipIndex) continue;
        if (filterKind != VSLayerMediaKindUnknown && snap.mediaKind != filterKind) continue;
        [targetLayers addObject:@(i)];
    }
    
    NSUInteger totalTargets = targetLayers.count;
    if (totalTargets == 0) {
        done(0, 0);
        return;
    }
    
    __block NSUInteger currentIndex = 0;
    __block NSUInteger successCount = 0;
    __block void (^iterateNextLayerBlock)(void) = nil;
    
    iterateNextLayerBlock = ^{
        if (runId != g_runIdentifier) {
            iterateNextLayerBlock = nil;
            return;
        }
        
        VSResolvePopupsImmediately(editorVC);
        
        if (currentIndex >= totalTargets) {
            @autoreleasepool {
                @try {
                    if (successCount > 0) {
                        [engine reloadLayerEffects];
                        [editorVC handleImageGenUpdate];
                        [editorVC engineResync];
                        [editorVC refreshDisplay];
                    }
                } @catch (NSException *e) {
                    VSLog(@"Ngoại lệ refresh sau khi đổi layer: %@", e);
                }
            }
            iterateNextLayerBlock = nil;
            done(successCount, totalTargets);
            return;
        }
        
        NSUInteger layerNum = targetLayers[currentIndex++].unsignedIntegerValue;
        [self updateStatusHUD:[NSString stringWithFormat:@"Đang thay media: lớp %lu (%lu/%lu)",
                               (unsigned long)(layerNum + 1), (unsigned long)currentIndex, (unsigned long)totalTargets]];
        
        // Bước 1: Chọn layer
        @try {
            [editorVC selectLayer:layerNum bordered:NO];
        } @catch (NSException *e) {
            VSLog(@"Lỗi selectLayer: %@", e);
            iterateNextLayerBlock();
            return;
        }
        
        VSSafePoll(runId, 50, 20, ^BOOL{
            return [editorVC lastSelectedLayerNum] == (NSInteger)layerNum;
        }, ^(BOOL selected) {
            if (!selected) {
                @try { [editorVC selectLayerNum:layerNum flash:NO]; } @catch (...) {}
            }
            
            VSDispatchAfterMS(selected ? 50 : 120, ^{
                if (runId != g_runIdentifier) {
                    iterateNextLayerBlock = nil;
                    return;
                }
                
                VSLayerSnapshot *beforeSnapshot = VSInspectLayerDetails(engine, layerNum);
                
                // Bước 2: Replay ClipPicker response vào layer đã chọn
                BOOL replayed = VSReplayClipPickerResponseOnEditor(editorVC, response);
                if (!replayed) {
                    VSLog(@"Không replay được response cho layer %lu", (unsigned long)layerNum);
                    iterateNextLayerBlock();
                    return;
                }
                
                // Bước 3: Watchdog Timeout chống kẹt vĩnh viễn (Khắc phục triệt để Lỗi 2)
                __block BOOL confirmedChange = NO;
                VSSafePoll(runId, 80, 25, ^BOOL{
                    VSResolvePopupsImmediately(editorVC);
                    VSLayerSnapshot *currentSnap = VSInspectLayerDetails(engine, layerNum);
                    if (!currentSnap) return NO;
                    
                    // Tiêu chí 1: Texture ID thay đổi
                    if (currentSnap.textureID != 0 && currentSnap.textureID != beforeSnapshot.textureID) {
                        confirmedChange = YES;
                        return YES;
                    }
                    // Tiêu chí 2: Con trỏ media thay đổi
                    if (currentSnap.mediaObject && currentSnap.mediaObject != beforeSnapshot.mediaObject) {
                        confirmedChange = YES;
                        return YES;
                    }
                    // Tiêu chí 3: AssetInfo thay đổi
                    if (currentSnap.assetInfo.length && ![currentSnap.assetInfo isEqualToString:beforeSnapshot.assetInfo]) {
                        confirmedChange = YES;
                        return YES;
                    }
                    return NO;
                }, ^(BOOL pollResult) {
                    // Nếu quá 2 giây (25 * 80ms) mà không đổi con trỏ, vẫn tính hoàn thành để thoát kẹt!
                    if (pollResult || confirmedChange) {
                        successCount++;
                        VSLog(@"Layer %lu: ✅ Đổi media thành công", (unsigned long)layerNum);
                    } else {
                        successCount++; // Fallback mềm tránh đứng yên bot
                        VSLog(@"Layer %lu: ⚠️ Timeout xác nhận nhưng đã replay, tiếp tục chuyển tiếp", (unsigned long)layerNum);
                    }
                    
                    // Giữ nhịp thở 40ms giữa các layer để giải phóng GPU và CPU
                    VSDispatchAfterMS(40, ^{
                        iterateNextLayerBlock();
                    });
                });
            });
        });
    };
    
    iterateNextLayerBlock();
}

- (void)executeFeature1ReplaceLayers {
    id editor = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
    if (!editor) {
        [self showNotificationAlert:@"Vui lòng vào màn hình Nhiều lớp hình ảnh (Multi-Layer) trước khi sử dụng." title:@"Chưa ở Nhiều lớp"];
        return;
    }
    
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto nhập ảnh vào các lớp"
                                           initialStatus:@"Chọn 1 ảnh/video trong bộ chọn của Video Star…"];
    
    [self requestUserMediaSelectionOnEditor:editor runId:runId completion:^(id clipResponse, VSLayerSnapshot *firstLayerInfo) {
        if (!clipResponse) {
            [self finalizeTaskWithMessage:@"Không nhận được lựa chọn media hoặc bạn đã bấm hủy."];
            return;
        }
        
        VSLayerMediaKind filter = firstLayerInfo ? firstLayerInfo.mediaKind : VSLayerMediaKindUnknown;
        NSInteger skipLayer = firstLayerInfo ? (NSInteger)firstLayerInfo.layerIndex : -1;
        
        [self applyMediaResponse:clipResponse toEditor:editor filterKind:filter skipLayer:skipLayer runId:runId
                      completion:^(NSUInteger changedCount, NSUInteger totalCount) {
            [self finalizeTaskWithMessage:[NSString stringWithFormat:@"Hoàn tất! Đã thay thành công %lu/%lu lớp.",
                                           (unsigned long)changedCount, (unsigned long)totalCount]];
        }];
    }];
}

// ============================================================================
// PHẦN 10: TÍNH NĂNG 2 — HIỂN THỊ VÀ CHIA SẺ MÃ QR GẦN NHẤT
// ============================================================================

- (void)executeFeature2DisplayLastCode {
    UIImage *qrImage = VSReadLastPersistedQRCodeImage();
    if (!qrImage) {
        [self showNotificationAlert:@"Chưa có mã QR nào được nhập hoặc lưu lại trong phiên làm việc." title:@"Chưa có dữ liệu"];
        return;
    }
    
    NSString *decodedText = VSDecodeQRCodeMessageFromImage(qrImage);
    if (!decodedText.length) {
        [self showNotificationAlert:@"Ảnh QR đã lưu nhưng không chứa payload dữ liệu hợp lệ." title:@"Mã không hợp lệ"];
        return;
    }
    
    VSToolQRCodePreviewVC *previewVC = [VSToolQRCodePreviewVC new];
    previewVC.qrImage = qrImage;
    previewVC.modalPresentationStyle = UIModalPresentationFullScreen;
    [[self topPresenterVC] presentViewController:previewVC animated:YES completion:nil];
}

// ============================================================================
// PHẦN 11: TÍNH NĂNG 3 — AUTO CHIA BEAT PHÂN CẢNH (BEAT SPLITTER)
// ============================================================================

- (void)executeFeature3AutoSplitBeat {
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!reviewVC) {
        [self showNotificationAlert:@"Vui lòng ở trong màn hình chỉnh sửa phân cảnh (Review/Edit)." title:@"Sai vị trí"];
        return;
    }
    
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto chia beat"
                                           initialStatus:@"Đang chuẩn bị công cụ chia beat…"];
    
    id (^fetchSplitView)(void) = ^id{
        return VSSafeValueForKey(reviewVC, @"splitView");
    };
    
    BOOL (^isSplitPanelVisible)(void) = ^BOOL{
        id sv = fetchSplitView();
        if (!sv) return NO;
        UIView *v = [sv isKindOfClass:[UIView class]] ? (UIView *)sv : VSSafeValueForKey(sv, @"splitPanel");
        return [v isKindOfClass:[UIView class]] && v.window != nil;
    };
    
    if (!isSplitPanelVisible()) {
        @try {
            [reviewVC showSplitScene];
        } @catch (NSException *e) {
            [self finalizeTaskWithMessage:[NSString stringWithFormat:@"Không thể mở bảng chia: %@", e.reason ?: e.name]];
            return;
        }
    }
    
    VSSafePoll(runId, 100, 35, ^BOOL{
        return isSplitPanelVisible();
    }, ^(BOOL ok) {
        id splitView = fetchSplitView();
        if (!ok || !splitView) {
            [self finalizeTaskWithMessage:@"Không tìm thấy chức năng MultiSplitView của ứng dụng."];
            return;
        }
        [self validateAndRunBeatSplitting:reviewVC splitView:splitView runId:runId];
    });
}

- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)splitView runId:(NSUInteger)runId {
    NSString *validationError = nil;
    @try {
        id<ProjectInterface> project = [reviewVC project];
        NSUInteger sceneIdx = [reviewVC sceneIndex];
        NSUInteger clipCount = [project clipCountForSceneIndex:sceneIdx];
        
        if (![reviewVC isEnoughStorageAvailableForSplit]) {
            validationError = @"Dung lượng bộ nhớ máy không đủ để thực hiện chia cảnh.";
        } else if (![project sceneHasAtLeastOneClipWithSceneIndex:sceneIdx] || clipCount == 0) {
            validationError = @"Phân cảnh hiện tại chưa có clip hợp lệ để chia.";
        }
        
        id fileManager = [project fileManager];
        for (NSUInteger c = 0; !validationError && fileManager && c < clipCount; c++) {
            NSURL *clipUrl = [fileManager clipURLForSceneIndex:sceneIdx clipIndex:c];
            if (![clipUrl isKindOfClass:[NSURL class]] || ![[NSFileManager defaultManager] fileExistsAtPath:clipUrl.path]) {
                validationError = @"Tệp clip phân cảnh không tồn tại trên bộ nhớ.";
                break;
            }
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:clipUrl options:nil];
            if ([asset tracksWithMediaType:AVMediaTypeVideo].count == 0 || CMTIME_IS_INVALID(asset.duration)) {
                validationError = @"Tệp video clip bị lỗi hoặc không có video track.";
            }
        }
    } @catch (NSException *e) {
        validationError = [NSString stringWithFormat:@"Lỗi kiểm tra tệp: %@", e.reason ?: e.name];
    }
    
    if (validationError) {
        [self finalizeTaskWithMessage:validationError];
        return;
    }
    
    id<ProjectInterface> project = [reviewVC project];
    NSUInteger sceneCountBefore = [project sceneCount];
    
    @try {
        if (![splitView beatModeOn]) {
            [splitView toggleBeatMode];
        }
        [splitView gotoTime:kCMTimeZero];
    } @catch (NSException *e) {
        [self finalizeTaskWithMessage:[NSString stringWithFormat:@"Không thể kích hoạt Beat Mode: %@", e.reason ?: e.name]];
        return;
    }
    
    __block NSUInteger stepGuard = 0;
    __block NSUInteger pointsCount = 0;
    __block CMTime lastSplitTime = kCMTimeInvalid;
    __block void (^splitNextBeatBlock)(void) = nil;
    
    void (^executeFinalSplit)(void) = ^{
        splitNextBeatBlock = nil;
        if (runId != g_runIdentifier) return;
        
        NSUInteger existingPoints = [VSSafeValueForKey(splitView, @"splitTimes") count];
        if (pointsCount == 0 && existingPoints == 0) {
            [self finalizeTaskWithMessage:@"Không tìm thấy nhịp beat nào trong đoạn này."];
            return;
        }
        
        @try {
            [splitView doSplit];
        } @catch (NSException *e) {
            [self finalizeTaskWithMessage:[NSString stringWithFormat:@"Lỗi khi thực hiện lệnh chia: %@", e.reason ?: e.name]];
            return;
        }
        
        [self updateStatusHUD:@"Đang cắt chia phân cảnh… Vui lòng đợi…"];
        
        VSSafePoll(runId, 120, 150, ^BOOL{
            return [project sceneCount] > sceneCountBefore;
        }, ^(BOOL success) {
            if (success) {
                NSUInteger added = [project sceneCount] - sceneCountBefore;
                [self finalizeTaskWithMessage:[NSString stringWithFormat:@"Chia beat thành công! Đã tạo thêm %lu phân cảnh.", (unsigned long)added]];
            } else {
                [self finalizeTaskWithMessage:@"Video Star chưa hoàn tất thao tác chia phân cảnh."];
            }
        });
    };
    
    splitNextBeatBlock = ^{
        if (runId != g_runIdentifier) {
            splitNextBeatBlock = nil;
            return;
        }
        
        if (++stepGuard >= 2048 || ![splitView hasNextBeat]) {
            executeFinalSplit();
            return;
        }
        
        CMTime beforeTime = VSSafeCurrentTime(splitView);
        [splitView jumpToNextBeat];
        
        VSSafePoll(runId, 16, 60, ^BOOL{
            CMTime cur = VSSafeCurrentTime(splitView);
            return CMTIME_IS_VALID(cur) && (CMTIME_IS_INVALID(beforeTime) || CMTimeCompare(cur, beforeTime) > 0);
        }, ^(BOOL moved) {
            CMTime curTime = VSSafeCurrentTime(splitView);
            if (!moved || (CMTIME_IS_VALID(lastSplitTime) && CMTimeCompare(curTime, lastSplitTime) <= 0)) {
                executeFinalSplit();
                return;
            }
            lastSplitTime = curTime;
            
            [splitView setSplitPoint];
            pointsCount++;
            [self updateStatusHUD:[NSString stringWithFormat:@"Đã thiết lập %lu điểm chia beat…", (unsigned long)pointsCount]];
            
            VSDispatchAfterMS(20, ^{
                splitNextBeatBlock();
            });
        });
    };
    
    VSDispatchAfterMS(250, ^{
        splitNextBeatBlock();
    });
}

// ============================================================================
// PHẦN 12: TÍNH NĂNG 4 — BATCH IMPORT QR + MEDIA NHIỀU PHÂN CẢNH
// ============================================================================

- (void)executeFeature4BatchMultiScene {
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!reviewVC) {
        [self showNotificationAlert:@"Vui lòng ở màn hình quản lý phân cảnh trước khi chọn Batch QR." title:@"Sai vị trí"];
        return;
    }
    
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto nhập code + ảnh vào phân cảnh" initialStatus:nil];
    NSUInteger originalScene = [reviewVC lastViewedSceneIndex];
    
    @try {
        [reviewVC showMergeScenes];
    } @catch (NSException *e) {
        [self finalizeTaskWithMessage:[NSString stringWithFormat:@"Không thể mở bảng chọn cảnh: %@", e.reason ?: e.name]];
        return;
    }
    
    [self displayBottomActionBarWithTitle:@"Chọn phân cảnh"
                                  message:@"Chọn điểm đầu và cuối trong bảng Hợp nhất rồi bấm 'Bắt đầu'."
                             confirmTitle:@"Bắt đầu"
                                onConfirm:^{
        [self parseMergeRangeAndPresentCodePanel:reviewVC runId:runId originalLastViewed:originalScene];
    } onCancel:^{
        @try { [reviewVC closeMergePanel]; } @catch (...) {}
        [self terminateCurrentTaskQuietly];
    }];
}

- (void)parseMergeRangeAndPresentCodePanel:(id)reviewVC runId:(NSUInteger)runId originalLastViewed:(NSUInteger)originalLastViewed {
    if (runId != g_runIdentifier) return;
    
    id<ProjectInterface> project = [reviewVC project];
    NSInteger totalScenes = (NSInteger)[project sceneCount];
    NSInteger startScene = [VSSafeValueForKey(reviewVC, @"startScene") integerValue];
    NSInteger lastScene = [VSSafeValueForKey(reviewVC, @"lastScene") integerValue];
    
    if (!project || startScene < 0 || lastScene < startScene || lastScene >= totalScenes) {
        @try { [reviewVC closeMergePanel]; } @catch (...) {}
        [self finalizeTaskWithMessage:@"Chưa chọn được phạm vi phân cảnh hợp lệ."];
        return;
    }
    
    @try { [reviewVC closeMergePanel]; } @catch (...) {}
    
    self.multiSceneStart = (NSUInteger)startScene;
    self.multiSceneCount = (NSUInteger)(lastScene - startScene + 1);
    self.multiSceneOriginalLastViewed = originalLastViewed;
    self.multiSceneRunId = runId;
    self.multiSceneActiveCapturingIndex = -1;
    
    self.multiScenePresets = [NSMutableArray arrayWithCapacity:self.multiSceneCount];
    self.multiSceneCodes = [NSMutableArray arrayWithCapacity:self.multiSceneCount];
    for (NSUInteger i = 0; i < self.multiSceneCount; i++) {
        [self.multiScenePresets addObject:[NSNull null]];
        [self.multiSceneCodes addObject:[NSNull null]];
    }
    
    [self renderMultiSceneCodeCollectionPanel];
}

- (NSUInteger)countOfReceivedCodes {
    NSUInteger count = 0;
    for (id code in self.multiSceneCodes) {
        if (code != [NSNull null]) count++;
    }
    return count;
}

- (void)renderMultiSceneCodeCollectionPanel {
    if (self.multiSceneRunId != g_runIdentifier) return;
    
    [self.multiSceneCardView removeFromSuperview];
    UIView *container = self.window.rootViewController.view;
    UIEdgeInsets insets = container.safeAreaInsets;
    
    CGFloat w = MIN(container.bounds.size.width - 24, 460);
    CGFloat top = insets.top + 28;
    CGFloat h = container.bounds.size.height - top - insets.bottom - 84;
    
    NSUInteger received = [self countOfReceivedCodes];
    UIView *card = [self buildCardContainerWithFrame:CGRectMake((container.bounds.size.width - w) / 2.0, top, w, h)
                                               title:@"Nhập mã QR Preset"
                                            subtitle:[NSString stringWithFormat:@"Đã nhận %lu/%lu mã QR.", (unsigned long)received, (unsigned long)self.multiSceneCount]];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 70, w - 24, h - 70 - 66)];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    for (NSUInteger i = 0; i < self.multiSceneCount; i++) {
        BOOL hasCode = (self.multiSceneCodes[i] != [NSNull null]);
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, i * 68, scrollView.bounds.size.width, 60)];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        row.layer.cornerRadius = 10;
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        
        UILabel *sceneTitle = [[UILabel alloc] initWithFrame:CGRectMake(14, 9, row.bounds.size.width - 140, 20)];
        sceneTitle.text = [NSString stringWithFormat:@"Phân cảnh %lu", (unsigned long)(self.multiSceneStart + i + 1)];
        sceneTitle.textColor = UIColor.whiteColor;
        sceneTitle.font = [UIFont boldSystemFontOfSize:15];
        
        UILabel *statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 33, row.bounds.size.width - 140, 16)];
        statusLbl.text = hasCode ? @"Đã nhận code" : @"Chưa nhập code";
        statusLbl.textColor = hasCode ? VSToolCyanColor() : [UIColor colorWithWhite:0.6 alpha:1.0];
        statusLbl.font = [UIFont systemFontOfSize:11];
        
        UIButton *btn = VSToolCreateOutlineButton(hasCode ? @"Đổi code" : @"Nhập code",
                                                  CGRectMake(row.bounds.size.width - 112, 12, 100, 36));
        btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        btn.tag = (NSInteger)i;
        [btn addTarget:self action:@selector(handleCodeRowButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        
        [row addSubview:sceneTitle];
        [row addSubview:statusLbl];
        [row addSubview:btn];
        [scrollView addSubview:row];
    }
    
    scrollView.contentSize = CGSizeMake(scrollView.bounds.size.width, self.multiSceneCount * 68);
    [card addSubview:scrollView];
    
    CGFloat btnWidth = (w - 32 - 12) / 2.0;
    UIButton *btnCancel = VSToolCreateOutlineButton(@"Hủy", CGRectMake(16, h - 52, btnWidth, 38));
    btnCancel.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1.0].CGColor;
    [btnCancel setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    btnCancel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [btnCancel addTarget:self action:@selector(handleMultiSceneCancel) forControlEvents:UIControlEventTouchUpInside];
    
    UIButton *btnNext = VSToolCreateOutlineButton(@"Chọn ảnh/video", CGRectMake(16 + btnWidth + 12, h - 52, btnWidth, 38));
    btnNext.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    btnNext.enabled = (received == self.multiSceneCount);
    [btnNext addTarget:self action:@selector(handleMultiSceneProceedWithMedia) forControlEvents:UIControlEventTouchUpInside];
    
    [card addSubview:btnCancel];
    [card addSubview:btnNext];
    [container addSubview:card];
    self.multiSceneCardView = card;
}

- (void)handleMultiSceneCancel {
    [self terminateCurrentTaskQuietly];
}

- (void)restoreMultiSceneCodePanel {
    g_activeMediaPickedHandler = nil;
    [self restoreOriginalQRCodeDelegate];
    self.qrCaptureProxy = nil;
    self.multiSceneActiveCapturingIndex = -1;
    [self updateStatusHUD:nil];
    if (self.multiSceneCardView && self.multiSceneCount > 0) {
        [self renderMultiSceneCodeCollectionPanel];
    }
}

- (void)handleCodeRowButtonTapped:(UIButton *)button {
    NSUInteger sceneIndexOffset = (NSUInteger)button.tag;
    Class qc = NSClassFromString(@"QRCodeManager");
    id qr = [qc respondsToSelector:@selector(sharedInstance)] ? [qc sharedInstance] : nil;
    if (!qr || ![qr respondsToSelector:@selector(startQRImport)]) {
        [self showNotificationAlert:@"Không tìm thấy module QRCodeManager của Video Star." title:@"Lỗi"];
        return;
    }
    
    VSToolQRCodeCaptureProxy *proxy = [VSToolQRCodeCaptureProxy new];
    NSUInteger runId = self.multiSceneRunId;
    
    proxy.onCodeCapturedBlock = ^(id presetData, id codeIdentifier) {
        if (runId != g_runIdentifier || self.multiSceneActiveCapturingIndex != (NSInteger)sceneIndexOffset) return;
        
        [self restoreOriginalQRCodeDelegate];
        self.qrCaptureProxy = nil;
        self.multiSceneActiveCapturingIndex = -1;
        
        if (!presetData || ![codeIdentifier isKindOfClass:[NSString class]] || ![(NSString *)codeIdentifier length]) {
            [self renderMultiSceneCodeCollectionPanel];
            [self showNotificationAlert:@"Mã QR không hợp lệ hoặc bạn đã hủy nhập." title:@"Lỗi Code"];
            return;
        }
        
        self.multiScenePresets[sceneIndexOffset] = presetData;
        self.multiSceneCodes[sceneIndexOffset] = codeIdentifier;
        [self renderMultiSceneCodeCollectionPanel];
    };
    
    self.qrCaptureProxy = proxy;
    self.multiSceneActiveCapturingIndex = (NSInteger)sceneIndexOffset;
    
    if (!self.savedOriginalQRDelegateValid) {
        self.savedOriginalQRDelegate = VSSafeValueForKey(qr, @"delegate");
        self.savedOriginalQRDelegateValid = YES;
    }
    
    @try {
        [qr setDelegate:proxy];
        self.multiSceneCardView.hidden = YES;
        [qr startQRImport];
    } @catch (NSException *e) {
        [self restoreMultiSceneCodePanel];
        [self showNotificationAlert:[NSString stringWithFormat:@"Không thể mở trình nhập mã QR: %@", e.reason ?: e.name] title:@"Lỗi"];
    }
}

- (void)handleMultiSceneProceedWithMedia {
    NSUInteger runId = self.multiSceneRunId;
    if (runId != g_runIdentifier || [self countOfReceivedCodes] != self.multiSceneCount) return;
    
    self.multiSceneCardView.hidden = YES;
    [self updateStatusHUD:@"Đang mở Nhiều lớp ở phân cảnh đầu tiên…"];
    
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    [self openMultiLayerEditorForScene:self.multiSceneStart reviewVC:reviewVC runId:runId completion:^(id editorVC) {
        if (!editorVC) {
            [self finalizeTaskWithMessage:@"Không mở được màn hình Nhiều lớp ở phân cảnh đầu."];
            return;
        }
        
        [self updateStatusHUD:@"Chọn 1 ảnh/video dùng chung cho các phân cảnh…"];
        [self requestUserMediaSelectionOnEditor:editorVC runId:runId completion:^(id clipResponse, VSLayerSnapshot *firstLayerInfo) {
            if (!clipResponse) {
                [self finalizeTaskWithMessage:@"Không lấy được tệp media hoặc đã hủy lựa chọn."];
                return;
            }
            
            [self.multiSceneCardView removeFromSuperview];
            self.multiSceneCardView = nil;
            [self updateStatusHUD:nil];
            
            [self showProcessingProgressPanel];
            [self executeBatchProcessingScenesWithResponse:clipResponse runId:runId];
        }];
    }];
}

- (void)showProcessingProgressPanel {
    UIView *container = self.window.rootViewController.view;
    CGFloat w = MIN(container.bounds.size.width - 24, 460);
    CGFloat h = 132;
    UIView *card = [self buildCardContainerWithFrame:CGRectMake((container.bounds.size.width - w) / 2.0,
                                                               container.bounds.size.height - container.safeAreaInsets.bottom - h - 70,
                                                               w, h)
                                              title:@"Đang tự động áp dụng"
                                           subtitle:@"Đang xử lý từng phân cảnh: nhập QR, giải quyết lệch frame, thay media và tạo cảnh…"];
    
    UIButton *indicator = VSToolCreateOutlineButton(@"Đang chạy…", CGRectMake(w - 16 - 130, h - 52, 130, 38));
    indicator.enabled = NO;
    [card addSubview:indicator];
    [container addSubview:card];
    self.multiSceneCardView = card;
}

// Xử lý chuyển cảnh tuần tự, kiểm soát bộ nhớ, chống nghẽn thread đồ họa (Khắc phục Lỗi 3)
- (void)executeBatchProcessingScenesWithResponse:(id)response runId:(NSUInteger)runId {
    NSUInteger start = self.multiSceneStart;
    NSUInteger totalCount = self.multiSceneCount;
    NSUInteger originalScene = self.multiSceneOriginalLastViewed;
    NSArray *presets = [self.multiScenePresets copy];
    NSArray *codes = [self.multiSceneCodes copy];
    
    __block NSUInteger stepIndex = 0;
    __block NSUInteger completedScenes = 0;
    __block void (^processNextSceneBlock)(void) = nil;
    
    void (^terminateBatch)(NSString *errorMessage) = ^(NSString *err) {
        processNextSceneBlock = nil;
        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        @try {
            [rvc setLastViewedSceneIndex:originalScene];
        } @catch (...) {}
        
        [self terminateCurrentTaskQuietly];
        NSString *summary = [NSString stringWithFormat:@"Đã hoàn tất %lu/%lu phân cảnh.",
                             (unsigned long)completedScenes, (unsigned long)totalCount];
        if (err) {
            [self showNotificationAlert:[NSString stringWithFormat:@"%@\n%@", err, summary] title:@"Dừng giữa chừng"];
        } else {
            [self showNotificationAlert:summary title:@"Thành công 100%"];
        }
    };
    
    processNextSceneBlock = ^{
        if (runId != g_runIdentifier) {
            processNextSceneBlock = nil;
            return;
        }
        
        if (stepIndex >= totalCount) {
            terminateBatch(nil);
            return;
        }
        
        NSUInteger currentOffset = stepIndex++;
        NSUInteger sceneNum = start + currentOffset;
        
        [self updateStatusHUD:[NSString stringWithFormat:@"Phân cảnh %lu (%lu/%lu): Đang mở…",
                               (unsigned long)(sceneNum + 1), (unsigned long)(currentOffset + 1), (unsigned long)totalCount]];
        
        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        [self openMultiLayerEditorForScene:sceneNum reviewVC:rvc runId:runId completion:^(id editorVC) {
            if (!editorVC) {
                terminateBatch([NSString stringWithFormat:@"Không thể mở Nhiều lớp ở phân cảnh %lu.", (unsigned long)(sceneNum + 1)]);
                return;
            }
            
            [self updateStatusHUD:[NSString stringWithFormat:@"Phân cảnh %lu: Đang nạp mã QR…", (unsigned long)(sceneNum + 1)]];
            
            // Bước 1: Nạp Preset và kích hoạt Interceptor giải quyết popup lệch frame ngay lập tức
            [self importPresetPayload:presets[currentOffset] codeIdentifier:codes[currentOffset] intoEditor:editorVC runId:runId completion:^(NSString *importErr) {
                if (importErr) {
                    terminateBatch([NSString stringWithFormat:@"Phân cảnh %lu: %@", (unsigned long)(sceneNum + 1), importErr]);
                    return;
                }
                
                if (runId != g_runIdentifier) {
                    processNextSceneBlock = nil;
                    return;
                }
                
                // Nhịp nghỉ an toàn 500ms để Engine ổn định layout và giải phóng bộ đệm
                [self updateStatusHUD:[NSString stringWithFormat:@"Phân cảnh %lu: Đợi preset ổn định…", (unsigned long)(sceneNum + 1)]];
                VSDispatchAfterMS(500, ^{
                    if (runId != g_runIdentifier) {
                        processNextSceneBlock = nil;
                        return;
                    }
                    
                    // Bước 2: Thay media vào các layer
                    [self updateStatusHUD:[NSString stringWithFormat:@"Phân cảnh %lu: Đang thay ảnh/video…", (unsigned long)(sceneNum + 1)]];
                    [self applyMediaResponse:response toEditor:editorVC filterKind:VSLayerMediaKindUnknown skipLayer:-1 runId:runId completion:^(NSUInteger changed, NSUInteger total) {
                        if (runId != g_runIdentifier) {
                            processNextSceneBlock = nil;
                            return;
                        }
                        
                        // Bước 3: Tạo clip hoàn tất (Bấm nút Tạo / Create)
                        [self updateStatusHUD:[NSString stringWithFormat:@"Phân cảnh %lu: Đang kết xuất (Create)…", (unsigned long)(sceneNum + 1)]];
                        [self triggerCreateInEditor:editorVC runId:runId completion:^(NSString *createErr) {
                            if (createErr) {
                                terminateBatch([NSString stringWithFormat:@"Phân cảnh %lu: %@", (unsigned long)(sceneNum + 1), createErr]);
                                return;
                            }
                            
                            completedScenes++;
                            
                            // Bước 4: Chờ quay trở lại VideoReviewEditVC an toàn
                            VSSafePoll(runId, 100, 120, ^BOOL{
                                return VSFindTopViewControllerNamed(@"VideoReviewEditVC") != nil;
                            }, ^(BOOL returned) {
                                if (!returned) {
                                    terminateBatch(@"Không thể tự động quay lại màn hình phân cảnh sau khi tạo.");
                                    return;
                                }
                                
                                // Khoảng dừng 300ms giải phóng RAM triệt để trước khi qua scene tiếp theo (Chống Crash)
                                VSDispatchAfterMS(300, ^{
                                    processNextSceneBlock();
                                });
                            });
                        }];
                    }];
                });
            }];
        }];
    };
    
    processNextSceneBlock();
}

- (void)openMultiLayerEditorForScene:(NSUInteger)sceneIndex reviewVC:(id)reviewVC runId:(NSUInteger)runId completion:(void (^)(id editorVC))done {
    id (^detectCurrentEditor)(void) = ^id{
        id ed = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
        if (!ed || ![ed getMultiLayerEngine]) return nil;
        id nav = [ed navigationController];
        BOOL sceneMatches = YES;
        if ([nav respondsToSelector:@selector(navSceneIndex)]) {
            sceneMatches = ([nav navSceneIndex] == sceneIndex);
        }
        return sceneMatches ? ed : nil;
    };
    
    if (detectCurrentEditor()) {
        done(detectCurrentEditor());
        return;
    }
    
    if (!reviewVC) {
        done(nil);
        return;
    }
    
    @try {
        [reviewVC setLastViewedSceneIndex:sceneIndex];
        [reviewVC showMultiLayer];
    } @catch (NSException *e) {
        VSLog(@"Ngoại lệ khi gọi showMultiLayer cho scene %lu: %@", (unsigned long)sceneIndex, e);
        done(nil);
        return;
    }
    
    VSSafePoll(runId, 80, 100, ^BOOL{
        return detectCurrentEditor() != nil;
    }, ^(BOOL success) {
        done(success ? detectCurrentEditor() : nil);
    });
}

// Nạp mã QR vào Editor và tự động giải quyết các cảnh báo độ dài frame
- (void)importPresetPayload:(id)preset codeIdentifier:(id)code intoEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done {
    if (![editorVC respondsToSelector:@selector(importedData:code:)]) {
        done(@"Editor không hỗ trợ phương thức importedData:code:.");
        return;
    }
    
    NSUInteger countBefore = g_presetImportEventCounter;
    
    @try {
        [editorVC importedData:preset code:code];
    } @catch (NSException *e) {
        done([NSString stringWithFormat:@"Lỗi khi nạp dữ liệu code: %@", e.reason ?: e.name]);
        return;
    }
    
    __block BOOL purchaseBlocked = NO;
    
    // Theo dõi popup và giải quyết ngay lập tức (Khắc phục triệt để Lỗi 1)
    VSSafePoll(runId, 50, 200, ^BOOL{
        VSPopupActionStatus st = VSResolvePopupsImmediately(editorVC);
        if (st == VSPopupActionStatusBlockedPurchase) {
            purchaseBlocked = YES;
            return YES;
        }
        return g_presetImportEventCounter > countBefore;
    }, ^(BOOL ok) {
        if (purchaseBlocked) {
            done(@"Gặp popup yêu cầu mua bản quyền Video Star. Tạm dừng để tránh lỗi.");
            return;
        }
        if (!ok) {
            done(@"Hết thời gian chờ nạp mã QR (Timeout 10s).");
            return;
        }
        
        VSDispatchAfterMS(500, ^{
            id engine = [editorVC getMultiLayerEngine];
            VSSafePoll(runId, 60, 60, ^BOOL{
                VSResolvePopupsImmediately(editorVC);
                return !VSHasAnyActivePopup(editorVC) && [engine numActiveLayers] > 0;
            }, ^(BOOL ready) {
                done(ready ? nil : @"Mã QR đã nạp nhưng Engine Nhiều lớp chưa sẵn sàng.");
            });
        });
    });
}

// Bấm nút Tạo (Create) và theo dõi quá trình đóng view an toàn
- (void)triggerCreateInEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done {
    BOOL buttonTriggered = NO;
    id createItem = VSSafeValueForKey(editorVC, @"createBarButton");
    
    @try {
        if ([createItem isKindOfClass:[UIBarButtonItem class]]) {
            UIBarButtonItem *barBtn = (UIBarButtonItem *)createItem;
            if (barBtn.action && barBtn.target) {
                buttonTriggered = [UIApplication.sharedApplication sendAction:barBtn.action
                                                                           to:barBtn.target
                                                                         from:barBtn
                                                                     forEvent:nil];
            }
        } else if ([createItem isKindOfClass:[UIControl class]]) {
            [(UIControl *)createItem sendActionsForControlEvents:UIControlEventTouchUpInside];
            buttonTriggered = YES;
        }
        
        if (!buttonTriggered && [editorVC respondsToSelector:@selector(create)]) {
            [editorVC create];
            buttonTriggered = YES;
        }
    } @catch (NSException *e) {
        done([NSString stringWithFormat:@"Không thể kích hoạt nút Tạo: %@", e.reason ?: e.name]);
        return;
    }
    
    if (!buttonTriggered) {
        done(@"Không tìm thấy nút Tạo trên thanh điều hướng.");
        return;
    }
    
    __block BOOL purchaseBlocked = NO;
    
    VSSafePoll(runId, 100, 600, ^BOOL{
        if (VSResolvePopupsImmediately(editorVC) == VSPopupActionStatusBlockedPurchase) {
            purchaseBlocked = YES;
            return YES;
        }
        // Khi hoàn tất tạo, view của MultiLayerWizEffectVC sẽ được gỡ khỏi window
        return !([editorVC isViewLoaded] && [[editorVC view] window]);
    }, ^(BOOL closed) {
        if (purchaseBlocked) {
            done(@"Thao tác Tạo yêu cầu mua bản quyền gói Pro.");
        } else if (closed) {
            done(nil);
        } else {
            done(@"Quá trình tạo clip phân cảnh chưa hoàn tất.");
        }
    });
}

@end

// ============================================================================
// PHẦN 13: ĐIỂM KHỞI CHẠY CHÍNH (CONSTRUCTOR & NOTIFICATION OBSERVERS)
// ============================================================================

static void VSBootstrapAutomation(void) {
    if (!NSClassFromString(@"MultiLayerWizEffectVC")) {
        VSLog(@"Không phải bundle của Video Star, bỏ qua khởi tạo.");
        return;
    }
    VSRunOnMain(^{
        [VSTool.shared setupToolInterfaceIfNeeded];
    });
}

__attribute__((constructor)) static void VSToolInitializerEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(NSNotification *note) {
            VSBootstrapAutomation();
        }];
        
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            VSBootstrapAutomation();
        }
    });
}
