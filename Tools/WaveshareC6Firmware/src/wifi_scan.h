#pragma once
#include "esp_http_server.h"
void c6_wifi_scan_init(void);
esp_err_t c6_wifi_scan_handler(httpd_req_t *req);
