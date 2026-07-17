/*
 * GSPlayerInfo — 播放信息面板 + NAS 推送
 *
 * 标题：JSON(display_title/video_title/…) + 无障碍扫描 + 顶栏 OCR
 * 悬浮钮：灰白半透明、缩小 50%；点击弹出面板
 * 无启动弹框、无顶栏横条
 * NAS: POST http://192.168.6.110:38617/api/download  {url,title}
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>

// ============== NAS（来自 D:\公共下载\main.py  port=38617）==============
// 若 NAS 不在此 IP，只改这一处即可
static NSString *const kGSNASDownloadURL = @"http://192.168.6.110:38617/api/download";

#pragma mark - State

static NSString *gURL = @"";
static NSString *gTitle = @"";
static NSString *gExtra = @"";
static NSInteger gW = 0, gH = 0;
static BOOL gHooksOK = NO;
static UIButton *gBtn = nil;
static UIView *gPanel = nil;
static UILabel *gLabRes = nil, *gLabTitle = nil, *gLabURL = nil;
static UIButton *gBtnNas = nil;
static id gLastIJK = nil;
static AVPlayer *gLastAV = nil;
static NSMutableArray<NSString *> *gURLHistory;
static NSMutableArray<NSString *> *gTitlePool; // 最近见过的标题候选
static NSTimeInterval gLastOCR = 0;

#pragma mark - Helpers

static BOOL GSIsNoiseHost(NSString *u) {
    NSString *l = u.lowercaseString;
    return [l containsString:@"umeng"] || [l containsString:@"umengcloud"] ||
           [l containsString:@"apple.com"] || [l containsString:@"icloud.com"] ||
           [l containsString:@"crashlytics"] || [l containsString:@"firebase"] ||
           [l containsString:@"googleapis"] || [l containsString:@"adjust.com"] ||
           [l containsString:@"sentry"] || [l containsString:@"bugly"] ||
           [l containsString:@"resolve.umeng"];
}

static BOOL GSLooksMediaURL(NSString *u) {
    if (u.length < 8 || GSIsNoiseHost(u)) return NO;
    NSString *l = u.lowercaseString;
    if (!([l hasPrefix:@"http://"] || [l hasPrefix:@"https://"] || [l hasPrefix:@"file://"]))
        return NO;
    return [l containsString:@".m3u8"] || [l containsString:@"m3u8"] || [l containsString:@".mp4"] ||
           [l containsString:@"/hls/"] || [l containsString:@"playlist"] ||
           [l containsString:@"getvideourl"] || [l containsString:@"/h5/m3u8"] ||
           [l containsString:@"film_m3u8"] || [l containsString:@"short_m3u8"] ||
           [l containsString:@"play_url"] || [l containsString:@".flv"] || [l containsString:@".ts"];
}

static BOOL GSHasCJK(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3040 && c <= 0x30FF) ||
            (c >= 0x3000 && c <= 0x303F) || c == 0x30FB /* ・ */)
            return YES;
    }
    return NO;
}

static BOOL GSLooksLikeTitle(NSString *t) {
    if (t.length < 2 || t.length > 150) return NO;
    NSString *trim = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length < 2) return NO;
    t = trim;
    if ([t hasPrefix:@"http"] || [t containsString:@"m3u8"] || [t containsString:@".mp4"]) return NO;
    if ([t isEqualToString:@"null"] || [t isEqualToString:@"undefined"] || [t isEqualToString:@"(无)"])
        return NO;
    NSArray *bad = @[
        @"关闭", @"复制", @"好的", @"播放信息", @"分辨率", @"视频标题", @"视频URL", @"推送到", @"NAS",
        @"hooks", @"GS", @"1.0X", @"1.0x", @"全屏", @"倍速", @"选集", @"i", @"OK", @"AVPlayer", @"IJK",
        @"FVP", @"未获取", @"等待", @"成功", @"失败", @"loading", @"Loading"
    ];
    for (NSString *b in bad) {
        if ([t isEqualToString:b]) return NO;
        if ([t hasPrefix:@"[GS"] || [t hasPrefix:@"【GS"]) return NO;
    }
    if ([t rangeOfString:@"^\\d{1,2}:\\d{2}(:\\d{2})?$" options:NSRegularExpressionSearch].location !=
        NSNotFound)
        return NO;
    if (GSHasCJK(t)) return YES;
    // 允许含日文假名/中点的片名
    return t.length >= 6;
}

