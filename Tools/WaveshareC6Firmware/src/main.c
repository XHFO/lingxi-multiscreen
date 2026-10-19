// Waveshare ESP32-C6-LCD-1.3 experimental receiver. Official LCD pin mapping.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "menu_state.h"
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "esp_event.h"
#include "esp_wifi.h"
#include "esp_netif.h"
#include "esp_http_server.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_sntp.h"
#include "standalone.h"
#include "local_sources.h"
#include "display_snapshot.h"
#include "display_styles.h"
#include "wifi_provision.h"
#include "software_simulation.h"
#include "wifi_scan.h"
#include "esp_partition.h"
#include <strings.h>
#include "mbedtls/base64.h"
#include <time.h>
#include <ctype.h>
#include "nvs_flash.h"
#include "nvs.h"
#include "lwip/sockets.h"
#include "lan_access.h"
#include "hybrid_cards.h"

#define FRAME_BYTES (240 * 240 * 2)
static spi_device_handle_t lcd;
static uint8_t *frame;
static uint32_t frame_generation;
// True only while the sole RGB565 buffer contains a complete displayed frame.
// Interrupted uploads cannot retain the previous LCD bytes without a second
// framebuffer, so preview must wait for a full replacement instead.
static bool frame_valid;
static uint32_t revision;
static int brightness = 80;
static char hostname[40], ip[16] = "0.0.0.0";
static esp_netif_t *station;
static unsigned retries;
static bool station_offline;
static bool station_has_credentials;
static uint32_t reconnect_at;
static bool station_joined_pending,network_notice;
static int64_t hotspot_close_at;
static bool network_notice_drawn;
static httpd_handle_t http_server;
static bool native_clock, display_rotated;
static int native_clock_style;
#include "terminal_display_policy.h"
static int terminal_rotation;
static bool terminal_asleep,terminal_manual_override;
static uint64_t terminal_last_activity;
static int terminal_preview_page=-1;
static int64_t terminal_preview_until;
static bool setup_notice_drawn,setup_qr_web;
static bool terminal_guide_qr,terminal_guide_offered,terminal_guide_empty;
#if C6_FORMLABS_ONLY
#include "captive_dns.h"
static esp_netif_t *setup_ap;
#endif
static uint32_t clock_epoch, last_clock_second;
static int clock_timezone;
static int64_t clock_anchor;
static uint32_t button_sequence, boot_id;
static int64_t page_since;
static uint32_t key_request;
static unsigned local_step_pending;
static c6_menu_t device_menu;
static uint32_t view_revision;
typedef struct {c6_button_event_t event;int64_t time;} c6_queued_gesture_t;
static QueueHandle_t gesture_queue;
static TaskHandle_t clock_task_handle;
static unsigned local_page;
static uint64_t software_heartbeat;
static bool software_visible, local_visible;
static int hybrid_page=-1;
static unsigned hybrid_ha_next;
static bool pairing_visible;
static int64_t software_simulation_until;
static void button_task(void *arg) {
    c6_button_input_t input;c6_button_init(&input,gpio_get_level(9),esp_timer_get_time()/1000);
    for (;;) {
        int64_t now=esp_timer_get_time()/1000;
        c6_button_event_t event=c6_button_sample(&input,gpio_get_level(9),now);
        if(event!=C6_BUTTON_NONE){
            c6_queued_gesture_t gesture={event,now};
            if(xQueueSend(gesture_queue,&gesture,0)==pdTRUE&&clock_task_handle)xTaskNotifyGive(clock_task_handle);
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
static esp_err_t button_handler(httpd_req_t *req) {
    char json[256];
    snprintf(json,sizeof(json),"{\"protocol\":2,\"device_id\":\"%s\",\"boot_id\":%lu,\"sequence\":%lu,\"menu_active\":%s,\"view_revision\":%lu}",hostname,
        (unsigned long)boot_id,(unsigned long)__atomic_load_n(&button_sequence,__ATOMIC_RELAXED),device_menu.depth?"true":"false",(unsigned long)view_revision);
    httpd_resp_set_hdr(req,"Cache-Control","no-store");
    httpd_resp_set_type(req,"application/json");return httpd_resp_sendstr(req,json);
}

static void command(uint8_t cmd, const uint8_t *data, size_t len) {
    gpio_set_level(15, 0);
    spi_transaction_t t = {.length = 8, .tx_buffer = &cmd};
    ESP_ERROR_CHECK(spi_device_polling_transmit(lcd, &t));
    gpio_set_level(15, 1);
    while (len) {
        size_t n = len > 4096 ? 4096 : len;
        t = (spi_transaction_t){.length = n * 8, .tx_buffer = data};
        ESP_ERROR_CHECK(spi_device_polling_transmit(lcd, &t));
        data += n; len -= n;
    }
}
static void set_brightness(int level) {
    brightness = level;
    frame_generation++; // Invalidate an unchanged local card after display controls.
    int effective=standalone_pairing_brightness(level,pairing_visible||device_menu.depth);
    if(network_notice||setup_notice_drawn)effective=standalone_pairing_brightness(level,true);
    if(terminal_asleep)effective=0;
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, 1023 * effective / 100);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
}
static void terminal_display_region(unsigned left,unsigned top,unsigned right,unsigned bottom);
static void display_frame(void) {
    frame_generation++;
    terminal_display_region(0,0,239,239);
    frame_valid=true;
}
// Update just the folding tiles. One small DMA buffer, no second framebuffer;
// rotation and vendor little-endian conversion happen only at the LCD boundary.
static uint8_t clock_scanlines[240*2*4] __attribute__((aligned(4)));
static void terminal_display_region(unsigned left,unsigned top,unsigned right,unsigned bottom){
    uint8_t columns[]={0,(uint8_t)left,0,(uint8_t)right},rows[]={0,(uint8_t)top,0,(uint8_t)bottom};
    command(0x2a,columns,4);command(0x2b,rows,4);command(0x2c,NULL,0);
    unsigned width=right-left+1;
    for(unsigned y=top;y<=bottom;){
        unsigned count=bottom-y+1;if(count>4)count=4;
        for(unsigned row=0;row<count;row++)for(unsigned x=left;x<=right;x++){
            size_t from=terminal_source_pixel(terminal_rotation,x,y+row)*2,to=(row*width+x-left)*2;
            clock_scanlines[to]=frame[from+1];clock_scanlines[to+1]=frame[from];
        }
        spi_transaction_t transfer={.length=count*width*16,.tx_buffer=clock_scanlines};
        ESP_ERROR_CHECK(spi_device_polling_transmit(lcd,&transfer));y+=count;
    }
}
static void display_clock_tiles(void){
    frame_generation++;
    if(terminal_rotation==90)terminal_display_region(81,0,167,239);
    else if(terminal_rotation==180)terminal_display_region(0,81,239,167);
    else if(terminal_rotation==270)terminal_display_region(72,0,158,239);
    else terminal_display_region(0,72,239,158);
}
#include "local_render.h"
#include "clock_animation.h"
static bool clock_animation_active;
static uint32_t clock_render_button, clock_render_key;
static c6_clock_animation_t clock_animation;
static unsigned fold_frames,last_fold_frames,last_fold_ms,fold_max_us,last_fold_max_us;
static int64_t fold_started;
static void draw_clock(void *arg) {
    if(!native_clock){__atomic_store_n(&clock_animation_active,false,__ATOMIC_RELAXED);c6_clock_animation_cancel(&clock_animation);return;}
    int64_t now=esp_timer_get_time();uint32_t utc=clock_epoch+(now-clock_anchor)/1000000;
    time_t shifted=(int64_t)utc+clock_timezone;struct tm t;gmtime_r(&shifted,&t);
    c6_render_clock_t target={t.tm_year+1900,t.tm_mon+1,t.tm_mday,t.tm_wday,t.tm_hour,t.tm_min,t.tm_sec};
    bool was_active=clock_animation.active;unsigned progress;
    if(!c6_clock_animation_step(&clock_animation,&target,utc,now,frame_generation,standalone_config.flip_animation&&native_clock_style==0,last_clock_second==UINT32_MAX,&progress))return;
    if(clock_animation.active&&!was_active&&clock_task_handle)xTaskNotifyGive(clock_task_handle);
    last_clock_second=utc;
    if(clock_animation.active||was_active){
        if(clock_animation.active&&!was_active){fold_frames=fold_max_us=0;fold_started=now;}
        c6_renderer_clock_smooth(renderer(),&clock_animation.current,&clock_animation.previous,progress,was_active);
        if(was_active&&clock_animation.active)display_clock_tiles();else display_frame();
        unsigned cost=(unsigned)(esp_timer_get_time()-now);fold_frames++;if(cost>fold_max_us)fold_max_us=cost;
        if(was_active&&!clock_animation.active){last_fold_frames=fold_frames;last_fold_ms=(unsigned)((esp_timer_get_time()-fold_started)/1000);last_fold_max_us=fold_max_us;}
    }
    else if(native_clock_style==1){c6_render_style_t style=local_style();c6_renderer_round_clock(renderer(),&target,&style);calibrated_display();}
    else draw_flip_clock(&t);
    c6_clock_animation_commit(&clock_animation,frame_generation);
    clock_render_button=__atomic_load_n(&button_sequence,__ATOMIC_RELAXED);clock_render_key=__atomic_load_n(&key_request,__ATOMIC_RELAXED);
    __atomic_store_n(&clock_animation_active,clock_animation.active,__ATOMIC_RELAXED);
}
void standalone_apply(void) {
    terminal_last_activity=c6_seconds();terminal_manual_override=true;terminal_asleep=false;
    display_rotated=standalone_config.rotation==180;
    terminal_rotation=standalone_config.rotation;
    if(terminal_preview_page==TERMINAL_OVERVIEW_PAGE&&!terminal_overview_available(c6_overview_printer_count(&standalone_config)))terminal_preview_page=-1;
    if((terminal_preview_page==0&&!standalone_config.clock)||(terminal_preview_page==2&&!standalone_config.weather)||
       (terminal_preview_page==1&&!standalone_config.diagnostics)||
       (terminal_preview_page>=10&&terminal_preview_page<20&&
        (!standalone_config.ha_enabled||(unsigned)(terminal_preview_page-10)>=(standalone_config.entity_count+3)/4))||
       (terminal_preview_page>=20&&terminal_preview_page<30&&
        ((unsigned)(terminal_preview_page-20)>=standalone_config.printer_count||!standalone_config.printers[terminal_preview_page-20].enabled)))terminal_preview_page=-1;
    set_brightness(standalone_config.brightness);
    hybrid_page=-1;native_clock=false;last_clock_second=UINT32_MAX;page_since=0;local_page=0;
    c6_sources_reconfigure();
}
static unsigned local_pages(unsigned *pages,const c6_source_snapshot_t *s) {
    unsigned count=0;
    if(standalone_config.clock&&(standalone_config.card_mask&1))pages[count++]=0;
    if(!C6_FORMLABS_ONLY&&standalone_config.diagnostics&&(standalone_config.card_mask&2))pages[count++]=1;
    if(standalone_config.weather&&(standalone_config.card_mask&4))pages[count++]=2;
    if(!C6_FORMLABS_ONLY&&standalone_config.ha_enabled&&(standalone_config.card_mask&8))for(unsigned i=0;i<(standalone_config.entity_count+3)/4;i++)pages[count++]=10+i;
    for(unsigned i=0;i<standalone_config.printer_count;i++)if(standalone_config.printers[i].enabled&&standalone_config.printers[i].rotate&&(C6_FORMLABS_ONLY||c6_print_eligible(&s->printers[i],c6_seconds())))pages[count++]=20+i;
    if(terminal_overview_available(c6_overview_printer_count(&standalone_config)))pages[count++]=TERMINAL_OVERVIEW_PAGE;
    return count;
}
static bool base_software_allowed(void) {
    if(C6_FORMLABS_ONLY)return false;
    // Native preference is per card, not a veto on all computer-only content.
    return !c6_simulation_active(software_simulation_until,esp_timer_get_time());
}
static bool software_controls(void){
    if(C6_FORMLABS_ONLY)return false;
    return !c6_simulation_active(software_simulation_until,esp_timer_get_time())&&
        c6_software_wins(standalone_config.enabled,false,true,software_heartbeat,c6_seconds());
}
static bool software_allowed(void){char pin[5];return !network_notice&&!device_menu.depth&&!(terminal_preview_page>=0&&esp_timer_get_time()<terminal_preview_until)&&!standalone_pairing_pin(pin,NULL)&&base_software_allowed();}
#include "local_menu.h"
static void local_display(void *arg);
static esp_err_t software_handler(httpd_req_t *req) {
    if(req->content_len>0) {
        // Renewals remain backward compatible; only a paired client can release ownership.
        if(!standalone_authorized(req))return ESP_OK;
        if(req->content_len>=64)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid software action");
        char body[64]={0};int used=0;
        while(used<req->content_len){int n=httpd_req_recv(req,body+used,req->content_len-used);if(n<=0)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid software action");used+=n;}
        cJSON *j=cJSON_ParseWithOpts(body,NULL,true),*action=cJSON_GetObjectItemCaseSensitive(j,"action");
        bool release=cJSON_IsString(action)&&!strcmp(action->valuestring,"release");cJSON_Delete(j);
        if(!release)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid software action");
        hybrid_page=-1;software_heartbeat=0;software_visible=false;native_clock=false;software_simulation_until=0;
        if(standalone_config.enabled)set_brightness(standalone_config.brightness);
        page_since=0;local_page=0;last_clock_second=UINT32_MAX;
        // HTTP task also owns rendering: no cross-task framebuffer race.
        local_display(NULL);
        httpd_resp_set_type(req,"application/json");return httpd_resp_sendstr(req,"{\"released\":true}");
    }
    // A software lease carries no credentials. Only valid software frames/clock commands establish ownership.
    if(software_visible&&(software_allowed()||(device_menu.depth&&device_menu.software_owner&&base_software_allowed())))software_heartbeat=c6_seconds();
    httpd_resp_set_type(req,"application/json");return httpd_resp_sendstr(req,software_allowed()?"{\"accepts_software\":true}":"{\"accepts_software\":false}");
}
static void finish_pairing_display(bool waiting_frame) {
    char pin[5];
    if(!pairing_visible||standalone_pairing_pin(pin,NULL))return;
    pairing_visible=false;set_brightness(brightness);
    if(device_menu.depth)return;
    // The pairing image is not a valid software frame. Request a fresh frame
    // and do not extend the old software lease while showing stale content.
    revision=0;software_visible=false;software_heartbeat=0;last_clock_second=UINT32_MAX;
    if(waiting_frame) {
        memset(frame,0,FRAME_BYTES);
        if(!native_clock){c6_render_style_t style=local_style();c6_renderer_menu(renderer(),"等待显示",NULL,0,0,"等待软件推送最新画面",&style);calibrated_display();}
    }
}
static bool setup_display_notice(void){
    wifi_mode_t mode=WIFI_MODE_NULL;esp_wifi_get_mode(&mode);
    if(device_menu.depth)setup_notice_drawn=false;
    if(mode!=WIFI_MODE_APSTA||(__atomic_load_n(&station_has_credentials,__ATOMIC_RELAXED)&&!__atomic_load_n(&station_offline,__ATOMIC_RELAXED))||device_menu.depth)return false;
    if(!setup_notice_drawn){
        char ssid[40];wifi_config_t ap={0};esp_wifi_get_config(WIFI_IF_AP,&ap);snprintf(ssid,sizeof(ssid),"%s",ap.ap.ssid);
        char payload[80];snprintf(payload,sizeof(payload),"WIFI:T:nopass;S:%s;;",ssid);
        c6_render_style_t style=local_style();
        c6_renderer_setup_qr(renderer(),setup_qr_web?"http://192.168.4.1/":payload,setup_qr_web?"打开配网后台":"扫码连接热点",setup_qr_web?"192.168.4.1":ssid,"单击切换二维码 · 长按设置",&style);
        setup_notice_drawn=true;set_brightness(brightness);calibrated_display();
    }return true;
}
static void local_display(void *arg) {
    int64_t now=esp_timer_get_time();
    if(__atomic_exchange_n(&station_joined_pending,false,__ATOMIC_RELAXED)){
        wifi_mode_t mode;if(esp_wifi_get_mode(&mode)==ESP_OK&&mode==WIFI_MODE_APSTA){
            hotspot_close_at=now+(C6_FORMLABS_ONLY?12000000:5000000);network_notice=true;network_notice_drawn=false;native_clock=false;revision=0;
        }
        bool empty=standalone_config.printer_count==0&&!standalone_config.weather&&!(standalone_config.ha_enabled&&standalone_config.entity_count);
        if(!terminal_guide_offered&&empty){network_notice=true;network_notice_drawn=false;native_clock=false;revision=0;}
        terminal_guide_offered=true;terminal_guide_qr=true;terminal_guide_empty=empty;setup_notice_drawn=false;
        network_notice_drawn=false; // A DHCP address change must refresh the QR.
    }
    if(hotspot_close_at&&now>=hotspot_close_at){
        if(!__atomic_load_n(&station_offline,__ATOMIC_RELAXED)&&esp_wifi_set_mode(WIFI_MODE_STA)==ESP_OK){hotspot_close_at=0;printf("LINGXI_SETUP_AP=closed\n");}
        else hotspot_close_at=now+5000000;
    }
    if(network_notice&&terminal_guide_empty&&(standalone_config.printer_count>0||standalone_config.weather||(standalone_config.ha_enabled&&standalone_config.entity_count))){network_notice=false;network_notice_drawn=false;last_clock_second=UINT32_MAX;set_brightness(brightness);}
    if(setup_display_notice())return;
    if(network_notice&&!device_menu.depth){
        // Never leave a stale LAN QR on screen while Wi-Fi is disconnected.
        if(__atomic_load_n(&station_offline,__ATOMIC_RELAXED)||!strcmp(ip,"0.0.0.0")){
            if(network_notice_drawn){c6_render_menu_row_t rows[]={{local_label("尚未连接局域网"),local_label("连接同一 Wi-Fi")}};c6_render_style_t style=local_style();c6_renderer_menu(renderer(),local_label("网络"),rows,1,1,local_label("长按 BOOT 打开设置"),&style);calibrated_display();network_notice_drawn=false;}
            return;
        }
        if(!network_notice_drawn){
            c6_render_style_t style=local_style();
            if(terminal_guide_qr){char url[80];snprintf(url,sizeof(url),"http://%s/standalone#printers",ip);c6_renderer_setup_qr(renderer(),url,"联网成功 · 扫码设置",ip,"先切回同一 Wi-Fi · 单击指引",&style);}
            else{c6_render_menu_row_t rows[]={{local_label("1 手机切回同一 Wi-Fi"),ip},{local_label("2 扫码打开设备设置"),local_label("配置热点即将关闭")},{local_label(C6_FORMLABS_ONLY?"3 配置打印机与天气":"3 配置卡片与数据源"),local_label("在后台填写设备信息")}};
                c6_renderer_menu(renderer(),local_label("联网成功 · 接着配置"),rows,3,3,local_label("单击扫码 · 双击稍后配置"),&style);}
            set_brightness(brightness);calibrated_display();network_notice_drawn=true;
        }return;
    }
    if(menu_draft.dirty&&device_menu.depth&&now/1000-device_menu.touched>=30000&&device_menu.levels[0].view!=C6_MENU_SETTINGS&&!menu_save_draft()){device_menu.touched=now/1000;}
    if(c6_menu_timeout(&device_menu,now/1000))menu_return_to_card();
    if(device_menu.depth){menu_render();return;}
    char pin[5];int seconds;
    if(standalone_pairing_pin(pin,&seconds)) {
        if(!pairing_visible){pairing_visible=true;set_brightness(brightness);}
        c6_render_style_t style=local_style();c6_renderer_pairing(renderer(),pin,seconds,&style);
        calibrated_display();last_clock_second=UINT32_MAX;return;
    }
    finish_pairing_display(true);
    const c6_source_snapshot_t *sources=display_sources();unsigned pages[12];unsigned count=local_pages(pages,sources);
    bool coordinated=software_controls()&&!(terminal_preview_page>=0&&now<terminal_preview_until);
    if(coordinated) {
        if(hybrid_page<0){c6_sources_media_focus(-1,-1);draw_clock(NULL);return;}
        // One playlist owner while connected. Never run the standalone carousel
        // on top of a selected native replacement or a computer-only frame.
        pages[0]=(unsigned)hybrid_page;count=1;
    }else{
        hybrid_page=-1;
    }
    if(terminal_preview_page>=0&&now<terminal_preview_until){pages[0]=(unsigned)terminal_preview_page;count=1;local_page=0;}
    else terminal_preview_page=-1;
    // A local render invalidates the previous external frame, even if its revision was nonzero.
    if(!local_visible&&standalone_config.enabled)set_brightness(standalone_config.brightness);
    software_visible=coordinated;local_visible=true;
    if(!count){native_clock=false;c6_render_style_t style=local_style();c6_renderer_menu(renderer(),local_label("等待本地数据"),NULL,0,0,local_label("请在软件中选择显示卡片"),&style);calibrated_display();return;}
    if(!page_since){page_since=now;}
    if(!coordinated&&(local_step_pending||now-page_since>=(int64_t)standalone_config.interval*1000000)) {
        local_page=(local_page+(local_step_pending?local_step_pending:1))%count;local_step_pending=0;page_since=now;last_clock_second=UINT32_MAX;
    }
    local_page%=count;unsigned page=pages[local_page];bool clock_page=page==0;
    local_context=(c6_card_context_t){0};
    if(page==0)local_context.kind=C6_CARD_CLOCK;
    else if(page==1)local_context.kind=C6_CARD_DIAGNOSTICS;
    else if(page==TERMINAL_OVERVIEW_PAGE)local_context.kind=C6_CARD_OVERVIEW;
    else if(page==2)local_context.kind=C6_CARD_WEATHER;
    else if(page>=20&&page<30)menu_set_printer(&local_context,page-20);
    else if(page>=10&&page<20){local_context.kind=C6_CARD_HA;local_context.group=page-10;}
    if(page<10)c6_sources_media_focus(-1,-1);
    if(page==2){native_clock=false;draw_weather(sources);return;}
    if(page==TERMINAL_OVERVIEW_PAGE){native_clock=false;draw_printer_overview(sources);return;}
    if(page>=20){native_clock=false;draw_printer(page-20,sources);return;}
    if(page>=10){native_clock=false;draw_entity(page-10,sources);return;}
    if(clock_page) {
        time_t utc=time(NULL);
        if(utc>=1609459200) {
            if(native_clock_style!=standalone_config.clock_style)last_clock_second=UINT32_MAX;
            native_clock_style=standalone_config.clock_style;
            clock_epoch=utc;clock_anchor=now;clock_timezone=standalone_config.timezone;native_clock=true;draw_clock(NULL);return;
        }
    }
    native_clock=false;
    char memory[32];snprintf(memory,sizeof(memory),"%lu KB",(unsigned long)esp_get_free_heap_size()/1024);
    c6_render_menu_row_t rows[]={{local_label(clock_page?"时间同步":"可用内存"),clock_page?local_label("等待网络校时"):memory},{local_label("网络地址"),ip},{local_label("设备设置"),local_label("长按 BOOT 打开设置")}};
    c6_render_style_t style=local_style();
    c6_renderer_menu(renderer(),local_label(clock_page?"桌面时钟":"设备状态"),rows,3,3,local_label("单击翻页 · 双击详情 · 长按设置"),&style);calibrated_display();
}
static bool local_work_queued;
static esp_err_t native_card_handler(httpd_req_t *req){
    if(!standalone_authorized(req))return ESP_OK;
    if(!software_allowed()){httpd_resp_set_status(req,"204 No Content");return httpd_resp_send(req,NULL,0);}
    if(req->content_len)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"No body expected");
    char explicit_text[8],group_text[8];bool explicit_native=false;unsigned group=0;
    if(httpd_req_get_hdr_value_len(req,"X-Lingxi-Native")){
        if(httpd_req_get_hdr_value_str(req,"X-Lingxi-Native",explicit_text,sizeof(explicit_text))!=ESP_OK||strcmp(explicit_text,"1"))
            return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid native selection");
        explicit_native=true;
    }
    if(httpd_req_get_hdr_value_len(req,"X-Lingxi-Group")){
        if(httpd_req_get_hdr_value_str(req,"X-Lingxi-Group",group_text,sizeof(group_text))!=ESP_OK||!*group_text)
            return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid native group");
        for(const char *p=group_text;*p;p++)if(*p<'0'||*p>'9')return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid native group");
        group=(unsigned)strtoul(group_text,NULL,10);
    }
    if(httpd_req_get_hdr_value_len(req,"X-Lingxi-Origin")>=sizeof(software_context.origin))
        return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid native origin");
    c6_card_context_t previous=software_context;menu_frame_context(req);
    const char *kind=software_context.kind==C6_CARD_WEATHER?"weather":software_context.kind==C6_CARD_HA?"ha":software_context.kind==C6_CARD_PRINTER?"printer":software_context.kind==C6_CARD_CLOCK?"clock":software_context.kind==C6_CARD_DIAGNOSTICS?"diagnostics":software_context.kind==C6_CARD_OVERVIEW?"overview":"generic";
    int target=c6_native_target(&standalone_config,kind,software_context.serial,software_context.brand,software_context.source,software_context.origin,group,explicit_native);
    // Replacement requests keep a valid Mac weather image until local data is
    // available. An explicit local card instead shows its native loading state.
    if(!explicit_native&&target==2&&!c6_sources_weather_available())target=-1;
    if(target<0){software_context=previous;httpd_resp_set_status(req,"404 Not Found");return httpd_resp_sendstr(req,"No matching native card");}
    if(target==10&&!explicit_native){
        unsigned groups=(standalone_config.entity_count+3)/4;
        target=hybrid_page>=10&&hybrid_page<20?hybrid_page:10+(int)(hybrid_ha_next++%groups);
        if((unsigned)(target-10)>=groups)target=10;
        software_context.group=(unsigned)(target-10);
    }
    if(target>=10&&target<20)software_context.group=(unsigned)(target-10);
    if(hybrid_page!=target){last_clock_second=UINT32_MAX;page_since=esp_timer_get_time();revision=0;}
    hybrid_page=target;software_visible=true;software_heartbeat=c6_seconds();local_step_pending=0;local_page=0;
    if(!terminal_asleep)local_display(NULL);
    httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_sendstr(req,"{\"native\":true}");
}
static esp_err_t simulation_handler(httpd_req_t *req) {
    if(!standalone_authorized(req))return ESP_OK;
    char body[64];
    if(req->content_len<=0||req->content_len>=sizeof(body))return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid simulation request");
    size_t count=0;
    while(count<(size_t)req->content_len){int n=httpd_req_recv(req,body+count,req->content_len-count);if(n<=0)return ESP_FAIL;count+=n;}
    body[count]=0;cJSON *json=cJSON_Parse(body);
    cJSON *enabled=json?cJSON_GetObjectItemCaseSensitive(json,"enabled"):NULL;
    if(!cJSON_IsBool(enabled)){cJSON_Delete(json);return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Expected enabled boolean");}
    bool simulate=cJSON_IsTrue(enabled);cJSON_Delete(json);
    if(simulate){
        const c6_source_snapshot_t *sources=display_sources();unsigned pages[12];
        if(!standalone_config.enabled||!local_pages(pages,sources)){
            httpd_resp_set_status(req,"409 Conflict");return httpd_resp_sendstr(req,"Enable and configure local cards first");
        }
    }
    bool was_active=c6_simulation_active(software_simulation_until,esp_timer_get_time());
    software_simulation_until=c6_simulation_deadline(simulate,esp_timer_get_time());
    if(simulate&&!was_active){
        software_heartbeat=0;software_visible=false;native_clock=false;
        last_clock_second=UINT32_MAX;page_since=0;local_visible=true;revision=0;
        local_display(NULL);
    }
    httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_sendstr(req,simulate?"{\"enabled\":true}":"{\"enabled\":false}");
}
static esp_err_t preview_frame_handler(httpd_req_t *req) {
    if(!standalone_authorized(req))return ESP_OK;
    httpd_resp_set_hdr(req,"Cache-Control","no-store");
    if(!frame_valid){httpd_resp_set_status(req,"503 Service Unavailable");return httpd_resp_sendstr(req,"Complete display frame unavailable");}
    // ESP-IDF retains header pointers until send; each value needs its own
    // storage. Reusing a buffer corrupts both revision and rotation headers.
    char value[24],query[64],revision_text[24],rotation_text[12];
    snprintf(revision_text,sizeof(revision_text),"%lu",(unsigned long)frame_generation);
    httpd_resp_set_hdr(req,"X-Lingxi-Frame-Revision",revision_text);
    snprintf(rotation_text,sizeof(rotation_text),"%d",terminal_rotation);httpd_resp_set_hdr(req,"X-Lingxi-Rotation",rotation_text);
    httpd_resp_set_hdr(req,"X-Lingxi-Asleep",terminal_asleep?"1":"0");
    if(httpd_req_get_url_query_str(req,query,sizeof(query))==ESP_OK&&httpd_query_key_value(query,"rev",value,sizeof(value))==ESP_OK){
        if(!strcmp(value,revision_text)){httpd_resp_set_status(req,"204 No Content");return httpd_resp_send(req,NULL,0);}
    }
    // HTTP and LCD share one owner: the buffer is canonical and immutable for
    // the entire response. Reading it neither renews a lease nor changes mode.
    httpd_resp_set_type(req,"application/x-rgb565");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    return httpd_resp_send(req,(const char*)frame,FRAME_BYTES);
}
static void terminal_wake(bool manual){
    terminal_last_activity=c6_seconds();terminal_manual_override=manual;
    if(terminal_asleep){terminal_asleep=false;set_brightness(brightness);last_clock_second=UINT32_MAX;page_since=0;}
}
static bool terminal_sleep_tick(void){
    bool printing=false;const c6_source_snapshot_t *s=display_sources();
    for(unsigned i=0;i<standalone_config.printer_count;i++)if(standalone_config.printers[i].enabled&&!c6_form_is_demo(&standalone_config.printers[i])&&s->printers[i].connected&&c6_print_active(s->printers[i].status))printing=true;
    time_t utc=time(NULL);int minute=-1;if(utc>=1609459200){time_t local=utc+standalone_config.timezone;struct tm t;gmtime_r(&local,&t);minute=t.tm_hour*60+t.tm_min;}
    bool asleep=terminal_should_sleep(standalone_config.sleep_mode,standalone_config.sleep_idle_minutes,standalone_config.sleep_start,standalone_config.sleep_end,
        standalone_config.sleep_keep_printing,printing,device_menu.depth!=0||network_notice||setup_notice_drawn||__atomic_load_n(&station_joined_pending,__ATOMIC_RELAXED)||hotspot_close_at!=0,c6_seconds(),terminal_last_activity,terminal_manual_override,minute);
    if(asleep!=terminal_asleep){terminal_asleep=asleep;set_brightness(brightness);last_clock_second=UINT32_MAX;page_since=0;}
    return asleep;
}
static esp_err_t terminal_view_handler(httpd_req_t *req){
    if(!standalone_authorized(req))return ESP_OK;
    if(device_menu.depth){httpd_resp_set_status(req,"409 Conflict");return httpd_resp_sendstr(req,"Close device settings before changing the displayed card");}
    char query[64],card[16],index[8];int page=-1;
    if(req->content_len||httpd_req_get_url_query_str(req,query,sizeof(query))!=ESP_OK||httpd_query_key_value(query,"card",card,sizeof(card))!=ESP_OK)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid view");
    if(!strcmp(card,"clock")&&standalone_config.clock)page=0;
    else if(!strcmp(card,"overview")&&terminal_overview_available(c6_overview_printer_count(&standalone_config)))page=TERMINAL_OVERVIEW_PAGE;
    else if(!strcmp(card,"weather")&&standalone_config.weather)page=2;
    else if(!strcmp(card,"printer")&&httpd_query_key_value(query,"index",index,sizeof(index))==ESP_OK&&strlen(index)==1&&index[0]>='0'&&index[0]<='2'){
        unsigned i=index[0]-'0';if(i<standalone_config.printer_count&&standalone_config.printers[i].enabled)page=20+(int)i;
    }else if(!strcmp(card,"ha")&&!C6_FORMLABS_ONLY&&standalone_config.ha_enabled&&standalone_config.entity_count&&httpd_query_key_value(query,"index",index,sizeof(index))==ESP_OK&&strlen(index)==1&&index[0]>='0'&&index[0]<='1'){
        unsigned i=index[0]-'0';if(i<(standalone_config.entity_count+3)/4)page=10+(int)i;
    }else if(!strcmp(card,"diagnostics")&&!C6_FORMLABS_ONLY&&standalone_config.diagnostics)page=1;
    else if(!strcmp(card,"auto"))page=-1;
    if(page<0&&strcmp(card,"auto")){httpd_resp_set_status(req,"409 Conflict");return httpd_resp_sendstr(req,"Card is not configured");}
    terminal_wake(true);terminal_preview_page=page;terminal_preview_until=esp_timer_get_time()+90000000;
    network_notice=false;network_notice_drawn=false;last_clock_second=UINT32_MAX;page_since=0;local_page=0;frame_generation++;
    local_display(NULL);httpd_resp_set_type(req,"application/json");return httpd_resp_sendstr(req,"{\"ok\":true,\"hold_seconds\":90}");
}
static void local_display_work(void *arg){
    c6_queued_gesture_t gesture;
    while(xQueueReceive(gesture_queue,&gesture,0)==pdTRUE){
        // A blocked HTTP upload must not replay stale presses on recovery.
        if(esp_timer_get_time()/1000-gesture.time<2000){
            bool waking=terminal_asleep;terminal_wake(true);terminal_preview_page=-1;
            if(waking)continue; // First gesture wakes only; never toggles a setting.
            wifi_mode_t mode=WIFI_MODE_NULL;esp_wifi_get_mode(&mode);
            if(!device_menu.depth&&mode==WIFI_MODE_APSTA&&(!__atomic_load_n(&station_has_credentials,__ATOMIC_RELAXED)||__atomic_load_n(&station_offline,__ATOMIC_RELAXED))&&gesture.event==C6_BUTTON_SINGLE){setup_qr_web=!setup_qr_web;setup_notice_drawn=false;view_revision++;continue;}
            if(network_notice){
                if(gesture.event==C6_BUTTON_SINGLE){terminal_guide_qr=!terminal_guide_qr;network_notice_drawn=false;view_revision++;continue;}
                network_notice=false;network_notice_drawn=false;revision=0;last_clock_second=UINT32_MAX;page_since=0;view_revision++;
                set_brightness(brightness);
                if(gesture.event==C6_BUTTON_DOUBLE)continue;
            }
            menu_gesture(gesture.event);
            // No PIN/SSID/credentials in diagnostics. Useful for real-button
            // verification without exposing a network gesture-injection API.
            printf("LINGXI_BOOT_GESTURE=%u MENU_DEPTH=%u STACK_FREE_MIN=%lu\n",(unsigned)gesture.event,device_menu.depth,(unsigned long)uxTaskGetStackHighWaterMark(NULL));
        }
    }
    if(terminal_sleep_tick()){
        __atomic_store_n(&clock_animation_active,false,__ATOMIC_RELAXED);c6_clock_animation_cancel(&clock_animation);
        __atomic_store_n(&local_work_queued,false,__ATOMIC_RELAXED);return;
    }
    bool animation_tick=arg!=NULL&&native_clock&&!pairing_visible&&!device_menu.depth&&
        clock_render_button==__atomic_load_n(&button_sequence,__ATOMIC_RELAXED)&&
        clock_render_key==__atomic_load_n(&key_request,__ATOMIC_RELAXED);
    if(animation_tick)draw_clock(NULL);else local_display(NULL);
    if(!native_clock||pairing_visible||device_menu.depth){
        __atomic_store_n(&clock_animation_active,false,__ATOMIC_RELAXED);
        c6_clock_animation_cancel(&clock_animation);
    }
    __atomic_store_n(&local_work_queued,false,__ATOMIC_RELAXED);
}
static void clock_task(void *arg) {
    int64_t last_full_work=0;
    for(;;){
        int64_t now=esp_timer_get_time();bool full=now-last_full_work>=1000000||uxQueueMessagesWaiting(gesture_queue)>0;
        bool active=__atomic_load_n(&clock_animation_active,__ATOMIC_RELAXED);
        if(http_server&&(full||active)&&!__atomic_exchange_n(&local_work_queued,true,__ATOMIC_RELAXED)){
            if(httpd_queue_work(http_server,local_display_work,full?NULL:(void*)1)!=ESP_OK)__atomic_store_n(&local_work_queued,false,__ATOMIC_RELAXED);
            else if(full)last_full_work=now;
        }
        // The display owner wakes this task on a minute transition. Idle cards
        // Remain 1Hz when idle; the profile bounds fold duration and cadence.
        ulTaskNotifyTake(pdTRUE,pdMS_TO_TICKS(active?C6_CLOCK_FRAME_MS:1000));
    }
}
static bool query_number(const char *query,const char *key,long *value) {
    char text[24],*end;
    if(httpd_query_key_value(query,key,text,sizeof(text))!=ESP_OK)return false;
    *value=strtol(text,&end,10);return end!=text&&!*end;
}
static esp_err_t clock_handler(httpd_req_t *req) {
#if C6_FORMLABS_ONLY
    return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Use native clock settings");
#endif
    if(device_menu.depth){httpd_resp_set_status(req,"204 No Content");return httpd_resp_send(req,NULL,0);}
    if(c6_simulation_active(software_simulation_until,esp_timer_get_time())){httpd_resp_set_status(req,"204 No Content");return httpd_resp_send(req,NULL,0);}
    char query[160];long enabled,epoch,tz,rotation=terminal_rotation,clock_style=0;
    if(httpd_req_get_url_query_str(req,query,sizeof(query))!=ESP_OK||!query_number(query,"enabled",&enabled))
        return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Missing enabled");
    // Version 2 playlist clocks belong to the device. A compatibility stop or
    // stale style push must not disable/change that selected native card.
    bool device_clock_selected=hybrid_page==0&&software_visible;
    if(enabled==0){if(!device_clock_selected)native_clock=false;finish_pairing_display(true);return httpd_resp_sendstr(req,"OK");}
    if(!software_allowed()){httpd_resp_set_status(req,"204 No Content");return httpd_resp_send(req,NULL,0);}
    if(enabled!=1||!query_number(query,"epoch",&epoch)||epoch<1609459200||epoch>2147483647L||
       !query_number(query,"tz",&tz)||tz< -43200||tz>50400)
        return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid clock time");
    query_number(query,"rotation",&rotation);
    if(rotation<0||rotation>270||!terminal_rotation_valid((int)rotation))return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid rotation");
    char style_text[24];
    if(httpd_query_key_value(query,"clock_style",style_text,sizeof(style_text))==ESP_OK&&
       (!query_number(query,"clock_style",&clock_style)||clock_style<0||clock_style>1))
        return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid clock style");
    finish_pairing_display(false);
    if(device_clock_selected){
        clock_epoch=epoch;clock_anchor=esp_timer_get_time();clock_timezone=standalone_config.timezone;
        native_clock_style=standalone_config.clock_style;software_heartbeat=c6_seconds();
        native_clock=true;last_clock_second=UINT32_MAX;if(!terminal_asleep)draw_clock(NULL);return httpd_resp_sendstr(req,"OK");
    }
    clock_epoch=epoch;clock_timezone=tz;clock_anchor=esp_timer_get_time();terminal_rotation=(int)rotation;display_rotated=rotation==180;
    hybrid_page=-1;software_visible=true;local_visible=false;software_heartbeat=c6_seconds();
    native_clock_style=(int)clock_style;
    native_clock=true;last_clock_second=UINT32_MAX;draw_clock(NULL);return httpd_resp_sendstr(req,"OK");
}
static void init_lcd(void) {
    gpio_set_direction(15, GPIO_MODE_OUTPUT);
    gpio_set_direction(21, GPIO_MODE_OUTPUT);
    gpio_set_level(21, 0); vTaskDelay(pdMS_TO_TICKS(50));
    gpio_set_level(21, 1); vTaskDelay(pdMS_TO_TICKS(120));
    spi_bus_config_t bus = {.mosi_io_num=6, .miso_io_num=-1, .sclk_io_num=7,
        .quadwp_io_num=-1, .quadhd_io_num=-1, .max_transfer_sz=4096};
    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO));
    spi_device_interface_config_t dev = {.clock_speed_hz=40000000, .mode=0,
        .spics_io_num=14, .queue_size=1};
    ESP_ERROR_CHECK(spi_bus_add_device(SPI2_HOST, &dev, &lcd));
    command(0x11, NULL, 0); vTaskDelay(pdMS_TO_TICKS(120));
    command(0x36, (uint8_t[]){0x00}, 1);
    command(0x3a, (uint8_t[]){0x05}, 1);
    command(0xb0, (uint8_t[]){0x00,0xe8}, 2);
    command(0xb2, (uint8_t[]){0x0c,0x0c,0x00,0x33,0x33}, 5);
    command(0xb7, (uint8_t[]){0x35}, 1);
    command(0xbb, (uint8_t[]){0x35}, 1);
    command(0xc0, (uint8_t[]){0x2c}, 1);
    command(0xc2, (uint8_t[]){0x01}, 1);
    command(0xc3, (uint8_t[]){0x13}, 1);
    command(0xc4, (uint8_t[]){0x20}, 1);
    command(0xc6, (uint8_t[]){0x0f}, 1);
    command(0xd0, (uint8_t[]){0xa4,0xa1}, 2);
    command(0xd6, (uint8_t[]){0xa1}, 1);
    command(0xe0, (uint8_t[]){0xf0,0,4,4,4,5,0x29,0x33,0x3e,0x38,0x12,0x12,0x28,0x30},14);
    command(0xe1, (uint8_t[]){0xf0,7,0x0a,0x0d,0x0b,7,0x28,0x33,0x3e,0x36,0x14,0x14,0x29,0x32},14);
    command(0x21, NULL, 0); command(0x29, NULL, 0);
    ledc_timer_config_t timer = {.speed_mode=LEDC_LOW_SPEED_MODE,
        .duty_resolution=LEDC_TIMER_10_BIT,.timer_num=LEDC_TIMER_0,.freq_hz=1000,.clk_cfg=LEDC_AUTO_CLK};
    ESP_ERROR_CHECK(ledc_timer_config(&timer));
    ledc_channel_config_t channel = {.gpio_num=22,.speed_mode=LEDC_LOW_SPEED_MODE,
        .channel=LEDC_CHANNEL_0,.timer_sel=LEDC_TIMER_0,.duty=0};
    ESP_ERROR_CHECK(ledc_channel_config(&channel));
    // Boot diagnostic: RGB bars. Replaced only after a complete valid frame arrives.
    for (int y=0;y<240;y++) for (int x=0;x<240;x++) {
        uint16_t color = x<80 ? 0xf800 : x<160 ? 0x07e0 : 0x001f;
        frame[(y*240+x)*2]=color>>8; frame[(y*240+x)*2+1]=color;
    }
    display_frame(); set_brightness(80);
}
static bool reset_station_wifi(void){
    // Physical confirmation only. Never erase the NVS partition or auth/config namespaces.
    const esp_partition_t *part=esp_partition_find_first(ESP_PARTITION_TYPE_DATA,(esp_partition_subtype_t)0x40,"lx_wifi");
    if(!part||part->address!=C6_WIFI_PROVISION_OFFSET||part->size!=C6_WIFI_PROVISION_SECTOR_BYTES||esp_partition_erase_range(part,0,C6_WIFI_PROVISION_SECTOR_BYTES)!=ESP_OK)return false;
    wifi_config_t empty={0};
    bool had=__atomic_exchange_n(&station_has_credentials,false,__ATOMIC_RELAXED);
    esp_wifi_disconnect();
    if(esp_wifi_set_config(WIFI_IF_STA,&empty)!=ESP_OK){__atomic_store_n(&station_has_credentials,had,__ATOMIC_RELAXED);if(had)esp_wifi_connect();return false;}
    strcpy(ip,"0.0.0.0");__atomic_store_n(&station_offline,true,__ATOMIC_RELAXED);
    terminal_guide_offered=false;setup_notice_drawn=false;setup_qr_web=false;network_notice=false;hotspot_close_at=0;
    return esp_wifi_set_mode(WIFI_MODE_APSTA)==ESP_OK;
}
static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START && __atomic_load_n(&station_has_credentials,__ATOMIC_RELAXED)) esp_wifi_connect();
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        strcpy(ip,"0.0.0.0");
        if(retries<5)retries++;
        __atomic_store_n(&reconnect_at,(uint32_t)(esp_timer_get_time()/1000)+(1U<<retries)*1000,__ATOMIC_RELAXED);
        __atomic_store_n(&station_offline,true,__ATOMIC_RELAXED);
    }
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event=data;
        snprintf(ip,sizeof(ip),IPSTR,IP2STR(&event->ip_info.ip)); retries=0;
        __atomic_store_n(&station_offline,false,__ATOMIC_RELAXED);
        printf("LINGXI_IP=%s\n",ip);
        __atomic_store_n(&station_joined_pending,true,__ATOMIC_RELAXED);
    }
}
bool standalone_lan_pairing_allowed(httpd_req_t *req){
    char header[80];if(httpd_req_get_hdr_value_str(req,"X-Lingxi-LAN",header,sizeof(header))!=ESP_OK||strcmp(header,"1"))return false;
    if(httpd_req_get_hdr_value_str(req,"Host",header,sizeof(header))!=ESP_OK)return false;
    char *port=strchr(header,':');if(port){if(strcmp(port,":80"))return false;*port=0;}
    char mdns[48];snprintf(mdns,sizeof(mdns),"%s.local",hostname);
    if(strcmp(header,ip)&&strcmp(header,hostname)&&strcmp(header,mdns))return false;
    struct sockaddr_storage peer={0},local={0};uint32_t peer_ipv4,local_ipv4;
    socklen_t size=sizeof(peer);int fd=httpd_req_to_sockfd(req);
    if(getpeername(fd,(struct sockaddr*)&peer,&size)!=0||!c6_sockaddr_ipv4(&peer,size,&peer_ipv4))return false;
    size=sizeof(local);if(getsockname(fd,(struct sockaddr*)&local,&size)!=0||!c6_sockaddr_ipv4(&local,size,&local_ipv4))return false;
    esp_netif_ip_info_t info;wifi_mode_t mode;
    if(esp_netif_get_ip_info(station,&info)!=ESP_OK||esp_wifi_get_mode(&mode)!=ESP_OK||local_ipv4!=info.ip.addr)return false;
    return c6_lan_peer(ntohl(peer_ipv4),ntohl(info.ip.addr),ntohl(info.netmask.addr),mode!=WIFI_MODE_STA);
}
static void reconnect_task(void *arg) {
    for(;;) {
        uint32_t now=(uint32_t)(esp_timer_get_time()/1000);
        if(__atomic_load_n(&station_has_credentials,__ATOMIC_RELAXED)&&__atomic_load_n(&station_offline,__ATOMIC_RELAXED)&&(int32_t)(now-__atomic_load_n(&reconnect_at,__ATOMIC_RELAXED))>=0) {
            __atomic_store_n(&reconnect_at,now+32000,__ATOMIC_RELAXED);
            esp_wifi_connect();
        }
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
static void import_wifi_provision(void) {
    const esp_partition_t *part=esp_partition_find_first(ESP_PARTITION_TYPE_DATA,(esp_partition_subtype_t)0x40,"lx_wifi");
    if(!part||part->address!=C6_WIFI_PROVISION_OFFSET||part->size!=C6_WIFI_PROVISION_SECTOR_BYTES)return;
    uint8_t record[C6_WIFI_PROVISION_RECORD_BYTES];c6_wifi_credentials_t credentials;
    if(esp_partition_read(part,0,record,sizeof(record))!=ESP_OK)return;
    bool empty=true;for(unsigned i=0;i<sizeof(record);i++)empty&=record[i]==0xff;
    if(empty)return;
    if(!c6_wifi_provision_parse(record,sizeof(record),&credentials)) {
        memset(record,0,sizeof(record));printf("LINGXI_WIFI_PROVISION=invalid\n");return;
    }
    wifi_config_t cfg={0};memcpy(cfg.sta.ssid,credentials.ssid,credentials.ssid_len);memcpy(cfg.sta.password,credentials.password,credentials.password_len);
    // Only Wi-Fi's own NVS namespace is modified; pairing/local config survive.
    esp_err_t result=esp_wifi_set_config(WIFI_IF_STA,&cfg);
    memset(record,0,sizeof(record));memset(&credentials,0,sizeof(credentials));memset(&cfg,0,sizeof(cfg));
    if(result!=ESP_OK){printf("LINGXI_WIFI_PROVISION=retry\n");return;}
    result=esp_partition_erase_range(part,0,C6_WIFI_PROVISION_SECTOR_BYTES);
    printf("LINGXI_WIFI_PROVISION=%s\n",result==ESP_OK?"applied":"erase_retry");
}
static esp_err_t info_handler(httpd_req_t *req) {
    char json[2048];
#if C6_FORMLABS_ONLY
    wifi_mode_t setup_mode=WIFI_MODE_NULL;esp_wifi_get_mode(&setup_mode);
    snprintf(json,sizeof(json),"{\"device\":\"" C6_DEVICE_ID "\",\"fw\":\"" C6_FIRMWARE_VERSION "\",\"profile\":\"formlabs-only\",\"max_printers\":3,\"standalone_api\":{\"path\":\"/api/standalone\",\"schema_version\":2,\"ha\":false,\"bambu\":false,\"formlabs\":true,\"media\":true},\"pairing_api\":{\"path\":\"/api/pair\",\"pin_digits\":0,\"mode\":\"lan\"},\"rotation_api\":{\"path\":\"/api/rotation\",\"device_rendered\":true},\"rotation\":%d,\"ota_api\":\"/api/ota\",\"accepts_software\":false,\"hostname\":\"%s\",\"ip\":\"%s\",\"screen\":{\"width\":240,\"height\":240},\"mode\":\"%s\",\"brightness\":%d,\"clock_animation\":{\"target_fps\":30,\"duration_ms\":720,\"partial_refresh\":true}}",
        terminal_rotation,hostname,ip,device_menu.depth?"menu":"standalone",brightness);
    size_t used=strlen(json);snprintf(json+used-1,sizeof(json)-used+1,",\"product_name\":\"XH Multiscreen\",\"model\":\"Form Monitor C6\",\"revision\":%d,\"language\":%d,\"asleep\":%s,\"rotation_steps\":[0,90,180,270],\"wifi_connected\":%s,\"setup_ap\":%s,\"needs_printer_setup\":%s,\"setup_path\":\"/standalone#printers\",\"clock_metrics\":{\"last_fold_frames\":%u,\"last_fold_ms\":%u,\"max_render_display_us\":%u}}",standalone_config.revision,standalone_config.language,terminal_asleep?"true":"false",strcmp(ip,"0.0.0.0")?"true":"false",setup_mode==WIFI_MODE_APSTA?"true":"false",standalone_config.printer_count?"false":"true",last_fold_frames,last_fold_ms,last_fold_max_us);
#else
    snprintf(json,sizeof(json),"{\"device\":\"lingxi-esp32-c6-screen\",\"fw\":\"" C6_FIRMWARE_VERSION "\",\"standalone_api\":{\"path\":\"/api/standalone\",\"schema_version\":2,\"ha\":true,\"bambu\":true,\"formlabs\":true,\"media\":true},\"pairing_api\":{\"path\":\"/api/pair\",\"pin_digits\":0,\"mode\":\"lan\"},\"rotation_api\":{\"path\":\"/api/rotation\",\"device_rendered\":true},\"rotation\":%d,\"ota_api\":\"/api/ota\",\"software_lease_api\":\"/api/software\",\"accepts_software\":%s,\"button_api\":\"/api/button\",\"native_clock_api\":{\"path\":\"/api/clock\",\"device_rendered\":true,\"supports_rotation\":true,\"styles\":[0,1],\"style\":%d},\"hostname\":\"%s\",\"ip\":\"%s\",\"screen\":{\"width\":240,\"height\":240},\"mode\":\"%s\",\"brightness\":%d,\"image_api\":{\"frame_rev\":%lu},\"rgb565_api\":{\"path\":\"/image/rgb565\",\"content_type\":\"application/x-rgb565\",\"byte_order\":\"big-endian\",\"bytes\":115200}}",
        terminal_rotation,software_allowed()?"true":"false",native_clock_style,hostname,ip,device_menu.depth?"menu":local_visible?"standalone":native_clock?"clock":revision?"external":"none",brightness,(unsigned long)revision);
    // Additive schema/capabilities: old readers can ignore these fields. No
    // credentials or network tokens are exposed by discovery.
    size_t used=strlen(json);if(used&&used+850<sizeof(json))snprintf(json+used-1,sizeof(json)-used+1,",\"interaction_protocol\":2,\"menu_active\":%s,\"view_revision\":%lu,\"native_card_api\":{\"path\":\"/api/card\",\"version\":2,\"explicit_native\":true,\"prefer_native\":%s},\"product_name\":\"XH Multiscreen\",\"model\":\"C6 Multiscreen\",\"revision\":%d,\"language\":%d,\"digit_style\":%d,\"asleep\":%s,\"ui_options\":true,\"rotations\":[0,90,180,270],\"rotation_steps\":[0,90,180,270],\"languages\":[0,1],\"digit_styles\":[0,1],\"sleep_modes\":[0,1,2],\"printer_card_styles\":[0,1,2],\"printer_overview\":true,\"preview_api\":\"/api/frame\",\"view_api\":\"/api/view\"}",device_menu.depth?"true":"false",(unsigned long)view_revision,standalone_config.enabled&&standalone_config.local_first?"true":"false",standalone_config.revision,standalone_config.language,standalone_config.digit_style,terminal_asleep?"true":"false");
#endif
    httpd_resp_set_type(req,"application/json"); return httpd_resp_sendstr(req,json);
}
static esp_err_t frame_handler(httpd_req_t *req) {
    if(!software_allowed()){httpd_resp_set_status(req,"204 No Content");httpd_resp_set_hdr(req,"Connection","close");return httpd_resp_send(req,NULL,0);}
    if (req->content_len != FRAME_BYTES) return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Expected 115200 bytes");
    // Even a later failed upload mutates the canonical buffer. Invalidate the
    // local-card cache before receiving the first byte, without another buffer.
    frame_generation++;frame_valid=false;
    size_t received=0;
    while(received<FRAME_BYTES) {
        int n=httpd_req_recv(req,(char*)frame+received,FRAME_BYTES-received);
        if(n<=0){
            // The LCD still has the old image, but RAM no longer does. Retire
            // the external lease and repaint from local data, never publish
            // or rotate the damaged buffer. Sleep remains untouched.
            software_heartbeat=0;software_visible=false;local_visible=false;
            hybrid_page=-1;native_clock=false;last_clock_second=UINT32_MAX;page_since=0;revision=0;
            setup_notice_drawn=false;network_notice_drawn=false;
            c6_clock_animation_cancel(&clock_animation);
            if(!terminal_asleep)local_display(NULL);
            return ESP_FAIL;
        }
        received+=n;
    }
    // Finish only after a complete replacement frame, never clear that frame.
    finish_pairing_display(false);
    menu_frame_context(req);
    hybrid_page=-1;native_clock=false;software_visible=true;local_visible=false;software_heartbeat=c6_seconds();display_frame(); revision++;
    return httpd_resp_sendstr(req,"OK");
}
static esp_err_t brightness_handler(httpd_req_t *req) {
    char query[64],value[16],*end;
    if(httpd_req_get_url_query_str(req,query,sizeof(query))!=ESP_OK ||
       httpd_query_key_value(query,"level",value,sizeof(value))!=ESP_OK)
        return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Missing level");
    long level=strtol(value,&end,10);
    if(end==value || *end || level<0 || level>100)
        return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid level");
    set_brightness(level); return httpd_resp_sendstr(req,"OK");
}
static esp_err_t rotation_handler(httpd_req_t *req) {
#if C6_FORMLABS_ONLY
    if(!standalone_authorized(req))return ESP_OK;
#endif
    char query[40];long rotation;
    if(httpd_req_get_url_query_str(req,query,sizeof(query))!=ESP_OK||!query_number(query,"rotation",&rotation)||rotation<0||rotation>270||!terminal_rotation_valid((int)rotation))return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Expected rotation 0, 90, 180 or 270");
    if(terminal_rotation!=rotation){terminal_rotation=(int)rotation;display_rotated=rotation==180;
        if(frame_valid)display_frame();else{last_clock_second=UINT32_MAX;page_since=0;if(!terminal_asleep)local_display(NULL);}}
    // Runtime screen control only. Persisted settings use authenticated config sync.
    return httpd_resp_sendstr(req,"OK");
}
#if C6_FORMLABS_ONLY
#include "formlabs_wifi_portal.h"
#else
#include "wifi_portal.h"
#endif
// Captive discovery is confined to the physical setup AP. Never intercept LAN
// 404s or return an Internet-success probe; no HTTPS interception.
#if C6_FORMLABS_ONLY
static bool setup_request(httpd_req_t *req){
    wifi_mode_t mode;esp_netif_ip_info_t info;
    if(esp_wifi_get_mode(&mode)!=ESP_OK||mode!=WIFI_MODE_APSTA||esp_netif_get_ip_info(setup_ap,&info)!=ESP_OK)return false;
    struct sockaddr_storage peer={0},local={0};socklen_t size=sizeof(local);uint32_t local4,peer4;int fd=httpd_req_to_sockfd(req);
    if(getsockname(fd,(struct sockaddr*)&local,&size)||!c6_sockaddr_ipv4(&local,size,&local4)||local4!=info.ip.addr)return false;
    size=sizeof(peer);return !getpeername(fd,(struct sockaddr*)&peer,&size)&&c6_sockaddr_ipv4(&peer,size,&peer4)&&peer4!=info.ip.addr&&(peer4&info.netmask.addr)==(info.ip.addr&info.netmask.addr);
}
static esp_err_t captive_redirect(httpd_req_t *req,httpd_err_code_t error){
    (void)error;if(req->method!=HTTP_GET||!setup_request(req))return httpd_resp_send_err(req,HTTPD_404_NOT_FOUND,"Not found");
    httpd_resp_set_status(req,"302 Found");httpd_resp_set_hdr(req,"Location","http://192.168.4.1/");httpd_resp_set_hdr(req,"Cache-Control","no-store");return httpd_resp_sendstr(req,"Open http://192.168.4.1/ to configure Wi-Fi");
}
#endif
static esp_err_t root_handler(httpd_req_t *req) {
#if C6_FORMLABS_ONLY
    char host[80];if(setup_request(req)&&(httpd_req_get_hdr_value_str(req,"Host",host,sizeof(host))!=ESP_OK||(strcmp(host,"192.168.4.1")&&strcmp(host,"192.168.4.1:80"))))return captive_redirect(req,HTTPD_404_NOT_FOUND);
#endif
    httpd_resp_set_type(req,"text/html; charset=utf-8");
    httpd_resp_set_hdr(req,"Cache-Control","no-store");
#ifdef C6_PORTAL_GZIP
    httpd_resp_set_hdr(req,"Content-Encoding","gzip");return httpd_resp_send(req,(const char*)portal,sizeof(portal));
#else
    return httpd_resp_sendstr(req,portal);
#endif
}
#if C6_FORMLABS_ONLY
#include "formlabs_language.h"
#endif
static int hex(char c) {
    if(c>='0'&&c<='9') return c-'0';
    if(c>='a'&&c<='f') return c-'a'+10;
    if(c>='A'&&c<='F') return c-'A'+10;
    return -1;
}
static bool decode(char *s) {
    char *out=s;
    for(char *p=s;*p;p++) {
        if(*p=='+') *out++=' ';
        else if(*p=='%') {
            if(!p[1]||!p[2]||hex(p[1])<0||hex(p[2])<0)return false;
            int c=hex(p[1])*16+hex(p[2]); if(!c)return false;
            *out++=c;p+=2;
        } else *out++=*p;
    }
    *out=0;return true;
}
static esp_err_t wifi_handler(httpd_req_t *req) {
#if C6_FORMLABS_ONLY
    char header[96],host[80],origin[96],expected[96];
    if(httpd_req_get_hdr_value_str(req,"X-XH-WiFi",header,sizeof(header))!=ESP_OK||strcmp(header,"1")||httpd_req_get_hdr_value_str(req,"Host",host,sizeof(host))!=ESP_OK)return httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"Open the device Wi-Fi page first");
    snprintf(expected,sizeof(expected),"http://%s",host);
    if(httpd_req_get_hdr_value_str(req,"Origin",origin,sizeof(origin))==ESP_OK&&strcmp(origin,expected))return httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"Same-origin Wi-Fi configuration required");
    char *port=strchr(host,':');if(port){if(strcmp(port,":80"))return httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"Invalid host");*port=0;}
    if(strcmp(host,setup_request(req)?"192.168.4.1":ip))return httpd_resp_send_err(req,HTTPD_403_FORBIDDEN,"Invalid device host");
