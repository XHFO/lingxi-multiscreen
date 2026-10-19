#pragma once
#include "standalone.h"
#include "cJSON.h"
#include <stdint.h>
typedef struct { char name[64], state[128], unit[32]; bool available; uint64_t updated; } c6_entity_state_t;
typedef struct {
    char task[128], status[40], job[80], thumbnail_key[17];
    char nozzle[32],bed[32],error[128];
    char material[96];
    int layer,layer_count;
    int progress, remaining;
    bool progress_valid,remaining_valid;
    unsigned thumbnail_key_rank;
    bool connected, known;
    uint64_t updated, completed_at;
    uint64_t end_epoch;
    uint64_t remaining_updated;
} c6_printer_state_t;
bool c6_private_ip(const char *text);
bool c6_print_active(const char *status);
bool c6_print_finished(const char *status);
void c6_print_update(c6_printer_state_t *state, cJSON *payload, uint64_t now);
// Identical FNV-1a UTF-8 contract to C6TaskThumbnail in the Mac core.
void c6_task_key(const char *source,const char *value,char out[17]);
void c6_mqtt_task_key(cJSON *payload,char out[17]);
uint64_t c6_parse_end_epoch(const char *text);
bool c6_print_eligible(const c6_printer_state_t *state, uint64_t now);
bool c6_software_wins(bool enabled, bool local_first, bool local_available, uint64_t heartbeat, uint64_t now);