static void GSRememberURL(NSString *u, NSString *source) {
    if (u.length == 0 || GSIsNoiseHost(u)) return;
    BOOL media = GSLooksMediaURL(u) || [source hasPrefix:@"AV"] || [source hasPrefix:@"IJK"] ||
                 [source hasPrefix:@"FVP"] || [source hasPrefix:@"JSON"];
    if (!media) return;
    if (!gURLHistory) gURLHistory = [NSMutableArray array];
    @synchronized (gURLHistory) {
        if (gURLHistory.count == 0 || ![gURLHistory.lastObject isEqualToString:u]) {
            [gURLHistory addObject:u];
            if (gURLHistory.count > 10) [gURLHistory removeObjectAtIndex:0];
        }
    }
    gURL = [u copy];
    if (source.length) gExtra = [source copy];
}

static void GSRememberTitle(NSString *t) {
    if (!GSLooksLikeTitle(t)) return;
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!gTitlePool) gTitlePool = [NSMutableArray array];
    @synchronized (gTitlePool) {
        if (![gTitlePool containsObject:t]) {
            [gTitlePool addObject:t];
            if (gTitlePool.count > 20) [gTitlePool removeObjectAtIndex:0];
        }
    }
    // 更长的中文标题优先
    if (gTitle.length > 0 && GSHasCJK(gTitle) && t.length < gTitle.length && GSHasCJK(t)) {
        // 若新标题是旧标题的前缀/后缀扩展则更新
        if (![t containsString:gTitle] && ![gTitle containsString:t]) {
            // keep longer
            if (t.length <= gTitle.length) return;
        }
    }
    gTitle = [t copy];
}

static void GSRememberSize(CGFloat w, CGFloat h) {
    if (w > 1 && h > 1 && w < 10000 && h < 10000) {
        gW = (NSInteger)(w + 0.5);
        gH = (NSInteger)(h + 0.5);
    }
}

static UIWindow *GSKeyWindow(void); // fwd

static NSString *GSResText(void) {
    if (gW > 0 && gH > 0) return [NSString stringWithFormat:@"%ldx%ld", (long)gW, (long)gH];
    return @"(未获取)";
}

static NSString *GSCopyTitleURL(void) {
    return [NSString stringWithFormat:@"%@----%@", gTitle.length ? gTitle : @"(无标题)",
                                      gURL.length ? gURL : @"(无URL)"];
}

static void GSToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = GSKeyWindow();
        if (!win) return;
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(40, win.bounds.size.height * 0.4,
                                                                 win.bounds.size.width - 80, 40)];
        lab.text = msg;
        lab.textAlignment = NSTextAlignmentCenter;
        lab.textColor = UIColor.whiteColor;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        lab.font = [UIFont systemFontOfSize:14];
        lab.layer.cornerRadius = 8;
        lab.clipsToBounds = YES;
        [win addSubview:lab];
        [UIView animateWithDuration:0.3 delay:1.2 options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL f) {
            [lab removeFromSuperview];
        }];
    });
}

#pragma mark - Window / VC

static UIWindow *GSKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
            if (((UIWindowScene *)scene).windows.count)
                return ((UIWindowScene *)scene).windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow ?: app.windows.firstObject;
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

#pragma mark - JSON title (关键：display_title / video_title / mv_title)

static void GSScanJSON(id o, int depth) {
    if (!o || depth > 7) return;
    if ([o isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)o;
        static NSArray *urlKeys, *titleKeys;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
          urlKeys = @[
              @"playUrl", @"play_url", @"videoUrl", @"video_url", @"url", @"urlM3u8", @"mv_play_url",
              @"preview_play_url", @"preview_play_url2", @"m3u8", @"src", @"video", @"path",
              @"play_url2", @"downUrl", @"download_url", @"link"
          ];
          // App AOT 中出现的关键键：display_title / video_title / video_name / mv_title / play_title
          titleKeys = @[
              @"display_title", @"displayTitle", @"video_title", @"videoTitle", @"video_name",
              @"videoName", @"mv_title", @"mvTitle", @"play_title", @"playTitle", @"title", @"name",
              @"vod_name", @"film_name", @"movieName", @"mediaName", @"caption", @"subject",
              @"headline", @"desc", @"description", @"sp91_film_subject", @"sp91_small_video_subject"
          ];
        });

        NSString *foundURL = nil;
        NSString *foundTitle = nil;
        for (NSString *k in urlKeys) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]] && GSLooksMediaURL(v)) {
                foundURL = v;
                break;
            }
        }
        for (NSString *k in titleKeys) {
            id v = d[k];
            if (![v isKindOfClass:[NSString class]]) continue;
            if (!GSLooksLikeTitle(v)) continue;
            // display_title / video_title 优先于通用 name
            BOOL preferred = [k containsString:@"title"] || [k containsString:@"Title"] ||
                             [k containsString:@"subject"];
            if (!foundTitle || preferred) foundTitle = v;
            if (preferred && GSHasCJK(v)) break;
        }
        if (foundURL) GSRememberURL(foundURL, @"JSON");
        if (foundTitle) GSRememberTitle(foundTitle);
        // 同层配对：有 URL 则强制采用同层标题
        if (foundURL && foundTitle) GSRememberTitle(foundTitle);

        // 遍历所有 string 值：长中文也可能是标题
        NSInteger n = 0;
        for (id key in d) {
            id v = d[key];
            if ([v isKindOfClass:[NSString class]]) {
                NSString *s = v;
                NSString *ks = [key description];
                if (([ks.lowercaseString containsString:@"title"] ||
                     [ks.lowercaseString containsString:@"name"] ||
                     [ks.lowercaseString containsString:@"subject"]) &&
                    GSLooksLikeTitle(s)) {
                    GSRememberTitle(s);
                }
            }
            if (++n > 100) break;
            if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]])
                GSScanJSON(v, depth + 1);
        }
    } else if ([o isKindOfClass:[NSArray class]]) {
        NSInteger n = 0;
        for (id v in (NSArray *)o) {
            if (++n > 50) break;
            GSScanJSON(v, depth + 1);
        }
    }
}

