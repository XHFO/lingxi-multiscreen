#pragma once
#include "display_snapshot.h"
#include "local_language.h"
#include "hybrid_cards.h"
// Included by main.c. All state/render/actions run on the HTTP display owner.
typedef enum {C6_CARD_GENERIC,C6_CARD_CLOCK,C6_CARD_WEATHER,C6_CARD_HA,C6_CARD_PRINTER,C6_CARD_DIAGNOSTICS,C6_CARD_OVERVIEW} c6_card_kind_t;
typedef struct {c6_card_kind_t kind;unsigned group;char serial[40],brand[12],source[12],origin[160];} c6_card_context_t;
static c6_card_context_t software_context,local_context,menu_context;
static char menu_entity_id[128];
static char menu_notice[96];
static struct {int revision,rotation,card_mask;unsigned printers;bool flip,dirty;
    int language;
    int sleep_mode;
} menu_draft;
static void menu_start_draft(void){
    menu_draft.revision=standalone_config.revision;menu_draft.rotation=standalone_config.rotation;menu_draft.card_mask=standalone_config.card_mask;
    menu_draft.flip=standalone_config.flip_animation;menu_draft.printers=0;menu_draft.dirty=false;
    menu_draft.language=standalone_config.language;
    menu_draft.sleep_mode=standalone_config.sleep_mode;
    for(unsigned i=0;i<standalone_config.printer_count;i++)if(standalone_config.printers[i].rotate)menu_draft.printers|=1U<<i;
}
static bool menu_save_draft(void){
    if(!menu_draft.dirty)return true;
    bool saved;
    saved=standalone_save_monitor_display(menu_draft.revision,menu_draft.rotation,menu_draft.flip,menu_draft.card_mask,menu_draft.printers,menu_draft.language,menu_draft.sleep_mode);
    if(!saved){
        snprintf(menu_notice,sizeof(menu_notice),"%s",menu_draft.revision!=standalone_config.revision?"配置已更新 · 重新打开设置":"保存失败 · 长按重试");
        if(menu_draft.revision!=standalone_config.revision)menu_start_draft();
        device_menu.revision++;return false;
    }
    c6_sources_display_options(standalone_config.revision,standalone_config.flip_animation);
    display_rotated=standalone_config.rotation==180;last_clock_second=UINT32_MAX;page_since=0;local_page=0;view_revision++;
    terminal_rotation=standalone_config.rotation;
    menu_start_draft();*menu_notice=0;return true;
}
static bool reset_station_wifi(void);
static uint32_t menu_draw_hash,menu_draw_generation;
static unsigned menu_row_count;
static c6_render_menu_row_t menu_rows[8];
static char menu_labels[8][64],menu_values[8][160];
static const char *menu_title;
static unsigned menu_add_raw(const char *label,const char *value){
    if(menu_row_count>=8)return menu_row_count;
    unsigned i=menu_row_count++;snprintf(menu_labels[i],64,"%s",label?label:"");snprintf(menu_values[i],160,"%s",value?value:"");
    menu_rows[i]=(c6_render_menu_row_t){menu_labels[i],menu_values[i]};return i;
}
static unsigned menu_add(const char *label,const char *value){return menu_add_raw(local_label(label),local_label(value));}
static int menu_printer_index(void){
    int found=-1;for(unsigned i=0;i<standalone_config.printer_count;i++){
        c6_printer_config_t *p=&standalone_config.printers[i];
        char origin[160];c6_printer_origin(&standalone_config,p,origin,sizeof(origin));
        if(p->enabled&&!strcmp(p->serial,menu_context.serial)&&!strcmp(c6_printer_brand(p),menu_context.brand)&&!strcmp(c6_printer_source(p),menu_context.source)&&(!*menu_context.origin||!strcmp(origin,menu_context.origin))){
            if(found>=0){return -1;}
            found=i;
        }
    }return found;
}
static void menu_set_printer(c6_card_context_t *context,unsigned i){
    const c6_printer_config_t *p=&standalone_config.printers[i];context->kind=C6_CARD_PRINTER;
    snprintf(context->serial,sizeof(context->serial),"%s",p->serial);snprintf(context->brand,sizeof(context->brand),"%s",c6_printer_brand(p));snprintf(context->source,sizeof(context->source),"%s",c6_printer_source(p));
    c6_printer_origin(&standalone_config,p,context->origin,sizeof(context->origin));
}
static void menu_frame_context(httpd_req_t *req){
    software_context=(c6_card_context_t){0};char kind[16];
    if(httpd_req_get_hdr_value_str(req,"X-Lingxi-Card",kind,sizeof(kind))!=ESP_OK)return;
    if(!strcmp(kind,"clock"))software_context.kind=C6_CARD_CLOCK;
    else if(!strcmp(kind,"diagnostics"))software_context.kind=C6_CARD_DIAGNOSTICS;
    else if(!strcmp(kind,"overview"))software_context.kind=C6_CARD_OVERVIEW;
    else if(!strcmp(kind,"weather"))software_context.kind=C6_CARD_WEATHER;
    else if(!strcmp(kind,"ha"))software_context.kind=C6_CARD_HA;
    else if(!strcmp(kind,"printer")){
        software_context.kind=C6_CARD_PRINTER;
        if(httpd_req_get_hdr_value_str(req,"X-Lingxi-Serial",software_context.serial,sizeof(software_context.serial))!=ESP_OK||
           httpd_req_get_hdr_value_str(req,"X-Lingxi-Brand",software_context.brand,sizeof(software_context.brand))!=ESP_OK||
           httpd_req_get_hdr_value_str(req,"X-Lingxi-Source",software_context.source,sizeof(software_context.source))!=ESP_OK)software_context=(c6_card_context_t){0};
    }
    if(httpd_req_get_hdr_value_str(req,"X-Lingxi-Origin",software_context.origin,sizeof(software_context.origin))!=ESP_OK)*software_context.origin=0;
}
static void menu_capture_context(bool software){
    menu_context=(c6_card_context_t){0};
    if(software){menu_context=native_clock?(c6_card_context_t){.kind=C6_CARD_CLOCK}:software_context;return;}
    menu_context=local_context;
}
static void menu_build(void){
    c6_menu_level_t *p=c6_menu_current(&device_menu);menu_row_count=0;menu_title="设备设置";if(!p)return;
    const c6_source_snapshot_t *s=display_sources();char value[160];
    switch(p->view){
    case C6_MENU_SETTINGS:menu_add("屏幕显示","方向与时钟动画");menu_add("轮询卡片","选择参与自动轮转的卡片");menu_add("网页详细配置","手机扫码 · 无需 PIN");menu_add("网络","连接信息与重置 Wi-Fi");menu_add("设备信息","固件与运行时间");break;
    case C6_MENU_DISPLAY:menu_title="屏幕显示";
        snprintf(value,sizeof(value),local_format("%d° · 双击切换","%d / double: rotate"),menu_draft.rotation);menu_add_raw(local_label("屏幕方向"),value);
        menu_add("动态翻页",menu_draft.flip?"已开启 · 双击关闭":"已关闭 · 双击开启");
        menu_add_raw(local_label("显示语言"),menu_draft.language?"English":"中文");
        menu_add("自动休眠",menu_draft.sleep_mode==1?"无操作休眠":menu_draft.sleep_mode==2?"定时休眠":"关闭");
        menu_add("网页详细配置","休眠时段与显示参数");
        break;
    case C6_MENU_CARDS:menu_title="轮询卡片";
#if C6_FORMLABS_ONLY
        menu_add("桌面时钟",standalone_config.clock?((menu_draft.card_mask&1)?"已启用 · 双击关闭":"已关闭 · 双击启用"):"尚未配置 · 双击扫码");
        menu_add("天气",standalone_config.weather?((menu_draft.card_mask&4)?"已启用 · 双击关闭":"已关闭 · 双击启用"):"尚未配置 · 双击扫码");
        for(unsigned i=0;i<standalone_config.printer_count;i++){
            menu_add_raw(*standalone_config.printers[i].name?standalone_config.printers[i].name:standalone_config.printers[i].serial,local_label(standalone_config.printers[i].enabled?((menu_draft.printers&(1U<<i))?"已启用 · 双击关闭":"已关闭 · 双击启用"):"尚未启用 · 双击扫码"));
        }
        break;
#else
        {const char *names[]={"桌面时钟","设备状态","天气","Home Assistant"};bool ready[]={standalone_config.clock,standalone_config.diagnostics,standalone_config.weather,standalone_config.ha_enabled&&standalone_config.entity_count};
        for(unsigned i=0;i<4;i++)menu_add(names[i],ready[i]?((menu_draft.card_mask&(1U<<i))?"已启用 · 双击关闭":"已关闭 · 双击启用"):"尚未配置 · 双击扫码");
        for(unsigned i=0;i<standalone_config.printer_count;i++)menu_add(standalone_config.printers[i].name,standalone_config.printers[i].enabled?((menu_draft.printers&(1U<<i))?"已启用 · 双击关闭":"已关闭 · 双击启用"):"尚未启用 · 双击扫码");}break;
#endif
    case C6_MENU_WEB:menu_title="网页详细配置";menu_add("连接同一 Wi-Fi",strcmp(ip,"0.0.0.0")?ip:"尚未连接局域网");break;
    case C6_MENU_PIN:{menu_title="配对码";char pin[5];int seconds;
        if(standalone_pairing_pin(pin,&seconds)){snprintf(value,sizeof(value),"%s · %d 秒内有效",pin,seconds);menu_add("4 位 PIN",value);menu_add("仅在可信局域网使用","");}
        else {menu_add("配对窗口已关闭","长按返回后重新打开");}
        break;}
    case C6_MENU_NETWORK:{menu_title="网络";wifi_ap_record_t ap={0};
        bool online=esp_wifi_sta_get_ap_info(&ap)==ESP_OK;menu_add_raw(local_label(online?"已连接 2.4 GHz Wi-Fi":"未连接 · 可使用配置热点"),online?(const char*)ap.ssid:"XH-Multiscreen");
        menu_add("IP 地址",ip);menu_add("重置 Wi-Fi",*menu_notice?menu_notice:"保留实体与打印机设置");break;}
    case C6_MENU_RESET:menu_title="确认重置 Wi-Fi";menu_add("取消","不修改网络配置");menu_add("重置 Wi-Fi","仅清除网络 · 不恢复出厂");break;
    case C6_MENU_INFO:menu_title="设备信息";menu_add_raw(local_label("设备名称"),hostname);menu_add("固件",C6_FIRMWARE_VERSION);snprintf(value,sizeof(value),local_format("%llu 分钟","%llu min"),(unsigned long long)c6_seconds()/60);menu_add("运行时间",value);menu_add("IP 地址",ip);menu_add("固件更新",C6_FORMLABS_ONLY?"网页后台 OTA 更新":"在电脑的设备管理中操作");break;
    case C6_MENU_CLOCK:menu_title="时钟设置";menu_add("时间同步",time(NULL)>=1609459200?"已同步":"等待网络校时");menu_add("动态翻页",menu_draft.flip?"已开启 · 双击关闭":"已关闭 · 双击开启");break;
    case C6_MENU_WEATHER:menu_title="天气详情";
        if(s->weather.valid){snprintf(value,sizeof(value),local_format("%.1f°C · 体感 %.1f°C","%.1f°C / FEELS %.1f°C"),s->weather.temperature,s->weather.apparent);menu_add_raw(standalone_config.weather_city,value);snprintf(value,sizeof(value),local_format("%.0f / %.0f°C · 降水 %d%%","%.0f / %.0f°C / RAIN %d%%"),s->weather.low,s->weather.high,s->weather.rain);menu_add("最低 / 最高",value);}
        menu_add("刷新天气",*menu_notice?menu_notice:"至少间隔 5 分钟，失败后退避");menu_add("网页详细配置","城市与更新间隔");break;
    case C6_MENU_ENTITIES:menu_title="Home Assistant";
        for(unsigned i=device_menu.software_owner?0:menu_context.group*4;i<standalone_config.entity_count&&(device_menu.software_owner||i<menu_context.group*4+4);i++)menu_add(standalone_config.entities[i].name,s->entities[i].available?s->entities[i].state:"不可用");
        if(!menu_row_count){menu_add("暂无实体","请在 Mac 卡片页面选择");}
        menu_add("网页详细配置","选择实体与显示名称");
        break;
    case C6_MENU_ENTITY:{menu_title="实体详情";int found=-1;for(unsigned i=0;i<standalone_config.entity_count;i++)if(!strcmp(menu_entity_id,standalone_config.entities[i].id))found=i;
        if(found<0){menu_add("实体已移除","");break;}const c6_entity_state_t *e=&s->entities[found];menu_add("名称",standalone_config.entities[found].name);snprintf(value,sizeof(value),"%s %s",e->state,e->unit);menu_add(e->available?"状态":"状态 · 不可用",value);snprintf(value,sizeof(value),"%llu 秒前",(unsigned long long)(e->updated?c6_seconds()-e->updated:0));menu_add("数据更新",e->updated?value:"尚未获取");break;}
    case C6_MENU_PRINTER:{menu_title=local_label("打印机详情");int i=menu_printer_index();if(i<0){menu_add("打印机已移除或未同步",C6_FORMLABS_ONLY?"请在网页添加打印机":"请在 Mac 同步显示设置");break;}
        c6_printer_config_t *c=&standalone_config.printers[i];const c6_printer_state_t *v=&s->printers[i];menu_title=*c->name?c->name:c->serial;
        if(*v->task){menu_add_raw(local_label("任务名称"),v->task);}
        if(*v->status){menu_add_raw(local_label("打印状态"),local_label(c6_renderer_print_status(v->status)));}
        if(v->progress_valid){snprintf(value,sizeof(value),"%d%%",v->progress);menu_add("打印进度",value);}
        if(v->remaining_valid){snprintf(value,sizeof(value),local_format("%d 分钟","%d min"),v->remaining);menu_add("剩余时间",value);}
        if(v->layer_count){snprintf(value,sizeof(value),"%d / %d",v->layer,v->layer_count);menu_add("层数",value);}if(*v->material)menu_add_raw(local_label("材料"),v->material);
        if(!menu_row_count){menu_add("等待打印数据","");}
        menu_add("网页详细配置","数据源与显示项目");
        break;}
    default:menu_title="卡片详情";menu_add("网页详细配置","手机连接同一 Wi-Fi");break;
    }
    if(p->view!=C6_MENU_PRINTER)menu_title=local_label(menu_title);
    p->selected%=menu_row_count?menu_row_count:1;
}
static void menu_render(void){
    menu_build();c6_menu_level_t *p=c6_menu_current(&device_menu);uint32_t hash=2166136261U;
    for(const unsigned char *s=(const unsigned char*)menu_title;*s;s++)hash=(hash^*s)*16777619U;
    for(unsigned i=0;i<menu_row_count;i++){const char *strings[]={menu_labels[i],menu_values[i]};for(unsigned j=0;j<2;j++)for(const unsigned char *p=(const unsigned char*)strings[j];*p;p++)hash=(hash^*p)*16777619U;}
    hash^=device_menu.revision;
    if(p->view==C6_MENU_WEB)for(const unsigned char *s=(const unsigned char*)ip;*s;s++)hash=(hash^*s)*16777619U;
    if(hash==menu_draw_hash&&menu_draw_generation==frame_generation)return;
    c6_render_style_t style=local_style();
    char pin[5];int seconds;
    if(p->view==C6_MENU_WEB&&strcmp(ip,"0.0.0.0")){
        char url[64];snprintf(url,sizeof(url),"http://%s/standalone",ip);
        if(!c6_renderer_qr(renderer(),url,ip,&style))c6_renderer_message(renderer(),"无法生成二维码",ip);
    }else if(p->view==C6_MENU_PIN&&standalone_pairing_pin(pin,&seconds)){
        c6_renderer_pairing(renderer(),pin,seconds,&style);
    }else c6_renderer_menu(renderer(),menu_title,menu_rows,menu_row_count,p->selected,local_label(*menu_notice?menu_notice:menu_draft.dirty?"长按返回 · 自动保存":"单击切换 · 双击确认 · 长按返回"),&style);
    calibrated_display();
    menu_draw_hash=hash;menu_draw_generation=frame_generation;
}
static void menu_return_to_card(void){
    standalone_pairing_close();pairing_visible=false;set_brightness(brightness);
    revision=0;last_clock_second=UINT32_MAX;page_since=esp_timer_get_time();view_revision++;
    if(device_menu.software_owner&&software_visible){
        // One framebuffer: never replay the menu as an external image.
        c6_renderer_message(renderer(),"正在恢复卡片","等待最新软件画面");display_frame();
    }
}
static void menu_gesture(c6_button_event_t event){
    int64_t now=esp_timer_get_time()/1000;
    if(!device_menu.depth){
        bool software=software_controls();
        if(event==C6_BUTTON_SINGLE){if(software)__atomic_add_fetch(&button_sequence,1,__ATOMIC_RELAXED);else local_step_pending++;page_since=esp_timer_get_time();return;}
        menu_capture_context(software);*menu_notice=0;menu_start_draft();
        c6_menu_view_t view=C6_MENU_SETTINGS;
        if(event==C6_BUTTON_DOUBLE){view=menu_context.kind==C6_CARD_CLOCK?C6_MENU_CLOCK:menu_context.kind==C6_CARD_WEATHER?C6_MENU_WEATHER:menu_context.kind==C6_CARD_HA?C6_MENU_ENTITIES:menu_context.kind==C6_CARD_PRINTER?C6_MENU_PRINTER:C6_MENU_GENERIC;}
        c6_menu_open(&device_menu,view,software,now);set_brightness(brightness);view_revision++;return;
    }
    menu_build();c6_menu_level_t *p=c6_menu_current(&device_menu);device_menu.touched=now;
    if(event==C6_BUTTON_SINGLE){c6_menu_next(&device_menu,menu_row_count,now);return;}
    if(event==C6_BUTTON_HOLD){if(!menu_save_draft())return;if(p->view==C6_MENU_PIN)standalone_pairing_close();c6_menu_back(&device_menu,now);if(!device_menu.depth)menu_return_to_card();return;}
    if(event!=C6_BUTTON_DOUBLE)return;
    if(p->view==C6_MENU_SETTINGS){static const c6_menu_view_t views[]={C6_MENU_DISPLAY,C6_MENU_CARDS,C6_MENU_WEB,C6_MENU_NETWORK,C6_MENU_INFO};*menu_notice=0;menu_start_draft();c6_menu_enter(&device_menu,views[p->selected],now);}
    else if(p->view==C6_MENU_NETWORK&&p->selected==2)c6_menu_enter(&device_menu,C6_MENU_RESET,now);
    else if(p->view==C6_MENU_RESET){bool reset=p->selected==1;if(reset)snprintf(menu_notice,sizeof(menu_notice),"%s",reset_station_wifi()?"已重置 · 请连接设备配置热点":"重置失败 · 请重试");c6_menu_back(&device_menu,now);}
    else if(p->view==C6_MENU_ENTITIES){if(p->selected==menu_row_count-1)c6_menu_enter(&device_menu,C6_MENU_WEB,now);else {unsigned i=(device_menu.software_owner?0:menu_context.group*4)+p->selected;if(i<standalone_config.entity_count){snprintf(menu_entity_id,sizeof(menu_entity_id),"%s",standalone_config.entities[i].id);c6_menu_enter(&device_menu,C6_MENU_ENTITY,now);}}}
    else if((p->view==C6_MENU_CLOCK&&p->selected==1)||(p->view==C6_MENU_DISPLAY&&p->selected==1)){menu_draft.flip=!menu_draft.flip;menu_draft.dirty=true;device_menu.revision++;}
    else if(p->view==C6_MENU_DISPLAY&&p->selected==0){menu_draft.rotation=(menu_draft.rotation+90)%360;menu_draft.dirty=true;device_menu.revision++;}
    else if(p->view==C6_MENU_DISPLAY&&p->selected==2){menu_draft.language^=1;menu_draft.dirty=true;menu_save_draft();device_menu.revision++;}
    else if(p->view==C6_MENU_DISPLAY&&p->selected==3){menu_draft.sleep_mode=(menu_draft.sleep_mode+1)%3;menu_draft.dirty=true;device_menu.revision++;}
    else if(p->view==C6_MENU_DISPLAY&&p->selected==4)c6_menu_enter(&device_menu,C6_MENU_WEB,now);
    else if(p->view==C6_MENU_CARDS){unsigned i=p->selected;
#if C6_FORMLABS_ONLY
        bool ready=i==0?standalone_config.clock:i==1?standalone_config.weather:standalone_config.printers[i-2].enabled;
        if(!ready)c6_menu_enter(&device_menu,C6_MENU_WEB,now);else {if(i<2)menu_draft.card_mask^=i==0?1:4;else menu_draft.printers^=1U<<(i-2);menu_draft.dirty=true;device_menu.revision++;}}
#else
        bool ready=i==0?standalone_config.clock:i==1?standalone_config.diagnostics:i==2?standalone_config.weather:i==3?standalone_config.ha_enabled&&standalone_config.entity_count:standalone_config.printers[i-4].enabled;
        if(!ready)c6_menu_enter(&device_menu,C6_MENU_WEB,now);else {if(i<4)menu_draft.card_mask^=1U<<i;else menu_draft.printers^=1U<<(i-4);menu_draft.dirty=true;device_menu.revision++;}}
#endif
    else if(p->view==C6_MENU_WEATHER&&p->selected==menu_row_count-2){snprintf(menu_notice,sizeof(menu_notice),"%s",c6_sources_weather_refresh()?"已安排刷新":"请等待 5 分钟间隔后重试");device_menu.revision++;}
    else if((p->view==C6_MENU_WEATHER||p->view==C6_MENU_PRINTER||p->view==C6_MENU_GENERIC)&&p->selected==menu_row_count-1)c6_menu_enter(&device_menu,C6_MENU_WEB,now);
}
