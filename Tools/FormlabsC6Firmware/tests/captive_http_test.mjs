import {readFileSync,mkdtempSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root=new URL('../../../',import.meta.url).pathname,source=readFileSync(root+'Tools/WaveshareC6Firmware/src/main.c','utf8');
const between=(start,end)=>{const a=source.indexOf(start),b=source.indexOf(end,a);assert(a>0&&b>a);return source.slice(a,b);};
const captive=between('static bool setup_request(', '\n#endif\nstatic esp_err_t root_handler(');
const guard=between('    char header[96],host[80],origin[96],expected[96];','\n#endif\n    char body[384]');
const program=`
#include <assert.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <arpa/inet.h>
#include "lan_access.h"
#define ESP_OK 0
#define ESP_FAIL -1
#define WIFI_MODE_APSTA 3
#define WIFI_MODE_STA 1
#define HTTP_GET 0
#define HTTP_POST 1
#define HTTPD_404_NOT_FOUND 404
#define HTTPD_403_FORBIDDEN 403
typedef int esp_err_t;
typedef int httpd_err_code_t;
typedef int wifi_mode_t;
typedef struct {int method,status;} httpd_req_t;
typedef struct {struct {uint32_t addr;} ip,netmask;} esp_netif_ip_info_t;
static int mode=WIFI_MODE_APSTA,setup_ap;
static uint32_t local4=0xc0a80401,peer4=0xc0a80402;
static const char *hostHeader="192.168.4.1",*originHeader="http://192.168.4.1",*customHeader="1";
static char ip[]="192.168.8.42",redirect[96];
static int esp_wifi_get_mode(int *out){*out=mode;return ESP_OK;}
static int esp_netif_get_ip_info(int unused,esp_netif_ip_info_t *out){out->ip.addr=htonl(0xc0a80401);out->netmask.addr=htonl(0xffffff00);return ESP_OK;}
static int httpd_req_to_sockfd(httpd_req_t *r){return 1;}
static int fake_addr(struct sockaddr *out,socklen_t *size,uint32_t address){struct sockaddr_in value={.sin_family=AF_INET,.sin_addr.s_addr=htonl(address)};memcpy(out,&value,sizeof(value));*size=sizeof(value);return 0;}
static int fake_local(int fd,struct sockaddr *out,socklen_t *size){return fake_addr(out,size,local4);}
static int fake_peer(int fd,struct sockaddr *out,socklen_t *size){return fake_addr(out,size,peer4);}
#define getsockname fake_local
#define getpeername fake_peer
static int httpd_resp_send_err(httpd_req_t *r,int code,const char *text){r->status=code;return ESP_OK;}
static int httpd_resp_set_status(httpd_req_t *r,const char *text){r->status=302;return ESP_OK;}
static int httpd_resp_set_hdr(httpd_req_t *r,const char *name,const char *value){if(!strcmp(name,"Location"))strcpy(redirect,value);return ESP_OK;}
static int httpd_resp_sendstr(httpd_req_t *r,const char *text){return ESP_OK;}
static int httpd_req_get_hdr_value_str(httpd_req_t *r,const char *key,char *out,size_t size){const char *v=!strcmp(key,"Host")?hostHeader:!strcmp(key,"Origin")?originHeader:customHeader;if(!v||strlen(v)>=size)return ESP_FAIL;strcpy(out,v);return ESP_OK;}
${captive}
static esp_err_t wifi_guard(httpd_req_t *req){${guard}\nreturn 7;}
int main(void){
 httpd_req_t req={.method=HTTP_GET};assert(setup_request(&req));captive_redirect(&req,404);assert(req.status==302&&!strcmp(redirect,"http://192.168.4.1/"));
 req=(httpd_req_t){.method=HTTP_POST};captive_redirect(&req,404);assert(req.status==404);
 req=(httpd_req_t){.method=HTTP_GET};peer4=0x08080808;assert(!setup_request(&req));captive_redirect(&req,404);assert(req.status==404);
 peer4=0xc0a80821;local4=0xc0a8082a;assert(!setup_request(&req));captive_redirect(&req,404);assert(req.status==404);
 local4=0xc0a80401;peer4=0xc0a80402;mode=WIFI_MODE_STA;assert(!setup_request(&req));mode=WIFI_MODE_APSTA;
 req=(httpd_req_t){.method=HTTP_POST};assert(wifi_guard(&req)==7);
 customHeader=NULL;assert(wifi_guard(&req)==0&&req.status==403);customHeader="1";
 originHeader="http://attacker.example";assert(wifi_guard(&req)==0&&req.status==403);originHeader="http://192.168.4.1";
 hostHeader="attacker.example";assert(wifi_guard(&req)==0&&req.status==403);
 mode=WIFI_MODE_STA;hostHeader="192.168.8.42";originHeader="http://192.168.8.42";local4=0xc0a8082a;peer4=0xc0a80821;assert(wifi_guard(&req)==7);
 hostHeader="192.168.8.42:81";originHeader="http://192.168.8.42:81";assert(wifi_guard(&req)==0&&req.status==403);
 puts("Actual captive HTTP: AP local-interface/subnet GET only, no LAN interception; Wi-Fi custom-header/same-origin/device-host guards passed");
}
`;
const stage=mkdtempSync('/private/tmp/form-monitor-captive-http.');writeFileSync(stage+'/test.c',program);
let result=spawnSync('clang',['-std=c11','-I',root+'Tools/WaveshareC6Firmware/src',stage+'/test.c','-o',stage+'/test'],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);
result=spawnSync(stage+'/test',[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);process.stdout.write(result.stdout);