#pragma mark - UI title scan + OCR

static void GSCollectTitle(NSString *text, CGFloat midY, CGFloat screenH,
                           NSMutableArray<NSDictionary *> *out) {
    if (!GSLooksLikeTitle(text)) return;
    if (screenH > 0 && midY > screenH * 0.62) return; // 标题在上半/中上
    [out addObject:@{@"t" : text, @"y" : @(midY), @"len" : @(text.length)}];
}

static void GSWalkView(UIView *view, int depth, CGFloat screenH, NSMutableArray *out) {
    if (!view || depth > 20 || view.hidden || view.alpha < 0.02) return;
    if (view == gBtn || view == gPanel) return;

    CGRect fr = [view convertRect:view.bounds toView:nil];
    CGFloat midY = CGRectGetMidY(fr);

    if ([view isKindOfClass:[UILabel class]])
        GSCollectTitle(((UILabel *)view).text, midY, screenH, out);
    else if ([view isKindOfClass:[UITextView class]])
        GSCollectTitle(((UITextView *)view).text, midY, screenH, out);

    NSString *acc = view.accessibilityLabel;
    if (acc.length) GSCollectTitle(acc, midY, screenH, out);

    NSArray *els = nil;
    @try {
        if (!view.isAccessibilityElement) els = view.accessibilityElements;
    } @catch (__unused NSException *e) {
    }
    if ([els isKindOfClass:[NSArray class]]) {
        for (id el in els) {
            NSString *lab = nil;
            CGFloat y = midY;
            @try {
                if ([el respondsToSelector:@selector(accessibilityLabel)])
                    lab = [el accessibilityLabel];
                if ([el respondsToSelector:@selector(accessibilityFrame)]) {
                    CGRect af = [el accessibilityFrame];
                    if (!CGRectIsEmpty(af)) y = CGRectGetMidY(af);
                }
            } @catch (__unused NSException *e) {
            }
            if (lab.length) GSCollectTitle(lab, y, screenH, out);
        }
    }
    for (UIView *sub in view.subviews) GSWalkView(sub, depth + 1, screenH, out);
}

static void GSScanTitleFromUI(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    CGFloat H = win.bounds.size.height;
    NSMutableArray *cands = [NSMutableArray array];
    GSWalkView(win, 0, H, cands);
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w != win) GSWalkView(w, 0, H, cands);
            }
        }
    }
    if (!cands.count) return;
    [cands sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      CGFloat ya = [a[@"y"] doubleValue], yb = [b[@"y"] doubleValue];
      if (ya < yb - 6) return NSOrderedAscending;
      if (yb < ya - 6) return NSOrderedDescending;
      return [@([b[@"len"] integerValue]) compare:@([a[@"len"] integerValue])];
    }];
    for (NSDictionary *c in cands) {
        if (GSHasCJK(c[@"t"])) {
            GSRememberTitle(c[@"t"]);
            return;
        }
    }
    GSRememberTitle(cands.firstObject[@"t"]);
}

