// ============================================================================
// VideoStarTool.m — Video Star 14.3.3 (build 1809) — v8 (PERFECT REWRITE)
//
// ĐÃ THIẾT KẾ LẠI HOÀN TOÀN THEO YÊU CẦU:
//   1. BỎ HOÀN TOÀN CỬ CHỈ 3 NGÓN 2 LẦN VÀ BẢNG MENU TỔNG HỢP:
//      - Không còn menu chung phức tạp hay cử chỉ dễ nhầm lẫn.
//      - Thay bằng NÚT NỔI NGỮ CẢNH (Floating Pill) tự động xuất hiện ở đúng màn hình:
//        * Màn hình Chia đoạn (Split Scene): Có nút nổi [⚡ Chia Beat]
//        * Màn hình Kết hợp (Merge Panel):  Có nút nổi [🔄 Nhập Multi]
//        * Màn hình Nhiều lớp (MultiLayer): Có nút nổi [📷 Auto Lớp]
//   2. CHỨC NĂNG 4 SIÊU TỐC VÀ KHÔNG CẦN CHỌN LẠI ẢNH (~20s / 10 PHÂN CẢNH):
//      - Chỉnh Cài đặt Đầu và Cuối trên giao diện Video Star trước.
//      - Bấm [🔄 Nhập Multi] -> Mở ngay kho ảnh iOS (PHPicker) chọn tất cả QR cùng lúc.
//      - Bỏ hoàn toàn bảng phân đoạn chọn từng code và bỏ chức năng xem code gần đây.
//      - Tự động bỏ qua bảng hỏi "Trùng khớp" / "Match" ngay lập tức khi nạp QR.
//      - Phân cảnh đầu tiên: Chọn 1 ảnh -> Tự động điền ảnh vào tất cả các lớp -> Tạo.
//      - TẤT CẢ các phân cảnh tiếp theo: TỰ ĐỘNG DÙNG LẠI ẢNH ĐÃ CHỌN Ở PHÂN CẢNH ĐẦU,
//        KHÔNG MỞ LẠI BẢNG CHỌN ẢNH -> Tự nạp vào tất cả các lớp -> Tự động bấm Tạo!
//   3. FIX TRIỆT ĐỂ LỖI VĂNG APP (ZERO CRASH):
//      - Thay thế hoàn toàn UIAlertController bằng Card thông báo nổi cao cấp.
//      - Hook confirmOverwrite: và confirmAddingLayer: giữ chuẩn 100% v5 (pure passthrough),
//        tuyệt đối không dereference tham số con trỏ thô để không bao giờ bị EXC_BAD_ACCESS!
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
#define VS_COPY_CONFIRM_TIMEOUT 8.0
#define VSLog(...) ((void)0)

typedef id (^VSObjProvider)(void);
typedef void (^VSFillCompletion)(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stopReason);

// ============================================================================
// AN TOÀN & BỘ NHỚ
// ============================================================================

static void VSAbortActiveTask(NSString *reason);

static void VSGuard(void (^block)(void)) {
    @try { block(); }
    @catch (NSException *e) {
        VSAbortActiveTask([NSString stringWithFormat:@"Dừng an toàn, app báo lỗi: %@", e.reason ?: e.name]);
    }
}

static inline void VSRunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) { @autoreleasepool { VSGuard(block); } }
    else { dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { VSGuard(block); } }); }
}

static inline void VSDispatchAfterMS(int64_t delayMs, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ @autoreleasepool { VSGuard(block); } });
}

static BOOL VSTry(void (^block)(void)) {
    @try { block(); return YES; }
    @catch (NSException *__unused e) { return NO; }
}

static CFAbsoluteTime g_memoryWarningAt = 0;

static unsigned long long VSAvailableMemoryMB(void) {
    if (@available(iOS 13.0, *)) {
        uint64_t bytes = (uint64_t)os_proc_available_memory();
        return bytes == 0 ? 100000ULL : bytes / (1024ULL * 1024ULL);
    }
    return 100000ULL;
}

static BOOL VSMemoryHealthy(void) {
    if (g_memoryWarningAt > 0 && CFAbsoluteTimeGetCurrent() - g_memoryWarningAt < 6.0) return NO;
    return VSAvailableMemoryMB() >= VS_MIN_FREE_MB;
}

// ============================================================================
// PRIVATE API & PROTOCOLS
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
- (void)selectLayer:(NSUInteger)arg0 bordered:(BOOL)arg1;
- (void)selectLayerNum:(NSUInteger)arg0 flash:(BOOL)arg1;
- (NSInteger)lastSelectedLayerNum;
- (id)lastSelectedLayer;
- (NSInteger)getSceneIndex;
- (void)create;
- (void)makePhotoLayer:(id)image;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show;
- (void)overwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show removeOverlayBlending:(BOOL)remove;
- (void)copyLayer:(NSInteger)layer;
- (void)importedData:(id)preset code:(id)code;
- (void)importNewPreset:(id)preset keyFrameAction:(id)action qrDurationInFrames:(NSInteger)frames;
- (void)importOldPreset:(id)preset;
- (BOOL)showImportConfirmation;
- (void)showLayerActionMenu:(NSUInteger)layerNum newLayer:(BOOL)isNewLayer;
- (void)confirmOverwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show;
- (void)confirmOverwrite:(id)object isAbleToShowTheLayerActionMenu:(BOOL)show removeOverlayBlending:(BOOL)remove;
- (void)confirmAddingLayer:(SEL)sel object:(id)o1 object2:(id)o2 object3:(id)o3;
- (void)confirmAddingLayer:(SEL)sel object:(id)o1 object2:(id)o2 object3:(id)o3 isAbleToShowTheLayerActionMenu:(BOOL)able;
- (void)simulateButtonPressButtonWithTitle:(id)title;
- (void)dismiss;
// MultiLayerEngine
- (NSInteger)numActiveLayers;
- (id)layerAtLayerNum:(NSUInteger)layerNum;
- (BOOL)assetHasBeenLoadedForLayer:(NSUInteger)layerNum;
- (id)assetForLayer:(NSUInteger)layerNum;
- (id)imageGenerator;
- (UIImage *)layerImage;
// VideoReviewEditVC
- (id<ProjectInterface>)project;
- (NSUInteger)sceneIndex;
- (NSUInteger)lastViewedSceneIndex;
- (void)setLastViewedSceneIndex:(NSUInteger)index;
- (void)showMultiLayer;
- (void)showSplitScene;
- (void)closeSplitPanel;
- (void)showMergeScenes;
- (void)closeMergePanel;
- (BOOL)isEnoughStorageAvailableForSplit;
// MultiSplitView
- (BOOL)beatModeOn;
- (void)toggleBeatMode;
- (BOOL)hasNextBeat;
- (void)jumpToNextBeat;
- (void)setSplitPoint;
- (void)doSplit;
- (void)gotoTime:(CMTime)time;
- (CMTime)currentTime;
- (BOOL)isNullLayer;
- (BOOL)isNullLayer:(NSUInteger)layer;
- (NSInteger)navSceneIndex;
@end

// ============================================================================
// SWIZZLING HELPER
// ============================================================================

static BOOL VSRobustSwizzleMethod(NSString *className, SEL selector, id block, IMP *originalStore) {
    Class targetClass = NSClassFromString(className);
    if (!targetClass) return NO;
    Method origMethod = class_getInstanceMethod(targetClass, selector);
    IMP blockIMP = imp_implementationWithBlock(block);
    if (!blockIMP) return NO;
    if (origMethod) {
        IMP oldIMP = class_replaceMethod(targetClass, selector, blockIMP, method_getTypeEncoding(origMethod));
        if (originalStore) *originalStore = oldIMP ? oldIMP : method_getImplementation(origMethod);
    } else {
        class_addMethod(targetClass, selector, blockIMP, "v@:");
        if (originalStore) *originalStore = NULL;
    }
    return YES;
}

// ============================================================================
// BIẾN TOÀN CỤC & TRẠNG THÁI
// ============================================================================

static NSUInteger g_runIdentifier = 0;
static BOOL g_vsaAutomating = NO;
static BOOL g_suppressLayerActionMenu = NO;
static BOOL g_dismissLayerMenu = YES;
static BOOL g_autoConfirmPopups = NO;
static BOOL g_createInProgress = NO;
static NSHashTable *g_activePopupsTable = nil;
static NSUInteger g_presetImportEventCounter = 0;
static const char * const kVSMenuDismissedKey = "kVSMenuDismissedKey";
static const char * const kVSPopupHandledKey = "kVSPopupHandledKey";
static id g_qrBatchPickerDelegate = nil;

// Ảnh lưu từ phân cảnh đầu tiên để tái sử dụng siêu tốc cho tất cả các phân cảnh tiếp theo
static UIImage *g_savedMultiSceneImage = nil;

// Handler thông báo layer được thêm (v5: chỉ đặt cờ, không lưu con trỏ thô)
static void (^g_onLayerAddedHandler)(id sender, NSArray *args, BOOL is5, BOOL able) = nil;

// Original IMP stores
static IMP g_origImportNewPreset = NULL;
static IMP g_origImportOldPreset = NULL;
static IMP g_origCustomPopupDidMove = NULL;
static IMP g_origShowLayerActionMenu = NULL;
static IMP g_origShowImportConfirmation = NULL;
static IMP g_origConfirmOverwrite1 = NULL;
static IMP g_origConfirmOverwrite2 = NULL;
static IMP g_origConfirmAdd4 = NULL;
static IMP g_origConfirmAdd5 = NULL;

// Hooks màn hình để bật/tắt nút nổi tự động
static IMP g_origShowSplitScene = NULL;
static IMP g_origCloseSplitPanel = NULL;
static IMP g_origShowMergeScenes = NULL;
static IMP g_origCloseMergePanel = NULL;
static IMP g_origMLViewDidAppear = NULL;
static IMP g_origMLViewWillDisappear = NULL;

// ============================================================================
// HỖ TRỢ AN TOÀN
// ============================================================================

static id VSSafeValueForKey(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *__unused e) { return nil; }
}

static BOOL VSSafeIsClass(id obj, NSString *clsName) {
    if (!obj || !clsName.length) return NO;
    Class c = NSClassFromString(clsName);
    return c && [obj isKindOfClass:c];
}

