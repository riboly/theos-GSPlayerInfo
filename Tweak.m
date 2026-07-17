/*
 * GSPlayerInfo — 基于稳定备份 + 多源标题/手动选取
 * - 不去 hook NSURLSession completion（进播放器闪退主因）
 * - m3u8 抓取带 re-entry 保护
 * - 标题源：A11y / DES(flutter_des) / JSON / OCR / AVMeta / M3U8
 * - 默认自动优选；面板可手动点选某一来源
 * - 过滤 snake_case 技术串；无启动弹框
 * - 不使用 fishhook 强开 VoiceOver（避免启动崩溃）
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>

static NSString *const kGSNASDownloadURL = @"http://192.168.6.110:38617/api/download";

#pragma mark - State

static NSString *gURL = @"";
static NSString *gExtra = @"";
static NSInteger gW = 0, gH = 0;
static BOOL gHooksOK = NO;

typedef NS_ENUM(NSInteger, GSTitleSrc) {
    GSTitleSrcNone = 0, // 自动
    GSTitleSrcA11y = 1,
    GSTitleSrcDES = 2,
    GSTitleSrcJSON = 3,
    GSTitleSrcOCR = 4,
    GSTitleSrcAVMeta = 5,
    GSTitleSrcM3U8 = 6,
};

static NSString *gTitleJSON = @"";
static NSString *gTitleAVMeta = @"";
static NSString *gTitleM3U8 = @"";
static NSString *gTitleA11y = @"";
static NSString *gTitleOCR = @"";
static NSString *gTitleDES = @"";
static NSString *gTitleBest = @"";
static GSTitleSrc gTitlePick = GSTitleSrcNone; // 手动选用；None=自动

static UIButton *gBtn = nil;
static UIView *gPanel = nil;
static UILabel *gLabRes = nil, *gLabTitle = nil, *gLabURL = nil, *gLabDebug = nil;
static UIButton *gBtnNas = nil;
static NSMutableArray<UIButton *> *gSrcBtns = nil;
static id gLastIJK = nil;
static AVPlayer *gLastAV = nil;
static NSTimeInterval gLastOCR = 0;
static NSTimeInterval gLastMeta = 0;
static NSTimeInterval gLastM3U8Fetch = 0;
static NSString *gLastM3U8URL = @"";
static NSString *gOCRBoundURL = @""; // 当前 OCR 结果对应的播放 URL
static NSUInteger gPlayGen = 0;     // 换片代数，丢弃过期异步 OCR
static CGPoint gFabOffset = {0, 0};
static BOOL gFabMoved = NO;
static volatile BOOL gInOurNetwork = NO; // 防止我们自己的请求再进 hook 逻辑
static BOOL gDesHooked = NO;

// 换片：清空各源标题，避免 OCR/A11y 等残留上一条
static void GSResetTitlesForNewMedia(void) {
    gTitleJSON = @"";
    gTitleAVMeta = @"";
    gTitleM3U8 = @"";
    gTitleA11y = @"";
    gTitleOCR = @"";
    gTitleDES = @"";
    gTitleBest = @"";
    gOCRBoundURL = @"";
    gLastOCR = 0;
    gLastMeta = 0;
    gLastM3U8Fetch = 0;
    gLastM3U8URL = @"";
    gPlayGen++;
}

#pragma mark - String helpers

static BOOL GSHasCJK(NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3040 && c <= 0x30FF) ||
            (c >= 0x3000 && c <= 0x303F) || c == 0x30FB)
            return YES;
    }
    return NO;
}

static BOOL GSIsTechIdentifier(NSString *t) {
    if (t.length == 0) return YES;
    NSString *l = t.lowercaseString;
    if ([l rangeOfString:@"^[a-z][a-z0-9_]*$" options:NSRegularExpressionSearch].location != NSNotFound) {
        if ([l containsString:@"_"]) return YES;
    }
    NSArray *bad = @[
        @"hierarchical", @"inner_product", @"tensor", @"embedding", @"layer", @"model",
        @"softmax", @"relu", @"conv", @"logits", @"weight", @"bias", @"flutter", @"dart",
        @"null", @"undefined", @"object", @"true", @"false"
    ];
    for (NSString *b in bad)
        if ([l containsString:b]) return YES;
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:"];
    if ([t rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound && !GSHasCJK(t))
        return YES;
    return NO;
}

static BOOL GSLooksLikeTitle(NSString *t) {
    if (t.length < 2 || t.length > 150) return NO;
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return NO;
    if ([t hasPrefix:@"http"] || [t containsString:@"m3u8"] || [t containsString:@".mp4"]) return NO;
    if (GSIsTechIdentifier(t)) return NO;
    NSArray *noise = @[
        @"关闭", @"复制", @"播放信息", @"分辨率", @"视频标题", @"视频URL", @"推送到", @"NAS", @"调试",
        @"1.0X", @"全屏", @"倍速", @"i", @"AVPlayer", @"JSON", @"OCR", @"A11y", @"DES", @"Meta", @"M3U8",
        @"未获取", @"等待", @"hooks", @"自动", @"选用", @"标题来源"
    ];
    for (NSString *b in noise)
        if ([t isEqualToString:b]) return NO;
    if ([t rangeOfString:@"^\\d{1,2}:\\d{2}(:\\d{2})?$" options:NSRegularExpressionSearch].location !=
        NSNotFound)
        return NO;
    // 本 App 片名必须含中日文
    return GSHasCJK(t);
}

static BOOL GSIsNoiseHost(NSString *u) {
    NSString *l = u.lowercaseString;
    return [l containsString:@"umeng"] || [l containsString:@"apple.com"] ||
           [l containsString:@"firebase"] || [l containsString:@"googleapis"] ||
           [l containsString:@"crashlytics"] || [l containsString:@"sentry"] ||
           [l containsString:@"bugly"] || [l containsString:@"icloud.com"];
}

static BOOL GSLooksMediaURL(NSString *u) {
    if (u.length < 8 || GSIsNoiseHost(u)) return NO;
    NSString *l = u.lowercaseString;
    if (!([l hasPrefix:@"http://"] || [l hasPrefix:@"https://"])) return NO;
    return [l containsString:@"m3u8"] || [l containsString:@".mp4"] || [l containsString:@"/hls/"] ||
           [l containsString:@"/h5/m3u8"] || [l containsString:@"film_m3u8"] ||
           [l containsString:@"getvideourl"] || [l containsString:@"play_url"] ||
           [l containsString:@"playlist"] || [l containsString:@".flv"];
}

static NSString *GSTitleOfSrc(GSTitleSrc src) {
    switch (src) {
        case GSTitleSrcA11y: return gTitleA11y;
        case GSTitleSrcDES: return gTitleDES;
        case GSTitleSrcJSON: return gTitleJSON;
        case GSTitleSrcOCR: return gTitleOCR;
        case GSTitleSrcAVMeta: return gTitleAVMeta;
        case GSTitleSrcM3U8: return gTitleM3U8;
        default: return @"";
    }
}

static NSString *GSSrcName(GSTitleSrc src) {
    switch (src) {
        case GSTitleSrcA11y: return @"A11y";
        case GSTitleSrcDES: return @"DES";
        case GSTitleSrcJSON: return @"JSON";
        case GSTitleSrcOCR: return @"OCR";
        case GSTitleSrcAVMeta: return @"AVMeta";
        case GSTitleSrcM3U8: return @"M3U8";
        default: return @"自动";
    }
}

// 自动优先：A11y(画面上真标题) > DES(站点解密明文) > JSON > OCR > AVMeta > M3U8
static GSTitleSrc GSAutoPickSource(void) {
    GSTitleSrc order[] = {
        GSTitleSrcA11y, GSTitleSrcDES, GSTitleSrcJSON,
        GSTitleSrcOCR, GSTitleSrcAVMeta, GSTitleSrcM3U8
    };
    for (size_t i = 0; i < sizeof(order) / sizeof(order[0]); i++) {
        NSString *t = GSTitleOfSrc(order[i]);
        if (GSLooksLikeTitle(t)) return order[i];
    }
    return GSTitleSrcNone;
}

static void GSRecomputeBestTitle(void) {
    GSTitleSrc autoSrc = GSAutoPickSource();
    gTitleBest = GSLooksLikeTitle(GSTitleOfSrc(autoSrc)) ? [GSTitleOfSrc(autoSrc) copy] : @"";
}

// 面板/复制/NAS 实际用的标题：手动优先，否则自动
static NSString *GSEffectiveTitle(void) {
    if (gTitlePick != GSTitleSrcNone) {
        NSString *t = GSTitleOfSrc(gTitlePick);
        if (t.length) return t; // 手动指定的即使略弱也展示，方便调试
    }
    GSRecomputeBestTitle();
    return gTitleBest ?: @"";
}

static void GSSetTitle(NSString *t, NSString *source) {
    if (!GSLooksLikeTitle(t)) return;
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([source isEqualToString:@"JSON"])
        gTitleJSON = t;
    else if ([source isEqualToString:@"A11y"])
        gTitleA11y = t;
    else if ([source isEqualToString:@"OCR"])
        gTitleOCR = t;
    else if ([source isEqualToString:@"AVMeta"])
        gTitleAVMeta = t;
    else if ([source isEqualToString:@"M3U8"])
        gTitleM3U8 = t;
    else if ([source isEqualToString:@"DES"])
        gTitleDES = t;
    GSRecomputeBestTitle();
}

static void GSScanJSON(id o, int depth); // 前置声明

// DES 解密明文：整段作标题 + 尝试当 JSON 再扫（标题同步进 DES 槽）
static void GSIngestPlaintext(NSString *text, NSString *source) {
    if (!text.length) return;
    NSString *trim = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length >= 2 && trim.length < 200 && GSLooksLikeTitle(trim))
        GSSetTitle(trim, source);
    if (trim.length < 2) return;
    BOOL maybeJSON = ([trim hasPrefix:@"{"] && [trim hasSuffix:@"}"]) ||
                     ([trim hasPrefix:@"["] && [trim hasSuffix:@"]"]);
    if (!maybeJSON) return;
    @try {
        NSData *d = [trim dataUsingEncoding:NSUTF8StringEncoding];
        id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (!obj) return;
        NSString *beforeJSON = gTitleJSON ?: @"";
        GSScanJSON(obj, 0);
        if ([source isEqualToString:@"DES"] && gTitleJSON.length &&
            ![gTitleJSON isEqualToString:beforeJSON] && GSLooksLikeTitle(gTitleJSON)) {
            gTitleDES = [gTitleJSON copy];
            GSRecomputeBestTitle();
        }
    } @catch (__unused NSException *e) {
    }
}

static void GSRememberURL(NSString *u, NSString *source) {
    if (!GSLooksMediaURL(u) &&
        !([source hasPrefix:@"AV"] || [source hasPrefix:@"IJK"] || [source hasPrefix:@"FVP"]))
        return;
    if (GSIsNoiseHost(u)) return;
    // 播放地址变了 = 新视频，清掉旧标题（含 OCR）
    if (u.length && gURL.length && ![gURL isEqualToString:u]) {
        GSResetTitlesForNewMedia();
    }
    gURL = [u copy];
    if (source.length) gExtra = [source copy];
}

static void GSRememberSize(CGFloat w, CGFloat h) {
    if (w > 1 && h > 1 && w < 10000 && h < 10000) {
        gW = (NSInteger)(w + 0.5);
        gH = (NSInteger)(h + 0.5);
    }
}

static NSString *GSResText(void) {
    return (gW > 0 && gH > 0) ? [NSString stringWithFormat:@"%ldx%ld", (long)gW, (long)gH] : @"(未获取)";
}

static NSString *GSDash(NSString *s) {
    if (!s.length) return @"-";
    if (s.length > 28) return [[s substringToIndex:28] stringByAppendingString:@"…"];
    return s;
}

static UIWindow *GSKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows)
                if (w.isKeyWindow) return w;
            if (((UIWindowScene *)scene).windows.count)
                return ((UIWindowScene *)scene).windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow ?: app.windows.firstObject;
#pragma clang diagnostic pop
}

static void GSToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
      UIWindow *win = GSKeyWindow();
      if (!win) return;
      UILabel *lab = [[UILabel alloc]
          initWithFrame:CGRectMake(40, win.bounds.size.height * 0.4, win.bounds.size.width - 80, 40)];
      lab.text = msg;
      lab.textAlignment = NSTextAlignmentCenter;
      lab.textColor = UIColor.whiteColor;
      lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
      lab.font = [UIFont systemFontOfSize:14];
      lab.layer.cornerRadius = 8;
      lab.clipsToBounds = YES;
      [win addSubview:lab];
      [UIView animateWithDuration:0.25 delay:1.2 options:0 animations:^{ lab.alpha = 0; } completion:^(BOOL f) {
        [lab removeFromSuperview];
      }];
    });
}

static void GSRefreshPanelLabels(void);

#pragma mark - AV metadata

static void GSLoadAVMetadataTitle(AVAsset *asset) {
    if (!asset) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastMeta < 2.0 && gTitleAVMeta.length) return;
    gLastMeta = now;

    @try {
        for (AVMetadataItem *it in asset.commonMetadata) {
            NSString *s = it.stringValue;
            if (!s.length && [it.value isKindOfClass:[NSString class]]) s = (NSString *)it.value;
            if (GSLooksLikeTitle(s)) {
                GSSetTitle(s, @"AVMeta");
                dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
                return;
            }
        }
    } @catch (__unused NSException *e) {
    }

    [asset loadValuesAsynchronouslyForKeys:@[ @"commonMetadata" ] completionHandler:^{
      @try {
          if ([asset statusOfValueForKey:@"commonMetadata" error:nil] != AVKeyValueStatusLoaded)
              return;
          NSArray *meta = [AVMetadataItem metadataItemsFromArray:asset.commonMetadata
                                                         withKey:AVMetadataCommonKeyTitle
                                                        keySpace:AVMetadataKeySpaceCommon];
          for (AVMetadataItem *it in meta) {
              if (GSLooksLikeTitle(it.stringValue)) {
                  GSSetTitle(it.stringValue, @"AVMeta");
                  dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
                  return;
              }
          }
      } @catch (__unused NSException *e) {
      }
    }];
}

#pragma mark - m3u8 (safe, no session swizzle re-entry)

static void GSParseM3U8ForTitle(NSString *text) {
    if (text.length < 10) return;
    NSUInteger lim = MIN(text.length, (NSUInteger)6000);
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"#EXTINF:[^,]*,\\s*(.+)"
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *m =
        [re firstMatchInString:text options:0 range:NSMakeRange(0, lim)];
    if (m.numberOfRanges > 1) {
        NSString *t = [[text substringWithRange:[m rangeAtIndex:1]]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (GSLooksLikeTitle(t)) {
            GSSetTitle(t, @"M3U8");
            return;
        }
    }
    re = [NSRegularExpression regularExpressionWithPattern:@"NAME=\"([^\"]+)\"" options:0 error:nil];
    for (NSTextCheckingResult *r in [re matchesInString:text options:0 range:NSMakeRange(0, lim)]) {
        if (r.numberOfRanges < 2) continue;
        NSString *t = [text substringWithRange:[r rangeAtIndex:1]];
        if (GSLooksLikeTitle(t)) {
            GSSetTitle(t, @"M3U8");
            return;
        }
    }
}

static void GSFetchM3U8TitleIfNeeded(NSString *url) {
    if (!url.length || ![url.lowercaseString containsString:@"m3u8"]) return;
    if ([gLastM3U8URL isEqualToString:url] && gTitleM3U8.length) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastM3U8Fetch < 3.0 && [gLastM3U8URL isEqualToString:url]) return;
    gLastM3U8Fetch = now;
    gLastM3U8URL = [url copy];

    NSURL *nsurl = [NSURL URLWithString:url];
    if (!nsurl) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:nsurl];
    req.timeoutInterval = 10;
    // 标记：走系统 session，hook 里看到 gInOurNetwork 只记 URL 不递归 fetch
    gInOurNetwork = YES;
    [[[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            gInOurNetwork = NO;
            if (err || data.length < 8) return;
            NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!txt) return;
            if (![txt containsString:@"#EXT"]) return;
            GSParseM3U8ForTitle(txt);
            dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
          }] resume];
    // 若 resume 同步失败，复位
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ gInOurNetwork = NO; });
}

#pragma mark - JSON

static void GSScanJSON(id o, int depth) {
    if (!o || depth > 6) return;
    if ([o isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)o;
        static NSArray *urlKeys, *titlePreferred;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
          urlKeys = @[
              @"playUrl", @"play_url", @"videoUrl", @"video_url", @"url", @"urlM3u8", @"mv_play_url",
              @"m3u8", @"link", @"play_url2"
          ];
          titlePreferred = @[
              @"display_title", @"displayTitle", @"video_title", @"videoTitle", @"video_name",
              @"mv_title", @"mvTitle", @"play_title", @"playTitle", @"sp91_film_subject",
              @"sp91_small_video_subject"
          ];
        });
        NSString *foundURL = nil, *foundTitle = nil;
        for (NSString *k in urlKeys) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]] && GSLooksMediaURL(v)) {
                foundURL = v;
                break;
            }
        }
        for (NSString *k in titlePreferred) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]] && GSLooksLikeTitle(v)) {
                foundTitle = v;
                break;
            }
        }
        // 弱键 title 仅中文≥4
        if (!foundTitle) {
            id v = d[@"title"];
            if ([v isKindOfClass:[NSString class]] && GSLooksLikeTitle(v) && [(NSString *)v length] >= 4)
                foundTitle = v;
        }
        if (foundURL) {
            GSRememberURL(foundURL, @"JSON");
            if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(foundURL);
        }
        if (foundTitle) GSSetTitle(foundTitle, @"JSON");

        NSInteger n = 0;
        for (id key in d) {
            id v = d[key];
            if (++n > 60) break;
            if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]])
                GSScanJSON(v, depth + 1);
        }
    } else if ([o isKindOfClass:[NSArray class]]) {
        NSInteger n = 0;
        for (id v in (NSArray *)o) {
            if (++n > 30) break;
            GSScanJSON(v, depth + 1);
        }
    }
}

#pragma mark - A11y / OCR

static void GSWalkA11y(UIView *view, int depth, CGFloat screenH, NSMutableArray *out) {
    if (!view || depth > 16 || view.hidden || view.alpha < 0.05) return;
    if (view == gBtn || view == gPanel) return;
    CGRect fr = [view convertRect:view.bounds toView:nil];
    CGFloat midY = CGRectGetMidY(fr);
    if (midY < screenH * 0.55) {
        if ([view isKindOfClass:[UILabel class]]) {
            NSString *t = ((UILabel *)view).text;
            if (GSLooksLikeTitle(t)) [out addObject:@{@"t" : t, @"y" : @(midY), @"len" : @(t.length)}];
        }
        NSString *acc = view.accessibilityLabel;
        if (GSLooksLikeTitle(acc))
            [out addObject:@{@"t" : acc, @"y" : @(midY), @"len" : @(acc.length)}];
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
                    lab = [el accessibilityLabel];
                    CGRect af = [el accessibilityFrame];
                    if (!CGRectIsEmpty(af)) y = CGRectGetMidY(af);
                } @catch (__unused NSException *e) {
                }
                if (GSLooksLikeTitle(lab))
                    [out addObject:@{@"t" : lab, @"y" : @(y), @"len" : @(lab.length)}];
            }
        }
    }
    for (UIView *s in view.subviews) GSWalkA11y(s, depth + 1, screenH, out);
}

static void GSScanA11yTitle(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    NSMutableArray *cands = [NSMutableArray array];
    GSWalkA11y(win, 0, win.bounds.size.height, cands);
    if (!cands.count) return;
    [cands sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      CGFloat ya = [a[@"y"] doubleValue], yb = [b[@"y"] doubleValue];
      if (ya < yb - 8) return NSOrderedAscending;
      if (yb < ya - 8) return NSOrderedDescending;
      return [@([b[@"len"] integerValue]) compare:@([a[@"len"] integerValue])];
    }];
    for (NSDictionary *c in cands) {
        if (GSLooksLikeTitle(c[@"t"])) {
            GSSetTitle(c[@"t"], @"A11y");
            return;
        }
    }
}

// force=YES：打开面板/复制时强制重识别；force=NO：仅当前片尚无 OCR 时补一次
static void GSOcrTopTitle(BOOL force) {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (!force) {
        // 本片已有 OCR 结果则跳过（换片会清 gTitleOCR / gOCRBoundURL）
        if (gTitleOCR.length &&
            (!gURL.length || !gOCRBoundURL.length || [gOCRBoundURL isEqualToString:gURL]))
            return;
        if (now - gLastOCR < 2.5) return;
    } else {
        // 强制也限流，避免连点 FAB 打爆 Vision
        if (now - gLastOCR < 0.7) return;
        // 先清空 OCR 槽，避免面板继续显示上一条/旧识别
        gTitleOCR = @"";
        gOCRBoundURL = @"";
        GSRecomputeBestTitle();
    }
    gLastOCR = now;
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat topInset = 0;
    if (@available(iOS 11.0, *)) topInset = win.safeAreaInsets.top;
    CGRect band = CGRectMake(56, topInset, MAX(80, win.bounds.size.width - 120), 48);
    UIGraphicsBeginImageContextWithOptions(band.size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return;
    }
    CGContextTranslateCTM(ctx, -band.origin.x, -band.origin.y);
    // afterScreenUpdates:YES 尽量抓到当前片标题栏
    [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:YES];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!img.CGImage) return;

    const NSUInteger gen = gPlayGen;
    NSString *boundURL = [gURL copy] ?: @"";

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
    VNRecognizeTextRequest *req =
        [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
          if (error || !request.results.count) return;
          NSString *best = nil;
          NSMutableString *join = [NSMutableString string];
          for (VNRecognizedTextObservation *obs in request.results) {
              NSString *s = [obs topCandidates:1].firstObject.string;
              if (!s.length) continue;
              [join appendString:s];
              if (GSLooksLikeTitle(s) && (!best || s.length > best.length)) best = s;
          }
          if ((!best || best.length < 4) && GSLooksLikeTitle(join)) best = join;
          if (!best.length) return;
          dispatch_async(dispatch_get_main_queue(), ^{
            // 换片后丢弃过期 OCR 结果
            if (gen != gPlayGen) return;
            if (boundURL.length && gURL.length && ![boundURL isEqualToString:gURL]) return;
            GSSetTitle(best, @"OCR");
            gOCRBoundURL = boundURL.length ? [boundURL copy] : [gURL copy];
            GSRefreshPanelLabels();
          });
        }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;
    if (@available(iOS 14.0, *))
        req.recognitionLanguages = @[ @"zh-Hans", @"zh-Hant", @"ja", @"en" ];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      @try {
          [handler performRequests:@[ req ] error:nil];
      } @catch (__unused NSException *e) {
      }
    });
}

#pragma mark - Sample

static void GSSampleAV(AVPlayer *player) {
    if (!player) return;
    gLastAV = player;
    AVPlayerItem *item = player.currentItem;
    if (!item) return;
    @try {
        CGSize s = item.presentationSize;
        GSRememberSize(s.width, s.height);
        AVAsset *asset = item.asset;
        if ([asset isKindOfClass:[AVURLAsset class]]) {
            NSString *u = ((AVURLAsset *)asset).URL.absoluteString;
            if (u.length) {
                GSRememberURL(u, @"AVPlayer");
                if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(u);
            }
        }
        GSLoadAVMetadataTitle(asset);
    } @catch (__unused NSException *e) {
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
    } @catch (__unused NSException *e) {
    }
    gExtra = @"IJK";
}

#pragma mark - Swizzle (safe)

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
    Method m = class_getInstanceMethod(object_getClass((id)cls), sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, neu);
    gHooksOK = YES;
}

static IMP o_ijk_s, o_ijk_so, o_ijk_u, o_ijk_uo, o_ijk_ds, o_ijk_prep;
static IMP o_fvp_url, o_fvpt_url;
static IMP o_av_replace, o_av_initURL, o_av_playerWithURL;
static IMP o_item_initURL, o_item_withURL, o_asset_initURL, o_asset_withURL;
static IMP o_sess_req, o_sess_url; // 不再 hook completion 版
static IMP o_json;

static id h_ijk_s(id s, SEL c, id u) {
    if ([u isKindOfClass:[NSString class]]) {
        GSRememberURL(u, @"IJK");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(u);
    }
    id r = ((id(*)(id, SEL, id))o_ijk_s)(s, c, u);
    GSSampleIJK(r ?: s);
    return r;
}
static id h_ijk_so(id s, SEL c, id u, id o) {
    if ([u isKindOfClass:[NSString class]]) {
        GSRememberURL(u, @"IJK");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(u);
    }
    id r = ((id(*)(id, SEL, id, id))o_ijk_so)(s, c, u, o);
    GSSampleIJK(r ?: s);
    return r;
}
static id h_ijk_u(id s, SEL c, id u) {
    NSString *us = [u isKindOfClass:[NSURL class]]
                       ? [(NSURL *)u absoluteString]
                       : ([u isKindOfClass:[NSString class]] ? u : nil);
    if (us) {
        GSRememberURL(us, @"IJK");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    id r = ((id(*)(id, SEL, id))o_ijk_u)(s, c, u);
    GSSampleIJK(r ?: s);
    return r;
}
static id h_ijk_uo(id s, SEL c, id u, id o) {
    NSString *us = [u isKindOfClass:[NSURL class]]
                       ? [(NSURL *)u absoluteString]
                       : ([u isKindOfClass:[NSString class]] ? u : nil);
    if (us) {
        GSRememberURL(us, @"IJK");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    id r = ((id(*)(id, SEL, id, id))o_ijk_uo)(s, c, u, o);
    GSSampleIJK(r ?: s);
    return r;
}
static void h_ijk_ds(id s, SEL c, id u) {
    NSString *us = [u isKindOfClass:[NSURL class]]
                       ? [(NSURL *)u absoluteString]
                       : ([u isKindOfClass:[NSString class]] ? u : nil);
    if (us) {
        GSRememberURL(us, @"IJK-ds");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    if (o_ijk_ds) ((void(*)(id, SEL, id))o_ijk_ds)(s, c, u);
    GSSampleIJK(s);
}
static void h_ijk_prep(id s, SEL c) {
    if (o_ijk_prep) ((void(*)(id, SEL))o_ijk_prep)(s, c);
    GSSampleIJK(s);
}

static id h_fvp_url(id s, SEL c, id url, id h, id a, id r) {
    NSString *us = [url isKindOfClass:[NSString class]]
                       ? url
                       : ([url isKindOfClass:[NSURL class]] ? [(NSURL *)url absoluteString] : nil);
    if (us) {
        GSRememberURL(us, @"FVP");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    id x = ((id(*)(id, SEL, id, id, id, id))o_fvp_url)(s, c, url, h, a, r);
    @try {
        id p = [x valueForKey:@"player"];
        if ([p isKindOfClass:[AVPlayer class]]) GSSampleAV(p);
    } @catch (__unused NSException *e) {
    }
    return x;
}
static id h_fvpt_url(id s, SEL c, id url, id fu, id dl, id h, id a, id r, id od) {
    NSString *us = [url isKindOfClass:[NSString class]]
                       ? url
                       : ([url isKindOfClass:[NSURL class]] ? [(NSURL *)url absoluteString] : nil);
    if (us) {
        GSRememberURL(us, @"FVP-tex");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
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
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVPlayer");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    id r = ((id(*)(id, SEL, id))o_av_initURL)(s, c, url);
    if ([r isKindOfClass:[AVPlayer class]]) GSSampleAV(r);
    return r;
}
static id h_av_playerWithURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVPlayer");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    id r = ((id(*)(id, SEL, id))o_av_playerWithURL)(s, c, url);
    if ([r isKindOfClass:[AVPlayer class]]) GSSampleAV(r);
    return r;
}
static id h_item_initURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVItem");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    return ((id(*)(id, SEL, id))o_item_initURL)(s, c, url);
}
static id h_item_withURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVItem");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    return ((id(*)(id, SEL, id))o_item_withURL)(s, c, url);
}
static id h_asset_initURL(id s, SEL c, id url, id o) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVURLAsset");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    id r = ((id(*)(id, SEL, id, id))o_asset_initURL)(s, c, url, o);
    if ([r isKindOfClass:[AVAsset class]]) GSLoadAVMetadataTitle(r);
    return r;
}
static id h_asset_withURL(id s, SEL c, id url, id o) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVURLAsset");
        if (!gInOurNetwork) GSFetchM3U8TitleIfNeeded(us);
    }
    id r = ((id(*)(id, SEL, id, id))o_asset_withURL)(s, c, url, o);
    if ([r isKindOfClass:[AVAsset class]]) GSLoadAVMetadataTitle(r);
    return r;
}

// 只 hook 非 completion 版本，避免 block ABI 闪退
static id h_sess_req(id s, SEL c, id req) {
    if (!gInOurNetwork && [req isKindOfClass:[NSURLRequest class]]) {
        NSString *u = [(NSURLRequest *)req URL].absoluteString;
        if (u.length) {
            GSRememberURL(u, @"NET");
            // 不在这里同步 fetch，避免重入；tick/面板里再拉
        }
    }
    return ((id(*)(id, SEL, id))o_sess_req)(s, c, req);
}
static id h_sess_url(id s, SEL c, id url) {
    if (!gInOurNetwork && [url isKindOfClass:[NSURL class]]) {
        GSRememberURL([(NSURL *)url absoluteString], @"NET");
    }
    return ((id(*)(id, SEL, id))o_sess_url)(s, c, url);
}

static id h_json(id s, SEL c, id data, NSUInteger opt, NSError **err) {
    id obj = ((id(*)(id, SEL, id, NSUInteger, NSError **))o_json)(s, c, data, opt, err);
    if (obj) {
        @try {
            GSScanJSON(obj, 0);
        } @catch (__unused NSException *e) {
        }
        dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
    }
    return obj;
}

// flutter_des：只包 decrypt 的 result，拿到明文；非 decrypt 原样转发
static IMP o_des_handle;
static void h_des_handle(id s, SEL c, id call, id result) {
    NSString *method = nil;
    @try {
        method = [call valueForKey:@"method"];
    } @catch (__unused NSException *e) {
    }
    NSString *ml = method.lowercaseString ?: @"";
    BOOL isDecrypt = [ml containsString:@"decrypt"];
    if (!isDecrypt || !result) {
        ((void (*)(id, SEL, id, id))o_des_handle)(s, c, call, result);
        return;
    }
    void (^origResult)(id) = result;
    void (^wrap)(id) = ^(id value) {
        @try {
            if ([value isKindOfClass:[NSString class]]) {
                GSIngestPlaintext((NSString *)value, @"DES");
            } else if ([value isKindOfClass:[NSData class]]) {
                NSString *txt =
                    [[NSString alloc] initWithData:(NSData *)value encoding:NSUTF8StringEncoding];
                if (txt) GSIngestPlaintext(txt, @"DES");
            } else if ([value isKindOfClass:[NSDictionary class]] ||
                       [value isKindOfClass:[NSArray class]]) {
                NSString *before = gTitleJSON ?: @"";
                GSScanJSON(value, 0);
                if (gTitleJSON.length && ![gTitleJSON isEqualToString:before] &&
                    GSLooksLikeTitle(gTitleJSON)) {
                    gTitleDES = [gTitleJSON copy];
                    GSRecomputeBestTitle();
                }
            }
        } @catch (__unused NSException *e) {
        }
        dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
        if (origResult) origResult(value);
    };
    ((void (*)(id, SEL, id, id))o_des_handle)(s, c, call, wrap);
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

    // 仅非 block 接口
    Class sess = [NSURLSession class];
    GSSwizzleInst(sess, @selector(dataTaskWithRequest:), (IMP)h_sess_req, &o_sess_req);
    GSSwizzleInst(sess, @selector(dataTaskWithURL:), (IMP)h_sess_url, &o_sess_url);

    if (!o_json) {
        Method mm = class_getInstanceMethod(object_getClass((id)[NSJSONSerialization class]),
                                            @selector(JSONObjectWithData:options:error:));
        if (mm) {
            o_json = method_getImplementation(mm);
            method_setImplementation(mm, (IMP)h_json);
            gHooksOK = YES;
        }
    }

    // flutter_des（存在才 hook；失败不影响启动）
    if (!gDesHooked) {
        Class desClasses[] = {
            NSClassFromString(@"FlutterDesPlugin"),
            NSClassFromString(@"SwiftFlutterDesPlugin"),
            NSClassFromString(@"_TtC11flutter_des21SwiftFlutterDesPlugin"),
        };
        for (size_t i = 0; i < sizeof(desClasses) / sizeof(desClasses[0]); i++) {
            Class des = desClasses[i];
            if (!des) continue;
            // 允许重复调用 GSSwizzleInst：其内部 *orig 已设则跳过
            GSSwizzleInst(des, @selector(handleMethodCall:result:), (IMP)h_des_handle, &o_des_handle);
            if (o_des_handle) {
                gDesHooked = YES;
                break;
            }
        }
    }
}

#pragma mark - NAS

static void GSPushToNAS(void) {
    if (!gURL.length) {
        GSToast(@"无视频URL");
        return;
    }
    NSString *title = GSEffectiveTitle();
    if (!title.length) title = @"未命名视频";
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"\\/:*?\"<>|\n\r\t"];
    title = [[title componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    if (title.length > 80) title = [title substringToIndex:80];
    NSData *json =
        [NSJSONSerialization dataWithJSONObject:@{@"url" : gURL, @"title" : title} options:0 error:nil];
    if (!json) return;
    NSMutableURLRequest *req =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGSNASDownloadURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = json;
    req.timeoutInterval = 15;
    GSToast(@"正在推送到 NAS…");
    gInOurNetwork = YES;
    [[[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            gInOurNetwork = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
              if (error) {
                  GSToast([NSString stringWithFormat:@"推送失败:%@", error.localizedDescription]);
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
              if (code == 200 || http.statusCode == 200)
                  GSToast(msg.length ? msg : @"已加入 NAS 队列");
              else
                  GSToast([NSString stringWithFormat:@"异常 HTTP%ld %@", (long)http.statusCode, msg]);
            });
          }] resume];
}

#pragma mark - Panel UI

@interface GSPlayerInfoTapTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)onFab;
- (void)onTick;
- (void)onClosePanel;
- (void)onCopyTitle;
- (void)onCopyURL;
- (void)onPushNAS;
- (void)onPan:(UIPanGestureRecognizer *)pan;
- (void)onPickSrc:(UIButton *)btn;
- (void)onIJKNote:(NSNotification *)n;
@end

static void GSRefreshPanelLabels(void) {
    GSRecomputeBestTitle();
    NSString *eff = GSEffectiveTitle();
    GSTitleSrc autoSrc = GSAutoPickSource();
    NSString *mode = (gTitlePick == GSTitleSrcNone)
                         ? [NSString stringWithFormat:@"自动(%@)", GSSrcName(autoSrc)]
                         : [NSString stringWithFormat:@"手动(%@)", GSSrcName(gTitlePick)];
    if (gLabRes) gLabRes.text = [NSString stringWithFormat:@"分辨率：%@", GSResText()];
    if (gLabTitle)
        gLabTitle.text = [NSString stringWithFormat:@"标题[%@]：%@(点此复制)", mode,
                                                    eff.length ? eff : @"(未获取)"];
    if (gLabURL)
        gLabURL.text =
            [NSString stringWithFormat:@"URL：%@(点此复制)", gURL.length ? gURL : @"(未获取)"];
    if (gLabDebug) {
        gLabDebug.text = [NSString
            stringWithFormat:
                @"调试·各方法标题（点上方按钮选用）:\n"
                 "A11y: %@\n"
                 "DES: %@\n"
                 "JSON: %@\n"
                 "OCR: %@\n"
                 "AVMeta: %@\n"
                 "M3U8: %@\n"
                 "当前: %@ | hooks=%@ | des=%@",
                GSDash(gTitleA11y), GSDash(gTitleDES), GSDash(gTitleJSON), GSDash(gTitleOCR),
                GSDash(gTitleAVMeta), GSDash(gTitleM3U8), GSDash(eff), gHooksOK ? @"OK" : @"NO",
                gDesHooked ? @"OK" : @"-"];
    }
    // 高亮：自动模式亮「自动」+ 当前命中源；手动模式只亮所选
    for (UIButton *b in gSrcBtns) {
        BOOL isAuto = (b.tag == 99);
        BOOL on = NO;
        if (isAuto)
            on = (gTitlePick == GSTitleSrcNone);
        else if (gTitlePick != GSTitleSrcNone)
            on = (b.tag == (NSInteger)gTitlePick);
        else
            on = (b.tag == (NSInteger)autoSrc);
        b.backgroundColor = on ? [UIColor colorWithRed:0.25 green:0.55 blue:0.95 alpha:0.95]
                               : [UIColor colorWithWhite:0.25 alpha:0.9];
    }
    gBtnNas.enabled = gURL.length > 0;
    gBtnNas.alpha = gURL.length ? 1 : 0.45;
}

static void GSHidePanel(void) {
    if (!gPanel) return;
    [UIView animateWithDuration:0.2
        animations:^{ gPanel.alpha = 0; }
        completion:^(BOOL f) { gPanel.hidden = YES; }];
}

static void GSShowPanel(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;

    @try {
        GSScanA11yTitle();
        if (gLastAV) GSSampleAV(gLastAV);
        if (gLastIJK) GSSampleIJK(gLastIJK);
        if (gURL.length && !gInOurNetwork) GSFetchM3U8TitleIfNeeded(gURL);
        // 每次开面板强制 OCR，避免一直显示上一条
        GSOcrTopTitle(YES);
    } @catch (__unused NSException *e) {
    }

    if (!gPanel) {
        CGFloat W = MIN(win.bounds.size.width - 28, 370);
        CGFloat H = 500;
        gPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
        gPanel.backgroundColor = [[UIColor colorWithWhite:0.1 alpha:1] colorWithAlphaComponent:0.96];
        gPanel.layer.cornerRadius = 14;
        gPanel.clipsToBounds = YES;

        UILabel *head = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, W - 60, 24)];
        head.text = @"播放信息";
        head.textColor = UIColor.whiteColor;
        head.font = [UIFont boldSystemFontOfSize:17];
        [gPanel addSubview:head];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(W - 44, 8, 36, 36);
        [close setTitle:@"✕" forState:UIControlStateNormal];
        [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [close addTarget:[GSPlayerInfoTapTarget shared]
                      action:@selector(onClosePanel)
            forControlEvents:UIControlEventTouchUpInside];
        [gPanel addSubview:close];

        gLabRes = [[UILabel alloc] initWithFrame:CGRectMake(16, 44, W - 32, 18)];
        gLabRes.textColor = [UIColor colorWithWhite:0.92 alpha:1];
        gLabRes.font = [UIFont systemFontOfSize:13];
        [gPanel addSubview:gLabRes];

        gLabTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, W - 32, 44)];
        gLabTitle.textColor = [UIColor colorWithRed:0.6 green:0.9 blue:1 alpha:1];
        gLabTitle.font = [UIFont systemFontOfSize:12];
        gLabTitle.numberOfLines = 3;
        gLabTitle.userInteractionEnabled = YES;
        [gLabTitle addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                            initWithTarget:[GSPlayerInfoTapTarget shared]
                                                    action:@selector(onCopyTitle)]];
        [gPanel addSubview:gLabTitle];

        // 标题来源手动选取：自动 + 6 源
        gSrcBtns = [NSMutableArray array];
        NSArray *labels = @[ @"自动", @"A11y", @"DES", @"JSON", @"OCR", @"Meta", @"M3U8" ];
        NSInteger tags[] = {99, GSTitleSrcA11y, GSTitleSrcDES, GSTitleSrcJSON,
                            GSTitleSrcOCR, GSTitleSrcAVMeta, GSTitleSrcM3U8};
        CGFloat bx = 12, by = 112, bh = 28, gap = 4;
        CGFloat bw = (W - 24 - gap * 3) / 4.0;
        for (NSInteger i = 0; i < (NSInteger)labels.count; i++) {
            NSInteger col = i % 4;
            NSInteger row = i / 4;
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(bx + col * (bw + gap), by + row * (bh + gap), bw, bh);
            b.tag = tags[i];
            b.layer.cornerRadius = 6;
            b.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.9];
            [b setTitle:labels[i] forState:UIControlStateNormal];
            [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
            [b addTarget:[GSPlayerInfoTapTarget shared]
                          action:@selector(onPickSrc:)
                forControlEvents:UIControlEventTouchUpInside];
            [gPanel addSubview:b];
            [gSrcBtns addObject:b];
        }

        gLabURL = [[UILabel alloc] initWithFrame:CGRectMake(16, 180, W - 32, 48)];
        gLabURL.textColor = [UIColor colorWithRed:0.55 green:1 blue:0.65 alpha:1];
        gLabURL.font = [UIFont systemFontOfSize:11];
        gLabURL.numberOfLines = 3;
        gLabURL.userInteractionEnabled = YES;
        [gLabURL addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                          initWithTarget:[GSPlayerInfoTapTarget shared]
                                                  action:@selector(onCopyURL)]];
        [gPanel addSubview:gLabURL];

        gBtnNas = [UIButton buttonWithType:UIButtonTypeCustom];
        gBtnNas.frame = CGRectMake(16, 236, W - 32, 44);
        gBtnNas.backgroundColor = [UIColor colorWithRed:0.2 green:0.55 blue:0.95 alpha:1];
        gBtnNas.layer.cornerRadius = 10;
        [gBtnNas setTitle:@"推送到 NAS 下载" forState:UIControlStateNormal];
        [gBtnNas setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gBtnNas.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [gBtnNas addTarget:[GSPlayerInfoTapTarget shared]
                      action:@selector(onPushNAS)
            forControlEvents:UIControlEventTouchUpInside];
        [gPanel addSubview:gBtnNas];

        UIView *dbgBox = [[UIView alloc] initWithFrame:CGRectMake(10, 290, W - 20, 196)];
        dbgBox.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.9];
        dbgBox.layer.cornerRadius = 8;
        dbgBox.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        dbgBox.layer.borderWidth = 0.5;
        [gPanel addSubview:dbgBox];

        gLabDebug = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, W - 36, 184)];
        gLabDebug.textColor = [UIColor colorWithRed:1 green:0.88 blue:0.45 alpha:1];
        gLabDebug.font = [UIFont systemFontOfSize:10];
        gLabDebug.numberOfLines = 0;
        gLabDebug.adjustsFontSizeToFitWidth = YES;
        gLabDebug.minimumScaleFactor = 0.7;
        [dbgBox addSubview:gLabDebug];

        [win addSubview:gPanel];
    } else if (gPanel.superview != win) {
        [gPanel removeFromSuperview];
        [win addSubview:gPanel];
    }

    gPanel.center = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds));
    gPanel.hidden = NO;
    gPanel.alpha = 0;
    [win bringSubviewToFront:gPanel];
    GSRefreshPanelLabels();
    [UIView animateWithDuration:0.2 animations:^{ gPanel.alpha = 1; }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     GSScanA11yTitle();
                     GSRefreshPanelLabels();
                   });
}

static void GSLayoutFab(void) {
    UIWindow *win = GSKeyWindow();
    if (!win || !gBtn) return;
    CGFloat top = 72;
    if (@available(iOS 11.0, *)) top = win.safeAreaInsets.top + 28;
    CGFloat side = 25;
    CGFloat x = win.bounds.size.width - side - 12 + gFabOffset.x;
    CGFloat y = top + gFabOffset.y;
    x = MAX(4, MIN(x, win.bounds.size.width - side - 4));
    y = MAX(4, MIN(y, win.bounds.size.height - side - 4));
    gBtn.frame = CGRectMake(x, y, side, side);
    gBtn.layer.cornerRadius = side / 2.0;
    [win bringSubviewToFront:gBtn];
    if (gPanel && !gPanel.hidden) [win bringSubviewToFront:gPanel];
}

static void GSEnsureFab(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    if (!gBtn) {
        gBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        gBtn.backgroundColor = [UIColor colorWithWhite:0.92 alpha:0.45];
        [gBtn setTitle:@"i" forState:UIControlStateNormal];
        [gBtn setTitleColor:[UIColor colorWithWhite:0.25 alpha:0.85] forState:UIControlStateNormal];
        gBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        gBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        gBtn.layer.borderWidth = 0.5;
        gBtn.clipsToBounds = YES;
        // 点击开面板
        [gBtn addTarget:[GSPlayerInfoTapTarget shared]
                      action:@selector(onFab)
            forControlEvents:UIControlEventTouchUpInside];
        // 拖动改位置（不拦截轻点：cancelsTouchesInView=NO）
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:[GSPlayerInfoTapTarget shared]
                                                    action:@selector(onPan:)];
        pan.delegate = [GSPlayerInfoTapTarget shared];
        pan.cancelsTouchesInView = NO;
        pan.maximumNumberOfTouches = 1;
        [gBtn addGestureRecognizer:pan];
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
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;
}
- (void)onPan:(UIPanGestureRecognizer *)pan {
    UIWindow *win = GSKeyWindow();
    if (!win || !gBtn) return;
    if (pan.state == UIGestureRecognizerStateBegan) {
        gFabMoved = NO;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:win];
        if (fabs(t.x) + fabs(t.y) > 4) gFabMoved = YES;
        if (!gFabMoved) return; // 未超过阈值，当点击
        gFabOffset = CGPointMake(gFabOffset.x + t.x, gFabOffset.y + t.y);
        [pan setTranslation:CGPointZero inView:win];
        GSLayoutFab();
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled) {
        // 拖动结束后短暂锁点击，避免松手再弹一次
        if (gFabMoved) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ gFabMoved = NO; });
        } else {
            gFabMoved = NO;
        }
    }
}
- (void)onFab {
    if (gFabMoved) return; // 刚拖过，不弹
    @try {
        if (gPanel && !gPanel.hidden)
            GSHidePanel();
        else
            GSShowPanel();
    } @catch (__unused NSException *e) {
        GSToast(@"面板打开异常");
    }
}
- (void)onClosePanel {
    GSHidePanel();
}
- (void)onCopyTitle {
    GSScanA11yTitle();
    GSOcrTopTitle(YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     NSString *t = GSEffectiveTitle();
                     if (t.length) {
                         UIPasteboard.generalPasteboard.string = t;
                         GSToast(@"已复制标题");
                     } else
                         GSToast(@"暂无有效标题");
                     GSRefreshPanelLabels();
                   });
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
    GSPushToNAS();
}
- (void)onPickSrc:(UIButton *)btn {
    if (btn.tag == 99)
        gTitlePick = GSTitleSrcNone;
    else
        gTitlePick = (GSTitleSrc)btn.tag;
    GSRefreshPanelLabels();
    NSString *name = GSSrcName(gTitlePick);
    NSString *val = GSEffectiveTitle();
    if (val.length)
        GSToast([NSString stringWithFormat:@"选用 %@：%@", name, GSDash(val)]);
    else
        GSToast([NSString stringWithFormat:@"已选 %@（暂无值）", name]);
}
- (void)onTick {
    @try {
        GSInstallHooks();
        GSEnsureFab();
        if (gLastAV) GSSampleAV(gLastAV);
        if (gLastIJK) GSSampleIJK(gLastIJK);
        if (gURL.length || gLastAV || gLastIJK) {
            GSScanA11yTitle();
            // 后台仅在本片尚无 OCR 时补识别（换片后会清空）
            GSOcrTopTitle(NO);
            if (gURL.length && !gInOurNetwork) GSFetchM3U8TitleIfNeeded(gURL);
        }
        // 清掉错误技术串
        if (gTitleJSON.length && GSIsTechIdentifier(gTitleJSON)) gTitleJSON = @"";
        if (gTitleA11y.length && GSIsTechIdentifier(gTitleA11y)) gTitleA11y = @"";
        if (gTitleDES.length && GSIsTechIdentifier(gTitleDES)) gTitleDES = @"";
        if (gTitleOCR.length && GSIsTechIdentifier(gTitleOCR)) gTitleOCR = @"";
        if (gTitleBest.length && GSIsTechIdentifier(gTitleBest)) gTitleBest = @"";
        GSRecomputeBestTitle();
        if (gPanel && !gPanel.hidden) GSRefreshPanelLabels();
    } @catch (__unused NSException *e) {
    }
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
    [NSTimer scheduledTimerWithTimeInterval:1.2
                                     target:t
                                   selector:@selector(onTick)
                                   userInfo:nil
                                    repeats:YES];
}

__attribute__((constructor)) static void GSPlayerInfoInit(void) {
    if ([NSThread isMainThread])
        GSBoot();
    else
        dispatch_async(dispatch_get_main_queue(), ^{ GSBoot(); });
    for (int i = 1; i <= 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         GSInstallHooks();
                         GSEnsureFab();
                       });
    }
}
