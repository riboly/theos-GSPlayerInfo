//
//  byg_title.h
//  注入 com.box.byg：堆扫描获取当前播放视频完整标题（UTF-16LE）
//  返回值：malloc 的 UTF-8，调用方 free；失败 NULL
//  勿在 +load / constructor 中做全量扫描
//

#ifndef BYG_TITLE_H
#define BYG_TITLE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 扫描并返回当前播放标题（UTF-8）。调用方 free。
char *byg_copy_current_video_title(void);

/// 带超时（毫秒）。0 = 默认 4000ms。
char *byg_copy_current_video_title_timeout(uint32_t timeout_ms);

/// 上次成功结果（内部缓存，勿 free，可能 NULL）
const char *byg_last_video_title_cached(void);

void byg_clear_video_title_cache(void);

/// 最近一次扫描诊断（静态缓冲，勿 free），如 "rc=0 reg=32 cand=5 hot=2"
const char *byg_last_scan_debug(void);

#ifdef __cplusplus
}
#endif

#endif /* BYG_TITLE_H */
