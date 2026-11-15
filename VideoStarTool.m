// ============================================================================
// VSCrashLogger.m
//
// Dylib độc lập. Không phụ thuộc VideoStarTool.m.
// Chỉ ghi log — không can thiệp vào bất kỳ luồng logic nào của app.
//
// Log file: <Documents>/VideoStar/VSCrashLog.txt
// Mỗi lần chạy app: ghi dòng "=== APP LAUNCH ===" kèm thời gian và RAM.
// Ghi memory warning, ghi mọi NSException chưa được bắt, ghi mọi signal crash.
// Mỗi dòng log có: thời gian ISO-8601, loại sự kiện, lý do, call stack (nếu có).
// File xoay vòng: giữ tối đa 500 KB, nếu vượt thì xoá nửa đầu.
// ============================================================================

#import <UIKit/UIKit.h>
#import <os/proc.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <time.h>
#import <objc/runtime.h>

// ============================================================================
// CẤU HÌNH
// ============================================================================

#define VSCL_MAX_BYTES  (500 * 1024)   // 500 KB tối đa
#define VSCL_TRIM_BYTES (200 * 1024)   // giữ lại 200 KB cuối khi xoay
#define VSCL_DIR        "VideoStar"
#define VSCL_FILE       "VSCrashLog.txt"

// ============================================================================
// LỌC SIGNAL: chỉ bắt loại liên quan đến crash thật
// ============================================================================

static const int kVSCLSignals[] = {
    SIGSEGV,   // bad pointer, null dereference
    SIGBUS,    // misaligned memory access
    SIGTRAP,   // Swift runtime trap, breakpoint
    SIGILL,    // illegal instruction
    SIGABRT,   // NSException chưa bắt, assert
    SIGFPE,    // arithmetic error
};
#define VSCL_NSIG (sizeof(kVSCLSignals)/sizeof(kVSCLSignals[0]))

// ============================================================================
// TRẠNG THÁI TOÀN CỤC (async-signal-safe: chỉ dùng kiểu C đơn giản)
// ============================================================================

static char   g_logPath[1024];       // đường dẫn file log
static int    g_logPathReady = 0;    // 1 = g_logPath đã được gán
static struct sigaction g_origSA[VSCL_NSIG];   // handler gốc để chain

// ============================================================================
// TIỆN ÍCH: an toàn trong signal handler (không malloc, không ObjC)
// ============================================================================

static void vscl_write_raw(const char *buf, size_t len) {
    if (!g_logPathReady || !buf || !len) return;
    int fd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    write(fd, buf, len);
    close(fd);
}

static void vscl_write_cstr(const char *s) {
    if (s) vscl_write_raw(s, strlen(s));
}

