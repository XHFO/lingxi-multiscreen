/*
 * SPDX-License-Identifier: Apache-2.0
 * 中文：验证并复制画板语义数据和内嵌16灰素材；私有JSON分配器不会影响别的线程。
 * English: Validate and copy semantic board data and embedded gray16 assets without changing global JSON allocation hooks.
 * 冻结：失败原子返回；不接触文件、设备、网络或交互应用实例。
 * Frozen: Fail atomically without touching files, hardware, networking or interactive app instances.
 */
#include "pico_board_data.h"
#include "../../components/read_pico_home_link/home_link_json.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef ESP_PLATFORM
#include "esp_heap_caps.h"
#include "psa/crypto.h"
#define BOARD_ALLOC(n) heap_caps_malloc((n), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)
#else
#include "mbedtls/sha256.h"
#define BOARD_ALLOC(n) malloc(n)
#endif
#if defined(ESP_PLATFORM) || defined(PICO_NATIVE_PREVIEW)
#include "pico_datetime.h"
#endif

static bool sha256(const uint8_t *data, size_t bytes, uint8_t digest[32]) {
#ifdef ESP_PLATFORM
    size_t written = 0;
    return psa_crypto_init() == PSA_SUCCESS
        && psa_hash_compute(PSA_ALG_SHA_256, data, bytes, digest, 32, &written) == PSA_SUCCESS && written == 32;
#else
    return !mbedtls_sha256(data, bytes, digest, 0);
#endif
}

