import {readFileSync,mkdtempSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import assert from 'node:assert/strict';
const root=new URL('../../',import.meta.url).pathname;
const source=readFileSync(join(root,'Tools/WaveshareC6Firmware/src/main.c'),'utf8');
const between=(a,b)=>source.slice(source.indexOf(a),source.indexOf(b,source.indexOf(a)));
const event=between('static void wifi_event(', 'bool standalone_lan_pairing_allowed(');
const lan=between('bool standalone_lan_pairing_allowed(', 'static void reconnect_task(');
const wifiWork=between('    if(__atomic_exchange_n(&station_joined_pending', '    if(network_notice&&!device_menu.depth)');
const pages=between('static unsigned local_pages(', 'static bool base_software_allowed(');
const stage=mkdtempSync(join(tmpdir(),'lingxi-c6-network-'));
const cjson=join(process.env.PLATFORMIO_CORE_DIR??join(process.env.HOME,'.platformio'),'packages/framework-espidf/components/json/cJSON');
const program=`
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>
#include "local_sources.h"
#include "lan_access.h"
#include "terminal_display_policy.h"
#define WIFI_EVENT 1
#define IP_EVENT 2
#define WIFI_EVENT_STA_START 1
#define WIFI_EVENT_STA_DISCONNECTED 2
#define IP_EVENT_STA_GOT_IP 3
#define WIFI_MODE_APSTA 3
#define WIFI_MODE_STA 1
#define IPSTR "%d.%d.%d.%d"
#define IP2STR(p) 192,168,1,8
typedef int esp_event_base_t;
typedef int wifi_mode_t;
typedef struct {struct {struct {unsigned addr;} ip,netmask;} ip_info;} ip_event_got_ip_t;
typedef struct {struct {unsigned addr;} ip,netmask;} esp_netif_ip_info_t;
static int station,mode=WIFI_MODE_APSTA,mode_error,closes,connects;
static unsigned retries,reconnect_at,revision;
static bool station_has_credentials,station_offline,station_joined_pending,network_notice,network_notice_drawn,native_clock;
static bool terminal_guide_offered,terminal_guide_qr,terminal_guide_empty,setup_notice_drawn;
static unsigned last_clock_second;static int brightness=80;
static void set_brightness(int b){}
static bool setup_display_notice(void){return false;}
static long long time_us,hotspot_close_at;
static char ip[16]="0.0.0.0",hostname[40]="lingxi-c6-test";
static const char *host="192.168.1.8",*header="1";
static unsigned peer_addr,local_addr,subnet=0xffffff00;
static int peer_error,local_error,peer_family=AF_INET,local_family=AF_INET,peer_short;
standalone_config_t standalone_config;
uint64_t c6_seconds(void){return 100;}
bool c6_print_eligible(const c6_printer_state_t *s,uint64_t now){return s->connected;}
static long long esp_timer_get_time(void){return time_us;}
static int esp_wifi_connect(void){connects++;return ESP_OK;}
static int esp_wifi_get_mode(int *out){*out=mode;return ESP_OK;}
static int esp_wifi_set_mode(int next){if(mode_error)return ESP_FAIL;mode=next;closes++;return ESP_OK;}
int httpd_req_get_hdr_value_str(httpd_req_t *r,const char *key,char *out,size_t n){const char *value=!strcmp(key,"Host")?host:header;if(!value)return ESP_FAIL;snprintf(out,n,"%s",value);return ESP_OK;}
static int httpd_req_to_sockfd(httpd_req_t *r){return 1;}
static void test_address(struct sockaddr *out,socklen_t *size,int family,unsigned address,bool short_address){
  struct sockaddr_storage value={0};socklen_t length;
  if(family==AF_INET){struct sockaddr_in *v=(void*)&value;v->sin_family=AF_INET;v->sin_addr.s_addr=htonl(address);length=sizeof(*v);}
  else {struct sockaddr_in6 *v=(void*)&value;v->sin6_family=family;v->sin6_addr.s6_addr[10]=255;v->sin6_addr.s6_addr[11]=255;unsigned network=htonl(address);memcpy(v->sin6_addr.s6_addr+12,&network,4);length=sizeof(*v);}
  if(short_address)length=sizeof(struct sockaddr_in);
  if(length>*size)length=*size;memcpy(out,&value,length);*size=length;
}
static int test_peer(int fd,struct sockaddr *out,socklen_t *size){test_address(out,size,peer_family,peer_addr,peer_short);return peer_error;}
static int test_local(int fd,struct sockaddr *out,socklen_t *size){test_address(out,size,local_family,local_addr,false);return local_error;}
#define getpeername test_peer
#define getsockname test_local
static int esp_netif_get_ip_info(int s,esp_netif_ip_info_t *out){out->ip.addr=htonl(0xc0a80108);out->netmask.addr=htonl(subnet);return ESP_OK;}
${event}
${lan}
static void owner_work(long long now){${wifiWork}}
${pages}
int main(void){
  ip_event_got_ip_t data={0};wifi_event(NULL,IP_EVENT,IP_EVENT_STA_GOT_IP,&data);
  assert(station_joined_pending&&!network_notice&&!closes);
  owner_work(100);assert(network_notice&&hotspot_close_at==5000100&&!station_joined_pending&&!closes);
  owner_work(5000000);assert(!closes);owner_work(5000100);assert(closes==1&&mode==WIFI_MODE_STA&&!hotspot_close_at);
  peer_addr=0xc0a80109;local_addr=0xc0a80108;httpd_req_t req={0};assert(standalone_lan_pairing_allowed(&req));
  peer_family=AF_INET6;local_family=AF_INET6;assert(standalone_lan_pairing_allowed(&req));
  local_family=AF_INET;assert(standalone_lan_pairing_allowed(&req));
  peer_family=AF_INET;local_family=AF_INET6;assert(standalone_lan_pairing_allowed(&req));
  peer_family=AF_INET6;peer_short=1;assert(!standalone_lan_pairing_allowed(&req));peer_short=0;
  peer_family=AF_UNIX;assert(!standalone_lan_pairing_allowed(&req));peer_family=AF_INET;local_family=AF_INET;
  struct sockaddr_storage native6={0};struct sockaddr_in6 *v6=(void*)&native6;uint32_t normalized;
  v6->sin6_family=AF_INET6;v6->sin6_addr.s6_addr[0]=0x20;v6->sin6_addr.s6_addr[1]=1;
  assert(!c6_sockaddr_ipv4(&native6,sizeof(*v6),&normalized));
  memset(v6->sin6_addr.s6_addr,0,16);v6->sin6_addr.s6_addr[15]=1;
  assert(!c6_sockaddr_ipv4(&native6,sizeof(*v6),&normalized));
  const char *badHosts[]={"evil.example","192.168.1.8:8080","192.168.4.1"};for(unsigned i=0;i<3;i++){host=badHosts[i];assert(!standalone_lan_pairing_allowed(&req));}
  host="192.168.1.8:80";assert(standalone_lan_pairing_allowed(&req));host="lingxi-c6-test.local";assert(standalone_lan_pairing_allowed(&req));
  header=NULL;assert(!standalone_lan_pairing_allowed(&req));header="1";
  unsigned badPeers[]={0xc0a80209,0xc0a80100,0xc0a801ff,0x08080808,0xc0a80108};
  for(unsigned i=0;i<5;i++){peer_addr=badPeers[i];assert(!standalone_lan_pairing_allowed(&req));}
  peer_addr=0xc0a80109;mode=WIFI_MODE_APSTA;assert(!standalone_lan_pairing_allowed(&req));mode=WIFI_MODE_STA;local_addr=0xc0a80401;assert(!standalone_lan_pairing_allowed(&req));local_addr=0xc0a80108;
  peer_error=1;assert(!standalone_lan_pairing_allowed(&req));peer_error=0;local_error=1;assert(!standalone_lan_pairing_allowed(&req));local_error=0;
  mode=WIFI_MODE_APSTA;station_joined_pending=true;owner_work(100);station_offline=true;owner_work(6000000);assert(mode==WIFI_MODE_APSTA&&hotspot_close_at>6000000);
  station_offline=false;mode_error=1;owner_work(12000000);assert(mode==WIFI_MODE_APSTA);mode_error=0;owner_work(18000000);assert(mode==WIFI_MODE_STA);
  standalone_config=(standalone_config_t){.clock=true,.diagnostics=true,.weather=true,.ha_enabled=true,.entity_count=6,.printer_count=2,.card_mask=15};
  c6_source_snapshot_t s={0};unsigned p[12];for(unsigned i=0;i<2;i++){standalone_config.printers[i].enabled=true;standalone_config.printers[i].rotate=true;s.printers[i].connected=true;}
  assert(local_pages(p,&s)==8&&p[7]==TERMINAL_OVERVIEW_PAGE);standalone_config.card_mask=0;assert(local_pages(p,&s)==3);standalone_config.printers[0].rotate=false;assert(local_pages(p,&s)==2&&p[0]==21&&p[1]==TERMINAL_OVERVIEW_PAGE&&standalone_config.printers[0].enabled);
  standalone_config.printers[0].enabled=false;assert(local_pages(p,&s)==1&&p[0]==21);
  puts("C6 actual network/display code: open-AP handoff delay/retry, LAN subnet/Host/custom-header/local-interface guards, configured per-card rotation and source preservation passed");
}`;
const binary=join(stage,'test'),build=spawnSync('clang',['-std=c11','-I',cjson,'-I',join(root,'Tools/C6StandaloneTests/stubs'),'-I',join(root,'Tools/WaveshareC6Firmware/src'),'-x','c','-','-o',binary],{input:program,encoding:'utf8'});
assert.equal(build.status,0,build.stderr);const result=spawnSync(binary,[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim());
assert.match(source,/ap\.ap\.authmode=WIFI_AUTH_OPEN/);assert.ok(!source.includes('lingxi-c6-test"));ap.ap.authmode'));
