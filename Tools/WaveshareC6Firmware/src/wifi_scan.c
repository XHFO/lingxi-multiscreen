// Scanning runs on a low-priority worker; the HTTP/display owner never waits
// for the radio. It never changes the saved network, connection or passwords.
#include "wifi_scan.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "cJSON.h"
#include <string.h>
#include <stdlib.h>
#define MAX_VISIBLE_NETWORKS 12
typedef struct { char ssid[33];int rssi;bool open; } network_t;
static SemaphoreHandle_t scan_lock;
static bool scanning;
static unsigned network_count;
static network_t networks[MAX_VISIBLE_NETWORKS];
static esp_err_t last_error;
void c6_wifi_scan_init(void){scan_lock=xSemaphoreCreateMutex();configASSERT(scan_lock);}
static void scan_worker(void *unused){
    wifi_scan_config_t config={.show_hidden=false,.scan_type=WIFI_SCAN_TYPE_PASSIVE,.scan_time.passive=120};
    esp_err_t error=esp_wifi_scan_start(&config,true);
    network_t found[MAX_VISIBLE_NETWORKS]={0};unsigned count=0;
    if(error==ESP_OK){
        uint16_t available=0;error=esp_wifi_scan_get_ap_num(&available);if(available>64)available=64;
        wifi_ap_record_t *records=available?calloc(available,sizeof(*records)):NULL;
        if(available&&!records)error=ESP_ERR_NO_MEM;
        if(error==ESP_OK&&available)error=esp_wifi_scan_get_ap_records(&available,records);
        if(error==ESP_OK)for(unsigned i=0;i<available&&count<MAX_VISIBLE_NETWORKS;i++){
            size_t length=strnlen((const char*)records[i].ssid,32);if(!length)continue;
            bool duplicate=false;for(unsigned n=0;n<count;n++)if(!strncmp(found[n].ssid,(const char*)records[i].ssid,33)){duplicate=true;break;}
            if(duplicate)continue;
            memcpy(found[count].ssid,records[i].ssid,length);found[count].rssi=records[i].rssi;found[count].open=records[i].authmode==WIFI_AUTH_OPEN;count++;
        }
        free(records);esp_wifi_clear_ap_list();
    }
    xSemaphoreTake(scan_lock,portMAX_DELAY);last_error=error;network_count=error==ESP_OK?count:0;memcpy(networks,found,sizeof(networks));scanning=false;xSemaphoreGive(scan_lock);
    vTaskDelete(NULL);
}
esp_err_t c6_wifi_scan_handler(httpd_req_t *req){
    char query[32],start[8];bool requested=httpd_req_get_url_query_str(req,query,sizeof(query))==ESP_OK&&httpd_query_key_value(query,"start",start,sizeof(start))==ESP_OK&&!strcmp(start,"1");
    xSemaphoreTake(scan_lock,portMAX_DELAY);
    if(requested&&!scanning){scanning=true;last_error=ESP_OK;network_count=0;if(xTaskCreate(scan_worker,"wifi_scan",4096,NULL,1,NULL)!=pdPASS){scanning=false;last_error=ESP_ERR_NO_MEM;}}
    bool busy=scanning;esp_err_t issue=last_error;unsigned count=network_count;network_t visible[MAX_VISIBLE_NETWORKS];memcpy(visible,networks,sizeof(visible));xSemaphoreGive(scan_lock);
    cJSON *root=cJSON_CreateObject();if(!root)return httpd_resp_send_err(req,HTTPD_500_INTERNAL_SERVER_ERROR,"Low memory");
    cJSON_AddBoolToObject(root,"busy",busy);cJSON_AddBoolToObject(root,"wifi_only_2g",true);cJSON_AddBoolToObject(root,"error",issue!=ESP_OK);
    if(issue!=ESP_OK)cJSON_AddStringToObject(root,"message",issue==ESP_ERR_WIFI_STATE?"设备正在连接网络，暂时无法扫描；稍后重试或手动填写 SSID。":"扫描未完成，请稍后重试或手动填写 SSID。");
    cJSON *list=cJSON_AddArrayToObject(root,"networks");if(list&&!busy&&!issue)for(unsigned i=0;i<count;i++){cJSON *item=cJSON_CreateObject();if(!item)continue;cJSON_AddStringToObject(item,"ssid",visible[i].ssid);cJSON_AddNumberToObject(item,"rssi",visible[i].rssi);cJSON_AddBoolToObject(item,"open",visible[i].open);cJSON_AddItemToArray(list,item);}
    char *body=cJSON_PrintUnformatted(root);cJSON_Delete(root);if(!body)return httpd_resp_send_err(req,HTTPD_500_INTERNAL_SERVER_ERROR,"Low memory");httpd_resp_set_type(req,"application/json");httpd_resp_set_hdr(req,"Cache-Control","no-store");esp_err_t result=httpd_resp_sendstr(req,body);cJSON_free(body);return result;
}