static const char *const kinds[] = {
    "clock", "date", "cpu", "memory", "network", "now_playing", "pomodoro", "uptime",
    "text", "image", "qwen_quota", "codex", "oracle_text", "sspai", "disk", "home_assistant",
    "bambu_lab", "formlabs", "weather", "reading_excerpt", "cloudflare", "grok_bot"
};
const char *ps_board_kind_name(ps_board_kind_t kind) {
    return (unsigned)kind < PS_BOARD_KIND_COUNT ? kinds[kind] : "";
}
typedef struct {
    ps_board_model_t *model;
    char *cursor, *end;
    const char *error;
} parser_t;
static bool set_world_map(ps_board_model_t *m, const void *data, size_t bytes, bool *out_of_memory);
static bool fail(parser_t *p, const char *error) { p->error = error; return false; }
static const cJSON *item(const cJSON *object, const char *name) {
    return cJSON_GetObjectItemCaseSensitive(object, name);
}
static void hash_bytes(ps_board_model_t *m, const void *bytes, size_t count) {
    const uint8_t *p = bytes;
    while (count--) m->semantic_hash = (m->semantic_hash ^ *p++) * UINT64_C(1099511628211);
}
static bool utf8(const uint8_t *s, size_t n) {
    for (size_t i = 0; i < n;) {
        unsigned c = s[i++], value, extra;
        if (c < 128) { if (!c) return false; continue; }
        if (c >= 0xc2 && c <= 0xdf) { value = c & 31; extra = 1; }
        else if (c >= 0xe0 && c <= 0xef) { value = c & 15; extra = 2; }
        else if (c >= 0xf0 && c <= 0xf4) { value = c & 7; extra = 3; }
        else return false;
        if (extra > n - i) return false;
        for (unsigned k = 0; k < extra; k++) {
            if ((s[i] & 0xc0) != 0x80) return false;
            value = (value << 6) | (s[i++] & 63);
        }
        if ((extra == 1 && value < 0x80) || (extra == 2 && value < 0x800)
            || (extra == 3 && value < 0x10000) || value > 0x10ffff
            || (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return true;
}
// 中文：先限制深度与NUL，避免JSON库递归超深或字符串截断后再验证。
// English: Bound depth and NUL before the JSON parser can recurse or truncate a decoded string.
static bool preflight(const uint8_t *s, size_t n) {
    if (!utf8(s, n)) return false;
    bool quoted = false;
    unsigned depth = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned c = s[i];
        if (quoted && c == '\\') {
            if (++i >= n) return false;
            if (s[i] == 'u' && i + 4 < n && !memcmp(s + i + 1, "0000", 4)) return false;
            continue;
        }
        if (c == '"') quoted = !quoted;
        if (quoted) { if (c < 32) return false; continue; }
        if (c == '[' || c == '{') { if (++depth > 6) return false; }
        if (c == ']' || c == '}') { if (!depth) return false; depth--; }
    }
    return !depth && !quoted;
}
static bool fields(parser_t *p, const cJSON *object, const char *allowed, unsigned maximum) {
    if (!cJSON_IsObject(object)) return fail(p, "object_required");
    unsigned count = 0;
    for (const cJSON *child = object->child; child; child = child->next) {
        if (++count > maximum || !child->string) return fail(p, "unknown_field");
        bool found = false;
        size_t n = strlen(child->string);
        for (const char *a = allowed; *a;) {
            const char *end = strchr(a, '|');
            size_t len = end ? (size_t)(end - a) : strlen(a);
            if (len == n && !memcmp(a, child->string, n)) { found = true; break; }
            if (!end) break;
            a = end + 1;
        }
        if (!found) return fail(p, "unknown_field");
        for (const cJSON *prior = object->child; prior != child; prior = prior->next)
            if (!strcmp(prior->string, child->string)) return fail(p, "duplicate_field");
    }
    return true;
}
static bool text(parser_t *p, const cJSON *object, const char *name, const char **target,
                 size_t maximum, bool required) {
    const cJSON *v = item(object, name);
    if (!v && !required) { *target = ""; hash_bytes(p->model, "", 1); return true; }
    if (!cJSON_IsString(v) || !v->valuestring) return fail(p, "string_required");
    size_t n = strlen(v->valuestring);
    if (n > maximum || (required && !n) || !utf8((const uint8_t *)v->valuestring, n))
        return fail(p, "string_limit");
    if ((size_t)(p->end - p->cursor) < n + 1) return fail(p, "model_limit");
    memcpy(p->cursor, v->valuestring, n + 1);
    *target = p->cursor;
    p->cursor += n + 1;
    hash_bytes(p->model, *target, n + 1);
    return true;
}
static bool number(parser_t *p, const cJSON *object, const char *name, double *value,
                   double low, double high, bool required, bool integral) {
    const cJSON *v = item(object, name);
    if (!v && !required) { *value = 0; return true; }
    if (!cJSON_IsNumber(v) || !isfinite(v->valuedouble) || v->valuedouble < low
        || v->valuedouble > high || (integral && floor(v->valuedouble) != v->valuedouble))
        return fail(p, "number_range");
    *value = v->valuedouble;
    return true;
}
static bool boolean(parser_t *p, const cJSON *object, const char *name, bool *value) {
    const cJSON *v = item(object, name);
    if (!v) { *value = false; return true; }
    if (!cJSON_IsBool(v)) return fail(p, "boolean_required");
    *value = cJSON_IsTrue(v);
    return true;
}
static bool array(parser_t *p, const cJSON *object, const char *name, const cJSON **out,
                  unsigned maximum, bool required) {
    *out = item(object, name);
    if (!*out && !required) return true;
    if (!cJSON_IsArray(*out)) return fail(p, "array_required");
    unsigned count = 0;
    for (const cJSON *a = (*out)->child; a; a = a->next)
        if (++count > maximum) return fail(p, "array_limit");
    if (!count && required) return fail(p, "empty_array");
    return true;
}
static int base64_char(unsigned c) {
    if (c >= 'A' && c <= 'Z') return (int)c - 'A';
    if (c >= 'a' && c <= 'z') return (int)c - 'a' + 26;
    if (c >= '0' && c <= '9') return (int)c - '0' + 52;
    return c == '+' ? 62 : c == '/' ? 63 : -1;
}
static bool decode(const char *text, uint8_t *out, size_t expected) {
    size_t n = strlen(text), written = 0;
    if (n != ((expected + 2) / 3) * 4) return false;
    for (size_t i = 0; i < n; i += 4) {
        int a = base64_char((unsigned char)text[i]), b = base64_char((unsigned char)text[i + 1]);
        int c = text[i + 2] == '=' ? 0 : base64_char((unsigned char)text[i + 2]);
        int d = text[i + 3] == '=' ? 0 : base64_char((unsigned char)text[i + 3]);
        if (a < 0 || b < 0 || c < 0 || d < 0) return false;
        unsigned count = text[i + 2] == '=' ? 1 : text[i + 3] == '=' ? 2 : 3;
        if (written + count > expected || (count < 3 && i + 4 != n)
            || (count == 1 && (text[i + 3] != '=' || (b & 15))) || (count == 2 && (c & 3))) return false;
        unsigned v = (unsigned)(a << 18 | b << 12 | c << 6 | d);
        out[written++] = (uint8_t)(v >> 16);
        if (count > 1) out[written++] = (uint8_t)(v >> 8);
        if (count > 2) out[written++] = (uint8_t)v;
    }
    return written == expected;
}
static bool assets(parser_t *p, const cJSON *root) {
    const cJSON *list;
    if (!array(p, root, "assets", &list, PS_BOARD_ASSET_MAX, false)) return false;
    size_t total = 0;
    for (const cJSON *a = list ? list->child : NULL; a; a = a->next) {
        ps_board_asset_t *out = &p->model->assets[p->model->asset_count];
        double width, height;
        if (!fields(p, a, "id|width|height|format|data", 5)
            || !text(p, a, "id", &out->id, 64, true)
            || !number(p, a, "width", &width, 1, PS_BOARD_ASSET_SIDE_MAX, true, true)
            || !number(p, a, "height", &height, 1, PS_BOARD_ASSET_SIDE_MAX, true, true)) return false;
        if (strlen(out->id) != 64) return fail(p, "asset_id");
        for (unsigned i = 0; i < 64; i++)
            if (!((out->id[i] >= '0' && out->id[i] <= '9') || (out->id[i] >= 'a' && out->id[i] <= 'f')))
                return fail(p, "asset_id");
        for (unsigned i = 0; i < p->model->asset_count; i++)
            if (!strcmp(out->id, p->model->assets[i].id)) return fail(p, "duplicate_asset");
        const cJSON *format = item(a, "format"), *encoded = item(a, "data");
        if (!cJSON_IsString(format) || strcmp(format->valuestring, "gray4") || !cJSON_IsString(encoded))
            return fail(p, "asset_format");
        out->width = (uint16_t)width; out->height = (uint16_t)height;
        size_t bytes = ((out->width + 1u) / 2u) * out->height;
        total += bytes;
        if (total > PS_BOARD_ASSET_BYTES_MAX || bytes > (size_t)(p->end - p->cursor))
            return fail(p, "asset_limit");
        out->pixels = (const uint8_t *)p->cursor;
        if (!decode(encoded->valuestring, (uint8_t *)p->cursor, bytes)) return fail(p, "asset_base64");
        uint8_t digest[32];
        if (!sha256(out->pixels, bytes, digest)) return fail(p, "asset_hash");
        static const char hex[] = "0123456789abcdef";
        for (unsigned i = 0; i < 32; i++)
            if (out->id[2 * i] != hex[digest[i] >> 4] || out->id[2 * i + 1] != hex[digest[i] & 15])
                return fail(p, "asset_hash");
        hash_bytes(p->model, &out->width, sizeof(out->width));
        hash_bytes(p->model, &out->height, sizeof(out->height));
        hash_bytes(p->model, digest, sizeof(digest));
        p->cursor += bytes;
        p->model->asset_count++;
    }
    return true;
}
static bool module(parser_t *p, const cJSON *object, ps_board_module_t *out) {
    if (!fields(p, object, "kind|id|title|subtitle|body|footer|metrics|rows|series|timestamp|duration|progress|asset|running|span|media_layout|presentation|rank_metric|regions", 19))
        return false;
    const cJSON *kind = item(object, "kind");
    unsigned k = 0;
    if (!cJSON_IsString(kind)) return fail(p, "kind_required");
    while (k < PS_BOARD_KIND_COUNT && strcmp(kind->valuestring, kinds[k])) k++;
    if (k == PS_BOARD_KIND_COUNT) return fail(p, "unsupported_kind");
    out->kind = (ps_board_kind_t)k;
    double span;
    if (!number(p, object, "span", &span, 1, 2, false, true)) return false;
    out->span = item(object, "span") ? (uint8_t)span : 1;
    const cJSON *layout = item(object, "media_layout"), *presentation = item(object, "presentation"), *rank = item(object, "rank_metric");
    if (layout) {
        if (out->kind != PS_BOARD_NOW_PLAYING || !cJSON_IsString(layout)
            || (strcmp(layout->valuestring,"horizontal") && strcmp(layout->valuestring,"vertical"))) return fail(p,"media_layout");
        out->media_vertical = !strcmp(layout->valuestring,"vertical");
    }
    if ((presentation || rank || item(object,"regions")) && out->kind != PS_BOARD_CLOUDFLARE) return fail(p,"region_kind");
    if (presentation) {
        if (!cJSON_IsString(presentation) || (strcmp(presentation->valuestring,"worldMap") && strcmp(presentation->valuestring,"ranking"))) return fail(p,"presentation");
        out->region_ranking = !strcmp(presentation->valuestring,"ranking");
    }
    if (rank) {
        if (!cJSON_IsString(rank) || (strcmp(rank->valuestring,"traffic") && strcmp(rank->valuestring,"requests"))) return fail(p,"rank_metric");
        out->rank_traffic = !strcmp(rank->valuestring,"traffic");
    }
    hash_bytes(p->model, &out->kind, sizeof(out->kind));
    if (!text(p, object, "id", &out->id, 64, true)
        || !text(p, object, "title", &out->title, 192, false)
        || !text(p, object, "subtitle", &out->subtitle, 384, false)
        || !text(p, object, "body", &out->body, 8192, false)
        || !text(p, object, "footer", &out->footer, 384, false)) return false;
    for (unsigned i = 0; i < p->model->module_count; i++)
        if (!strcmp(out->id, p->model->modules[i].id)) return fail(p, "duplicate_module");
    const cJSON *list;
    if (!array(p,object,"regions",&list,250,false)) return false;
    if (list && list->child) {
        unsigned count = (unsigned)cJSON_GetArraySize(list);
        uintptr_t aligned = ((uintptr_t)p->cursor + _Alignof(ps_board_region_t)-1) & ~((uintptr_t)_Alignof(ps_board_region_t)-1);
        size_t bytes = count * sizeof(ps_board_region_t);
        if (aligned > (uintptr_t)p->end || bytes > (size_t)((uintptr_t)p->end-aligned)) return fail(p,"model_limit");
        out->regions = (ps_board_region_t*)aligned;
        p->cursor = (char*)aligned + bytes;
        for (const cJSON *a = list->child; a; a = a->next) {
            ps_board_region_t *region = &out->regions[out->region_count];
            if (!fields(p,a,"code|value",2) || !text(p,a,"code",&region->code,32,true)
                || !number(p,a,"value",&region->value,0,1e30,true,false)) return false;
            for (const unsigned char *c=(const unsigned char*)region->code;*c;c++)
                if (*c<32 || *c>126) return fail(p,"region_code");
            for (unsigned i=0;i<out->region_count;i++)
                if (!strcmp(out->regions[i].code,region->code)) return fail(p,"duplicate_region");
            hash_bytes(p->model,&region->value,sizeof(region->value));
            out->region_count++;
        }
    }
    if (!array(p, object, "metrics", &list, 8, false)) return false;
    for (const cJSON *a = list ? list->child : NULL; a; a = a->next) {
        ps_board_metric_t *metric = &out->metrics[out->metric_count++];
        if (!fields(p, a, "label|value|unit", 3)
            || !text(p, a, "label", &metric->label, 96, false)
            || !text(p, a, "value", &metric->value, 96, false)
            || !text(p, a, "unit", &metric->unit, 32, false)) return false;
    }
    if (!array(p, object, "rows", &list, 24, false)) return false;
    for (const cJSON *a = list ? list->child : NULL; a; a = a->next) {
        ps_board_row_t *row = &out->rows[out->row_count++];
        if (!fields(p, a, "label|value", 2)
            || !text(p, a, "label", &row->label, 96, false)
            || !text(p, a, "value", &row->value, 256, false)) return false;
    }
    if (!array(p, object, "series", &list, 60, false)) return false;
    for (const cJSON *a = list ? list->child : NULL; a; a = a->next) {
        if (!cJSON_IsNumber(a) || !isfinite(a->valuedouble) || fabs(a->valuedouble) > 1e30)
            return fail(p, "series_range");
        out->series[out->series_count++] = (float)a->valuedouble;
    }
    if (!number(p, object, "timestamp", &out->timestamp, 0, 4102444800., false, false)
        || !number(p, object, "duration", &out->duration, 0, 315360000., false, false)
        || !number(p, object, "progress", &out->progress, 0, 100, false, false)
        || !boolean(p, object, "running", &out->running)) return false;
    out->has_progress = item(object, "progress") != NULL;
    out->asset_index = -1;
    const cJSON *asset = item(object, "asset");
    if (asset) {
        if (!cJSON_IsString(asset)) return fail(p, "asset_reference");
        if (*asset->valuestring) {
            for (unsigned i = 0; i < p->model->asset_count; i++)
                if (!strcmp(asset->valuestring, p->model->assets[i].id)) out->asset_index = (int8_t)i;
            if (out->asset_index < 0) return fail(p, "asset_missing");
        }
    }
    if (out->kind == PS_BOARD_IMAGE && out->asset_index < 0) return fail(p, "asset_missing");
    hash_bytes(p->model, &out->metric_count, sizeof(out->metric_count));
    hash_bytes(p->model, &out->row_count, sizeof(out->row_count));
    hash_bytes(p->model, &out->series_count, sizeof(out->series_count));
    hash_bytes(p->model, out->series, out->series_count * sizeof(float));
    hash_bytes(p->model, &out->timestamp, sizeof(out->timestamp));
    hash_bytes(p->model, &out->duration, sizeof(out->duration));
    hash_bytes(p->model, &out->progress, sizeof(out->progress));
    hash_bytes(p->model, &out->has_progress, sizeof(out->has_progress));
    hash_bytes(p->model, &out->running, sizeof(out->running));
    hash_bytes(p->model, &out->asset_index, sizeof(out->asset_index));
    hash_bytes(p->model, &out->span, sizeof(out->span));
    hash_bytes(p->model, &out->media_vertical, sizeof(out->media_vertical));
    hash_bytes(p->model, &out->region_ranking, sizeof(out->region_ranking));
    hash_bytes(p->model, &out->rank_traffic, sizeof(out->rank_traffic));
    hash_bytes(p->model, &out->region_count, sizeof(out->region_count));
    return true;
}
ps_board_model_t *ps_board_model_parse_ex(const void *data, size_t bytes, const char **error) {
    if (error) *error = "invalid_json";
    if (!data || !bytes || bytes > PS_BOARD_DATA_MAX || !preflight(data, bytes)) return NULL;
    const char *end = NULL;
    rp_home_json_allocation_reset();
    cJSON *root = cJSON_ParseWithLengthOpts(data, bytes, &end, false);
    if (!root) {if(error&&rp_home_json_allocation_failed())*error="out_of_memory";return NULL;}
    const char *limit = (const char *)data + bytes;
    while (end && end < limit && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r')) end++;
    ps_board_model_t *m = NULL;
    parser_t p = {.error = "invalid_json"};
    if (end != limit) goto done;
    m = BOARD_ALLOC(sizeof(*m) + bytes + 1);
    if (!m) { p.error = "out_of_memory"; goto done; }
    memset(m, 0, sizeof(*m));
    m->allocation_bytes = sizeof(*m) + bytes + 1;
    m->semantic_hash = UINT64_C(14695981039346656037);
    m->adopted_ms = -1;
    m->paint_bucket = -1;
    p.model = m; p.cursor = m->arena; p.end = m->arena + bytes + 1;
    double schema, columns, scale;
    if (!fields(&p, root, "schema|board_id|generated_at|modules|columns|dark|assets|text_scale|world_map", 9)
        || !number(&p, root, "schema", &schema, 1, 1, true, true)
        || !text(&p, root, "board_id", &m->board_id, 64, true)
        || !number(&p, root, "generated_at", &m->generated_at, 0, 4102444800., true, false)
        || !number(&p, root, "columns", &columns, 1, 2, true, true)
        || !number(&p, root, "text_scale", &scale, 2, 4, false, true)
        || !boolean(&p, root, "dark", &m->dark) || !assets(&p, root)) goto done;
    m->columns = (uint8_t)columns;
    m->text_scale = item(root,"text_scale") ? (uint8_t)scale : 3;
    hash_bytes(m, &m->columns, sizeof(m->columns));
    hash_bytes(m, &m->dark, sizeof(m->dark));
    hash_bytes(m, &m->text_scale, sizeof(m->text_scale));
    const cJSON *list;
    if (!array(&p, root, "modules", &list, PS_BOARD_MODULE_MAX, true)) goto done;
    for (const cJSON *a = list->child; a; a = a->next) {
        if (!module(&p, a, &m->modules[m->module_count])) goto done;
        m->module_count++;
    }
    const cJSON *world=item(root,"world_map");
    bool need_map=ps_board_model_needs_world_map(m);
    if(need_map!=!!world){p.error=need_map?"world_map_missing":"world_map_unused";goto done;}
    if(world){
        if(!cJSON_IsString(world)){p.error="world_map_format";goto done;}
        size_t encoded=strlen(world->valuestring);
        if(encoded<32||encoded%4||encoded>((PS_BOARD_WORLD_MAP_MAX+2)/3)*4){p.error="world_map_limit";goto done;}
        size_t raw=encoded/4*3-(world->valuestring[encoded-1]=='=')-(world->valuestring[encoded-2]=='=');
        bool out_of_memory=false;
        if(raw>PS_BOARD_WORLD_MAP_MAX||raw>(size_t)(p.end-p.cursor)
            ||!decode(world->valuestring,(uint8_t*)p.cursor,raw)
            ||!set_world_map(m,p.cursor,raw,&out_of_memory)){
            p.error=out_of_memory?"out_of_memory":"world_map_invalid";goto done;
        }
        hash_bytes(m,p.cursor,raw);
    }
    m->display_time = m->generated_at;
    cJSON_Delete(root);
    if (error) *error = NULL;
    return m;
done:
    cJSON_Delete(root);
    ps_board_model_free(m);
    if (error) *error = p.error;
    return NULL;
}
ps_board_model_t *ps_board_model_parse(const void *data, size_t bytes) {
    return ps_board_model_parse_ex(data, bytes, NULL);
}
void ps_board_model_free(ps_board_model_t *m) { if(m)free(m->world_map);free(m); }
bool ps_board_model_tick_at(ps_board_model_t *m, int64_t now, double utc) {
    if (!m) return false;
    if (m->adopted_ms < 0 || now < m->adopted_ms) m->adopted_ms = now;
    double next = isfinite(utc) && utc >= 1577836800. && utc <= 4102444800.
        ? utc : m->generated_at + (double)(now - m->adopted_ms) / 1000.;
    bool dynamic = false;
    for (unsigned i = 0; i < m->module_count; i++)
        if (m->modules[i].kind == PS_BOARD_CLOCK || m->modules[i].kind == PS_BOARD_DATE
            || (m->modules[i].running && m->modules[i].duration > 0)) dynamic = true;
    // 中文：本机时间以分钟节拍定稿，不让时钟触发每秒整屏刷新。
    // English: Settle local time at minute boundaries instead of refreshing the whole screen every second.
    int64_t bucket = (int64_t)(next / 60.);
    bool changed = dynamic && m->paint_bucket >= 0 && m->paint_bucket != bucket;
    m->display_time = next;
    m->paint_bucket = bucket;
    return changed;
}
bool ps_board_model_tick(ps_board_model_t *m, int64_t now) {
    bool zone_changed = false;
#if defined(ESP_PLATFORM) || defined(PICO_NATIVE_PREVIEW)
    zone_changed = ps_board_model_set_timezone(m, ps_datetime_timezone_minutes());
#endif
    return ps_board_model_tick_at(m, now, (double)time(NULL)) || zone_changed;
}
bool ps_board_model_set_timezone(ps_board_model_t *m, int minutes) {
    if (!m || minutes < -720 || minutes > 840 || minutes % 15 || m->utc_offset_minutes == minutes) return false;
    m->utc_offset_minutes = (int16_t)minutes;
    return true;
}
bool ps_board_model_needs_world_map(const ps_board_model_t *m) {
    if(m)for(unsigned i=0;i<m->module_count;i++)
        if(m->modules[i].kind==PS_BOARD_CLOUDFLARE&&!m->modules[i].region_ranking)return true;
    return false;
}
static uint16_t map_u16(const uint8_t *p){return (uint16_t)(p[0]|p[1]<<8);}
static uint32_t map_u32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static bool set_world_map(ps_board_model_t *m,const void *data,size_t bytes,bool *out_of_memory) {
    if(out_of_memory)*out_of_memory=false;
    const uint8_t *p=data;
    if(!m||!p||bytes<24||bytes>PS_BOARD_WORLD_MAP_MAX||memcmp(p,"BWMAP001",8)
        ||map_u16(p+8)!=120||map_u16(p+10)!=52||map_u32(p+16)!=bytes-24)return false;
    unsigned countries=map_u16(p+12),points=map_u16(p+14);
    if(!countries||countries>250||!points||points>6240||bytes!=24+countries*6+points*2)return false;
    uint32_t crc=~0u;
    for(size_t i=24;i<bytes;i++){crc^=p[i];for(unsigned b=0;b<8;b++)crc=(crc>>1)^((0u-(crc&1u))&0xedb88320u);}
    if(~crc!=map_u32(p+20))return false;
    unsigned next=0;uint8_t occupied[780]={0};
    for(unsigned i=0;i<countries;i++){
        const uint8_t *r=p+24+i*6;unsigned start=map_u16(r+2),count=map_u16(r+4);
        if(r[0]<'A'||r[0]>'Z'||r[1]<'A'||r[1]>'Z'||start!=next||!count||count>points-start)return false;
        if(i&&memcmp(r-6,r,2)>=0)return false;
        next+=count;
    }
    if(next!=points)return false;
    for(unsigned i=0;i<points;i++){
        unsigned dot=map_u16(p+24+countries*6+i*2);
        if(dot>=6240||(occupied[dot/8]&(1u<<(dot%8))))return false;
        occupied[dot/8]|=(uint8_t)(1u<<(dot%8));
    }
    uint8_t *copy=BOARD_ALLOC(bytes);if(!copy){if(out_of_memory)*out_of_memory=true;return false;}
    memcpy(copy,data,bytes);free(m->world_map);m->world_map=copy;m->world_map_bytes=bytes;return true;
}
bool ps_board_model_set_world_map(ps_board_model_t *m,const void *data,size_t bytes) {
    return set_world_map(m,data,bytes,NULL);
}
