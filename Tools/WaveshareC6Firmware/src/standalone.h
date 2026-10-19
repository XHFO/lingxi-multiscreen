#pragma once
#include "esp_http_server.h"
#include <stdbool.h>
#include <stdint.h>
#include "firmware_profile.h"
#if C6_FORMLABS_ONLY
// The dedicated profile rejects HA entities; retain one slot for shared APIs,
// not six unused configuration/state/media cache slots.
#define C6_MAX_ENTITIES 1
#else
#define C6_MAX_ENTITIES 6
#endif
#define C6_MAX_PRINTERS 3
#define C6_CONFIG_BYTES 12288
typedef struct { char id[128], name[64]; } c6_entity_config_t;
typedef struct {
    bool enabled,dark;
    uint32_t background,card,inset,border,accent,secondary_accent,primary_text,secondary_text,tertiary_text;
} c6_theme_config_t;
typedef struct {
    char host[16], serial[40], name[64], access_code[32], certificate[2048];
    bool enabled, trust_lan, rotate;
    bool source_ha;
    bool source_formlabs,show_layers,show_material;
    char form_client_id[128],form_client_secret[256];
    bool show_status,show_progress,show_task,show_remaining,show_image;
    bool show_nozzle,show_bed,show_error;
    bool brand_accent;
    int time_mode;
    int card_style; // Per-printer: 0 standard, 1 hero percentage, 2 hero remaining time.
    char status_entity[128],progress_entity[128],task_entity[128],remaining_entity[128],image_entity[128];
    char nozzle_entity[128],bed_entity[128],error_entity[128],end_time_entity[128];
    bool live_image;
    char task_cover_entity[128];
} c6_printer_config_t;
static inline bool c6_printer_images_enabled(const c6_printer_config_t *p){
    return p->show_image&&p->card_style==0;
}
static inline const char *c6_printer_brand(const c6_printer_config_t *p){return p->source_formlabs?"formlabs":"bambu";}
static inline const char *c6_printer_source(const c6_printer_config_t *p){return p->source_formlabs?"formlabs":p->source_ha?"ha":"mqtt";}
typedef struct {
    int revision, rotation, brightness, interval, timezone, saturation_percent, contrast_percent, card_mask;
    bool enabled, clock, diagnostics, flip_animation;
    int clock_style; // 0: legacy flip clock, 1: rounded geometric numerals.
    bool local_first, ha_enabled;
    c6_theme_config_t theme;
    char ha_host[16], ha_token[1024];
    int ha_port;
    bool ha_tls;
    unsigned entity_count, printer_count;
    c6_entity_config_t entities[C6_MAX_ENTITIES];
    c6_printer_config_t printers[C6_MAX_PRINTERS];
    bool weather;
    double latitude,longitude;
    char weather_city[64];
    int weather_minutes;
    int language; // 0: Simplified Chinese, 1: English. Absent legacy field = Chinese.
    int digit_style; // 0: existing pixel numerals, 1: smooth aerospace numerals.
    int sleep_mode,sleep_idle_minutes,sleep_start,sleep_end;
    bool sleep_keep_printing;
} standalone_config_t;
static inline unsigned c6_enabled_printer_count(const standalone_config_t *c){unsigned count=0;for(unsigned i=0;i<c->printer_count&&i<C6_MAX_PRINTERS;i++)count+=c->printers[i].enabled;return count;}
static inline unsigned c6_overview_printer_count(const standalone_config_t *c){return C6_FORMLABS_ONLY?c->printer_count:c6_enabled_printer_count(c);}
extern standalone_config_t standalone_config;
extern char standalone_token[17];
extern const char *standalone_restore_status;
extern const char *standalone_save_status;
static inline bool standalone_profile_valid(const standalone_config_t *c){
#if C6_FORMLABS_ONLY
    if(!c->enabled||!c->local_first||c->diagnostics||c->ha_enabled||c->entity_count||*c->ha_host||*c->ha_token||(c->card_mask&~5))return false;
    if(c->printer_count>C6_MAX_PRINTERS)return false;
    for(unsigned i=0;i<c->printer_count;i++)if(!c->printers[i].source_formlabs||c->printers[i].source_ha)return false;
#else
    (void)c;
#endif
    return true;
}
void standalone_init(void);
void standalone_register(httpd_handle_t server);
void standalone_apply(void);
bool standalone_authorized(httpd_req_t *req);
// Called on the HTTP server task, like local display work and API handlers.
// The PIN is ephemeral; the internal bearer credential remains unchanged.
void standalone_pairing_open(void);
void standalone_pairing_close(void);
bool standalone_set_flip(bool enabled);
bool standalone_save_display(int expected_revision,int rotation,bool flip,int card_mask,unsigned printer_mask);
bool standalone_save_display_language(int expected_revision,int rotation,bool flip,int card_mask,unsigned printer_mask,int language);
bool standalone_save_monitor_display(int expected_revision,int rotation,bool flip,int card_mask,unsigned printer_mask,int language,int sleep_mode);
bool standalone_lan_pairing_allowed(httpd_req_t *req);
bool standalone_pairing_pin(char pin[5],int *remaining_seconds);
int standalone_pairing_brightness(int requested,bool visible);
