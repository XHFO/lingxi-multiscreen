#include "include/c6_display_renderer.h"
#include "include/c6_display_styles.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "aa_font.inc"
#ifndef C6_FORMLABS_ONLY
#define C6_FORMLABS_ONLY 0
#endif
#if C6_FORMLABS_ONLY
static void terminal_clock(c6_renderer_t *,const c6_render_clock_t *);
static void terminal_menu(c6_renderer_t *,const char *,const c6_render_menu_row_t *,unsigned,unsigned,const char *);
static void terminal_weather(c6_renderer_t *,const c6_render_weather_t *);
static void terminal_printer(c6_renderer_t *,const c6_render_printer_t *);
static bool terminal_setup_qr(c6_renderer_t *,const char *,const char *,const char *,const char *);
#endif

static uint16_t color24(uint32_t c){return ((c>>8)&0xf800)|((c>>5)&0x7e0)|((c>>3)&31);}
#ifdef C6_RENDER_LAYOUT_TEST
extern void c6_layout_test_pixel(int,int,uint16_t);
extern void c6_layout_test_group(unsigned);
extern void c6_layout_test_text(const char *,bool);
#endif
static void pixel(c6_renderer_t *r,int x,int y,uint16_t c){
#ifdef C6_RENDER_LAYOUT_TEST
    c6_layout_test_pixel(x,y,c);
#endif
    if(x<0||x>=240||y<0||y>=240)return;
    size_t i=(y*240+x)*2;r->frame[i]=c>>8;r->frame[i+1]=c;
}
#include "terminal_pixel_font.h"
#include "terminal_aero_digits.h"
#include "terminal_language.h"
#include "weather_scene.h"
static void terminal_smooth_blend(c6_renderer_t *r,int x,int y,uint32_t ink,unsigned alpha){
    if(x<0||x>=240||y<0||y>=240||!alpha)return;
    pixel(r,x,y,color24(weather_mix24(weather_pixel24(r,x,y),ink,alpha)));
}
static void fill(c6_renderer_t *r,uint32_t color){for(int y=0;y<240;y++)for(int x=0;x<240;x++)pixel(r,x,y,color24(color));}
static unsigned next_code(const char **s){unsigned char a=*(*s)++;if(a<128)return a;unsigned count=(a&0xe0)==0xc0?1:(a&0xf0)==0xe0?2:(a&0xf8)==0xf0?3:0;if(!count)return '?';unsigned code=a&((1U<<(6-count))-1);for(unsigned i=0;i<count;i++){unsigned char b=**s;if(!b||(b&0xc0)!=0x80)return '?';(*s)++;code=(code<<6)|(b&63);}return code;}
static const aa_glyph_t *font_glyph(unsigned code,bool large){
    const aa_glyph_t *glyphs=large?aa_large_glyphs:aa_body_glyphs;unsigned left=0,right=large?sizeof(aa_large_glyphs)/sizeof(*glyphs):sizeof(aa_body_glyphs)/sizeof(*glyphs);
    while(left<right){unsigned mid=(left+right)/2;if(glyphs[mid].code<code)left=mid+1;else right=mid;}
    unsigned count=large?sizeof(aa_large_glyphs)/sizeof(*glyphs):sizeof(aa_body_glyphs)/sizeof(*glyphs);
    if(left<count&&glyphs[left].code==code)return &glyphs[left];
    return !large&&code!='?'?font_glyph('?',false):NULL;
}
static bool font_load(c6_renderer_t *r,const aa_glyph_t *g,bool large){
    if(r->cached_group==g->group&&r->cached_font==(unsigned)large)return true;
    const aa_group_t *group=(large?aa_large_groups:aa_body_groups)+g->group;
    const uint8_t *src=(large?aa_large_data:aa_body_data)+group->offset;size_t in=0,out=0;
    if(group->raw>C6_AA_CACHE_BYTES)return false;
    while(in<group->compressed){unsigned token=src[in++];if(token&128){unsigned count=(token&127)+3;if(in+2>group->compressed)return false;unsigned distance=src[in]|((unsigned)src[in+1]<<8);in+=2;if(!distance||distance>out||out+count>group->raw)return false;for(unsigned i=0;i<count;i++){r->glyph_cache[out]=r->glyph_cache[out-distance];out++;}}
        else{unsigned count=token+1;if(in+count>group->compressed||out+count>group->raw)return false;memcpy(r->glyph_cache+out,src+in,count);in+=count;out+=count;}}
    if(out!=group->raw)return false;
    r->cached_group=g->group;r->cached_font=large;return true;
}
static unsigned font_sample(c6_renderer_t *r,const aa_glyph_t *g,int x,int y){if(x<0||y<0||x>=g->width||y>=g->height)return 0;unsigned bits=r->cached_font?AA_LARGE_BITS:AA_BODY_BITS,per_byte=8/bits,levels=(1U<<bits)-1,pos=y*g->width+x;return ((r->glyph_cache[g->offset+pos/per_byte]>>(8-bits-bits*(pos%per_byte)))&levels)*255/levels;}
static unsigned font_bilinear(c6_renderer_t *r,const aa_glyph_t *g,int sx,int sy){int x=sx>>8,y=sy>>8;unsigned fx=sx&255,fy=sy&255;unsigned a=font_sample(r,g,x,y)*(256-fx)+font_sample(r,g,x+1,y)*fx,b=font_sample(r,g,x,y+1)*(256-fx)+font_sample(r,g,x+1,y+1)*fx;return (a*(256-fy)+b*fy+32768)>>16;}
static const aa_glyph_t *sized_glyph(unsigned code,unsigned size,bool *large){
    *large=false;
    if(size>=28){const aa_glyph_t *g=font_glyph(code,true);if(g){*large=true;return g;}}
    return font_glyph(code,false);
}
static int glyph_advance(const aa_glyph_t *g,unsigned size,bool large){unsigned base=large?AA_LARGE_SIZE:AA_BODY_SIZE;return (g->advance*(int)size+(int)base/2)/(int)base;}
static int code_advance(unsigned code,unsigned size){
#if C6_FORMLABS_ONLY
    if(terminal_hero_code(code,size))return (int)terminal_hero_scale(size)*14;
    if(terminal_pixel_rows(code))return terminal_pixel_advance(size);
#endif
    bool large;const aa_glyph_t *g=sized_glyph(code,size,&large);return g?glyph_advance(g,size,large):0;}
