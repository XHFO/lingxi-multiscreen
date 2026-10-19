// Shared-profile additions exercise production parsing/storage/rendering.
// No network, device, extra framebuffer or private user configuration.
#define main baseline_main
#include "firmware_contract.c"
#undef main
#include "../../Sources/C6DisplayRenderer/include/c6_display_renderer.h"
#include "../../Tools/WaveshareC6Firmware/src/terminal_display_policy.h"
static void integer_value(cJSON *j,const char *name,int value){cJSON_ReplaceItemInObjectCaseSensitive(j,name,cJSON_CreateNumber(value));}
static uint64_t frame_hash(const uint8_t *bytes){uint64_t hash=14695981039346656037ULL;for(unsigned i=0;i<C6_RENDER_BYTES;i++)hash=(hash^bytes[i])*1099511628211ULL;return hash;}
int main(void){
    baseline_main();
    assert(!strcmp(C6_DEVICE_ID,"lingxi-esp32-c6-screen")&&!strcmp(C6_CONFIG_NAMESPACE,"standalone"));
    standalone_config_t source=standalone_config,parsed;
    source.language=1;source.digit_style=1;source.sleep_mode=2;source.sleep_idle_minutes=17;source.sleep_start=1320;source.sleep_end=360;source.sleep_keep_printing=true;
    source.printer_count=3;
    for(unsigned i=0;i<3;i++){source.printers[i]=source.printers[0];source.printers[i].enabled=true;source.printers[i].card_style=(int)i;snprintf(source.printers[i].serial,40,"PRINTER_%u",i);}
    source.printers[1].source_ha=false;strcpy(source.printers[1].host,"192.168.1.21");strcpy(source.printers[1].access_code,"fixture-code");source.printers[1].trust_lan=true;
    source.printers[2].source_ha=false;source.printers[2].source_formlabs=true;strcpy(source.printers[2].form_client_id,"fixture-client");strcpy(source.printers[2].form_client_secret,"fixture-secret");
    // Same serial across brands remains distinct, not a mixed subscription.
    strcpy(source.printers[2].serial,source.printers[0].serial);
    cJSON *j=document(&source,true);assert(parse(j,&parsed,NULL));assert(parsed.printer_count==3&&parsed.language==1&&parsed.digit_style==1&&parsed.sleep_mode==2);
    assert(parsed.sleep_idle_minutes==17&&parsed.sleep_start==1320&&parsed.sleep_end==360&&parsed.sleep_keep_printing);
    for(unsigned i=0;i<3;i++)assert(parsed.printers[i].card_style==(int)i&&c6_printer_images_enabled(&parsed.printers[i])==(parsed.printers[i].show_image&&i==0));
    const char *fields[]={"language","digit_style","sleep_mode","sleep_idle_minutes","sleep_start","sleep_end"};
    const int invalid[]={2,-1,3,0,1440,-1},valid[]={1,1,2,17,1320,360};
    for(unsigned i=0;i<6;i++){integer_value(j,fields[i],invalid[i]);assert(!parse(j,&parsed,NULL));integer_value(j,fields[i],valid[i]);}
    integer_value(j,"sleep_end",1320);assert(!parse(j,&parsed,NULL));integer_value(j,"sleep_end",360);
    for(int rotation=0;rotation<360;rotation+=90){integer_value(j,"rotation",rotation);assert(parse(j,&parsed,NULL)&&parsed.rotation==rotation);}
    integer_value(j,"rotation",45);assert(!parse(j,&parsed,NULL));integer_value(j,"rotation",0);
    cJSON *printers=cJSON_GetObjectItemCaseSensitive(j,"printers"),*p=cJSON_GetArrayItem(printers,1);
    integer_value(p,"card_style",3);assert(!parse(j,&parsed,NULL));integer_value(p,"card_style",1);
    // Missing new fields on legacy clients retain device-owned choices.
    for(unsigned i=0;i<6;i++)cJSON_DeleteItemFromObjectCaseSensitive(j,fields[i]);cJSON_DeleteItemFromObjectCaseSensitive(j,"sleep_keep_printing");
    for(unsigned i=0;i<3;i++)cJSON_DeleteItemFromObjectCaseSensitive(cJSON_GetArrayItem(printers,i),"card_style");
    assert(parse(j,&parsed,&source)&&parsed.language==1&&parsed.digit_style==1&&parsed.sleep_idle_minutes==17&&parsed.sleep_mode==2);
    for(unsigned i=0;i<3;i++)assert(parsed.printers[i].card_style==(int)i);
    assert(parse(j,&parsed,NULL)&&parsed.language==0&&parsed.digit_style==0&&parsed.sleep_mode==0&&parsed.sleep_idle_minutes==5&&parsed.sleep_start==1380&&parsed.sleep_end==420&&parsed.sleep_keep_printing);
    cJSON_Delete(j);
    standalone_config=source;int revision=source.revision;
    assert(standalone_save_monitor_display(revision,270,false,15,7,1,1));standalone_config=(standalone_config_t){0};standalone_init();
    assert(standalone_config.rotation==270&&standalone_config.language==1&&standalone_config.sleep_mode==1&&standalone_config.printers[2].card_style==2);
    assert(c6_enabled_printer_count(&standalone_config)==3);standalone_config.printers[1].enabled=false;assert(c6_enabled_printer_count(&standalone_config)==2);standalone_config.printers[2].enabled=false;assert(!terminal_overview_available(c6_enabled_printer_count(&standalone_config)));
    for(int rotation=0;rotation<360;rotation+=90){unsigned seen[240*240]={0};for(unsigned y=0;y<240;y++)for(unsigned x=0;x<240;x++){unsigned offset=terminal_source_pixel(rotation,x,y);assert(offset<240*240&&!seen[offset]);seen[offset]=1;}}
    assert(terminal_should_sleep(1,5,1380,420,true,false,false,300,0,false,0));
    assert(!terminal_should_sleep(1,5,1380,420,true,true,false,300,0,false,0));
    assert(!terminal_should_sleep(2,5,1380,420,false,false,true,300,0,false,60));
    assert(terminal_should_sleep(2,5,1380,420,false,false,false,300,0,false,60));
    assert(!terminal_should_sleep(2,5,1380,420,false,false,false,300,299,true,60));
    struct {uint8_t guard_before[32],bytes[C6_RENDER_BYTES],guard_after[32];} *frame=malloc(sizeof(*frame));assert(frame);memset(frame,0xa5,sizeof(*frame));
    c6_renderer_t r;assert(c6_renderer_init(&r,frame->bytes,C6_RENDER_BYTES)&&!r.english&&!r.smooth_digits);
    assert(!strcmp(c6_renderer_localized(&r,"打印中"),"打印中"));r.english=true;assert(!strcmp(c6_renderer_localized(&r,"打印中"),"PRINTING"));
    assert(!strcmp(c6_renderer_localized(&r,"用户的打印机名称"),"用户的打印机名称"));
    c6_render_clock_t now={2026,10,15,4,8,59,59},next=now;next.minute=0;next.hour=9;next.second=0;
    c6_renderer_clock(&r,&now,NULL,1000);uint64_t classic=frame_hash(frame->bytes);r.smooth_digits=true;c6_renderer_clock(&r,&now,NULL,1000);assert(frame_hash(frame->bytes)!=classic);
    c6_renderer_round_clock(&r,&now,NULL);uint64_t rounded=frame_hash(frame->bytes);r.smooth_digits=false;c6_renderer_round_clock(&r,&now,NULL);assert(frame_hash(frame->bytes)==rounded);
    uint8_t *reference=malloc(C6_RENDER_BYTES);assert(reference);c6_renderer_t other;assert(c6_renderer_init(&other,reference,C6_RENDER_BYTES));
    for(unsigned english=0;english<2;english++)for(unsigned digits=0;digits<2;digits++){
        r.english=other.english=english;r.smooth_digits=other.smooth_digits=digits;
        c6_renderer_clock(&other,&now,NULL,1000);c6_renderer_clock_smooth(&r,&next,&now,0,false);assert(!memcmp(reference,frame->bytes,C6_RENDER_BYTES));
        for(unsigned step=0;step<=1000;step+=10){c6_renderer_clock_smooth(&r,&next,&now,step,true);c6_renderer_clock_smooth(&other,&next,&now,step,false);assert(!memcmp(reference,frame->bytes,C6_RENDER_BYTES));}
        c6_renderer_clock(&other,&next,NULL,1000);assert(!memcmp(reference,frame->bytes,C6_RENDER_BYTES));
    }
    free(reference);
    c6_render_printer_t value={.name="用户打印机 · LONG NAME",.task="User task cannot be translated.gcode",.status="printing",.connected=true,.progress=74,.remaining=77,.remaining_seconds=4620,.progress_available=true,.remaining_available=true,.show_task=true,.show_progress=true,.show_status=true,.show_remaining=true,.show_image=true,.layers="层数 12 / 800",.material="User material",.updated_text="UPDATED 12:34",.show_temperature=true,.nozzle="220",.bed="60"};
    for(unsigned style=1;style<=2;style++)for(unsigned language=0;language<2;language++)for(unsigned digits=0;digits<2;digits++){
        r.english=language;r.smooth_digits=digits;value.card_style=(int)style;c6_renderer_printer(&r,&value);uint64_t no_picture=frame_hash(frame->bytes);
        uint8_t thumbnail[]={255,255};value.thumbnail_rgb565=thumbnail;value.thumbnail_width=value.thumbnail_height=1;value.thumbnail_stride=2;c6_renderer_printer(&r,&value);assert(frame_hash(frame->bytes)==no_picture);value.thumbnail_rgb565=NULL;
    }
    c6_render_printer_summary_t rows[]={{.name="用户的 Form 4",.status="printing",.progress=74,.enabled=true,.connected=true,.progress_available=true,.formlabs=true},{.name="用户的 X2D",.status="paused",.progress=32,.enabled=true,.connected=true,.progress_available=true}};
    c6_renderer_printer_overview_styled(&r,rows,2,NULL);
    for(unsigned i=0;i<32;i++)assert(frame->guard_before[i]==0xa5&&frame->guard_after[i]==0xa5);free(frame);
    puts("C6 unified UI: validated/legacy fields, all source styles, brand isolation, atomic NVS restore, four canonical rotations, idle/schedule sleep, translated fixed strings, shared smooth hero/clock and guarded no-thumbnail layouts passed");
}