#endif
    char body[384],ssid[128],password[256];
    if(req->content_len<=0||req->content_len>=sizeof(body))return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid form");
    int count=0;
    while(count<req->content_len) {
        int n=httpd_req_recv(req,body+count,req->content_len-count);if(n<=0)return ESP_FAIL;count+=n;
    }
    body[count]=0;
    if(httpd_query_key_value(body,"ssid",ssid,sizeof(ssid))!=ESP_OK||
       httpd_query_key_value(body,"password",password,sizeof(password))!=ESP_OK||
       !decode(ssid)||!decode(password)||!strlen(ssid)||strlen(ssid)>32||strlen(password)>64||
       (strlen(password)>0&&strlen(password)<8))return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Check SSID/password length");
    if(strlen(password)==64)for(unsigned i=0;i<64;i++)if(!isxdigit((unsigned char)password[i]))return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"64-character passwords must be hexadecimal PSK");
    wifi_config_t cfg={0};memcpy(cfg.sta.ssid,ssid,strlen(ssid));memcpy(cfg.sta.password,password,strlen(password));
    esp_wifi_disconnect(); ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA,&cfg));__atomic_store_n(&station_has_credentials,true,__ATOMIC_RELAXED);retries=0;esp_wifi_connect();
    httpd_resp_set_type(req,"text/plain; charset=utf-8");return httpd_resp_sendstr(req,"网络已保存。联网成功后屏幕会显示局域网 IP，并关闭配置热点；请切回同一 Wi-Fi，或在多屏灵犀中扫描添加。");
}
void app_main(void) {
    ESP_ERROR_CHECK(nvs_flash_init());
    standalone_init();
    frame=heap_caps_malloc(FRAME_BYTES,MALLOC_CAP_8BIT); if(!frame)abort();
    init_lcd();standalone_apply();
    boot_id=esp_random();
    gpio_config_t button={.pin_bit_mask=1ULL<<9,.mode=GPIO_MODE_INPUT,.pull_up_en=GPIO_PULLUP_ENABLE};
    ESP_ERROR_CHECK(gpio_config(&button));
    gesture_queue=xQueueCreate(8,sizeof(c6_queued_gesture_t));if(!gesture_queue)abort();
    xTaskCreate(button_task,"boot_button",2048,NULL,5,NULL);
    ESP_ERROR_CHECK(esp_netif_init());ESP_ERROR_CHECK(esp_event_loop_create_default());
    station=esp_netif_create_default_wifi_sta();
#if C6_FORMLABS_ONLY
    setup_ap=esp_netif_create_default_wifi_ap();
#else
    esp_netif_create_default_wifi_ap();
#endif
    wifi_init_config_t init=WIFI_INIT_CONFIG_DEFAULT();ESP_ERROR_CHECK(esp_wifi_init(&init));
    c6_wifi_scan_init();
    uint8_t mac[6];esp_read_mac(mac,ESP_MAC_WIFI_STA);
    snprintf(hostname,sizeof(hostname),C6_FORMLABS_ONLY?"xh-multiscreen-%02x%02x%02x":"lingxi-c6-%02x%02x%02x",mac[3],mac[4],mac[5]);
    esp_netif_set_hostname(station,hostname);
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT,ESP_EVENT_ANY_ID,wifi_event,NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT,IP_EVENT_STA_GOT_IP,wifi_event,NULL));
    wifi_config_t ap={0};snprintf((char*)ap.ap.ssid,sizeof(ap.ap.ssid),"XH-Multiscreen-%02X%02X%02X",mac[3],mac[4],mac[5]);
    // Open only for first provisioning or an explicit physical Wi-Fi reset.
    ap.ap.authmode=WIFI_AUTH_OPEN;ap.ap.max_connection=1;ap.ap.channel=1;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP,&ap));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_FLASH));import_wifi_provision();
    wifi_config_t saved={0};ESP_ERROR_CHECK(esp_wifi_get_config(WIFI_IF_STA,&saved));station_has_credentials=saved.sta.ssid[0]!=0;memset(&saved,0,sizeof(saved));
    if(station_has_credentials)ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
