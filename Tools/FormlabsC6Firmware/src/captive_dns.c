#include "captive_dns.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "lwip/inet.h"
#include "dhcpserver/dhcpserver.h"
#include "esp_log.h"
#include <unistd.h>
static esp_netif_t *setup_interface;
static bool setup_active(void){wifi_mode_t mode;return esp_wifi_get_mode(&mode)==ESP_OK&&(mode==WIFI_MODE_APSTA||mode==WIFI_MODE_AP);}
static void captive_task(void *unused){
    (void)unused;int fd=-1;uint8_t packet[512];
    for(;;){
        esp_netif_ip_info_t info;
        if(!setup_active()||esp_netif_get_ip_info(setup_interface,&info)!=ESP_OK){if(fd>=0){close(fd);fd=-1;}vTaskDelay(pdMS_TO_TICKS(500));continue;}
        if(fd<0){
            fd=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);if(fd<0){vTaskDelay(pdMS_TO_TICKS(500));continue;}
            struct timeval timeout={.tv_sec=0,.tv_usec=250000};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
            struct sockaddr_in local={.sin_family=AF_INET,.sin_port=htons(53),.sin_addr.s_addr=info.ip.addr};
            if(bind(fd,(struct sockaddr*)&local,sizeof(local))<0){close(fd);fd=-1;vTaskDelay(pdMS_TO_TICKS(500));continue;}
        }
        struct sockaddr_in peer;socklen_t length=sizeof(peer);int n=recvfrom(fd,packet,sizeof(packet),0,(struct sockaddr*)&peer,&length);
        if(n<=0||!setup_active()||length!=sizeof(peer)||peer.sin_family!=AF_INET||peer.sin_addr.s_addr==info.ip.addr||(peer.sin_addr.s_addr&info.netmask.addr)!=(info.ip.addr&info.netmask.addr))continue;
        size_t response=c6_captive_answer(packet,(size_t)n,sizeof(packet),(const uint8_t*)&info.ip.addr);
        if(response)sendto(fd,packet,response,0,(struct sockaddr*)&peer,length);
    }
}
void c6_captive_dns_start(esp_netif_t *ap){
    setup_interface=ap;esp_netif_ip_info_t info;
    if(esp_netif_get_ip_info(ap,&info)==ESP_OK){
        esp_netif_dns_info_t dns={.ip.type=ESP_IPADDR_TYPE_V4};dns.ip.u_addr.ip4.addr=info.ip.addr;
        esp_netif_dhcps_stop(ap);
        esp_err_t result=esp_netif_set_dns_info(ap,ESP_NETIF_DNS_MAIN,&dns);
        dhcps_offer_t offer=OFFER_DNS;
        if(result==ESP_OK)result=esp_netif_dhcps_option(ap,ESP_NETIF_OP_SET,ESP_NETIF_DOMAIN_NAME_SERVER,&offer,sizeof(offer));
        if(result!=ESP_OK)ESP_LOGW("setup_dns","DHCP DNS offer unavailable (%d); use manual setup address",result);
        result=esp_netif_dhcps_start(ap);
        if(result!=ESP_OK&&result!=ESP_ERR_ESP_NETIF_DHCP_ALREADY_STARTED)ESP_LOGW("setup_dns","DHCP start pending (%d)",result);
    }
    if(xTaskCreate(captive_task,"setup_dns",3072,NULL,2,NULL)!=pdPASS)ESP_LOGW("setup_dns","Portal discovery unavailable; use manual setup address");
}
