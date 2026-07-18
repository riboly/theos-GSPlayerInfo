//
//  byg_title.m
//  与 get_title.py / PRINCIPLE.md 对齐：
//  热区(1.0X/m3u8) + 分隔符 + 针点 → 过滤 → exact count → hot/count/len
//
//  关键修复：
//  1) 正确处理 vm_region_recurse_64 的 is_submap（此前 depth 恒 0 会漏 Dart 堆）
//  2) 注入进程内直接读指针（Frida 同进程语义），不用大块 vm_read_overwrite（易慢/失败）
//  3) 热区优先；有 hot 候选可提前结束，避免 sep 全堆拖死
//  4) 诊断串 byg_last_scan_debug
//

#import "byg_title.h"

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/types.h>

#pragma mark - Cache / debug

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char *g_cached_title = NULL;
static char g_dbg[256] = "rc=- reg=0 cand=0";

static char *byg_strdup(const char *s) {
    if (!s)
        return NULL;
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p)
        return NULL;
    memcpy(p, s, n + 1);
    return p;
}

static void byg_set_cache_unlocked(const char *utf8) {
    if (g_cached_title) {
        free(g_cached_title);
        g_cached_title = NULL;
    }
    if (utf8)
        g_cached_title = byg_strdup(utf8);
}

static void byg_set_dbg(int rc, size_t nreg, size_t ncand, size_t nhot, size_t nitems) {
    snprintf(g_dbg, sizeof(g_dbg), "rc=%d reg=%zu cand=%zu hot=%zu items=%zu", rc, nreg, ncand,
             nhot, nitems);
}

#pragma mark - Regions（关键：submap 递归）

typedef struct {
    vm_address_t addr;
    vm_size_t size;
} byg_region_t;

/*
 * 正确枚举用户 rw 区。iOS/macOS 上很多堆在 submap 里：
 * is_submap=1 时 depth++ 且不前进 address，再 recurse 进入。
 * 叶子区 address += size 后 depth=0。
 */
static void byg_enum_rw_regions(byg_region_t **out_list, size_t *out_count) {
    *out_list = NULL;
    *out_count = 0;

    task_t task = mach_task_self();
    vm_address_t address = 0;
    natural_t depth = 0;
    byg_region_t *list = NULL;
    size_t n = 0, cap = 0;
    int guard = 0;

    while (guard++ < 200000) {
        vm_size_t size = 0;
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        memset(&info, 0, sizeof(info));

        kern_return_t kr = vm_region_recurse_64(task, &address, &size, &depth,
                                                (vm_region_recurse_info_t)&info, &count);
        if (kr != KERN_SUCCESS)
            break;

        if (info.is_submap) {
            // 进入子映射，不要 address += size
            depth++;
            continue;
        }

        bool readable = (info.protection & VM_PROT_READ) != 0;
        bool writable = (info.protection & VM_PROT_WRITE) != 0;
        // Dart 堆多为 rw；个别实现可能带 execute，仍收
        if (readable && writable && size >= 4096 && size <= (64ull * 1024 * 1024)) {
            // 跳过过低地址（通常不是堆）
            if (address >= 0x100000000ull || address >= 0x1000000ull) {
                if (n + 1 > cap) {
                    cap = cap ? cap * 2 : 128;
                    byg_region_t *nl =
                        (byg_region_t *)realloc(list, cap * sizeof(byg_region_t));
                    if (!nl) {
                        free(list);
                        *out_list = NULL;
                        *out_count = 0;
                        return;
                    }
                    list = nl;
                }
                list[n].addr = address;
                list[n].size = size;
                n++;
            }
        }

        if (size == 0)
            break;
        address += size;
        depth = 0;
    }

    // 相邻 rw 合并（类似 Frida coalesce）
    if (n > 1) {
        size_t w = 0;
        for (size_t i = 0; i < n; i++) {
            if (w == 0) {
                list[w++] = list[i];
                continue;
            }
            byg_region_t *prev = &list[w - 1];
            if (prev->addr + prev->size == list[i].addr &&
                prev->size + list[i].size <= (64ull * 1024 * 1024)) {
                prev->size += list[i].size;
            } else {
                list[w++] = list[i];
            }
        }
        n = w;
    }

    // 大区优先
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

// 安全读入 buf（失败则跳过该段，避免直接解引用崩溃）
static bool byg_copy_pages(vm_address_t addr, vm_size_t size, uint8_t *buf, vm_size_t *out_n) {
    *out_n = 0;
    if (size == 0 || !buf)
        return false;
    vm_size_t got = 0;
    kern_return_t kr =
        vm_read_overwrite(mach_task_self(), addr, size, (vm_address_t)(uintptr_t)buf, &got);
    if (kr == KERN_SUCCESS && got > 0) {
        *out_n = got;
        return true;
    }
    return false;
}

#pragma mark - UTF-16

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
    // 全角标点等
    if (cu == 0xff0c || cu == 0x3001 || cu == 0x3002 || cu == 0x3010 || cu == 0x3011)
        return true;
    if (cu == 0xff08 || cu == 0xff09 || cu == 0x201c || cu == 0x201d)
        return true;
    return false;
}