int c6_renderer_text_width(const char *text,unsigned size){int width=0;if(!text)return 0;while(*text)width+=code_advance(next_code(&text),size);return width;}
static void text_weight(c6_renderer_t *r,const char *s,int x,int baseline,unsigned size,int max_width,uint32_t color,bool bold){
    if(!s||!size)return;
#if C6_FORMLABS_ONLY && defined(C6_RENDER_LAYOUT_TEST)
    c6_layout_test_text(s,r->english);
#endif
    int start=x;
    while(*s){unsigned code=next_code(&s);
#if C6_FORMLABS_ONLY
        if(terminal_hero_code(code,size)){int advance=(int)terminal_hero_scale(size)*14;if(x+advance>start+max_width)break;terminal_hero_text(r,code,x,baseline,size,color);x+=advance;continue;}
        const uint8_t *rows=terminal_pixel_rows(code);if(rows){int advance=terminal_pixel_advance(size);if(x+advance>start+max_width)break;terminal_pixel_text(r,rows,x,baseline,size,color);x+=advance;continue;}
#endif
        bool large;const aa_glyph_t *g=sized_glyph(code,size,&large);if(!g)continue;int advance=glyph_advance(g,size,large);if(x+advance>start+max_width)break;if(font_load(r,g,large)){
        int base=large?AA_LARGE_SIZE:AA_BODY_SIZE;
        int left=x+g->left*(int)size/base,top=baseline+g->top*(int)size/base,w=(g->width*(int)size+base-1)/base,h=(g->height*(int)size+base-1)/base;
        for(int y=0;y<h;y++)for(int xx=0;xx<w+(bold?1:0);xx++){int sx=xx*base*256/(int)size,sy=y*base*256/(int)size;unsigned alpha=font_bilinear(r,g,sx,sy);if(bold){unsigned weighted=font_bilinear(r,g,sx-128,sy);if(weighted>alpha)alpha=weighted;}weather_blend_pixel(r,left+xx,top+y,color,alpha);}}
        x+=advance;
    }
}
static void text(c6_renderer_t *r,const char *s,int x,int baseline,unsigned size,int max_width,uint32_t color){text_weight(r,s,x,baseline,size,max_width,color,false);}
static unsigned fit_size(const char *s,unsigned size,int width){while(size>12&&c6_renderer_text_width(s,size)>width)size--;return size;}
static void center_text(c6_renderer_t *r,const char *s,int cx,int baseline,unsigned size,int max_width,uint32_t color){size=fit_size(s,size,max_width);text(r,s,cx-c6_renderer_text_width(s,size)/2,baseline,size,max_width,color);}
static void rect(c6_renderer_t *r,int x,int y,int w,int h,int radius,uint32_t color){for(int yy=0;yy<h;yy++)for(int xx=0;xx<w;xx++){int dx=xx<radius?radius-xx:xx>w-radius-1?xx-(w-radius-1):0,dy=yy<radius?radius-yy:yy>h-radius-1?yy-(h-radius-1):0;if(dx*dx+dy*dy<=radius*radius)pixel(r,x+xx,y+yy,color24(color));}}
static bool inside_round(int x,int y,int w,int h,int radius){if(x<0||y<0||x>=w||y>=h)return false;int dx=x<radius?radius-x:x>w-radius-1?x-(w-radius-1):0,dy=y<radius?radius-y:y>h-radius-1?y-(h-radius-1):0;return dx*dx+dy*dy<=radius*radius;}
static void stroke_rect(c6_renderer_t *r,int x,int y,int w,int h,int radius,uint32_t color){for(int yy=0;yy<h;yy++)for(int xx=0;xx<w;xx++)if(inside_round(xx,yy,w,h,radius)&&!inside_round(xx-1,yy-1,w-2,h-2,radius>0?radius-1:0))pixel(r,x+xx,y+yy,color24(color));}
c6_render_style_t c6_renderer_default_style(void){return (c6_render_style_t){.background=0x080b12,.card=0x111827,.inset=0x0b1220,.border=0x26344a,.accent=0x55e6b8,.secondary_accent=0x60a5fa,.primary_text=0xf8fafc,.secondary_text=0xb9c4d6,.tertiary_text=0x8a9ab0,.enabled=true};}
static c6_render_style_t resolved_style(const c6_render_style_t *style){return style&&style->enabled?*style:c6_renderer_default_style();}
static double color_luminance(uint32_t color){double value=0;const double weights[]={.2126,.7152,.0722};for(unsigned i=0;i<3;i++){double channel=((color>>(16-i*8))&255)/255.0;value+=weights[i]*(channel<=.04045?channel/12.92:pow((channel+.055)/1.055,2.4));}return value;}
static uint32_t legible_ink(uint32_t ink,uint32_t surface,uint32_t fallback){
    double background=color_luminance(surface);
    for(unsigned i=0;i<12;i++){double foreground=color_luminance(ink),contrast=(fmax(foreground,background)+.05)/(fmin(foreground,background)+.05);if(contrast>=4.5)return ink;ink=weather_mix24(ink,fallback,32);}
    return fallback;
}
static const char *line_end(const char *s,unsigned size,int width){const char *start=s,*space=NULL;int measured=0;while(*s){const char *next=s;int step=code_advance(next_code(&next),size);if(measured+step>width)break;if(*s==' ')space=s;measured+=step;s=next;}return *s&&space&&space>start?space:s;}
static const char *skip_spaces(const char *s){while(*s==' ')s++;return s;}
// Optional aerospace numerals use the same original 4-bit atlas as the
// dedicated monitor. Only hero numbers opt in; body text and legacy metrics
// remain unchanged, and rendering needs no second frame or font cache.
static void display_number(c6_renderer_t *r,const char *s,int x,int baseline,unsigned size,int width,uint32_t ink){
    if(!r->smooth_digits){text_weight(r,s,x,baseline,size,width,ink,true);return;}
    int start=x;
    while(s&&*s){const char *first=s;unsigned code=next_code(&s);int advance=code_advance(code,size);if(x+advance>start+width)break;
        if(code>='0'&&code<='9'&&size>=28){unsigned w=advance>3?(unsigned)advance-3:1,h=size;
            for(unsigned y=0;y<h;y++)for(unsigned xx=0;xx<w;xx++){
                int sx=(int)((xx*256+128)*42/w)-128,sy=(int)((y*256+128)*60/h)-128;
                terminal_smooth_blend(r,x+(int)xx,baseline-(int)h+(int)y,ink,terminal_smooth_alpha(code-'0',sx,sy));
            }
        }else{char glyph[8];size_t bytes=(size_t)(s-first);if(bytes>7)bytes=7;memcpy(glyph,first,bytes);glyph[bytes]=0;text_weight(r,glyph,x,baseline,size,advance,ink,true);}
        x+=advance;
    }
}
// Baselines and advances are identical for English and CJK. The final line has
// a real ellipsis instead of silently chopping a word or a UTF-8 codepoint.
static unsigned label_lines(c6_renderer_t *r,const char *s,int x,int top,unsigned preferred,unsigned minimum,int width,unsigned lines,bool center,uint32_t color,bool bold){
    if(!s||!*s||width<=0||!lines)return 0;
    unsigned size=preferred;
    while(size>minimum){const char *end=s;for(unsigned n=0;n<lines&&*end;n++)end=skip_spaces(line_end(end,size,width));if(!*end)break;size--;}
    unsigned used=0;
    while(*s&&used<lines){const char *end=line_end(s,size,width);bool ellipsis=used+1==lines&&*end;int room=ellipsis?width-c6_renderer_text_width("…",size):width;
        if(ellipsis){end=s;int measured=0;while(*end){const char *next=end;int step=code_advance(next_code(&next),size);if(measured+step>room)break;measured+=step;end=next;}}
        char line[256];size_t bytes=(size_t)(end-s);while(bytes&&s[bytes-1]==' ')bytes--;if(bytes>sizeof(line)-5){bytes=sizeof(line)-5;while(bytes&&((unsigned char)s[bytes]&0xc0)==0x80)bytes--;ellipsis=true;}
        memcpy(line,s,bytes);line[bytes]=0;if(ellipsis)strcat(line,"…");
        int measured=c6_renderer_text_width(line,size),height=(int)size,gap=2;
#if C6_FORMLABS_ONLY
        if(height<(int)terminal_pixel_scale(size)*7)height=(int)terminal_pixel_scale(size)*7;
        gap=4;
#endif
        text_weight(r,line,x+(center?(width-measured)/2:0),top+height+(int)used*(height+gap),size,width,color,bold);
        used++;if(end==s)break;s=skip_spaces(end);
    }
    return used;
}
static void header(c6_renderer_t *r,const char *title,const char *subtitle){fill(r,0x080d18);text(r,title,18,33,fit_size(title,20,204),204,0xf8fafc);if(subtitle)text(r,subtitle,18,52,12,204,0x9eadc2);for(int x=18;x<222;x++)pixel(r,x,61,color24(0x2b3b50));}
static const char *wrapped_line(c6_renderer_t *r,const char *s,int x,int baseline,unsigned size,int width,uint32_t color){if(!s)return "";const char *start=s,*space=NULL;int measured=0;while(*s){const char *next=s;int step=code_advance(next_code(&next),size);if(measured+step>width)break;if(*s==' ')space=s;measured+=step;s=next;}if(*s&&space&&space>start)s=space;char line[256];size_t n=(size_t)(s-start);if(n>=sizeof(line))n=sizeof(line)-1;memcpy(line,start,n);line[n]=0;text(r,line,x,baseline,size,width,color);while(*s==' ')s++;return s;}
bool c6_renderer_init(c6_renderer_t *r,uint8_t *frame,size_t capacity){if(!r||!frame||capacity<C6_RENDER_BYTES)return false;r->frame=frame;r->capacity=capacity;r->cached_group=UINT16_MAX;r->cached_font=255;r->english=false;r->smooth_digits=false;return true;}
size_t c6_renderer_font_bytes(void){return sizeof(aa_body_glyphs)+sizeof(aa_large_glyphs)+sizeof(aa_body_groups)+sizeof(aa_large_groups)+sizeof(aa_body_data)+sizeof(aa_large_data);}
void c6_renderer_label(c6_renderer_t *r,const char *s,int x,int baseline,unsigned size,int max_width,uint32_t color){text(r,s,x,baseline,size,max_width,color);}
void c6_renderer_calibrate(c6_renderer_t *r,int saturation,int contrast){
    if(saturation<50)saturation=50;
    if(saturation>200)saturation=200;
    if(contrast<75)contrast=75;
    if(contrast>150)contrast=150;
    if(saturation==100&&contrast==100)return;
    double s=saturation/100.0,c=contrast/100.0;
    int channel=(int)lround(s*c*16384),red=(int)lround((1-s)*c*.2126*16384),green=(int)lround((1-s)*c*.7152*16384);
    int blue=(int)lround(c*16384)-channel-red-green,bias=(int)lround((1-c)*.5*16384)*255+8192;
    for(size_t i=0;i<C6_RENDER_BYTES;i+=2){
        unsigned color=((unsigned)r->frame[i]<<8)|r->frame[i+1];
        int rgb[3]={(int)((color>>11)*255/31),(int)(((color>>5)&63)*255/63),(int)((color&31)*255/31)};
        int common=red*rgb[0]+green*rgb[1]+blue*rgb[2]+bias;
        for(unsigned n=0;n<3;n++){int value=(channel*rgb[n]+common)>>14;rgb[n]=value<0?0:value>255?255:value;}
        uint16_t corrected=color24(((unsigned)rgb[0]<<16)|((unsigned)rgb[1]<<8)|rgb[2]);
        r->frame[i]=corrected>>8;r->frame[i+1]=corrected;
    }
}
static bool same_ascii(const char *a,const char *b){while(*a&&*b){unsigned char c=*a++;if(c>='A'&&c<='Z')c+=32;if(c!=(unsigned char)*b++)return false;}return !*a&&!*b;}
const char *c6_renderer_print_status(const char *raw){
    if(!raw||!*raw)return "等待状态";
    static const char *form_pairs[][2]={{"complete","已完成"},{"preprint","准备中"},{"pre_print","准备中"},{"postprint","后处理中"},{"post_print","后处理中"},{"cancelled","已取消"},{"canceled","已取消"},{"aborted","已终止"}};
    for(unsigned i=0;i<sizeof(form_pairs)/sizeof(*form_pairs);i++)if(same_ascii(raw,form_pairs[i][0]))return form_pairs[i][1];
    static const char *pairs[][2]={{"idle","空闲"},{"printing","打印中"},{"running","打印中"},{"pause","已暂停"},{"paused","已暂停"},{"error","报错"},{"standby","待机"},{"off","关机"},{"offline","离线"},{"completed","已完成"},{"finish","已完成"},{"finished","已完成"},{"busy","忙碌"},{"preparing","准备中"},{"prepare","准备中"},{"init","初始化中"},{"slicing","切片中"},{"unloading","退料中"},{"loading","进料中"},{"cooling","冷却中"},{"heating","加热中"},{"calibrating","校准中"},{"failed","失败"},{"unknown","未知"}};
    for(unsigned i=0;i<sizeof(pairs)/sizeof(*pairs);i++)if(same_ascii(raw,pairs[i][0]))return pairs[i][1];
    return raw;
}
void c6_renderer_message(c6_renderer_t *r,const char *title,const char *message){header(r,title,NULL);const char *tail=wrapped_line(r,message,18,109,18,204,0xf8fafc);if(*tail)wrapped_line(r,tail,18,134,18,204,0xf8fafc);}
void c6_renderer_menu(c6_renderer_t *r,const char *title,const c6_render_menu_row_t *rows,unsigned count,unsigned selected,const char *footer,const c6_render_style_t *style){
#if C6_FORMLABS_ONLY
    terminal_menu(r,title,rows,count,selected,footer);return;
#endif
    c6_render_style_t c=resolved_style(style);fill(r,c.background);
    rect(r,6,6,228,228,16,c.card);stroke_rect(r,6,6,228,228,16,c.border);
    label_lines(r,c6_renderer_localized(r,title),18,12,22,16,count>3?162:204,1,false,legible_ink(c.primary_text,c.card,c.primary_text),true);
    for(int x=18;x<222;x++)pixel(r,x,45,color24(c.border));
    if(count){bool selectable=selected<count;unsigned first=selectable?(selected/3)*3:0;
        if(count>3){char page[32];snprintf(page,sizeof(page),"%u/%u",first/3+1,(count+2)/3);text(r,page,186,32,12,36,legible_ink(c.secondary_text,c.card,c.primary_text));}
        for(unsigned i=first;i<count&&i<first+3;i++){
            int y=55+(i-first)*50;bool chosen=selectable&&i==selected;
            rect(r,12,y,216,45,8,c.inset);
            // Selection has a border and a text marker, never color alone.
            if(chosen){stroke_rect(r,12,y,216,45,8,legible_ink(c.accent,c.inset,c.primary_text));text(r,">",18,y+27,16,12,legible_ink(c.primary_text,c.inset,c.primary_text));}
            int x=34,w=182; // Labels never jump when the selection changes.
            bool value=rows[i].value&&rows[i].value[0];
            label_lines(r,rows[i].label,x,y+(value?1:12),18,16,w,1,false,legible_ink(c.primary_text,c.inset,c.primary_text),true);
            if(value)label_lines(r,rows[i].value,x,y+23,14,14,w,1,false,legible_ink(c.secondary_text,c.inset,c.primary_text),false);
        }
    }
    label_lines(r,c6_renderer_localized(r,footer?footer:"单击切换 · 双击确认"),16,209,12,12,208,1,true,legible_ink(c.secondary_text,c.card,c.primary_text),false);
}
#include "qrcodegen.h"
static bool labeled_qr(c6_renderer_t *r,const char *url,const char *title,const char *address,const char *footer,const c6_render_style_t *style){
    // Static scratch is safe: the framebuffer has one serialized display owner.
    static uint8_t qr[qrcodegen_BUFFER_LEN_FOR_VERSION(4)],scratch[qrcodegen_BUFFER_LEN_FOR_VERSION(4)];
    c6_render_style_t c=resolved_style(style);
    c6_renderer_menu(r,title,NULL,0,0,footer,&c);
    if(!qrcodegen_encodeText(url,scratch,qr,qrcodegen_Ecc_MEDIUM,1,4,qrcodegen_Mask_AUTO,true))return false;
    int size=qrcodegen_getSize(qr),scale=144/(size+8),edge=(size+8)*scale,x=(240-edge)/2,y=48+(144-edge)/2;
    // Four-module quiet zone, integer pixels, black/white regardless of theme.
    rect(r,x,y,edge,edge,0,0xffffff);
    for(int yy=0;yy<size;yy++)for(int xx=0;xx<size;xx++)if(qrcodegen_getModule(qr,xx,yy))rect(r,x+(xx+4)*scale,y+(yy+4)*scale,scale,scale,0,0);
    label_lines(r,address,18,192,14,14,204,1,true,legible_ink(c.primary_text,c.card,c.primary_text),false);return true;
}
bool c6_renderer_qr(c6_renderer_t *r,const char *url,const char *address,const c6_render_style_t *style){
#if C6_FORMLABS_ONLY
    return labeled_qr(r,url,c6_renderer_localized(r,"网页详细配置"),address,c6_renderer_localized(r,"手机连接同一 Wi-Fi · 长按返回"),style);
#else
    return labeled_qr(r,url,c6_renderer_localized(r,"网页详细配置"),address,c6_renderer_localized(r,"手机连接同一 Wi-Fi · 长按返回"),style);
#endif
}
bool c6_renderer_setup_qr(c6_renderer_t *r,const char *payload,const char *title,const char *address,const char *footer,const c6_render_style_t *style){
#if C6_FORMLABS_ONLY
    (void)style;
    return terminal_setup_qr(r,payload,c6_renderer_localized(r,title),address,c6_renderer_localized(r,footer));
#else
    return labeled_qr(r,payload,c6_renderer_localized(r,title),address,c6_renderer_localized(r,footer),style);
#endif
}
void c6_renderer_pairing(c6_renderer_t *r,const char *pin,int seconds,const c6_render_style_t *style){
    c6_render_style_t c=resolved_style(style);
    c6_renderer_menu(r,"配对码",NULL,0,0,"仅限可信网络 · 长按返回",&c);
    rect(r,18,71,204,89,12,c.inset);stroke_rect(r,18,71,204,89,12,c.border);
    center_text(r,pin,120,141,64,188,legible_ink(c.primary_text,c.inset,c.primary_text));
    char remaining[64];snprintf(remaining,sizeof(remaining),"%d 秒内有效 · 离开后失效",seconds);
    label_lines(r,remaining,18,177,14,14,204,1,true,legible_ink(c.secondary_text,c.card,c.primary_text),false);
}
static void icon_line(c6_renderer_t *r,int x0,int y0,int x1,int y1,uint32_t color){
    int dx=x1-x0,dy=y1-y0,steps=abs(dx)>abs(dy)?abs(dx):abs(dy);
    for(int i=0;i<=steps;i++){int x=x0+(steps?dx*i/steps:0),y=y0+(steps?dy*i/steps:0);for(int yy=0;yy<2;yy++)for(int xx=0;xx<2;xx++)pixel(r,x+xx,y+yy,color24(color));}
}
void c6_renderer_weather_background(c6_renderer_t *r,int code){
    c6_weather_style_t style=c6_weather_style(code);weather_backdrop(r,style);
    if(style.kind==C6_WEATHER_CLEAR){weather_soft_sun(r,185,89,17);return;}
    if(style.kind==C6_WEATHER_CLOUDY)weather_soft_sun(r,167,77,16);
    weather_soft_cloud(r,style,146,c6_weather_wet(style.kind)?59:65,66,51,255,false);
    if(style.kind==C6_WEATHER_DRIZZLE||style.kind==C6_WEATHER_RAIN){
        for(int i=0;i<(style.kind==C6_WEATHER_DRIZZLE?2:3);i++)icon_line(r,165+i*18,106,161+i*18,118,style.accent);
    }else if(style.kind==C6_WEATHER_SNOW){
        for(int i=0;i<3;i++){int x=162+i*20;icon_line(r,x,108,x,118,style.accent);icon_line(r,x-4,110,x+4,116,style.accent);icon_line(r,x-4,116,x+4,110,style.accent);}
    }else if(style.kind==C6_WEATHER_THUNDER){
        for(int y=104;y<125;y++)for(int x=175;x<196;x++)if((y<115&&x>=187-(y-104)&&x<=194-(y-104)/2)||(y>=114&&x>=181-(y-114)/2&&x<=192-(y-114)))pixel(r,x,y,color24(style.sun));
    }else if(style.kind==C6_WEATHER_FOG){icon_line(r,157,111,212,111,style.accent);icon_line(r,164,119,206,119,style.accent);}
}
void c6_renderer_weather(c6_renderer_t *r,const c6_render_weather_t *p){
#if C6_FORMLABS_ONLY
    terminal_weather(r,p);return;
#endif
    c6_weather_style_t style=c6_weather_style(p->valid?p->code:-1);c6_renderer_weather_background(r,p->valid?p->code:-1);uint32_t ink=style.accent;
    text(r,p->city?p->city:"天气",18,34,20,204,ink);for(int x=18;x<222;x++)pixel(r,x,46,color24(weather_mix24(c6_weather_background_at(style,46),ink,60)));
    if(!p->valid){text(r,c6_renderer_localized(r,"等待天气更新"),18,107,18,204,ink);return;}
    char value[40];snprintf(value,sizeof(value),"%.0f",p->temperature);unsigned temperature=fit_size(value,56,100);
    if(r->smooth_digits)display_number(r,value,18,111,temperature,100,ink);else text(r,value,18,111,temperature,100,ink);
    int unit_x=18+c6_renderer_text_width(value,temperature)+3;text(r,"°C",unit_x,104,16,32,ink);
    snprintf(value,sizeof(value),"%s  %.0f° / %.0f°",r->english?c6_weather_label_en(p->code):c6_weather_label(p->code),p->low,p->high);text(r,value,18,139,17,204,ink);
    text(r,r->english?(p->apparent<10?"WEAR / WARM COAT":p->apparent<20?"WEAR / LIGHT JACKET":"WEAR / LIGHT CLOTHES"):(p->apparent<10?"穿衣 · 厚外套保暖":p->apparent<20?"穿衣 · 薄外套叠穿":"穿衣 · 轻薄透气"),18,169,16,204,ink);
    text(r,r->english?(p->rain>=40||c6_weather_wet(style.kind)?"CAR WASH / POSTPONE":"CAR WASH / SUITABLE"):(p->rain>=40||c6_weather_wet(style.kind)?"洗车 · 暂缓洗车":"洗车 · 适宜洗车"),18,198,16,204,ink);
    snprintf(value,sizeof(value),"%02d:%02d  %s",p->updated_hour,p->updated_minute,p->stale?"缓存":"Open-Meteo");text(r,value,18,223,12,204,ink);
}
static const char *entity_state(const char *raw){
    if(!raw||!*raw)return "等待状态";
    if(same_ascii(raw,"on"))return "开";
    if(same_ascii(raw,"off"))return "关";
    if(same_ascii(raw,"unknown"))return "未知";
    if(same_ascii(raw,"unavailable"))return "不可用";
    if(same_ascii(raw,"none"))return "无";
    return raw;
}
static void dot(c6_renderer_t *r,int cx,int cy,int radius,uint32_t color){for(int y=-radius;y<=radius;y++)for(int x=-radius;x<=radius;x++)if(x*x+y*y<=radius*radius)pixel(r,cx+x,cy+y,color24(color));}
static void entity_symbol(c6_renderer_t *r,const c6_render_entity_t *e,int x,int y,uint32_t color){
    if(e->unit&&(strstr(e->unit,"°")||strstr(e->unit,"℃"))){stroke_rect(r,x+4,y,5,11,2,color);rect(r,x+6,y+3,1,10,0,color);dot(r,x+6,y+13,3,color);}
    else if(e->unit&&strchr(e->unit,'%')){dot(r,x+6,y+11,5,color);for(int yy=0;yy<8;yy++)for(int xx=-yy/2;xx<=yy/2;xx++)pixel(r,x+6+xx,y+yy,color24(color));}
    else {stroke_rect(r,x+1,y+3,12,12,3,color);rect(r,x+5,y+7,4,4,1,color);}
}
static void picture_box(c6_renderer_t *,const c6_render_picture_t *,int,int,int,int,int,bool,bool,const char *,const c6_render_style_t *);
void c6_renderer_entities_styled(c6_renderer_t *r,const char *title,const c6_render_entity_t *items,unsigned count,bool connected,const c6_render_style_t *style){
    c6_render_style_t colors=resolved_style(style);if(count>4)count=4;
    fill(r,colors.background);
    label_lines(r,title&&*title&&!same_ascii(title,"home system")?title:"HOME SYSTEM",15,19,12,12,connected?210:170,1,false,legible_ink(colors.accent,colors.background,colors.primary_text),true);
    if(!connected)label_lines(r,c6_renderer_localized(r,"缓存"),181,20,10,10,42,1,true,colors.tertiary_text,false);
    for(int x=15;x<225;x++)pixel(r,x,41,color24(colors.border));
    if(!count){label_lines(r,c6_renderer_localized(r,"请选择显示的实体"),18,113,16,14,204,2,true,colors.secondary_text,false);return;}
    // Match the AI Mac classic card's centered, equal-height list. Four text
    // entities aren't forced into narrow columns just because this is offline.
    bool media=false;for(unsigned i=0;i<count;i++)media|=items[i].media;
    int columns=media&&count>1?2:1,rows=((int)count+columns-1)/columns,gap=6;
    int width=(214-gap*(columns-1))/columns;
    int height=media?(174-gap*(rows-1))/rows:count==1?84:38;
    int total=rows*height+(rows-1)*gap;
    int first=48+(174-total)/2;
    for(unsigned i=0;i<count;i++){
        const c6_render_entity_t *e=&items[i];int x=13+(int)(i%columns)*(width+gap),y=first+(int)(i/columns)*(height+gap);
        rect(r,x,y,width,height,8,colors.inset);stroke_rect(r,x,y,width,height,8,colors.border);
        const char *state=c6_renderer_localized(r,entity_state(e->state));char value[256];snprintf(value,sizeof(value),"%s%s%s",state,e->unit&&*e->unit?" ":"",e->unit?e->unit:"");
        uint32_t ink=e->available?colors.primary_text:colors.secondary_text;
        if(e->media&&height>=52){
            picture_box(r,&e->picture,x+5,y+5,width-10,height-32,5,true,false,NULL,&colors);
            label_lines(r,e->name,x+5,y+height-25,columns==1?11:10,9,width-10,2,true,ink,true);
        }else if(height>=48){
            label_lines(r,e->name,x+8,y+7,13,9,width-16,1,true,colors.secondary_text,false);
            unsigned value_size=28;while(value_size>9&&c6_renderer_text_width(value,value_size)>width-16)value_size--;
            label_lines(r,value,x+8,y+27+(height-32-(int)value_size)/2,value_size,9,width-16,1,true,ink,true);
        }else{
            entity_symbol(r,e,18,y+11,colors.accent);
            unsigned name_size=11;while(name_size>8&&c6_renderer_text_width(e->name,name_size)>112)name_size--;
            label_lines(r,e->name,35,y+19-(int)name_size/2,name_size,8,112,1,false,colors.secondary_text,false);
            unsigned value_size=12;while(value_size>8&&c6_renderer_text_width(value,value_size)>73)value_size--;
            int vw=c6_renderer_text_width(value,value_size);int vx=221-vw;if(vx<148)vx=148;
            label_lines(r,value,vx,y+19-(int)value_size/2,value_size,8,73,1,false,ink,true);
        }
    }
}
void c6_renderer_entities(c6_renderer_t *r,const char *title,const c6_render_entity_t *items,unsigned count,bool connected){c6_renderer_entities_styled(r,title,items,count,connected,NULL);}
static bool valid_picture(const c6_render_picture_t *p){return p->rgb565&&p->width&&p->height&&p->stride>=p->width*2;}
static uint32_t picture_pixel(const c6_render_picture_t *p,unsigned x,unsigned y){
    if(x>=p->width)x=p->width-1;
    if(y>=p->height)y=p->height-1;
    const uint8_t *bytes=p->rgb565+y*p->stride+x*2;unsigned v=((unsigned)bytes[0]<<8)|bytes[1];return (((v>>11)*255/31)<<16)|((((v>>5)&63)*255/63)<<8)|((v&31)*255/31);
}
static uint32_t picture_sample(const c6_render_picture_t *p,unsigned sx,unsigned sy){
    uint32_t a=picture_pixel(p,sx>>8,sy>>8),b=picture_pixel(p,(sx>>8)+1,sy>>8),c=picture_pixel(p,sx>>8,(sy>>8)+1),d=picture_pixel(p,(sx>>8)+1,(sy>>8)+1),color=0;
    unsigned fx=sx&255,fy=sy&255;
    for(unsigned n=0;n<3;n++){unsigned shift=n*8,top=((a>>shift)&255)*(256-fx)+((b>>shift)&255)*fx,bottom=((c>>shift)&255)*(256-fx)+((d>>shift)&255)*fx;color|=((top*(256-fy)+bottom*fy+32768)>>16)<<shift;}return color;
}
static void picture_box(c6_renderer_t *r,const c6_render_picture_t *p,int x,int y,int w,int h,int radius,bool cover,bool glow,const char *label,const c6_render_style_t *colors){
    if(w<8||h<8)return;
    bool valid=valid_picture(p);
    if(valid&&glow){
        unsigned red=0,green=0,blue=0;
        for(unsigned yy=0;yy<8;yy++)for(unsigned xx=0;xx<8;xx++){uint32_t c=picture_pixel(p,(xx*2+1)*p->width/16,(yy*2+1)*p->height/16);red+=c>>16;green+=(c>>8)&255;blue+=c&255;}
        uint32_t tint=((red/64)<<16)|((green/64)<<8)|(blue/64);
        for(int yy=-5;yy<h+5;yy++)for(int xx=-5;xx<w+5;xx++){
            int dx=xx<radius?radius-xx:xx>w-radius-1?xx-(w-radius-1):0,dy=yy<radius?radius-yy:yy>h-radius-1?yy-(h-radius-1):0;
            int distance=(int)sqrt((double)(dx*dx+dy*dy))-radius;
            if(distance>=0&&distance<5)weather_blend_pixel(r,x+xx,y+yy,tint,(5-distance)*14);
        }
    }
    rect(r,x,y,w,h,radius,colors->inset);
    if(valid){
        double scale=cover?fmax((double)w/p->width,(double)h/p->height):fmin((double)w/p->width,(double)h/p->height);
        double left=(w-p->width*scale)/2,top=(h-p->height*scale)/2;
        for(int yy=0;yy<h;yy++)for(int xx=0;xx<w;xx++)if(inside_round(xx,yy,w,h,radius)){
            double sx=(xx-left)/scale,sy=(yy-top)/scale;
            if(sx>=0&&sy>=0&&sx<p->width&&sy<p->height)pixel(r,x+xx,y+yy,color24(picture_sample(p,(unsigned)(sx*256),(unsigned)(sy*256))));
        }
    }else{
        const char *waiting="等待画面";
        waiting=c6_renderer_localized(r,waiting);
        label_lines(r,waiting,x+4,y+h/2-5,10,8,w-8,1,true,colors->secondary_text,false);
    }
    stroke_rect(r,x,y,w,h,radius,colors->border);
    label=c6_renderer_localized(r,label);
    if(label&&*label&&h>=30){int lw=c6_renderer_text_width(label,8)+12;if(lw<36)lw=36;if(lw>w-8)lw=w-8;
        rect(r,x+5,y+5,lw,16,7,colors->background);label_lines(r,label,x+5,y+8,8,8,lw,1,true,colors->primary_text,true);}
}
static bool present(const char *s){return s&&*s&&!same_ascii(s,"unknown")&&!same_ascii(s,"unavailable");}
static void printer_hero(c6_renderer_t *r,const c6_render_printer_t *p,int top,int bottom,const c6_render_style_t *c){
    char number[32];const char *unit="";bool time=p->card_style==2;
    int percent=p->progress<0?0:p->progress>100?100:p->progress;
    bool resting=!p->connected||same_ascii(p->status?p->status:"","idle")||same_ascii(p->status?p->status:"","standby");
    if(resting){
        int edge=bottom-top-12;if(edge>56)edge=56;if(edge<18)edge=18;int x=(240-edge)/2,y=top+(bottom-top-edge)/2;
        for(int yy=0;yy<edge;yy++)for(int xx=0;xx<edge;xx++){int a=xx*64/edge-27,b=yy*64/edge-35,d=xx*64/edge-39,e=yy*64/edge-25;if(a*a+b*b<=576&&d*d+e*e>529)pixel(r,x+xx,y+yy,color24(c->secondary_text));}
        return;
    }
    if(time&&p->completed)snprintf(number,sizeof(number),"%s",r->english?"DONE":"已完成");
    else if(time&&p->remaining_available){unsigned minutes=(unsigned)(((uint64_t)p->remaining_seconds+59)/60);if(minutes>=60){snprintf(number,sizeof(number),"%02u:%02u",minutes/60,minutes%60);unit=r->english?"HOURS : MINUTES":"小时 : 分钟";}else{snprintf(number,sizeof(number),"%u",minutes);unit=r->english?"MINUTES REMAINING":"剩余分钟";}}
    else if(!time&&p->progress_available){snprintf(number,sizeof(number),"%d",percent);unit="%";}
    else snprintf(number,sizeof(number),"--");
    int room=bottom-top-(time&&*unit?28:12);if(room<14)room=14;unsigned size=room>108?108:(unsigned)room;
    int width,uw;
    do{width=c6_renderer_text_width(number,size);uw=!time&&*unit?c6_renderer_text_width(unit,size/2)+6:0;if(width+uw<=204||size<=14)break;size--;}while(true);
    int baseline=top+(room+(int)size)/2;
    display_number(r,number,(240-width-uw)/2,baseline,size,204,c->primary_text);
    if(!time&&*unit)text_weight(r,unit,(240-width-uw)/2+width+6,baseline,size/2,uw-6,c->secondary_text,true);
    if(time&&*unit)label_lines(r,unit,18,baseline+5,12,10,204,1,true,c->secondary_text,false);
    if(p->progress_available&&p->show_progress){rect(r,18,bottom-6,204,4,2,c->border);if(percent)rect(r,18,bottom-6,204*percent/100,4,2,c->accent);}
}
void c6_renderer_printer(c6_renderer_t *r,const c6_render_printer_t *p){
#if C6_FORMLABS_ONLY
    terminal_printer(r,p);return;
#endif
    c6_render_style_t colors=resolved_style(&p->style);
    fill(r,colors.background);rect(r,8,8,224,224,16,colors.card);stroke_rect(r,8,8,224,224,16,colors.border);
    dot(r,22,23,4,colors.accent);
    const char *name=present(p->name)?p->name:"Bambu Lab 打印机";int name_width=p->show_status?108:186;
    label_lines(r,name,32,11,14,10,name_width,2,false,colors.primary_text,true);
    if(p->show_status){
        uint32_t ink=legible_ink(p->is_error?0xef5947:colors.accent,colors.inset,colors.primary_text);
        rect(r,144,15,78,24,10,colors.inset);stroke_rect(r,144,15,78,24,10,colors.border);
        const char *status=c6_renderer_localized(r,p->connected?c6_renderer_print_status(p->status):"离线");
        label_lines(r,status,149,19,13,11,68,1,true,ink,true);
    }
    for(int x=18;x<222;x++)pixel(r,x,45,color24(colors.border));
    int cursor=51;
    if(p->show_task&&present(p->task)){label_lines(r,p->task,18,cursor,14,10,204,p->card_style?1:2,false,colors.primary_text,true);cursor+=p->card_style?20:34;}
    if(p->show_progress&&!p->card_style){
        int percent=p->progress<0?0:p->progress>100?100:p->progress;char number[12];snprintf(number,sizeof(number),"%d%%",percent);
        rect(r,18,cursor+7,154,5,2,colors.border);if(percent)rect(r,18,cursor+7,154*percent/100,5,2,colors.accent);stroke_rect(r,18,cursor+7,154,5,2,colors.secondary_text);
        unsigned percent_size=13;int number_width=c6_renderer_text_width(number,percent_size);
        text_weight(r,number,222-number_width,cursor+14,percent_size,43,colors.primary_text,true);cursor+=23;
    }
    char temperature[128]={0},time_value[96]={0};
    bool has_temperature=p->show_temperature&&(present(p->nozzle)||present(p->bed));
    if(has_temperature){if(present(p->nozzle)&&present(p->bed))snprintf(temperature,sizeof(temperature),r->english?"NOZZLE %s / BED %s":"喷嘴 %s   热床 %s",p->nozzle,p->bed);else snprintf(temperature,sizeof(temperature),"%s %s",present(p->nozzle)?(r->english?"NOZZLE":"喷嘴"):(r->english?"BED":"热床"),present(p->nozzle)?p->nozzle:p->bed);}
    if(p->show_remaining&&p->card_style!=2){if(p->time_text)snprintf(time_value,sizeof(time_value),"%s",p->time_text);else if(p->completed)snprintf(time_value,sizeof(time_value),"%s",r->english?"DONE / KEEP 30 MIN":"已完成 · 保留30分钟");else snprintf(time_value,sizeof(time_value),r->english?"ETA %d MIN":"剩余 %d 分钟",p->remaining);}
    bool has_time=present(time_value),has_error=p->show_error&&p->is_error&&present(p->error);
    bool has_footer=present(p->updated_text);int bottom=has_footer?212:222;
    bool has_layers=present(p->layers),has_material=present(p->material);
    int detail_rows=(has_temperature?1:0)+(has_time?1:0)+(has_error?1:0)+(has_layers?1:0)+(has_material?1:0);
    int detail_top=bottom-detail_rows*17;
    if(p->card_style)printer_hero(r,p,cursor,detail_top-7,&colors);
    if(p->show_image&&!p->card_style){
        int y=cursor+5,h=detail_top-y-(detail_rows?5:0);
        if(h>8){
            c6_render_picture_t legacy={p->thumbnail_rgb565,p->thumbnail_width,p->thumbnail_height,p->thumbnail_stride};
            bool camera=p->camera_configured,cover=p->cover_configured;
            if(camera&&cover){picture_box(r,&p->camera,18,y,126,h,9,true,true,"实况",&colors);picture_box(r,&p->cover,151,y,71,h,9,false,false,"任务",&colors);}
            else if(camera)picture_box(r,&p->camera,18,y,204,h,9,true,true,"实况",&colors);
            else if(cover)picture_box(r,&p->cover,18,y,204,h,9,false,p->formlabs,"任务",&colors);
            else picture_box(r,&legacy,18,y,204,h,9,false,true,p->image_label,&colors);
        }
    }
    int detail_y=detail_top;
    if(has_temperature){label_lines(r,temperature,18,detail_y,12,11,204,1,true,colors.secondary_text,true);detail_y+=17;}
    if(has_time){label_lines(r,time_value,18,detail_y,12,11,204,1,true,colors.secondary_text,true);detail_y+=17;}
    if(has_layers){label_lines(r,p->layers,18,detail_y,12,10,204,1,true,colors.secondary_text,true);detail_y+=17;}
    if(has_material){label_lines(r,p->material,18,detail_y,12,10,204,1,true,colors.secondary_text,true);detail_y+=17;}
    if(has_error)label_lines(r,p->error,18,detail_y,12,11,204,1,true,0xef5947,true);
    if(has_footer){for(int x=26;x<214;x++)pixel(r,x,215,color24(colors.border));label_lines(r,p->updated_text,18,216,11,11,204,1,true,colors.tertiary_text,false);}
}
void c6_renderer_printer_overview_styled(c6_renderer_t *r,const c6_render_printer_summary_t *items,unsigned count,const c6_render_style_t *style){
#if C6_FORMLABS_ONLY
    (void)style;c6_renderer_printer_overview(r,items,count);return;
#else
    c6_render_style_t c=resolved_style(style);fill(r,c.background);rect(r,8,8,224,224,16,c.card);stroke_rect(r,8,8,224,224,16,c.border);
    label_lines(r,c6_renderer_localized(r,"打印机总览"),18,13,18,14,204,1,false,c.primary_text,true);rect(r,18,43,204,1,0,c.border);
    unsigned enabled=0;for(unsigned i=0;i<count&&i<3;i++)if(items[i].enabled)enabled++;
    if(!enabled)return;
    int height=(174-(int)(enabled-1)*6)/(int)enabled;unsigned row=0;
    for(unsigned i=0;i<count&&i<3;i++)if(items[i].enabled){const c6_render_printer_summary_t *p=&items[i];int top=50+(int)row++*(height+6);
        rect(r,14,top,212,height,10,c.inset);stroke_rect(r,14,top,212,height,10,c.border);
        label_lines(r,p->name,22,top+5,15,12,196,1,false,c.primary_text,true);
        label_lines(r,c6_renderer_localized(r,p->connected?c6_renderer_print_status(p->status):"离线"),22,top+25,12,10,104,1,false,p->connected?c.accent:c.secondary_text,false);
        label_lines(r,p->formlabs?"FORMLABS":"BAMBU LAB",128,top+25,10,8,90,1,false,c.secondary_text,false);
        int percent=p->progress<0?0:p->progress>100?100:p->progress;char value[16];snprintf(value,sizeof(value),p->progress_available?"%d%%":"--",percent);
        int y=top+height-14;rect(r,22,y,150,4,2,c.border);if(p->progress_available&&percent)rect(r,22,y,150*percent/100,4,2,c.accent);
        label_lines(r,value,178,y-7,12,10,40,1,true,c.primary_text,true);
    }
#endif
}
#if !C6_FORMLABS_ONLY
void c6_renderer_printer_overview(c6_renderer_t *r,const c6_render_printer_summary_t *items,unsigned count){c6_renderer_printer_overview_styled(r,items,count,NULL);}
#endif
#include "round_clock.h"
static void clock_digit(c6_renderer_t *r,char digit,int x,int top,int source_y,int source_h,int dest_y,int dest_h,uint32_t ink){
    if(digit<'0'||digit>'9'||!dest_h)return;
    if(terminal_use_smooth(r)){
    for(int y=0;y<dest_h;y++)for(int xx=0;xx<36;xx++){
        int sx=((xx*256+128)*42/36)-128,sy=source_y*256+(y*256+128)*source_h/dest_h-128;
        unsigned alpha=terminal_smooth_alpha(digit-'0',sx,sy);int px=x+5+xx,py=top+dest_y+y;
        terminal_smooth_blend(r,px,py,ink,alpha);
    }
    return;
    }
#if C6_FORMLABS_ONLY
#if C6_TERMINAL_AERO_DIGITS == 1
    const uint16_t *rows=terminal_aero_digits[digit-'0'];
    for(int y=0;y<dest_h;y++)for(int xx=0;xx<36;xx++){int sy=(source_y+y*source_h/dest_h)*20/60;if(sy>=0&&sy<20&&(rows[sy]&(0x2000>>(xx*14/36))))pixel(r,x+5+xx,top+dest_y+y,color24(ink));}
#else
    const uint16_t *rows=terminal_hero_digits[digit-'0'];
    for(int y=0;y<dest_h;y++)for(int xx=0;xx<30;xx++){int sy=(source_y+y*source_h/dest_h)*20/60;if(sy>=0&&sy<20&&(rows[sy]&(0x800>>(xx*12/30))))pixel(r,x+8+xx,top+dest_y+y,color24(ink));}
#endif
    return;
#endif
    const aa_glyph_t *g=font_glyph(digit,true);if(!g||!dest_h||!font_load(r,g,true))return;
    for(int y=0;y<dest_h;y++)for(int xx=0;xx<36;xx++){int sy=(source_y+y*source_h/dest_h)*g->height*256/60,sx=xx*g->width*256/36;unsigned alpha=font_bilinear(r,g,sx,sy);weather_blend_pixel(r,x+5+xx,top+dest_y+y,ink,alpha);}
}
void c6_renderer_clock(c6_renderer_t *r,const c6_render_clock_t *t,const c6_render_clock_t *old,unsigned progress){
    if(progress>1000)progress=1000;
    if(old&&progress==0)t=old;
#if C6_FORMLABS_ONLY
    terminal_clock(r,t);return;
#endif
    fill(r,0x070b16);text(r,"FLIP CLOCK",18,34,16,204,0x9eadc2);char digits[5],prior[5];snprintf(digits,sizeof(digits),"%02d%02d",t->hour,t->minute);snprintf(prior,sizeof(prior),"%02d%02d",old?old->hour:t->hour,old?old->minute:t->minute);
    for(unsigned i=0;i<4;i++){int x=c6_flip_card_x(i);rect(r,x,72,46,86,7,0x39414f);rect(r,x+1,73,44,84,6,0x1f242e);rect(r,x+1,115,44,42,5,0x181c24);bool moving=old&&prior[i]!=digits[i]&&progress<1000;
        char upper=moving&&progress<500?prior[i]:digits[i],lower=moving?prior[i]:digits[i];clock_digit(r,upper,x,85,0,30,0,30,0xffffff);clock_digit(r,lower,x,85,30,30,30,30,0xdfe6f0);
        if(moving&&progress<500){rect(r,x+1,73,44,41,5,0x1f242e);clock_digit(r,digits[i],x,85,0,30,0,30,0xffffff);int height=(int)((500-progress)*30/500);if(height)clock_digit(r,prior[i],x,85,0,30,30-height,height,0xe0e6ed);}
        else if(moving){int height=(int)((progress-500)*30/500);if(height)clock_digit(r,digits[i],x,85,30,30,30,height,0xdfe6f0);}
        for(int xx=1;xx<45;xx++){pixel(r,x+xx,114,color24(0x070b16));pixel(r,x+xx,115,color24(0x070b16));}rect(r,x,111,3,8,0,0x39414f);rect(r,x+43,111,3,8,0,0x39414f);
    }
    for(int y=100;y<=104;y++)for(int x=118;x<=122;x++)if((x-120)*(x-120)+(y-102)*(y-102)<=4)pixel(r,x,y,color24(0x9eadc2));
    for(int y=126;y<=130;y++)for(int x=118;x<=122;x++)if((x-120)*(x-120)+(y-128)*(y-128)<=4)pixel(r,x,y,color24(0x9eadc2));
    char line[48];snprintf(line,sizeof(line),"%02d",t->second);center_text(r,line,120,185,20,204,0x50e6b8);const char *days_en[]={"SUN","MON","TUE","WED","THU","FRI","SAT"},*days_zh[]={"周日","周一","周二","周三","周四","周五","周六"};const char **days=r->english?days_en:days_zh;int weekday=t->weekday<0||t->weekday>6?0:t->weekday;snprintf(line,sizeof(line),"%04d.%02d.%02d  %s",t->year,t->month,t->day,days[weekday]);center_text(r,line,120,219,14,204,0x9eadc2);
}
void c6_renderer_clock_smooth(c6_renderer_t *r,const c6_render_clock_t *t,const c6_render_clock_t *old,unsigned progress,bool incremental){
    if(progress>1000)progress=1000;
    // Keep seconds/date from the previous static frame while only the four
    // tiles are transferred. Both endpoints are exact static frames; commit
    // the new metadata with a complete LCD refresh after the fold finishes.
    if(old&&progress==0){c6_renderer_clock(r,old,NULL,1000);return;}
    if(progress==1000){c6_renderer_clock(r,t,NULL,1000);return;}
    if(!incremental)c6_renderer_clock(r,old?old:t,NULL,1000);
    char digits[5],prior[5];snprintf(digits,sizeof(digits),"%02d%02d",t->hour,t->minute);
    snprintf(prior,sizeof(prior),"%02d%02d",old?old->hour:t->hour,old?old->minute:t->minute);
    // Two smooth half-rotations, not a linear shrinking text animation.
    double half=progress<500?progress/500.0:(progress-500)/500.0;
    double ease=half*half*(3.0-2.0*half);
    double projection=progress<500?cos(ease*1.5707963267948966):sin(ease*1.5707963267948966);
    for(unsigned i=0;i<4;i++){
        int x=c6_flip_card_x(i);bool moving=old&&prior[i]!=digits[i]&&progress<1000;
        // Restore the tile including its curved corners without touching the rest of the frame.
        const uint32_t base=C6_FORMLABS_ONLY?0:0x070b16,border=C6_FORMLABS_ONLY?0x555555:0x39414f;
        const uint32_t upper=C6_FORMLABS_ONLY?0x111111:0x1f242e,lower_surface=C6_FORMLABS_ONLY?0x0a0a0a:0x181c24;
        rect(r,x,72,46,87,0,base);rect(r,x,72,46,86,7,border);
        rect(r,x+1,73,44,84,6,upper);rect(r,x+1,115,44,42,5,lower_surface);
        char lower=moving?prior[i]:digits[i];
        clock_digit(r,digits[i],x,85,0,30,0,30,0xffffff);
        clock_digit(r,lower,x,85,30,30,30,30,C6_FORMLABS_ONLY?0xffffff:0xdfe6f0);
        if(moving){
            int panel=(int)lround(42*projection),glyph=(int)lround(30*projection);
            uint32_t surface=weather_mix24(progress<500?upper:lower_surface,C6_FORMLABS_ONLY?0:0x080a10,(unsigned)((1-projection)*150));
            uint32_t ink=weather_mix24(C6_FORMLABS_ONLY?0xffffff:progress<500?0xffffff:0xdfe6f0,C6_FORMLABS_ONLY?0x888888:0x758298,(unsigned)((1-projection)*100));
            if(progress<500){
                rect(r,x+1,115-panel,44,panel,panel>12?5:0,surface);
                if(glyph)clock_digit(r,prior[i],x,85,0,30,30-glyph,glyph,ink);
            }else{
                rect(r,x+1,115,44,panel,panel>12?5:0,surface);
                if(glyph)clock_digit(r,digits[i],x,85,30,30,30,glyph,ink);
            }
            // Soft hinge shadow, bounded to the tile and derived from fold angle.
            for(int row=0;row<3;row++)for(int xx=2;xx<44;xx++)weather_blend_pixel(r,x+xx,116+row,0x04060a,(unsigned)((1-projection)*(70-row*20)));
        }
        for(int xx=1;xx<45;xx++){pixel(r,x+xx,114,color24(base));pixel(r,x+xx,115,color24(base));}
        rect(r,x,111,3,8,0,border);rect(r,x+43,111,3,8,0,border);
    }
}
#include "formlabs_terminal.h"
