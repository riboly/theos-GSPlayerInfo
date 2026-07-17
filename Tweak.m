/*
 * GSPlayerInfo — 强抓 URL + 标题版
 *
 * 标题在 Flutter 顶栏绘制（如「时间静止の…」），JSON 里常无 video_name。
 * 策略：无障碍树 + UILabel/UIText 扫描屏幕上半区中文标题；
 * URL 仍走 AV/IJK/FVP/NSURLSession；复制格式：标题----URL
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
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

static BOOL GSIsNoiseHost(NSString *u) {
    NSString *l = u.lowercaseString;
    return [l containsString:@"umeng"] || [l containsString:@"umengcloud"] ||
           [l containsString:@"apple.com"] || [l containsString:@"icloud.com"] ||
           [l containsString:@"crashlytics"] || [l containsString:@"firebase"] ||
           [l containsString:@"googleapis"] || [l containsString:@"adjust.com"] ||
           [l containsString:@"sentry.io"] || [l containsString:@"bugly"];
}

static BOOL GSLooksMediaURL(NSString *u) {
    if (u.length < 8) return NO;
    if (GSIsNoiseHost(u)) return NO;
    NSString *l = u.lowercaseString;
    if (!([l hasPrefix:@"http://"] || [l hasPrefix:@"https://"] || [l hasPrefix:@"file://"])) return NO;
    return [l containsString:@".m3u8"] || [l containsString:@"m3u8"] || [l containsString:@".mp4"] ||
           [l containsString:@".flv"] || [l containsString:@".ts"] || [l containsString:@"/hls/"] ||
           [l containsString:@"playlist"] || [l containsString:@"getvideourl"] ||
           [l containsString:@"/h5/m3u8"] || [l containsString:@"film_m3u8"] ||
           [l containsString:@"short_m3u8"] || [l containsString:@"play_url"];
}

static void GSRememberURL(NSString *u, NSString *source) {
    if (u.length == 0 || GSIsNoiseHost(u)) return;
    BOOL media = GSLooksMediaURL(u) || [source hasPrefix:@"AV"] || [source hasPrefix:@"IJK"] ||
                 [source hasPrefix:@"FVP"];
    if (!media && ![source hasPrefix:@"JSON"]) {
        gLastNet = [u copy];
        return; // 不把友盟等写进主 URL / 历史
    }
    if (!gURLHistory) gURLHistory = [NSMutableArray array];
    @synchronized (gURLHistory) {
        if (gURLHistory.count == 0 || ![gURLHistory.lastObject isEqualToString:u]) {
            [gURLHistory addObject:u];
            if (gURLHistory.count > 12) [gURLHistory removeObjectAtIndex:0];
        }
    }
    gURL = [u copy];
    if (source.length) gExtra = [source copy];
}

static BOOL GSHasCJK(NSString *s) {
    if (s.length == 0) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3040 && c <= 0x30FF) || (c >= 0x3000 && c <= 0x303F))
            return YES;
    }
    return NO;
}

static BOOL GSLooksLikeTitle(NSString *t) {
    if (t.length < 2 || t.length > 120) return NO;
    if ([t hasPrefix:@"http"] || [t containsString:@"m3u8"] || [t containsString:@".mp4"]) return NO;
    if ([t isEqualToString:@"null"] || [t isEqualToString:@"undefined"]) return NO;
    // 排除控件/我们自己的 UI
    NSArray *bad = @[
        @"关闭", @"复制", @"好的", @"播放信息", @"分辨率", @"当前URL", @"来源", @"hooks", @"GS",
        @"1.0X", @"1.0x", @"全屏", @"倍速", @"选集", @"i", @"OK", @"NO"
    ];
    for (NSString *b in bad) {
        if ([t isEqualToString:b] || [t hasPrefix:@"[GS"] || [t hasPrefix:@"【GS"]) return NO;
    }
    // 时间码 00:06 / 01:16:15
    if ([t rangeOfString:@"^\\d{1,2}:\\d{2}(:\\d{2})?$" options:NSRegularExpressionSearch].location != NSNotFound)
        return NO;
    // 优先中日文标题；也允许较长的非纯数字
    if (GSHasCJK(t)) return YES;
    if (t.length >= 6 && [t rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == NSNotFound)
        return t.length >= 8;
    return NO;
}

static void GSRememberTitle(NSString *t) {
    if (!GSLooksLikeTitle(t)) return;
    // 更长/更像片名的覆盖短噪声
    if (gTitle.length > 0 && t.length < gTitle.length && GSHasCJK(gTitle)) return;
    gTitle = [t copy];
}

static void GSRememberSize(CGFloat w, CGFloat h) {
    if (w > 1 && h > 1 && w < 10000 && h < 10000) {
        gW = (NSInteger)(w + 0.5);
        gH = (NSInteger)(h + 0.5);
    }
}

static void GSUpdateBannerText(void); // fwd
static void GSScanTitleFromUI(void);

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

static NSString *GSCopyPayload(void) {
    NSString *t = gTitle.length ? gTitle : @"(无标题)";
    NSString *u = gURL.length ? gURL : @"(无URL)";
    return [NSString stringWithFormat:@"%@----%@", t, u];
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
            @"分辨率: %@\n\n标题: %@\n\n当前URL:\n%@\n\n来源: %@\n\nhooks=%@\n\n最近媒体URL:%@\n\n复制格式:\n标题----URL",
            res,
            gTitle.length ? gTitle : @"(无)",
            gURL.length ? gURL : @"(无)",
            gExtra.length ? gExtra : @"?",
            gHooksOK ? @"OK" : @"NO",
            hist.length ? hist : @"\n(无)"];
}

static void GSShowAlert(NSString *title) {
    dispatch_async(dispatch_get_main_queue(), ^{
        GSScanTitleFromUI();
        UIViewController *vc = GSTopVC();
        if (!vc || vc.presentedViewController) return;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:title ?: @"播放信息"
                                                message:GSInfoText()
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"复制 标题----URL"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
                                                  GSScanTitleFromUI();
                                                  UIPasteboard.generalPasteboard.string = GSCopyPayload();
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
        NSString *shortURL = gURL.length ? gURL : @"等待播放…";
        if (shortURL.length > 42)
            shortURL = [NSString stringWithFormat:@"%@…%@",
                                                  [shortURL substringToIndex:16],
                                                  [shortURL substringFromIndex:shortURL.length - 18]];
        NSString *res = (gW > 0 && gH > 0)
            ? [NSString stringWithFormat:@"%ldx%ld", (long)gW, (long)gH]
            : @"?x?";
        NSString *tt = gTitle.length ? gTitle : @"(无标题)";
        if (tt.length > 18) tt = [[tt substringToIndex:18] stringByAppendingString:@"…"];
        gBanner.text = [NSString stringWithFormat:@"%@ | %@\n%@", res, tt, shortURL];
        gBanner.numberOfLines = 2;
        gBanner.adjustsFontSizeToFitWidth = YES;
    });
}

#pragma mark - Title from UI (Flutter 顶栏文案)

static void GSCollectTitleCandidate(NSString *text, CGFloat midY, CGFloat screenH,
                                    NSMutableArray<NSDictionary *> *out) {
    if (!GSLooksLikeTitle(text)) return;
    // 播放器标题一般在屏幕上半部分
    if (screenH > 0 && midY > screenH * 0.55) return;
    [out addObject:@{@"t" : text, @"y" : @(midY), @"len" : @(text.length)}];
}

static void GSWalkViewForTitle(UIView *view, int depth, CGFloat screenH,
                               NSMutableArray<NSDictionary *> *out) {
    if (!view || depth > 18 || view.hidden || view.alpha < 0.05) return;
    // 跳过我们自己的控件
    if (view == gBanner || view == gBtn) return;
    if ([view isKindOfClass:[UIAlertController class]]) return;

    CGRect fr = [view convertRect:view.bounds toView:nil];
    CGFloat midY = CGRectGetMidY(fr);

    if ([view isKindOfClass:[UILabel class]]) {
        GSCollectTitleCandidate(((UILabel *)view).text, midY, screenH, out);
    } else if ([view isKindOfClass:[UITextView class]]) {
        GSCollectTitleCandidate(((UITextView *)view).text, midY, screenH, out);
    } else if ([view isKindOfClass:[UIButton class]]) {
        NSString *bt = [(UIButton *)view titleForState:UIControlStateNormal];
        // 按钮文字通常不是片名
        if (bt.length > 8) GSCollectTitleCandidate(bt, midY, screenH, out);
    }

    NSString *acc = view.accessibilityLabel;
    if (acc.length) GSCollectTitleCandidate(acc, midY, screenH, out);
    NSString *hint = view.accessibilityValue;
    if ([hint isKindOfClass:[NSString class]] && hint.length)
        GSCollectTitleCandidate(hint, midY, screenH, out);

    // Flutter semantics 元素
    NSArray *els = nil;
    @try {
        if (view.isAccessibilityElement == NO && [view respondsToSelector:@selector(accessibilityElements)]) {
            els = view.accessibilityElements;
        }
    } @catch (__unused NSException *e) {}
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
            } @catch (__unused NSException *e) {}
            if (lab.length) GSCollectTitleCandidate(lab, y, screenH, out);
        }
    }

    for (UIView *sub in view.subviews) {
        GSWalkViewForTitle(sub, depth + 1, screenH, out);
    }
}

static void GSScanTitleFromUI(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    CGFloat screenH = win.bounds.size.height;
    NSMutableArray<NSDictionary *> *cands = [NSMutableArray array];
    GSWalkViewForTitle(win, 0, screenH, cands);
    // 也扫其它 window（Flutter 有时多层）
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w == win) continue;
                GSWalkViewForTitle(w, 0, screenH, cands);
            }
        }
    }
    if (cands.count == 0) return;

    // 优先：更靠上 + 更长 + 含 CJK
    [cands sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        CGFloat ya = [a[@"y"] doubleValue], yb = [b[@"y"] doubleValue];
        if (ya < yb - 8) return NSOrderedAscending;
        if (yb < ya - 8) return NSOrderedDescending;
        NSInteger la = [a[@"len"] integerValue], lb = [b[@"len"] integerValue];
        if (la > lb) return NSOrderedAscending;
        if (lb > la) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    for (NSDictionary *c in cands) {
        NSString *t = c[@"t"];
        if (GSHasCJK(t)) {
            GSRememberTitle(t);
            GSUpdateBannerText();
            return;
        }
    }
    // 没有中文则取排序第一
    GSRememberTitle(cands.firstObject[@"t"]);
    GSUpdateBannerText();
}

// Flutter Text 常不进无障碍树：截取顶部条做 OCR
static NSTimeInterval gLastOCR = 0;
static void GSOcrTitleFromTopBand(void) {
    if (gTitle.length >= 4 && GSHasCJK(gTitle)) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastOCR < 2.5) return; // 节流
    gLastOCR = now;

    UIWindow *win = GSKeyWindow();
    if (!win) return;
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat topInset = 0;
    if (@available(iOS 11.0, *)) topInset = win.safeAreaInsets.top;
    // 顶栏标题带：状态栏下约 56pt 高
    CGRect band = CGRectMake(40, topInset, win.bounds.size.width - 100, 56);
    if (band.size.width < 50) return;

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
        [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
          if (error || request.results.count == 0) return;
          NSMutableArray<NSString *> *parts = [NSMutableArray array];
          NSMutableString *joined = [NSMutableString string];
          for (VNRecognizedTextObservation *obs in request.results) {
              NSString *s = [obs topCandidates:1].firstObject.string;
              if (s.length == 0) continue;
              [parts addObject:s];
              if (joined.length) [joined appendString:s];
              else [joined appendString:s];
          }
          NSString *best = nil;
          for (NSString *s in parts) {
              if (GSLooksLikeTitle(s) && GSHasCJK(s)) {
                  if (!best || s.length > best.length) best = s;
              }
          }
          if ((!best || best.length < 4) && joined.length >= 4 && GSLooksLikeTitle(joined))
              best = joined;
          if (best.length) {
              dispatch_async(dispatch_get_main_queue(), ^{
                GSRememberTitle(best);
                GSUpdateBannerText();
              });
          }
        }];
    if (@available(iOS 16.0, *)) {
        req.revision = VNRecognizeTextRequestRevision3;
    }
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;
    // 中日文
    if (@available(iOS 14.0, *)) {
        req.recognitionLanguages = @[ @"zh-Hans", @"zh-Hant", @"ja", @"en" ];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError *err = nil;
      [handler performRequests:@[ req ] error:&err];
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
                @"film_name", @"movieName", @"mediaName", @"caption", @"play_title",
                @"playTitle", @"videoTitle", @"video_title", @"mv_name", @"mvName",
                @"subject", @"headline", @"desc", @"description"
            ];
        });
        BOOL gotUrl = NO;
        NSString *localTitle = nil;
        for (NSString *k in urlKeys) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]] && GSLooksMediaURL(v)) {
                GSRememberURL(v, [@"JSON:" stringByAppendingString:k]);
                gotUrl = YES;
            }
        }
        for (NSString *k in titleKeys) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]] && GSLooksLikeTitle(v)) {
                localTitle = v;
                GSRememberTitle(v);
            }
        }
        // 同层既有媒体 URL 又有标题时加强记忆
        if (gotUrl && localTitle.length) GSRememberTitle(localTitle);
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
    // 信息条放底部，避免挡住播放器顶栏标题（Flutter 标题在顶部）
    CGFloat bottom = 8;
    if (@available(iOS 11.0, *)) bottom = win.safeAreaInsets.bottom + 6;
    CGFloat bannerH = 40;
    CGFloat bannerY = b.size.height - bottom - bannerH - 52; // 避开进度条/底部控件
    if (bannerY < 80) bannerY = b.size.height * 0.72;
    if (gBanner) {
        if (gBanner.superview != win) {
            [gBanner removeFromSuperview];
            [win addSubview:gBanner];
        }
        gBanner.frame = CGRectMake(0, bannerY, b.size.width, bannerH);
        [win bringSubviewToFront:gBanner];
    }
    if (gBtn) {
        if (gBtn.superview != win) {
            [gBtn removeFromSuperview];
            [win addSubview:gBtn];
        }
        // 按钮仍靠右上，方便点
        CGFloat top = 50;
        if (@available(iOS 11.0, *)) top = win.safeAreaInsets.top + 8;
        gBtn.frame = CGRectMake(b.size.width - 58, top, 50, 50);
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
    GSScanTitleFromUI();
    if (gTitle.length < 2) {
        // 先 OCR 再弹框（稍延迟等识别完成）
        GSOcrTitleFromTopBand();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ GSShowAlert(@"播放信息 / URL"); });
    } else {
        GSShowAlert(@"播放信息 / URL");
    }
}
- (void)onTick {
    GSInstallHooks();
    GSEnsureUI();
    if (gLastIJK) GSSampleIJK(gLastIJK);
    if (gLastAV) GSSampleAV(gLastAV);
    // 播放中周期性扫顶栏标题（无障碍 + OCR）
    if (gURL.length > 0 || gLastAV || gLastIJK) {
        GSScanTitleFromUI();
        if (gTitle.length < 2) GSOcrTitleFromTopBand();
    }
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
