/*
 * EZPcMonitor 采集内核的 C ABI。
 *
 * 宿主（SwiftUI）只需要这一个头文件。所有数据都以 JSON 传递，
 * 形状跟 `src-tauri` 时代发给 WebView 的完全一致——历史文件本来就是 JSONL，
 * 没必要为了跨语言再造一套结构体。
 *
 * 调用约定：
 *   1. ezpcm_engine_new 建引擎，内部起采集线程；
 *   2. ezpcm_call 拿数据，返回的字符串必须用 ezpcm_string_free 释放；
 *   3. 退出前 ezpcm_engine_free。
 *
 * 线程：引擎内部有锁，可以从任意线程调 ezpcm_call。
 *      new/free 不并发调用即可。
 */

#ifndef EZPCM_CORE_H
#define EZPCM_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EzpcmEngine EzpcmEngine;

/*
 * data_dir   —— 历史数据目录（history.jsonl、procs/），不存在会自动建
 * config_dir —— 偏好目录（settings.json）
 * bundled_smartctl —— 应用包内 smartctl 的绝对路径，可传 NULL
 *
 * 返回 NULL 表示分配失败（实际不会发生）。
 */
EzpcmEngine *ezpcm_engine_new(const char *data_dir,
                              const char *config_dir,
                              const char *bundled_smartctl);

void ezpcm_engine_free(EzpcmEngine *engine);

/*
 * 唯一的数据入口。返回 UTF-8 JSON；失败也返回 JSON（形如 {"error": "..."}）。
 * args 可以是 NULL，等价于 {}。
 *
 * 支持的方法：
 *   "snapshot"      → {"seq": N, "snapshot": {...}}      最新一拍
 *   "recent"        → [HistoryPoint]                     内存里最近 300 点
 *   "history"       → [Point]          args {"from": ts} 落盘历史
 *   "leaders"       → Leaders          args {"from": ts} 高占用程序榜
 *   "stats"         → HistoryStats                       历史占用现状
 *   "settings"      → Settings
 *   "patch"         → Settings         args 同 SettingsPatch（字段全可选）
 *   "locale"        → "zh-CN"
 *   "seq"           → 42                                 只取序号，最省
 *   "wantProcs"     → {}               args {"on": true}
 *   "clearHistory"  → {}
 *   "health"        → [DiskHealth]     args {"force": false}
 *   "bench"         → BenchResult      args {"mount": "/", "sizeMb": 512}
 *   "version"       → "0.1.0"
 */
char *ezpcm_call(EzpcmEngine *engine, const char *method, const char *args);

/* 释放 ezpcm_call 的返回值。传 NULL 是安全的。 */
void ezpcm_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* EZPCM_CORE_H */