#if C6_FORMLABS_ONLY
    c6_captive_dns_start(setup_ap);
#endif
    xTaskCreate(reconnect_task,"wifi_reconnect",2048,NULL,3,NULL);
    esp_sntp_setoperatingmode(SNTP_OPMODE_POLL);esp_sntp_setservername(0,"pool.ntp.org");esp_sntp_init();
    c6_sources_init();
    httpd_config_t config=HTTPD_DEFAULT_CONFIG();config.stack_size=12288;config.recv_wait_timeout=5;config.max_uri_handlers=24;
    httpd_handle_t server;ESP_ERROR_CHECK(httpd_start(&server,&config));
    http_server=server;xTaskCreate(clock_task,"native_clock",2048,NULL,3,&clock_task_handle);
    httpd_uri_t routes[]={
        {.uri="/",.method=HTTP_GET,.handler=root_handler},
        {.uri="/wifi",.method=HTTP_POST,.handler=wifi_handler},
        {.uri="/api/wifi/scan",.method=HTTP_GET,.handler=c6_wifi_scan_handler},
        {.uri="/api/info",.method=HTTP_GET,.handler=info_handler},
        {.uri="/api/button",.method=HTTP_GET,.handler=button_handler},
        {.uri="/api/clock",.method=HTTP_POST,.handler=clock_handler},
        {.uri="/api/brightness",.method=HTTP_POST,.handler=brightness_handler},
        {.uri="/api/rotation",.method=HTTP_POST,.handler=rotation_handler},
        {.uri="/api/software",.method=HTTP_POST,.handler=software_handler},
        {.uri="/api/simulation",.method=HTTP_POST,.handler=simulation_handler},
        {.uri="/api/frame",.method=HTTP_GET,.handler=preview_frame_handler},
        {.uri="/api/view",.method=HTTP_POST,.handler=terminal_view_handler},
#if C6_FORMLABS_ONLY
        {.uri="/api/language",.method=HTTP_POST,.handler=terminal_language_handler},
#endif
        {.uri="/api/card",.method=HTTP_POST,.handler=native_card_handler},
        {.uri="/api/thumbnail",.method=HTTP_POST,.handler=c6_thumbnail_handler},
        {.uri="/image/rgb565",.method=HTTP_POST,.handler=frame_handler}};
    for(size_t i=0;i<sizeof(routes)/sizeof(routes[0]);i++)ESP_ERROR_CHECK(httpd_register_uri_handler(server,&routes[i]));
    standalone_register(server);
#if C6_FORMLABS_ONLY
    ESP_ERROR_CHECK(httpd_register_err_handler(server,HTTPD_404_NOT_FOUND,captive_redirect));
#endif
    c6_register_updates(server);
}