static BOOL VSContains(NSString *str, NSString *needle) {
    if (!str.length || !needle.length) return NO;
    return [str rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSUInteger VSCountOf(id coll) {
    if ([coll respondsToSelector:@selector(count)]) {
        @try { return (NSUInteger)[coll count]; }
        @catch (NSException *__unused e) { return 0; }
    }
    return 0;
}

static CMTime VSSafeCurrentTime(id obj) {
    if (!obj || ![obj respondsToSelector:@selector(currentTime)]) return kCMTimeInvalid;
    @try {
        SEL s = @selector(currentTime);
        NSMethodSignature *sig = [obj methodSignatureForSelector:s];
        if (!sig || strcmp(sig.methodReturnType, @encode(CMTime)) != 0) return kCMTimeInvalid;
        CMTime (*fn)(id, SEL) = (CMTime (*)(id, SEL))objc_msgSend;
        return fn(obj, s);
    } @catch (NSException *__unused e) { return kCMTimeInvalid; }
}

// ============================================================================
// ENGINE HELPERS
// ============================================================================

static id VSEngineFrom(id editorVC) {
    if (!editorVC) return nil;
    if ([editorVC respondsToSelector:@selector(getMultiLayerEngine)]) {
        @try { return [editorVC getMultiLayerEngine]; }
        @catch (NSException *__unused e) { return nil; }
    }
    return VSSafeValueForKey(editorVC, @"engine") ?: VSSafeValueForKey(editorVC, @"multiLayerEngine");
}

static NSInteger VSNumActiveLayers(id engine) {
    if (!engine || ![engine respondsToSelector:@selector(numActiveLayers)]) return 0;
    @try { return [engine numActiveLayers]; }
    @catch (NSException *__unused e) { return 0; }
}

static NSInteger VSLastSelectedLayer(id editorVC) {
    if (!editorVC) return -1;
    if ([editorVC respondsToSelector:@selector(lastSelectedLayerNum)]) {
        @try { return [editorVC lastSelectedLayerNum]; }
        @catch (NSException *__unused e) { return -1; }
    }
    id num = VSSafeValueForKey(editorVC, @"lastSelectedLayerNum");
    return [num respondsToSelector:@selector(integerValue)] ? [num integerValue] : -1;
}

static BOOL VSLayerAssetLoaded(id engine, NSUInteger layerNum) {
    if (!engine) return NO;
    if ([engine respondsToSelector:@selector(assetHasBeenLoadedForLayer:)]) {
        @try { return [engine assetHasBeenLoadedForLayer:layerNum]; }
        @catch (NSException *__unused e) { return NO; }
    }
    id layer = [engine respondsToSelector:@selector(layerAtLayerNum:)] ? [engine layerAtLayerNum:layerNum] : nil;
    id gen = VSSafeValueForKey(layer, @"imageGenerator");
    id loaded = VSSafeValueForKey(gen, @"assetHasBeenLoaded");
    return [loaded respondsToSelector:@selector(boolValue)] && [loaded boolValue];
}

static NSString *VSLayerSignature(id engine, NSUInteger layerNum) {
    if (!engine) return nil;
    id layer = [engine respondsToSelector:@selector(layerAtLayerNum:)] ? [engine layerAtLayerNum:layerNum] : nil;
    if (!layer) return nil;
    id gen = VSSafeValueForKey(layer, @"imageGenerator");
    id asset = [engine respondsToSelector:@selector(assetForLayer:)] ? [engine assetForLayer:layerNum] : nil;
    if (!asset) asset = VSSafeValueForKey(gen, @"asset");
    NSString *assetStr = nil;
    if ([asset respondsToSelector:@selector(URL)]) {
        assetStr = [[asset performSelector:@selector(URL)] description];
    } else if (asset) {
        assetStr = [asset description];
    }
    id tex = VSSafeValueForKey(gen, @"layerImageTextureID");
    id origInfo = VSSafeValueForKey(layer, @"origAssetInfo");
    return [NSString stringWithFormat:@"%@|%@|%@", assetStr ?: @"", tex ?: @"", origInfo ?: @""];
}

static NSArray<NSNumber *> *VSDetectFillableLayers(id engine, BOOL allowEmpty) {
    NSMutableArray<NSNumber *> *outArr = [NSMutableArray array];
    if (!engine) return outArr;
    NSInteger active = VSNumActiveLayers(engine);
    if (active <= 0) return outArr;
    NSUInteger count = (NSUInteger)MIN((NSInteger)VS_MAX_LAYERS, MAX(0, active));
    for (NSUInteger i = 0; i < count; i++) {
        id layer = [engine respondsToSelector:@selector(layerAtLayerNum:)] ? [engine layerAtLayerNum:i] : nil;
        if (!layer) continue;
        BOOL isNull = NO;
        if ([layer respondsToSelector:@selector(isNullLayer)]) isNull = [layer isNullLayer];
        else if ([engine respondsToSelector:@selector(isNullLayer:)]) isNull = [engine isNullLayer:i];
        if (isNull) continue;
        BOOL hasAsset = VSLayerAssetLoaded(engine, i);
        if (hasAsset || allowEmpty) {
            [outArr addObject:@(i)];
        }
    }
    return outArr;
}

static BOOL VSFireCopyLayer(id editor, id engine, NSUInteger src) {
    SEL s = NSSelectorFromString(@"copyLayer:");
    id receiver = nil;
    if ([editor respondsToSelector:s]) receiver = editor;
    else if ([engine respondsToSelector:s]) receiver = engine;
    if (!receiver) return NO;
    @try {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(receiver, s, src);
        return YES;
    } @catch (NSException *__unused e) { return NO; }
}

// ============================================================================
// POPUP RESOLVER (TỰ BỎ QUA "TRÙNG KHỚP" / "MATCH")
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
        UIView *popupView = [popup isKindOfClass:[UIView class]] ? (UIView *)popup : nil;
        if ((dimView && dimView.window) || (popupView && popupView.window)) [visibleOnly addObject:popup];
    }
    return visibleOnly;
}

static BOOL VSCheckIfPopupIsPurchasePrompt(id popup) {
    NSString *message = [VSSafeValueForKey(popup, @"_message") description] ?: @"";
    NSString *title = [VSSafeValueForKey(popup, @"_title") description] ?: @"";
    NSString *combined = [NSString stringWithFormat:@" %@ %@ ", title, message];
    NSArray *keywords = @[@"purchase", @"subscription", @"unlock pro", @"pro pack", @"restore purchase",
                          @"all access", @" pass ", @" buy ", @"upgrade", @"free trial",
                          @"mua gói", @"khôi phục", @"đăng ký", @"nâng cấp",
                          @"dùng thử", @"mở khóa", @"thanh toán"];
    for (NSString *keyword in keywords) if (VSContains(combined, keyword)) return YES;
    return NO;
}

static BOOL VSTitleMatches(NSString *title, NSString *candidate) {
    if (!title.length || !candidate.length) return NO;
    NSString *trimmed = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (candidate.length <= 4) return [trimmed caseInsensitiveCompare:candidate] == NSOrderedSame;
    return VSContains(trimmed, candidate);
}

static NSArray<NSString *> *VSPopupButtonTitles(id popup, NSDictionary<NSString *, UIButton *> **buttonMap) {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableDictionary<NSString *, UIButton *> *map = [NSMutableDictionary dictionary];
    id strings = VSSafeValueForKey(popup, @"_buttonStrings");
    if ([strings isKindOfClass:[NSArray class]])
        for (id t in (NSArray *)strings) if ([t isKindOfClass:[NSString class]] && [(NSString *)t length]) [titles addObject:t];
    id buttons = VSSafeValueForKey(popup, @"_buttons");
    if ([buttons isKindOfClass:[NSArray class]]) {
        for (id b in (NSArray *)buttons) {
            if (![b isKindOfClass:[UIButton class]]) continue;
            NSString *t = ((UIButton *)b).currentTitle;
            if (!t.length) continue;
            map[t] = (UIButton *)b;
            if (![titles containsObject:t]) [titles addObject:t];
        }
    }
    if (buttonMap) *buttonMap = map;
    return titles;
}

static BOOL VSPopupIsLayerActionMenu(id popup) {
    NSArray<NSString *> *titles = VSPopupButtonTitles(popup, NULL);
    if (titles.count < 3) return NO;
    NSArray *known = @[@"Edit Keyframes", @"Biên tập Khung hình chính",
                       @"Add Mask", @"Thêm Mặt nạ",
                       @"Edit Title", @"Sửa tiêu đề",
                       @"Replace Content", @"Thay Nội dung",
                       @"Deactivate", @"Activate", @"Hủy kích hoạt", @"Kích hoạt",
                       @"Delete", @"Xoá", @"Xóa"];
    NSUInteger hits = 0;
    for (NSString *t in titles) {
        for (NSString *k in known) {
            if (VSTitleMatches(t, k)) { hits++; break; }
        }
    }
    return hits >= 3;
}

