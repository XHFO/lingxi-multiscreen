// Actual endpoint + LAN/AP guards + actual NVS language serializer. No device.
import {readFileSync,mkdtempSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root=new URL('../../../',import.meta.url).pathname,src=root+'Tools/WaveshareC6Firmware/src/';
const main=readFileSync(src+'main.c','utf8');
const between=(a,b)=>{const i=main.indexOf(a),j=main.indexOf(b,i);assert(i>=0&&j>i);return main.slice(i,j);};
const lan=between('bool standalone_lan_pairing_allowed(', 'static void reconnect_task(');
const ap=between('static bool setup_request(', 'static esp_err_t captive_redirect(');
const contract=readFileSync(root+'Tools/C6StandaloneTests/firmware_contract.c','utf8')
    .replace('"../../Tools/WaveshareC6Firmware/src/standalone.c"',JSON.stringify(src+'standalone.c'))
    .replace('if(fail_storage)return ESP_ERR_NVS_NOT_ENOUGH_SPACE;','stored_writes++;if(fail_storage)return ESP_ERR_NVS_NOT_ENOUGH_SPACE;');
const c=`
#include <arpa/inet.h>
static int stored_writes;
#define main unused_contract_main
#define standalone_lan_pairing_allowed contract_lan_allowed
${contract}
#undef standalone_lan_pairing_allowed
#undef main
#include "lan_access.h"
#define HTTPD_403_FORBIDDEN 403
#define WIFI_MODE_STA 1
#define WIFI_MODE_APSTA 3
typedef int wifi_mode_t;
typedef struct {struct {uint32_t addr;} ip,netmask;} esp_netif_ip_info_t;
static int station=1,setup_ap=2,mode=WIFI_MODE_APSTA;
static uint32_t local4=0xc0a80401,peer4=0xc0a80402;
static char ip[]="192.168.8.42",hostname[]="xh-multiscreen-ABC123";
static const char *hostHeader="192.168.4.1",*originHeader="http://192.168.4.1",*customHeader="1",*lanHeader="1";
static int esp_wifi_get_mode(int *m){*m=mode;return ESP_OK;}
static int esp_netif_get_ip_info(int net,esp_netif_ip_info_t *out){out->ip.addr=htonl(net==setup_ap?0xc0a80401:0xc0a8082a);out->netmask.addr=htonl(0xffffff00);return ESP_OK;}
static int httpd_req_to_sockfd(httpd_req_t *r){return 1;}
static int fake_addr(struct sockaddr *out,socklen_t *size,uint32_t address){struct sockaddr_in v={.sin_family=AF_INET,.sin_addr.s_addr=htonl(address)};memcpy(out,&v,sizeof(v));*size=sizeof(v);return 0;}
static int fake_local(int fd,struct sockaddr *out,socklen_t *size){return fake_addr(out,size,local4);}
static int fake_peer(int fd,struct sockaddr *out,socklen_t *size){return fake_addr(out,size,peer4);}
#define getsockname fake_local
#define getpeername fake_peer
static const char *header(const char *key){return !strcmp(key,"Host")?hostHeader:!strcmp(key,"Origin")?originHeader:!strcmp(key,"X-Lingxi-LAN")?lanHeader:customHeader;}
static int lang_header(httpd_req_t *r,const char *key,char *out,size_t size){const char *v=header(key);if(!v||strlen(v)>=size)return ESP_FAIL;strcpy(out,v);return ESP_OK;}
static size_t lang_header_len(httpd_req_t *r,const char *key){const char *v=header(key);return v?strlen(v):0;}
#define httpd_req_get_hdr_value_str lang_header
#define httpd_req_get_hdr_value_len lang_header_len
${lan}
${ap}
static bool network_notice_drawn=true,setup_notice_drawn=true;
static uint32_t last_clock_second=3,view_revision;
static struct {int language,revision;} menu_draft;
static struct {unsigned revision;} device_menu;
static int options_calls;
static void c6_sources_display_options(int revision,bool flip){options_calls++;}
#include "formlabs_language.h"
static httpd_req_t language_send(const char *body){httpd_req_t r={.method=HTTP_POST,.body=body,.content_len=(int)strlen(body)};terminal_language_handler(&r);return r;}
static httpd_req_t change(int revision,int language){char b[80];snprintf(b,sizeof(b),"{\\"revision\\":%d,\\"language\\":%d}",revision,language);return language_send(b);}
int main(void){
 standalone_init();standalone_config.printer_count=3;standalone_config.rotation=270;
 for(unsigned i=0;i<3;i++){c6_printer_config_t *p=&standalone_config.printers[i];p->source_formlabs=p->enabled=true;p->rotate=i!=1;snprintf(p->serial,40,"FORM_%u",i);strcpy(p->name,"User name");strcpy(p->form_client_id,"fixture-account");strcpy(p->form_client_secret,"private-fixture");}
 strcpy(standalone_config.weather_city,"User city");standalone_config.sleep_mode=1;standalone_config.digit_style=1;
 standalone_config_t before=standalone_config;menu_draft.revision=before.revision;
 httpd_req_t r=change(before.revision,1);assert(r.status==200&&standalone_config.language==1&&standalone_config.revision==before.revision+1);
 assert(stored_writes==1&&options_calls==1&&applied==0&&!network_notice_drawn&&!setup_notice_drawn&&last_clock_second==UINT32_MAX&&view_revision==1&&device_menu.revision==1);
 assert(menu_draft.language==1&&menu_draft.revision==standalone_config.revision);
 standalone_config_t expected=before;expected.language=1;expected.revision++;assert(!memcmp(&expected,&standalone_config,sizeof(expected)));
 assert(!strstr(r.response,"private")&&!strstr(r.response,"token")&&!strstr(r.response,"FORM_"));
 r=change(standalone_config.revision,1);assert(r.status==200&&stored_writes==1&&options_calls==1);
 r=change(before.revision,0);assert(r.status==409&&stored_writes==1);
 const char *invalid[]={"{}","{\\"revision\\":1,\\"language\\":2}","{\\"revision\\":1,\\"language\\":0.5}","{\\"revision\\":1.5,\\"language\\":0}","{\\"revision\\":-1,\\"language\\":0}","{\\"revision\\":1,\\"language\\":\\"0\\"}","{\\"revision\\":1,\\"language\\":0,\\"brightness\\":9}","{\\"revision\\":1,\\"language\\":0}junk","{\\"revision\\":1,\\"revision\\":1,\\"language\\":0}"};
 for(unsigned i=0;i<sizeof(invalid)/sizeof(invalid[0]);i++){r=language_send(invalid[i]);assert(r.status==400&&stored_writes==1);}
 customHeader=NULL;r=change(1,0);assert(r.status==403);customHeader="1";
 originHeader="http://evil.example";r=change(1,0);assert(r.status==403);originHeader="http://192.168.4.1";
 hostHeader="evil.example";r=change(1,0);assert(r.status==403);hostHeader="192.168.4.1";
 peer4=0x08080808;r=change(1,0);assert(r.status==403);peer4=0xc0a80402;
 originHeader=NULL;r=change(1,1);assert(r.status==200); // non-browser local clients still need the custom header
 originHeader="http://192.168.4.1";
 assert(!standalone_lan_pairing_allowed(&r)); // language access never permits AP pairing
 mode=WIFI_MODE_STA;local4=0xc0a8082a;peer4=0xc0a80821;hostHeader="192.168.8.42";originHeader="http://192.168.8.42";
 fail_storage=1;r=change(1,0);assert(r.status==500&&standalone_config.language==1&&standalone_config.revision==1&&options_calls==1);fail_storage=0;
 r=change(1,0);assert(r.status==200&&standalone_config.language==0&&options_calls==2);
 unsigned writes=stored_writes;mode=WIFI_MODE_APSTA;r=change(2,1);assert(r.status==403&&stored_writes==writes);mode=WIFI_MODE_STA;
 lanHeader=NULL;r=change(2,1);assert(r.status==403);lanHeader="1";
 peer4=0x08080808;r=change(2,1);assert(r.status==403);peer4=0xc0a80821;
 hostHeader="192.168.8.42:81";originHeader="http://192.168.8.42:81";r=change(2,1);assert(r.status==403);
 hostHeader="192.168.8.42:80";originHeader="http://192.168.8.42:80";r=change(2,0);assert(r.status==200&&stored_writes==writes);
 puts("Actual language HTTP/NVS: local AP or STA/subnet only, same origin/header/Host, strict narrow CAS, no-op flash suppression, rollback and settings/secrets/menu-draft retention passed");
}
`;
const stage=mkdtempSync('/private/tmp/form-monitor-language.');writeFileSync(stage+'/test.c',c);
const cjson=(process.env.PLATFORMIO_CORE_DIR||process.env.HOME+'/.platformio')+'/packages/framework-espidf/components/json/cJSON';
let r=spawnSync('clang',['-std=c11','-D','C6_FORMLABS_ONLY=1','-I',root+'Tools/C6StandaloneTests/stubs','-I',src,'-I',root+'Tools/FormlabsC6Firmware/src','-I',cjson,stage+'/test.c',src+'local_state.c',cjson+'/cJSON.c','-lm','-o',stage+'/test'],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
r=spawnSync(stage+'/test',[],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);process.stdout.write(r.stdout);
assert(main.includes('.uri="/api/language",.method=HTTP_POST,.handler=terminal_language_handler'));
