//
//  byg_title.m
//  与 get_title.py / PRINCIPLE.md 对齐的堆扫描实现：
//  热区(1.0X/m3u8) + 分隔符 + 通用针点 → 过滤 → exact count → hot/count/len 排序
//

#import "byg_title.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <sys/types.h>

#pragma mark - Cache

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char *g_cached_title = NULL;

static char *byg_strdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n + 1);
    return p;
}

static void byg_set_cache_unlocked(const char *utf8) {
    if (g_cached_title) {
        free(g_cached_title);
        g_cached_title = NULL;
    }
    if (utf8) g_cached_title = byg_strdup(utf8);
}

#pragma mark - Region enum

typedef struct {
    mach_vm_address_t addr;
    mach_vm_size_t size;
} byg_region_t;

static void byg_enum_rw_regions(byg_region_t **out_list, size_t *out_count) {
    *out_list = NULL;
    *out_count = 0;
    task_t task = mach_task_self();
    mach_vm_address_t address = 0;
    byg_region_t *list = NULL;
    size_t n = 0, cap = 0;

    for (;;) {
        mach_vm_size_t size = 0;
        natural_t depth = 0;
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        memset(&info, 0, sizeof(info));

        kern_return_t kr = mach_vm_region_recurse(
            task, &address, &size, &depth, (vm_region_recurse_info_t)&info, &count);
        if (kr != KERN_SUCCESS)
            break;

        bool readable = (info.protection & VM_PROT_READ) != 0;
        bool writable = (info.protection & VM_PROT_WRITE) != 0;
        if (readable && writable && size >= 4096 && size <= (64ull * 1024 * 1024)) {
            if (n + 1 > cap) {
                cap = cap ? cap * 2 : 64;
                list = (byg_region_t *)realloc(list, cap * sizeof(byg_region_t));
                if (!list) {
                    *out_list = NULL;
                    *out_count = 0;
                    return;
                }
            }
            list[n].addr = address;
            list[n].size = size;
            n++;
        }
        address += size;
        if (size == 0)
            break;
    }

    // 大区优先（与 Frida allRanges sort 一致）
    for (size_t i = 0; i + 1 < n; i++) {
        for (size_t j = i + 1; j < n; j++) {
            if (list[j].size > list[i].size) {
                byg_region_t t = list[i];
                list[i] = list[j];
                list[j] = t;
            }
        }
    }

    *out_list = list;
    *out_count = n;
}

static bool byg_read_chunk(mach_vm_address_t addr, mach_vm_size_t size, uint8_t *buf) {
    mach_vm_size_t out = 0;
    kern_return_t kr = mach_vm_read_overwrite(
        mach_task_self(), addr, size, (mach_vm_address_t)(uintptr_t)buf, &out);
    return kr == KERN_SUCCESS && out == size;
}

#pragma mark - UTF-16 helpers

static bool byg_is_title_unit(uint16_t cu) {
    if (cu == 0)
        return false;
    if (cu >= 0x4e00 && cu <= 0x9fff)
        return true;
    if (cu >= 0x3040 && cu <= 0x30ff)
        return true;
    if (cu >= 0x3000 && cu <= 0x303f)
        return true;
    if (cu == 0x2026 || cu == 0x00b7)
        return true;
    if (cu >= 0x20 && cu < 0x7f)
        return true;
    return false;
}

static uint16_t byg_u16_at(const uint8_t *buf, size_t off) {
    return (uint16_t)buf[off] | ((uint16_t)buf[off + 1] << 8);
}

// 从 hit_off 对齐后向前回溯再读全串，返回 NSString（nil 失败）
static NSString *byg_read_utf16_title(const uint8_t *buf, size_t buflen, size_t hit_off) {
    if (hit_off + 1 >= buflen)
        return nil;
    size_t off = hit_off & ~(size_t)1;

    while (off >= 2) {
        uint16_t prev = byg_u16_at(buf, off - 2);
        if (!byg_is_title_unit(prev))
            break;
        off -= 2;
    }

    unichar tmp[128];
    size_t n = 0;
    size_t p = off;
    while (p + 1 < buflen && n < 100) {
        uint16_t cu = byg_u16_at(buf, p);
        if (!byg_is_title_unit(cu))
            break;
        tmp[n++] = (unichar)cu;
        p += 2;
    }
    if (n < 12)
        return nil;
    return [NSString stringWithCharacters:tmp length:n];
}