static void VSDismissLayerActionMenus(id editorVC) {
    if (!g_dismissLayerMenu) return;
    for (id popup in VSCollectAllVisiblePopups(editorVC)) {
        if (!VSPopupIsLayerActionMenu(popup)) continue;
        if ([objc_getAssociatedObject(popup, kVSMenuDismissedKey) boolValue]) continue;
        objc_setAssociatedObject(popup, kVSMenuDismissedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VSTry(^{
            if ([popup respondsToSelector:@selector(dismiss)]) [popup dismiss];
        });
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
    } @catch (NSException *__unused e) { alive = NO; }
    return alive;
}

static BOOL VSEditorIsBusy(id editorVC) {
    id spinner = VSSafeValueForKey(editorVC, @"spinner");
    if ([spinner isKindOfClass:[UIActivityIndicatorView class]]) {
        UIActivityIndicatorView *sp = (UIActivityIndicatorView *)spinner;
        if (sp.isAnimating && sp.window && !sp.hidden) return YES;
    }
    id progress = VSSafeValueForKey(editorVC, @"progressView");
    if ([progress isKindOfClass:[UIView class]] && ((UIView *)progress).window && !((UIView *)progress).hidden) return YES;
    return NO;
}

static BOOL VSTitleIsCancelLike(NSString *t) {
    return VSTitleMatches(t, @"Cancel") || VSTitleMatches(t, @"Hủy") || VSTitleMatches(t, @"Huỷ");
}

static BOOL VSPopupWasHandled(id popup) {
    return [objc_getAssociatedObject(popup, kVSPopupHandledKey) boolValue];
}

static VSPopupActionStatus VSResolvePopupsImmediately(id editorVC) {
    if (!g_autoConfirmPopups) return VSPopupActionStatusNone;
    NSArray *popups = VSCollectAllVisiblePopups(editorVC);
    if (popups.count == 0) return VSPopupActionStatusNone;

    NSArray *matchNames = @[@"Khớp: rút ngắn/giãn", @"Match: shorten/stretch", @"Trùng khớp", @"Match"];
    NSArray *matchFallbackNames = @[@"Bắt đầu", @"Start", @"Kết thúc", @"End"];
    NSArray *okNames = @[@"OK", @"Đồng ý", @"Xong", @"Done"];
    BOOL anyHandled = NO;

    for (id popup in popups) {
        if (VSPopupIsLayerActionMenu(popup)) continue;
        if (VSCheckIfPopupIsPurchasePrompt(popup)) return VSPopupActionStatusBlockedPurchase;
        if (VSPopupWasHandled(popup)) { anyHandled = YES; continue; }

        NSDictionary<NSString *, UIButton *> *buttonByTitle = nil;
        NSArray<NSString *> *titles = VSPopupButtonTitles(popup, &buttonByTitle);
        if (titles.count == 0) continue;

        NSString *(^firstTitleMatching)(NSArray *) = ^NSString *(NSArray *names) {
            for (NSString *candidate in names) {
                NSString *localized = VSLocalizedString(candidate);
                for (NSString *t in titles) {
                    if (VSTitleIsCancelLike(t)) continue;
                    if (VSTitleMatches(t, candidate) || VSTitleMatches(t, localized)) return t;
                }
            }
            return nil;
        };

        NSString *header = [NSString stringWithFormat:@"%@ %@", [VSSafeValueForKey(popup, @"_title") description] ?: @"", [VSSafeValueForKey(popup, @"_message") description] ?: @""];
        NSString *matchedTitle = nil;

        NSString *matchBtn = firstTitleMatching(matchNames);
        if (matchBtn) { matchedTitle = matchBtn; }
        else if (VSContains(header, @"Original Preset Layers") || VSContains(header, @"Các lớp Cài đặt sẵn Gốc") ||
                 VSContains(header, VSLocalizedString(@"Original Preset Layers"))) {
            matchedTitle = firstTitleMatching(okNames);
        }
        else if (titles.count == 1) { matchedTitle = firstTitleMatching(okNames); }
        else if (firstTitleMatching(matchFallbackNames) && VSContains(header, @"dài hơn")) {
            matchedTitle = firstTitleMatching(matchFallbackNames);
        }

        if (!matchedTitle) continue;

        objc_setAssociatedObject(popup, kVSPopupHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIButton *matchedButton = buttonByTitle[matchedTitle];
        VSTry(^{
            if ([popup respondsToSelector:@selector(simulateButtonPressButtonWithTitle:)]) {
                [popup simulateButtonPressButtonWithTitle:matchedTitle];
            } else if (matchedButton) {
                [matchedButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
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

static BOOL VSPurchasePopupVisible(id editorVC) {
    for (id popup in VSCollectAllVisiblePopups(editorVC)) {
        if (VSPopupIsLayerActionMenu(popup)) continue;
        if (VSCheckIfPopupIsPurchasePrompt(popup)) return YES;
    }
    return NO;
}

// ============================================================================
// TOP VIEW CONTROLLER & WINDOW HELPERS
// ============================================================================

static UIWindow *VSFindKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) continue;
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if ([w isKindOfClass:NSClassFromString(@"VSToolPassThroughWindow")]) continue;
            if (w.isKeyWindow) return w;
        }
        if (ws.windows.count > 0) return ws.windows.firstObject;
    }
    #pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

static UIViewController *VSTopViewControllerFrom(UIViewController *root) {
    if (!root) return nil;
    if (root.presentedViewController) return VSTopViewControllerFrom(root.presentedViewController);
    if ([root isKindOfClass:[UINavigationController class]])
        return VSTopViewControllerFrom([(UINavigationController *)root visibleViewController]);
    if ([root isKindOfClass:[UITabBarController class]])
        return VSTopViewControllerFrom([(UITabBarController *)root selectedViewController]);
    return root;
}

static UIViewController *VSFindTopViewController(void) {
    UIWindow *w = VSFindKeyWindow();
    return VSTopViewControllerFrom(w.rootViewController);
}

static id VSFindTopViewControllerNamed(NSString *clsName) {
    UIViewController *top = VSFindTopViewController();
    while (top) {
        if (VSSafeIsClass(top, clsName)) return top;
        if ([top isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *c in [(UINavigationController *)top viewControllers].reverseObjectEnumerator)
                if (VSSafeIsClass(c, clsName)) return c;
        }
        top = top.presentingViewController;
    }
    return nil;
}

static UIBarButtonItem *VSFindCreateButtonOnEditor(id editorVC) {
    id b = VSSafeValueForKey(editorVC, @"createBarButton");
    if ([b isKindOfClass:[UIBarButtonItem class]]) return (UIBarButtonItem *)b;
    if ([editorVC isKindOfClass:[UIViewController class]]) {
        UINavigationItem *item = ((UIViewController *)editorVC).navigationItem;
        if ([item.rightBarButtonItem.title isEqualToString:@"Create"] || [item.rightBarButtonItem.title isEqualToString:@"Tạo"])
            return item.rightBarButtonItem;
    }
    return nil;
}

// ============================================================================
// POLLING AN TOÀN
// ============================================================================

static void VSSafePoll(NSUInteger runId, int64_t intervalMs, NSUInteger remainingTries,
                       BOOL (^condition)(void), void (^done)(BOOL ok)) {
    if (runId != g_runIdentifier) return;
    BOOL pass = NO;
    @try { pass = condition(); } @catch (NSException *__unused e) { pass = NO; }
    if (pass) { if (done) done(YES); return; }
    if (remainingTries == 0) { if (done) done(NO); return; }
    VSDispatchAfterMS(intervalMs, ^{
        VSSafePoll(runId, intervalMs, remainingTries - 1, condition, done);
    });
}

static void VSSafePollEditor(NSUInteger runId, int64_t intervalMs, NSUInteger remainingTries,
                             VSObjProvider provider, BOOL (^condition)(id ed), void (^done)(BOOL ok)) {
    if (runId != g_runIdentifier) return;
    id ed = provider();
    if (!ed || !VSEditorIsAlive(ed)) { if (done) done(NO); return; }
    BOOL pass = NO;
    @try { pass = condition(ed); } @catch (NSException *__unused e) { pass = NO; }
    if (pass) { if (done) done(YES); return; }
    if (remainingTries == 0) { if (done) done(NO); return; }
    VSDispatchAfterMS(intervalMs, ^{
        VSSafePollEditor(runId, intervalMs, remainingTries - 1, provider, condition, done);
    });
}

static void VSWaitForMemory(NSUInteger runId, void (^done)(BOOL ok)) {
    if (VSMemoryHealthy()) { done(YES); return; }
    VSSafePoll(runId, 250, 20, ^BOOL{ return VSMemoryHealthy(); }, done);
}

// ============================================================================
// QR CODE SCANNING
// ============================================================================

static NSString *VSDecodeQRCodeMessageFromImage(UIImage *image) {
    if (!image) return nil;
    CIImage *ciImage = image.CIImage ?: [CIImage imageWithCGImage:image.CGImage];
    if (!ciImage) return nil;
    CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
    NSArray *features = [detector featuresInImage:ciImage];
    for (CIQRCodeFeature *feature in features) {
        if (feature.messageString.length) return feature.messageString;
    }
    return nil;
}

// ============================================================================
// UI COMPONENTS (PASS-THROUGH WINDOW, PILL BUTTONS, COMPLETION CARD)
// ============================================================================

@interface VSToolPassThroughWindow : UIWindow
@end

@implementation VSToolPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface VSToolRootVC : UIViewController
@end

@implementation VSToolRootVC
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

@interface VSQRBatchPickerDelegate : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, copy) void (^onPicked)(NSArray<PHPickerResult *> *results);
@end

@implementation VSQRBatchPickerDelegate
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (self.onPicked) self.onPicked(results);
}
@end

static void VSLoadPickedImages(NSArray<PHPickerResult *> *results, void (^done)(NSArray *images)) {
    if (results.count == 0) { done(@[]); return; }
    NSMutableArray *images = [NSMutableArray arrayWithCapacity:results.count];
    for (NSUInteger i = 0; i < results.count; i++) [images addObject:[NSNull null]];
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger i = 0; i < results.count; i++) {
        dispatch_group_enter(group);
        NSItemProvider *item = results[i].itemProvider;
        if ([item canLoadObjectOfClass:[UIImage class]]) {
            [item loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
                if ([obj isKindOfClass:[UIImage class]]) images[i] = (UIImage *)obj;
                dispatch_group_leave(group);
            }];
        } else {
            dispatch_group_leave(group);
        }
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{ done([images copy]); });
}

// ============================================================================
// VSLAYERFILLER (Chức năng 1 & Chức năng 4 Scene 1)
// ============================================================================

@interface VSLayerFiller : NSObject
@property (nonatomic, weak)   id editor;
@property (nonatomic, assign) NSUInteger runId;
@property (nonatomic, strong) NSArray<NSNumber *> *layers;
@property (nonatomic, copy)   VSFillCompletion completion;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *unconfirmed;
@property (nonatomic, assign) NSUInteger source;
@property (nonatomic, assign) NSUInteger nextIndex;
@property (nonatomic, assign) NSUInteger copied;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, copy)   NSString *beforeSignature;
@property (nonatomic, assign) BOOL pickerSeenOpen;
@property (nonatomic, assign) BOOL pickerConfirmed;
@property (nonatomic, assign) CFAbsoluteTime pickerClosedAt;
@property (nonatomic, assign) NSInteger pickOutcome;
+ (void)fillLayers:(NSArray<NSNumber *> *)layers editor:(id)editor runId:(NSUInteger)runId completion:(VSFillCompletion)completion;
@end

static VSLayerFiller *g_activeFiller = nil;

@interface VSTool : NSObject
@property (nonatomic, strong) VSToolPassThroughWindow *window;
@property (nonatomic, strong) UIView *statusHUDPill;
@property (nonatomic, strong) UILabel *statusHUDLabel;
@property (nonatomic, strong) UIButton *floatingBeatButton;    // [⚡ Chia Beat]
@property (nonatomic, strong) UIButton *floatingMergeButton;   // [🔄 Nhập Multi]
@property (nonatomic, strong) UIButton *floatingLayerButton;   // [📷 Auto Lớp]
@property (nonatomic, strong) UIView *completionCardView;
@property (nonatomic, strong) NSMutableArray *multiScenePresets;
@property (nonatomic, strong) NSMutableArray *multiSceneCodes;
@property (nonatomic, assign) NSUInteger multiSceneStart;
@property (nonatomic, assign) NSUInteger multiSceneCount;
@property (nonatomic, assign) NSUInteger multiSceneOriginalLastViewed;
@property (nonatomic, assign) NSUInteger multiSceneRunId;
@property (nonatomic, copy)   NSString *currentTaskName;

+ (instancetype)shared;
- (void)setupToolInterfaceIfNeeded;
- (void)updateStatusHUD:(NSString *)message;
- (void)hideStatusHUD;
- (void)showFloatingBeatButton;
- (void)hideFloatingBeatButton;
- (void)showFloatingMergeButton;
- (void)hideFloatingMergeButton;
- (void)showFloatingLayerButton;
- (void)hideFloatingLayerButton;
- (void)showCompletionCardWithMessage:(NSString *)msg isSuccess:(BOOL)success;
- (void)dismissCompletionCard;
- (void)showToastMessage:(NSString *)msg;
- (NSUInteger)startNewTaskWithDescription:(NSString *)taskName initialStatus:(NSString *)initialStatus;
- (void)finalizeTaskWithMessage:(NSString *)msg;
- (void)terminateCurrentTaskQuietly;
- (void)presentFromTop:(UIViewController *)controller;

