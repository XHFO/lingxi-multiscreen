// The PNG comes from the firmware's actual RGB565 buffer, not a UI mockup.
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <assert.h>
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../../Tools/WaveshareC6Firmware/src/local_sources.h"

standalone_config_t standalone_config;
static uint8_t frame[240*240*2];
#define FRAME_BYTES sizeof(frame)
static uint32_t frame_generation;
static time_t preview_now=1791453000;
static time_t preview_time(time_t *output){if(output)*output=preview_now;return preview_now;}
uint64_t c6_seconds(void){return 100;}
#define time preview_time
static uint16_t rgb(int r,int g,int b){return ((r&248)<<8)|((g&252)<<3)|(b>>3);}
static void display_frame(void){frame_generation++;}
static uint8_t sample_thumbnail[80*80*2];static bool thumbnail_available;
bool c6_sources_thumbnail_visit(const char *serial,const char *key,c6_thumbnail_visitor_t visitor,void *context){
    if(!thumbnail_available)return false;visitor(sample_thumbnail,80,80,160,context);return true;
}
void c6_sources_media_focus(int group,int printer){}
void c6_sources_entity_pictures_visit(unsigned first,unsigned count,c6_media_visitor_t visitor,void *context){
    c6_thumbnail_cache_t sample={.bytes=sample_thumbnail,.width=80,.height=80};const c6_thumbnail_cache_t *pictures[4]={0};
    if(thumbnail_available)for(unsigned i=0;i<count&&i<4;i++)pictures[i]=&sample;
    visitor(pictures,count,context);
}
void c6_sources_printer_pictures_visit_scoped(const char *serial,const char *brand,const char *source,const char *key,c6_media_visitor_t visitor,void *context){
    c6_thumbnail_cache_t sample={.bytes=sample_thumbnail,.width=80,.height=80};const c6_thumbnail_cache_t *pictures[]={thumbnail_available?&sample:NULL,NULL};visitor(pictures,2,context);
}
#include "../../Sources/C6DisplayRenderer/include/c6_display_styles.h"
#include "../../Tools/WaveshareC6Firmware/src/local_render.h"
#include "../../Tools/WaveshareC6Firmware/src/clock_animation.h"

