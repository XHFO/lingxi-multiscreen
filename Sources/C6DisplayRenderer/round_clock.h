#pragma once
#include <limits.h>
// Original geometric numerals inspired by rounded industrial displays.
// No web-font data is embedded. Analytic strokes are antialiased directly into
// the caller's RGB565 frame; no second framebuffer or permanent glyph cache.
typedef struct {int8_t x,y;} round_clock_point_t;
static const round_clock_point_t round_clock_paths[10][16]={
    {{14,7},{28,7},{34,13},{34,47},{28,53},{14,53},{8,47},{8,13},{14,7},{-1,-1}},
    {{13,17},{21,7},{21,53},{-2,-2},{12,53},{31,53},{-1,-1}},
    {{8,13},{14,7},{28,7},{34,13},{34,23},{28,30},{14,30},{8,37},{8,53},{34,53},{-1,-1}},
    {{8,7},{28,7},{34,13},{34,23},{28,30},{18,30},{-2,-2},{28,30},{34,37},{34,47},{28,53},{8,53},{-1,-1}},
    {{29,53},{29,7},{8,32},{8,36},{36,36},{-1,-1}},
    {{34,7},{8,7},{8,29},{27,29},{34,36},{34,47},{28,53},{8,53},{-1,-1}},
    {{32,7},{15,7},{8,14},{8,47},{14,53},{28,53},{34,47},{34,36},{28,30},{8,30},{-1,-1}},
    {{8,7},{34,7},{34,15},{21,30},{21,53},{-1,-1}},
    {{14,7},{28,7},{34,13},{34,23},{28,30},{14,30},{8,23},{8,13},{14,7},{-2,-2},{14,30},{8,37},{8,47},{14,53},{28,53},{-1,-1}},
    {{34,30},{14,30},{8,23},{8,13},{14,7},{28,7},{34,13},{34,47},{28,53},{10,53},{-1,-1}}
};
// Coordinates use 1/64 design units. Integer distance/coverage avoids software
// double arithmetic and square roots on the C6's no-FPU core.
static int round_clock_segment(int x,int y,round_clock_point_t a,round_clock_point_t b){
    int vx=b.x-a.x,vy=b.y-a.y,dx=x-a.x*64,dy=y-a.y*64;
    int length=vx*vx+vy*vy;
    if(!length)return dx*dx+dy*dy;
    int projection=(dx*vx+dy*vy)/length;
    if(projection<0)projection=0;
    if(projection>64)projection=64;
    dx-=projection*vx;dy-=projection*vy;return dx*dx+dy*dy;
}
static void round_clock_digit(c6_renderer_t *r,unsigned digit,int left,int top,int width,int height,uint32_t color){
    if(digit>9||width<=0||height<=0)return;
    const round_clock_point_t *points=round_clock_paths[digit];
    for(int y=0;y<height;y++)for(int x=0;x<width;x++){
        int gx=(x*2+1)*42*32/width,gy=(y*2+1)*60*32/height,best=INT_MAX;
        for(unsigned i=1;i<16&&points[i].x!=-1;i++){
            if(points[i].x<0||points[i-1].x<0)continue;
            int distance=round_clock_segment(gx,gy,points[i-1],points[i]);if(distance<best)best=distance;
        }
        // Close the lower bowl of 8 separately to keep paths bounded to 16 points.
        if(digit==8){
            const round_clock_point_t a={28,53},b={34,47},c={34,37},d={28,30};
            int distance=round_clock_segment(gx,gy,a,b);if(distance<best)best=distance;
            distance=round_clock_segment(gx,gy,b,c);if(distance<best)best=distance;
            distance=round_clock_segment(gx,gy,c,d);if(distance<best)best=distance;
        }
        int edge=21*64/width,inner=(320-edge)*(320-edge),outer=(320+edge)*(320+edge);
        if(best<outer){unsigned coverage=best<=inner?255:(unsigned)((outer-best)*255/(outer-inner));weather_blend_pixel(r,left+x,top+y,color,coverage);}
    }
}
void c6_renderer_round_clock(c6_renderer_t *r,const c6_render_clock_t *t,const c6_render_style_t *style){
    c6_render_style_t s=style&&style->enabled?*style:c6_renderer_default_style();
    // A still diffuse surface, not pointer animation: one bounded 1Hz render.
    for(int y=0;y<240;y++)for(int x=0;x<240;x++){
        int dx=x-120,dy=y-110;
        int glow=210-dx*dx*210/(155*155)-dy*dy*210/(145*145);
        pixel(r,x,y,color24(weather_mix24(s.background,s.card,glow>0?(unsigned)glow:0)));
    }
    text(r,r->english?"ROUND CLOCK":"桌面时钟",18,34,14,204,s.secondary_text);
    round_clock_digit(r,(unsigned)t->hour/10,22,76,44,76,s.primary_text);
    round_clock_digit(r,(unsigned)t->hour%10,67,76,44,76,s.primary_text);
    round_clock_digit(r,(unsigned)t->minute/10,129,76,44,76,s.primary_text);
    round_clock_digit(r,(unsigned)t->minute%10,174,76,44,76,s.primary_text);
    dot(r,120,103,3,s.secondary_text);dot(r,120,128,3,s.secondary_text);
    round_clock_digit(r,(unsigned)t->second/10,101,173,18,26,s.accent);
    round_clock_digit(r,(unsigned)t->second%10,121,173,18,26,s.accent);
    const char *days_en[]={"SUN","MON","TUE","WED","THU","FRI","SAT"},*days_zh[]={"周日","周一","周二","周三","周四","周五","周六"};const char **days=r->english?days_en:days_zh;
    char date[48];int weekday=t->weekday<0||t->weekday>6?0:t->weekday;
    snprintf(date,sizeof(date),"%04d.%02d.%02d  %s",t->year,t->month,t->day,days[weekday]);
    center_text(r,date,120,225,14,212,s.secondary_text);
}
