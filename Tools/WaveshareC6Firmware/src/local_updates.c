#include "local_sources.h"
#include "form_demo.h"
#include "esp_ota_ops.h"
#include "esp_app_desc.h"
#include "esp_image_format.h"
#include "esp_system.h"
#include "esp_heap_caps.h"
#include "esp_random.h"
#include "mbedtls/sha256.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
static void restart(void *arg){vTaskDelay(pdMS_TO_TICKS(1500));esp_restart();}
static void confirm_boot(void *arg){vTaskDelay(pdMS_TO_TICKS(20000));esp_ota_mark_app_valid_cancel_rollback();vTaskDelete(NULL);}
static uint32_t boot_id;
static esp_err_t ota_handler(httpd_req_t *req) {
    if(!standalone_authorized(req))return ESP_OK;
    const esp_partition_t *part=esp_ota_get_next_update_partition(NULL);
    if(!part||req->content_len<1024||req->content_len>part->size)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid firmware size or OTA partition missing");
    char expected[65];
    if(httpd_req_get_hdr_value_str(req,"X-Firmware-SHA256",expected,sizeof(expected))!=ESP_OK||strlen(expected)!=64)
        return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"SHA256 required");
    esp_ota_handle_t handle;
    if(esp_ota_begin(part,req->content_len,&handle)!=ESP_OK)return httpd_resp_send_err(req,HTTPD_500_INTERNAL_SERVER_ERROR,"Could not start OTA");
    unsigned char *buffer=malloc(4096);if(!buffer){esp_ota_abort(handle);return ESP_FAIL;}
    mbedtls_sha256_context hash;mbedtls_sha256_init(&hash);mbedtls_sha256_starts(&hash,0);
    int left=req->content_len;bool valid=true,first=true;const char *failure="Firmware validation failed; current firmware unchanged";
    while(left>0) {
        int n=httpd_req_recv(req,(char*)buffer,left>4096?4096:left);if(n<=0){failure="Firmware upload incomplete; current firmware unchanged";valid=false;break;}
        if(first) {
            first=false;
            // esp_ota_end verifies chip/image integrity; also reject another project's firmware.
            const int required=sizeof(esp_image_header_t)+sizeof(esp_image_segment_header_t)+sizeof(esp_app_desc_t);
            while(n<required){int more=httpd_req_recv(req,(char*)buffer+n,required-n);if(more<=0){valid=false;break;}n+=more;}
            if(!valid)break;
            const esp_app_desc_t *desc=(const void*)(buffer+sizeof(esp_image_header_t)+sizeof(esp_image_segment_header_t));
            if(strncmp(desc->project_name,esp_app_get_description()->project_name,sizeof(desc->project_name))){failure="Firmware project mismatch; current firmware unchanged";valid=false;break;}
        }
        if(esp_ota_write(handle,buffer,n)!=ESP_OK){failure="Firmware write rejected; current firmware unchanged";valid=false;break;}mbedtls_sha256_update(&hash,buffer,n);left-=n;
    }
    unsigned char digest[32];mbedtls_sha256_finish(&hash,digest);mbedtls_sha256_free(&hash);free(buffer);
    char actual[65];for(unsigned i=0;i<32;i++)snprintf(actual+i*2,3,"%02x",digest[i]);
    if(!valid||left||strcmp(actual,expected)){esp_ota_abort(handle);return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,valid&&!left?"Firmware SHA256 mismatch; current firmware unchanged":failure);}
    if(esp_ota_end(handle)!=ESP_OK||esp_ota_set_boot_partition(part)!=ESP_OK)return httpd_resp_send_err(req,HTTPD_400_BAD_REQUEST,"Invalid ESP32-C6 image");
    httpd_resp_set_type(req,"application/json");esp_err_t result=httpd_resp_sendstr(req,"{\"accepted\":true,\"restarting\":true}");
    xTaskCreate(restart,"ota_restart",2048,NULL,3,NULL);return result;
}
static esp_err_t health_handler(httpd_req_t *req) {
    if(!standalone_authorized(req))return ESP_OK;
    static c6_source_snapshot_t s;
    httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    if(!c6_sources_try_snapshot(&s)){
        // Recovery path: no JSON heap allocation or indefinite source-lock wait.
        static char recovery[256];
        snprintf(recovery,sizeof(recovery),"{\"snapshot_available\":false,\"free_heap\":%lu,\"minimum_heap\":%lu,\"largest_free_block\":%lu,\"uptime_seconds\":%llu}",
            (unsigned long)esp_get_free_heap_size(),(unsigned long)esp_get_minimum_free_heap_size(),(unsigned long)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT),(unsigned long long)(c6_seconds()-1));
        return httpd_resp_sendstr(req,recovery);
    }
    cJSON *j=cJSON_CreateObject();if(!j){httpd_resp_set_status(req,"503 Service Unavailable");return httpd_resp_sendstr(req,"Low memory; retry later");}
    cJSON_AddBoolToObject(j,"snapshot_available",true);
    cJSON_AddStringToObject(j,"firmware",esp_app_get_description()->version);
    cJSON_AddNumberToObject(j,"boot_id",boot_id);
    cJSON_AddBoolToObject(j,"weather_cached",s.weather.valid&&s.weather.latitude==standalone_config.latitude&&s.weather.longitude==standalone_config.longitude);
    const char *weather_phases[]={"disabled","waiting_wifi","waiting_memory","fetching","cached","retrying"};
    cJSON_AddStringToObject(j,"weather_phase",s.weather_phase<6?weather_phases[s.weather_phase]:"unknown");
    cJSON_AddStringToObject(j,"config_restore",standalone_restore_status);
    cJSON_AddStringToObject(j,"config_save",standalone_save_status);
    cJSON_AddNumberToObject(j,"config_revision",standalone_config.revision);
    cJSON_AddBoolToObject(j,"standalone_enabled",standalone_config.enabled);
    cJSON_AddBoolToObject(j,"ha_configured",standalone_config.ha_enabled&&*standalone_config.ha_token);
    const char *phases[]={"disabled","waiting_wifi","connecting","authorizing","subscribing","connected","retrying","auth_rejected","subscription_rejected","low_memory"};
    cJSON_AddStringToObject(j,"ha_phase",s.ha_phase<10?phases[s.ha_phase]:"unknown");
    cJSON_AddNumberToObject(j,"uptime_seconds",c6_seconds()-1);cJSON_AddNumberToObject(j,"free_heap",esp_get_free_heap_size());
    cJSON_AddNumberToObject(j,"minimum_heap",esp_get_minimum_free_heap_size());cJSON_AddBoolToObject(j,"ha_connected",s.ha_connected);
    cJSON_AddNumberToObject(j,"largest_free_block",heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
    cJSON_AddNumberToObject(j,"ha_reconnects",s.ha_reconnects);cJSON_AddNumberToObject(j,"mqtt_reconnects",s.mqtt_reconnects);
    cJSON_AddNumberToObject(j,"dropped_messages",s.dropped_messages);cJSON *a=cJSON_AddArrayToObject(j,"printers");
    for(unsigned i=0;i<standalone_config.printer_count;i++) {
        cJSON *p=cJSON_CreateObject();cJSON_AddBoolToObject(p,"connected",s.printers[i].connected);
        cJSON_AddStringToObject(p,"brand",c6_printer_brand(&standalone_config.printers[i]));
        cJSON_AddStringToObject(p,"name",standalone_config.printers[i].name);cJSON_AddStringToObject(p,"serial",standalone_config.printers[i].serial);
        cJSON_AddStringToObject(p,"source",c6_printer_source(&standalone_config.printers[i]));
        cJSON_AddStringToObject(p,"status",s.printers[i].status);cJSON_AddNumberToObject(p,"progress",s.printers[i].progress);
        cJSON_AddBoolToObject(p,"progress_valid",s.printers[i].progress_valid);
        cJSON_AddBoolToObject(p,"demo",c6_form_is_demo(&standalone_config.printers[i]));
        if(standalone_config.printers[i].source_formlabs){const char *form_phases[]={"waiting","connected","retrying","auth_rejected","low_memory","demo"};cJSON_AddStringToObject(p,"source","formlabs");cJSON_AddStringToObject(p,"phase",s.form_phase[i]<6?form_phases[s.form_phase[i]]:"unknown");}
        cJSON_AddBoolToObject(p,"eligible",C6_FORMLABS_ONLY?(standalone_config.printers[i].enabled&&standalone_config.printers[i].rotate):c6_print_eligible(&s.printers[i],c6_seconds()));cJSON_AddItemToArray(a,p);
    }
    char *body=cJSON_PrintUnformatted(j);cJSON_Delete(j);if(!body)return ESP_FAIL;
    httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");
    esp_err_t result=httpd_resp_sendstr(req,body);cJSON_free(body);return result;
}
void c6_register_updates(httpd_handle_t server) {
    boot_id=esp_random();
    httpd_uri_t ota={.uri="/api/ota",.method=HTTP_POST,.handler=ota_handler},health={.uri="/api/health",.method=HTTP_GET,.handler=health_handler};
    ESP_ERROR_CHECK(httpd_register_uri_handler(server,&ota));ESP_ERROR_CHECK(httpd_register_uri_handler(server,&health));
    xTaskCreate(confirm_boot,"ota_confirmation",2048,NULL,2,NULL);
}