static void GSOcrTopTitle(void) {
    if (gTitle.length >= 4 && GSHasCJK(gTitle)) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastOCR < 2.0) return;
    gLastOCR = now;

    UIWindow *win = GSKeyWindow();
    if (!win) return;
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat topInset = 0;
    if (@available(iOS 11.0, *)) topInset = win.safeAreaInsets.top;
    // 避开右上角按钮，截取中间标题带
    CGRect band = CGRectMake(50, topInset + 2, MAX(100, win.bounds.size.width - 120), 52);
    UIGraphicsBeginImageContextWithOptions(band.size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return;
    }
    CGContextTranslateCTM(ctx, -band.origin.x, -band.origin.y);
    [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!img.CGImage) return;

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
    VNRecognizeTextRequest *req =
        [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *err) {
          if (err || !request.results.count) return;
          NSString *best = nil;
          NSMutableString *line = [NSMutableString string];
          for (VNRecognizedTextObservation *obs in request.results) {
              NSString *s = [obs topCandidates:1].firstObject.string;
              if (!s.length) continue;
              if (line.length) [line appendString:s];
              else [line setString:s];
              if (GSLooksLikeTitle(s) && GSHasCJK(s) && (!best || s.length > best.length)) best = s;
          }
          if ((!best || best.length < 4) && line.length >= 4 && GSLooksLikeTitle(line)) best = line;
          if (best.length) {
              dispatch_async(dispatch_get_main_queue(), ^{ GSRememberTitle(best); });
          }
        }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;
    if (@available(iOS 14.0, *))
        req.recognitionLanguages = @[ @"zh-Hans", @"zh-Hant", @"ja", @"en" ];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      [handler performRequests:@[ req ] error:nil];
    });
}

#pragma mark - Sample players

static void GSSampleAV(AVPlayer *player) {
    if (!player) return;
    gLastAV = player;
    AVPlayerItem *item = player.currentItem;
    if (!item) return;
    CGSize s = item.presentationSize;
    GSRememberSize(s.width, s.height);
    if ([item.asset isKindOfClass:[AVURLAsset class]]) {
        NSString *u = ((AVURLAsset *)item.asset).URL.absoluteString;
        if (u.length) GSRememberURL(u, @"AVPlayer");
    }
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
        id mon = [ijk valueForKey:@"monitor"];
        if (mon) {
            NSInteger w = [[mon valueForKey:@"width"] integerValue];
            NSInteger h = [[mon valueForKey:@"height"] integerValue];
            if (w > 1 && h > 1) GSRememberSize(w, h);
        }
    } @catch (__unused NSException *e) {
    }
    gExtra = @"IJK";
}

#pragma mark - Swizzle

static void GSSwizzleInst(Class cls, SEL sel, IMP neu, IMP *orig) {
    if (!cls || !sel || !neu || !orig || *orig) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, neu);
    gHooksOK = YES;
}
static void GSSwizzleClass(Class cls, SEL sel, IMP neu, IMP *orig) {
    if (!cls || !sel || !neu || !orig || *orig) return;
    Class meta = object_getClass((id)cls);
    Method m = class_getInstanceMethod(meta, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, neu);
    gHooksOK = YES;
}

static IMP o_ijk_s, o_ijk_so, o_ijk_u, o_ijk_uo, o_ijk_ds, o_ijk_prep;
static IMP o_fvp_url, o_fvpt_url;
static IMP o_av_replace, o_av_initURL, o_av_playerWithURL;
static IMP o_item_initURL, o_item_withURL, o_asset_initURL, o_asset_withURL;
static IMP o_sess_req, o_sess_url, o_sess_req_c, o_sess_url_c, o_json;

static id h_ijk_s(id s, SEL c, id u) {
    if ([u isKindOfClass:[NSString class]]) GSRememberURL(u, @"IJK");
    id r = ((id(*)(id, SEL, id))o_ijk_s)(s, c, u);
    GSSampleIJK(r ?: s);
    return r;
}
static id h_ijk_so(id s, SEL c, id u, id o) {
    if ([u isKindOfClass:[NSString class]]) GSRememberURL(u, @"IJK");
    id r = ((id(*)(id, SEL, id, id))o_ijk_so)(s, c, u, o);
    GSSampleIJK(r ?: s);
    return r;
}
static id h_ijk_u(id s, SEL c, id u) {
    if ([u isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)u absoluteString], @"IJK");
    else if ([u isKindOfClass:[NSString class]])
        GSRememberURL(u, @"IJK");
    id r = ((id(*)(id, SEL, id))o_ijk_u)(s, c, u);
    GSSampleIJK(r ?: s);
    return r;
}
static id h_ijk_uo(id s, SEL c, id u, id o) {
    if ([u isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)u absoluteString], @"IJK");
    else if ([u isKindOfClass:[NSString class]])
        GSRememberURL(u, @"IJK");
    id r = ((id(*)(id, SEL, id, id))o_ijk_uo)(s, c, u, o);
    GSSampleIJK(r ?: s);
    return r;
}
static void h_ijk_ds(id s, SEL c, id u) {
    if ([u isKindOfClass:[NSString class]])
        GSRememberURL(u, @"IJK-ds");
    else if ([u isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)u absoluteString], @"IJK-ds");
    if (o_ijk_ds) ((void(*)(id, SEL, id))o_ijk_ds)(s, c, u);
    GSSampleIJK(s);
}
static void h_ijk_prep(id s, SEL c) {
    if (o_ijk_prep) ((void(*)(id, SEL))o_ijk_prep)(s, c);
    GSSampleIJK(s);
}