static inline uint16_t byg_u16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static NSString *byg_read_utf16_title(const uint8_t *buf, size_t buflen, size_t hit_off) {
    if (hit_off + 1 >= buflen)
        return nil;
    size_t off = hit_off & ~(size_t)1;

    while (off >= 2) {
        uint16_t prev = byg_u16(buf + off - 2);
        if (!byg_is_title_unit(prev))
            break;
        off -= 2;
    }

    unichar tmp[128];
    size_t n = 0;
    size_t p = off;
    while (p + 1 < buflen && n < 100) {
        uint16_t cu = byg_u16(buf + p);
        if (!byg_is_title_unit(cu))
            break;
        tmp[n++] = (unichar)cu;
        p += 2;
    }
    if (n < 10)
        return nil;
    return [NSString stringWithCharacters:tmp length:n];
}

static NSString *byg_clean_title(NSString *t) {
    if (!t.length)
        return t;
    NSMutableString *m = [t mutableCopy];
    while (m.length) {
        unichar c = [m characterAtIndex:m.length - 1];
        if (c < 0x20 || c == 0x8484 /*萴*/)
            [m deleteCharactersInRange:NSMakeRange(m.length - 1, 1)];
        else
            break;
    }
    while (m.length) {
        unichar c = [m characterAtIndex:0];
        if (c < 0x20)
            [m deleteCharactersInRange:NSMakeRange(0, 1)];
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
    if (!t || t.length < 10 || t.length > 95)
        return YES;
    if ([t containsString:@"怪兽承诺"] || [t containsString:@"做牛马"] ||
        [t containsString:@"分享才有动力"] || [t containsString:@"肀肀"])
        return YES;
    if ([t containsString:@"http"] || [t containsString:@"m3u8"] || [t containsString:@".mp4"])
        return YES;

    NSUInteger half = 0;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c >= 0xff61 && c <= 0xff9f)
            half++;
    }
    if (half >= 2)
        return YES;

    NSUInteger cjk = byg_cjk_count(t);
    // 略放宽：cjk>=6 且占比>=0.40（Frida 为 8/0.48，过严会漏）
    if (cjk < 6 || (double)cjk / (double)t.length < 0.40)
        return YES;
    if (byg_is_ascii_masq(t))
        return YES;

    BOOL hasSep = NO;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c == ' ' || c == ',' || c == 0xff0c || c == 0x3000 || c == 0x3010 || c == '[' ||
            c == '-' || c == 0x3001)
            hasSep = YES;
    }
    // 无分隔时若 cjk 很长也可能是标题，放宽：cjk>=14 可过
    if (!hasSep && cjk < 14)
        return YES;

    static NSString *const kBad = @"｜ｋｚｐｕｗｘｙ惿忿";
    for (NSUInteger i = 0; i < kBad.length; i++) {
        if ([t rangeOfString:[kBad substringWithRange:NSMakeRange(i, 1)]].location != NSNotFound)
            return YES;
    }
    return NO;
}

