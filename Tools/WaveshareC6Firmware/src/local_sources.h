#pragma once
#include "local_state.h"
#include "thumbnail_cache.h"
typedef struct {
    double latitude,longitude,temperature,apparent,low,high;
    int code,rain;
    uint64_t epoch;
    bool valid;
#if C6_FORMLABS_ONLY
    int humidity;
    double wind;
    bool humidity_valid,wind_valid;
#endif
} c6_weather_state_t;
typedef struct {
    c6_entity_state_t entities[C6_MAX_ENTITIES];
    c6_printer_state_t printers[C6_MAX_PRINTERS];
    bool ha_connected;
    // 0 disabled, 1 waiting Wi-Fi, 2 connecting, 3 authorizing, 4 subscribing,
    // 5 connected, 6 retrying, 7 authorization rejected, 8 subscription rejected, 9 low memory.
    unsigned ha_phase;
    uint32_t ha_reconnects, mqtt_reconnects, dropped_messages, generation;
    c6_weather_state_t weather;
    // 0 disabled, 1 waiting Wi-Fi, 2 waiting memory, 3 fetching, 4 cached, 5 retrying.
    unsigned weather_phase;
    // 0 waiting, 1 cached, 2 unsupported format, 3 oversized, 4 fetch/decode error.
    unsigned thumbnail_status[C6_MAX_PRINTERS];
    uint32_t thumbnail_revision[C6_MAX_PRINTERS];
    // 0 waiting, 1 connected, 2 retrying, 3 credentials rejected, 4 low memory, 5 fixed demo.
    unsigned form_phase[C6_MAX_PRINTERS];
    unsigned media_status[C6_MAX_ENTITIES+C6_MAX_PRINTERS];
    uint32_t media_revision[C6_MAX_ENTITIES+C6_MAX_PRINTERS];
} c6_source_snapshot_t;
void c6_sources_init(void);
void c6_sources_reconfigure(void);
void c6_sources_snapshot(c6_source_snapshot_t *out);
// Leaves the last good snapshot untouched on contention.
bool c6_sources_try_snapshot(c6_source_snapshot_t *out);
bool c6_sources_weather_available(void);
void c6_register_updates(httpd_handle_t server);
uint64_t c6_seconds(void);
bool c6_sources_weather_refresh(void);
void c6_sources_display_options(int revision,bool flip_animation);
typedef void (*c6_thumbnail_visitor_t)(const uint8_t *rgb565,unsigned width,unsigned height,unsigned stride,void *context);
bool c6_sources_thumbnail_visit(const char *serial,const char *task_key,c6_thumbnail_visitor_t visitor,void *context);
int c6_sources_thumbnail_validate(int revision,const char *serial,const char *task_key);
int c6_sources_thumbnail_validate_scoped(int revision,const char *serial,const char *brand,const char *source,const char *key);
int c6_sources_thumbnail_store_scoped(int revision,const char *serial,const char *brand,const char *source,const char *key,unsigned w,unsigned h,uint8_t *bytes,size_t length);
// Takes ownership on 200 only; rejects changed configuration, task, or disabled printer.
int c6_sources_thumbnail_store(int revision,const char *serial,const char *task_key,unsigned width,unsigned height,uint8_t *bytes,size_t length);
esp_err_t c6_thumbnail_handler(httpd_req_t *req);
typedef void (*c6_media_visitor_t)(const c6_thumbnail_cache_t *const *pictures,unsigned count,void *context);
void c6_sources_entity_pictures_visit(unsigned first,unsigned count,c6_media_visitor_t visitor,void *context);
void c6_sources_printer_pictures_visit(const char *serial,const char *key,c6_media_visitor_t visitor,void *context);
void c6_sources_printer_pictures_visit_scoped(const char *serial,const char *brand,const char *source,const char *key,c6_media_visitor_t visitor,void *context);
int c6_sources_media_validate_scoped(int revision,const char *serial,const char *brand,const char *source,const char *entity,const char *key,bool cover);
int c6_sources_media_store_scoped(int revision,const char *serial,const char *brand,const char *source,const char *entity,const char *key,bool cover,unsigned w,unsigned h,uint8_t *bytes,size_t length);
// A shared pool of at most four 80px frames, prioritizing the currently visible page.
void c6_sources_media_focus(int entity_group,int printer);
int c6_sources_media_validate(int revision,const char *serial,const char *entity,const char *key,bool cover);
int c6_sources_media_store(int revision,const char *serial,const char *entity,const char *key,bool cover,unsigned w,unsigned h,uint8_t *bytes,size_t length);