static NSString *byg_clean_title(NSString *t) {
    if (!t.length)
        return t;
    // 去掉尾部控制符 / 噪声
    NSMutableString *m = [t mutableCopy];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"萴"];
    NSRange r;
    while ((r = [m rangeOfCharacterFromSet:bad]).location != NSNotFound)
        [m deleteCharactersInRange:r];
    // 去尾部 C0
    while (m.length) {
        unichar c = [m characterAtIndex:m.length - 1];
        if (c < 0x20)
            [m deleteCharactersInRange:NSMakeRange(m.length - 1, 1)];
        else
            break;
    }
    return [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSUInteger byg_cjk_count(NSString *s) {
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar x = [s characterAtIndex:i];
        if (x >= 0x4e00 && x <= 0x9fff)
            n++;
    }
    return n;
}

static BOOL byg_is_ascii_masq(NSString *s) {
    NSUInteger both = 0, hi = 0, ck = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar cu = [s characterAtIndex:i];
        if (cu < 0x4e00 || cu > 0x9fff)
            continue;
        ck++;
        unsigned lo = cu & 0xff, h = (cu >> 8) & 0xff;
        if (lo >= 0x20 && lo < 0x7f && h >= 0x20 && h < 0x7f)
            both++;
        if (lo >= 0x80)
            hi++;
    }
    if (ck < 4)
        return YES;
    if ((double)both / (double)ck > 0.45)
        return YES;
    if ((double)hi / (double)ck < 0.25)
        return YES;
    return NO;
}

static BOOL byg_garbage(NSString *t) {
    if (!t || t.length < 12 || t.length > 95)
        return YES;
    if ([t rangeOfString:@"怪兽承诺"].location != NSNotFound)
        return YES;
    if ([t rangeOfString:@"做牛马"].location != NSNotFound)
        return YES;
    if ([t rangeOfString:@"分享才有动力"].location != NSNotFound)
        return YES;
    if ([t rangeOfString:@"肀肀"].location != NSNotFound)
        return YES;
    // 半角片假名
    NSUInteger half = 0;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c >= 0xff61 && c <= 0xff9f)
            half++;
    }
    if (half >= 2)
        return YES;
    NSUInteger cjk = byg_cjk_count(t);
    if (cjk < 8 || (double)cjk / (double)t.length < 0.48)
        return YES;
    if (byg_is_ascii_masq(t))
        return YES;
    // 片名常见分隔
    BOOL hasSep = NO;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c == ' ' || c == ',' || c == 0xff0c || c == 0x3010 /*【*/ || c == '[' || c == '-') {
            hasSep = YES;
            break;
        }
    }
    if (!hasSep)
        return YES;
    // 英文按 UTF-16 误读的「｜ｋｚ…」类
    static NSString *const kBadChars = @"｜ｋｚｐｕｗｘｙ惿";
    for (NSUInteger i = 0; i < kBadChars.length; i++) {
        if ([t rangeOfString:[kBadChars substringWithRange:NSMakeRange(i, 1)]].location != NSNotFound)
            return YES;
    }
    return NO;
}

static void byg_add_candidate(NSMutableDictionary *found, NSString *t, int hot) {
    t = byg_clean_title(t);
    if (byg_garbage(t))
        return;
    NSNumber *cur = found[t];
    int h = (cur ? cur.intValue : 0) + hot;
    found[t] = @(h);
}

#pragma mark - memmem

static void byg_memmem_all(const uint8_t *buf, size_t len, const uint8_t *needle, size_t nlen,
                           size_t *offs, size_t *count, size_t cap) {
    *count = 0;
    if (!needle || nlen == 0 || len < nlen)
        return;
    for (size_t i = 0; i + nlen <= len; i++) {
        if (memcmp(buf + i, needle, nlen) == 0) {
            if (*count < cap)
                offs[(*count)++] = i;
            if (*count >= cap)
                return;
        }
    }
}

#pragma mark - Harvest

static void byg_harvest_hot_buf(const uint8_t *buf, size_t len, NSMutableDictionary *found,
                                int *marks_left) {
    static const char *pats[] = {"1.0X", "1.5X", "2.0X", "0.5X", "m3u8", ".m3u8"};
    static const size_t plen[] = {4, 4, 4, 4, 4, 5};
    size_t offs[64];
    for (size_t pi = 0; pi < 6 && *marks_left > 0; pi++) {
        size_t n = 0;
        byg_memmem_all(buf, len, (const uint8_t *)pats[pi], plen[pi], offs, &n, 64);
        for (size_t j = 0; j < n && *marks_left > 0; j++) {
            (*marks_left)--;
            size_t mark = offs[j];
            // 窗口 [mark-500, mark+800)，步进 2，找 CJK 串起点
            ssize_t start = (ssize_t)mark - 500;
            if (start < 0)
                start = 0;
            // 对齐偶地址
            start &= ~1;
            ssize_t end = (ssize_t)mark + 800;
            if (end > (ssize_t)len)
                end = (ssize_t)len;
            for (ssize_t off = start; off + 1 < end; off += 2) {
                uint16_t cu = byg_u16_at(buf, (size_t)off);
                if (cu < 0x4e00 || cu > 0x9fff)
                    continue;
                if (off > start) {
                    uint16_t pv = byg_u16_at(buf, (size_t)off - 2);
                    if (byg_is_title_unit(pv) && pv != 0)
                        continue; // 非串起点
                }
                NSString *t = byg_read_utf16_title(buf, len, (size_t)off);
                if (t)
                    byg_add_candidate(found, t, 1);
            }
        }
    }
}

