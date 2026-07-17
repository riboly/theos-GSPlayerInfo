/*
 * GSPlayerInfo — 强抓 URL 版
 *
 * hooks=OK 但无分辨率/标题/URL：说明只挂了部分入口，实际走 FVP/IJK 其他 init 或纯网络 m3u8。
 * 本版：
 *  1) AVURLAsset / AVPlayerItem / AVPlayer URL 全钩
 *  2) IJK 全部 init + setDataSource:
 *  3) FVPVideoPlayer / FVPTextureBasedVideoPlayer initWithURL*
 *  4) NSURLSession dataTaskWithRequest: / dataTaskWithURL: 抓 m3u8/mp4/getVideoUrl
 *  5) 顶栏常驻显示「最新 URL / 分辨率」——播放器外也看得见
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
static NSString *gLastNet = @"";
static NSInteger gW = 0, gH = 0;
static BOOL gHooksOK = NO;
static BOOL gAlerted = NO;
static UIButton *gBtn = nil;
static UILabel *gBanner = nil;
static id gLastIJK = nil;
static AVPlayer *gLastAV = nil;
static NSMutableArray<NSString *> *gURLHistory; // 最近几条

#pragma mark - Capture helpers

static BOOL GSLooksMediaURL(NSString *u) {
    if (u.length < 8) return NO;
    NSString *l = u.lowercaseString;
    if ([l hasPrefix:@"http://"] || [l hasPrefix:@"https://"] || [l hasPrefix:@"file://"]) {
        if ([l containsString:@".m3u8"] || [l containsString:@".mp4"] || [l containsString:@".flv"] ||
            [l containsString:@".ts"] || [l containsString:@"m3u8"] || [l containsString:@"getvideourl"] ||
            [l containsString:@"/hls/"] || [l containsString:@"playlist"] || [l containsString:@"video"] ||
            [l containsString:@"play"] || [l containsString:@"stream"] || [l containsString:@"mp4"]) {
            return YES;
        }
        // 任意长 http(s) 也记入网络历史，便于排查
        if (u.length > 20) return YES;
    }
    return NO;
}

static void GSRememberURL(NSString *u, NSString *source) {
    if (u.length == 0) return;
    if (!gURLHistory) gURLHistory = [NSMutableArray array];
    @synchronized (gURLHistory) {
        if (gURLHistory.count == 0 || ![gURLHistory.lastObject isEqualToString:u]) {
            [gURLHistory addObject:u];
            if (gURLHistory.count > 12) [gURLHistory removeObjectAtIndex:0];
        }
    }
    if (GSLooksMediaURL(u) || [source hasPrefix:@"AV"] || [source hasPrefix:@"IJK"] || [source hasPrefix:@"FVP"]) {
        gURL = [u copy];
        if (source.length) gExtra = [source copy];
    } else {
        gLastNet = [u copy];
        // 若还没有任何媒体 URL，先显示网络 URL
        if (gURL.length == 0) {
            gURL = [u copy];
            gExtra = source.length ? source : @"NET";
        }
    }
}

static void GSRememberTitle(NSString *t) {
    if (t.length == 0 || t.length > 200) return;
    // 过滤噪音
    if ([t hasPrefix:@"http"]) return;
    if ([t isEqualToString:@"null"] || [t isEqualToString:@"undefined"]) return;
    gTitle = [t copy];
}

static void GSRememberSize(CGFloat w, CGFloat h) {
    if (w > 1 && h > 1 && w < 10000 && h < 10000) {
        gW = (NSInteger)(w + 0.5);
        gH = (NSInteger)(h + 0.5);
    }
}

static void GSUpdateBannerText(void); // fwd

#pragma mark - UI helpers

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
    if ([vc isKindOfClass:[UINavigationController class]])
        vc = ((UINavigationController *)vc).visibleViewController ?: vc;
    if ([vc isKindOfClass:[UITabBarController class]])
        vc = ((UITabBarController *)vc).selectedViewController ?: vc;
    return vc;
}

static NSString *GSInfoText(void) {
    NSString *res = (gW > 0 && gH > 0)
        ? [NSString stringWithFormat:@"%ldx%ld", (long)gW, (long)gH]
        : @"(未获取)";
    NSMutableString *hist = [NSMutableString string];
    @synchronized (gURLHistory) {
        NSInteger n = gURLHistory.count;
        NSInteger from = n > 5 ? n - 5 : 0;
        for (NSInteger i = from; i < n; i++) {
            [hist appendFormat:@"\n• %@", gURLHistory[i]];
        }
    }
    return [NSString stringWithFormat:
            @"分辨率: %@\n\n标题: %@\n\n当前URL:\n%@\n\n来源: %@\n\nhooks=%@\n\n最近URL:%@",
            res,
            gTitle.length ? gTitle : @"(无)",
            gURL.length ? gURL : @"(无)",
            gExtra.length ? gExtra : @"?",
            gHooksOK ? @"OK" : @"NO",
            hist.length ? hist : @"\n(无)"];
}

static void GSShowAlert(NSString *title) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = GSTopVC();
        if (!vc || vc.presentedViewController) return;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:title ?: @"播放信息"
                                                message:GSInfoText()
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"复制URL"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
                                                  if (gURL.length)
                                                      UIPasteboard.generalPasteboard.string = gURL;
                                                }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static void GSUpdateBannerText(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gBanner) return;
        NSString *shortURL = gURL.length ? gURL : (gLastNet.length ? gLastNet : @"等待播放/网络…");
        if (shortURL.length > 48)
            shortURL = [NSString stringWithFormat:@"%@…%@",
                                                  [shortURL substringToIndex:20],
                                                  [shortURL substringFromIndex:shortURL.length - 20]];
        NSString *res = (gW > 0 && gH > 0)
            ? [NSString stringWithFormat:@"%ldx%ld", (long)gW, (long)gH]
            : @"?x?";
        gBanner.text = [NSString stringWithFormat:@"[%@] %@ | %@", res, gExtra.length ? gExtra : @"-", shortURL];
        gBanner.numberOfLines = 2;
        gBanner.adjustsFontSizeToFitWidth = YES;
    });
}

#pragma mark - Sample

static void GSSampleAV(AVPlayer *player) {
    if (!player) return;
    gLastAV = player;
    AVPlayerItem *item = player.currentItem;
    if (!item) return;
    CGSize s = item.presentationSize;
    GSRememberSize(s.width, s.height);
    AVAsset *asset = item.asset;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        NSString *u = ((AVURLAsset *)asset).URL.absoluteString;
        if (u.length) GSRememberURL(u, @"AVPlayer");
    }
    GSUpdateBannerText();
}

static void GSSampleIJK(id ijk) {
    if (!ijk) return;
    gLastIJK = ijk;
    @try {
        NSValue *v = [ijk valueForKey:@"naturalSize"];
        if ([v isKindOfClass:[NSValue class]]) {
            CGSize s = v.CGSizeValue;
            GSRememberSize(s.width, s.height);
        }
        // 部分版本 monitor.width/height
        id mon = [ijk valueForKey:@"monitor"];
        if (mon) {
            NSInteger w = [[mon valueForKey:@"width"] integerValue];
            NSInteger h = [[mon valueForKey:@"height"] integerValue];
            if (w > 1 && h > 1) GSRememberSize(w, h);
        }
    } @catch (__unused NSException *e) {}
    gExtra = @"IJK";
    GSUpdateBannerText();
}

#pragma mark - Swizzle core

static void GSSwizzleInst(Class cls, SEL sel, IMP neu, IMP *orig) {
    if (!cls || !sel || !neu || !orig) return;
    if (*orig) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, neu);
    gHooksOK = YES;
}

static void GSSwizzleClass(Class cls, SEL sel, IMP neu, IMP *orig) {
    if (!cls || !sel || !neu || !orig) return;
    if (*orig) return;
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    // class methods live on metaclass
    Class meta = object_getClass((id)cls);
    Method mm = class_getInstanceMethod(meta, sel);
    if (!mm) return;
    *orig = method_getImplementation(mm);
    method_setImplementation(mm, neu);
    gHooksOK = YES;
}

#pragma mark - IJK hooks

static IMP o_ijk_s, o_ijk_so, o_ijk_u, o_ijk_uo, o_ijk_ds, o_ijk_prep;

static id h_ijk_s(id self, SEL _cmd, id urlString) {
    if ([urlString isKindOfClass:[NSString class]]) GSRememberURL(urlString, @"IJK-str");
    id r = ((id(*)(id, SEL, id))o_ijk_s)(self, _cmd, urlString);
    GSSampleIJK(r ?: self);
    return r;
}
static id h_ijk_so(id self, SEL _cmd, id urlString, id opts) {
    if ([urlString isKindOfClass:[NSString class]]) GSRememberURL(urlString, @"IJK-strOpt");
    id r = ((id(*)(id, SEL, id, id))o_ijk_so)(self, _cmd, urlString, opts);
    GSSampleIJK(r ?: self);
    return r;
}
static id h_ijk_u(id self, SEL _cmd, id url) {
    if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"IJK-url");
    else if ([url isKindOfClass:[NSString class]]) GSRememberURL(url, @"IJK-url");
    id r = ((id(*)(id, SEL, id))o_ijk_u)(self, _cmd, url);
    GSSampleIJK(r ?: self);
    return r;
}
static id h_ijk_uo(id self, SEL _cmd, id url, id opts) {
    if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"IJK-urlOpt");
    else if ([url isKindOfClass:[NSString class]]) GSRememberURL(url, @"IJK-urlOpt");
    id r = ((id(*)(id, SEL, id, id))o_ijk_uo)(self, _cmd, url, opts);
    GSSampleIJK(r ?: self);
    return r;
}
static void h_ijk_ds(id self, SEL _cmd, id url) {
    if ([url isKindOfClass:[NSString class]]) GSRememberURL(url, @"IJK-ds");
    else if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"IJK-ds");
    if (o_ijk_ds) ((void(*)(id, SEL, id))o_ijk_ds)(self, _cmd, url);
    GSSampleIJK(self);
}
static void h_ijk_prep(id self, SEL _cmd) {
    if (o_ijk_prep) ((void(*)(id, SEL))o_ijk_prep)(self, _cmd);
    GSSampleIJK(self);
}

#pragma mark - FVP hooks

static IMP o_fvp_url, o_fvpt_url, o_fvp_asset, o_fvpt_asset;

// -[FVPVideoPlayer initWithURL:httpHeaders:avFactory:registrar:]
static id h_fvp_url(id self, SEL _cmd, id url, id headers, id avf, id reg) {
    if ([url isKindOfClass:[NSString class]]) GSRememberURL(url, @"FVP");
    else if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"FVP");
    id r = ((id(*)(id, SEL, id, id, id, id))o_fvp_url)(self, _cmd, url, headers, avf, reg);
    // try player
    @try {
        id p = [r valueForKey:@"player"];
        if ([p isKindOfClass:[AVPlayer class]]) GSSampleAV(p);
    } @catch (__unused NSException *e) {}
    return r;
}

// -[FVPTextureBasedVideoPlayer initWithURL:frameUpdater:displayLink:httpHeaders:avFactory:registrar:onDisposed:]
static id h_fvpt_url(id self, SEL _cmd, id url, id fu, id dl, id headers, id avf, id reg, id od) {
    if ([url isKindOfClass:[NSString class]]) GSRememberURL(url, @"FVP-tex");
    else if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"FVP-tex");
    id r = ((id(*)(id, SEL, id, id, id, id, id, id, id))o_fvpt_url)(self, _cmd, url, fu, dl, headers, avf, reg, od);
    @try {
        id p = [r valueForKey:@"player"];
        if ([p isKindOfClass:[AVPlayer class]]) GSSampleAV(p);
    } @catch (__unused NSException *e) {}
    return r;
}

#pragma mark - AVFoundation hooks

static IMP o_av_replace, o_av_initURL, o_av_playerWithURL;
static IMP o_item_initURL, o_item_withURL;
static IMP o_asset_initURL, o_asset_withURL;

static void h_av_replace(id self, SEL _cmd, id item) {
    ((void(*)(id, SEL, id))o_av_replace)(self, _cmd, item);
    if ([self isKindOfClass:[AVPlayer class]]) GSSampleAV((AVPlayer *)self);
}
static id h_av_initURL(id self, SEL _cmd, id url) {
    if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"AVPlayer-init");
    id r = ((id(*)(id, SEL, id))o_av_initURL)(self, _cmd, url);
    if ([r isKindOfClass:[AVPlayer class]]) GSSampleAV(r);
    return r;
}
static id h_av_playerWithURL(id self, SEL _cmd, id url) {
    if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"AVPlayer+URL");
    id r = ((id(*)(id, SEL, id))o_av_playerWithURL)(self, _cmd, url);
    if ([r isKindOfClass:[AVPlayer class]]) GSSampleAV(r);
    return r;
}
static id h_item_initURL(id self, SEL _cmd, id url) {
    if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"AVItem");
    return ((id(*)(id, SEL, id))o_item_initURL)(self, _cmd, url);
}
static id h_item_withURL(id self, SEL _cmd, id url) {
    if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"AVItem+");
    return ((id(*)(id, SEL, id))o_item_withURL)(self, _cmd, url);
}
static id h_asset_initURL(id self, SEL _cmd, id url, id opts) {
    if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"AVURLAsset");
    return ((id(*)(id, SEL, id, id))o_asset_initURL)(self, _cmd, url, opts);
}
static id h_asset_withURL(id self, SEL _cmd, id url, id opts) {
    if ([url isKindOfClass:[NSURL class]]) GSRememberURL([(NSURL *)url absoluteString], @"AVURLAsset+");
    return ((id(*)(id, SEL, id, id))o_asset_withURL)(self, _cmd, url, opts);
}

#pragma mark - NSURLSession hooks（关键：m3u8 真实拉流）

static IMP o_sess_req, o_sess_url, o_sess_req_comp, o_sess_url_comp;

static void GSCaptureRequest(NSURLRequest *req, NSString *tag) {
    if (![req isKindOfClass:[NSURLRequest class]]) return;
    NSString *u = req.URL.absoluteString;
    if (u.length) GSRememberURL(u, tag);
    GSUpdateBannerText();
}

static id h_sess_req(id self, SEL _cmd, id request) {
    GSCaptureRequest(request, @"NSURLSession-req");
    return ((id(*)(id, SEL, id))o_sess_req)(self, _cmd, request);
}
static id h_sess_url(id self, SEL _cmd, id url) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"NSURLSession-url");
    GSUpdateBannerText();
    return ((id(*)(id, SEL, id))o_sess_url)(self, _cmd, url);
}
// dataTaskWithRequest:completionHandler:
static id h_sess_req_comp(id self, SEL _cmd, id request, id comp) {
    GSCaptureRequest(request, @"NSURLSession-reqC");
    return ((id(*)(id, SEL, id, id))o_sess_req_comp)(self, _cmd, request, comp);
}
static id h_sess_url_comp(id self, SEL _cmd, id url, id comp) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"NSURLSession-urlC");
    GSUpdateBannerText();
    return ((id(*)(id, SEL, id, id))o_sess_url_comp)(self, _cmd, url, comp);
}

#pragma mark - JSON harvest

static void GSScanJSON(id o, int depth) {
    if (!o || depth > 6) return;
    if ([o isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = o;
        static NSArray *urlKeys, *titleKeys;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            urlKeys = @[
                @"playUrl", @"play_url", @"videoUrl", @"video_url", @"url", @"urlM3u8",
                @"mv_play_url", @"preview_play_url", @"preview_play_url2", @"m3u8", @"src",
                @"video", @"path", @"play_url2", @"downUrl", @"download_url"
            ];
            titleKeys = @[
                @"video_name", @"videoName", @"title", @"name", @"vod_name",
                @"film_name", @"movieName", @"mediaName", @"caption"
            ];
        });
        for (NSString *k in urlKeys) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]] && GSLooksMediaURL(v)) {
                GSRememberURL(v, [@"JSON:" stringByAppendingString:k]);
            }
        }
        for (NSString *k in titleKeys) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]]) GSRememberTitle(v);
        }
        // 同 dict 内同时有 title + url
        NSInteger n = 0;
        for (id v in d.allValues) {
            if (++n > 80) break;
            GSScanJSON(v, depth + 1);
        }
    } else if ([o isKindOfClass:[NSArray class]]) {
        NSInteger n = 0;
        for (id v in (NSArray *)o) {
            if (++n > 40) break;
            GSScanJSON(v, depth + 1);
        }
    }
    GSUpdateBannerText();
}

static IMP o_json;
static id h_json(id self, SEL _cmd, id data, NSUInteger opt, NSError **err) {
    id obj = ((id(*)(id, SEL, id, NSUInteger, NSError **))o_json)(self, _cmd, data, opt, err);
    if (obj) GSScanJSON(obj, 0);
    return obj;
}

#pragma mark - Install

static void GSInstallHooks(void) {
    // IJK
    Class ijk = NSClassFromString(@"IJKFFMoviePlayerController");
    if (ijk) {
        GSSwizzleInst(ijk, @selector(initWithContentURLString:), (IMP)h_ijk_s, &o_ijk_s);
        GSSwizzleInst(ijk, @selector(initWithContentURLString:withOptions:), (IMP)h_ijk_so, &o_ijk_so);
        GSSwizzleInst(ijk, @selector(initWithContentURL:), (IMP)h_ijk_u, &o_ijk_u);
        GSSwizzleInst(ijk, @selector(initWithContentURL:withOptions:), (IMP)h_ijk_uo, &o_ijk_uo);
        GSSwizzleInst(ijk, @selector(setDataSource:), (IMP)h_ijk_ds, &o_ijk_ds);
        GSSwizzleInst(ijk, @selector(prepareToPlay), (IMP)h_ijk_prep, &o_ijk_prep);
    }

    // FVP
    Class fvp = NSClassFromString(@"FVPVideoPlayer");
    if (fvp) {
        GSSwizzleInst(fvp, @selector(initWithURL:httpHeaders:avFactory:registrar:),
                      (IMP)h_fvp_url, &o_fvp_url);
    }
    Class fvpt = NSClassFromString(@"FVPTextureBasedVideoPlayer");
    if (fvpt) {
        SEL s = NSSelectorFromString(@"initWithURL:frameUpdater:displayLink:httpHeaders:avFactory:registrar:onDisposed:");
        GSSwizzleInst(fvpt, s, (IMP)h_fvpt_url, &o_fvpt_url);
    }

    // AVPlayer
    Class av = [AVPlayer class];
    GSSwizzleInst(av, @selector(replaceCurrentItemWithPlayerItem:), (IMP)h_av_replace, &o_av_replace);
    GSSwizzleInst(av, @selector(initWithURL:), (IMP)h_av_initURL, &o_av_initURL);
    GSSwizzleClass(av, @selector(playerWithURL:), (IMP)h_av_playerWithURL, &o_av_playerWithURL);

    Class item = [AVPlayerItem class];
    GSSwizzleInst(item, @selector(initWithURL:), (IMP)h_item_initURL, &o_item_initURL);
    GSSwizzleClass(item, @selector(playerItemWithURL:), (IMP)h_item_withURL, &o_item_withURL);

    Class asset = [AVURLAsset class];
    GSSwizzleInst(asset, @selector(initWithURL:options:), (IMP)h_asset_initURL, &o_asset_initURL);
    GSSwizzleClass(asset, @selector(URLAssetWithURL:options:), (IMP)h_asset_withURL, &o_asset_withURL);

    // NSURLSession
    Class sess = [NSURLSession class];
    GSSwizzleInst(sess, @selector(dataTaskWithRequest:), (IMP)h_sess_req, &o_sess_req);
    GSSwizzleInst(sess, @selector(dataTaskWithURL:), (IMP)h_sess_url, &o_sess_url);
    GSSwizzleInst(sess, @selector(dataTaskWithRequest:completionHandler:), (IMP)h_sess_req_comp, &o_sess_req_comp);
    GSSwizzleInst(sess, @selector(dataTaskWithURL:completionHandler:), (IMP)h_sess_url_comp, &o_sess_url_comp);

    // JSON
    if (!o_json) {
        Method m = class_getClassMethod([NSJSONSerialization class],
                                        @selector(JSONObjectWithData:options:error:));
        if (m) {
            Class meta = object_getClass((id)[NSJSONSerialization class]);
            Method mm = class_getInstanceMethod(meta, @selector(JSONObjectWithData:options:error:));
            if (mm) {
                o_json = method_getImplementation(mm);
                method_setImplementation(mm, (IMP)h_json);
                gHooksOK = YES;
            }
        }
    }
}

#pragma mark - UI

@interface GSPlayerInfoTapTarget : NSObject
+ (instancetype)shared;
- (void)onTap;
- (void)onTick;
- (void)onActive;
- (void)onIJKSize:(NSNotification *)n;
@end

static void GSLayoutUI(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    CGRect b = win.bounds;
    CGFloat top = 50;
    if (@available(iOS 11.0, *)) top = win.safeAreaInsets.top + 4;
    if (gBanner) {
        if (gBanner.superview != win) {
            [gBanner removeFromSuperview];
            [win addSubview:gBanner];
        }
        gBanner.frame = CGRectMake(0, top, b.size.width, 40);
        [win bringSubviewToFront:gBanner];
    }
    if (gBtn) {
        if (gBtn.superview != win) {
            [gBtn removeFromSuperview];
            [win addSubview:gBtn];
        }
        gBtn.frame = CGRectMake(b.size.width - 58, top + 48, 50, 50);
        [win bringSubviewToFront:gBtn];
    }
}

static void GSEnsureUI(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    if (!gBanner) {
        gBanner = [[UILabel alloc] initWithFrame:CGRectZero];
        gBanner.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        gBanner.textColor = [UIColor greenColor];
        gBanner.font = [UIFont boldSystemFontOfSize:11];
        gBanner.textAlignment = NSTextAlignmentLeft;
        gBanner.numberOfLines = 2;
        gBanner.text = @"[GS] 等待 URL… 播放任意视频";
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
    GSUpdateBannerText();
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
    GSShowAlert(@"播放信息 / URL");
}
- (void)onTick {
    GSInstallHooks();
    GSEnsureUI();
    if (gLastIJK) GSSampleIJK(gLastIJK);
    if (gLastAV) GSSampleAV(gLastAV);
    GSUpdateBannerText();
}
- (void)onActive {
    GSInstallHooks();
    GSEnsureUI();
    if (!gAlerted) {
        gAlerted = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         GSShowAlert(@"GS 注入成功");
                       });
    }
}
- (void)onIJKSize:(NSNotification *)n {
    GSSampleIJK(n.object);
}
@end

static void GSBootMain(void) {
    GSInstallHooks();
    GSEnsureUI();
    GSPlayerInfoTapTarget *t = [GSPlayerInfoTapTarget shared];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:t selector:@selector(onActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:t selector:@selector(onActive) name:UIApplicationDidFinishLaunchingNotification object:nil];
    [nc addObserver:t selector:@selector(onIJKSize:) name:@"IJKMPMovieNaturalSizeAvailableNotification" object:nil];
    [nc addObserver:t selector:@selector(onIJKSize:) name:@"IJKMPMoviePlayerFirstVideoFrameRenderedNotification" object:nil];
    [NSTimer scheduledTimerWithTimeInterval:0.8 target:t selector:@selector(onTick) userInfo:nil repeats:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
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
    if ([NSThread isMainThread]) GSBootMain();
    else dispatch_async(dispatch_get_main_queue(), ^{ GSBootMain(); });
    for (int s = 1; s <= 8; s++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         GSInstallHooks();
                         GSEnsureUI();
                       });
    }
}