// ISO-8601 timestamp, không dùng ObjC
static void vscl_timestamp(char *out, size_t sz) {
    time_t t = time(NULL);
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(out, sz, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

static const char *vscl_signame(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV (bad pointer / null deref)";
        case SIGBUS:  return "SIGBUS (misaligned access)";
        case SIGTRAP: return "SIGTRAP (Swift trap / assert)";
        case SIGILL:  return "SIGILL (illegal instruction)";
        case SIGABRT: return "SIGABRT (abort / NSException)";
        case SIGFPE:  return "SIGFPE (arithmetic error)";
        default:      return "SIGNAL (unknown)";
    }
}

// ============================================================================
// XOAY VÒNG FILE (chạy trên main queue, dùng được ObjC)
// ============================================================================

static void vscl_rotate_if_needed(void) {
    if (!g_logPathReady) return;
    NSString *path = [NSString stringWithUTF8String:g_logPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length <= VSCL_MAX_BYTES) return;
    // Giữ lại VSCL_TRIM_BYTES cuối
    NSData *trimmed = [data subdataWithRange:NSMakeRange(data.length - VSCL_TRIM_BYTES, VSCL_TRIM_BYTES)];
    // Tìm dòng đầy đủ đầu tiên để không cắt giữa chừng
    NSRange newline = [trimmed rangeOfData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]
                                   options:0
                                     range:NSMakeRange(0, MIN(512UL, trimmed.length))];
    if (newline.location != NSNotFound)
        trimmed = [trimmed subdataWithRange:NSMakeRange(newline.location + 1, trimmed.length - newline.location - 1)];
    NSMutableData *out = [NSMutableData data];
    NSString *header = [NSString stringWithFormat:@"[LOG TRIMMED — kept last %lu KB]\n", (unsigned long)(VSCL_TRIM_BYTES/1024)];
    [out appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [out appendData:trimmed];
    [out writeToFile:path atomically:YES];
}

// ============================================================================
// GHI LOG (dùng ObjC — không gọi từ signal handler)
// ============================================================================

static NSString *vscl_free_mb(void) {
    if (@available(iOS 13.0, *)) {
        uint64_t b = (uint64_t)os_proc_available_memory();
        return [NSString stringWithFormat:@"%llu MB free", b / (1024*1024)];
    }
    return @"RAM unknown";
}

static void vscl_log(NSString *tag, NSString *message, NSArray<NSString *> *stack) {
    if (!g_logPathReady) return;
    NSString *path = [NSString stringWithUTF8String:g_logPath];
    NSMutableString *line = [NSMutableString string];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    df.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    [line appendFormat:@"\n[%@] %@ | %@\n", [df stringFromDate:[NSDate date]], tag, message];
    if (stack.count) {
        [line appendString:@"  Stack:\n"];
        NSUInteger limit = MIN((NSUInteger)30, stack.count);
        for (NSUInteger i = 0; i < limit; i++)
            [line appendFormat:@"  %lu: %@\n", (unsigned long)i, stack[i]];
    }
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(g_logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { write(fd, data.bytes, data.length); close(fd); }
    vscl_rotate_if_needed();
}

// ============================================================================
// SIGNAL HANDLER (async-signal-safe: chỉ dùng write, open, close, strlen)
// ============================================================================

static void vscl_signal_handler(int sig, siginfo_t *info, void *ctx) {
    // 1. Ghi dòng crash vào file bằng syscall thuần
    char ts[32]; vscl_timestamp(ts, sizeof(ts));
    char buf[512];
    snprintf(buf, sizeof(buf),
             "\n[%s] CRASH | %s | addr=%p\n",
             ts, vscl_signame(sig),
             info ? info->si_addr : NULL);
    vscl_write_cstr(buf);

    // 2. Gọi lại handler gốc (crash reporter của OS, lldb, v.v.)
    struct sigaction *orig = NULL;
    for (size_t i = 0; i < VSCL_NSIG; i++) {
        if (kVSCLSignals[i] == sig) { orig = &g_origSA[i]; break; }
    }
    if (orig) {
        if (orig->sa_flags & SA_SIGINFO) {
            if (orig->sa_sigaction) orig->sa_sigaction(sig, info, ctx);
        } else {
            if (orig->sa_handler && orig->sa_handler != SIG_IGN && orig->sa_handler != SIG_DFL)
                orig->sa_handler(sig);
            else { signal(sig, SIG_DFL); raise(sig); }
        }
    } else {
        signal(sig, SIG_DFL); raise(sig);
    }
}

// ============================================================================
// UNCAUGHT EXCEPTION HANDLER
// ============================================================================

static NSUncaughtExceptionHandler *g_origExcHandler = NULL;

static void vscl_exception_handler(NSException *e) {
    NSString *reason = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"(nil)"];
    NSString *mem = vscl_free_mb();
    vscl_log(@"UNCAUGHT_EXCEPTION",
             [NSString stringWithFormat:@"%@ | %@", reason, mem],
             e.callStackSymbols);
    if (g_origExcHandler) g_origExcHandler(e);
}

// ============================================================================
// SWIZZLE didReceiveMemoryWarning (UIApplication level)
// ============================================================================

static IMP g_origAppMemWarn = NULL;

static void vscl_app_memory_warning(id self, SEL _cmd) {
    NSString *msg = [NSString stringWithFormat:@"UIApplication memory warning | %@", vscl_free_mb()];
    vscl_log(@"MEMORY_WARNING", msg, nil);
    if (g_origAppMemWarn)
        ((void(*)(id,SEL))g_origAppMemWarn)(self, _cmd);
}

// ============================================================================
// SWIZZLE MultiLayerWizEffectVC didReceiveMemoryWarning
// ============================================================================

static IMP g_origEdMemWarn = NULL;

static void vscl_editor_memory_warning(id self, SEL _cmd) {
    NSString *msg = [NSString stringWithFormat:@"MultiLayerWizEffectVC memory warning | %@", vscl_free_mb()];
    vscl_log(@"MEMORY_WARNING", msg, [NSThread callStackSymbols]);
    if (g_origEdMemWarn)
        ((void(*)(id,SEL))g_origEdMemWarn)(self, _cmd);
}

// ============================================================================
// THEO DÕI VÒNG ĐỜI APP (để ghi mốc quan trọng)
// ============================================================================

static IMP g_origBecomeActive = NULL;

static void vscl_app_become_active(id self, SEL _cmd) {
    vscl_log(@"APP_FOREGROUND",
             [NSString stringWithFormat:@"applicationDidBecomeActive | %@", vscl_free_mb()],
             nil);
    if (g_origBecomeActive)
        ((void(*)(id,SEL))g_origBecomeActive)(self, _cmd);
}

static IMP g_origResignActive = NULL;

static void vscl_app_resign_active(id self, SEL _cmd) {
    vscl_log(@"APP_BACKGROUND", @"applicationWillResignActive", nil);
    if (g_origResignActive)
        ((void(*)(id,SEL))g_origResignActive)(self, _cmd);
}

static IMP g_origTerminate = NULL;

static void vscl_app_terminate(id self, SEL _cmd) {
    vscl_log(@"APP_TERMINATE", @"applicationWillTerminate", nil);
    if (g_origTerminate)
        ((void(*)(id,SEL))g_origTerminate)(self, _cmd);
}

// ============================================================================
// SWIZZLE HELPER
// ============================================================================

static void vscl_swizzle(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (origOut && *origOut) return;    // đã swizzle
    IMP imp = imp_implementationWithBlock((__bridge id)(__bridge void *)(id)newImp);
    // Dùng block trực tiếp không được vì newImp là function pointer — dùng method_setImplementation
    if (class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        if (origOut) *origOut = method_getImplementation(m);
    } else {
        if (origOut) *origOut = method_setImplementation(m, newImp);
    }
    (void)imp;
}

// ============================================================================
// KHỞI TẠO
// ============================================================================

static void vscl_setup_log_dir(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir  = [docs stringByAppendingPathComponent:@VSCL_DIR];
    NSString *file = [dir  stringByAppendingPathComponent:@VSCL_FILE];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
    strlcpy(g_logPath, file.UTF8String, sizeof(g_logPath));
    g_logPathReady = 1;
}

static void vscl_install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = vscl_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;    // SA_RESETHAND: sau khi bắt thì reset về SIG_DFL
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < VSCL_NSIG; i++)
        sigaction(kVSCLSignals[i], &sa, &g_origSA[i]);
}

