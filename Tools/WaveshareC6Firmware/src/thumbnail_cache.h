#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define C6_THUMBNAIL_EDGE 80
#define C6_THUMBNAIL_BYTES (C6_THUMBNAIL_EDGE*C6_THUMBNAIL_EDGE*2)
typedef struct {
    uint8_t *bytes;
    unsigned width,height;
    char serial[40],task_key[17];
} c6_thumbnail_cache_t;
bool c6_thumbnail_valid_key(const char *key);
bool c6_thumbnail_matches(const c6_thumbnail_cache_t *cache,const char *serial,const char *key);
// Takes ownership only on success. Caller retains the staging buffer on failure.
bool c6_thumbnail_commit(c6_thumbnail_cache_t *cache,const char *serial,const char *key,unsigned width,unsigned height,uint8_t *bytes,size_t length);
void c6_thumbnail_clear(c6_thumbnail_cache_t *cache);
// Only authenticated same-origin HA URLs; no redirects, camera proxies or token leakage.
bool c6_thumbnail_url(const char *host,int port,bool tls,const char *picture,char *out,size_t capacity);
// Constructs only HA's single-frame endpoint from a validated entity ID.
// Camera URLs from entity_picture are deliberately still rejected above.
bool c6_camera_snapshot_url(const char *host,int port,bool tls,const char *entity,char *out,size_t capacity);
bool c6_thumbnail_due(bool camera,bool cached,uint64_t now,uint64_t next);
// Samples one decoded RGB888 block into a fixed, caller-owned RGB565 cover.
bool c6_thumbnail_rgb_block(uint8_t *out,unsigned source_width,unsigned source_height,
                            unsigned left,unsigned top,unsigned right,unsigned bottom,const uint8_t *rgb);
