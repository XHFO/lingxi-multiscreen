#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "c6_display_renderer.h"
#include "../../WaveshareC6Firmware/src/clock_animation.h"
static uint8_t frame[C6_RENDER_BYTES],reference[C6_RENDER_BYTES];
static unsigned frame_pixel(unsigned x,unsigned y){return (frame[(y*240+x)*2]<<8)|frame[(y*240+x)*2+1];}
static void assert_pixel_heading(void){
    // FLIP CLOCK starts at (28,16), using 2x integer blocks. Reject smoothing
    // or accidental proportional/system-font fallback in the actual renderer.
    const unsigned char f[]={31,16,16,30,16,16,16};
    for(unsigned y=0;y<14;y++)for(unsigned x=0;x<12;x++){
        bool on=x<10&&(f[y/2]&(16>>(x/2)));
        assert(frame_pixel(28+x,16+y)==(on?0xffff:0));
    }
    for(unsigned y=16;y<30;y++)for(unsigned x=28;x<148;x++){
        unsigned pixel=frame_pixel(x,y);assert(pixel==0||pixel==0xffff);
    }
    assert(c6_renderer_text_width("FLIP CLOCK",14)==120);
    assert(c6_renderer_text_width("iii",14)==c6_renderer_text_width("WWW",14));
    assert(c6_renderer_text_width("0123456789",24)==180);
}
static CGImageRef image(void){
    uint8_t *pixels=malloc(240*240*3);assert(pixels);
    for(unsigned i=0;i<240*240;i++){unsigned value=(frame[i*2]<<8)|frame[i*2+1];pixels[i*3]=((value>>11)&31)*255/31;pixels[i*3+1]=((value>>5)&63)*255/63;pixels[i*3+2]=(value&31)*255/31;}
    CFDataRef data=CFDataCreate(NULL,pixels,240*240*3);free(pixels);CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef result=CGImageCreate(240,240,8,24,240*3,space,(CGBitmapInfo)kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault);CGColorSpaceRelease(space);CGDataProviderRelease(provider);CFRelease(data);return result;
}
static CGImageDestinationRef destination(const char *path,CFStringRef format,unsigned count){CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)path,strlen(path),false);CGImageDestinationRef result=CGImageDestinationCreateWithURL(url,format,count,NULL);CFRelease(url);assert(result);return result;}
static void write_png(const char *dir,const char *name){char path[1024];snprintf(path,sizeof(path),"%s/%s.png",dir,name);CGImageDestinationRef png=destination(path,CFSTR("public.png"),1);CGImageRef rendered=image();CGImageDestinationAddImage(png,rendered,NULL);assert(CGImageDestinationFinalize(png));CGImageRelease(rendered);CFRelease(png);}
int main(int argc,char **argv){
    assert(argc==2);c6_renderer_t r={0},other={0};assert(c6_renderer_init(&r,frame,sizeof(frame)));assert(c6_renderer_init(&other,reference,sizeof(reference)));
    r.english=other.english=true;
#ifdef TEST_SMOOTH_DIGITS
    r.smooth_digits=other.smooth_digits=true;
#endif
    assert(!strcmp(c6_renderer_localized(&r,"天气"),"WEATHER"));
    const c6_render_clock_t prior={2026,10,9,5,23,59,59},now={2026,10,10,6,0,0,0};
    c6_renderer_clock_smooth(&r,&now,&prior,0,false);memcpy(reference,frame,sizeof(frame));
    for(unsigned progress=0;progress<=1000;progress+=10){
        c6_renderer_clock_smooth(&r,&now,&prior,progress,true);c6_renderer_clock_smooth(&other,&now,&prior,progress,false);assert(!memcmp(frame,reference,sizeof(frame)));
    }
    c6_renderer_clock(&other,&now,NULL,1000);assert(!memcmp(frame,reference,sizeof(frame)));
    c6_clock_animation_t animation={0};unsigned progress;assert(c6_clock_animation_step(&animation,&prior,100,1000000,0,true,true,&progress));c6_clock_animation_commit(&animation,0);
    assert(c6_clock_animation_step(&animation,&now,101,2000000,0,true,false,&progress)&&animation.active&&progress==0);
    for(unsigned step=1;step<=21;step++){assert(c6_clock_animation_step(&animation,&now,101,2000000+step*33000,0,true,false,&progress));assert(animation.active&&progress<1000);}
    assert(c6_clock_animation_step(&animation,&now,101,2720000,0,true,false,&progress)&&!animation.active&&progress==1000);
    assert(!c6_clock_animation_step(&animation,&now,101,2800000,0,true,false,&progress));
    assert(c6_clock_animation_step(&animation,&prior,102,3000000,0,true,false,&progress)&&animation.active);c6_clock_animation_cancel(&animation);assert(!animation.active);
    char path[1024];snprintf(path,sizeof(path),"%s/flip-clock.gif",argv[1]);CGImageDestinationRef gif=destination(path,CFSTR("com.compuserve.gif"),24);
    int loop=0;CFNumberRef loopValue=CFNumberCreate(NULL,kCFNumberIntType,&loop);const void *loopKeys[]={kCGImagePropertyGIFLoopCount},*loopValues[]={loopValue};CFDictionaryRef loopInfo=CFDictionaryCreate(NULL,loopKeys,loopValues,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);const void *outerKeys[]={kCGImagePropertyGIFDictionary},*outerValues[]={loopInfo};CFDictionaryRef props=CFDictionaryCreate(NULL,outerKeys,outerValues,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);CGImageDestinationSetProperties(gif,props);
    for(unsigned i=0;i<24;i++){unsigned p=i==23?1000:i*33000*1000/720000;c6_renderer_clock_smooth(&r,&now,&prior,p,i!=0);CGImageRef rendered=image();double delay=i==0||i==23?1.0:.033;CFNumberRef value=CFNumberCreate(NULL,kCFNumberDoubleType,&delay);const void *keys[]={kCGImagePropertyGIFDelayTime,kCGImagePropertyGIFUnclampedDelayTime},*values[]={value,value};CFDictionaryRef timing=CFDictionaryCreate(NULL,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);const void *frameKeys[]={kCGImagePropertyGIFDictionary},*frameValues[]={timing};CFDictionaryRef frameProps=CFDictionaryCreate(NULL,frameKeys,frameValues,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);CGImageDestinationAddImage(gif,rendered,frameProps);CFRelease(frameProps);CFRelease(timing);CFRelease(value);CGImageRelease(rendered);}
    assert(CGImageDestinationFinalize(gif));CFRelease(gif);CFRelease(props);CFRelease(loopInfo);CFRelease(loopValue);
    c6_renderer_clock_smooth(&r,&now,&prior,350,false);snprintf(path,sizeof(path),"%s/clock-fold.png",argv[1]);CGImageDestinationRef png=destination(path,CFSTR("public.png"),1);CGImageRef rendered=image();CGImageDestinationAddImage(png,rendered,NULL);assert(CGImageDestinationFinalize(png));CGImageRelease(rendered);CFRelease(png);
    const c6_render_clock_t sample={2026,10,10,6,7,42,58};c6_renderer_clock(&r,&sample,NULL,1000);assert_pixel_heading();write_png(argv[1],"clock");
    c6_render_weather_t weather={.city="SINGAPORE",.temperature=24,.low=21,.high=29,.apparent=25,.code=0,.valid=true,.humidity=58,.wind=3.2,.humidity_valid=true,.wind_valid=true};c6_renderer_weather(&r,&weather);write_png(argv[1],"weather");
    c6_render_printer_t printer={.name="FORM 4",.status="printing",.progress=74,.remaining=14,.connected=true,.show_status=true,.show_progress=true,.show_remaining=true,.time_text="ETA: 14m",.layers="层数 148 / 200",.formlabs=true};c6_renderer_printer(&r,&printer);write_png(argv[1],"printer");
    printer.show_task=true;printer.task="长任务文件名称 · Mechanical bracket assembly version 2";printer.show_image=true;printer.material="Clear V5 · 0.1mm";c6_renderer_printer(&r,&printer);write_png(argv[1],"printer-details");
    printer.card_style=1;printer.progress_available=true;printer.show_progress=false;
    c6_renderer_printer(&r,&printer);write_png(argv[1],"printer-large-percentage");memcpy(reference,frame,sizeof(frame));
    static uint8_t fixture_picture[32*32*2];memset(fixture_picture,0xff,sizeof(fixture_picture));
    printer.thumbnail_rgb565=fixture_picture;printer.thumbnail_width=printer.thumbnail_height=32;printer.thumbnail_stride=64;printer.show_image=false;
    c6_renderer_printer(&r,&printer);assert(!memcmp(reference,frame,sizeof(frame))); // Never draw a thumbnail in hero modes.
    printer.card_style=2;printer.show_progress=true;printer.show_remaining=false;printer.remaining_available=true;printer.remaining_seconds=2*3600+41*60;
    c6_renderer_printer(&r,&printer);write_png(argv[1],"printer-remaining-time");memcpy(reference,frame,sizeof(frame));
    printer.time_text="END 23:59";printer.show_image=true;c6_renderer_printer(&r,&printer);assert(!memcmp(reference,frame,sizeof(frame))); // Hero time is not finish time.
    printer.remaining_seconds=42*60;c6_renderer_printer(&r,&printer);write_png(argv[1],"printer-remaining-minutes");
    printer.remaining_available=false;c6_renderer_printer(&r,&printer);write_png(argv[1],"printer-time-unavailable");
    // A directly drawn moon + Z, not WAITING or an unsupported Unicode glyph.
    memcpy(reference,frame,sizeof(frame));r.english=false;c6_renderer_printer(&r,&printer);
    for(unsigned y=76;y<152;y++)for(unsigned x=72;x<168;x++)assert(frame_pixel(x,y)==((reference[(y*240+x)*2]<<8)|reference[(y*240+x)*2+1]));
    r.english=true;printer.show_task=false;printer.show_progress=false;printer.show_remaining=false;printer.layers=printer.material=NULL;
    printer.card_style=1;printer.progress_available=false;c6_renderer_printer(&r,&printer);write_png(argv[1],"printer-progress-unavailable");
    assert(frame_pixel(101,148)==0xffff); // Filled left edge of the crescent.
    assert(frame_pixel(127,131)==0); // Open cut-out, not a solid circle.
    memcpy(reference,frame,sizeof(frame));r.smooth_digits=!r.smooth_digits;c6_renderer_printer(&r,&printer);assert(!memcmp(reference,frame,sizeof(frame)));r.smooth_digits=!r.smooth_digits;
    printer.card_style=2;c6_renderer_printer(&r,&printer);assert(!memcmp(reference,frame,sizeof(frame))); // Both styles share the icon.
    printer.show_task=true;printer.show_progress=true;printer.layers="层数 148 / 200";printer.material="Clear V5 · 0.1mm";printer.progress_available=true;
    printer.completed=true;c6_renderer_printer(&r,&printer);write_png(argv[1],"printer-time-complete");
    printer.completed=false;printer.remaining_available=true;printer.remaining_seconds=UINT32_MAX;c6_renderer_printer(&r,&printer);write_png(argv[1],"printer-time-long");
    const c6_render_menu_row_t menu[]={{"翻页动画","已开启 · 双击关闭"},{"屏幕亮度","80%"},{"屏幕方向","正常 · 双击翻转"},{"网页详细配置","手机扫码设置打印机"}};c6_renderer_menu(&r,"[ 设置 ]",menu,4,0,"单击选择 · 双击确认 · 长按返回",NULL);write_png(argv[1],"settings");
    const c6_render_menu_row_t en_menu[]={{"ROTATION","0 / double: rotate"},{"FLIP ANIMATION","On / double: off"},{"LANGUAGE","English"}};
    c6_renderer_menu(&r,"DISPLAY",en_menu,3,2,"Tap: next / 2x: OK / hold: back",NULL);write_png(argv[1],"settings-en");
    unsigned arrow=0;for(unsigned y=151;y<183;y++)for(unsigned x=16;x<26;x++)if(frame_pixel(x,y)==0xfaa0)arrow++;
    assert(arrow>20); // #ff5500 encoded as RGB565; selection arrow must not vanish.
    c6_renderer_clock(&r,&sample,NULL,1000);memcpy(reference,frame,sizeof(frame));r.english=false;
    assert(!strcmp(c6_renderer_localized(&r,"天气"),"天气"));
    c6_renderer_clock(&r,&sample,NULL,1000);assert(memcmp(frame,reference,sizeof(frame)));write_png(argv[1],"clock-zh");
    c6_renderer_weather(&r,&weather);write_png(argv[1],"weather-zh");
    c6_render_printer_summary_t rows[]={
        {.name="Form 4 · 研发",.status="printing",.progress=74,.enabled=true,.connected=true,.progress_available=true},
        {.name="Form 4L · 样品",.status="finished",.progress=100,.enabled=true,.connected=true,.progress_available=true},
        {.name="Form 3 · Long user defined printer name",.status="printing",.progress=25,.enabled=true,.connected=true,.progress_available=true}
    };
    for(unsigned english=0;english<2;english++){
        r.english=english;c6_renderer_printer_overview(&r,rows,2);write_png(argv[1],english?"overview-2-en":"overview-2-zh");
        c6_renderer_printer_overview(&r,rows,3);write_png(argv[1],english?"overview-3-en":"overview-3-zh");memcpy(reference,frame,sizeof(frame));
        c6_renderer_printer_overview(&r,rows,3);assert(!memcmp(reference,frame,sizeof(frame)));
        rows[1].progress=0;c6_renderer_printer_overview(&r,rows,3);
        assert(!memcmp(reference+54*480,frame+54*480,56*480));
        assert(memcmp(reference+110*480,frame+110*480,56*480));
        assert(!memcmp(reference+166*480,frame+166*480,56*480));
        rows[1].progress=100;rows[1].connected=false;rows[1].progress_available=false;
        rows[2].enabled=false;c6_renderer_printer_overview(&r,rows,3);write_png(argv[1],english?"overview-unavailable-en":"overview-unavailable-zh");
        assert(frame_pixel(40,153)!=0xfaa0&&frame_pixel(40,209)!=0xfaa0);
        rows[1].connected=rows[1].progress_available=rows[2].enabled=true;
        c6_renderer_printer_overview(&r,rows,3);memcpy(reference,frame,sizeof(frame));
        c6_renderer_printer_overview(&r,rows,4);assert(!memcmp(reference,frame,sizeof(frame)));
    }
    c6_renderer_printer_overview(&r,NULL,0);
    puts("Printer overview: 2/3 rows, bilingual, independent progress, 0/100/unknown/disabled and bounded count passed");
    puts("Formlabs pixel font: exact integer blocks, binary edges and monospace advances passed");
    puts("Formlabs smooth clock: 101 incremental/full parity frames, endpoint, midnight, timing, cancellation passed; GIF uses actual RGB565 renderer");return 0;
}
