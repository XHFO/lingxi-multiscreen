#include "../../Tools/WaveshareC6Firmware/src/local_state.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "../../Tools/WaveshareC6Firmware/src/display_styles.h"
#include "../../Tools/WaveshareC6Firmware/src/wifi_provision.h"
#include "../../Tools/WaveshareC6Firmware/src/software_simulation.h"
static void provision_crc(uint8_t *record){uint32_t crc=c6_wifi_crc32(record,112);for(unsigned i=0;i<4;i++)record[112+i]=crc>>(i*8);}
static double luminance(uint32_t color) {
    double value=0;const double weights[]={0.2126,0.7152,0.0722};
    for(unsigned i=0;i<3;i++){double channel=((color>>(16-i*8))&255)/255.0;value+=weights[i]*(channel<=0.04045?channel/12.92:pow((channel+0.055)/1.055,2.4));}return value;
}
static double contrast(uint32_t a,uint32_t b){double first=luminance(a),last=luminance(b);return (fmax(first,last)+0.05)/(fmin(first,last)+0.05);}
static uint32_t rgb565_precision(uint32_t value){return value&0xf8fcf8;}
static void update(c6_printer_state_t *s,const char *body,uint64_t now){cJSON *j=cJSON_Parse(body);c6_print_update(s,j,now);cJSON_Delete(j);}
int main(void) {
    c6_printer_state_t s={0};
    assert(c6_parse_end_epoch("2026-10-08T12:00:00+08:00")==c6_parse_end_epoch("2026-10-08T04:00:00Z"));
    assert(c6_parse_end_epoch("2026-10-08T04:00:00.500Z")==c6_parse_end_epoch("2026-10-08T04:00:00Z"));
    assert(!c6_parse_end_epoch("unknown")&&!c6_parse_end_epoch("2026-02-30T12:00:00Z")&&!c6_parse_end_epoch("2026-10-08T12:00:00"));
    c6_printer_state_t detail={0};update(&detail,"{\"nozzle_temper\":220,\"bed_temper\":60,\"print_error\":0,\"mc_remaining_time\":40,\"mc_percent\":12,\"end_time\":\"2026-10-08T04:00:00Z\"}",20);
    assert(!strcmp(detail.nozzle,"220")&&!strcmp(detail.bed,"60")&&!strcmp(detail.error,"0")&&detail.remaining_valid&&detail.progress_valid&&detail.remaining_updated==20&&detail.end_epoch);
    update(&detail,"{\"nozzle_temper\":\"unknown\",\"mc_remaining_time\":null,\"mc_percent\":null}",21);assert(!*detail.nozzle&&!detail.remaining_valid&&!detail.progress_valid);
    int64_t simulation_now=1234567,until=c6_simulation_deadline(true,simulation_now);
    assert(c6_simulation_deadline(false,simulation_now)==0&&until==simulation_now+45000000);
    assert(c6_simulation_active(until,until-1)&&!c6_simulation_active(until,until)&&!c6_simulation_active(0,simulation_now));
    char key[17];c6_task_key("ha","模型 A.gcode",key);assert(!strcmp(key,"51f8e7ab9c2c491e"));
    c6_task_key("ha","unknown",key);assert(!*key);
    c6_printer_state_t thumbnail_printer={0};
    update(&thumbnail_printer,"{\"gcode_state\":\"RUNNING\",\"subtask_id\":\"1234\",\"task_id\":\"456\",\"subtask_name\":\"test\"}",1);
    assert(!strcmp(thumbnail_printer.thumbnail_key,"1bf798bd4bce1656"));
    update(&thumbnail_printer,"{\"subtask_name\":\"test\",\"mc_percent\":20}",2);
    assert(!strcmp(thumbnail_printer.thumbnail_key,"1bf798bd4bce1656")); // Partial report cannot downgrade identity.
    update(&thumbnail_printer,"{\"subtask_id\":\"2345\"}",3);assert(strcmp(thumbnail_printer.thumbnail_key,"1bf798bd4bce1656"));
    assert(!c6_print_eligible(&s,1));
    update(&s,"{\"gcode_state\":\"RUNNING\",\"task_id\":\"1\",\"mc_percent\":20}",100);
    assert(c6_print_eligible(&s,100)&&s.progress==20);
    update(&s,"{\"gcode_state\":\"FINISH\",\"mc_percent\":100}",200);
    assert(s.completed_at==200&&c6_print_eligible(&s,1999));assert(!c6_print_eligible(&s,2000));
    update(&s,"{\"gcode_state\":\"FINISH\"}",900);assert(s.completed_at==200);
    update(&s,"{\"gcode_state\":\"IDLE\"}",1000);assert(s.completed_at==200);
    update(&s,"{\"gcode_state\":\"FINISH\"}",1200);assert(s.completed_at==200);
    update(&s,"{\"gcode_state\":\"RUNNING\",\"task_id\":\"2\",\"mc_percent\":1}",1500);assert(!s.completed_at&&s.progress==1);
    update(&s,"{\"gcode_state\":\"IDLE\"}",1600);assert(!c6_print_eligible(&s,1600));
    assert(c6_print_active("printing")&&c6_print_active("paused")&&c6_print_finished("completed"));
    assert(c6_software_wins(true,false,true,100,129));assert(!c6_software_wins(true,false,true,100,130));
    assert(!c6_software_wins(true,true,true,100,110));assert(c6_software_wins(true,true,false,100,110));
    assert(!c6_software_wins(true,false,true,0,110)); // Explicit quit releases immediately.
    assert(!c6_software_wins(true,false,true,0,1)); // RST never restores an old software lease.
    assert(!c6_software_wins(true,false,true,100,99)); // Counter discontinuity cannot retain ownership.
    assert(c6_software_wins(false,false,true,0,110)); // User-disabled local mode is respected.
    assert(c6_private_ip("192.168.1.2")&&!c6_private_ip("8.8.8.8")&&!c6_private_ip("192.168.1.2:80"));
    const int codes[]={0,1,2,3,45,48,51,53,55,56,57,61,63,65,66,67,80,81,82,71,73,75,77,85,86,95,96,99};
    for(unsigned i=0;i<sizeof(codes)/sizeof(codes[0]);i++) {
        c6_weather_style_t style=c6_weather_style(codes[i]);
        assert(style.kind!=C6_WEATHER_UNKNOWN);assert(style.background!=style.surface);
        assert(style.accent==style.secondary);assert(strcmp(c6_weather_label(codes[i]),"未知"));
        assert(c6_weather_background_at(style,0)==style.background&&c6_weather_background_at(style,239)==style.surface);
        for(int y=0;y<240;y++)assert(contrast(rgb565_precision(style.accent),rgb565_precision(c6_weather_background_at(style,y)))>=4.5);
    }
    assert(c6_weather_kind(0)==C6_WEATHER_CLEAR&&c6_weather_style(0).background==0x4b99e4);
    c6_weather_style_t sunny=c6_weather_style(0),cloudy=c6_weather_style(2);
    assert(sunny.background==cloudy.background&&sunny.surface==cloudy.surface&&sunny.cloud==0xf4faff&&sunny.sun==0xffd45e);
    assert(c6_weather_background_at(sunny,120)==0x84c0ef);
    assert(c6_weather_background_at(sunny,-1)==sunny.background&&c6_weather_background_at(sunny,999)==sunny.surface);
    assert(c6_weather_kind(2)==C6_WEATHER_CLOUDY&&c6_weather_kind(3)==C6_WEATHER_OVERCAST);
    assert(c6_weather_kind(48)==C6_WEATHER_FOG&&c6_weather_kind(57)==C6_WEATHER_DRIZZLE);
    assert(c6_weather_kind(67)==C6_WEATHER_RAIN&&c6_weather_kind(86)==C6_WEATHER_SNOW&&c6_weather_kind(99)==C6_WEATHER_THUNDER);
    assert(c6_weather_kind(-1)==C6_WEATHER_UNKNOWN&&c6_weather_kind(4)==C6_WEATHER_UNKNOWN&&c6_weather_kind(100)==C6_WEATHER_UNKNOWN);
    assert(c6_weather_wet(C6_WEATHER_SNOW)&&!c6_weather_wet(C6_WEATHER_CLEAR));
    for(unsigned i=0;i<4;i++){assert(c6_flip_card_x(i)>=0);assert(c6_flip_card_x(i)+C6_FLIP_CARD_WIDTH<=240);}
    assert(C6_FLIP_CARD_Y+C6_FLIP_CARD_HEIGHT<175&&C6_FLIP_DIGIT_WIDTH<C6_FLIP_CARD_WIDTH&&C6_FLIP_DIGIT_HEIGHT<C6_FLIP_CARD_HEIGHT);
    const uint8_t canonical[]={0xf8,0x00,0x07,0xe0,0x00,0x1f,0xff,0xff};
    const uint8_t normal_lcd[]={0x00,0xf8,0xe0,0x07,0x1f,0x00,0xff,0xff};
    const uint8_t rotated_lcd[]={0xff,0xff,0x1f,0x00,0xe0,0x07,0x00,0xf8};
    uint8_t frame[sizeof(canonical)];memcpy(frame,canonical,sizeof(frame));
    c6_lcd_transform(frame,sizeof(frame),false);assert(!memcmp(frame,normal_lcd,sizeof(frame)));
    c6_lcd_transform(frame,sizeof(frame),false);assert(!memcmp(frame,canonical,sizeof(frame)));
    for(unsigned i=0;i<4;i++){c6_lcd_transform(frame,sizeof(frame),true);assert(!memcmp(frame,rotated_lcd,sizeof(frame)));c6_lcd_transform(frame,sizeof(frame),true);assert(!memcmp(frame,canonical,sizeof(frame)));}
    uint8_t center[]={0xf8,0x00};c6_lcd_transform(center,sizeof(center),true);assert(center[0]==0&&center[1]==0xf8);c6_lcd_transform(center,sizeof(center),true);assert(center[0]==0xf8&&center[1]==0);
    assert(c6_wifi_crc32((const uint8_t *)"123456789",9)==0xcbf43926);
    uint8_t record[116]={0};memcpy(record,"LXC6WF01",8);record[8]=1;record[9]=32;record[10]=8;
    memset(record+12,'s',32);memcpy(record+45,"abcdefgh",8);provision_crc(record);c6_wifi_credentials_t credentials;
    assert(c6_wifi_provision_parse(record,sizeof(record),&credentials));assert(credentials.ssid_len==32&&credentials.ssid[32]==0&&credentials.password_len==8);
    record[10]=0;memset(record+45,0,65);provision_crc(record);assert(c6_wifi_provision_parse(record,sizeof(record),&credentials)&&credentials.password[0]==0);
    record[10]=64;memset(record+45,'A',64);provision_crc(record);assert(c6_wifi_provision_parse(record,sizeof(record),&credentials)&&credentials.password_len==64);
    record[45]='G';provision_crc(record);assert(!c6_wifi_provision_parse(record,sizeof(record),&credentials));record[45]='A';provision_crc(record);
    record[12]^=1;assert(!c6_wifi_provision_parse(record,sizeof(record),&credentials));record[12]^=1;
    assert(!c6_wifi_provision_parse(record,115,&credentials));
    record[11]=1;provision_crc(record);assert(!c6_wifi_provision_parse(record,sizeof(record),&credentials));record[11]=0;
    record[44]=1;provision_crc(record);assert(!c6_wifi_provision_parse(record,sizeof(record),&credentials));record[44]=0;
    record[110]=1;provision_crc(record);assert(!c6_wifi_provision_parse(record,sizeof(record),&credentials));record[110]=0;
    memcpy(record,"LXAIWF01",8);provision_crc(record);assert(!c6_wifi_provision_parse(record,sizeof(record),&credentials));
    memset(record,0,sizeof(record));memcpy(record,"LXC6WF01",8);record[8]=1;record[9]=6;record[10]=11;
    memcpy(record+12,"Test24",6);memcpy(record+45,"password123",11);
    assert(c6_wifi_crc32(record,112)==0x6ed88a71);provision_crc(record);
    assert(record[112]==0x71&&record[113]==0x8a&&record[114]==0xd8&&record[115]==0x6e);
    assert(c6_wifi_provision_parse(record,sizeof(record),&credentials)&&!strcmp(credentials.ssid,"Test24")&&!strcmp(credentials.password,"password123"));
    assert(C6_WIFI_PROVISION_OFFSET>=0x200000+0x1e0000&&C6_WIFI_PROVISION_OFFSET+C6_WIFI_PROVISION_SECTOR_BYTES<=0x400000);
    puts("C6 styles/rotation/state: WMO themes, flip layout, LCD rotation/restore, USB Wi-Fi/CRC validation, completion boundaries, new jobs and lease arbitration passed");
}