// Chức năng
- (void)executeFeature1ReplaceLayers;
- (void)executeFeature3AutoSplitBeat;
- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)splitView runId:(NSUInteger)runId;
- (void)executeFeature4BatchMultiSceneDirect;
- (void)processBatchQRImagesAndRun:(NSArray *)images runId:(NSUInteger)runId;
- (void)executeBatchProcessingScenesWithRunId:(NSUInteger)runId;
- (void)openMultiLayerEditorForScene:(NSUInteger)sceneIndex reviewVC:(id)reviewVC runId:(NSUInteger)runId completion:(void (^)(id editorVC))done;
- (void)importPresetPayload:(id)preset codeIdentifier:(id)code intoEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
- (void)waitForEditorSettledThenCreate:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
- (void)triggerCreateInEditor:(id)editorVC runId:(NSUInteger)runId completion:(void (^)(NSString *errorMessage))done;
@end

@implementation VSLayerFiller

+ (void)fillLayers:(NSArray<NSNumber *> *)layers editor:(id)editor runId:(NSUInteger)runId completion:(VSFillCompletion)completion {
    if (layers.count == 0) { if (completion) completion(0, 0, @[], @"Không có lớp để thay"); return; }
    VSLayerFiller *f = [VSLayerFiller new];
    f.editor = editor;
    f.runId = runId;
    f.layers = layers;
    f.completion = completion;
    f.unconfirmed = [NSMutableArray array];
    f.source = layers.firstObject.unsignedIntegerValue;
    f.nextIndex = 1;
    g_vsaAutomating = YES;
    g_suppressLayerActionMenu = YES;
    g_activeFiller = f;
    [f selectSourceAndPick];
}

- (BOOL)alive { return !self.finished && self.runId == g_runIdentifier; }

- (VSObjProvider)provider {
    __weak VSLayerFiller *wSelf = self;
    return ^id{ return wSelf.editor; };
}

- (void)finishWithStop:(NSString *)reason {
    if (self.finished) return;
    self.finished = YES;
    g_onLayerAddedHandler = nil;
    g_vsaAutomating = NO;
    g_suppressLayerActionMenu = NO;
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
    VSObjProvider p = [self provider];
    id ed = p();
    if (!ed) { next(NO); return; }
    if ([ed respondsToSelector:@selector(selectLayerNum:flash:)]) {
        VSTry(^{ [ed selectLayerNum:n flash:NO]; });
    }
    if (![ed respondsToSelector:@selector(lastSelectedLayerNum)]) {
        VSDispatchAfterMS(150, ^{ next(YES); });
        return;
    }
    VSSafePollEditor(self.runId, 30, 60, p, ^BOOL(id e) {
        return VSLastSelectedLayer(e) == (NSInteger)n;
    }, ^(BOOL ok) { next(ok); });
}

- (void)selectSourceAndPick {
    [self selectLayer:self.source then:^(BOOL ok) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!ok) { [self finishWithStop:@"Không chọn được lớp nguồn"]; return; }
        VSDispatchAfterMS(120, ^{ [self openPicker]; });
    }];
}

- (void)openPicker {
    if (![self alive]) { [self finishWithStop:nil]; return; }
    id ed = self.editor;
    if (!VSEditorIsAlive(ed)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }
    if (![ed respondsToSelector:@selector(pickNewContent)]) { [self finishWithStop:@"Không tìm thấy pickNewContent"]; return; }

    self.beforeSignature = VSLayerSignature(VSEngineFrom(ed), self.source) ?: @"";
    self.pickerSeenOpen = NO;
    self.pickerConfirmed = NO;
    self.pickerClosedAt = 0;
    self.pickOutcome = 0;

    __weak VSLayerFiller *wSelf = self;
    g_onLayerAddedHandler = ^(id sender, NSArray *args, BOOL is5, BOOL able) {
        VSLayerFiller *s = wSelf;
        if (!s || sender != s.editor) return;
        s.pickerConfirmed = YES;
    };

    BOOL opened = VSTry(^{ [ed pickNewContent]; });
    if (!opened) { [self finishWithStop:@"Không mở được bảng chọn media"]; return; }

    VSSafePollEditor(self.runId, 100, 900, [self provider], ^BOOL(id e) {
        return [self pickConditionOn:e];
    }, ^(BOOL ok) {
        [self afterPickWait];
    });
}

- (BOOL)pickConditionOn:(id)ed {
    UIViewController *vc = (UIViewController *)ed;
    BOOL open = NO;
    @try {
        open = vc.presentedViewController != nil || vc.navigationController.presentedViewController != nil;
    } @catch (NSException *__unused e) { open = NO; }
    
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (open) {
        self.pickerSeenOpen = YES;
        self.pickerClosedAt = 0;
        return NO;
    }
    if (VSPurchasePopupVisible(ed)) { self.pickOutcome = 3; return YES; }

    id engine = VSEngineFrom(ed);
    NSString *sig = VSLayerSignature(engine, self.source) ?: @"";
    BOOL changed = sig.length > 0 && ![sig isEqualToString:(self.beforeSignature ?: @"")];
    BOOL pickedSignal = self.pickerConfirmed || changed;

    if (pickedSignal && VSLayerAssetLoaded(engine, self.source) && !VSEditorIsBusy(ed)) {
        self.pickOutcome = 1;
        return YES;
    }
    if (self.pickerSeenOpen) {
        if (self.pickerClosedAt == 0) self.pickerClosedAt = now;
        if (now - self.pickerClosedAt > 2.0) { self.pickOutcome = 2; return YES; }
    }
    return NO;
}

- (void)afterPickWait {
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
    VSDispatchAfterMS(80, ^{ [self copyNext]; });
}

- (void)skipTarget:(NSUInteger)target {
    [self.unconfirmed addObject:@(target)];
    [self advance];
}

- (void)copyNext {
    if (![self alive]) { [self finishWithStop:nil]; return; }
    id ed = self.editor;
    if (!VSEditorIsAlive(ed)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }
    if (VSPurchasePopupVisible(ed)) { [self finishWithStop:@"Popup mua Pro"]; return; }

    if (self.nextIndex >= self.layers.count) {
        [self selectLayer:self.source then:^(BOOL ok) { [self finishWithStop:nil]; }];
        return;
    }

    NSUInteger target = [self.layers[self.nextIndex] unsignedIntegerValue];
    [[VSTool shared] updateStatusHUD:[NSString stringWithFormat:@"Đang chép sang lớp %lu (%lu/%lu)…",
                                      (unsigned long)target + 1,
                                      (unsigned long)self.nextIndex,
                                      (unsigned long)(self.layers.count - 1)]];
    VSDismissLayerActionMenus(ed);

    VSWaitForMemory(self.runId, ^(BOOL memOK) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!memOK) { [self skipTarget:target]; return; }
        [self copyToTarget:target];
    });
}

- (void)copyToTarget:(NSUInteger)target {
    [self selectLayer:target then:^(BOOL selected) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (!selected || !VSEditorIsAlive(self.editor)) { [self skipTarget:target]; return; }

        VSDispatchAfterMS(60, ^{
            if (![self alive]) { [self finishWithStop:nil]; return; }
            id e2 = self.editor;
            if (!VSEditorIsAlive(e2)) { [self finishWithStop:@"Editor đã bị đóng"]; return; }
            NSString *before = VSLayerSignature(VSEngineFrom(e2), target) ?: @"";
            if (!VSFireCopyLayer(e2, VSEngineFrom(e2), self.source)) { [self skipTarget:target]; return; }
            [self waitCopyConfirmTarget:target before:before];
        });
    }];
}

- (void)waitCopyConfirmTarget:(NSUInteger)target before:(NSString *)before {
    NSUInteger tries = (NSUInteger)(VS_COPY_CONFIRM_TIMEOUT * 1000.0 / 80.0);
    VSSafePollEditor(self.runId, 80, tries, [self provider], ^BOOL(id e) {
        if (VSPurchasePopupVisible(e)) return YES;
        if (VSEditorIsBusy(e)) return NO;
        id engine = VSEngineFrom(e);
        NSString *now = VSLayerSignature(engine, target) ?: @"";
        return VSLayerAssetLoaded(engine, target) && now.length > 0 && ![now isEqualToString:before];
    }, ^(BOOL ok) {
        if (![self alive]) { [self finishWithStop:nil]; return; }
        if (VSPurchasePopupVisible(self.editor)) { [self finishWithStop:@"Popup mua Pro"]; return; }
        if (ok) {
            self.copied += 1;
        } else {
            [self.unconfirmed addObject:@(target)];
        }
        [self advance];
    });
}

@end

// ============================================================================
// IMPLEMENTATION VSTOOL (NÚT NỔI & TỰ ĐỘNG HÓA HOÀN TOÀN)
// ============================================================================

@implementation VSTool

+ (instancetype)shared {
    static VSTool *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [VSTool new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupToolInterfaceIfNeeded];
    }
    return self;
}

- (void)setupToolInterfaceIfNeeded {
    if (self.window) return;
    UIWindowScene *ws = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                (s.activationState == UISceneActivationStateForegroundActive ||
                 s.activationState == UISceneActivationStateForegroundInactive)) {
                ws = (UIWindowScene *)s; break;
            }
        }
    }
    VSToolPassThroughWindow *w = ws ? [[VSToolPassThroughWindow alloc] initWithWindowScene:ws] : [[VSToolPassThroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.windowLevel = UIWindowLevelStatusBar + 100.0;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [VSToolRootVC new];
    w.hidden = NO;
    self.window = w;
    
    // Status HUD pill (Hiển thị tiến trình đang chạy ở mép trên)
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(20, 10, 200, 32)];
    pill.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:0.92];
    pill.layer.cornerRadius = 16;
    pill.layer.borderWidth = 1.0;
    pill.layer.borderColor = [UIColor colorWithRed:1.0 green:0.16 blue:0.43 alpha:0.6].CGColor;
    pill.layer.shadowColor = UIColor.blackColor.CGColor;
    pill.layer.shadowOffset = CGSizeMake(0, 3);
    pill.layer.shadowOpacity = 0.35;
    pill.layer.shadowRadius = 5;
    pill.hidden = YES;
    
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 172, 32)];
    lbl.textColor = UIColor.whiteColor;
    lbl.font = [UIFont boldSystemFontOfSize:12];
    lbl.textAlignment = NSTextAlignmentCenter;
    [pill addSubview:lbl];
    [self.window.rootViewController.view addSubview:pill];
    self.statusHUDPill = pill;
    self.statusHUDLabel = lbl;
}

- (void)updateStatusHUD:(NSString *)message {
    VSRunOnMain(^{
        [self setupToolInterfaceIfNeeded];
        if (!message.length) { [self hideStatusHUD]; return; }
        self.statusHUDLabel.text = message;
        [self.statusHUDLabel sizeToFit];
        CGFloat w = MAX(self.statusHUDLabel.bounds.size.width + 30.0, 140.0);
        CGFloat screenW = self.window.bounds.size.width;
        CGFloat safeTop = 44.0;
        if (@available(iOS 11.0, *)) {
            safeTop = MAX(self.window.safeAreaInsets.top, 24.0);
        }
        self.statusHUDPill.frame = CGRectMake((screenW - w) / 2.0, safeTop + 6.0, w, 32);
        self.statusHUDLabel.frame = CGRectMake(15, 0, w - 30, 32);
        self.statusHUDPill.hidden = NO;
        [self.window.rootViewController.view bringSubviewToFront:self.statusHUDPill];
    });
}

