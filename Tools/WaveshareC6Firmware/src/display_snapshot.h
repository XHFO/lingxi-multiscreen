#pragma once
#include "local_sources.h"
// Display/menu callbacks share the HTTP task. A reusable snapshot prevents
// multiple full-device copies in nested stack frames. Consume before refreshing.
static const c6_source_snapshot_t *display_sources(void){
    static c6_source_snapshot_t snapshot;
    c6_sources_try_snapshot(&snapshot);
    return &snapshot;
}
