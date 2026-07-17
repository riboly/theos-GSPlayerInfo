/*
 * GSPlayerInfo
 * 标题主路径：强制 Flutter Semantics（fishhook VoiceOver）→ A11y 读顶栏文案
 * 副路径：flutter_des 解密明文 JSON / 打开面板 OCR
 * 标题可手动切换来源；URL/分辨率保持原稳定 hook
 * NAS: POST http://192.168.6.110:38617/api/download
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <string.h>
#import <stdlib.h>

static NSString *const kGSNASDownloadURL = @"http://192.168.6.110:38617/api/download";

#pragma mark - Title sources

typedef NS_ENUM(NSInteger, GSTitleSrc) {
    GSTitleSrcNone = -1,
    GSTitleSrcA11y = 0,
    GSTitleSrcDES = 1,
    GSTitleSrcJSON = 2,
    GSTitleSrcOCR = 3,
    GSTitleSrcAVMeta = 4,
    GSTitleSrcM3U8 = 5,
    GSTitleSrcCount = 6,
};

static NSString *gTitleBySrc[GSTitleSrcCount];
static GSTitleSrc gTitlePick = GSTitleSrcNone; // 用户手动选择；None=自动
static NSString *gURL = @"";
static NSString *gExtra = @"";
static NSInteger gW = 0, gH = 0;
static BOOL gHooksOK = NO;
static BOOL gVoiceOverHooked = NO;

static UIButton *gBtn = nil;
static UIView *gPanel = nil;
static UILabel *gLabRes = nil, *gLabTitle = nil, *gLabURL = nil, *gLabDebug = nil;
static UIScrollView *gSrcScroll = nil;
static UIView *gSrcBox = nil;
static UIButton *gBtnNas = nil;
static NSMutableArray<UIButton *> *gSrcBtns;
static id gLastIJK = nil;
static AVPlayer *gLastAV = nil;
static NSTimeInterval gLastOCR = 0, gLastM3U8 = 0;
static NSString *gLastM3U8URL = @"";
static CGPoint gFabOffset = {0, 0};
static BOOL gFabMoved = NO;
static volatile BOOL gInOurNetwork = NO;

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
    if ([l rangeOfString:@"^[a-z][a-z0-9_]*$" options:NSRegularExpressionSearch].location != NSNotFound &&
        [l containsString:@"_"])
        return YES;
    NSArray *bad = @[
        @"hierarchical", @"inner_product", @"tensor", @"embedding", @"layer", @"model", @"softmax",
        @"flutter", @"dart", @"null", @"undefined", @"object", @"true", @"false", @"loading"
    ];
    for (NSString *b in bad)
        if ([l containsString:b]) return YES;
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
        @"1.0X", @"全屏", @"倍速", @"i", @"选用", @"自动", @"JSON", @"OCR", @"A11y", @"DES", @"M3U8",
        @"AVMeta", @"未获取", @"hooks", @"返回", @"分享", @"选集", @"线路"
    ];
    for (NSString *b in noise)
        if ([t isEqualToString:b]) return NO;
    if ([t rangeOfString:@"^\\d{1,2}:\\d{2}(:\\d{2})?$" options:NSRegularExpressionSearch].location !=
        NSNotFound)
        return NO;
    return GSHasCJK(t);
}

static BOOL GSIsNoiseHost(NSString *u) {
    NSString *l = u.lowercaseString;
    return [l containsString:@"umeng"] || [l containsString:@"apple.com"] ||
           [l containsString:@"firebase"] || [l containsString:@"googleapis"] ||
           [l containsString:@"crashlytics"] || [l containsString:@"sentry"] ||
           [l containsString:@"bugly"] || [l containsString:@"icloud"];
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

static NSString *GSSrcName(GSTitleSrc s) {
    switch (s) {
        case GSTitleSrcA11y: return @"A11y(语义/无障碍)";
        case GSTitleSrcDES: return @"DES解密";
        case GSTitleSrcJSON: return @"JSON";
        case GSTitleSrcOCR: return @"OCR顶栏";
        case GSTitleSrcAVMeta: return @"AVMeta";
        case GSTitleSrcM3U8: return @"M3U8";
        default: return @"?";
    }
}

static NSString *GSBestTitleAuto(void) {
    // 优先级：A11y(强制语义后最准) > DES > JSON > OCR > AVMeta > M3U8
    GSTitleSrc order[] = {GSTitleSrcA11y, GSTitleSrcDES, GSTitleSrcJSON, GSTitleSrcOCR,
                          GSTitleSrcAVMeta, GSTitleSrcM3U8};
    for (int i = 0; i < 6; i++) {
        NSString *t = gTitleBySrc[order[i]];
        if (GSLooksLikeTitle(t)) return t;
    }
    return @"";
}

static NSString *GSEffectiveTitle(void) {
    if (gTitlePick >= 0 && gTitlePick < GSTitleSrcCount) {
        NSString *t = gTitleBySrc[gTitlePick];
        if (GSLooksLikeTitle(t)) return t;
    }
    return GSBestTitleAuto();
}

static GSTitleSrc GSAutoPickSource(void) {
    GSTitleSrc order[] = {GSTitleSrcA11y, GSTitleSrcDES, GSTitleSrcJSON, GSTitleSrcOCR,
                          GSTitleSrcAVMeta, GSTitleSrcM3U8};
    for (int i = 0; i < 6; i++) {
        if (GSLooksLikeTitle(gTitleBySrc[order[i]])) return order[i];
    }
    return GSTitleSrcNone;
}

static void GSSetTitle(NSString *t, GSTitleSrc src) {
    if (!GSLooksLikeTitle(t) || src < 0 || src >= GSTitleSrcCount) return;
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 同来源保留更长中文
    NSString *old = gTitleBySrc[src];
    if (old.length && GSLooksLikeTitle(old) && old.length > t.length && [old containsString:t])
        return;
    gTitleBySrc[src] = [t copy];
}

static void GSRememberURL(NSString *u, NSString *source) {
    if (u.length == 0 || GSIsNoiseHost(u)) return;
    BOOL ok = GSLooksMediaURL(u) || [source hasPrefix:@"AV"] || [source hasPrefix:@"IJK"] ||
              [source hasPrefix:@"FVP"] || [source isEqualToString:@"JSON"];
    if (!ok) return;
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
    if (s.length > 36) return [[s substringToIndex:36] stringByAppendingString:@"…"];
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

#pragma mark - fishhook: 强制 Flutter 打开 Semantics

// 精简 fishhook：重绑指定镜像对某符号的导入指针
static int GSRebindSymbolInImage(const struct mach_header *header, intptr_t slide, const char *symbol,
                                 void *replacement, void **replaced_out) {
    if (header->magic != MH_MAGIC_64) return -1;
    const struct mach_header_64 *hdr = (const struct mach_header_64 *)header;
    const uint8_t *base = (const uint8_t *)header;
    const struct load_command *lc = (const struct load_command *)(base + sizeof(struct mach_header_64));

    const struct segment_command_64 *linkedit = NULL;
    const struct segment_command_64 *data_seg = NULL;
    const struct dysymtab_command *dysym = NULL;
    const struct symtab_command *symtab = NULL;

    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
            // 多个 DATA 段
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysym = (const struct dysymtab_command *)lc;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!linkedit || !symtab || !dysym) return -1;

    // 再扫一遍找 lazy/non-lazy pointer sections
    lc = (const struct load_command *)(base + sizeof(struct mach_header_64));
    uintptr_t linkedit_base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab_ptr =
        (const struct nlist_64 *)(linkedit_base + symtab->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkedit_base + dysym->indirectsymoff);

    int found = 0;
    lc = (const struct load_command *)(base + sizeof(struct mach_header_64));
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            const struct section_64 *sec = (const struct section_64 *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++, sec++) {
                uint32_t type = sec->flags & SECTION_TYPE;
                if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
                uint32_t count = (uint32_t)(sec->size / sizeof(void *));
                void **indirect_sym =
                    (void **)((uintptr_t)slide + sec->addr);
                uint32_t idx0 = sec->reserved1;
                for (uint32_t k = 0; k < count; k++) {
                    uint32_t symIndex = indirect[idx0 + k];
                    if (symIndex == INDIRECT_SYMBOL_ABS || symIndex == INDIRECT_SYMBOL_LOCAL ||
                        symIndex == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS))
                        continue;
                    if (symIndex >= symtab->nsyms) continue;
                    const struct nlist_64 *nl = &symtab_ptr[symIndex];
                    const char *name = strtab + nl->n_un.n_strx;
                    if (name[0] == '_') name++;
                    if (strcmp(name, symbol) != 0) continue;
                    if (replaced_out && !*replaced_out && indirect_sym[k])
                        *replaced_out = indirect_sym[k];
                    // 写入新指针
                    indirect_sym[k] = replacement;
                    found = 1;
                }
            }
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    return found ? 0 : -1;
}

static BOOL (*orig_UIAccessibilityIsVoiceOverRunning)(void) = NULL;
static BOOL fake_UIAccessibilityIsVoiceOverRunning(void) { return YES; }

static void GSForceFlutterSemantics(void) {
    if (gVoiceOverHooked) return;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        // 对主程序和 Flutter 都 rebind
        if (strstr(name, "Flutter") || strstr(name, "byg") || strstr(name, "/App")) {
            const struct mach_header *hdr = _dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            void *old = NULL;
            if (GSRebindSymbolInImage(hdr, slide, "UIAccessibilityIsVoiceOverRunning",
                                      (void *)fake_UIAccessibilityIsVoiceOverRunning, &old) == 0) {
                if (old && !orig_UIAccessibilityIsVoiceOverRunning)
                    orig_UIAccessibilityIsVoiceOverRunning = old;
                gVoiceOverHooked = YES;
            }
        }
    }
    // 也 rebind 全局默认
    void *old = NULL;
    const struct mach_header *mh = _dyld_get_image_header(0);
    GSRebindSymbolInImage(mh, _dyld_get_image_vmaddr_slide(0), "UIAccessibilityIsVoiceOverRunning",
                          (void *)fake_UIAccessibilityIsVoiceOverRunning, &old);
    if (old && !orig_UIAccessibilityIsVoiceOverRunning)
        orig_UIAccessibilityIsVoiceOverRunning = old;

    // 通知无障碍状态变化，促使 Flutter 建语义树
    dispatch_async(dispatch_get_main_queue(), ^{
      UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
      // 再发一次 layout
      UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
    });
}

#pragma mark - A11y scan (after semantics)

static void GSWalkA11y(id node, int depth, CGFloat screenH, NSMutableArray *out) {
    if (!node || depth > 24) return;

    NSString *lab = nil;
    CGFloat midY = 0;
    @try {
        if ([node respondsToSelector:@selector(accessibilityLabel)])
            lab = [node accessibilityLabel];
        if ([node respondsToSelector:@selector(accessibilityValue)]) {
            id v = [node accessibilityValue];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > (lab.length ?: 0))
                lab = v;
        }
        if ([node respondsToSelector:@selector(accessibilityFrame)]) {
            CGRect f = [node accessibilityFrame];
            if (!CGRectIsEmpty(f)) midY = CGRectGetMidY(f);
        }
    } @catch (__unused NSException *e) {
    }

    if (GSLooksLikeTitle(lab)) {
        // 优先上半屏
        if (screenH <= 0 || midY < 1 || midY < screenH * 0.55)
            [out addObject:@{@"t" : lab, @"y" : @(midY > 0 ? midY : 0), @"len" : @(lab.length)}];
    }

    // UIView 子树
    if ([node isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)node;
        if (view.hidden || view.alpha < 0.02) return;
        if (view == gBtn || view == gPanel) return;
        if ([view isKindOfClass:[UILabel class]]) {
            NSString *t = ((UILabel *)view).text;
            CGRect fr = [view convertRect:view.bounds toView:nil];
            if (GSLooksLikeTitle(t))
                [out addObject:@{
                    @"t" : t,
                    @"y" : @(CGRectGetMidY(fr)),
                    @"len" : @(t.length)
                }];
        }
        NSArray *els = nil;
        @try {
            if (!view.isAccessibilityElement) els = view.accessibilityElements;
        } @catch (__unused NSException *e) {
        }
        if ([els isKindOfClass:[NSArray class]]) {
            for (id el in els) GSWalkA11y(el, depth + 1, screenH, out);
        }
        for (UIView *sub in view.subviews) GSWalkA11y(sub, depth + 1, screenH, out);
    }
}

static void GSScanA11yTitle(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    CGFloat H = win.bounds.size.height;
    NSMutableArray *cands = [NSMutableArray array];
    GSWalkA11y(win, 0, H, cands);
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w != win) GSWalkA11y(w, 0, H, cands);
            }
        }
    }
    if (!cands.count) return;
    [cands sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      CGFloat ya = [a[@"y"] doubleValue], yb = [b[@"y"] doubleValue];
      if (ya > 1 && yb > 1) {
          if (ya < yb - 10) return NSOrderedAscending;
          if (yb < ya - 10) return NSOrderedDescending;
      }
      return [@([b[@"len"] integerValue]) compare:@([a[@"len"] integerValue])];
    }];
    for (NSDictionary *c in cands) {
        if (GSLooksLikeTitle(c[@"t"])) {
            GSSetTitle(c[@"t"], GSTitleSrcA11y);
            return;
        }
    }
}

#pragma mark - OCR

static void GSOcrTopTitle(void) {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastOCR < 2.0) return;
    gLastOCR = now;
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat topInset = 0;
    if (@available(iOS 11.0, *)) topInset = win.safeAreaInsets.top;
    CGRect band = CGRectMake(48, topInset, MAX(80, win.bounds.size.width - 110), 50);
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
          if (best.length) {
              dispatch_async(dispatch_get_main_queue(), ^{
                GSSetTitle(best, GSTitleSrcOCR);
                GSRefreshPanelLabels();
              });
          }
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

#pragma mark - Parse title from plaintext JSON string

static void GSIngestPlaintextMaybeJSON(NSString *text, GSTitleSrc src) {
    if (text.length < 4) return;
    // 尝试整段 JSON
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (d) {
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (obj) {
            // 内联轻量扫描（避免依赖未定义函数顺序）
            // 用递归 block 会 retain cycle — 用简单栈式
            NSMutableArray *stack = [NSMutableArray arrayWithObject:obj];
            static NSArray *tkeys;
            static NSArray *ukeys;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
              tkeys = @[
                  @"display_title", @"displayTitle", @"video_title", @"videoTitle", @"video_name",
                  @"mv_title", @"mvTitle", @"play_title", @"playTitle", @"sp91_film_subject",
                  @"sp91_small_video_subject", @"title"
              ];
              ukeys = @[
                  @"playUrl", @"play_url", @"videoUrl", @"video_url", @"url", @"urlM3u8", @"m3u8",
                  @"mv_play_url", @"link"
              ];
            });
            int guard = 0;
            while (stack.count && guard++ < 400) {
                id cur = stack.lastObject;
                [stack removeLastObject];
                if ([cur isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *dict = cur;
                    for (NSString *k in ukeys) {
                        id v = dict[k];
                        if ([v isKindOfClass:[NSString class]] && GSLooksMediaURL(v))
                            GSRememberURL(v, @"JSON");
                    }
                    for (NSString *k in tkeys) {
                        id v = dict[k];
                        if ([v isKindOfClass:[NSString class]] && GSLooksLikeTitle(v)) {
                            // title 弱键要求更长
                            if ([k isEqualToString:@"title"] && [(NSString *)v length] < 4) continue;
                            GSSetTitle(v, src);
                        }
                    }
                    for (id v in dict.allValues) {
                        if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]])
                            [stack addObject:v];
                    }
                } else if ([cur isKindOfClass:[NSArray class]]) {
                    for (id v in (NSArray *)cur) {
                        if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]])
                            [stack addObject:v];
                    }
                }
            }
            return;
        }
    }
    // 非完整 JSON：正则挖 "display_title":"..."
    NSArray *keys = @[
        @"display_title", @"video_title", @"video_name", @"mv_title", @"play_title", @"title"
    ];
    for (NSString *k in keys) {
        NSString *pat =
            [NSString stringWithFormat:@"\"%@\"\\s*[:=]\\s*\"([^\"]{2,120})\"", k];
        NSRegularExpression *re =
            [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
        NSTextCheckingResult *m =
            [re firstMatchInString:text options:0 range:NSMakeRange(0, MIN(text.length, (NSUInteger)50000))];
        if (m.numberOfRanges > 1) {
            NSString *t = [text substringWithRange:[m rangeAtIndex:1]];
            if (GSLooksLikeTitle(t)) GSSetTitle(t, src);
        }
    }
}

#pragma mark - m3u8 / AVMeta (keep, low priority)

static void GSParseM3U8(NSString *text) {
    if (text.length < 10 || ![text containsString:@"#EXT"]) return;
    NSUInteger lim = MIN(text.length, (NSUInteger)5000);
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"#EXTINF:[^,]*,\\s*(.+)" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, lim)];
    if (m.numberOfRanges > 1) {
        NSString *t = [[text substringWithRange:[m rangeAtIndex:1]]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (GSLooksLikeTitle(t)) GSSetTitle(t, GSTitleSrcM3U8);
    }
}

static void GSFetchM3U8(NSString *url) {
    if (!url.length || ![url.lowercaseString containsString:@"m3u8"]) return;
    if ([gLastM3U8URL isEqualToString:url] && gTitleBySrc[GSTitleSrcM3U8].length) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastM3U8 < 4.0 && [gLastM3U8URL isEqualToString:url]) return;
    gLastM3U8 = now;
    gLastM3U8URL = [url copy];
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = 10;
    gInOurNetwork = YES;
    [[[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            gInOurNetwork = NO;
            if (e || data.length < 8) return;
            NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (txt) GSParseM3U8(txt);
            dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
          }] resume];
}

static void GSLoadAVMeta(AVAsset *asset) {
    if (!asset) return;
    static NSTimeInterval last = 0;
    if (CFAbsoluteTimeGetCurrent() - last < 2.0 && gTitleBySrc[GSTitleSrcAVMeta].length) return;
    last = CFAbsoluteTimeGetCurrent();
    @try {
        for (AVMetadataItem *it in asset.commonMetadata) {
            if (GSLooksLikeTitle(it.stringValue)) {
                GSSetTitle(it.stringValue, GSTitleSrcAVMeta);
                return;
            }
        }
    } @catch (__unused NSException *e) {
    }
    [asset loadValuesAsynchronouslyForKeys:@[ @"commonMetadata" ] completionHandler:^{
      @try {
          NSArray *meta = [AVMetadataItem metadataItemsFromArray:asset.commonMetadata
                                                         withKey:AVMetadataCommonKeyTitle
                                                        keySpace:AVMetadataKeySpaceCommon];
          for (AVMetadataItem *it in meta) {
              if (GSLooksLikeTitle(it.stringValue)) {
                  GSSetTitle(it.stringValue, GSTitleSrcAVMeta);
                  dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
                  return;
              }
          }
      } @catch (__unused NSException *e) {
      }
    }];
}

#pragma mark - Sample / URL hooks (stable)

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
                if (!gInOurNetwork) GSFetchM3U8(u);
            }
        }
        GSLoadAVMeta(asset);
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
static IMP o_sess_req, o_sess_url, o_json, o_des_handle;

static id h_ijk_s(id s, SEL c, id u) {
    if ([u isKindOfClass:[NSString class]]) {
        GSRememberURL(u, @"IJK");
        if (!gInOurNetwork) GSFetchM3U8(u);
    }
    id r = ((id(*)(id, SEL, id))o_ijk_s)(s, c, u);
    GSSampleIJK(r ?: s);
    return r;
}
static id h_ijk_so(id s, SEL c, id u, id o) {
    if ([u isKindOfClass:[NSString class]]) {
        GSRememberURL(u, @"IJK");
        if (!gInOurNetwork) GSFetchM3U8(u);
    }
    id r = ((id(*)(id, SEL, id, id))o_ijk_so)(s, c, u, o);
    GSSampleIJK(r ?: s);
    return r;
}
static id h_ijk_u(id s, SEL c, id u) {
    NSString *us = [u isKindOfClass:[NSURL class]] ? [(NSURL *)u absoluteString]
                   : [u isKindOfClass:[NSString class]] ? u
                                                        : nil;
    if (us) {
        GSRememberURL(us, @"IJK");
        if (!gInOurNetwork) GSFetchM3U8(us);
    }
    id r = ((id(*)(id, SEL, id))o_ijk_u)(s, c, u);
    GSSampleIJK(r ?: s);
    return r;
}
static id h_ijk_uo(id s, SEL c, id u, id o) {
    NSString *us = [u isKindOfClass:[NSURL class]] ? [(NSURL *)u absoluteString]
                   : [u isKindOfClass:[NSString class]] ? u
                                                        : nil;
    if (us) {
        GSRememberURL(us, @"IJK");
        if (!gInOurNetwork) GSFetchM3U8(us);
    }
    id r = ((id(*)(id, SEL, id, id))o_ijk_uo)(s, c, u, o);
    GSSampleIJK(r ?: s);
    return r;
}
static void h_ijk_ds(id s, SEL c, id u) {
    NSString *us = [u isKindOfClass:[NSURL class]] ? [(NSURL *)u absoluteString]
                   : [u isKindOfClass:[NSString class]] ? u
                                                        : nil;
    if (us) {
        GSRememberURL(us, @"IJK-ds");
        if (!gInOurNetwork) GSFetchM3U8(us);
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
        if (!gInOurNetwork) GSFetchM3U8(us);
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
        if (!gInOurNetwork) GSFetchM3U8(us);
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
        if (!gInOurNetwork) GSFetchM3U8(us);
    }
    id r = ((id(*)(id, SEL, id))o_av_initURL)(s, c, url);
    if ([r isKindOfClass:[AVPlayer class]]) GSSampleAV(r);
    return r;
}
static id h_av_playerWithURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVPlayer");
        if (!gInOurNetwork) GSFetchM3U8(us);
    }
    id r = ((id(*)(id, SEL, id))o_av_playerWithURL)(s, c, url);
    if ([r isKindOfClass:[AVPlayer class]]) GSSampleAV(r);
    return r;
}
static id h_item_initURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVItem");
        if (!gInOurNetwork) GSFetchM3U8(us);
    }
    return ((id(*)(id, SEL, id))o_item_initURL)(s, c, url);
}
static id h_item_withURL(id s, SEL c, id url) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVItem");
        if (!gInOurNetwork) GSFetchM3U8(us);
    }
    return ((id(*)(id, SEL, id))o_item_withURL)(s, c, url);
}
static id h_asset_initURL(id s, SEL c, id url, id o) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];
        GSRememberURL(us, @"AVURLAsset");
        if (!gInOurNetwork) GSFetchM3U8(us);
    }
    id r = ((id(*)(id, SEL, id, id))o_asset_initURL)(s, c, url, o);
    if ([r isKindOfClass:[AVAsset class]]) GSLoadAVMeta(r);
    return r;
}
static id h_asset_withURL(id s, SEL c, id url, id o) {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *us = [(NSURL *)url absoluteString];



static id h_sess_req(id s, SEL c, id req) {
    if (!gInOurNetwork && [req isKindOfClass:[NSURLRequest class]]) {
        NSString *u = [(NSURLRequest *)req URL].absoluteString;
        if (u.length) GSRememberURL(u, @"NET");
    }
    return ((id(*)(id, SEL, id))o_sess_req)(s, c, req);
}
static id h_sess_url(id s, SEL c, id url) {
    if (!gInOurNetwork && [url isKindOfClass:[NSURL class]])
        GSRememberURL([(NSURL *)url absoluteString], @"NET");
    return ((id(*)(id, SEL, id))o_sess_url)(s, c, url);
}

static id h_json(id s, SEL c, id data, NSUInteger opt, NSError **err) {
    id obj = ((id(*)(id, SEL, id, NSUInteger, NSError **))o_json)(s, c, data, opt, err);
    if (obj) {
        // 仅当已是容器：用 GSIngest 路径
        @try {
            NSData *raw = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
            if (raw) {
                NSString *txt = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
                if (txt) GSIngestPlaintextMaybeJSON(txt, GSTitleSrcJSON);
            }
        } @catch (__unused NSException *e) {
        }
        dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
    }
    return obj;
}

// flutter_des: handleMethodCall — 解密结果在 result 回调
static void h_des_handle(id s, SEL c, id call, id result) {
    NSString *method = nil;
    id args = nil;
    @try {
        method = [call valueForKey:@"method"];
        args = [call valueForKey:@"arguments"];
    } @catch (__unused NSException *e) {
    }

    BOOL isDecrypt = method && ([method.lowercaseString containsString:@"decrypt"] ||
                                [method isEqualToString:@"decrypt"] ||
                                [method isEqualToString:@"decryptFromHex"]);

    if (!isDecrypt || !result) {
        ((void(*)(id, SEL, id, id))o_des_handle)(s, c, call, result);
        return;
    }

    // 包装 result：拿到明文
    void (^origResult)(id) = result;
    void (^wrap)(id) = ^(id value) {
      if ([value isKindOfClass:[NSString class]]) {
          GSIngestPlaintextMaybeJSON((NSString *)value, GSTitleSrcDES);
          dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
      } else if ([value isKindOfClass:[NSData class]]) {
          NSString *txt = [[NSString alloc] initWithData:(NSData *)value encoding:NSUTF8StringEncoding];
          if (txt) {
              GSIngestPlaintextMaybeJSON(txt, GSTitleSrcDES);
              dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
          }
      } else if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
          @try {
              NSData *raw = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
              NSString *txt = raw ? [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding] : nil;
              if (txt) GSIngestPlaintextMaybeJSON(txt, GSTitleSrcDES);
          } @catch (__unused NSException *e) {
          }
          dispatch_async(dispatch_get_main_queue(), ^{ GSRefreshPanelLabels(); });
      }
      if (origResult) origResult(value);
    };
    ((void(*)(id, SEL, id, id))o_des_handle)(s, c, call, wrap);
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
        GSSwizzleInst(fvp, @selector(initWithURL:httpHeaders:avFactory:registrar:), (IMP)h_fvp_url, &o_fvp_url);
    Class fvpt = NSClassFromString(@"FVPTextureBasedVideoPlayer");
    if (fvpt) {
        SEL s = NSSelectorFromString(@"initWithURL:frameUpdater:displayLink:httpHeaders:avFactory:registrar:onDisposed:");
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
    if (!o_json) {
        Method mm = class_getInstanceMethod(object_getClass((id)[NSJSONSerialization class]),
                                            @selector(JSONObjectWithData:options:error:));
        if (mm) {
            o_json = method_getImplementation(mm);
            method_setImplementation(mm, (IMP)h_json);
            gHooksOK = YES;
        }
    }
    // flutter_des ObjC + Swift 插件
    Class des1 = NSClassFromString(@"FlutterDesPlugin");
    Class des2 = NSClassFromString(@"SwiftFlutterDesPlugin");
    Class des3 = NSClassFromString(@"_TtC11flutter_des21SwiftFlutterDesPlugin");
    for (Class des in @[ des1 ?: [NSNull null], des2 ?: [NSNull null], des3 ?: [NSNull null] ]) {
        if ((id)des == [NSNull null] || !des) continue;
        GSSwizzleInst(des, @selector(handleMethodCall:result:), (IMP)h_des_handle, &o_des_handle);
        if (o_des_handle) break;
    }
}

#pragma mark - NAS

static void GSPushToNAS(void) {
    if (!gURL.length) { GSToast(@"无视频URL"); return; }
    NSString *title = GSEffectiveTitle();
    if (!title.length) title = @"未命名视频";
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"\\/:*?\"<>|\n\r\t"];
    title = [[title componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    if (title.length > 80) title = [title substringToIndex:80];
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"url": gURL, @"title": title} options:0 error:nil];
    if (!json) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGSNASDownloadURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = json;
    req.timeoutInterval = 15;
    GSToast(@"正在推送到 NAS…");
    gInOurNetwork = YES;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        gInOurNetwork = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { GSToast([NSString stringWithFormat:@"推送失败:%@", error.localizedDescription]); return; }
            NSInteger code = 0; NSString *msg = @"";
            if (data.length) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    code = [obj[@"code"] integerValue];
                    msg = [obj[@"msg"] description] ?: @"";
                }
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            if (code == 200 || http.statusCode == 200) GSToast(msg.length ? msg : @"已加入 NAS 队列");
            else GSToast([NSString stringWithFormat:@"异常 HTTP%ld %@", (long)http.statusCode, msg]);
        });
    }] resume];
}

#pragma mark - Panel + FAB

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
    if (gLabRes) gLabRes.text = [NSString stringWithFormat:@"分辨率：%@", GSResText()];
    NSString *eff = GSEffectiveTitle();
    GSTitleSrc autoSrc = GSAutoPickSource();
    NSString *mode = (gTitlePick == GSTitleSrcNone)
        ? [NSString stringWithFormat:@"自动(%@)", GSSrcName(autoSrc)]
        : [NSString stringWithFormat:@"手动(%@)", GSSrcName(gTitlePick)];
    if (gLabTitle)
        gLabTitle.text = [NSString stringWithFormat:@"标题[%@]：%@(点此复制)", mode, eff.length ? eff : @"(未获取)"];
    if (gLabURL)
        gLabURL.text = [NSString stringWithFormat:@"URL：%@(点此复制)", gURL.length ? gURL : @"(未获取)"];
    if (gLabDebug) {
        gLabDebug.text = [NSString stringWithFormat:
            @"调试·各方法标题（点下方按钮切换选用）:\n"
             "A11y: %@\nDES: %@\nJSON: %@\nOCR: %@\nAVMeta: %@\nM3U8: %@\n"
             "当前选用: %@ | hooks=%@ | VOHook=%@",
            GSDash(gTitleBySrc[GSTitleSrcA11y]), GSDash(gTitleBySrc[GSTitleSrcDES]),
            GSDash(gTitleBySrc[GSTitleSrcJSON]), GSDash(gTitleBySrc[GSTitleSrcOCR]),
            GSDash(gTitleBySrc[GSTitleSrcAVMeta]), GSDash(gTitleBySrc[GSTitleSrcM3U8]),
            eff.length ? eff : @"-", gHooksOK ? @"OK" : @"NO", gVoiceOverHooked ? @"YES" : @"NO"];
    }
    // 刷新来源按钮高亮
    GSTitleSrc highlight = (gTitlePick != GSTitleSrcNone) ? gTitlePick : autoSrc;
    for (UIButton *b in gSrcBtns) {
        BOOL isAuto = (b.tag == 99);
        BOOL on = isAuto ? (gTitlePick == GSTitleSrcNone) : (b.tag == highlight);
        b.backgroundColor = on ? [UIColor colorWithRed:0.25 green:0.55 blue:0.95 alpha:0.95]
                               : [UIColor colorWithWhite:0.25 alpha:0.9];
        if (isAuto) {
            b.alpha = 1.0;
        } else if (b.tag >= 0 && b.tag < GSTitleSrcCount) {
            b.alpha = GSLooksLikeTitle(gTitleBySrc[b.tag]) ? 1.0 : 0.4;
        }
    }
    if (gBtnNas) {
        gBtnNas.enabled = gURL.length > 0;
        gBtnNas.alpha = gURL.length ? 1 : 0.45;
    }
}

static void GSHidePanel(void) {
    if (!gPanel) return;
    [UIView animateWithDuration:0.2 animations:^{ gPanel.alpha = 0; } completion:^(BOOL f) { gPanel.hidden = YES; }];
}

static void GSShowPanel(void) {
    UIWindow *win = GSKeyWindow();
    if (!win) return;
    @try {
        GSForceFlutterSemantics();
        GSScanA11yTitle();
        if (gLastAV) GSSampleAV(gLastAV);
        if (gLastIJK) GSSampleIJK(gLastIJK);
        if (gURL.length && !gInOurNetwork) GSFetchM3U8(gURL);
        if (!GSLooksLikeTitle(GSEffectiveTitle())) GSOcrTopTitle();
    } @catch (__unused NSException *e) {}

    if (!gPanel) {
        CGFloat W = MIN(win.bounds.size.width - 24, 380);
        CGFloat H = 460;
        gPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
        gPanel.backgroundColor = [[UIColor colorWithWhite:0.1 alpha:1] colorWithAlphaComponent:0.96];
        gPanel.layer.cornerRadius = 14;
        gPanel.clipsToBounds = YES;

        UILabel *head = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, W - 60, 22)];
        head.text = @"播放信息";
        head.textColor = UIColor.whiteColor;
        head.font = [UIFont boldSystemFontOfSize:17];
        [gPanel addSubview:head];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(W - 44, 6, 36, 36);
        [close setTitle:@"✕" forState:UIControlStateNormal];
        [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [close addTarget:[GSPlayerInfoTapTarget shared] action:@selector(onClosePanel) forControlEvents:UIControlEventTouchUpInside];
        [gPanel addSubview:close];

        gLabRes = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, W - 32, 18)];
        gLabRes.textColor = [UIColor colorWithWhite:0.9 alpha:1];
        gLabRes.font = [UIFont systemFontOfSize:13];
        [gPanel addSubview:gLabRes];

        gLabTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 62, W - 32, 44)];
        gLabTitle.textColor = [UIColor colorWithRed:0.6 green:0.9 blue:1 alpha:1];
        gLabTitle.font = [UIFont systemFontOfSize:12];
        gLabTitle.numberOfLines = 3;
        gLabTitle.userInteractionEnabled = YES;
        [gLabTitle addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:[GSPlayerInfoTapTarget shared] action:@selector(onCopyTitle)]];
        [gPanel addSubview:gLabTitle];

        gLabURL = [[UILabel alloc] initWithFrame:CGRectMake(16, 108, W - 32, 48)];
        gLabURL.textColor = [UIColor colorWithRed:0.55 green:1 blue:0.65 alpha:1];
        gLabURL.font = [UIFont systemFontOfSize:11];
        gLabURL.numberOfLines = 3;
        gLabURL.userInteractionEnabled = YES;
        [gLabURL addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:[GSPlayerInfoTapTarget shared] action:@selector(onCopyURL)]];
        [gPanel addSubview:gLabURL];

        // 可选标题来源按钮
        UILabel *pickHint = [[UILabel alloc] initWithFrame:CGRectMake(16, 160, W - 32, 16)];
        pickHint.text = @"选择标题来源（高亮=当前选用）：";
        pickHint.textColor = [UIColor colorWithWhite:0.7 alpha:1];
        pickHint.font = [UIFont systemFontOfSize:11];
        [gPanel addSubview:pickHint];

        gSrcBtns = [NSMutableArray array];
        NSArray *names = @[ @"A11y", @"DES", @"JSON", @"OCR", @"AVMeta", @"M3U8", @"自动" ];
        CGFloat bw = (W - 32 - 18) / 4.0;
        for (int i = 0; i < 7; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            int row = i / 4, col = i % 4;
            b.frame = CGRectMake(16 + col * (bw + 6), 180 + row * 30, bw, 26);
            b.tag = (i < 6) ? i : 99; // 99=自动
            b.layer.cornerRadius = 6;
            b.titleLabel.font = [UIFont systemFontOfSize:11];
            [b setTitle:names[i] forState:UIControlStateNormal];
            [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            b.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.9];
            [b addTarget:[GSPlayerInfoTapTarget shared] action:@selector(onPickSrc:) forControlEvents:UIControlEventTouchUpInside];
            [gPanel addSubview:b];
            if (i < 6) [gSrcBtns addObject:b];
            else [gSrcBtns addObject:b]; // include auto btn too for styling optional
        }

        gBtnNas = [UIButton buttonWithType:UIButtonTypeCustom];
        gBtnNas.frame = CGRectMake(16, 248, W - 32, 44);
        gBtnNas.backgroundColor = [UIColor colorWithRed:0.2 green:0.55 blue:0.95 alpha:1];
        gBtnNas.layer.cornerRadius = 10;
        [gBtnNas setTitle:@"推送到 NAS 下载" forState:UIControlStateNormal];
        [gBtnNas setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gBtnNas.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [gBtnNas addTarget:[GSPlayerInfoTapTarget shared] action:@selector(onPushNAS) forControlEvents:UIControlEventTouchUpInside];
        [gPanel addSubview:gBtnNas];

        UIView *dbgBox = [[UIView alloc] initWithFrame:CGRectMake(10, 302, W - 20, 148)];
        dbgBox.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.95];
        dbgBox.layer.cornerRadius = 8;
        [gPanel addSubview:dbgBox];
        gLabDebug = [[UILabel alloc] initWithFrame:CGRectMake(8, 6, W - 36, 136)];
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GSForceFlutterSemantics();
        GSScanA11yTitle();
        GSRefreshPanelLabels();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GSScanA11yTitle();
        if (!GSLooksLikeTitle(GSEffectiveTitle())) GSOcrTopTitle();
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
        [gBtn addTarget:[GSPlayerInfoTapTarget shared] action:@selector(onFab) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[GSPlayerInfoTapTarget shared] action:@selector(onPan:)];
        pan.delegate = [GSPlayerInfoTapTarget shared];
        pan.cancelsTouchesInView = NO;
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
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }
- (void)onPan:(UIPanGestureRecognizer *)pan {
    UIWindow *win = GSKeyWindow();
    if (!win || !gBtn) return;
    if (pan.state == UIGestureRecognizerStateBegan) gFabMoved = NO;
    else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:win];
        if (fabs(t.x) + fabs(t.y) > 4) gFabMoved = YES;
        if (!gFabMoved) return;
        gFabOffset = CGPointMake(gFabOffset.x + t.x, gFabOffset.y + t.y);
        [pan setTranslation:CGPointZero inView:win];
        GSLayoutFab();
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        if (gFabMoved)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ gFabMoved = NO; });
        else gFabMoved = NO;
    }
}
- (void)onFab {
    if (gFabMoved) return;
    @try {
        if (gPanel && !gPanel.hidden) GSHidePanel();
        else GSShowPanel();
    } @catch (__unused NSException *e) { GSToast(@"面板异常"); }
}
- (void)onClosePanel { GSHidePanel(); }
- (void)onPickSrc:(UIButton *)btn {
    if (btn.tag == 99) {
        gTitlePick = GSTitleSrcNone; // 自动
        GSToast(@"已切回自动选标题");
    } else if (btn.tag >= 0 && btn.tag < GSTitleSrcCount) {
        if (!GSLooksLikeTitle(gTitleBySrc[btn.tag])) {
            GSToast(@"该来源暂无有效标题");
            return;
        }
        gTitlePick = (GSTitleSrc)btn.tag;
        GSToast([NSString stringWithFormat:@"已选用:%@", GSSrcName(gTitlePick)]);
    }
    GSRefreshPanelLabels();
}
- (void)onCopyTitle {
    GSForceFlutterSemantics();
    GSScanA11yTitle();
    if (!GSLooksLikeTitle(GSEffectiveTitle())) GSOcrTopTitle();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *t = GSEffectiveTitle();
        if (t.length) { UIPasteboard.generalPasteboard.string = t; GSToast(@"已复制标题"); }
        else GSToast(@"暂无有效标题");
        GSRefreshPanelLabels();
    });
}
- (void)onCopyURL {
    if (!gURL.length) { GSToast(@"暂无URL"); return; }
    UIPasteboard.generalPasteboard.string = gURL;
    GSToast(@"已复制URL");
}
- (void)onPushNAS { GSPushToNAS(); }
- (void)onTick {
    @try {
        GSInstallHooks();
        GSForceFlutterSemantics();
        GSEnsureFab();
        if (gLastAV) GSSampleAV(gLastAV);
        if (gLastIJK) GSSampleIJK(gLastIJK);
        if (gURL.length || gLastAV || gLastIJK) {
            GSScanA11yTitle();
            if (!GSLooksLikeTitle(GSEffectiveTitle())) GSOcrTopTitle();
            if (gURL.length && !gInOurNetwork) GSFetchM3U8(gURL);
        }
        // 清技术串
        for (int i = 0; i < GSTitleSrcCount; i++) {
            if (gTitleBySrc[i].length && GSIsTechIdentifier(gTitleBySrc[i])) gTitleBySrc[i] = @"";
        }
        if (gPanel && !gPanel.hidden) GSRefreshPanelLabels();
    } @catch (__unused NSException *e) {}
}
- (void)onIJKNote:(NSNotification *)n { GSSampleIJK(n.object); }
@end

#pragma mark - Boot

static void GSBoot(void) {
    for (int i = 0; i < GSTitleSrcCount; i++) gTitleBySrc[i] = @"";
    gTitlePick = GSTitleSrcNone;
    GSForceFlutterSemantics();
    GSInstallHooks();
    GSEnsureFab();
    GSPlayerInfoTapTarget *t = [GSPlayerInfoTapTarget shared];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:t selector:@selector(onTick) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:t selector:@selector(onIJKNote:) name:@"IJKMPMovieNaturalSizeAvailableNotification" object:nil];
    [NSTimer scheduledTimerWithTimeInterval:1.2 target:t selector:@selector(onTick) userInfo:nil repeats:YES];
}

__attribute__((constructor)) static void GSPlayerInfoInit(void) {
    if ([NSThread isMainThread]) GSBoot();
    else dispatch_async(dispatch_get_main_queue(), ^{ GSBoot(); });
    for (int i = 1; i <= 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GSForceFlutterSemantics();
            GSInstallHooks();
            GSEnsureFab();
        });
    }
}