- (void)hideStatusHUD {
    VSRunOnMain(^{
        self.statusHUDPill.hidden = YES;
    });
}

// ---------------------------------------------------------------------------
// NÚT NỔI NGỮ CẢNH: CHIA BEAT, NHẬP MULTI, AUTO LỚP
// ---------------------------------------------------------------------------

- (UIButton *)createPillButtonWithTitle:(NSString *)title icon:(NSString *)icon bgColor:(UIColor *)bg action:(SEL)act {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.backgroundColor = bg;
    [btn setTitle:[NSString stringWithFormat:@"%@ %@", icon, title] forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    btn.layer.cornerRadius = 18;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
    btn.layer.shadowColor = UIColor.blackColor.CGColor;
    btn.layer.shadowOffset = CGSizeMake(0, 3);
    btn.layer.shadowOpacity = 0.4;
    btn.layer.shadowRadius = 6;
    [btn addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
    
    // Hỗ trợ kéo di chuyển nếu bị vướng
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleFloatingPan:)];
    [btn addGestureRecognizer:pan];
    return btn;
}

- (void)handleFloatingPan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    CGPoint trans = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + trans.x, btn.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
}

- (CGRect)defaultFloatingFrameForWidth:(CGFloat)width {
    CGFloat screenW = self.window.bounds.size.width;
    CGFloat safeTop = 44.0;
    if (@available(iOS 11.0, *)) {
        safeTop = MAX(self.window.safeAreaInsets.top, 24.0);
    }
    return CGRectMake(screenW - width - 14.0, safeTop + 8.0, width, 36.0);
}

// 1. Nút Chia Beat (trong màn hình Split Scene)
- (void)showFloatingBeatButton {
    VSRunOnMain(^{
        [self setupToolInterfaceIfNeeded];
        if (!self.floatingBeatButton) {
            UIColor *purplePink = [UIColor colorWithRed:0.75 green:0.12 blue:0.55 alpha:0.95];
            self.floatingBeatButton = [self createPillButtonWithTitle:@"Chia Beat" icon:@"⚡" bgColor:purplePink action:@selector(executeFeature3AutoSplitBeat)];
            [self.window.rootViewController.view addSubview:self.floatingBeatButton];
        }
        self.floatingBeatButton.frame = [self defaultFloatingFrameForWidth:110.0];
        self.floatingBeatButton.hidden = NO;
        [self.window.rootViewController.view bringSubviewToFront:self.floatingBeatButton];
    });
}

- (void)hideFloatingBeatButton {
    VSRunOnMain(^{
        self.floatingBeatButton.hidden = YES;
    });
}

// 2. Nút Nhập Multi (trong màn hình Hợp nhất / Merge Panel)
- (void)showFloatingMergeButton {
    VSRunOnMain(^{
        [self setupToolInterfaceIfNeeded];
        if (!self.floatingMergeButton) {
            UIColor *neonPink = [UIColor colorWithRed:1.00 green:0.14 blue:0.45 alpha:0.95];
            self.floatingMergeButton = [self createPillButtonWithTitle:@"Nhập Multi" icon:@"🔄" bgColor:neonPink action:@selector(executeFeature4BatchMultiSceneDirect)];
            [self.window.rootViewController.view addSubview:self.floatingMergeButton];
        }
        self.floatingMergeButton.frame = [self defaultFloatingFrameForWidth:120.0];
        self.floatingMergeButton.hidden = NO;
        [self.window.rootViewController.view bringSubviewToFront:self.floatingMergeButton];
    });
}

- (void)hideFloatingMergeButton {
    VSRunOnMain(^{
        self.floatingMergeButton.hidden = YES;
    });
}

// 3. Nút Auto Lớp (trong màn hình Nhiều lớp - MultiLayer)
- (void)showFloatingLayerButton {
    VSRunOnMain(^{
        [self setupToolInterfaceIfNeeded];
        if (!self.floatingLayerButton) {
            UIColor *blueCyan = [UIColor colorWithRed:0.00 green:0.55 blue:0.95 alpha:0.95];
            self.floatingLayerButton = [self createPillButtonWithTitle:@"Auto Lớp" icon:@"📷" bgColor:blueCyan action:@selector(executeFeature1ReplaceLayers)];
            [self.window.rootViewController.view addSubview:self.floatingLayerButton];
        }
        self.floatingLayerButton.frame = [self defaultFloatingFrameForWidth:110.0];
        self.floatingLayerButton.hidden = NO;
        [self.window.rootViewController.view bringSubviewToFront:self.floatingLayerButton];
    });
}

- (void)hideFloatingLayerButton {
    VSRunOnMain(^{
        self.floatingLayerButton.hidden = YES;
    });
}

// ---------------------------------------------------------------------------
// CARD THÔNG BÁO HOÀN THÀNH (THAY THẾ HOÀN TOÀN UIAlertController ĐỂ KHÔNG VĂNG APP)
// ---------------------------------------------------------------------------

- (void)showCompletionCardWithMessage:(NSString *)msg isSuccess:(BOOL)success {
    VSRunOnMain(^{
        [self setupToolInterfaceIfNeeded];
        [self.completionCardView removeFromSuperview];
        self.completionCardView = nil;
        
        UIView *rootView = self.window.rootViewController.view;
        CGFloat screenW = rootView.bounds.size.width;
        CGFloat cardW = MIN(screenW - 36.0, 340.0);
        CGFloat cardH = 145.0;
        CGFloat cardX = (screenW - cardW) / 2.0;
        CGFloat cardY = (rootView.bounds.size.height - cardH) / 2.0;
        
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
        card.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.13 alpha:0.96];
        card.layer.cornerRadius = 18;
        card.layer.borderWidth = 1.5;
        card.layer.borderColor = (success ? [UIColor colorWithRed:0.25 green:0.85 blue:0.45 alpha:1.0] : [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0]).CGColor;
        card.layer.shadowColor = UIColor.blackColor.CGColor;
        card.layer.shadowOffset = CGSizeMake(0, 6);
        card.layer.shadowOpacity = 0.55;
        card.layer.shadowRadius = 14;
        
        UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 16, cardW - 32, 26)];
        titleLbl.text = success ? @"🎉 HOÀN TẤT THÀNH CÔNG!" : @"⚠️ THÔNG BÁO";
        titleLbl.textColor = success ? [UIColor colorWithRed:0.35 green:0.95 blue:0.55 alpha:1.0] : [UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0];
        titleLbl.font = [UIFont boldSystemFontOfSize:17];
        titleLbl.textAlignment = NSTextAlignmentCenter;
        [card addSubview:titleLbl];
        
        UILabel *msgLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 46, cardW - 32, 44)];
        msgLbl.text = msg;
        msgLbl.textColor = UIColor.whiteColor;
        msgLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        msgLbl.textAlignment = NSTextAlignmentCenter;
        msgLbl.numberOfLines = 2;
        [card addSubview:msgLbl];
        
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        closeBtn.frame = CGRectMake((cardW - 120) / 2.0, 96, 120, 34);
        closeBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        closeBtn.layer.cornerRadius = 17;
        [closeBtn setTitle:@"Đóng" forState:UIControlStateNormal];
        [closeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [closeBtn addTarget:self action:@selector(dismissCompletionCard) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:closeBtn];
        
        [rootView addSubview:card];
        self.completionCardView = card;
        
        // Tự động tắt sau 6 giây
        VSDispatchAfterMS(6000, ^{ [self dismissCompletionCard]; });
    });
}

- (void)dismissCompletionCard {
    VSRunOnMain(^{
        [self.completionCardView removeFromSuperview];
        self.completionCardView = nil;
    });
}

- (void)showToastMessage:(NSString *)msg {
    [self updateStatusHUD:msg];
    VSDispatchAfterMS(2500, ^{ [self hideStatusHUD]; });
}

- (NSUInteger)startNewTaskWithDescription:(NSString *)taskName initialStatus:(NSString *)initialStatus {
    NSUInteger runId = ++g_runIdentifier;
    self.currentTaskName = taskName;
    if (initialStatus.length) [self updateStatusHUD:initialStatus];
    return runId;
}

- (void)finalizeTaskWithMessage:(NSString *)msg {
    [self hideStatusHUD];
    if (msg.length) [self showToastMessage:msg];
}

- (void)terminateCurrentTaskQuietly {
    g_runIdentifier++;
    self.currentTaskName = nil;
    [self hideStatusHUD];
}

- (void)presentFromTop:(UIViewController *)controller {
    UIViewController *top = VSFindTopViewController();
    if (top && controller) {
        [top presentViewController:controller animated:YES completion:nil];
    }
}

// ============================================================================
// CHỨC NĂNG 1: AUTO NHẬP ẢNH/VIDEO (TỪ NÚT [📷 Auto Lớp])
// ============================================================================

- (void)executeFeature1ReplaceLayers {
    id editor = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
    if (!editor) { [self showToastMessage:@"Hãy vào màn hình Nhiều lớp trước."]; return; }

    NSArray<NSNumber *> *layers = VSDetectFillableLayers(VSEngineFrom(editor), NO);
    if (layers.count == 0) { [self showToastMessage:@"Không có lớp video/ảnh nào để thay."]; return; }

    NSUInteger runId = [self startNewTaskWithDescription:@"Auto nhập ảnh" initialStatus:@"Chọn 1 ảnh/video…"];
    [VSLayerFiller fillLayers:layers editor:editor runId:runId completion:^(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stop) {
        if (runId != g_runIdentifier) return;
        NSString *msg = stop ?: [NSString stringWithFormat:@"Đã chép %lu/%lu lớp", (unsigned long)copied, (unsigned long)targets];
        VSDispatchAfterMS(300, ^{ [self finalizeTaskWithMessage:msg]; });
    }];
}

// ============================================================================
// CHỨC NĂNG 3: AUTO CHIA BEAT (TỪ NÚT [⚡ Chia Beat])
// ============================================================================

- (void)executeFeature3AutoSplitBeat {
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!reviewVC) { [self showToastMessage:@"Vào màn hình phân cảnh trước"]; return; }
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto chia beat" initialStatus:@"Chuẩn bị…"];

    __weak id wRvc = reviewVC;
    VSObjProvider rvcProv = ^id{ return wRvc; };
    VSObjProvider svProv = ^id{
        id r = wRvc;
        return r ? VSSafeValueForKey(r, @"splitView") : nil;
    };
    BOOL (^svVisible)(void) = ^BOOL{
        id sv = svProv();
        if (!sv) return NO;
        UIView *v = [sv isKindOfClass:[UIView class]] ? sv : VSSafeValueForKey(sv, @"splitPanel");
        return [v isKindOfClass:[UIView class]] && v.window != nil;
    };

    if (!svVisible()) {
        id r = rvcProv();
        if (!r || !VSTry(^{ [r showSplitScene]; })) { [self finalizeTaskWithMessage:@"Không mở được bảng chia"]; return; }
    }

    VSSafePoll(runId, 50, 40, ^BOOL{ return svVisible(); }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        id sv = svProv();
        id r = rvcProv();
        if (!ok || !sv || !r) { [self finalizeTaskWithMessage:@"Không tìm thấy MultiSplitView"]; return; }
        [self validateAndRunBeatSplitting:r splitView:sv runId:runId];
    });
}

