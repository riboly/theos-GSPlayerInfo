/*
 * GSPlayerInfo — 按 DYYY/Theos 正规 iOS 工具链编写
 *
 * 与此前 Zig 交叉编译版的本质区别：
 *  - 使用 iphoneos SDK + clang 编译（arm64）
 *  - 正常链接 UIKit/Foundation/objc（两级命名空间绑定）
 *  - 使用现代 dyld chained fixups（与 DYYY 一致）
 *
 * 注入（与 flex 相同）：
 *   @executable_path/GSPlayerInfo.dylib
 *
 * 验证 UI：启动后红条 + 悬浮按钮 + 自动弹框
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <pthread.h>

#pragma mark - State

static NSString *gURL = @"";
static NSString *gTitle = @"";
static NSString *gExtra = @"";
static NSInteger gW = 0, gH = 0;
static BOOL gHooksOK = NO;
static BOOL gAlerted = NO;
static UIButton *gBtn = nil;
static UILabel *gBanner = nil;
static id gLastIJK = nil;
static AVPlayer *gLastAV = nil;

#pragma mark - Helpers

static UIWindow *GSKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (app.keyWindow) return app.keyWindow;
    return app.windows.firstObject;
#pragma clang diagnostic pop
}

static UIViewController *GSTopVC(void) {
    UIViewController *vc = GSKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = ((UINavigationController *)vc).visibleViewController ?: vc;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        vc = ((UITabBarController *)vc).selectedViewController ?: vc;
    }
    return vc;
}

static NSString *GSInfoText(void) {
    NSString *res = (gW > 0 && gH > 0)
        ? [NSString stringWithFormat:@"%ldx%ld", (long)gW, (long)gH]
        : @"(未获取，请先进入播放页)";
    return [NSString stringWithFormat:
            @"✅ GSPlayerInfo 已注入\n\n"
            @"分辨率:\n%@\n\n标题:\n%@\n\nURL:\n%@\n\n播放器:\n%@\n\n"
            @"hooks=%@\n"
            @"注入路径应与 flex 相同:\n@executable_path/GSPlayerInfo.dylib",
            res,
            gTitle.length ? gTitle : @"(无)",
            gURL.length ? gURL : @"(无)",
            gExtra.length ? gExtra : @"(未知)",
            gHooksOK ? @"OK" : @"未挂上"];
}

static void GSShowAlert(NSString *title) {
    UIViewController *vc = GSTopVC();
    if (!vc || vc.presentedViewController) return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title ?: @"GS 注入成功"
                                            message:GSInfoText()
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Sample players

static void GSSampleAV(AVPlayer *player) {
    if (!player) return;
    gLastAV = player;
    AVPlayerItem *item = player.currentItem;
    if (!item) return;
    CGSize s = item.presentationSize;
    if (s.width > 1 && s.height > 1) {
        gW = (NSInteger)(s.width + 0.5);
        gH = (NSInteger)(s.height + 0.5);
    }
    AVAsset *asset = item.asset;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        gURL = ((AVURLAsset *)asset).URL.absoluteString ?: gURL;
    }
    gExtra = @"AVPlayer";
}

static void GSSampleIJK(id ijk) {
    if (!ijk) return;
    gLastIJK = ijk;
    @try {
        NSValue *v = [ijk valueForKey:@"naturalSize"];
        if (v) {
            CGSize s = v.CGSizeValue;
            if (s.width > 1 && s.height > 1) {
                gW = (NSInteger)(s.width + 0.5);
                gH = (NSInteger)(s.height + 0.5);
            }
        }
    } @catch (__unused NSException *e) {}
    gExtra = @"IJK";
}

#pragma mark - Swizzle

static IMP GSOrigIJKInitStr = NULL;
static IMP GSOrigIJKInitURL = NULL;
static IMP GSOrigAVReplace = NULL;
static IMP GSOrigJSON = NULL;

static id GSHookIJKInitStr(id self, SEL _cmd, id urlString) {
    if ([urlString isKindOfClass:[NSString class]]) gURL = urlString;
    id r = ((id(*)(id, SEL, id))GSOrigIJKInitStr)(self, _cmd, urlString);
    GSSampleIJK(r ?: self);
    return r;
}
static id GSHookIJKInitURL(id self, SEL _cmd, id url) {
    if ([url isKindOfClass:[NSURL class]]) gURL = [(NSURL *)url absoluteString];
    else if ([url isKindOfClass:[NSString class]]) gURL = url;
    id r = ((id(*)(id, SEL, id))GSOrigIJKInitURL)(self, _cmd, url);
    GSSampleIJK(r ?: self);
    return r;
}
static void GSHookAVReplace(id self, SEL _cmd, id item) {
    ((void(*)(id, SEL, id))GSOrigAVReplace)(self, _cmd, item);
    if ([self isKindOfClass:[AVPlayer class]]) GSSampleAV((AVPlayer *)self);
}
static id GSHookJSON(id self, SEL _cmd, id data, NSUInteger opt, NSError **err) {
    id obj = ((id(*)(id, SEL, id, NSUInteger, NSError **))GSOrigJSON)(self, _cmd, data, opt, err);
    if (![obj isKindOfClass:[NSDictionary class]] && ![obj isKindOfClass:[NSArray class]]) return obj;
    // shallow scan
    void (^scan)(id, int);
    __block void (^bscan)(id, int);
    bscan = ^(id o, int depth) {
        if (!o || depth > 4) return;
        if ([o isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = o;
            for (NSString *k in @[@"playUrl", @"play_url", @"videoUrl", @"url", @"urlM3u8", @"m3u8"]) {
                id v = d[k];
                if ([v isKindOfClass:[NSString class]] &&
                    ([(NSString *)v containsString:@"http"] || [(NSString *)v containsString:@"m3u8"])) {
                    gURL = v;
                    break;
                }
            }
            for (NSString *k in @[@"video_name", @"title", @"name"]) {
                id v = d[k];
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                    gTitle = v;
                    break;
                }
            }
            for (id v in d.allValues) bscan(v, depth + 1);
        } else if ([o isKindOfClass:[NSArray class]]) {
            for (id v in (NSArray *)o) bscan(v, depth + 1);
        }
    };
    bscan(obj, 0);
    return obj;
}

static void GSSwizzleInst(Class cls, SEL sel, IMP neu, IMP *orig) {
    if (!cls || !orig || *orig) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, neu);
    gHooksOK = YES;
}

static void GSInstallHooks(void) {
    Class ijk = NSClassFromString(@"IJKFFMoviePlayerController");
    if (ijk) {
        GSSwizzleInst(ijk, @selector(initWithContentURLString:), (IMP)GSHookIJKInitStr, &GSOrigIJKInitStr);
        GSSwizzleInst(ijk, @selector(initWithContentURL:), (IMP)GSHookIJKInitURL, &GSOrigIJKInitURL);
    }
    Class av = [AVPlayer class];
    GSSwizzleInst(av, @selector(replaceCurrentItemWithPlayerItem:), (IMP)GSHookAVReplace, &GSOrigAVReplace);

    if (!GSOrigJSON) {
        Method m = class_getClassMethod([NSJSONSerialization class],
                                        @selector(JSONObjectWithData:options:error:));
        if (m) {
            GSOrigJSON = method_getImplementation(m);
            method_setImplementation(m, (IMP)GSHookJSON);
        }
    }
}

#pragma mark - Tap target (declared early)

@interface GSPlayerInfoTapTarget : NSObject
+ (instancetype)shared;
- (void)onTap;
- (void)onTick;
- (void)onActive;
@end

#pragma mark - UI

static void GSLayoutUI(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    CGRect b = win.bounds;
    CGFloat top = 50;
    if (@available(iOS 11.0, *)) top = win.safeAreaInsets.top + 6;

    if (gBanner) {
        if (gBanner.superview != win) {
            [gBanner removeFromSuperview];
            [win addSubview:gBanner];
        }
        gBanner.frame = CGRectMake(0, top, b.size.width, 34);
        [win bringSubviewToFront:gBanner];
    }
    if (gBtn) {
        if (gBtn.superview != win) {
            [gBtn removeFromSuperview];
            [win addSubview:gBtn];
        }
        gBtn.frame = CGRectMake(b.size.width - 62, top + 42, 50, 50);
        [win bringSubviewToFront:gBtn];
    }
}

static void GSEnsureUI(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;

    if (!gBanner) {
        gBanner = [[UILabel alloc] initWithFrame:CGRectZero];
        gBanner.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.92];
        gBanner.textColor = UIColor.whiteColor;
        gBanner.font = [UIFont boldSystemFontOfSize:13];
        gBanner.textAlignment = NSTextAlignmentCenter;
        gBanner.text = @"【GS注入成功】点右上角 i 查看播放信息";
        gBanner.userInteractionEnabled = NO;
        [win addSubview:gBanner];
    }
    if (!gBtn) {
        gBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        gBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.95];
        [gBtn setTitle:@"i" forState:UIControlStateNormal];
        [gBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gBtn.titleLabel.font = [UIFont boldSystemFontOfSize:26];
        gBtn.layer.cornerRadius = 25;
        gBtn.clipsToBounds = YES;
        [gBtn addTarget:[GSPlayerInfoTapTarget shared]
                      action:@selector(onTap)
            forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:gBtn];
    }
    GSLayoutUI();
}

@implementation GSPlayerInfoTapTarget
+ (instancetype)shared {
    static GSPlayerInfoTapTarget *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [GSPlayerInfoTapTarget new]; });
    return s;
}
- (void)onTap {
    if (gLastIJK) GSSampleIJK(gLastIJK);
    if (gLastAV) GSSampleAV(gLastAV);
    GSShowAlert(@"播放信息");
}
- (void)onTick {
    GSInstallHooks();
    GSEnsureUI();
    if (gLastIJK) GSSampleIJK(gLastIJK);
    if (gLastAV) GSSampleAV(gLastAV);
}
- (void)onActive {
    GSInstallHooks();
    GSEnsureUI();
    if (!gAlerted) {
        gAlerted = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         GSShowAlert(@"GS 注入成功");
                       });
    }
}
@end

#pragma mark - Boot

static void GSBootMain(void) {
    GSInstallHooks();
    GSEnsureUI();

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    GSPlayerInfoTapTarget *t = [GSPlayerInfoTapTarget shared];
    [nc addObserver:t selector:@selector(onActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:t selector:@selector(onActive) name:UIApplicationDidFinishLaunchingNotification object:nil];
    [nc addObserver:t
            selector:@selector(onTick)
                name:@"IJKMPMovieNaturalSizeAvailableNotification"
              object:nil];

    [NSTimer scheduledTimerWithTimeInterval:1.0
                                     target:t
                                   selector:@selector(onTick)
                                   userInfo:nil
                                    repeats:YES];

    // 首启强制弹一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     GSEnsureUI();
                     if (!gAlerted) {
                         gAlerted = YES;
                         GSShowAlert(@"GS 注入成功");
                     }
                   });
}

__attribute__((constructor))
static void GSPlayerInfoInit(void) {
    // 与 DYYY 一致：尽快转到主线程
    if ([NSThread isMainThread]) {
        GSBootMain();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ GSBootMain(); });
    }
    // 再延迟几次，防止 Flutter 窗口尚未就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ GSEnsureUI(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ GSEnsureUI(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ GSEnsureUI(); });
}
