#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
// Socket declarations must be included by the platform adapter first.
// ESP-IDF's dual-stack HTTP listener returns ::ffff:a.b.c.d even for IPv4
// clients. Normalize only that representation; native IPv6 is not LAN IPv4.
static inline bool c6_sockaddr_ipv4(const struct sockaddr_storage *address,
                                   socklen_t length,uint32_t *network_address){
    if(!address||!network_address)return false;
    if(address->ss_family==AF_INET&&length>=sizeof(struct sockaddr_in)){
        *network_address=((const struct sockaddr_in*)address)->sin_addr.s_addr;
        return true;
    }
    if(address->ss_family!=AF_INET6||length<sizeof(struct sockaddr_in6))return false;
    const uint8_t *bytes=((const struct sockaddr_in6*)address)->sin6_addr.s6_addr;
    for(unsigned i=0;i<10;i++)if(bytes[i])return false;
    if(bytes[10]!=0xff||bytes[11]!=0xff)return false;
    memcpy(network_address,bytes+12,sizeof(*network_address));
    return true;
}
// IPv4 arguments are in host byte order. Open setup APs and off-subnet peers
// never receive LAN authorization. Router/VPN forwarding is not allowed.
static inline bool c6_lan_peer(uint32_t peer,uint32_t local,uint32_t mask,bool setup_ap){
    bool private=(peer>>24)==10||(peer>>20)==0xAC1||(peer>>16)==0xC0A8;
    return !setup_ap&&local&&mask&&private&&peer!=local&&
        (peer&mask)==(local&mask)&&peer!=(local&mask)&&peer!=((local&mask)|~mask);
}
