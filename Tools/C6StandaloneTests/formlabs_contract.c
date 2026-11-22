#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../../Tools/WaveshareC6Firmware/src/formlabs_source.h"
static bool update(c6_printer_state_t *s,const char *body,uint64_t now,char *url){cJSON *j=cJSON_Parse(body);bool ok=c6_formlabs_update(s,j,"Form-123",now,url,1536);cJSON_Delete(j);return ok;}
int main(void){
    c6_printer_state_t state={0};char url[1536]={0},body[1280];bool bearer=false;
    assert(c6_formlabs_form_body("a+b@example","sec&ret/?",body,sizeof(body)));
    assert(!strcmp(body,"grant_type=client_credentials&client_id=a%2Bb%40example&client_secret=sec%26ret%2F%3F"));
    assert(!c6_formlabs_form_body("a","secret",body,10));
    assert(c6_formlabs_picture_url("/developer/v1/thumbnail/",url,sizeof(url),&bearer)&&bearer);
    assert(c6_formlabs_picture_url("https://bucket.s3.amazonaws.com/print.jpg?signature=test",url,sizeof(url),&bearer)&&!bearer);
    const char *bad[]={"http://bucket.s3.amazonaws.com/a","https://api.formlabs.com.evil.test/a","https://api.formlabs.com@evil.test/a","https://192.168.1.1/a","//localhost/a","https://api.formlabs.com:443/a","https://api.formlabs.com/\r\nX: secret"};
    for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++)assert(!c6_formlabs_picture_url(bad[i],url,sizeof(url),&bearer));
    url[0]=0;
    const char *printing="{\"printer\":{\"serial\":\"Form-123\",\"is_connected\":true,\"printer_status\":{\"status\":\"printing\",\"current_print_run\":{\"print_run_id\":\"run1\",\"name\":\"收纳盒\",\"status\":\"printing\",\"currently_printing_layer\":50,\"layer_count\":100,\"estimated_time_remaining_ms\":120000,\"material_name\":\"unknown\",\"print_settings_name\":\"Default\",\"front_cartridge\":\"good\",\"print_thumbnail\":{\"thumbnail\":\"https://bucket.s3.amazonaws.com/p.jpg\"}}},\"cartridge_status\":[{\"cartridge\":{\"serial\":\"other\",\"display_name\":\"Gray\"}},{\"cartridge\":{\"serial\":\"good\",\"display_name\":\"Clear V5\"}}]}}";
    assert(update(&state,printing,100,url));assert(state.progress==50&&state.remaining==2&&state.layer==50&&state.layer_count==100&&state.connected);
    assert(!strcmp(state.material,"Clear V5")&&!strcmp(state.task,"收纳盒")&&*state.thumbnail_key&&*url);
    char key[17];strcpy(key,state.thumbnail_key);
    assert(c6_print_eligible(&state,101));
    assert(update(&state,"{\"printer_status\":{\"status\":\"completed\",\"current_print_run\":null}}",200,url));
    assert(state.completed_at==200&&state.progress==100&&state.layer==100&&!strcmp(key,state.thumbnail_key)&&!strcmp(state.material,"Clear V5"));
    assert(update(&state,"{\"printer_status\":{\"status\":\"idle\",\"current_print_run\":null}}",300,url));assert(state.completed_at==200);
    assert(c6_print_eligible(&state,1999)&&!c6_print_eligible(&state,2000));
    assert(update(&state,"{\"printer_status\":{\"status\":\"printing\",\"current_print_run\":{\"print_run_id\":\"run2\",\"name\":\"新任务\",\"status\":\"printing\",\"elapsed_duration_ms\":100,\"estimated_duration_ms\":400}}}",2100,url));
    assert(state.progress==25&&state.completed_at==0&&strcmp(key,state.thumbnail_key)&&!state.material[0]&&!url[0]);
    c6_printer_state_t previous=state;assert(!update(&state,"{\"detail\":\"unauthorized\"}",2200,url));assert(!memcmp(&previous,&state,sizeof(state)));
    assert(!update(&state,"{\"serial\":\"other\",\"status\":\"idle\"}",2300,url));assert(!memcmp(&previous,&state,sizeof(state)));
    assert(update(&state,"{\"is_connected\":false,\"printer_status\":{\"status\":\"printing\",\"current_print_run\":{\"run_id\":\"run2\",\"name\":\"新任务\",\"status\":\"failed\"}}}",2400,url));
    assert(!state.connected&&!strcmp(state.status,"failed"));
    assert(update(&state,"{\"printer_status\":{\"status\":\"idle\",\"current_print_run\":null}}",2500,url));assert(!strcmp(state.status,"failed")&&!state.completed_at);
    // A missing run never proves success, including an online UNKNOWN shell.
    const char *missing_statuses[]={"idle","UNKNOWN","offline","failed","error","cancelled","canceled","aborted","finished","completed"};
    for(unsigned i=0;i<sizeof(missing_statuses)/sizeof(*missing_statuses);i++){
        memset(&state,0,sizeof(state));assert(update(&state,printing,100,url));
        char missing[256];snprintf(missing,sizeof(missing),"{\"is_connected\":true,\"printer_status\":{\"status\":\"%s\",\"current_print_run\":null}}",missing_statuses[i]);
        assert(update(&state,missing,200,url));
        bool finished=c6_print_finished(missing_statuses[i]);
        assert(state.progress==(finished?100:50)&&state.layer==(finished?100:50));
        assert(state.completed_at==(finished?200:0)&&!strcmp(state.status,missing_statuses[i]));
        assert(!strcmp(state.task,"收纳盒")&&!strcmp(state.material,"Clear V5")&&!strcmp(state.thumbnail_key,key));
        if(i==1||i==2){
            assert(!state.connected&&state.updated==100&&state.remaining==2&&state.remaining_updated==100);
            assert(update(&state,missing,300,url)&&state.updated==100&&!state.completed_at);
        }else assert(state.connected&&state.updated==200);
    }
    // Explicitly completed cached work survives later idle/unknown shells without
    // renewing the completion window or pretending the unknown data is current.
    assert(update(&state,"{\"printer_status\":{\"status\":\"idle\",\"current_print_run\":null}}",300,url));
    assert(state.completed_at==200&&state.progress==100&&!strcmp(state.status,"completed"));
    assert(update(&state,"{\"is_connected\":true,\"printer_status\":{\"status\":\"UNKNOWN\",\"current_print_run\":null}}",400,url));
    assert(state.completed_at==200&&state.updated==300&&!state.connected&&state.progress==100&&!strcmp(state.status,"completed"));
    assert(update(&state,"{\"is_connected\":false,\"printer_status\":{\"status\":\"printing\",\"current_print_run\":null}}",450,url));
    assert(!state.connected&&state.updated==300&&state.progress==100&&state.completed_at==200);
    assert(update(&state,"{\"printer_status\":{\"status\":\"failed\",\"current_print_run\":{\"print_run_id\":\"run1\",\"name\":\"收纳盒\",\"status\":\"failed\",\"currently_printing_layer\":50,\"layer_count\":100}}}",475,url));
    assert(!state.completed_at&&state.progress==50&&!strcmp(state.status,"failed"));
    // The official GUID is stable even if a legacy numeric id changes. A new
    // GUID with the same name/id must start a new task and discard old material.
    memset(&state,0,sizeof(state));
    assert(update(&state,"{\"status\":\"printing\",\"current_print_run\":{\"guid\":\"guid-one\",\"id\":1,\"name\":\"same\",\"status\":\"printing\",\"material_name\":\"Clear\",\"currently_printing_layer\":1,\"layer_count\":4}}",500,url));
    assert(!strcmp(state.job,"guid-one"));strcpy(key,state.thumbnail_key);
    assert(update(&state,"{\"status\":\"printing\",\"current_print_run\":{\"guid\":\"guid-one\",\"id\":2,\"name\":\"same\",\"status\":\"printing\",\"currently_printing_layer\":2,\"layer_count\":4}}",600,url));
    assert(!strcmp(state.thumbnail_key,key)&&!strcmp(state.material,"Clear")&&state.progress==50);
    assert(update(&state,"{\"status\":\"printing\",\"current_print_run\":{\"guid\":\"guid-two\",\"id\":2,\"name\":\"same\",\"status\":\"printing\",\"currently_printing_layer\":1,\"layer_count\":4}}",700,url));
    assert(strcmp(state.thumbnail_key,key)&&!strcmp(state.job,"guid-two")&&!state.material[0]&&state.progress==25);
    // Printer failure can precede the nested run's stale successful status.
    assert(update(&state,"{\"status\":\"failed\",\"current_print_run\":{\"guid\":\"guid-two\",\"status\":\"finished\",\"currently_printing_layer\":1,\"layer_count\":4}}",800,url));
    assert(!strcmp(state.status,"failed")&&state.progress==25&&!state.completed_at);
    puts("Formlabs actual parser: OAuth/thumbnail contracts, GUID identity, explicit terminal outcomes, unknown/offline cache freshness, task reset and completion-window retention passed");
}
