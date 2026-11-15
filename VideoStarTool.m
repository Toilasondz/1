// ============================================================================
// VSCrashLogger.m — dylib độc lập, chỉ ghi log, không hook class nào của app.
// Log: <Documents>/VideoStar/VSCrashLog.txt
// ============================================================================

#import <UIKit/UIKit.h>
#import <os/proc.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <time.h>

#define VSCL_MAX_BYTES  (500 * 1024)
#define VSCL_TRIM_BYTES (200 * 1024)
#define VSCL_DIR  "VideoStar"
#define VSCL_FILE "VSCrashLog.txt"

static const int kVSCLSignals[] = { SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGABRT, SIGFPE };
#define VSCL_NSIG (sizeof(kVSCLSignals) / sizeof(kVSCLSignals[0]))

static char g_logPath[1024];
static int  g_logPathReady = 0;
static struct sigaction g_origSA[VSCL_NSIG];
static NSUncaughtExceptionHandler *g_origExcHandler = NULL;

// ============================================================================
// AN TOÀN TRONG SIGNAL HANDLER: chỉ dùng open / write / close
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
// GHI LOG (ObjC, không gọi từ signal handler)
// ============================================================================

static NSString *vscl_free_mb(void) {
    if (@available(iOS 13.0, *)) {
        uint64_t b = (uint64_t)os_proc_available_memory();
        return [NSString stringWithFormat:@"%llu MB free", (unsigned long long)(b / (1024ULL * 1024ULL))];
    }
    return @"RAM unknown";
}

static void vscl_rotate_if_needed(void) {
    if (!g_logPathReady) return;
    NSString *path = [NSString stringWithUTF8String:g_logPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length <= VSCL_MAX_BYTES) return;

    NSData *trimmed = [data subdataWithRange:NSMakeRange(data.length - VSCL_TRIM_BYTES, VSCL_TRIM_BYTES)];
    NSData *nl = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange found = [trimmed rangeOfData:nl options:0 range:NSMakeRange(0, MIN((NSUInteger)512, trimmed.length))];
    if (found.location != NSNotFound)
        trimmed = [trimmed subdataWithRange:NSMakeRange(found.location + 1, trimmed.length - found.location - 1)];

    NSString *header = [NSString stringWithFormat:@"[LOG TRIMMED — kept last %lu KB]\n", (unsigned long)(VSCL_TRIM_BYTES / 1024)];
    NSMutableData *out = [NSMutableData data];
    [out appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [out appendData:trimmed];
    [out writeToFile:path atomically:YES];
}

static void vscl_log(NSString *tag, NSString *message, NSArray<NSString *> *stack) {
    if (!g_logPathReady) return;
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        df.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    });

    NSMutableString *line = [NSMutableString string];
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
// SIGNAL HANDLER
// ============================================================================

static void vscl_signal_handler(int sig, siginfo_t *info, void *ctx) {
    char ts[32];
    vscl_timestamp(ts, sizeof(ts));
    char buf[512];
    snprintf(buf, sizeof(buf), "\n[%s] CRASH | %s | addr=%p\n",
             ts, vscl_signame(sig), info ? info->si_addr : NULL);
    vscl_write_cstr(buf);

    // Chain sang handler gốc (crash reporter của OS)
    for (size_t i = 0; i < VSCL_NSIG; i++) {
        if (kVSCLSignals[i] != sig) continue;
        struct sigaction *orig = &g_origSA[i];
        if (orig->sa_flags & SA_SIGINFO) {
            if (orig->sa_sigaction) { orig->sa_sigaction(sig, info, ctx); return; }
        } else if (orig->sa_handler && orig->sa_handler != SIG_IGN && orig->sa_handler != SIG_DFL) {
            orig->sa_handler(sig);
            return;
        }
        break;
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

// ============================================================================
// UNCAUGHT EXCEPTION
// ============================================================================

static void vscl_exception_handler(NSException *e) {
    NSString *msg = [NSString stringWithFormat:@"%@: %@ | %@",
                     e.name, e.reason ?: @"(nil)", vscl_free_mb()];
    vscl_log(@"UNCAUGHT_EXCEPTION", msg, e.callStackSymbols);
    if (g_origExcHandler) g_origExcHandler(e);
}

// ============================================================================
// LOG THEO NOTIFICATION (không swizzle gì)
// ============================================================================

static void vscl_write_launch_banner(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build   = info[@"CFBundleVersion"] ?: @"?";
    NSString *msg = [NSString stringWithFormat:@"App %@ (%@) | iOS %@ | %@ | %@",
                     version, build,
                     [UIDevice currentDevice].systemVersion ?: @"?",
                     [UIDevice currentDevice].model ?: @"?",
                     vscl_free_mb()];
    vscl_log(@"APP_LAUNCH", msg, nil);
}

static void vscl_observe(NSNotificationName name, NSString *tag) {
    [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                usingBlock:^(NSNotification *n) {
        vscl_log(tag, [NSString stringWithFormat:@"%@ | %@", name, vscl_free_mb()], nil);
    }];
}

// ============================================================================
// SETUP
// ============================================================================

static void vscl_setup_log_path(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir  = [docs stringByAppendingPathComponent:@VSCL_DIR];
    NSString *file = [dir stringByAppendingPathComponent:@VSCL_FILE];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    strlcpy(g_logPath, file.UTF8String, sizeof(g_logPath));
    g_logPathReady = 1;
}

static void vscl_install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = vscl_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < VSCL_NSIG; i++)
        sigaction(kVSCLSignals[i], &sa, &g_origSA[i]);
}

__attribute__((constructor))
static void VSCrashLoggerInit(void) {
    vscl_setup_log_path();
    vscl_install_signal_handlers();

    g_origExcHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&vscl_exception_handler);

    vscl_observe(UIApplicationDidBecomeActiveNotification, @"APP_FOREGROUND");
    vscl_observe(UIApplicationDidEnterBackgroundNotification, @"APP_BACKGROUND");
    vscl_observe(UIApplicationWillTerminateNotification, @"APP_TERMINATE");
    vscl_observe(UIApplicationDidReceiveMemoryWarningNotification, @"MEMORY_WARNING");

    vscl_write_launch_banner();
}