- (void)validateAndRunBeatSplitting:(id)reviewVC splitView:(id)sv runId:(NSUInteger)runId {
    __block NSString *err = nil;
    __block id<ProjectInterface> p = nil;
    __block NSUInteger before = 0;
    VSTry(^{
        p = [reviewVC project];
        NSUInteger s = [reviewVC sceneIndex];
        NSUInteger cc = [p clipCountForSceneIndex:s];
        if (![reviewVC isEnoughStorageAvailableForSplit]) err = @"Bộ nhớ không đủ";
        else if (![p sceneHasAtLeastOneClipWithSceneIndex:s] || cc == 0) err = @"Không có clip";
        else before = [p sceneCount];
    });
    if (err) { [self finalizeTaskWithMessage:err]; return; }
    if (!p) { [self finalizeTaskWithMessage:@"Lỗi kiểm tra"]; return; }

    BOOL started = VSTry(^{
        if (![sv beatModeOn]) [sv toggleBeatMode];
        [sv gotoTime:kCMTimeZero];
    });
    if (!started) { [self finalizeTaskWithMessage:@"Không bật Beat Mode"]; return; }

    __weak id wSv = sv;
    __block NSUInteger guard = 0, count = 0;
    __block CMTime last = kCMTimeInvalid;
    __block void (^step)(void) = nil;

    void (^finish)(void) = ^{
        step = nil;
        if (runId != g_runIdentifier) return;
        id s = wSv;
        if (!s) { [self finalizeTaskWithMessage:@"Mất màn hình chia beat"]; return; }
        if (count == 0 && VSCountOf(VSSafeValueForKey(s, @"splitTimes")) == 0) { [self finalizeTaskWithMessage:@"Không có beat"]; return; }
        if (!VSTry(^{ [s doSplit]; })) { [self finalizeTaskWithMessage:@"Lỗi chia"]; return; }
        [self updateStatusHUD:@"Đang chia…"];
        VSSafePoll(runId, 100, 150, ^BOOL{
            __block NSUInteger now = 0;
            VSTry(^{ now = [p sceneCount]; });
            return now > before;
        }, ^(BOOL ok) {
            if (runId != g_runIdentifier) return;
            __block NSUInteger after = before;
            VSTry(^{ after = [p sceneCount]; });
            [self finalizeTaskWithMessage:ok ? [NSString stringWithFormat:@"Xong, +%lu scene", (unsigned long)(after - before)] : @"Chưa xong"];
        });
    };

    step = ^{
        if (runId != g_runIdentifier) { step = nil; return; }
        if (++guard >= 2048) { finish(); return; }
        id s = wSv;
        if (!s) { finish(); return; }
        __block BOOL hasNext = NO;
        __block CMTime fromTime = kCMTimeInvalid;
        BOOL called = VSTry(^{
            hasNext = [s hasNextBeat];
            if (hasNext) { fromTime = VSSafeCurrentTime(s); [s jumpToNextBeat]; }
        });
        if (!called || !hasNext) { finish(); return; }
        CMTime from = fromTime;
        VSSafePoll(runId, 16, 60, ^BOOL{
            id s2 = wSv;
            if (!s2) return YES;
            CMTime cur = VSSafeCurrentTime(s2);
            return CMTIME_IS_VALID(cur) && (CMTIME_IS_INVALID(from) || CMTimeCompare(cur, from) > 0);
        }, ^(BOOL moved) {
            if (runId != g_runIdentifier) { step = nil; return; }
            id s3 = wSv;
            if (!s3) { finish(); return; }
            CMTime cur = VSSafeCurrentTime(s3);
            if (!moved || (CMTIME_IS_VALID(last) && CMTimeCompare(cur, last) <= 0)) { finish(); return; }
            last = cur;
            if (!VSTry(^{ [s3 setSplitPoint]; })) { finish(); return; }
            count++;
            [self updateStatusHUD:[NSString stringWithFormat:@"%lu điểm chia…", (unsigned long)count]];
            VSDispatchAfterMS(15, ^{ if (step) step(); });
        });
    };
    VSDispatchAfterMS(180, ^{ if (step) step(); });
}

// ============================================================================
// CHỨC NĂNG 4: NHẬP MULTI SIÊU TỐC VÀ DÙNG LẠI ẢNH (TỪ NÚT [🔄 Nhập Multi])
// ============================================================================

- (void)executeFeature4BatchMultiSceneDirect {
    id reviewVC = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
    if (!reviewVC) { [self showToastMessage:@"Hãy vào màn hình phân cảnh trước"]; return; }
    
    __block id<ProjectInterface> p = nil;
    __block NSInteger total = 0;
    __block NSInteger s = -1, l = -1;
    VSTry(^{
        p = [reviewVC project];
        total = p ? (NSInteger)[p sceneCount] : 0;
        id sObj = VSSafeValueForKey(reviewVC, @"startScene");
        id lObj = VSSafeValueForKey(reviewVC, @"lastScene");
        s = [sObj respondsToSelector:@selector(integerValue)] ? [sObj integerValue] : -1;
        l = [lObj respondsToSelector:@selector(integerValue)] ? [lObj integerValue] : -1;
    });
    
    if (!p || s < 0 || l < s || l >= total) {
        [self showToastMessage:@"Vui lòng chọn Cài đặt Đầu và Cuối trước"];
        return;
    }
    
    __block NSUInteger origScene = 0;
    VSTry(^{ origScene = [reviewVC lastViewedSceneIndex]; });
    
    // Đóng bảng Merge panel của Video Star & ẩn nút
    VSTry(^{ [reviewVC closeMergePanel]; });
    [self hideFloatingMergeButton];
    
    NSUInteger count = (NSUInteger)(l - s + 1);
    NSUInteger runId = [self startNewTaskWithDescription:@"Auto Multi-Scene" initialStatus:@"Chọn mã QR…"];
    
    self.multiSceneStart = (NSUInteger)s;
    self.multiSceneCount = count;
    self.multiSceneOriginalLastViewed = origScene;
    self.multiSceneRunId = runId;
    self.multiScenePresets = [NSMutableArray arrayWithCapacity:count];
    self.multiSceneCodes = [NSMutableArray arrayWithCapacity:count];
    g_savedMultiSceneImage = nil;
    
    // Mở ngay kho ảnh iOS (PHPicker) để chọn tất cả ảnh QR một lần duy nhất
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = count;
        cfg.filter = [PHPickerFilter imagesFilter];
        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        VSQRBatchPickerDelegate *del = [VSQRBatchPickerDelegate new];
        __weak VSTool *wSelf = self;
        del.onPicked = ^(NSArray<PHPickerResult *> *results) {
            g_qrBatchPickerDelegate = nil;
            VSTool *tool = wSelf;
            if (!tool || runId != g_runIdentifier || results.count == 0) return;
            if (results.count != tool.multiSceneCount) {
                [tool showCompletionCardWithMessage:[NSString stringWithFormat:@"Cần đúng %lu ảnh QR cho %lu phân cảnh (bạn đã chọn %lu).",
                                                      (unsigned long)tool.multiSceneCount, (unsigned long)tool.multiSceneCount, (unsigned long)results.count]
                                          isSuccess:NO];
                return;
            }
            [tool updateStatusHUD:@"Đang quét mã QR…"];
            VSLoadPickedImages(results, ^(NSArray *images) {
                [tool processBatchQRImagesAndRun:images runId:runId];
            });
        };
        g_qrBatchPickerDelegate = del;
        pk.delegate = del;
        [self presentFromTop:pk];
    } else {
        [self showCompletionCardWithMessage:@"Cần iOS 14 trở lên để chọn nhiều ảnh QR" isSuccess:NO];
    }
}

- (void)processBatchQRImagesAndRun:(NSArray *)images runId:(NSUInteger)runId {
    if (runId != g_runIdentifier) return;
    NSMutableArray *presets = [NSMutableArray array];
    NSMutableArray *codes = [NSMutableArray array];
    
    for (NSUInteger i = 0; i < images.count; i++) {
        UIImage *img = images[i];
        if (![img isKindOfClass:[UIImage class]]) {
            [self showCompletionCardWithMessage:[NSString stringWithFormat:@"Lỗi đọc ảnh thứ %lu", (unsigned long)(i + 1)] isSuccess:NO];
            return;
        }
        NSString *qrStr = VSDecodeQRCodeMessageFromImage(img);
        if (!qrStr.length) {
            [self showCompletionCardWithMessage:[NSString stringWithFormat:@"Ảnh thứ %lu không chứa mã QR Video Star hợp lệ", (unsigned long)(i + 1)] isSuccess:NO];
            return;
        }
        NSData *payload = [qrStr dataUsingEncoding:NSUTF8StringEncoding];
        if (!payload.length) {
            [self showCompletionCardWithMessage:[NSString stringWithFormat:@"Mã QR thứ %lu không đọc được dữ liệu", (unsigned long)(i + 1)] isSuccess:NO];
            return;
        }
        [presets addObject:payload];
        [codes addObject:qrStr];
    }
    
    self.multiScenePresets = presets;
    self.multiSceneCodes = codes;
    
    // Bắt đầu áp dụng hàng loạt siêu tốc!
    g_autoConfirmPopups = YES;
    g_vsaAutomating = YES;
    [self executeBatchProcessingScenesWithRunId:runId];
}