static uint32_t expanded565(uint16_t color){unsigned r=(color>>11)&31,g=(color>>5)&63,b=color&31;return ((r*255/31)<<16)|((g*255/63)<<8)|(b*255/31);}
static double luminance(uint32_t color){double result=0;const double weights[]={0.2126,0.7152,0.0722};for(int i=0;i<3;i++){double c=((color>>(16-i*8))&255)/255.0;result+=weights[i]*(c<=0.04045?c/12.92:pow((c+0.055)/1.055,2.4));}return result;}
static double contrast(uint32_t a,uint32_t b){double first=luminance(a),last=luminance(b);return (fmax(first,last)+0.05)/(fmin(first,last)+0.05);}
static bool text_clearzone(int x,int y){
    return (x>=18&&x<222&&y>=16&&y<35)||(x>=18&&x<141&&y>=60&&y<112)||(x>=18&&x<222&&y>=126&&y<225);
}
static bool write_png(const char *directory,const char *name){
    uint8_t pixels[240*240*3];for(size_t i=0;i<240*240;i++){uint32_t color=expanded565(((uint16_t)frame[i*2]<<8)|frame[i*2+1]);pixels[i*3]=color>>16;pixels[i*3+1]=color>>8;pixels[i*3+2]=color;}
    char path[1024];snprintf(path,sizeof(path),"%s/%s.png",directory,name);
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)path,strlen(path),false);
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,pixels,sizeof(pixels),NULL);
    CGImageRef image=CGImageCreate(240,240,8,24,240*3,space,(CGBitmapInfo)kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault);
    CGImageDestinationRef destination=CGImageDestinationCreateWithURL(url,CFSTR("public.png"),1,NULL);
    bool ok=destination&&image;if(ok){CGImageDestinationAddImage(destination,image,NULL);ok=CGImageDestinationFinalize(destination);}
    if(destination)CFRelease(destination);if(image)CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(space);CFRelease(url);return ok;
}
static bool write_raw(const char *directory,const char *name){char path[1024];snprintf(path,sizeof(path),"%s/%s.rgb565",directory,name);FILE *file=fopen(path,"wb");if(!file)return false;bool ok=fwrite(frame,1,sizeof(frame),file)==sizeof(frame);fclose(file);return ok;}
int main(int argc,char **argv){
    assert(argc==2);strcpy(standalone_config.weather_city,"上海");standalone_config.timezone=28800;
    standalone_config.saturation_percent=100;standalone_config.contrast_percent=100;
    c6_source_snapshot_t sources={0};sources.weather=(c6_weather_state_t){.valid=true,.temperature=26,.apparent=27,.low=21,.high=28,.code=0,.rain=10,.epoch=(uint64_t)time(NULL)};
    const int codes[]={0,2,3,48,53,63,73,95,-1};const char *names[]={"sunny","cloudy","overcast","fog","drizzle","rain","snow","thunder","unknown"};
    for(unsigned i=0;i<sizeof(codes)/sizeof(codes[0]);i++){
        sources.weather.code=codes[i];c6_weather_style_t style=c6_weather_style(codes[i]);
        c6_renderer_weather_background(renderer(),codes[i]);
        double minimum=100;int worst_x=0,worst_y=0;
        for(int y=0;y<240;y++)for(int x=0;x<240;x++)if(text_clearzone(x,y)){
            size_t p=(y*240+x)*2;double current=contrast(expanded565(rgb(style.accent>>16,(style.accent>>8)&255,style.accent&255)),expanded565(((uint16_t)frame[p]<<8)|frame[p+1]));
            if(current<minimum){minimum=current;worst_x=x;worst_y=y;}
        }
        assert(minimum>=4.5);printf("%s clearzone RGB565 min contrast %.3f at %d,%d\n",names[i],minimum,worst_x,worst_y);
        char backdrop[64];snprintf(backdrop,sizeof(backdrop),"%s-background",names[i]);assert(write_png(argv[1],backdrop));
        draw_weather(&sources);assert(write_png(argv[1],names[i]));assert(write_raw(argv[1],names[i]));
    }
    sources.weather.code=0;
    const int temperatures[]={-40,-9,0,9,100};
    for(unsigned n=0;n<5;n++){sources.weather.temperature=temperatures[n];draw_weather(&sources);char name[64];snprintf(name,sizeof(name),"temperature-%d",temperatures[n]);assert(write_png(argv[1],name));}
    sources.weather.temperature=26;draw_weather(&sources);uint32_t before=frame_generation;
    draw_weather(&sources);assert(frame_generation==before);
    sources.weather.temperature=27;draw_weather(&sources);assert(frame_generation==++before);
    sources.weather.apparent=8;draw_weather(&sources);assert(frame_generation==++before);
    sources.weather.low=19;draw_weather(&sources);assert(frame_generation==++before);
    sources.weather.high=29;draw_weather(&sources);assert(frame_generation==++before);
    sources.weather.code=2;draw_weather(&sources);assert(frame_generation==++before);
    sources.weather.rain=80;draw_weather(&sources);assert(frame_generation==++before);
    sources.weather.epoch--;draw_weather(&sources);assert(frame_generation==++before);
    preview_now+=10801;draw_weather(&sources);assert(frame_generation==++before); // Only the stale label changes.
    sources.weather.epoch=time(NULL)-10801;draw_weather(&sources);assert(frame_generation==++before);
    standalone_config.weather_city[0]='X';draw_weather(&sources);assert(frame_generation==++before);
    standalone_config.timezone=0;draw_weather(&sources);assert(frame_generation==++before);
    standalone_config.brightness=10;draw_weather(&sources);assert(frame_generation==++before);
    standalone_config.rotation=180;draw_weather(&sources);assert(frame_generation==++before);
    standalone_config.revision++;draw_weather(&sources);assert(frame_generation==++before);
    sources.weather.valid=false;draw_weather(&sources);assert(frame_generation==++before);
    frame_generation++;frame[(130*240+25)*2]=frame[(130*240+25)*2+1]=0;before++;draw_weather(&sources);assert(frame_generation==++before);
    display_frame();before++;draw_weather(&sources);assert(frame_generation==++before);
    struct tm t={.tm_hour=12,.tm_min=34,.tm_sec=56,.tm_year=126,.tm_mon=9,.tm_mday=8,.tm_wday=4};draw_flip_clock(&t);before++;
    assert(write_png(argv[1],"flip-clock"));assert(write_raw(argv[1],"flip-clock"));draw_weather(&sources);assert(frame_generation==++before);
    c6_render_clock_t round_time={2026,10,8,4,12,34,56};
    c6_renderer_round_clock(renderer(),&round_time,NULL);
    assert(write_png(argv[1],"round-clock"));assert(write_raw(argv[1],"round-clock"));
    standalone_config.saturation_percent=150;draw_weather(&sources);assert(frame_generation==++before);
    standalone_config.contrast_percent=125;draw_weather(&sources);assert(frame_generation==++before);
    draw_weather(&sources);assert(frame_generation==before); // A cached calibrated frame is never corrected twice.
    standalone_config.saturation_percent=standalone_config.contrast_percent=100;
    assert(c6_renderer_text_width("WWW",16)>c6_renderer_text_width("iii",16));
    memset(frame,0,sizeof(frame));c6_renderer_label(renderer(),"English 中文抗锯齿",18,60,22,204,0xffffff);
    unsigned antialias=0;for(size_t i=0;i<sizeof(frame);i+=2){unsigned c=((unsigned)frame[i]<<8)|frame[i+1];if(c&&c!=65535)antialias++;}
    assert(antialias>100);assert(write_png(argv[1],"smooth-font"));
    c6_render_entity_t entities[]={{"客厅空气温度传感器","24.6","°C",true},{"Bedroom humidity","53","%",true},{"书房氛围照明","on","",true},{"长状态设备示例","服务器状态不可用","",false}};
    c6_renderer_entities(renderer(),"Home System",entities,4,true);assert(write_png(argv[1],"entities4"));assert(write_raw(argv[1],"entities4"));
    standalone_config.entity_count=4;sources.ha_connected=true;
    for(unsigned i=0;i<4;i++){snprintf(sources.entities[i].name,64,"%s",entities[i].name);snprintf(sources.entities[i].state,128,"%s",entities[i].state);snprintf(sources.entities[i].unit,32,"%s",entities[i].unit);sources.entities[i].available=true;}
    draw_entity(0,&sources);assert(write_raw(argv[1],"entities4-shared"));
    c6_renderer_entities(renderer(),"Home System",entities,1,true);assert(write_png(argv[1],"entity1"));
    c6_renderer_entities(renderer(),"Home System",entities,2,true);assert(write_png(argv[1],"entities2"));
    standalone_config.entity_count=6;for(unsigned i=0;i<6;i++){snprintf(standalone_config.entities[i].name,64,"设备 %d",i+1);snprintf(sources.entities[i].state,128,"%d",i+1);sources.entities[i].available=true;}
    draw_entity(1,&sources);assert(write_png(argv[1],"entities6-second-page"));before=frame_generation;draw_entity(1,&sources);assert(frame_generation==before);
    sources.entities[4].updated++;draw_entity(1,&sources);assert(frame_generation==before);
    strcpy(sources.entities[4].state,"新状态");draw_entity(1,&sources);assert(frame_generation==++before);
    frame_generation++;before++;draw_entity(1,&sources);assert(frame_generation==++before);
    for(unsigned i=0;i<80*80;i++){uint16_t c=rgb((i%80)*3,((i/80)%80)*3,128);sample_thumbnail[i*2]=c>>8;sample_thumbnail[i*2+1]=c;}
    c6_render_printer_t printer={.name="工作室 X2D",.task="长文件名测试 双层收纳结构打印项目",.status="PRINTING",.progress=67,.remaining=92,.connected=true,.show_task=true,.show_progress=true,.show_status=true,.show_remaining=true,.show_image=true,.thumbnail_rgb565=sample_thumbnail,.thumbnail_width=80,.thumbnail_height=80,.thumbnail_stride=160,.image_label="实况"};
    c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"printer-all-fields"));assert(write_raw(argv[1],"printer-all-fields"));
    printer.thumbnail_rgb565=NULL;c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"printer-no-cover"));
    // Real portable classic-style frames: palette/flags/details, not composited UI.
    const c6_render_style_t light={.background=0xeef2f7,.card=0xffffff,.inset=0xf3f6fa,.border=0xcbd5e1,.accent=0x0f766e,.secondary_accent=0x2563eb,.primary_text=0x0f172a,.secondary_text=0x414d61,.tertiary_text=0x5d6c82,.enabled=true};
    c6_render_style_t dark=c6_renderer_default_style();
    c6_renderer_entities_styled(renderer(),"Home System",entities,4,true,&light);assert(write_png(argv[1],"classic-ha-light"));
    c6_renderer_entities_styled(renderer(),"Home System",entities,4,true,&dark);assert(write_png(argv[1],"classic-ha-dark"));
    c6_renderer_entities_styled(renderer(),"Home System",entities,1,true,&light);assert(write_png(argv[1],"classic-ha-single"));
    c6_render_entity_t long_states[]={{"Bedroom temperature sensor","Temperature sensor temporarily unavailable","",false},{"客厅窗帘设备名称示例","正在等待服务器重新连接","",false}};
    c6_renderer_entities_styled(renderer(),"Home System",long_states,2,false,&light);assert(write_png(argv[1],"classic-ha-long-english"));
    printer.thumbnail_rgb565=sample_thumbnail;printer.style=light;printer.style.accent=0x629e4e;
    printer.nozzle="220 °C";printer.bed="60 °C";printer.show_temperature=true;
    printer.time_text="预计结束 16:38";printer.updated_text="数据更新  15:06:21";printer.image_label="任务";
    c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"classic-printer-light"));assert(write_raw(argv[1],"classic-printer-light"));
    uint8_t detailed[FRAME_BYTES];memcpy(detailed,frame,sizeof(frame));
    printer.style=dark;c6_renderer_printer(renderer(),&printer);assert(memcmp(detailed,frame,sizeof(frame)));assert(write_png(argv[1],"classic-printer-dark"));
    printer.show_temperature=false;printer.show_task=false;printer.show_progress=false;printer.show_remaining=false;
    c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"classic-printer-cover-expanded"));
    // With more room, the cover extends above its old compact region.
    size_t cover_top=(80*240+120)*2;assert(frame[cover_top]||frame[cover_top+1]);
    printer.show_temperature=printer.show_task=printer.show_progress=printer.show_remaining=true;
    printer.status="ERROR";printer.is_error=true;printer.show_error=true;printer.error="喷嘴温度异常";
    c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"classic-printer-error"));
    printer.task="A rather long English filename with useful word boundaries.gcode";printer.name="Bedroom Bambu X2D printer";
    c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"classic-printer-long-english"));
    printer.thumbnail_rgb565=NULL;printer.show_image=true;c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"classic-printer-waiting-image"));
    printer.show_image=false;c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"classic-printer-image-disabled"));
    printer.is_error=printer.show_error=false;printer.error="";printer.name="工作室 X2D";printer.task="长文件名测试 双层收纳结构打印项目";printer.status="PRINTING";
    printer.camera_configured=printer.cover_configured=printer.show_image=true;
    printer.camera=(c6_render_picture_t){sample_thumbnail,80,40,160};printer.cover=(c6_render_picture_t){sample_thumbnail,80,80,160};
    printer.style=light;c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"dual-printer-light"));
    printer.style=dark;c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"dual-printer-dark"));
    printer.show_task=printer.show_temperature=printer.show_remaining=false;c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"dual-printer-expanded"));
    printer=(c6_render_printer_t){.name="工作室 Form 4",.task="打印任务 双层收纳盒",.status="printing",.progress=37,.connected=true,.show_task=true,.show_status=true,.show_progress=true,.show_remaining=true,.time_text="剩余 92 分钟",.show_image=true,.cover_configured=true,.formlabs=true,.layers="层数 120 / 320",.material="Clear V5",.cover={sample_thumbnail,80,80,160},.style=light};
    printer.style.accent=0x2878db;c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"formlabs-light"));assert(write_raw(argv[1],"formlabs-shared"));
    printer.style=dark;printer.style.accent=0x2878db;c6_renderer_printer(renderer(),&printer);assert(write_png(argv[1],"formlabs-dark"));
    entities[0].name="工作室摄像头";entities[0].media=true;entities[0].picture=(c6_render_picture_t){sample_thumbnail,80,40,160};
    entities[1].name="打印任务封面";entities[1].media=true;entities[1].picture=(c6_render_picture_t){sample_thumbnail,80,80,160};
    c6_renderer_entities_styled(renderer(),"Home System",entities,4,true,&light);assert(write_png(argv[1],"ha-media4-light"));
    c6_renderer_entities_styled(renderer(),"Home System",entities,4,true,&dark);assert(write_png(argv[1],"ha-media4-dark"));
    c6_renderer_entities_styled(renderer(),"Home System",entities,2,true,&light);assert(write_png(argv[1],"ha-media2-light"));
    puts("Classic C6 palette/light-dark/brand accent, optional details and long English fixtures passed");
    c6_render_clock_t old={2026,10,8,4,12,59,59},next={2026,10,8,4,13,0,0};uint8_t baseline[FRAME_BYTES];
    c6_renderer_clock(renderer(),&old,NULL,1000);memcpy(baseline,frame,sizeof(frame));
    c6_renderer_clock(renderer(),&next,&old,0);assert(!memcmp(baseline,frame,sizeof(frame)));
    for(unsigned p=0;p<=1000;p+=250){char name[32];snprintf(name,sizeof(name),"flip-%d",p);c6_renderer_clock(renderer(),&next,&old,p);assert(write_png(argv[1],name));}
    memcpy(baseline,frame,sizeof(frame));c6_renderer_clock(renderer(),&next,NULL,1000);assert(!memcmp(baseline,frame,sizeof(frame)));
    assert(c6_renderer_font_bytes()<600000);printf("Portable smooth font flash payload: %zu bytes / cache %d bytes\n",c6_renderer_font_bytes(),C6_AA_CACHE_BYTES);
    standalone_config.printers[0]=(c6_printer_config_t){.show_status=true,.show_task=true,.show_progress=true,.show_remaining=true,.show_image=true};
    strcpy(standalone_config.printers[0].name,"设备");strcpy(sources.printers[0].task,"任务");strcpy(sources.printers[0].status,"PRINTING");sources.printers[0].connected=true;sources.printers[0].progress_valid=true;sources.printers[0].updated=50;
    thumbnail_available=true;sources.thumbnail_status[0]=1;draw_printer(0,&sources);before=frame_generation;
    draw_printer(0,&sources);assert(frame_generation==before);sources.printers[0].updated++;draw_printer(0,&sources);assert(frame_generation==before);
    sources.printers[0].progress++;draw_printer(0,&sources);assert(frame_generation==++before);
    standalone_config.printers[0].show_progress=false;draw_printer(0,&sources);assert(frame_generation==++before);
    sources.printers[0].progress++;draw_printer(0,&sources);assert(frame_generation==before);
    strcpy(sources.printers[0].thumbnail_key,"new-task-key");draw_printer(0,&sources);assert(frame_generation==++before);
    sources.thumbnail_revision[0]++;draw_printer(0,&sources);assert(frame_generation==++before);
    draw_printer(0,&sources);assert(frame_generation==before); // Same camera frame doesn't redraw.
    strcpy(standalone_config.printers[0].image_entity,"camera.x2d_camera");draw_printer(0,&sources);assert(frame_generation==++before);
    c6_clock_animation_t animation={0};unsigned progress;uint32_t generation=1;
    assert(c6_clock_animation_step(&animation,&old,99,0,generation,true,false,&progress)&&progress==1000&&!animation.active);
    c6_clock_animation_commit(&animation,++generation);assert(!c6_clock_animation_step(&animation,&old,99,200000,generation,true,false,&progress));
    assert(c6_clock_animation_step(&animation,&next,100,1000000,generation,true,false,&progress)&&progress==0&&animation.active);
    c6_clock_animation_commit(&animation,++generation);
    assert(c6_clock_animation_step(&animation,&next,100,1000000+C6_CLOCK_DURATION_US/2,generation,true,false,&progress)&&progress==500);
    c6_clock_animation_commit(&animation,++generation);
    assert(c6_clock_animation_step(&animation,&next,100,1000000+C6_CLOCK_DURATION_US,generation,true,false,&progress)&&progress==1000&&!animation.active);
    c6_clock_animation_commit(&animation,++generation);assert(!c6_clock_animation_step(&animation,&next,100,1000000+C6_CLOCK_DURATION_US+100000,generation,true,false,&progress));
    c6_clock_animation_cancel(&animation);assert(c6_clock_animation_step(&animation,&old,200,2000000,generation,true,false,&progress)&&!animation.active);
    c6_clock_animation_commit(&animation,++generation);assert(c6_clock_animation_step(&animation,&next,201,3000000,generation,true,false,&progress)&&animation.active);
    assert(c6_clock_animation_step(&animation,&next,201,3100000,++generation,true,false,&progress)&&!animation.active); // New page / partial upload / control invalidates it.
    c6_clock_animation_commit(&animation,++generation);assert(c6_clock_animation_step(&animation,&old,3600,3200000,generation,true,false,&progress)&&!animation.active); // Calibration jump never plays stale digits.
    c6_clock_animation_commit(&animation,++generation);assert(c6_clock_animation_step(&animation,&next,3601,4200000,generation,false,false,&progress)&&!animation.active);
    puts("Flip clock 720ms / 33ms scheduling, 1Hz idle, page/upload/control cancellation and time jumps passed");
    c6_render_menu_row_t menu[]={{"屏幕显示","方向与时钟动画"},{"轮询卡片","选择参与自动轮转的卡片"},{"网页详细配置","手机扫码 · 无需 PIN"},{"网络","连接信息与重置 Wi-Fi"},{"设备信息","固件与运行时间"}};
    c6_renderer_menu(renderer(),"设备设置",menu,5,1,"单击切换 · 双击确认 · 长按返回",NULL);assert(write_png(argv[1],"menu-dark"));
    c6_render_style_t menu_light=light;
    c6_renderer_menu(renderer(),"设备设置",menu,5,1,"单击切换 · 双击确认 · 长按返回",&menu_light);assert(write_png(argv[1],"menu-light"));
    c6_render_menu_row_t reset[]={{"取消","不修改网络配置"},{"重置 Wi-Fi","仅清除网络 · 不恢复出厂"}};
    c6_renderer_menu(renderer(),"确认重置 Wi-Fi",reset,2,0,"单击下一项 · 双击确认 · 长按返回",NULL);assert(write_png(argv[1],"menu-reset"));
    c6_render_style_t pin_style=c6_renderer_default_style();
    c6_renderer_pairing(renderer(),"0123",120,&pin_style);assert(write_png(argv[1],"menu-pin"));
    c6_renderer_pairing(renderer(),"0123",120,&menu_light);assert(write_png(argv[1],"menu-pin-light"));
    assert(c6_renderer_qr(renderer(),"http://192.168.1.123/standalone","192.168.1.123",NULL));assert(write_png(argv[1],"menu-qr-dark"));
    assert(c6_renderer_qr(renderer(),"http://192.168.1.123/standalone","192.168.1.123",&menu_light));assert(write_png(argv[1],"menu-qr-light"));
    c6_render_menu_row_t rotation[]={{"屏幕翻转","180° · 双击恢复"},{"动态翻页","已开启 · 双击关闭"}};
    c6_renderer_menu(renderer(),"屏幕显示",rotation,2,0,"长按返回 · 自动保存",NULL);assert(write_png(argv[1],"menu-display"));
    puts("C6 exact framebuffer preview, menu light/dark/reset, text clearzone contrast and weather redraw invalidation passed");
}