static id h_fvp_url(id s, SEL c, id url, id h, id a, id r) {
    if ([url isKindOfClass:[NSString class]])
        GSRememberURL(url, @"FVP");
    else if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"FVP");
    id x = ((id(*)(id, SEL, id, id, id, id))o_fvp_url)(s, c, url, h, a, r);
    @try {
        id p = [x valueForKey:@"player"];
        if ([p isKindOfClass:[AVPlayer class]]) GSSampleAV(p);
    } @catch (__unused NSException *e) {
    }
    return x;
}
static id h_fvpt_url(id s, SEL c, id url, id fu, id dl, id h, id a, id r, id od) {
    if ([url isKindOfClass:[NSString class]])
        GSRememberURL(url, @"FVP-tex");
    else if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"FVP-tex");
    id x = ((id(*)(id, SEL, id, id, id, id, id, id, id))o_fvpt_url)(s, c, url, fu, dl, h, a, r, od);
    @try {
        id p = [x valueForKey:@"player"];
        if ([p isKindOfClass:[AVPlayer class]]) GSSampleAV(p);
    } @catch (__unused NSException *e) {
    }
    return x;
}

static void h_av_replace(id s, SEL c, id item) {
    ((void(*)(id, SEL, id))o_av_replace)(s, c, item);
    if ([s isKindOfClass:[AVPlayer class]]) GSSampleAV(s);
}
static id h_av_initURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"AVPlayer");
    id r = ((id(*)(id, SEL, id))o_av_initURL)(s, c, url);
    if ([r isKindOfClass:[AVPlayer class]]) GSSampleAV(r);
    return r;
}
static id h_av_playerWithURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"AVPlayer");
    id r = ((id(*)(id, SEL, id))o_av_playerWithURL)(s, c, url);
    if ([r isKindOfClass:[AVPlayer class]]) GSSampleAV(r);
    return r;
}
static id h_item_initURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"AVItem");
    return ((id(*)(id, SEL, id))o_item_initURL)(s, c, url);
}
static id h_item_withURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"AVItem");
    return ((id(*)(id, SEL, id))o_item_withURL)(s, c, url);
}
static id h_asset_initURL(id s, SEL c, id url, id o) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"AVURLAsset");
    return ((id(*)(id, SEL, id, id))o_asset_initURL)(s, c, url, o);
}
static id h_asset_withURL(id s, SEL c, id url, id o) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"AVURLAsset");
    return ((id(*)(id, SEL, id, id))o_asset_withURL)(s, c, url, o);
}

