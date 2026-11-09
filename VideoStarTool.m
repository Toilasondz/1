// ============================================================================
// VideoStarTool.m
// Video Star 14.3.3 (build 1809)
//
// LOGIC MỚI (3 yêu cầu):
//   1. Phân loại layer:
//      - VIDEO/IMAGE có content  → thay media
//      - RỖNG (chưa nhập)        → giữ im
//      - KHÁC (3D/text/color/...)→ giữ im
//   2. CN1: chỉ thay media, KHÔNG bấm popup
//      CN4: thay media + tự bấm Trùng khớp/OK
//   3. Layer đầu dùng picker UI, layer 2+ chạy ngầm
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

- (id)imageGenerator;
- (id)origAssetInfo;

- (id)asset;
- (UIImage *)layerImage;
- (id)layerDrawing;
- (id)layerZaps;
- (id)layerGIF;
- (id)layerOverlay;
- (unsigned int)layerImageTextureID;

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

- (NSURL *)clipURLForSceneIndex:(NSUInteger)sceneIndex clipIndex:(NSUInteger)clipIndex;

- (void)show;
- (void)dismiss;
- (void)simulateButtonPressButtonWithTitle:(id)title;
@end

// ============================================================================
// PHẦN 2: UTILITIES
// ============================================================================

static NSUInteger g_runIdentifier = 0;
static NSHashTable *g_activePopupsTable = nil;
static id g_lastHandledPopup = nil;
static CFAbsoluteTime g_lastHandledPopupTime = 0;

static inline void VSRunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) { @autoreleasepool { block(); } }
    else { dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { block(); } }); }
}

static inline void VSDispatchAfterMS(int64_t delayMs, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ @autoreleasepool { block(); } });
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

static inline id VSSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; } @catch (...) { return nil; }
}

static inline BOOL VSSafeIsClass(id object, NSString *className) {
    if (!object || !className.length) return NO;
    Class targetClass = NSClassFromString(className);
    return targetClass && [object isKindOfClass:targetClass];
}

// Tìm nút "Tạo" (không bao giờ trả về "Hủy")
static UIBarButtonItem *VSFindCreateButtonOnEditor(id editorVC) {
    if (!editorVC) return nil;
    NSArray *createKeywords = @[@"tạo", @"create", @"done", @"xong", @"save", @"lưu", @"export", @"xuất"];
    NSArray *cancelKeywords = @[@"hủy", @"huỷ", @"cancel", @"back", @"quay lại", @"dismiss", @"close", @"đóng"];

    BOOL (^isCreateButton)(UIBarButtonItem *) = ^BOOL(UIBarButtonItem *btn) {
        if (!btn) return NO;
        NSString *title = [btn.title lowercaseString] ?: @"";
        SEL action = btn.action;
        NSString *actionStr = action ? [[NSStringFromSelector(action) lowercaseString]
                                          stringByReplacingOccurrencesOfString:@"_" withString:@""] : @"";
        for (NSString *kw in cancelKeywords) if ([title containsString:kw] || [actionStr containsString:kw]) return NO;
        for (NSString *kw in createKeywords) if ([title containsString:kw] || [actionStr containsString:kw]) return YES;
        return NO;
    };

    id kvcButton = VSSafeValueForKey(editorVC, @"createBarButton");
    if ([kvcButton isKindOfClass:[UIBarButtonItem class]] && isCreateButton((UIBarButtonItem *)kvcButton)) {
        VSLog(@"[CreateButton] KVC: '%@'", ((UIBarButtonItem *)kvcButton).title ?: @"?");
        return (UIBarButtonItem *)kvcButton;
    }

    UINavigationController *nav = [editorVC navigationController];
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

static UIWindow *g_overlayToolWindow = nil;

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
        UIView *popupView = (UIView *)popup;
        if ((dimView && dimView.window) || (popupView && popupView.window)) [visibleOnly addObject:popup];
    }
    return visibleOnly;
}

