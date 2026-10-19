#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { C6_RENDER_WIDTH=240,C6_RENDER_HEIGHT=240,C6_RENDER_BYTES=115200,C6_AA_CACHE_BYTES=6144 };
typedef struct {
    uint8_t *frame;
    size_t capacity;
    uint16_t cached_group;
    uint8_t cached_font;
    uint8_t glyph_cache[C6_AA_CACHE_BYTES];
    bool english;
    bool smooth_digits; // Dedicated monitor: hero numerals only, never captions.
} c6_renderer_t;
typedef struct {const uint8_t *rgb565;unsigned width,height,stride;} c6_render_picture_t;
typedef struct { const char *name,*state,*unit; bool available; bool media; c6_render_picture_t picture; } c6_render_entity_t;
// Portable RGB24 tokens copied from ScreenPalette, not a second device theme.
// An absent/disabled style keeps the original deepSpace defaults for older configs.
typedef struct {
    uint32_t background,card,inset,border,accent,secondary_accent;
    uint32_t primary_text,secondary_text,tertiary_text;
    bool enabled;
} c6_render_style_t;
typedef struct {
    const char *city;
    double temperature,apparent,low,high;
    int code,rain,updated_hour,updated_minute;
    bool valid,stale;
#if C6_FORMLABS_ONLY
    int humidity;
    double wind;
    bool humidity_valid,wind_valid;
#endif
} c6_render_weather_t;
typedef struct {
    const char *name,*task,*status;
    int progress,remaining;
    bool connected,completed,show_task,show_progress,show_status,show_remaining;
    const uint8_t *thumbnail_rgb565;
    unsigned thumbnail_width,thumbnail_height,thumbnail_stride;
    c6_render_style_t style;
    // NULL time_text uses the legacy minute value. An empty string means that
    // the selected time entity isn't available and must not reserve a row.
    const char *nozzle,*bed,*error,*time_text,*updated_text,*image_label;
    bool show_temperature,show_error,is_error,show_image;
    c6_render_picture_t camera,cover;
    bool camera_configured,cover_configured,formlabs;
    const char *layers,*material;
    int card_style;
    unsigned remaining_seconds;
    bool remaining_available,progress_available,demo;
} c6_render_printer_t;
// Overview borrows source strings; no thumbnails or per-printer frame copies.
typedef struct {
    const char *name,*status;
    int progress;
    bool enabled,connected,progress_available,demo,formlabs;
} c6_render_printer_summary_t;
void c6_renderer_printer_overview(c6_renderer_t *,const c6_render_printer_summary_t *,unsigned);
void c6_renderer_printer_overview_styled(c6_renderer_t *,const c6_render_printer_summary_t *,unsigned,const c6_render_style_t *);
typedef struct { int year,month,day,weekday,hour,minute,second; } c6_render_clock_t;
bool c6_renderer_init(c6_renderer_t *,uint8_t *frame,size_t capacity);
// Localizes fixed UI strings only, never names or task/material content.
const char *c6_renderer_localized(c6_renderer_t *,const char *);
void c6_renderer_weather(c6_renderer_t *,const c6_render_weather_t *);
void c6_renderer_weather_background(c6_renderer_t *,int weather_code);
void c6_renderer_entities(c6_renderer_t *,const char *title,const c6_render_entity_t *,unsigned count,bool connected);
void c6_renderer_entities_styled(c6_renderer_t *,const char *title,const c6_render_entity_t *,unsigned count,bool connected,const c6_render_style_t *);
c6_render_style_t c6_renderer_default_style(void);
void c6_renderer_printer(c6_renderer_t *,const c6_render_printer_t *);
// progress 0..1000: exact old frame at 0, exact new frame at 1000.
// Only the caller's current framebuffer and 6KB font cache are used.
void c6_renderer_clock(c6_renderer_t *,const c6_render_clock_t *now,const c6_render_clock_t *previous,unsigned progress);
// Optional, original rounded-numeral clock. Shared by software and native firmware.
void c6_renderer_round_clock(c6_renderer_t *,const c6_render_clock_t *,const c6_render_style_t *);
// Formlabs profile: eased perspective fold; incremental only touches y=72…158.
void c6_renderer_clock_smooth(c6_renderer_t *,const c6_render_clock_t *now,const c6_render_clock_t *previous,unsigned progress,bool incremental);
void c6_renderer_message(c6_renderer_t *,const char *title,const char *message);
typedef struct {const char *label,*value;} c6_render_menu_row_t;
void c6_renderer_menu(c6_renderer_t *,const char *title,const c6_render_menu_row_t *,unsigned count,unsigned selected,const char *footer,const c6_render_style_t *);
void c6_renderer_pairing(c6_renderer_t *,const char *pin,int seconds,const c6_render_style_t *);
bool c6_renderer_qr(c6_renderer_t *,const char *url,const char *address,const c6_render_style_t *);
bool c6_renderer_setup_qr(c6_renderer_t *,const char *payload,const char *title,const char *address,const char *footer,const c6_render_style_t *);
void c6_renderer_label(c6_renderer_t *,const char *text,int x,int baseline,unsigned size,int max_width,uint32_t color);
// Calibration is applied once to a newly rendered canonical RGB565 frame.
void c6_renderer_calibrate(c6_renderer_t *,int saturation_percent,int contrast_percent);
const char *c6_renderer_print_status(const char *raw);
int c6_renderer_text_width(const char *,unsigned size);
size_t c6_renderer_font_bytes(void);
#ifdef __cplusplus
}
#endif