static void GSCapReq(NSURLRequest *req, NSString *tag) {
    if (![req isKindOfClass:[NSURLRequest class]]) return;
    NSString *u = req.URL.absoluteString;
    if (u.length) GSRememberURL(u, tag);
}
static id h_sess_req(id s, SEL c, id req) {
    GSCapReq(req, @"NET");
    return ((id(*)(id, SEL, id))o_sess_req)(s, c, req);
}
static id h_sess_url(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"NET");
    return ((id(*)(id, SEL, id))o_sess_url)(s, c, url);
}
static id h_sess_req_c(id s, SEL c, id req, id comp) {
    GSCapReq(req, @"NET");
    return ((id(*)(id, SEL, id, id))o_sess_req_c)(s, c, req, comp);
}
static id h_sess_url_c(id s, SEL c, id url, id comp) {
    if ([url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"NET");
    return ((id(*)(id, SEL, id, id))o_sess_url_c)(s, c, url, comp);
}

static id h_json(id s, SEL c, id data, NSUInteger opt, NSError **err) {
    id obj = ((id(*)(id, SEL, id, NSUInteger, NSError **))o_json)(s, c, data, opt, err);
    if (obj) GSScanJSON(obj, 0);
    return obj;
}

static void GSInstallHooks(void) {
    Class ijk = NSClassFromString(@"IJKFFMoviePlayerController");
    if (ijk) {
        GSSwizzleInst(ijk, @selector(initWithContentURLString:), (IMP)h_ijk_s, &o_ijk_s);
        GSSwizzleInst(ijk, @selector(initWithContentURLString:withOptions:), (IMP)h_ijk_so, &o_ijk_so);
        GSSwizzleInst(ijk, @selector(initWithContentURL:), (IMP)h_ijk_u, &o_ijk_u);
        GSSwizzleInst(ijk, @selector(initWithContentURL:withOptions:), (IMP)h_ijk_uo, &o_ijk_uo);
        GSSwizzleInst(ijk, @selector(setDataSource:), (IMP)h_ijk_ds, &o_ijk_ds);
        GSSwizzleInst(ijk, @selector(prepareToPlay), (IMP)h_ijk_prep, &o_ijk_prep);
    }
    Class fvp = NSClassFromString(@"FVPVideoPlayer");
    if (fvp)
        GSSwizzleInst(fvp, @selector(initWithURL:httpHeaders:avFactory:registrar:), (IMP)h_fvp_url,
                      &o_fvp_url);
    Class fvpt = NSClassFromString(@"FVPTextureBasedVideoPlayer");
    if (fvpt) {
        SEL s = NSSelectorFromString(
            @"initWithURL:frameUpdater:displayLink:httpHeaders:avFactory:registrar:onDisposed:");
        GSSwizzleInst(fvpt, s, (IMP)h_fvpt_url, &o_fvpt_url);
    }
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
    Class sess = [NSURLSession class];
    GSSwizzleInst(sess, @selector(dataTaskWithRequest:), (IMP)h_sess_req, &o_sess_req);
    GSSwizzleInst(sess, @selector(dataTaskWithURL:), (IMP)h_sess_url, &o_sess_url);
    GSSwizzleInst(sess, @selector(dataTaskWithRequest:completionHandler:), (IMP)h_sess_req_c,
                  &o_sess_req_c);
    GSSwizzleInst(sess, @selector(dataTaskWithURL:completionHandler:), (IMP)h_sess_url_c, &o_sess_url_c);
    if (!o_json) {
        Class meta = object_getClass((id)[NSJSONSerialization class]);
        Method mm =
            class_getInstanceMethod(meta, @selector(JSONObjectWithData:options:error:));
        if (mm) {
            o_json = method_getImplementation(mm);
            method_setImplementation(mm, (IMP)h_json);
            gHooksOK = YES;
        }
    }
}

#pragma mark - NAS push

static void GSPushToNAS(void) {
    if (gURL.length == 0) {
        GSToast(@"无视频URL，无法推送");
        return;
    }
    NSString *title = gTitle.length ? gTitle : @"未命名视频";
    // 清理标题中不适合做文件名的字符
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"\\/:*?\"<>|\n\r\t"];
    title = [[title componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    if (title.length > 80) title = [title substringToIndex:80];

    NSDictionary *body = @{@"url" : gURL, @"title" : title};
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (!json) {
        GSToast(@"构造请求失败");
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGSNASDownloadURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = json;
    req.timeoutInterval = 15;

    GSToast(@"正在推送到 NAS…");
    [[[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
              if (error) {
                  GSToast([NSString stringWithFormat:@"推送失败: %@", error.localizedDescription]);
                  return;
              }
              NSInteger code = 0;
              NSString *msg = @"";
              if (data.length) {
                  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                  if ([obj isKindOfClass:[NSDictionary class]]) {
                      code = [obj[@"code"] integerValue];
                      msg = [obj[@"msg"] description] ?: @"";
                  }
              }
              NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
              if (code == 200 || http.statusCode == 200) {
                  GSToast(msg.length ? msg : @"已加入 NAS 下载队列");
              } else {
                  GSToast([NSString stringWithFormat:@"推送异常 HTTP %ld %@", (long)http.statusCode,
                                                     msg]);
              }
            });
          }] resume];
}

#pragma mark - Panel UI

@interface GSPlayerInfoTapTarget : NSObject
+ (instancetype)shared;
- (void)onFab;
- (void)onTick;
- (void)onClosePanel;
- (void)onCopyTitle;
- (void)onCopyURL;
- (void)onPushNAS;
- (void)onIJKNote:(NSNotification *)n;
@end

static void GSRefreshPanelLabels(void) {
    if (gLabRes)
        gLabRes.text = [NSString stringWithFormat:@"分辨率：%@", GSResText()];
    if (gLabTitle)
        gLabTitle.text =
            [NSString stringWithFormat:@"标题：%@", gTitle.length ? gTitle : @"(未获取，点此重试复制)"];
    if (gLabURL)
        gLabURL.text = [NSString stringWithFormat:@"URL：%@", gURL.length ? gURL : @"(未获取)"];
    gBtnNas.enabled = gURL.length > 0;
    gBtnNas.alpha = gURL.length ? 1.0 : 0.45;
}

static void GSHidePanel(void) {
    if (!gPanel) return;
    [UIView animateWithDuration:0.2
        animations:^{ gPanel.alpha = 0; }
        completion:^(BOOL f) {
          gPanel.hidden = YES;
        }];
}

static void GSShowPanel(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;

    // 打开前再抓一次标题
    GSScanTitleFromUI();
    if (gTitle.length < 2) GSOcrTopTitle();
    if (gLastAV) GSSampleAV(gLastAV);
    if (gLastIJK) GSSampleIJK(gLastIJK);

    if (!gPanel) {
        CGFloat W = MIN(win.bounds.size.width - 32, 360);
        CGFloat H = 320;
        gPanel = [[UIView alloc] initWithFrame:CGRectMake((win.bounds.size.width - W) / 2,
                                                          (win.bounds.size.height - H) / 2, W, H)];
        gPanel.backgroundColor = [[UIColor colorWithWhite:0.12 alpha:1] colorWithAlphaComponent:0.94];
        gPanel.layer.cornerRadius = 14;
        gPanel.clipsToBounds = YES;
        gPanel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        gPanel.layer.borderWidth = 1;

        UILabel *head = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, W - 60, 24)];
        head.text = @"播放信息";
        head.textColor = UIColor.whiteColor;
        head.font = [UIFont boldSystemFontOfSize:17];
        [gPanel addSubview:head];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(W - 44, 8, 36, 36);
        [close setTitle:@"✕" forState:UIControlStateNormal];
        [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont systemFontOfSize:18];
        [close addTarget:[GSPlayerInfoTapTarget shared]
                      action:@selector(onClosePanel)
            forControlEvents:UIControlEventTouchUpInside];
        [gPanel addSubview:close];

        gLabRes = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, W - 32, 22)];
        gLabRes.textColor = [UIColor colorWithWhite:0.9 alpha:1];
        gLabRes.font = [UIFont systemFontOfSize:14];
        [gPanel addSubview:gLabRes];

        gLabTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 78, W - 32, 56)];
        gLabTitle.textColor = [UIColor colorWithRed:0.6 green:0.9 blue:1 alpha:1];
        gLabTitle.font = [UIFont systemFontOfSize:14];
        gLabTitle.numberOfLines = 3;
        gLabTitle.userInteractionEnabled = YES;
        UITapGestureRecognizer *t1 =
            [[UITapGestureRecognizer alloc] initWithTarget:[GSPlayerInfoTapTarget shared]
                                                    action:@selector(onCopyTitle)];
        [gLabTitle addGestureRecognizer:t1];
        [gPanel addSubview:gLabTitle];

        gLabURL = [[UILabel alloc] initWithFrame:CGRectMake(16, 140, W - 32, 72)];
        gLabURL.textColor = [UIColor colorWithRed:0.55 green:1 blue:0.65 alpha:1];
        gLabURL.font = [UIFont systemFontOfSize:12];
        gLabURL.numberOfLines = 4;
        gLabURL.userInteractionEnabled = YES;
        UITapGestureRecognizer *t2 =
            [[UITapGestureRecognizer alloc] initWithTarget:[GSPlayerInfoTapTarget shared]
                                                    action:@selector(onCopyURL)];
        [gLabURL addGestureRecognizer:t2];
        [gPanel addSubview:gLabURL];

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 214, W - 32, 18)];
        hint.text = @"提示：点标题复制标题 · 点URL复制链接";
        hint.textColor = [UIColor colorWithWhite:0.6 alpha:1];
        hint.font = [UIFont systemFontOfSize:11];
        [gPanel addSubview:hint];

        gBtnNas = [UIButton buttonWithType:UIButtonTypeCustom];
        gBtnNas.frame = CGRectMake(16, 242, W - 32, 48);
        gBtnNas.backgroundColor = [UIColor colorWithRed:0.2 green:0.55 blue:0.95 alpha:1];
        gBtnNas.layer.cornerRadius = 10;
        [gBtnNas setTitle:@"推送到 NAS 下载" forState:UIControlStateNormal];
        [gBtnNas setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gBtnNas.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [gBtnNas addTarget:[GSPlayerInfoTapTarget shared]
                      action:@selector(onPushNAS)
            forControlEvents:UIControlEventTouchUpInside];
        [gPanel addSubview:gBtnNas];

        [win addSubview:gPanel];
    } else if (gPanel.superview != win) {
        [gPanel removeFromSuperview];
        [win addSubview:gPanel];
    }

    // 居中
    CGFloat W = gPanel.bounds.size.width, H = gPanel.bounds.size.height;
    gPanel.center = CGPointMake(win.bounds.size.width / 2, win.bounds.size.height / 2);
    gPanel.bounds = CGRectMake(0, 0, W, H);
    gPanel.hidden = NO;
    gPanel.alpha = 0;
    [win bringSubviewToFront:gPanel];
    GSRefreshPanelLabels();
    [UIView animateWithDuration:0.2 animations:^{ gPanel.alpha = 1; }];

    // 延迟再 OCR 一次刷新面板
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     GSScanTitleFromUI();
                     GSRefreshPanelLabels();
                   });
}