static BOOL VSCheckIfPopupIsPurchasePrompt(id popup) {
    NSString *message = [VSSafeValueForKey(popup, @"_message") description].lowercaseString ?: @"";
    NSString *title = [VSSafeValueForKey(popup, @"_title") description].lowercaseString ?: @"";
    NSString *combined = [title stringByAppendingFormat:@" %@", message];
    NSArray *keywords = @[@"purchase", @"subscription", @"unlock pro", @"pro pack", @"restore purchase",
                          @"all access", @"pass", @"buy", @"mua gói", @"khôi phục", @"đăng ký", @"nâng cấp",
                          @"dùng thử", @"mở khóa", @"thanh toán"];
    for (NSString *keyword in keywords) if ([combined containsString:keyword]) return YES;
    return NO;
}

static VSPopupActionStatus VSResolvePopupsImmediately(id editorVC) {
    NSArray *popups = VSCollectAllVisiblePopups(editorVC);
    if (popups.count == 0) return VSPopupActionStatusNone;
    NSArray *priorityButtonNames = @[
        @"Khớp: rút ngắn/giãn", @"Match: shorten/stretch",
        @"Trùng khớp", @"Match",
        @"Original Preset Layers", @"Các lớp cài đặt sẵn gốc",
        @"Bắt đầu", @"Start", @"Kết thúc", @"End",
        @"Fit", @"Vừa khung", @"Replace", @"Thay thế",
        @"Continue", @"Tiếp tục", @"Yes", @"Có",
        @"OK", @"Đồng ý", @"Done", @"Xong"
    ];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (id popup in popups) {
        if (VSCheckIfPopupIsPurchasePrompt(popup)) { VSLog(@"Popup mua Pro — dừng"); return VSPopupActionStatusBlockedPurchase; }
        if (popup == g_lastHandledPopup && (now - g_lastHandledPopupTime < 0.35)) return VSPopupActionStatusHandled;

        NSArray *buttonStrings = VSSafeValueForKey(popup, @"_buttonStrings");
        NSArray *buttonsArray = VSSafeValueForKey(popup, @"_buttons");
        NSString *matchedTitle = nil;
        UIButton *matchedButtonObj = nil;

        for (NSString *candidate in priorityButtonNames) {
            NSString *localizedCandidate = VSLocalizedString(candidate);
            if ([buttonStrings isKindOfClass:[NSArray class]]) {
                for (id t in buttonStrings) {
                    if (![t isKindOfClass:[NSString class]]) continue;
                    if ([(NSString *)t localizedCaseInsensitiveContainsString:candidate] ||
                        [(NSString *)t localizedCaseInsensitiveContainsString:localizedCandidate]) { matchedTitle = t; break; }
                }
            }
            if (matchedTitle) break;
            if ([buttonsArray isKindOfClass:[NSArray class]]) {
                for (id b in buttonsArray) {
                    if (![b isKindOfClass:[UIButton class]]) continue;
                    UIButton *btn = (UIButton *)b;
                    if (btn.currentTitle.length &&
                        ([btn.currentTitle localizedCaseInsensitiveContainsString:candidate] ||
                         [btn.currentTitle localizedCaseInsensitiveContainsString:localizedCandidate])) {
                        matchedTitle = btn.currentTitle; matchedButtonObj = btn; break;
                    }
                }
            }
            if (matchedTitle || matchedButtonObj) break;
        }
        if (matchedTitle || matchedButtonObj) {
            g_lastHandledPopup = popup; g_lastHandledPopupTime = now;
            @try {
                if (matchedTitle && [popup respondsToSelector:@selector(simulateButtonPressButtonWithTitle:)]) {
                    VSLog(@"[SmartPopup] Nhấn: '%@'", matchedTitle);
                    [popup simulateButtonPressButtonWithTitle:matchedTitle];
                } else if (matchedButtonObj) {
                    VSLog(@"[SmartPopup] Touch: '%@'", matchedButtonObj.currentTitle);
                    [matchedButtonObj sendActionsForControlEvents:UIControlEventTouchUpInside];
                }
            } @catch (NSException *e) { VSLog(@"[SmartPopup] Exception: %@", e); }
            return VSPopupActionStatusHandled;
        }
    }
    return VSPopupActionStatusNone;
}

