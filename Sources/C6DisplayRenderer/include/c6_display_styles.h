#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
typedef enum { C6_WEATHER_CLEAR,C6_WEATHER_CLOUDY,C6_WEATHER_OVERCAST,C6_WEATHER_FOG,
    C6_WEATHER_DRIZZLE,C6_WEATHER_RAIN,C6_WEATHER_SNOW,C6_WEATHER_THUNDER,C6_WEATHER_UNKNOWN } c6_weather_kind_t;
typedef struct { c6_weather_kind_t kind;uint32_t background,surface,accent,secondary,cloud,sun; } c6_weather_style_t;
static inline c6_weather_kind_t c6_weather_kind(int code) {
    switch(code) {
        case 0:return C6_WEATHER_CLEAR;
        case 1:case 2:return C6_WEATHER_CLOUDY;
        case 3:return C6_WEATHER_OVERCAST;
        case 45:case 48:return C6_WEATHER_FOG;
        case 51:case 53:case 55:case 56:case 57:return C6_WEATHER_DRIZZLE;
        case 61:case 63:case 65:case 66:case 67:
        case 80:case 81:case 82:return C6_WEATHER_RAIN;
        case 71:case 73:case 75:case 77:case 85:case 86:return C6_WEATHER_SNOW;
        case 95:case 96:case 99:return C6_WEATHER_THUNDER;
        default:return C6_WEATHER_UNKNOWN;
    }
}
static inline c6_weather_style_t c6_weather_style(int code) {
    c6_weather_kind_t kind=c6_weather_kind(code);
    switch(kind) {
        case C6_WEATHER_CLEAR:case C6_WEATHER_CLOUDY:return (c6_weather_style_t){kind,0x4b99e4,0xbce6fa,0x08253f,0x08253f,0xf4faff,0xffd45e};
        case C6_WEATHER_OVERCAST:return (c6_weather_style_t){kind,0x8ea3b6,0xd1dae3,0x172c3f,0x172c3f,0xeff4f8,0xffd45e};
        case C6_WEATHER_FOG:return (c6_weather_style_t){kind,0xa8b7be,0xdce4e5,0x18313c,0x18313c,0xf3f7f8,0xffd45e};
        case C6_WEATHER_DRIZZLE:return (c6_weather_style_t){kind,0x739cab,0xbbcfd9,0x102b3e,0x102b3e,0xe5f0f5,0xffd45e};
        case C6_WEATHER_RAIN:return (c6_weather_style_t){kind,0x7d96aa,0xc2d0de,0x0e283f,0x0e283f,0xe1ebf2,0xffd45e};
        case C6_WEATHER_SNOW:return (c6_weather_style_t){kind,0x94b8ce,0xdfedf5,0x102c43,0x102c43,0xffffff,0xffd45e};
        case C6_WEATHER_THUNDER:return (c6_weather_style_t){kind,0x333c62,0x5a6785,0xf8fafc,0xf8fafc,0x4a5572,0xffe57c};
        default:return (c6_weather_style_t){kind,0x789cb8,0xc4d9e8,0x102b41,0x102b41,0xeff7fc,0xffd45e};
    }
}
static inline uint32_t c6_weather_background_at(c6_weather_style_t style,int y) {
    if(y<0)y=0;
    if(y>239)y=239;
    uint32_t color=0;
    for(int shift=16;shift>=0;shift-=8) {
        int top=(style.background>>shift)&255,bottom=(style.surface>>shift)&255;
        int difference=bottom-top;
        color|=(uint32_t)(top+(difference*y+(difference>=0?119:-119))/239)<<shift;
    }
    return color;
}
static inline const char *c6_weather_label(int code) {
    switch(c6_weather_kind(code)) {
        case C6_WEATHER_CLEAR:return "晴";
        case C6_WEATHER_CLOUDY:return code==1?"少云":"多云";
        case C6_WEATHER_OVERCAST:return "阴";
        case C6_WEATHER_FOG:return "雾";
        case C6_WEATHER_DRIZZLE:return "小雨";
        case C6_WEATHER_RAIN:return "雨";
        case C6_WEATHER_SNOW:return "雪";
        case C6_WEATHER_THUNDER:return "雷雨";
        default:return "未知";
    }
}
static inline bool c6_weather_wet(c6_weather_kind_t kind) {
    return kind==C6_WEATHER_DRIZZLE||kind==C6_WEATHER_RAIN||kind==C6_WEATHER_SNOW||kind==C6_WEATHER_THUNDER;
}
static inline const char *c6_weather_label_en(int code){
    static const char *labels[]={"SUNNY","CLOUDY","OVERCAST","FOG","DRIZZLE","RAIN","SNOW","THUNDER","UNKNOWN"};
    int kind=(int)c6_weather_kind(code);return labels[kind>=0&&kind<8?kind:8];
}
enum { C6_FLIP_CARD_Y=72,C6_FLIP_CARD_WIDTH=46,C6_FLIP_CARD_HEIGHT=86,
    C6_FLIP_DIGIT_WIDTH=40,C6_FLIP_DIGIT_HEIGHT=60,C6_FLIP_SEAM_Y=114 };
static inline int c6_flip_card_x(unsigned index){return index<2?16+(int)index*48:130+((int)index-2)*48;}
// Convert the canonical big-endian RGB565 buffer only at the LCD boundary.
// Rotation plus byte-swap is an involution, so the second call restores it.
static inline void c6_lcd_transform(uint8_t *frame,size_t bytes,bool rotated) {
    if(!rotated){for(size_t i=0;i+1<bytes;i+=2){uint8_t a=frame[i];frame[i]=frame[i+1];frame[i+1]=a;}return;}
    for(size_t i=0;i+1<bytes;i+=2) {
        size_t other=bytes-2-i;if(i>other)break;
        if(i==other){uint8_t a=frame[i];frame[i]=frame[i+1];frame[i+1]=a;break;}
        uint8_t high=frame[i],low=frame[i+1];
        frame[i]=frame[other+1];frame[i+1]=frame[other];frame[other]=low;frame[other+1]=high;
    }
}