static void byg_harvest_seps_buf(const uint8_t *buf, size_t len, NSMutableDictionary *found,
                                 int *used_left) {
    // space / ideographic space / fullwidth comma / comma / （0d ff 兼容）
    static const uint8_t seps[][2] = {
        {0x20, 0x00}, {0x00, 0x30}, {0x0c, 0xff}, {0x2c, 0x00}, {0x0d, 0xff},
    };
    size_t offs[800];
    for (size_t si = 0; si < 5 && *used_left > 0; si++) {
        size_t n = 0;
        byg_memmem_all(buf, len, seps[si], 2, offs, &n, 800);
        for (size_t j = 0; j < n && *used_left > 0; j++) {
            size_t a = offs[j];
            if (a < 2)
                continue;
            uint16_t before = byg_u16_at(buf, a - 2);
            if (before < 0x4e00 || before > 0x9fff)
                continue;
            (*used_left)--;
            // 从 sep 前回溯
            size_t start = a;
            for (int b = 1; b <= 55; b++) {
                size_t po = a - (size_t)b * 2;
                if (po + 1 >= a)
                    break;
                if (po + 1 >= len)
                    break;
                uint16_t cu = byg_u16_at(buf, po);
                if (cu == 0 || !byg_is_title_unit(cu))
                    break;
                start = po;
            }
            if (start + 1 >= len)
                continue;
            if (byg_u16_at(buf, start) < 0x4e00)
                continue;
            NSString *t = byg_read_utf16_title(buf, len, start);
            if (t)
                byg_add_candidate(found, t, 0);
        }
    }
}

static void byg_harvest_needles_buf(const uint8_t *buf, size_t len, NSMutableDictionary *found,
                                    NSArray<NSData *> *needles) {
    size_t offs[50];
    for (NSData *nd in needles) {
        if (nd.length < 2)
            continue;
        size_t n = 0;
        byg_memmem_all(buf, len, (const uint8_t *)nd.bytes, nd.length, offs, &n, 50);
        for (size_t j = 0; j < n; j++) {
            size_t a = offs[j];
            // 向前回溯
            size_t start = a;
            for (int b = 1; b <= 55; b++) {
                if (a < (size_t)b * 2)
                    break;
                size_t po = a - (size_t)b * 2;
                uint16_t cu = byg_u16_at(buf, po);
                if (cu == 0 || !byg_is_title_unit(cu))
                    break;
                start = po;
            }
            NSString *t = byg_read_utf16_title(buf, len, start);
            if (t)
                byg_add_candidate(found, t, 0);
        }
    }
}

static NSArray<NSData *> *byg_needle_datas(void) {
    static NSArray<NSData *> *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSArray *needles = @[
          @"束缚", @"调教", @"双马尾", @"新人", @"首作", @"女仆", @"学姐", @"萝莉",
          @"人妻", @"内射", @"COS", @"cos", @"玩具", @"试用", @"任务", @"物资",
          @"精液", @"肉棒", @"骚穴", @"肉穴", @"淫荡", @"体验", @"中出", @"按摩",
          @"时间停止", @"达妮娅", @"NTR", @"角色扮演", @"充电", @"布兰", @"菲比",
          @"李慕婉", @"花火", @"公孙离", @"警官", @"灌肠", @"裸贷",
      ];
      NSMutableArray *arr = [NSMutableArray arrayWithCapacity:needles.count];
      for (NSString *s in needles) {
          NSData *d = [s dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
          // NSString UTF16LE 可能带 BOM；去掉
          if (d.length >= 2) {
              const uint8_t *b = d.bytes;
              if (b[0] == 0xff && b[1] == 0xfe)
                  d = [d subdataWithRange:NSMakeRange(2, d.length - 2)];
              else if (b[0] == 0xfe && b[1] == 0xff)
                  d = [d subdataWithRange:NSMakeRange(2, d.length - 2)];
          }
          if (d.length)
              [arr addObject:d];
      }
      cached = [arr copy];
    });
    return cached;
}