static inline BOOL VSHasAnyActivePopup(id editorVC) {
    return VSCollectAllVisiblePopups(editorVC).count > 0;
}

// ============================================================================
// HẾT ĐOẠN 1 — Dán đoạn 2 vào ngay sau đây
// ============================================================================
// ============================================================================
// PHẦN 4: LAYER SNAPSHOT — PHÂN LOẠI 3 YÊU CẦU
// ============================================================================

typedef NS_ENUM(NSInteger, VSLayerMediaKind) {
    VSLayerMediaKindUnknown = 0,
    VSLayerMediaKindImage,
    VSLayerMediaKindVideo,
    VSLayerMediaKindEmpty   // ← Layer rỗng, giữ im
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

// Phân loại layer:
// - VIDEO/IMAGE (có content) → thay thế
// - RỖNG (chưa nhập) → giữ im
// - KHÁC (3D/text/color/gif/zap/drawing/overlay) → trả nil, không xử lý
static VSLayerSnapshot *VSInspectLayerDetails(id engine, NSUInteger layerNum) {
    if (!engine) return nil;
    @autoreleasepool {
        @try {
            id layer = [engine layerAtLayerNum:layerNum];
            if (!layer) return nil;

            if (VSSafeValueForKey(layer, @"layer3D") || VSSafeValueForKey(layer, @"layer3d")) return nil;

            id generator = [layer respondsToSelector:@selector(imageGenerator)] ? [layer imageGenerator] : nil;
            if (!generator) return nil;

            if ([generator respondsToSelector:@selector(layerGIF)] && [generator layerGIF]) return nil;
            if ([generator respondsToSelector:@selector(layerZaps)] && [generator layerZaps]) return nil;
            if ([generator respondsToSelector:@selector(layerDrawing)] && [generator layerDrawing]) return nil;
            if ([generator respondsToSelector:@selector(layerOverlay)] && [generator layerOverlay]) return nil;

            if (VSSafeValueForKey(generator, @"isTextLayer") || VSSafeValueForKey(generator, @"textView")) return nil;
            if (VSSafeValueForKey(generator, @"isColorLayer") || VSSafeValueForKey(generator, @"fillColor")) return nil;
            if (VSSafeValueForKey(generator, @"is3DLayer")) return nil;

            id asset = [generator respondsToSelector:@selector(asset)] ? [generator asset] : nil;
            BOOL hasVideo = [asset isKindOfClass:[AVAsset class]];

            UIImage *img = [generator respondsToSelector:@selector(layerImage)] ? [generator layerImage] : nil;
            BOOL hasImage = [img isKindOfClass:[UIImage class]] && img.size.width > 1.0;

            VSLayerSnapshot *snap = [VSLayerSnapshot new];
            snap.layerIndex = layerNum;
            snap.assetInfo = [layer respondsToSelector:@selector(origAssetInfo)] ? ([layer origAssetInfo] ?: @"") : @"";
            if ([generator respondsToSelector:@selector(layerImageTextureID)]) {
                snap.textureID = [generator layerImageTextureID];
            }

            if (hasVideo) {
                snap.mediaKind = VSLayerMediaKindVideo;
                snap.mediaObject = asset;
                VSLog(@"[Layer %lu] VIDEO → thay thế", (unsigned long)layerNum);
            } else if (hasImage) {
                snap.mediaKind = VSLayerMediaKindImage;
                snap.mediaObject = img;
                VSLog(@"[Layer %lu] IMAGE → thay thế", (unsigned long)layerNum);
            } else {
                snap.mediaKind = VSLayerMediaKindEmpty;
                snap.mediaObject = nil;
                VSLog(@"[Layer %lu] RỖNG → giữ im", (unsigned long)layerNum);
            }
            return snap;
        } @catch (NSException *e) {
            VSLog(@"Inspect layer %lu: %@", (unsigned long)layerNum, e);
            return nil;
        }
    }
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
                [png writeToFile:VSGetLastQRCodeStoragePath() atomically:YES];
                VSLog(@"Đã lưu QR (%lu bytes)", (unsigned long)png.length);
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
        CIImage *ci = [CIImage imageWithCGImage:image.CGImage];
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
static IMP g_origCustomPopupShow = NULL;

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

        VSRobustSwizzleMethod(@"CustomPopup", @selector(show), ^(id selfInstance) {
            if (g_origCustomPopupShow)
                ((void (*)(id, SEL))g_origCustomPopupShow)(selfInstance, @selector(show));
            if (selfInstance) [g_activePopupsTable addObject:selfInstance];
            VSDispatchAfterMS(80, ^{ VSResolvePopupsImmediately(nil); });
        }, &g_origCustomPopupShow);

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
@end

// ============================================================================
// HẾT ĐOẠN 2 — Dán đoạn 3 vào ngay sau đây
// ============================================================================
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

- (void)requestUserMediaSelectionOnEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(id clipResponse, VSLayerSnapshot *firstLayerInfo))done;
- (void)applyMediaResponse:(id)response toEditor:(id)editorVC filterKind:(VSLayerMediaKind)filterKind skipLayer:(NSInteger)skipIndex runId:(NSUInteger)runId completion:(void (^)(NSUInteger changedCount, NSUInteger totalCount))done;
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.floatingButton;
    sheet.popoverPresentationController.sourceRect = self.floatingButton.bounds;
    [[self topPresenterVC] presentViewController:sheet animated:YES completion:nil];
}