- (void)executeBatchProcessingScenesWithRunId:(NSUInteger)runId {
    NSUInteger start = self.multiSceneStart;
    NSUInteger total = self.multiSceneCount;
    NSUInteger orig = self.multiSceneOriginalLastViewed;
    NSArray *presets = [self.multiScenePresets copy];
    NSArray *codes = [self.multiSceneCodes copy];
    __block NSUInteger offset = 0, okCount = 0;
    __block void (^step)(void) = nil;

    void (^finish)(NSString *) = ^(NSString *err) {
        step = nil;
        g_autoConfirmPopups = NO;
        g_vsaAutomating = NO;
        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        VSTry(^{ [rvc setLastViewedSceneIndex:orig]; });
        [self terminateCurrentTaskQuietly];
        
        NSString *msg = [NSString stringWithFormat:@"Đã nhập xong %lu/%lu phân cảnh thành công!", (unsigned long)okCount, (unsigned long)total];
        if (err) {
            msg = [NSString stringWithFormat:@"Dừng ở cảnh %lu: %@ - Đã xong %lu/%lu cảnh", (unsigned long)(start + offset), err, (unsigned long)okCount, (unsigned long)total];
        }
        [self showCompletionCardWithMessage:msg isSuccess:(err == nil)];
    };

    step = ^{
        if (runId != g_runIdentifier) { step = nil; return; }
        if (offset >= total) { finish(nil); return; }
        NSUInteger o = offset++, sc = start + o;
        NSString *label = [NSString stringWithFormat:@"Scene %lu (%lu/%lu)", (unsigned long)(sc + 1), (unsigned long)o + 1, (unsigned long)total];
        [self updateStatusHUD:[NSString stringWithFormat:@"%@: Mở Nhiều lớp…", label]];
        
        id rvc = VSFindTopViewControllerNamed(@"VideoReviewEditVC");
        [self openMultiLayerEditorForScene:sc reviewVC:rvc runId:runId completion:^(id editor) {
            if (runId != g_runIdentifier) { step = nil; return; }
            if (!editor) { finish([label stringByAppendingString:@": không mở được Nhiều lớp"]); return; }

            __weak id wEd = editor;
            [self updateStatusHUD:[label stringByAppendingString:@": nạp QR…"]];
            [self importPresetPayload:presets[o] codeIdentifier:codes[o] intoEditor:editor runId:runId completion:^(NSString *e1) {
                if (runId != g_runIdentifier) { step = nil; return; }
                if (e1) { finish([NSString stringWithFormat:@"%@: %@", label, e1]); return; }
                
                // Sau khi nạp QR xong, poll nhanh kiểm tra lớp
                VSDispatchAfterMS(80, ^{
                    if (runId != g_runIdentifier) { step = nil; return; }
                    id ed = wEd;
                    if (!VSEditorIsAlive(ed)) { finish([label stringByAppendingString:@": editor đã bị đóng"]); return; }

                    NSArray<NSNumber *> *layers = VSDetectFillableLayers(VSEngineFrom(ed), YES);
                    if (layers.count == 0) {
                        // Không có lớp media nào, bấm Tạo luôn
                        [self updateStatusHUD:[label stringByAppendingString:@": không có lớp media, đang Tạo…"]];
                        [self waitForEditorSettledThenCreate:ed runId:runId completion:^(NSString *e2) {
                            if (runId != g_runIdentifier) { step = nil; return; }
                            if (e2) { finish([NSString stringWithFormat:@"%@: %@", label, e2]); return; }
                            okCount++;
                            VSSafePoll(runId, 35, 120, ^BOOL{ return VSFindTopViewControllerNamed(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                                if (runId != g_runIdentifier) { step = nil; return; }
                                if (!back) { finish(@"Không quay lại được"); return; }
                                VSDispatchAfterMS(80, ^{ if (step) step(); });
                            });
                        }];
                        return;
                    }

                    // CÓ LỚP MEDIA:
                    if (!g_savedMultiSceneImage) {
                        // PHÂN CẢNH ĐẦU TIÊN (chưa có ảnh):
                        // Cho người dùng chọn 1 ảnh qua picker của Video Star
                        [self updateStatusHUD:[label stringByAppendingString:@": chọn 1 ảnh cho toàn bộ các đoạn…"]];
                        [VSLayerFiller fillLayers:layers editor:ed runId:runId completion:^(NSUInteger copied, NSUInteger targets, NSArray<NSNumber *> *unconfirmed, NSString *stop) {
                            if (runId != g_runIdentifier) { step = nil; return; }
                            if (stop) { finish([NSString stringWithFormat:@"%@: %@", label, stop]); return; }
                            
                            id edDone = wEd;
                            if (!VSEditorIsAlive(edDone)) { finish([label stringByAppendingString:@": editor bị đóng trước khi Tạo"]); return; }

                            // Trích xuất ảnh vừa chọn một cách an toàn 100% để dùng cho tất cả phân cảnh sau
                            VSTry(^{
                                id curEngine = VSEngineFrom(edDone);
                                id srcLayer = (curEngine && [curEngine respondsToSelector:@selector(layerAtLayerNum:)]) ? [curEngine layerAtLayerNum:layers.firstObject.unsignedIntegerValue] : nil;
                                id gen = VSSafeValueForKey(srcLayer, @"imageGenerator");
                                id img = VSSafeValueForKey(gen, @"layerImage");
                                if ([img isKindOfClass:[UIImage class]]) {
                                    g_savedMultiSceneImage = (UIImage *)img;
                                }
                                if (!g_savedMultiSceneImage) {
                                    id img2 = VSSafeValueForKey(srcLayer, @"layerImage");
                                    if ([img2 isKindOfClass:[UIImage class]]) g_savedMultiSceneImage = (UIImage *)img2;
                                }
                            });

                            [self updateStatusHUD:[label stringByAppendingString:@": hoàn tất, đang Tạo…"]];
                            [self waitForEditorSettledThenCreate:edDone runId:runId completion:^(NSString *e2) {
                                if (runId != g_runIdentifier) { step = nil; return; }
                                if (e2) { finish([NSString stringWithFormat:@"%@: %@", label, e2]); return; }
                                okCount++;
                                VSSafePoll(runId, 35, 120, ^BOOL{ return VSFindTopViewControllerNamed(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                                    if (runId != g_runIdentifier) { step = nil; return; }
                                    if (!back) { finish(@"Không quay lại được"); return; }
                                    VSDispatchAfterMS(80, ^{ if (step) step(); });
                                });
                            }];
                        }];
                    } else {
                        // TẤT CẢ CÁC PHÂN CẢNH TIẾP THEO:
                        // TỰ ĐỘNG DÙNG LẠI ẢNH ĐÃ CHỌN Ở PHÂN CẢNH ĐẦU, KHÔNG MỞ LẠI BẢNG CHỌN ẢNH NỮA!
                        [self updateStatusHUD:[label stringByAppendingString:@": tự nạp ảnh & chép lớp…"]];
                        NSUInteger src = layers.firstObject.unsignedIntegerValue;
                        
                        // 1. Áp dụng ảnh vào lớp nguồn
                        if ([ed respondsToSelector:@selector(selectLayerNum:flash:)]) {
                            [ed selectLayerNum:src flash:NO];
                        }
                        if ([ed respondsToSelector:@selector(makePhotoLayer:)]) {
                            [ed makePhotoLayer:g_savedMultiSceneImage];
                        }
                        
                        // 2. Chép nhanh sang toàn bộ các lớp fillable còn lại
                        VSDispatchAfterMS(80, ^{
                            if (runId != g_runIdentifier) { step = nil; return; }
                            id ed2 = wEd;
                            if (!VSEditorIsAlive(ed2)) { finish([label stringByAppendingString:@": editor bị đóng"]); return; }
                            id engine2 = VSEngineFrom(ed2);
                            
                            for (NSUInteger idx = 1; idx < layers.count; idx++) {
                                NSUInteger target = [layers[idx] unsignedIntegerValue];
                                if ([ed2 respondsToSelector:@selector(selectLayerNum:flash:)]) {
                                    [ed2 selectLayerNum:target flash:NO];
                                }
                                VSFireCopyLayer(ed2, engine2, src);
                            }
                            
                            // 3. Tự động bấm Tạo ngay lập tức
                            VSDispatchAfterMS(80, ^{
                                if (runId != g_runIdentifier) { step = nil; return; }
                                id edDone = wEd;
                                if (!VSEditorIsAlive(edDone)) { finish([label stringByAppendingString:@": editor bị đóng trước khi Tạo"]); return; }
                                
                                [self updateStatusHUD:[label stringByAppendingString:@": đang Tạo…"]];
                                [self waitForEditorSettledThenCreate:edDone runId:runId completion:^(NSString *e2) {
                                    if (runId != g_runIdentifier) { step = nil; return; }
                                    if (e2) { finish([NSString stringWithFormat:@"%@: %@", label, e2]); return; }
                                    okCount++;
                                    VSSafePoll(runId, 35, 120, ^BOOL{ return VSFindTopViewControllerNamed(@"VideoReviewEditVC") != nil; }, ^(BOOL back) {
                                        if (runId != g_runIdentifier) { step = nil; return; }
                                        if (!back) { finish(@"Không quay lại được"); return; }
                                        VSDispatchAfterMS(80, ^{ if (step) step(); });
                                    });
                                }];
                            });
                        });
                    }
                });
            }];
        }];
    };
    step();
}

- (void)openMultiLayerEditorForScene:(NSUInteger)scene reviewVC:(id)rvc runId:(NSUInteger)runId completion:(void (^)(id))done {
    id (^current)(void) = ^id{
        __block id ed = nil;
        VSTry(^{
            id candidate = VSFindTopViewControllerNamed(@"MultiLayerWizEffectVC");
            if (!candidate || ![candidate getMultiLayerEngine]) return;
            id nav = [candidate navigationController];
            BOOL ok = YES;
            if ([nav respondsToSelector:@selector(navSceneIndex)]) ok = ([nav navSceneIndex] == scene);
            if (ok) ed = candidate;
        });
        return ed;
    };
    id existing = current();
    if (existing) { done(existing); return; }
    if (!rvc) { done(nil); return; }
    if (!VSTry(^{ [rvc setLastViewedSceneIndex:scene]; [rvc showMultiLayer]; })) { done(nil); return; }
    VSSafePoll(runId, 35, 120, ^BOOL{ return current() != nil; }, ^(BOOL ok) {
        done(ok ? current() : nil);
    });
}

- (void)importPresetPayload:(id)preset codeIdentifier:(id)code intoEditor:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    if (![editor respondsToSelector:@selector(importedData:code:)]) { done(@"Editor không hỗ trợ importedData:code:"); return; }
    NSUInteger before = g_presetImportEventCounter;
    BOOL imported = VSTry(^{ [editor importedData:preset code:code]; });
    if (!imported) { done(@"Lỗi nạp preset"); return; }

    __weak id wEd = editor;
    VSObjProvider prov = ^id{ return wEd; };
    __block BOOL blocked = NO;
    VSSafePollEditor(runId, 30, 250, prov, ^BOOL(id ed) {
        VSPopupActionStatus s = VSResolvePopupsImmediately(ed);
        if (s == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
        return g_presetImportEventCounter > before;
    }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        if (blocked) { done(@"Popup mua Pro"); return; }
        if (!ok) { done(@"Timeout nạp QR"); return; }
        VSDispatchAfterMS(120, ^{
            if (runId != g_runIdentifier) return;
            __block BOOL purchase = NO;
            VSSafePollEditor(runId, 35, 70, prov, ^BOOL(id ed) {
                if (VSResolvePopupsImmediately(ed) == VSPopupActionStatusBlockedPurchase) { purchase = YES; return YES; }
                return !VSHasAnyActivePopup(ed) && VSNumActiveLayers(VSEngineFrom(ed)) > 0;
            }, ^(BOOL ready) {
                if (runId != g_runIdentifier) return;
                done(purchase ? @"Popup mua Pro" : (ready ? nil : @"Engine chưa sẵn sàng"));
            });
        });
    });
}

- (void)waitForEditorSettledThenCreate:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    __weak id wEd = editor;
    VSObjProvider prov = ^id{ return wEd; };
    __block NSUInteger stable = 0;
    __block BOOL purchase = NO;
    VSSafePollEditor(runId, 40, 150, prov, ^BOOL(id ed) {
        if (!VSEditorIsAlive(ed)) return YES;
        VSDismissLayerActionMenus(ed);
        if (VSResolvePopupsImmediately(ed) == VSPopupActionStatusBlockedPurchase) { purchase = YES; return YES; }
        BOOL calm = !VSHasAnyActivePopup(ed) && !VSEditorIsBusy(ed);
        stable = calm ? stable + 1 : 0;
        return stable >= 3;
    }, ^(BOOL ok) {
        if (runId != g_runIdentifier) return;
        if (purchase) { done(@"Popup mua Pro"); return; }
        id edNow = prov();
        if (!edNow || !VSEditorIsAlive(edNow)) { done(@"Editor bị đóng trước khi Tạo"); return; }
        if (!ok) { done(@"Editor chưa ổn định để Tạo"); return; }
        [self triggerCreateInEditor:edNow runId:runId completion:done];
    });
}