static void vscl_install_exception_handler(void) {
    g_origExcHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&vscl_exception_handler);
}

static void vscl_install_swizzles(void) {
    // UIApplication lifecycle
    Class appCls = [UIApplication class];
    vscl_swizzle(appCls, @selector(applicationDidBecomeActive:),   (IMP)vscl_app_become_active,  &g_origBecomeActive);
    vscl_swizzle(appCls, @selector(applicationWillResignActive:),  (IMP)vscl_app_resign_active,  &g_origResignActive);
    vscl_swizzle(appCls, @selector(applicationWillTerminate:),     (IMP)vscl_app_terminate,       &g_origTerminate);
    vscl_swizzle(appCls, @selector(applicationDidReceiveMemoryWarning:), (IMP)vscl_app_memory_warning, &g_origAppMemWarn);

    // Editor memory warning (nếu class đã load)
    Class edCls = NSClassFromString(@"MultiLayerWizEffectVC");
    if (edCls)
        vscl_swizzle(edCls, @selector(didReceiveMemoryWarning), (IMP)vscl_editor_memory_warning, &g_origEdMemWarn);
}

static void vscl_write_launch_banner(void) {
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build   = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"?";
    NSString *device  = [UIDevice currentDevice].model ?: @"?";
    NSString *os      = [UIDevice currentDevice].systemVersion ?: @"?";
    NSString *msg = [NSString stringWithFormat:
        @"App %@ (%@) | iOS %@ | %@ | %@",
        version, build, os, device, vscl_free_mb()];
    vscl_log(@"APP_LAUNCH", msg, nil);
}

// ============================================================================
// ENTRY POINT
// ============================================================================

__attribute__((constructor))
static void VSCrashLoggerInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vscl_setup_log_dir();
        vscl_install_signal_handlers();
        vscl_install_exception_handler();
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                vscl_install_swizzles();
                vscl_write_launch_banner();
            }
        });
    });
}