- (NSUInteger)startNewTaskWithDescription:(NSString *)name initialStatus:(NSString *)status {
    g_runIdentifier++;
    self.currentTaskName = name;
    self.floatingButton.alpha = 0.55;
    [self updateStatusHUD:status];
    return g_runIdentifier;
}

- (void)restoreOriginalQRCodeDelegate {
    if (!self.savedOriginalQRDelegateValid) return;
    id qr = [NSClassFromString(@"QRCodeManager") respondsToSelector:@selector(sharedInstance)] ? [NSClassFromString(@"QRCodeManager") sharedInstance] : nil;
    if (qr) VSSetQRDelegateSafely(qr, self.savedOriginalQRDelegate);
    self.savedOriginalQRDelegate = nil; self.savedOriginalQRDelegateValid = NO;
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
    if (msg.length) [self showNotificationAlert:msg title:@"VideoStarTool"];
}

// ============================================================================
// PHẦN 9: FEATURE 1 — Auto replace layers
// ============================================================================

- (void)requestUserMediaSelectionOnEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(id, VSLayerSnapshot *))done {
    if (!g_origPickedWithResponse) { done(nil, nil); return; }
    g_activeMediaPickedHandler = ^(id me, id response) {
        if (runId != g_runIdentifier || me != editorVC) return;
        g_activeMediaPickedHandler = nil;
        __block VSLayerSnapshot *snap = nil;
        VSSafePoll(runId, 120, 50, ^BOOL{
            id eng = [me getMultiLayerEngine]; NSInteger n = [me lastSelectedLayerNum];
            if (!eng || n < 0) return NO;
            snap = VSInspectLayerDetails(eng, (NSUInteger)n);
            return snap != nil;
        }, ^(BOOL ok) { done(ok ? response : nil, snap); });
    };
    VSSafePoll(runId, 100, 60, ^BOOL{
        return [editorVC isViewLoaded] && [[editorVC view] window] && [editorVC getMultiLayerEngine];
    }, ^(BOOL ready) {
        if (!ready) { g_activeMediaPickedHandler = nil; done(nil, nil); return; }
        VSDispatchAfterMS(150, ^{
            if (runId != g_runIdentifier) return;
            @try { [editorVC pickNewContent]; }
            @catch (NSException *e) { g_activeMediaPickedHandler = nil; VSLog(@"pickNewContent: %@", e); done(nil, nil); }
        });
    });
}