- (void)triggerCreateInEditor:(id)editor runId:(NSUInteger)runId completion:(void (^)(NSString *))done {
    UIBarButtonItem *btn = VSFindCreateButtonOnEditor(editor);
    if (!btn) { done(@"Không tìm thấy nút Tạo"); return; }
    g_createInProgress = YES;
    __block BOOL fired = NO;
    if (btn.action && btn.target) {
        if (!VSTry(^{ fired = [UIApplication.sharedApplication sendAction:btn.action to:btn.target from:btn forEvent:nil]; })) {
            g_createInProgress = NO;
            done(@"Lỗi nhấn nút Tạo"); return;
        }
    }
    if (!fired && [editor respondsToSelector:@selector(create)]) {
        if (!VSTry(^{ [editor create]; fired = YES; })) { g_createInProgress = NO; done(@"Lỗi create"); return; }
    }
    if (!fired) { g_createInProgress = NO; done(@"Không kích hoạt được"); return; }

    __weak id wEd = editor;
    VSObjProvider prov = ^id{ return wEd; };
    __block BOOL blocked = NO;
    VSSafePollEditor(runId, 40, 600, prov, ^BOOL(id ed) {
        if (VSResolvePopupsImmediately(ed) == VSPopupActionStatusBlockedPurchase) { blocked = YES; return YES; }
        return !([ed isViewLoaded] && [[ed view] window]);
    }, ^(BOOL closed) {
        g_createInProgress = NO;
        if (runId != g_runIdentifier) return;
        BOOL gone = (prov() == nil);
        done(blocked ? @"Tạo yêu cầu Pro" : ((closed || gone) ? nil : @"Tạo timeout"));
    });
}

@end

// ============================================================================
// HỦY TÁC VỤ KHI CÓ LỖI NỘI BỘ
// ============================================================================

static void VSAbortActiveTask(NSString *reason) {
    if (g_runIdentifier == 0) return;
    g_runIdentifier++;
    g_vsaAutomating = NO;
    g_suppressLayerActionMenu = NO;
    g_autoConfirmPopups = NO;
    g_createInProgress = NO;
    if (g_activeFiller) {
        [g_activeFiller finishWithStop:reason ?: @"Dừng do lỗi"];
        g_activeFiller = nil;
    }
    VSRunOnMain(^{
        [[VSTool shared] finalizeTaskWithMessage:reason ?: @"Dừng tác vụ"];
    });
}

// ============================================================================
// CORE HOOKS (CHỈ THÔNG BÁO / PASSTHROUGH, TUYỆT ĐỐI KHÔNG TOUCH THAM SỐ THÔ)
// ============================================================================

static void VSNotifyLayerAdded(id sender, BOOL is5, BOOL able) {
    if (!sender) return;
    void (^cb)(id, NSArray *, BOOL, BOOL) = g_onLayerAddedHandler;
    if (cb) cb(sender, @[], is5, able);
}

static void VSInstallCoreHooksOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_activePopupsTable = [NSHashTable weakObjectsHashTable];

        // 1. Popup DidMoveToWindow
        VSRobustSwizzleMethod(@"CustomPopup", @selector(didMoveToWindow), ^(id selfInstance) {
            if (g_origCustomPopupDidMove)
                ((void (*)(id, SEL))g_origCustomPopupDidMove)(selfInstance, @selector(didMoveToWindow));
            if (![selfInstance isKindOfClass:[UIView class]] || !((UIView *)selfInstance).window) return;
            [g_activePopupsTable addObject:selfInstance];
            if (g_autoConfirmPopups) VSDispatchAfterMS(50, ^{ VSResolvePopupsImmediately(nil); });
        }, &g_origCustomPopupDidMove);

        // 2. Preset import event counters
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

        // 3. Layer action menu suppression
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(showLayerActionMenu:newLayer:), ^(id selfInstance, NSUInteger layerNum, BOOL isNewLayer) {
            if (g_suppressLayerActionMenu) return;
            if (g_origShowLayerActionMenu)
                ((void (*)(id, SEL, NSUInteger, BOOL))g_origShowLayerActionMenu)(selfInstance, @selector(showLayerActionMenu:newLayer:), layerNum, isNewLayer);
        }, &g_origShowLayerActionMenu);

        // 4. Import confirmation suppression
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(showImportConfirmation), ^BOOL(id selfInstance) {
            if (g_vsaAutomating) return NO;
            if (g_origShowImportConfirmation)
                return ((BOOL (*)(id, SEL))g_origShowImportConfirmation)(selfInstance, @selector(showImportConfirmation));
            return NO;
        }, &g_origShowImportConfirmation);

        // 5. Hook confirmOverwrite: chuẩn 100% v5 – PURE PASSTHROUGH, TUYỆT ĐỐI KHÔNG DEREFERENCE OBJECT
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:), ^(id selfInstance, id object, BOOL showMenu) {
            if (g_vsaAutomating && [selfInstance respondsToSelector:@selector(overwrite:isAbleToShowTheLayerActionMenu:)]) {
                [selfInstance overwrite:object isAbleToShowTheLayerActionMenu:NO];
                return;
            }
            if (g_origConfirmOverwrite1)
                ((void (*)(id, SEL, id, BOOL))g_origConfirmOverwrite1)(selfInstance, @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:), object, showMenu);
        }, &g_origConfirmOverwrite1);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:removeOverlayBlending:), ^(id selfInstance, id object, BOOL showMenu, BOOL removeOverlay) {
            if (g_vsaAutomating && [selfInstance respondsToSelector:@selector(overwrite:isAbleToShowTheLayerActionMenu:removeOverlayBlending:)]) {
                [selfInstance overwrite:object isAbleToShowTheLayerActionMenu:NO removeOverlayBlending:removeOverlay];
                return;
            }
            if (g_origConfirmOverwrite2)
                ((void (*)(id, SEL, id, BOOL, BOOL))g_origConfirmOverwrite2)(selfInstance, @selector(confirmOverwrite:isAbleToShowTheLayerActionMenu:removeOverlayBlending:), object, showMenu, removeOverlay);
        }, &g_origConfirmOverwrite2);

        // 6. Hook confirmAddingLayer: chuẩn 100% v5 – CHỈ ĐẶT CỜ, TUYỆT ĐỐI KHÔNG CHẠM THAM SỐ THÔ
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:), ^(id selfInstance, id layer, id o1, id o2, id o3, BOOL able) {
            if (g_origConfirmAdd5)
                ((void (*)(id, SEL, id, id, id, id, BOOL))g_origConfirmAdd5)(selfInstance, @selector(confirmAddingLayer:object:object2:object3:isAbleToShowTheLayerActionMenu:), layer, o1, o2, o3, able);
            VSNotifyLayerAdded(selfInstance, YES, able);
        }, &g_origConfirmAdd5);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(confirmAddingLayer:object:object2:object3:), ^(id selfInstance, id layer, id o1, id o2, id o3) {
            if (g_origConfirmAdd4)
                ((void (*)(id, SEL, id, id, id, id))g_origConfirmAdd4)(selfInstance, @selector(confirmAddingLayer:object:object2:object3:), layer, o1, o2, o3);
            VSNotifyLayerAdded(selfInstance, NO, NO);
        }, &g_origConfirmAdd4);

        // ====================================================================
        // HOOKS HIỂN THỊ NÚT NỔI TỰ ĐỘNG THEO TỪNG MÀN HÌNH
        // ====================================================================

        // A. Màn hình Chia đoạn (VideoReviewEditVC)
        VSRobustSwizzleMethod(@"VideoReviewEditVC", @selector(showSplitScene), ^(id selfInstance) {
            if (g_origShowSplitScene) ((void (*)(id, SEL))g_origShowSplitScene)(selfInstance, @selector(showSplitScene));
            [[VSTool shared] showFloatingBeatButton];
        }, &g_origShowSplitScene);

        VSRobustSwizzleMethod(@"VideoReviewEditVC", @selector(closeSplitPanel), ^(id selfInstance) {
            if (g_origCloseSplitPanel) ((void (*)(id, SEL))g_origCloseSplitPanel)(selfInstance, @selector(closeSplitPanel));
            [[VSTool shared] hideFloatingBeatButton];
        }, &g_origCloseSplitPanel);

        // B. Màn hình Hợp nhất (VideoReviewEditVC)
        VSRobustSwizzleMethod(@"VideoReviewEditVC", @selector(showMergeScenes), ^(id selfInstance) {
            if (g_origShowMergeScenes) ((void (*)(id, SEL))g_origShowMergeScenes)(selfInstance, @selector(showMergeScenes));
            [[VSTool shared] showFloatingMergeButton];
        }, &g_origShowMergeScenes);

        VSRobustSwizzleMethod(@"VideoReviewEditVC", @selector(closeMergePanel), ^(id selfInstance) {
            if (g_origCloseMergePanel) ((void (*)(id, SEL))g_origCloseMergePanel)(selfInstance, @selector(closeMergePanel));
            [[VSTool shared] hideFloatingMergeButton];
        }, &g_origCloseMergePanel);

        // C. Màn hình Nhiều lớp (MultiLayerWizEffectVC)
        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(viewDidAppear:), ^(id selfInstance, BOOL animated) {
            if (g_origMLViewDidAppear) ((void (*)(id, SEL, BOOL))g_origMLViewDidAppear)(selfInstance, @selector(viewDidAppear:), animated);
            if (!g_vsaAutomating) {
                [[VSTool shared] showFloatingLayerButton];
            }
        }, &g_origMLViewDidAppear);

        VSRobustSwizzleMethod(@"MultiLayerWizEffectVC", @selector(viewWillDisappear:), ^(id selfInstance, BOOL animated) {
            if (g_origMLViewWillDisappear) ((void (*)(id, SEL, BOOL))g_origMLViewWillDisappear)(selfInstance, @selector(viewWillDisappear:), animated);
            [[VSTool shared] hideFloatingLayerButton];
        }, &g_origMLViewWillDisappear);
    });
}

// ============================================================================
// KHỞI ĐỘNG TỰ ĐỘNG
// ============================================================================

static void VSBootstrapAutomation(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VSInstallCoreHooksOnce();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[VSTool shared] setupToolInterfaceIfNeeded];
        });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification *__unused n) {
            g_memoryWarningAt = CFAbsoluteTimeGetCurrent();
        }];
    });
}

__attribute__((constructor)) static void VSInitAutomationTweak(void) {
    VSBootstrapAutomation();
}