#pragma mark - count / fragment / sort

static int byg_count_exact(NSString *text, byg_region_t *regions, size_t nreg, uint8_t *buf,
                           size_t chunk_cap, CFAbsoluteTime deadline) {
    if (text.length < 4)
        return 0;
    NSUInteger npre = MIN((NSUInteger)10, text.length);
    NSString *prefix = [text substringToIndex:npre];
    NSData *preData = [prefix dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (preData.length >= 2) {
        const uint8_t *b = preData.bytes;
        if ((b[0] == 0xff && b[1] == 0xfe) || (b[0] == 0xfe && b[1] == 0xff))
            preData = [preData subdataWithRange:NSMakeRange(2, preData.length - 2)];
    }
    if (preData.length < 2)
        return 0;

    NSData *fullData = [text dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (fullData.length >= 2) {
        const uint8_t *b = fullData.bytes;
        if ((b[0] == 0xff && b[1] == 0xfe) || (b[0] == 0xfe && b[1] == 0xff))
            fullData = [fullData subdataWithRange:NSMakeRange(2, fullData.length - 2)];
    }
    size_t fullBytes = fullData.length;
    int cnt = 0;
    const size_t OVERLAP = 256;

    for (size_t ri = 0; ri < nreg && cnt < 20; ri++) {
        if (CFAbsoluteTimeGetCurrent() > deadline)
            break;
        mach_vm_address_t cur = regions[ri].addr;
        mach_vm_size_t remain = regions[ri].size;
        // 与 Frida 一致：单区最多扫 8MB
        if (remain > 8ull * 1024 * 1024)
            remain = 8ull * 1024 * 1024;

        while (remain > 0 && cnt < 20) {
            mach_vm_size_t chunk = remain > chunk_cap ? chunk_cap : remain;
            if (!byg_read_chunk(cur, chunk, buf)) {
                cur += chunk;
                remain = remain > chunk ? remain - chunk : 0;
                continue;
            }
            size_t offs[64];
            size_t nh = 0;
            byg_memmem_all(buf, (size_t)chunk, (const uint8_t *)preData.bytes, preData.length, offs,
                           &nh, 64);
            for (size_t j = 0; j < nh && cnt < 20; j++) {
                size_t off = offs[j];
                if (off + fullBytes > (size_t)chunk)
                    continue;
                if (memcmp(buf + off, fullData.bytes, fullBytes) == 0) {
                    // 完整等于 text：后一 unit 不应继续是 title 串的延伸？
                    // Frida: readUtf16(addr, text.length+2) === text → 刚好停在 text 后
                    size_t after = off + fullBytes;
                    if (after + 1 < (size_t)chunk) {
                        uint16_t next = byg_u16_at(buf, after);
                        if (byg_is_title_unit(next) && next != 0)
                            continue; // 更长串的前缀，不算 exact
                    }
                    cnt++;
                }
            }
            if (remain <= chunk)
                break;
            // overlap 推进
            mach_vm_size_t step = chunk > OVERLAP ? chunk - OVERLAP : chunk;
            cur += step;
            remain -= step;
        }
    }
    return cnt;
}

static BOOL byg_is_fragment_of(NSString *a, NSString *b) {
    if (!a.length || !b.length || [a isEqualToString:b] || a.length >= b.length)
        return NO;
    if ([b containsString:a])
        return YES;
    NSCharacterSet *strip =
        [NSCharacterSet characterSetWithCharactersInString:@" \t,，.。…-|【】[]"];
    NSArray *pa = [a componentsSeparatedByCharactersInSet:strip];
    NSArray *pb = [b componentsSeparatedByCharactersInSet:strip];
    NSString *na = [pa componentsJoinedByString:@""];
    NSString *nb = [pb componentsJoinedByString:@""];
    return na.length >= 8 && [nb containsString:na];
}

#pragma mark - Scan core

static int byg_scan_current_title_utf8(char **out_utf8, uint32_t timeout_ms) {
    if (!out_utf8)
        return -1;
    *out_utf8 = NULL;

    CFAbsoluteTime deadline =
        CFAbsoluteTimeGetCurrent() + ((timeout_ms > 0) ? (timeout_ms / 1000.0) : 5.0);

    byg_region_t *regions = NULL;
    size_t nreg = 0;
    byg_enum_rw_regions(&regions, &nreg);
    if (!regions || nreg == 0)
        return -3;

    const size_t CHUNK = 2 * 1024 * 1024;
    const size_t OVERLAP = 256;
    uint8_t *buf = (uint8_t *)malloc(CHUNK);
    if (!buf) {
        free(regions);
        return -4;
    }

    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    int hot_marks_left = 40;
    int sep_used_left = 600;
    NSArray<NSData *> *needles = byg_needle_datas();

    // 限制扫区数量（Frida sep 用 min(40)）
    size_t max_reg = nreg > 48 ? 48 : nreg;

    for (size_t i = 0; i < max_reg; i++) {
        if (CFAbsoluteTimeGetCurrent() > deadline)
            break;

        mach_vm_address_t cur = regions[i].addr;
        mach_vm_size_t remain = regions[i].size;
        // 热区/针点单区上限 12MB（对齐 Frida Math.min）
        if (remain > 12ull * 1024 * 1024)
            remain = 12ull * 1024 * 1024;

        while (remain > 0) {
            if (CFAbsoluteTimeGetCurrent() > deadline)
                break;
            mach_vm_size_t chunk = remain > CHUNK ? CHUNK : remain;
            if (!byg_read_chunk(cur, chunk, buf)) {
                cur += chunk;
                remain = remain > chunk ? remain - chunk : 0;
                continue;
            }

            byg_harvest_hot_buf(buf, (size_t)chunk, found, &hot_marks_left);
            byg_harvest_seps_buf(buf, (size_t)chunk, found, &sep_used_left);
            byg_harvest_needles_buf(buf, (size_t)chunk, found, needles);

            if (remain <= chunk)
                break;
            mach_vm_size_t step = chunk > OVERLAP ? chunk - OVERLAP : chunk;
            cur += step;
            remain -= step;
        }
    }

    // 候选列表
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *t in found) {
        if (CFAbsoluteTimeGetCurrent() > deadline)
            break;
        int hot = [found[t] intValue];
        int c = byg_count_exact(t, regions, max_reg, buf, CHUNK, deadline);
        if (c < 1)
            c = 1;
        [items addObject:@{
            @"text" : t,
            @"hot" : @(hot),
            @"count" : @(c),
            @"len" : @(t.length),
        }];
    }

    free(buf);
    free(regions);

    // 去残片
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSUInteger i = 0; i < items.count; i++) {
        NSString *ti = items[i][@"text"];
        BOOL frag = NO;
        for (NSUInteger j = 0; j < items.count; j++) {
            if (i == j)
                continue;
            if (byg_is_fragment_of(ti, items[j][@"text"])) {
                frag = YES;
                break;
            }
        }
        if (!frag)
            [filtered addObject:items[i]];
    }

    // hot ↓ → count ↓ → len ↓
    [filtered sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      int ha = [a[@"hot"] intValue], hb = [b[@"hot"] intValue];
      if (hb != ha)
          return hb > ha ? NSOrderedDescending : NSOrderedAscending;
      int ca = [a[@"count"] intValue], cb = [b[@"count"] intValue];
      if (cb != ca)
          return cb > ca ? NSOrderedDescending : NSOrderedAscending;
      int la = [a[@"len"] intValue], lb = [b[@"len"] intValue];
      if (lb != la)
          return lb > la ? NSOrderedDescending : NSOrderedAscending;
      return NSOrderedSame;
    }];

    if (!filtered.count)
        return -5;

    NSString *best = filtered[0][@"text"];
    if (!best.length)
        return -5;

    const char *u8 = [best UTF8String];
    if (!u8)
        return -6;
    *out_utf8 = byg_strdup(u8);
    return *out_utf8 ? 0 : -6;
}

#pragma mark - Public API

char *byg_copy_current_video_title(void) {
    return byg_copy_current_video_title_timeout(5000);
}

char *byg_copy_current_video_title_timeout(uint32_t timeout_ms) {
    char *result = NULL;
    @autoreleasepool {
        int rc = byg_scan_current_title_utf8(&result, timeout_ms);
        if (rc != 0 || !result) {
            pthread_mutex_lock(&g_lock);
            if (g_cached_title)
                result = byg_strdup(g_cached_title);
            pthread_mutex_unlock(&g_lock);
            return result;
        }
        pthread_mutex_lock(&g_lock);
        byg_set_cache_unlocked(result);
        pthread_mutex_unlock(&g_lock);
        return result;
    }
}

const char *byg_last_video_title_cached(void) {
    const char *p = NULL;
    pthread_mutex_lock(&g_lock);
    p = g_cached_title;
    pthread_mutex_unlock(&g_lock);
    return p;
}

void byg_clear_video_title_cache(void) {
    pthread_mutex_lock(&g_lock);
    byg_set_cache_unlocked(NULL);
    pthread_mutex_unlock(&g_lock);
}
