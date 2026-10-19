#pragma once
#include <stddef.h>
#include <assert.h>
typedef int esp_err_t;
typedef void *httpd_handle_t;
#define ESP_OK 0
#define ESP_FAIL -1
#define ESP_ERROR_CHECK(x) assert((x)==ESP_OK)
#define HTTP_GET 0
#define HTTP_PUT 1
#define HTTP_POST 2
#define HTTPD_400_BAD_REQUEST 400
#define HTTPD_500_INTERNAL_SERVER_ERROR 500
typedef struct { int method,content_len,status,offset; const char *body,*auth,*card,*native,*origin,*group,*serial,*brand,*source; char response[16384]; } httpd_req_t;
typedef struct {const char *uri;int method;esp_err_t (*handler)(httpd_req_t*);} httpd_uri_t;
esp_err_t httpd_req_get_hdr_value_str(httpd_req_t*,const char*,char*,size_t);
size_t httpd_req_get_hdr_value_len(httpd_req_t*,const char*);
esp_err_t httpd_resp_set_status(httpd_req_t*,const char*);
esp_err_t httpd_resp_sendstr(httpd_req_t*,const char*);
esp_err_t httpd_resp_send_err(httpd_req_t*,int,const char*);
int httpd_req_recv(httpd_req_t*,char*,size_t);
esp_err_t httpd_resp_set_type(httpd_req_t*,const char*);
esp_err_t httpd_resp_set_hdr(httpd_req_t*,const char*,const char*);
esp_err_t httpd_register_uri_handler(httpd_handle_t,const httpd_uri_t*);
