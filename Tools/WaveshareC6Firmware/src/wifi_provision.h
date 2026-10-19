#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
enum { C6_WIFI_PROVISION_OFFSET=0x3f0000,C6_WIFI_PROVISION_SECTOR_BYTES=4096,
    C6_WIFI_PROVISION_RECORD_BYTES=116,C6_WIFI_PROVISION_CRC_OFFSET=112 };
typedef struct { char ssid[33],password[65];uint8_t ssid_len,password_len; } c6_wifi_credentials_t;
static inline uint32_t c6_wifi_crc32(const uint8_t *bytes,size_t size) {
    uint32_t crc=0xffffffff;
    for(size_t i=0;i<size;i++){crc^=bytes[i];for(unsigned bit=0;bit<8;bit++)crc=(crc>>1)^((crc&1)?0xedb88320:0);}
    return crc^0xffffffff;
}
static inline bool c6_wifi_provision_parse(const uint8_t *record,size_t size,c6_wifi_credentials_t *out) {
    if(!record||!out||size<C6_WIFI_PROVISION_RECORD_BYTES||memcmp(record,"LXC6WF01",8)||record[8]!=1||record[11]||record[110]||record[111])return false;
    unsigned ssid=record[9],password=record[10];
    if(!ssid||ssid>32||password>64||(password>0&&password<8))return false;
    for(unsigned i=0;i<33;i++)if(i<ssid?!record[12+i]:record[12+i]!=0)return false;
    for(unsigned i=0;i<65;i++) {
        uint8_t c=record[45+i];
        if(i<password?!c:c!=0)return false;
        if(i<password&&password==64&&!((c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F')))return false;
    }
    uint32_t stored=0;for(unsigned i=0;i<4;i++)stored|=(uint32_t)record[C6_WIFI_PROVISION_CRC_OFFSET+i]<<(8*i);
    if(stored!=c6_wifi_crc32(record,C6_WIFI_PROVISION_CRC_OFFSET))return false;
    memset(out,0,sizeof(*out));memcpy(out->ssid,record+12,ssid);memcpy(out->password,record+45,password);
    out->ssid_len=ssid;out->password_len=password;return true;
}
