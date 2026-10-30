/* 私有解析器固定使用PSRAM，不改变其它组件的全局hooks；cJSON仍来自原MIT许可依赖。
 * Private parser allocates in PSRAM without changing other components hooks; cJSON retains its dependency MIT license. */
#include <stdlib.h>
#include <stdbool.h>
static _Thread_local bool home_json_failed;
void rp_home_json_allocation_reset(void){home_json_failed=false;}
bool rp_home_json_allocation_failed(void){return home_json_failed;}
#ifdef ESP_PLATFORM
#include "esp_heap_caps.h"
static void *home_json_allocate(size_t n){void *p=heap_caps_malloc(n,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);if(!p)home_json_failed=true;return p;}
#else
static void *home_json_allocate(size_t n){void *p=malloc(n);if(!p)home_json_failed=true;return p;}
#endif
#include "home_link_json.h"
#define malloc home_json_allocate
#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
#include "cJSON.c"
#ifdef __clang__
#pragma clang diagnostic pop
#endif