static void GSLayoutFab(void) {
    UIWindow *win = GSKeyWindow();
    if (!win || !gBtn) return;
    CGFloat top = 56;
    if (@available(iOS 11.0, *)) top = win.safeAreaInsets.top + 10;
    // 原约 50pt，缩小 50% → 25pt
    CGFloat side = 25;
    gBtn.frame = CGRectMake(win.bounds.size.width - side - 12, top, side, side);
    gBtn.layer.cornerRadius = side / 2.0;
    [win bringSubviewToFront:gBtn];
    if (gPanel && !gPanel.hidden) [win bringSubviewToFront:gPanel];
}

static void GSEnsureFab(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    if (!gBtn) {
        gBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        // 灰白色半透明
        gBtn.backgroundColor = [UIColor colorWithWhite:0.92 alpha:0.45];
        [gBtn setTitle:@"i" forState:UIControlStateNormal];
        [gBtn setTitleColor:[UIColor colorWithWhite:0.25 alpha:0.85] forState:UIControlStateNormal];
        gBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        gBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        gBtn.layer.borderWidth = 0.5;
        gBtn.clipsToBounds = YES;
        [gBtn addTarget:[GSPlayerInfoTapTarget shared]
                      action:@selector(onFab)
            forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:gBtn];
    } else if (gBtn.superview != win) {
        [gBtn removeFromSuperview];
        [win addSubview:gBtn];
    }
    GSLayoutFab();
}

