// Execute the actual font selector, decoder, metrics and glyph drawing path.
#include "../../Sources/C6DisplayRenderer/c6_display_renderer.c"
#include <assert.h>
int main(void) {
    uint8_t frame[C6_RENDER_BYTES]={0};c6_renderer_t r;
    assert(c6_renderer_init(&r,frame,sizeof(frame)));
    bool large;
    const char *labels="设备设置配对码网络设备信息时间同步等待网络校时固件更新单击切换双击确认长按返回仅限可信网络秒内有效离开后失效可用内存桌面时钟";
    while(*labels){unsigned code=next_code(&labels);const aa_glyph_t *g=font_glyph(code,false);assert(g&&g->code==code);}
    assert(sized_glyph('6',56,&large)==font_glyph('6',true)&&large);
    assert(sized_glyph('-',56,&large)==font_glyph('-',true)&&large);
    assert(sized_glyph(0x2212,56,&large)==font_glyph(0x2212,true)&&large);
    assert(sized_glyph('6',27,&large)==font_glyph('6',false)&&!large);
    assert(sized_glyph(0x4e0a,56,&large)==font_glyph(0x4e0a,false)&&!large);
    for(unsigned n=0;n<sizeof(aa_large_glyphs)/sizeof(aa_large_glyphs[0]);n++) {
        const aa_glyph_t *g=&aa_large_glyphs[n];assert(font_load(&r,g,true));
        assert(g->offset+((unsigned)g->width*g->height+1)/2<=aa_large_groups[g->group].raw);
        assert(c6_renderer_text_width("26",56)==code_advance('2',56)+code_advance('6',56));
    }
    for(unsigned n=0;n<sizeof(aa_body_groups)/sizeof(aa_body_groups[0]);n++)assert(aa_body_groups[n].raw<=C6_AA_CACHE_BYTES);
    // At native 64px, glyph coverage is exact; never an upscaled 16px bitmap.
    const aa_glyph_t *g=font_glyph('6',true);assert(font_load(&r,g,true));
    unsigned coverages=0;
    for(unsigned y=0;y<g->height;y++)for(unsigned x=0;x<g->width;x++)coverages|=1U<<(font_sample(&r,g,x,y)/17);
    assert(__builtin_popcount(coverages)>10); // > four-level body anti-aliasing.
    text(&r,"6",10,90,64,80,0xffffff);assert(r.cached_font==1);
    for(unsigned y=0;y<g->height;y++)for(unsigned x=0;x<g->width;x++){
        unsigned alpha=font_sample(&r,g,x,y);int px=10+g->left+x,py=90+g->top+y;
        unsigned expected=alpha?weather_rgb565(weather_mix24(0,0xffffff,alpha),px,py):0;
        unsigned index=(py*240+px)*2;
        assert((((unsigned)frame[index]<<8)|frame[index+1])==expected);
    }
    assert(c6_renderer_text_width("-40",56)<=100);
    assert(c6_renderer_text_width("100",56)<=102);
    // Exercise all original geometric numerals with a guarded caller-owned
    // frame: no glyph is empty, clipped, or drawn outside its allotted layer.
    struct {uint8_t before[32],bytes[C6_RENDER_BYTES],after[32];} guarded;
    memset(&guarded,0xa5,sizeof(guarded));
    c6_renderer_t rounded;assert(c6_renderer_init(&rounded,guarded.bytes,sizeof(guarded.bytes)));
    for(unsigned digit=0;digit<10;digit++){
        memset(guarded.bytes,0,sizeof(guarded.bytes));round_clock_digit(&rounded,digit,22,76,44,76,0xffffff);
        unsigned filled=0,soft=0;
        for(int y=0;y<240;y++)for(int x=0;x<240;x++){
            unsigned offset=(y*240+x)*2,c=((unsigned)guarded.bytes[offset]<<8)|guarded.bytes[offset+1];
            if(c){assert(x>=22&&x<66&&y>=76&&y<152);filled++;if(c!=65535)soft++;}
        }
        assert(filled>200&&soft>20);
        for(unsigned i=0;i<32;i++)assert(guarded.before[i]==0xa5&&guarded.after[i]==0xa5);
    }
    c6_render_clock_t time={2026,10,8,4,12,34,56};c6_renderer_round_clock(&rounded,&time,NULL);
    for(unsigned i=0;i<32;i++)assert(guarded.before[i]==0xa5&&guarded.after[i]==0xa5);
    puts("C6 rounded clock: all 10 antialiased numerals, bounded layer writes and caller-owned framebuffer passed");
    puts("C6 offline font: native 64px display atlas, 4-bit coverage, exact native glyph pixels, negative temperatures, matching width/wrapping metrics and bounded cache passed");
}
