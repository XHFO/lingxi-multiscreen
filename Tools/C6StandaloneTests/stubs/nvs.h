#pragma once
#include "esp_http_server.h"
typedef int nvs_handle_t;
#define NVS_READWRITE 1
#define ESP_ERR_NVS_NOT_FOUND -10
#define ESP_ERR_NVS_INVALID_LENGTH -11
#define ESP_ERR_NVS_NOT_ENOUGH_SPACE -12
#define ESP_ERR_NVS_VALUE_TOO_LONG -13
esp_err_t nvs_open(const char*,int,nvs_handle_t*);
esp_err_t nvs_get_str(nvs_handle_t,const char*,char*,size_t*);
esp_err_t nvs_set_str(nvs_handle_t,const char*,const char*);
esp_err_t nvs_get_blob(nvs_handle_t,const char*,void*,size_t*);
esp_err_t nvs_set_blob(nvs_handle_t,const char*,const void*,size_t);
esp_err_t nvs_erase_key(nvs_handle_t,const char*);
esp_err_t nvs_commit(nvs_handle_t);
void nvs_close(nvs_handle_t);