static void byg_add(NSMutableDictionary *found, NSString *t, int hot) {
    t = byg_clean_title(t);
    if (byg_garbage(t))
        return;
    int h = [found[t] intValue] + hot;
    found[t] = @(h);
}

#pragma mark - memmem

static void byg_memmem_all(const uint8_t *buf, size_t len, const uint8_t *needle, size_t nlen,
                           size_t *offs, size_t *count, size_t cap) {
    *count = 0;
    if (!buf || !needle || nlen == 0 || len < nlen)
        return;
    // 单字节加速：先找 needle[0]
    uint8_t first = needle[0];
    for (size_t i = 0; i + nlen <= len; i++) {
        if (buf[i] != first)
            continue;
        if (nlen == 1 || memcmp(buf + i, needle, nlen) == 0) {
            if (*count < cap)
                offs[(*count)++] = i;
            if (*count >= cap)
                return;
            i += nlen - 1;
        }
    }
}

#pragma mark - Harvest on buffer

static void byg_harvest_hot(const uint8_t *buf, size_t len, NSMutableDictionary *found,
                            int *marks_left) {
    static const char *pats[] = {"1.0X", "1.5X", "2.0X", "0.5X", "m3u8", ".m3u8"};
    static const size_t plen[] = {4, 4, 4, 4, 4, 5};
    size_t offs[48];

    for (size_t pi = 0; pi < 6 && *marks_left > 0; pi++) {
        size_t n = 0;
        byg_memmem_all(buf, len, (const uint8_t *)pats[pi], plen[pi], offs, &n, 48);
        for (size_t j = 0; j < n && *marks_left > 0; j++) {
            (*marks_left)--;
            size_t mark = offs[j];
            ssize_t start = (ssize_t)mark - 600;
            if (start < 0)
                start = 0;
            start &= ~1;
            ssize_t end = (ssize_t)mark + 900;
            if (end > (ssize_t)len)
                end = (ssize_t)len;

            for (ssize_t off = start; off + 1 < end; off += 2) {
                uint16_t cu = byg_u16(buf + off);
                if (cu < 0x4e00 || cu > 0x9fff)
                    continue;
                if (off > start) {
                    uint16_t pv = byg_u16(buf + off - 2);
                    if (byg_is_title_unit(pv))
                        continue;
                }
                NSString *t = byg_read_utf16_title(buf, len, (size_t)off);
                if (t)
                    byg_add(found, t, 1);
            }
        }
    }
}

static void byg_harvest_seps(const uint8_t *buf, size_t len, NSMutableDictionary *found,
                             int *used_left) {
    static const uint8_t seps[][2] = {
        {0x20, 0x00}, {0x00, 0x30}, {0x0c, 0xff}, {0x2c, 0x00},
    };
    size_t offs[400];
    for (size_t si = 0; si < 4 && *used_left > 0; si++) {
        size_t n = 0;
        byg_memmem_all(buf, len, seps[si], 2, offs, &n, 400);
        for (size_t j = 0; j < n && *used_left > 0; j++) {
            size_t a = offs[j];
            if (a < 2)
                continue;
            uint16_t before = byg_u16(buf + a - 2);
            if (before < 0x4e00 || before > 0x9fff)
                continue;
            (*used_left)--;
            size_t start = a;
            for (int b = 1; b <= 55; b++) {
                if (a < (size_t)b * 2)
                    break;
                size_t po = a - (size_t)b * 2;
                uint16_t cu = byg_u16(buf + po);
                if (cu == 0 || !byg_is_title_unit(cu))
                    break;
                start = po;
            }
            if (byg_u16(buf + start) < 0x4e00)
                continue;
            NSString *t = byg_read_utf16_title(buf, len, start);
            if (t)
                byg_add(found, t, 0);
        }
    }
}

