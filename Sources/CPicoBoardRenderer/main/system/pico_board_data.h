/*
 * SPDX-License-Identifier: Apache-2.0
 * 中文：灵犀画板有界语义快照；网络只交付数据，横竖排版由设备决定。
 * English: Bounded semantic board snapshots; the device owns layout in every orientation.
 * 冻结：不接受绘图指令、路径、脚本或凭据；解析失败不改变当前画面。
 * Frozen: No drawing commands, paths, scripts or credentials; failed parsing never changes the active frame.
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PS_BOARD_DATA_MAX 65536u
#define PS_BOARD_MODULE_MAX 12u
#define PS_BOARD_ASSET_MAX 8u
#define PS_BOARD_ASSET_BYTES_MAX 32768u
#define PS_BOARD_ASSET_SIDE_MAX 192u
#define PS_BOARD_WORLD_MAP_MAX 8192u

typedef enum {
    PS_BOARD_CLOCK, PS_BOARD_DATE, PS_BOARD_CPU, PS_BOARD_MEMORY,
    PS_BOARD_NETWORK, PS_BOARD_NOW_PLAYING, PS_BOARD_POMODORO, PS_BOARD_UPTIME,
    PS_BOARD_TEXT, PS_BOARD_IMAGE, PS_BOARD_QWEN_QUOTA, PS_BOARD_CODEX,
    PS_BOARD_ORACLE_TEXT, PS_BOARD_SSPAI, PS_BOARD_DISK, PS_BOARD_HOME_ASSISTANT,
    PS_BOARD_BAMBU_LAB, PS_BOARD_FORMLABS, PS_BOARD_WEATHER,
    PS_BOARD_READING_EXCERPT, PS_BOARD_CLOUDFLARE, PS_BOARD_GROK_BOT,
    PS_BOARD_KIND_COUNT
} ps_board_kind_t;

typedef struct { const char *label, *value, *unit; } ps_board_metric_t;
typedef struct { const char *label, *value; } ps_board_row_t;
typedef struct { const char *code; double value; } ps_board_region_t;
typedef struct {
    const char *id;
    uint16_t width, height;
    const uint8_t *pixels;
} ps_board_asset_t;
typedef struct {
    ps_board_kind_t kind;
    const char *id, *title, *subtitle, *body, *footer;
    ps_board_metric_t metrics[8];
    ps_board_row_t rows[24];
    float series[60];
    uint8_t metric_count, row_count, series_count;
    int8_t asset_index;
    double timestamp, duration, progress;
    bool has_progress, running;
    uint8_t span;
    bool media_vertical, region_ranking, rank_traffic;
    uint16_t region_count;
    ps_board_region_t *regions;
} ps_board_module_t;

/// 模型拥有所有字符串和素材，不引用请求缓冲区。/ The model owns strings/assets independently of the request buffer.
typedef struct ps_board_model {
    const char *board_id;
    ps_board_module_t modules[PS_BOARD_MODULE_MAX];
    ps_board_asset_t assets[PS_BOARD_ASSET_MAX];
    uint8_t module_count, asset_count, columns, text_scale;
    bool dark;
    int16_t utc_offset_minutes;
    double generated_at;
    uint64_t semantic_hash;
    int64_t adopted_ms, paint_bucket;
    double display_time;
    size_t allocation_bytes;
    uint8_t *world_map;
    size_t world_map_bytes;
    char arena[];
} ps_board_model_t;

/// 严格解析；失败返回NULL且不产生I/O。/ Strict parsing; NULL on failure, with no I/O.
ps_board_model_t *ps_board_model_parse(const void *data, size_t bytes);
/// 可选固定错误码，不回显内容；线程间不共享错误状态。/ Optional fixed error code, never content; no shared error state.
ps_board_model_t *ps_board_model_parse_ex(const void *data, size_t bytes, const char **error);
void ps_board_model_free(ps_board_model_t *model);
/// 只按可见的时间变化请求重画，不进行显示、网络或文件操作。/ Request a repaint for visible time changes only; no display, network or file operations.
bool ps_board_model_tick(ps_board_model_t *model, int64_t monotonic_ms);
/// 用可注入墙钟测试；负数表示RTC尚不可用。/ Injectable wall-clock tick; negative means RTC unavailable.
bool ps_board_model_tick_at(ps_board_model_t *model, int64_t monotonic_ms, double utc_seconds);
/// 缓存时区，纯绘制不读取设置；返回是否改变。/ Cache timezone so painting never reads settings; return whether it changed.
bool ps_board_model_set_timezone(ps_board_model_t *model, int minutes);
/// 固定格式底图随语义快照持久保存，不编入APP，也不是界面位图。/ Fixed-format basemap data persists with the semantic snapshot; it is neither APP data nor a rendered UI bitmap.
bool ps_board_model_needs_world_map(const ps_board_model_t *model);
/// 解析时验证并复制；失败保留旧资源。纯绘制不读取TF。/ Validate and copy while parsing; failure retains old resources. Painting never reads TF.
bool ps_board_model_set_world_map(ps_board_model_t *model, const void *data, size_t bytes);
/// 纯绘制当前快照；不分配、联网、读盘或导航。/ Paint the snapshot without allocating, networking, reading files or navigating.
void ps_board_model_render(uint8_t *fb, const ps_board_model_t *model);
/// 同一原生排版可用于电脑预览；仅绘图后端不同。/ Native layout is shared with desktop previews; only drawing backends differ.
typedef struct {
    void *context;
    int width, height;
    void (*fill)(void *, int x, int y, int w, int h, int gray);
    void (*line)(void *, int x0, int y0, int x1, int y1, int gray);
    void (*text)(void *, int x, int y, int size, const char *, int gray);
    int (*measure)(void *, int size, const char *);
    void (*image)(void *, const ps_board_asset_t *, int x, int y, int w, int h);
} ps_board_painter_t;
void ps_board_model_paint(const ps_board_model_t *model, const ps_board_painter_t *painter);
/// 协议kind名称列表与索引。/ Protocol kind names and index.
const char *ps_board_kind_name(ps_board_kind_t kind);
