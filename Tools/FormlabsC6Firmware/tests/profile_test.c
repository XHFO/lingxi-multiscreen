#define C6_FORMLABS_ONLY 1
#define main baseline_contract_main
#include "../../C6StandaloneTests/firmware_contract.c"
#undef main
#include "../../WaveshareC6Firmware/src/form_auth_cache.h"
#include "../../WaveshareC6Firmware/src/formlabs_source.h"
#include "../../WaveshareC6Firmware/src/source_budget.h"
static standalone_config_t fixture(void){
    standalone_config_t c=standalone_config;c.printer_count=3;c.weather=true;
    for(unsigned i=0;i<3;i++){
        c6_printer_config_t *p=&c.printers[i];memset(p,0,sizeof(*p));
        p->enabled=p->rotate=p->source_formlabs=p->show_task=p->show_status=p->show_progress=p->show_remaining=p->show_image=p->show_layers=p->show_material=true;
        snprintf(p->serial,40,"FORM_%u",i);snprintf(p->name,64,"Form %u",i);snprintf(p->form_client_id,128,"account_%u",i);snprintf(p->form_client_secret,256,"fixture-secret-%u",i);
    }return c;
}
static httpd_req_t write_document(const standalone_config_t *c,bool secrets){
    char *body=config_json_encode(c,secrets,NULL,NULL);assert(body);
    httpd_req_t req={.method=HTTP_PUT,.body=body,.content_len=(int)strlen(body),.auth="Bearer 1234abcd1234abcd"};handler(&req);free(body);req.body=NULL;return req;
}
int main(void){
    assert(!strcmp(C6_CONFIG_NAMESPACE,"form_monitor")&&!strcmp(C6_DEVICE_ID,"lingxi-c6-formlabs-monitor"));
    assert(standalone_config.enabled&&standalone_config.local_first&&standalone_config.clock&&!standalone_config.diagnostics&&!standalone_config.ha_enabled&&standalone_config.card_mask==5);
    strcpy(standalone_token,"1234abcd1234abcd");standalone_config_t original=fixture();standalone_config=original;
    httpd_req_t req=write_document(&original,true);assert(req.status==200&&standalone_config.printer_count==3&&applied==1);
    assert(!strstr(req.response,"fixture-secret")&&strstr(req.response,"form_credentials_set\":true"));
    standalone_config_t english=standalone_config;english.language=1;
    req=write_document(&english,true);assert(req.status==200&&standalone_config.language==1&&strstr(req.response,"\"language\":1"));
    standalone_config_t invalid=standalone_config;invalid.language=2;
    req=write_document(&invalid,true);assert(req.status==400&&standalone_config.language==1);
    char *legacy=config_json_encode(&standalone_config,true,NULL,NULL);cJSON *legacy_json=cJSON_Parse(legacy);free(legacy);cJSON_DeleteItemFromObject(legacy_json,"language");
    standalone_config_t parsed;assert(parse(legacy_json,&parsed,NULL)&&parsed.language==0);assert(parse(legacy_json,&parsed,&standalone_config)&&parsed.language==1);cJSON_Delete(legacy_json);
    int language_revision=standalone_config.revision;
    fail_storage=1;assert(!standalone_save_display_language(language_revision,0,true,5,7,0)&&standalone_config.language==1);fail_storage=0;
    assert(standalone_save_display_language(language_revision,0,true,5,7,0)&&standalone_config.language==0);
    standalone_config_t smooth=standalone_config;smooth.digit_style=1;
    req=write_document(&smooth,true);assert(req.status==200&&standalone_config.digit_style==1&&strstr(req.response,"\"digit_style\":1"));
    smooth=standalone_config;smooth.digit_style=2;req=write_document(&smooth,true);assert(req.status==400&&standalone_config.digit_style==1);
    legacy=config_json_encode(&standalone_config,true,NULL,NULL);legacy_json=cJSON_Parse(legacy);free(legacy);cJSON_DeleteItemFromObject(legacy_json,"digit_style");
    assert(parse(legacy_json,&parsed,NULL)&&parsed.digit_style==0);assert(parse(legacy_json,&parsed,&standalone_config)&&parsed.digit_style==1);cJSON_Delete(legacy_json);
    fail_storage=1;smooth=standalone_config;smooth.digit_style=0;req=write_document(&smooth,false);assert(req.status!=200&&standalone_config.digit_style==1);fail_storage=0;
    int style_revision=standalone_config.revision;
    assert(standalone_save_display_language(style_revision,0,true,5,7,0)&&standalone_config.digit_style==1);
    standalone_config_t cards=standalone_config;for(unsigned i=0;i<3;i++)cards.printers[i].card_style=(int)((i+1)%3);
    req=write_document(&cards,true);assert(req.status==200);
    for(unsigned i=0;i<3;i++){assert(standalone_config.printers[i].card_style==(int)((i+1)%3));assert(c6_printer_images_enabled(&standalone_config.printers[i])==(i==2));}
    cards=standalone_config;cards.printers[0].card_style=3;req=write_document(&cards,false);assert(req.status==400&&standalone_config.printers[0].card_style==1);
    legacy=config_json_encode(&standalone_config,true,NULL,NULL);legacy_json=cJSON_Parse(legacy);free(legacy);
    cJSON_DeleteItemFromObject(cJSON_GetArrayItem(cJSON_GetObjectItem(legacy_json,"printers"),0),"card_style");
    assert(parse(legacy_json,&parsed,NULL)&&parsed.printers[0].card_style==0);assert(parse(legacy_json,&parsed,&standalone_config)&&parsed.printers[0].card_style==1);cJSON_Delete(legacy_json);
    fail_storage=1;cards=standalone_config;cards.printers[0].card_style=2;req=write_document(&cards,false);assert(req.status!=200&&standalone_config.printers[0].card_style==1);fail_storage=0;
    assert(!standalone_save_display_language(language_revision,0,true,5,7,1));
    for(int angle=0;angle<360;angle+=90){standalone_config_t rotated=standalone_config;rotated.rotation=angle;req=write_document(&rotated,false);assert(req.status==200&&standalone_config.rotation==angle&&standalone_config.digit_style==1);}
    standalone_config_t sleep=standalone_config;sleep.sleep_mode=2;sleep.sleep_start=1380;sleep.sleep_end=420;sleep.sleep_idle_minutes=1;
    req=write_document(&sleep,false);assert(req.status==200&&standalone_config.sleep_mode==2);
    standalone_config_t retained=standalone_config;
    for(unsigned n=0;n<6;n++){
        standalone_config_t bad=retained;
        switch(n){case 0:bad.rotation=45;break;case 1:bad.rotation=360;break;case 2:bad.sleep_mode=3;break;case 3:bad.sleep_idle_minutes=0;break;case 4:bad.sleep_start=1440;break;case 5:bad.sleep_end=bad.sleep_start;break;}
        req=write_document(&bad,false);assert(req.status==400&&standalone_config.revision==retained.revision);
    }
    legacy=config_json_encode(&standalone_config,true,NULL,NULL);legacy_json=cJSON_Parse(legacy);free(legacy);
    const char *sleep_keys[]={"sleep_mode","sleep_idle_minutes","sleep_start","sleep_end","sleep_keep_printing"};for(unsigned i=0;i<5;i++)cJSON_DeleteItemFromObject(legacy_json,sleep_keys[i]);
    assert(parse(legacy_json,&parsed,NULL)&&parsed.sleep_mode==0&&parsed.sleep_idle_minutes==5&&parsed.sleep_keep_printing);
    assert(parse(legacy_json,&parsed,&standalone_config)&&parsed.sleep_mode==2&&parsed.sleep_idle_minutes==1);cJSON_Delete(legacy_json);
    fail_storage=1;assert(!standalone_save_monitor_display(standalone_config.revision,90,true,5,7,0,1));fail_storage=0;
    assert(standalone_config.sleep_mode==2);
    assert(standalone_save_monitor_display(standalone_config.revision,90,true,5,7,0,1)&&standalone_config.rotation==90&&standalone_config.sleep_mode==1);
    standalone_config.sleep_mode=0;standalone_config.sleep_idle_minutes=5;
    // Reorder printers without secrets: retain by identity, never by array index.
    standalone_config_t reordered=standalone_config;c6_printer_config_t temp=reordered.printers[0];reordered.printers[0]=reordered.printers[2];reordered.printers[2]=temp;
    req=write_document(&reordered,false);assert(req.status==200&&!strcmp(standalone_config.printers[0].form_client_secret,"fixture-secret-2"));
    assert(standalone_config.printers[0].card_style==0&&standalone_config.printers[2].card_style==1);
    standalone_config_t good=standalone_config;
    for(unsigned case_id=0;case_id<6;case_id++){
        standalone_config_t bad=good;
        switch(case_id){case 0:bad.printers[0].source_formlabs=false;bad.printers[0].enabled=false;break;case 1:bad.ha_enabled=true;strcpy(bad.ha_host,"192.168.1.2");strcpy(bad.ha_token,"bad");break;case 2:bad.card_mask=15;break;case 3:bad.diagnostics=true;break;case 4:bad.local_first=false;break;case 5:bad.enabled=false;break;}
        req=write_document(&bad,true);assert(req.status==400&&standalone_config.revision==good.revision);
    }
    assert(!standalone_save_display(good.revision,0,true,15,7));
    assert(standalone_save_display(good.revision,180,false,5,5));assert(standalone_config.printers[0].rotate&&!standalone_config.printers[1].rotate&&standalone_config.printers[2].rotate);
    assert(!standalone_save_display(good.revision,0,true,5,7));
    c6_form_auth_cache_t cache={0};char token[1024];uint64_t expires;
    c6_form_auth_put(&cache,0,"account0","token0",1000);c6_form_auth_put(&cache,1,"account1","token1",1100);c6_form_auth_put(&cache,2,"account2","token2",1200);
    assert(c6_form_auth_get(&cache,"account1",100,token,&expires)&&!strcmp(token,"token1"));
    assert(!c6_form_auth_get(&cache,"account0",880,token,&expires));assert(!c6_form_auth_get(&cache,"unknown",0,token,&expires));
    c6_form_auth_reject(&cache,"account1");assert(!c6_form_auth_get(&cache,"account1",0,token,&expires));assert(c6_form_auth_get(&cache,"account2",100,token,&expires)&&!strcmp(token,"token2"));
    // Three printer states, same job name, distinct run keys and completion windows.
    c6_printer_state_t states[3]={0};char pictures[3][1536]={{0}};
    for(unsigned i=0;i<3;i++){
        char body[600],serial[40];snprintf(serial,40,"FORM_%u",i);
        snprintf(body,sizeof(body),"{\"serial\":\"%s\",\"is_connected\":true,\"printer_status\":{\"status\":\"printing\",\"current_print_run\":{\"id\":\"run-%u\",\"name\":\"Same task\",\"status\":\"printing\",\"currently_printing_layer\":%u,\"layer_count\":100}}}",serial,i,i*10+10);
        cJSON *j=cJSON_Parse(body);assert(c6_formlabs_update(&states[i],j,serial,100,pictures[i],1536));cJSON_Delete(j);
        assert(states[i].progress==(int)i*10+10&&states[i].connected);
    }
    assert(strcmp(states[0].thumbnail_key,states[1].thumbnail_key)&&strcmp(states[1].thumbnail_key,states[2].thumbnail_key));
    cJSON *wrong=cJSON_Parse("{\"serial\":\"FORM_2\",\"status\":\"finished\"}");assert(!c6_formlabs_update(&states[0],wrong,"FORM_0",200,pictures[0],1536));cJSON_Delete(wrong);assert(states[0].progress==10&&states[1].progress==20);
    // Exact serial fixtures share ordinary slots/NVS/config. No credentials,
    // no remote worker and no timestamp-driven motion in a fixed snapshot.
    for(unsigned id=1;id<=4;id++){
        standalone_config_t demo=fixture();demo.printer_count=1;
        snprintf(demo.printers[0].serial,40,";;tex_%u",id);
        req=write_document(&demo,true);assert(req.status==200);
        assert(!*standalone_config.printers[0].form_client_id&&!*standalone_config.printers[0].form_client_secret);
        assert(!c6_source_needed(&standalone_config,C6_WORK_FORM));
        c6_printer_state_t a,b;assert(c6_form_demo_seed(&standalone_config.printers[0],&a));
        assert(c6_form_demo_seed(&standalone_config.printers[0],&b)&&!memcmp(&a,&b,sizeof(a)));
        assert(a.connected&&a.known&&!a.updated&&!a.end_epoch&&!a.remaining_updated&&!*a.thumbnail_key);
        const char *status[]={"idle","printing","finished","failed"};assert(!strcmp(a.status,status[id-1]));
        if(id==1)assert(!a.progress_valid&&!a.remaining_valid);
        if(id==2)assert(a.progress==74&&a.remaining==42&&a.layer==888);
        if(id==3)assert(a.progress==100&&a.completed_at);
        if(id==4)assert(a.progress==32&&*a.error&&!a.remaining_valid);
        char *encoded=config_json_encode(&standalone_config,true,NULL,NULL);cJSON *j=cJSON_Parse(encoded);free(encoded);
        cJSON_DeleteItemFromObject(cJSON_GetArrayItem(cJSON_GetObjectItem(j,"printers"),0),"form_client_id");
        assert(parse(j,&parsed,NULL)&&!strcmp(parsed.printers[0].serial,demo.printers[0].serial));cJSON_Delete(j);
        demo=standalone_config;demo.printers[0].enabled=false;c6_form_demo_seed(&demo.printers[0],&a);assert(!a.connected);
    }
    const char *bad[]={";;tex_0",";;tex_5",";;tex_12",";;tex_1x",";;TEX_1"," ;;tex_1",";;tex_1 "};
    for(unsigned i=0;i<sizeof(bad)/sizeof(*bad);i++){standalone_config_t demo=standalone_config;snprintf(demo.printers[0].serial,40,"%s",bad[i]);req=write_document(&demo,false);assert(req.status==400);}
    standalone_config_t real=standalone_config;strcpy(real.printers[0].serial,"REAL_PRINTER");req=write_document(&real,false);assert(req.status==400);
    strcpy(real.printers[0].form_client_id,"real-account");strcpy(real.printers[0].form_client_secret,"fixture-only");req=write_document(&real,true);assert(req.status==200&&c6_source_needed(&standalone_config,C6_WORK_FORM));
    c6_printer_state_t untouched={.progress=23},before=untouched;assert(!c6_form_demo_seed(&standalone_config.printers[0],&untouched)&&!memcmp(&before,&untouched,sizeof(before)));
    standalone_config_t mixed=fixture();strcpy(mixed.printers[0].serial,";;tex_2");strcpy(mixed.printers[1].serial,";;tex_3");req=write_document(&mixed,true);assert(req.status==200&&c6_source_needed(&standalone_config,C6_WORK_FORM));
    mixed=standalone_config;c6_printer_config_t swap=mixed.printers[0];mixed.printers[0]=mixed.printers[2];mixed.printers[2]=swap;req=write_document(&mixed,false);assert(req.status==200&&!strcmp(standalone_config.printers[0].form_client_secret,"fixture-secret-2")&&c6_form_is_demo(&standalone_config.printers[2]));
    mixed=standalone_config;mixed.printers[1]=mixed.printers[2];req=write_document(&mixed,false);assert(req.status==400);
    puts("Formlabs profile: 4 exact static demos, normal config/restore/reorder, no credentials/cloud polling, malformed-code rejection and real-device isolation passed");
    return 0;
}