// applyMediaResponse — Logic 3 yêu cầu
// CN1 (skipIndex >= 0): không bấm popup
// CN4 (skipIndex < 0): tự bấm popup
- (void)applyMediaResponse:(id)response toEditor:(id)editorVC filterKind:(VSLayerMediaKind)filterKind skipLayer:(NSInteger)skipIndex runId:(NSUInteger)runId completion:(void (^)(NSUInteger, NSUInteger))done {
    id engine = [editorVC getMultiLayerEngine];
    if (!engine) { done(0, 0); return; }

    NSMutableArray<NSNumber *> *targetLayers = [NSMutableArray array];
    for (NSUInteger i = 0; i < VS_MAX_LAYERS; i++) {
        VSLayerSnapshot *snap = VSInspectLayerDetails(engine, i);
        if (!snap) continue;
        if (snap.mediaKind == VSLayerMediaKindEmpty) continue;
        if ((NSInteger)i == skipIndex) continue;
        if (filterKind != VSLayerMediaKindUnknown && snap.mediaKind != filterKind) continue;
        [targetLayers addObject:@(i)];
    }

    NSUInteger total = targetLayers.count;
    if (total == 0) { done(0, 0); return; }
    BOOL isBatchMode = (skipIndex < 0);

    __block NSUInteger idx = 0, successCount = 0;
    __block void (^iterate)(void) = nil;

    iterate = ^{
        if (runId != g_runIdentifier) { iterate = nil; return; }
        if (isBatchMode) VSResolvePopupsImmediately(editorVC);

        if (idx >= total) {
            @try {
                if (successCount > 0) {
                    [engine reloadLayerEffects];
                    [editorVC handleImageGenUpdate];
                    [editorVC engineResync];
                    [editorVC refreshDisplay];
                }
            } @catch (...) {}
            iterate = nil;
            done(successCount, total);
            return;
        }

        NSUInteger n = targetLayers[idx++].unsignedIntegerValue;
        [self updateStatusHUD:[NSString stringWithFormat:@"Đang thay: lớp %lu (%lu/%lu)", (unsigned long)(n + 1), (unsigned long)idx, (unsigned long)total]];

        @try { [editorVC selectLayer:n bordered:NO]; }
        @catch (NSException *e) { VSLog(@"selectLayer %lu: %@", (unsigned long)n, e); iterate(); return; }

        VSSafePoll(runId, 50, 20, ^BOOL{ return [editorVC lastSelectedLayerNum] == (NSInteger)n; }, ^(BOOL sel) {
            if (!sel) { @try { [editorVC selectLayerNum:n flash:NO]; } @catch (...) {} }
            VSDispatchAfterMS(sel ? 50 : 120, ^{
                if (runId != g_runIdentifier) { iterate = nil; return; }
                VSLayerSnapshot *before = VSInspectLayerDetails(engine, n);
                BOOL ok = VSReplayClipPickerResponseOnEditor(editorVC, response);
                if (!ok) { VSLog(@"layer %lu: replay fail", (unsigned long)n); iterate(); return; }

                __block BOOL confirmed = NO;
                VSSafePoll(runId, 80, 25, ^BOOL{
                    if (isBatchMode) VSResolvePopupsImmediately(editorVC);
                    VSLayerSnapshot *cur = VSInspectLayerDetails(engine, n);
                    if (!cur) return NO;
                    if (cur.textureID && cur.textureID != before.textureID) { confirmed = YES; return YES; }
                    if (cur.mediaObject && cur.mediaObject != before.mediaObject) { confirmed = YES; return YES; }
                    if (cur.assetInfo.length && ![cur.assetInfo isEqualToString:before.assetInfo]) { confirmed = YES; return YES; }
                    return NO;
                }, ^(BOOL r) {
                    successCount++;
                    VSLog(@"layer %lu: %@", (unsigned long)n, (r || confirmed) ? @"✅" : @"⚠️ timeout");
                    VSDispatchAfterMS(40, ^{ iterate(); });
                });
            });
        });
    };
    iterate();
}