static void byg_harvest_needles(const uint8_t *buf, size_t len, NSMutableDictionary *found,
                                NSArray<NSData *> *needles, int *hits_left) {
    size_t offs[32];
    for (NSData *nd in needles) {
        if (*hits_left <= 0)
            return;
        if (nd.length < 2)
            continue;
        size_t n = 0;
        byg_memmem_all(buf, len, (const uint8_t *)nd.bytes, nd.length, offs, &n, 32);
        for (size_t j = 0; j < n && *hits_left > 0; j++) {
            (*hits_left)--;
            size_t a = offs[j];
            size_t start = a;
            for (int b = 1; b <= 55; b++) {
                if (a < (size_t)b * 2)
                    break;
                size_t po = a - (size_t)b * 2;
                uint16_t cu = byg_u16(buf + po);
                if (cu == 0 || !byg_is_title_unit(cu))
                    break;
                start = po;
            }
            NSString *t = byg_read_utf16_title(buf, len, start);
            if (t)
                byg_add(found, t, 0);
        }
    }
}

static NSArray<NSData *> *byg_needles(void) {
    static NSArray<NSData *> *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSArray *words = @[
          @"束缚",   @"调教",   @"双马尾", @"新人", @"首作",   @"女仆", @"学姐", @"萝莉",
          @"人妻",   @"内射",   @"COS",   @"cos", @"玩具",   @"试用", @"任务", @"物资",
          @"精液",   @"肉棒",   @"骚穴",   @"肉穴", @"淫荡",   @"体验", @"中出", @"按摩",
          @"时间停止", @"达妮娅", @"NTR",   @"角色扮演", @"充电", @"布兰", @"菲比",
          @"李慕婉", @"花火",   @"公孙离", @"警官", @"灌肠",   @"裸贷", @"学姐", @"颜值",
          @"换不",   @"还贷",   @"同框",
      ];
      NSMutableArray *arr = [NSMutableArray array];
      for (NSString *s in words) {
          NSMutableData *d = [[s dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
          if (d.length >= 2) {
              const uint8_t *b = d.bytes;
              if ((b[0] == 0xff && b[1] == 0xfe) || (b[0] == 0xfe && b[1] == 0xff))
                  [d replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];
          }
          if (d.length >= 2)
              [arr addObject:d];
      }
      cached = [arr copy];
    });
    return cached;
}

#pragma mark - count / fragment

