#pragma once
// Fixed UI strings only. User names, tasks and raw values are never translated.
static const char *local_label(const char *text){
    return c6_renderer_localized(renderer(),text);
}
static const char *local_format(const char *zh,const char *en){
    if(standalone_config.language==1)return en;
    return zh;
}