@implementation GSPlayerInfoTapTarget
+ (instancetype)shared {
    static GSPlayerInfoTapTarget *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [GSPlayerInfoTapTarget new]; });
    return s;
}
- (void)onFab {
    if (gPanel && !gPanel.hidden) {
        GSHidePanel();
        return;
    }
    if (gLastAV) GSSampleAV(gLastAV);
    if (gLastIJK) GSSampleIJK(gLastIJK);
    GSScanTitleFromUI();
    if (gTitle.length < 2) GSOcrTopTitle();
    GSShowPanel();
}
- (void)onClosePanel {
    GSHidePanel();
}
- (void)onCopyTitle {
    GSScanTitleFromUI();
    if (gTitle.length < 2) {
        GSOcrTopTitle();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         if (gTitle.length) {
                             UIPasteboard.generalPasteboard.string = gTitle;
                             GSToast(@"已复制标题");
                             GSRefreshPanelLabels();
                         } else {
                             GSToast(@"暂无标题");
                         }
                       });
        return;
    }
    UIPasteboard.generalPasteboard.string = gTitle;
    GSToast(@"已复制标题");
}
- (void)onCopyURL {
    if (!gURL.length) {
        GSToast(@"暂无URL");
        return;
    }
    UIPasteboard.generalPasteboard.string = gURL;
    GSToast(@"已复制URL");
}
- (void)onPushNAS {
    GSScanTitleFromUI();
    GSPushToNAS();
}
- (void)onTick {
    GSInstallHooks();
    GSEnsureFab();
    if (gLastAV) GSSampleAV(gLastAV);
    if (gLastIJK) GSSampleIJK(gLastIJK);
    if (gURL.length || gLastAV || gLastIJK) {
        GSScanTitleFromUI();
        if (gTitle.length < 2) GSOcrTopTitle();
    }
    if (gPanel && !gPanel.hidden) GSRefreshPanelLabels();
}
- (void)onIJKNote:(NSNotification *)n {
    GSSampleIJK(n.object);
}
@end

#pragma mark - Boot

static void GSBoot(void) {
    GSInstallHooks();
    GSEnsureFab();
    GSPlayerInfoTapTarget *t = [GSPlayerInfoTapTarget shared];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:t selector:@selector(onTick) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:t
            selector:@selector(onIJKNote:)
                name:@"IJKMPMovieNaturalSizeAvailableNotification"
              object:nil];
    [nc addObserver:t
            selector:@selector(onIJKNote:)
                name:@"IJKMPMoviePlayerFirstVideoFrameRenderedNotification"
              object:nil];
    [NSTimer scheduledTimerWithTimeInterval:1.0 target:t selector:@selector(onTick) userInfo:nil repeats:YES];
}

__attribute__((constructor)) static void GSPlayerInfoInit(void) {
    // 无启动弹框、无顶栏
    if ([NSThread isMainThread])
        GSBoot();
    else
        dispatch_async(dispatch_get_main_queue(), ^{ GSBoot(); });
    for (int i = 1; i <= 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         GSInstallHooks();
                         GSEnsureFab();
                       });
    }
}