- (void)executeFeature1ReplaceLayers {
    id editor = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
    if (!editor) { [self showNotificationAlert:@"Vào màn hình Nhiều lớp trước." title:@"Chưa ở Nhiều lớp"]; return; }
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto nhập ảnh" initialStatus:@"Chọn 1 ảnh/video…"];
    [self requestUserMediaSelectionOnEditor:editor runId:runId completion:^(id clipResponse, VSLayerSnapshot *firstLayerInfo) {
        if (!clipResponse) { [self finalizeTaskWithMessage:@"Không nhận được media"]; return; }
        VSLayerMediaKind filter = firstLayerInfo ? firstLayerInfo.mediaKind : VSLayerMediaKindUnknown;
        NSInteger skip = firstLayerInfo ? (NSInteger)firstLayerInfo.layerIndex : -1;
        [self applyMediaResponse:clipResponse toEditor:editor filterKind:filter skipLayer:skip runId:runId completion:^(NSUInteger c, NSUInteger t) {
            [self finalizeTaskWithMessage:[NSString stringWithFormat:@"Xong %lu/%lu lớp", (unsigned long)c, (unsigned long)t]];
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
    if (!visible()) { @try { [reviewVC showSplitScene]; } @catch (NSException *e) { [self finalizeTaskWithMessage:@"Không mở được bảng chia"]; return; } }

    VSSafePoll(runId, 100, 35, ^BOOL{ return visible(); }, ^(BOOL ok) {
        id sv = fetchSV();
        if (!ok || !sv) { [self finalizeTaskWithMessage:@"Không tìm thấy MultiSplitView"]; return; }
        [self validateAndRunBeatSplitting:reviewVC splitView:sv runId:runId];
    });
}

- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)sv runId:(NSUInteger)runId {
    NSString *err = nil;
    @try {
        id<ProjectInterface> p = [reviewVC project];
        NSUInteger s = [reviewVC sceneIndex];
        NSUInteger cc = [p clipCountForSceneIndex:s];
        if (![reviewVC isEnoughStorageAvailableForSplit]) err = @"Bộ nhớ không đủ";
        else if (![p sceneHasAtLeastOneClipWithSceneIndex:s] || cc == 0) err = @"Không có clip";
    } @catch (...) { err = @"Lỗi kiểm tra"; }
    if (err) { [self finalizeTaskWithMessage:err]; return; }

    id<ProjectInterface> p = [reviewVC project];
    NSUInteger before = [p sceneCount];
    @try {
        if (![sv beatModeOn]) [sv toggleBeatMode];
        [sv gotoTime:kCMTimeZero];
    } @catch (NSException *e) { [self finalizeTaskWithMessage:@"Không bật Beat Mode"]; return; }

    __block NSUInteger guard = 0, count = 0;
    __block CMTime last = kCMTimeInvalid;
    __block void (^step)(void) = nil;

    void (^finish)(void) = ^{
        step = nil;
        if (runId != g_runIdentifier) return;
        if (count == 0 && [VSSafeValueForKey(sv, @"splitTimes") count] == 0) { [self finalizeTaskWithMessage:@"Không có beat"]; return; }
        @try { [sv doSplit]; } @catch (NSException *e) { [self finalizeTaskWithMessage:@"Lỗi chia"]; return; }
        [self updateStatusHUD:@"Đang chia…"];
        VSSafePoll(runId, 120, 150, ^BOOL{ return [p sceneCount] > before; }, ^(BOOL ok) {
            [self finalizeTaskWithMessage:ok ? [NSString stringWithFormat:@"Xong, +%lu scene", (unsigned long)([p sceneCount] - before)] : @"Chưa xong"];
        });
    };

    step = ^{
        if (runId != g_runIdentifier) { step = nil; return; }
        if (++guard >= 2048 || ![sv hasNextBeat]) { finish(); return; }
        CMTime from = VSSafeCurrentTime(sv);
        [sv jumpToNextBeat];
        VSSafePoll(runId, 16, 60, ^BOOL{
            CMTime cur = VSSafeCurrentTime(sv);
            return CMTIME_IS_VALID(cur) && (CMTIME_IS_INVALID(from) || CMTimeCompare(cur, from) > 0);
        }, ^(BOOL moved) {
            CMTime cur = VSSafeCurrentTime(sv);
            if (!moved || (CMTIME_IS_VALID(last) && CMTimeCompare(cur, last) <= 0)) { finish(); return; }
            last = cur;
            [sv setSplitPoint];
            count++;
            [self updateStatusHUD:[NSString stringWithFormat:@"%lu điểm chia…", (unsigned long)count]];
            VSDispatchAfterMS(20, ^{ step(); });
        });
    };
    VSDispatchAfterMS(250, ^{ step(); });
}

// ============================================================================
// PHẦN 12: FEATURE 4 — Batch multi-scene
// ============================================================================

- (void)executeFeature4BatchMultiScene {
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!reviewVC) { [self showNotificationAlert:@"Vào màn hình phân cảnh trước" title:@"Sai vị trí"]; return; }
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto code + ảnh" initialStatus:nil];
    NSUInteger origScene = [reviewVC lastViewedSceneIndex];
    @try { [reviewVC showMergeScenes]; }
    @catch (NSException *e) { [self finalizeTaskWithMessage:@"Không mở được Hợp nhất"]; return; }
    [self displayBottomActionBarWithTitle:@"Chọn phân cảnh" message:@"Chọn đầu và cuối, bấm Bắt đầu" confirmTitle:@"Bắt đầu" onConfirm:^{
        [self parseMergeRangeAndPresentCodePanel:reviewVC runId:runId originalLastViewed:origScene];
    } onCancel:^{ @try { [reviewVC closeMergePanel]; } @catch (...) {} [self terminateCurrentTaskQuietly]; }];
}

- (void)parseMergeRangeAndPresentCodePanel:(id)reviewVC runId:(NSUInteger)runId originalLastViewed:(NSUInteger)orig {
    if (runId != g_runIdentifier) return;
    id<ProjectInterface> p = [reviewVC project];
    NSInteger total = (NSInteger)[p sceneCount];
    NSInteger s = [VSSafeValueForKey(reviewVC, @"startScene") integerValue];
    NSInteger l = [VSSafeValueForKey(reviewVC, @"lastScene") integerValue];
    if (!p || s < 0 || l < s || l >= total) {
        @try { [reviewVC closeMergePanel]; } @catch (...) {}
        [self finalizeTaskWithMessage:@"Phạm vi không hợp lệ"];
        return;
    }
    @try { [reviewVC closeMergePanel]; } @catch (...) {}
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
    self.multiSceneCardView.hidden = YES;
    [self updateStatusHUD:@"Mở Nhiều lớp ở scene đầu…"];
    id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    [self openMultiLayerEditorForScene:self.multiSceneStart reviewVC:rvc runId:runId completion:^(id editor) {
        if (!editor) { [self finalizeTaskWithMessage:@"Không mở được Nhiều lớp"]; return; }
        [self updateStatusHUD:@"Chọn 1 ảnh/video dùng chung…"];
        [self requestUserMediaSelectionOnEditor:editor runId:runId completion:^(id resp, VSLayerSnapshot *first) {
            if (!resp) { [self finalizeTaskWithMessage:@"Không lấy được media"]; return; }
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
    __block NSUInteger offset = 0, ok = 0;
    __block void (^step)(void) = nil;

    void (^finish)(NSString *) = ^(NSString *err) {
        step = nil;
        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        @try { [rvc setLastViewedSceneIndex:orig]; } @catch (...) {}
        [self terminateCurrentTaskQuietly];
        NSString *msg = [NSString stringWithFormat:@"Xong %lu/%lu scene", (unsigned long)ok, (unsigned long)total];
        [self showNotificationAlert:err ? [err stringByAppendingFormat:@"\n%@", msg] : msg title:err ? @"Dừng" : @"Thành công"];
    };

    step = ^{
        if (runId != g_runIdentifier) { step = nil; return; }
        if (offset >= total) { finish(nil); return; }
        NSUInteger o = offset++, sc = start + o;
        [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu (%lu/%lu): mở…", (unsigned long)(sc + 1), (unsigned long)(o + 1), (unsigned long)total]];
        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        [self openMultiLayerEditorForScene:sc reviewVC:rvc runId:runId completion:^(id editor) {
            if (!editor) { finish([NSString stringWithFormat:@"Không mở được scene %lu", (unsigned long)(sc + 1)]); return; }
            [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: nhập code…", (unsigned long)(sc + 1)]];
            [self importPresetPayload:presets[o] codeIdentifier:codes[o] intoEditor:editor runId:runId completion:^(NSString *e1) {
                if (e1) { finish([NSString stringWithFormat:@"Scene %lu: %@", (unsigned long)(sc + 1), e1]); return; }
                if (runId != g_runIdentifier) { step = nil; return; }
                [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: đợi ổn định…", (unsigned long)(sc + 1)]];
                VSDispatchAfterMS(500, ^{
                    if (runId != g_runIdentifier) { step = nil; return; }
                    [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: thay media…", (unsigned long)(sc + 1)]];
                    [self applyMediaResponse:resp toEditor:editor filterKind:VSLayerMediaKindUnknown skipLayer:-1 runId:runId completion:^(NSUInteger c, NSUInteger t) {
                        if (runId != g_runIdentifier) { step = nil; return; }
                        [self updateStatusHUD:[NSString stringWithFormat:@"Scene %lu: Tạo…", (unsigned long)(sc + 1)]];
                        [self triggerCreateInEditor:editor runId:runId completion:^(NSString *e2) {
                            if (e2) { finish([NSString stringWithFormat:@"Scene %lu: %@", (unsigned long)(sc + 1), e2]); return; }
                            ok++;
                            VSSafePoll(runId, 100, 120, ^BOOL{ return VSFindTopViewControllerNamed(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                                if (!back) { finish(@"Không quay lại được"); return; }
                                VSDispatchAfterMS(300, ^{ step(); });
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
    if (current()) { done(current()); return; }
    if (!rvc) { done(nil); return; }
    @try { [rvc setLastViewedSceneIndex:scene]; [rvc showMultiLayer]; }
    @catch (NSException *e) { done(nil); return; }
    VSSafePoll(runId, 80, 100, ^BOOL{ return current() != nil; }, ^(BOOL ok) { done(ok ? current() : nil); });
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
        if (blocked) { done(@"Popup mua Pro"); return; }
        if (!ok) { done(@"Timeout 10s"); return; }
        VSDispatchAfterMS(500, ^{
            id engine = [editor getMultiLayerEngine];
            VSSafePoll(runId, 60, 60, ^BOOL{
                VSResolvePopupsImmediately(editor);
                return !VSHasAnyActivePopup(editor) && [engine numActiveLayers] > 0;
            }, ^(BOOL ready) { done(ready ? nil : @"Engine chưa sẵn sàng"); });
        });
    });
}

- (void)triggerCreateInEditor:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    UIBarButtonItem *btn = VSFindCreateButtonOnEditor(editor);
    if (!btn) { done(@"Không tìm thấy nút Tạo"); return; }
    VSLog(@"[Create] '%@' action='%@'", btn.title ?: @"?", btn.action ? NSStringFromSelector(btn.action) : @"?");
    BOOL fired = NO;
    @try {
        if (btn.action && btn.target) {
            fired = [UIApplication.sharedApplication sendAction:btn.action to:btn.target from:btn forEvent:nil];
        }
    } @catch (NSException *e) { done([NSString stringWithFormat:@"Lỗi: %@", e.reason ?: e.name]); return; }
    if (!fired) {
        @try {
            if ([editor respondsToSelector:@selector(create)]) { [editor create]; fired = YES; }
        } @catch (NSException *e) { done(@"Lỗi create"); return; }
    }
    if (!fired) { done(@"Không kích hoạt được"); return; }
    __block BOOL blocked = NO;
    VSSafePoll(runId, 100, 600, ^BOOL{
        if (VSResolvePopupsImmediately(editor) == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
        return !([editor isViewLoaded] && [[editor view] window]);
    }, ^(BOOL closed) {
        done(blocked ? @"Tạo yêu cầu Pro" : (closed ? nil : @"Tạo timeout"));
    });
}

@end

// ============================================================================
// HẾT ĐOẠN 3 — Dán đoạn 4 vào ngay sau đây
// ============================================================================
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