static NSData *byg_u16le_data(NSString *s) {
    NSMutableData *d = [[s dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
    if (d.length >= 2) {
        const uint8_t *b = d.bytes;
        if ((b[0] == 0xff && b[1] == 0xfe) || (b[0] == 0xfe && b[1] == 0xff))
            [d replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];
    }
    return d;
}

static int byg_count_exact_copy(NSString *text, byg_region_t *regions, size_t nreg, uint8_t *buf,
                                size_t bufcap, CFAbsoluteTime deadline) {
    NSData *full = byg_u16le_data(text);
    if (full.length < 8)
        return 0;
    NSUInteger npre = MIN((NSUInteger)8, text.length);
    NSData *pre = byg_u16le_data([text substringToIndex:npre]);
    if (pre.length < 4)
        return 0;

    int cnt = 0;
    size_t fullN = full.length;
    size_t maxPerReg = 6ull * 1024 * 1024;
    const size_t STEP = 512 * 1024;

    for (size_t ri = 0; ri < nreg && cnt < 20; ri++) {
        if (CFAbsoluteTimeGetCurrent() > deadline)
            break;
        vm_address_t base = regions[ri].addr;
        size_t sz = (size_t)regions[ri].size;
        if (sz > maxPerReg)
            sz = maxPerReg;

        for (size_t off = 0; off < sz && cnt < 20;) {
            if (CFAbsoluteTimeGetCurrent() > deadline)
                break;
            size_t want = sz - off;
            if (want > STEP)
                want = STEP;
            if (want > bufcap)
                want = bufcap;
            vm_size_t got = 0;
            if (!byg_copy_pages(base + off, (vm_size_t)want, buf, &got) || got < pre.length) {
                off += want ? want : 0x1000;
                continue;
            }
            size_t offs[48];
            size_t nh = 0;
            byg_memmem_all(buf, (size_t)got, (const uint8_t *)pre.bytes, pre.length, offs, &nh, 48);
            for (size_t j = 0; j < nh && cnt < 20; j++) {
                size_t at = offs[j];
                if (at + fullN > (size_t)got)
                    continue;
                if (memcmp(buf + at, full.bytes, fullN) != 0)
                    continue;
                if (at + fullN + 1 < (size_t)got) {
                    uint16_t next = byg_u16(buf + at + fullN);
                    if (byg_is_title_unit(next))
                        continue;
                }
                cnt++;
            }
            size_t step = (size_t)got > 256 ? (size_t)got - 256 : (size_t)got;
            if (step == 0)
                step = 0x1000;
            off += step;
        }
    }
    return cnt;
}

static BOOL byg_is_fragment(NSString *a, NSString *b) {
    if (!a.length || !b.length || [a isEqualToString:b] || a.length >= b.length)
        return NO;
    if ([b containsString:a])
        return YES;
    NSCharacterSet *st =
        [NSCharacterSet characterSetWithCharactersInString:@" \t,，.。…-|【】[]"];
    NSString *na = [[a componentsSeparatedByCharactersInSet:st] componentsJoinedByString:@""];
    NSString *nb = [[b componentsSeparatedByCharactersInSet:st] componentsJoinedByString:@""];
    return na.length >= 8 && [nb containsString:na];
}

#pragma mark - Scan one region (safe copy)

static void byg_scan_region_copy(byg_region_t reg, uint8_t *buf, size_t bufcap,
                                 NSMutableDictionary *found, int *hot_left, int *sep_left,
                                 int *needle_left, NSArray *needles, BOOL do_sep,
                                 CFAbsoluteTime deadline) {
    size_t total = (size_t)reg.size;
    if (total > 12ull * 1024 * 1024)
        total = 12ull * 1024 * 1024;

    const size_t OVERLAP = 512;
    vm_address_t base = reg.addr;

    for (size_t off = 0; off < total;) {
        if (CFAbsoluteTimeGetCurrent() > deadline)
            return;
        size_t want = total - off;
        if (want > bufcap)
            want = bufcap;
        vm_size_t got = 0;
        if (!byg_copy_pages(base + off, (vm_size_t)want, buf, &got) || got < 4) {
            // 整块失败：按页跳过
            off += 0x1000;
            continue;
        }

        byg_harvest_hot(buf, (size_t)got, found, hot_left);
        byg_harvest_needles(buf, (size_t)got, found, needles, needle_left);
        if (do_sep)
            byg_harvest_seps(buf, (size_t)got, found, sep_left);

        size_t step = (size_t)got > OVERLAP ? (size_t)got - OVERLAP : (size_t)got;
        if (step == 0)
            step = 0x1000;
        off += step;
    }
}

#pragma mark - Core scan

static int byg_scan_current_title_utf8(char **out_utf8, uint32_t timeout_ms) {
    if (!out_utf8)
        return -1;
    *out_utf8 = NULL;

    double sec = (timeout_ms > 0) ? (timeout_ms / 1000.0) : 4.0;
    if (sec < 1.5)
        sec = 1.5;
    if (sec > 12.0)
        sec = 12.0;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + sec;

    byg_region_t *regions = NULL;
    size_t nreg = 0;
    byg_enum_rw_regions(&regions, &nreg);
    if (!regions || nreg == 0) {
        byg_set_dbg(-3, 0, 0, 0, 0);
        return -3;
    }

    const size_t BUFCAP = 512 * 1024; // 512KB 块，快且稳
    uint8_t *buf = (uint8_t *)malloc(BUFCAP);
    if (!buf) {
        free(regions);
        byg_set_dbg(-4, nreg, 0, 0, 0);
        return -4;
    }

    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    int hot_left = 60;
    int sep_left = 400;
    int needle_left = 200;
    NSArray *needles = byg_needles();

    size_t max_reg = nreg > 60 ? 60 : nreg;

    // Pass1: 热区 + 针点（不做 sep，避免 0x20 00 拖死）
    for (size_t i = 0; i < max_reg; i++) {
        if (CFAbsoluteTimeGetCurrent() > deadline)
            break;
        byg_scan_region_copy(regions[i], buf, BUFCAP, found, &hot_left, &sep_left, &needle_left,
                             needles, NO, deadline);
    }

    // 有 hot>0 的候选则不必 sep；否则 Pass2 轻量 sep（前 20 大区）
    BOOL anyHot = NO;
    for (NSString *k in found) {
        if ([found[k] intValue] > 0) {
            anyHot = YES;
            break;
        }
    }
    if (!anyHot && found.count < 3) {
        size_t lim = max_reg > 20 ? 20 : max_reg;
        for (size_t i = 0; i < lim; i++) {
            if (CFAbsoluteTimeGetCurrent() > deadline)
                break;
            byg_scan_region_copy(regions[i], buf, BUFCAP, found, &hot_left, &sep_left, &needle_left,
                                 needles, YES, deadline);
        }
    }

    size_t ncand = found.count;
    size_t nhot = 0;
    for (NSString *k in found) {
        if ([found[k] intValue] > 0)
            nhot++;
    }

    if (ncand == 0) {
        free(buf);
        free(regions);
        byg_set_dbg(-5, nreg, 0, 0, 0);
        return -5;
    }

    // 候选过多时：优先保留 hot>0，再截断
    NSArray *keys = found.allKeys;
    if (keys.count > 40) {
        NSArray *sortedKeys = [keys sortedArrayUsingComparator:^NSComparisonResult(NSString *a,
                                                                                   NSString *b) {
          int ha = [found[a] intValue], hb = [found[b] intValue];
          if (hb != ha)
              return hb > ha ? NSOrderedAscending : NSOrderedDescending;
          return a.length < b.length ? NSOrderedDescending : NSOrderedAscending;
        }];
        NSMutableDictionary *trim = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < 40 && i < sortedKeys.count; i++) {
            NSString *k = sortedKeys[i];
            trim[k] = found[k];
        }
        found = trim;
    }

    NSMutableArray *items = [NSMutableArray array];
    for (NSString *t in found) {
        if (CFAbsoluteTimeGetCurrent() > deadline)
            break;
        int hot = [found[t] intValue];
        int c = byg_count_exact_copy(t, regions, max_reg, buf, BUFCAP, deadline);
        if (c < 1)
            c = 1;
        [items addObject:@{@"text" : t, @"hot" : @(hot), @"count" : @(c), @"len" : @(t.length)}];
    }
    free(buf);
    free(regions);
    regions = NULL;

    // 去残片
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSUInteger i = 0; i < items.count; i++) {
        NSString *ti = items[i][@"text"];
        BOOL frag = NO;
        for (NSUInteger j = 0; j < items.count; j++) {
            if (i == j)
                continue;
            if (byg_is_fragment(ti, items[j][@"text"])) {
                frag = YES;
                break;
            }
        }
        if (!frag)
            [filtered addObject:items[i]];
    }

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

    if (!filtered.count) {
        byg_set_dbg(-5, nreg, ncand, nhot, 0);
        return -5;
    }

    NSString *best = filtered[0][@"text"];
    const char *u8 = [best UTF8String];
    if (!u8) {
        byg_set_dbg(-6, nreg, ncand, nhot, filtered.count);
        return -6;
    }
    *out_utf8 = byg_strdup(u8);
    byg_set_dbg(*out_utf8 ? 0 : -6, nreg, ncand, nhot, filtered.count);
    return *out_utf8 ? 0 : -6;
}

#pragma mark - Public API

char *byg_copy_current_video_title(void) {
    return byg_copy_current_video_title_timeout(4000);
}

char *byg_copy_current_video_title_timeout(uint32_t timeout_ms) {
    char *result = NULL;
    @autoreleasepool {
        // 失败时不返回旧缓存标题（避免误报「堆扫成功」）；缓存仅供 last_cached 查询
        int rc = byg_scan_current_title_utf8(&result, timeout_ms);
        if (rc == 0 && result) {
            pthread_mutex_lock(&g_lock);
            byg_set_cache_unlocked(result);
            pthread_mutex_unlock(&g_lock);
            return result;
        }
        if (result) {
            free(result);
            result = NULL;
        }
        return NULL;
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

const char *byg_last_scan_debug(void) {
    return g_dbg;
}
