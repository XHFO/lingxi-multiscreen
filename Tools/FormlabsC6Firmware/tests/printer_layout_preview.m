// Exercise actual RGB565 draw calls, not an HTML reimplementation. Test-only
// pixel ownership catches overlap even when a later rectangle erases text.
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "c6_display_renderer.h"
static uint8_t storage[C6_RENDER_BYTES+64],owners[240*240];
static unsigned group,collisions,clipped,checks;
static int first_x,first_y;static unsigned first_a,first_b;
static const char *case_name;static int case_style,case_mask,case_variant;static bool case_english;
void c6_layout_test_group(unsigned value){group=value;}
static bool han(const char *text){
    for(const unsigned char *s=(const unsigned char*)text;*s;){
        unsigned c=*s++,n=c<128?0:(c&0xe0)==0xc0?1:(c&0xf0)==0xe0?2:3;
        if(n){c&=(1U<<(6-n))-1;while(n--&&*s)c=(c<<6)|(*s++&63);}
        if((c>=0x3400&&c<=0x9fff)||(c>=0xf900&&c<=0xfaff))return true;
    }return false;
}
void c6_layout_test_text(const char *text,bool english){
    if(!english||!han(text))return;
    // Only user-controlled printer/task names may retain Chinese here. Test
    // fixtures for labels, layers, timing, placeholders and errors are English.
    bool raw=!strcmp(case_name,"overview")?(group>=2&&(group-2)%6==0):(group==1||group==4);
    if(raw)return;
    fprintf(stderr,"Unexpected Chinese in English %s (group %u): %s\n",case_name,group,text);exit(1);
}
void c6_layout_test_pixel(int x,int y,uint16_t color){
    (void)color;if(!group)return;
    if(x<15||x>224||y<12||y>225){clipped++;return;}
    unsigned at=y*240+x;
    if(owners[at]&&owners[at]!=group){
        if(!collisions){first_x=x;first_y=y;first_a=owners[at];first_b=group;}
        collisions++;
    }
    owners[at]=group;
}
static void reset(void){
    memset(owners,0,sizeof(owners));memset(storage,0xa5,sizeof(storage));
    group=collisions=clipped=0;
}
static void validate(void){
    for(unsigned i=0;i<32;i++)assert(storage[i]==0xa5&&storage[C6_RENDER_BYTES+32+i]==0xa5);
    checks++;
    if(collisions||clipped){
        fprintf(stderr,"Layout %s / style=%d / lang=%s / flags=%d / variant=%d: %u overlap pixels (groups %u/%u at %d,%d), %u clipped pixels\n",
            case_name,case_style,case_english?"en":"zh",case_mask,case_variant,collisions,first_a,first_b,first_x,first_y,clipped);
        exit(1);
    }
}
static CGImageRef image(void){
    uint8_t *pixels=malloc(240*240*3);assert(pixels);const uint8_t *frame=storage+32;
    for(unsigned i=0;i<240*240;i++){
        unsigned v=(frame[i*2]<<8)|frame[i*2+1];pixels[i*3]=((v>>11)&31)*255/31;
        pixels[i*3+1]=((v>>5)&63)*255/63;pixels[i*3+2]=(v&31)*255/31;
    }
    CFDataRef data=CFDataCreate(NULL,pixels,240*240*3);free(pixels);
    CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef result=CGImageCreate(240,240,8,24,240*3,space,(CGBitmapInfo)kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);CGDataProviderRelease(provider);CFRelease(data);return result;
}
static void png(const char *dir,const char *name,CGImageRef rendered){
    char path[1024];snprintf(path,sizeof(path),"%s/%s.png",dir,name);
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)path,strlen(path),false);
    CGImageDestinationRef dest=CGImageDestinationCreateWithURL(url,CFSTR("public.png"),1,NULL);assert(dest);CFRelease(url);
    CGImageDestinationAddImage(dest,rendered,NULL);assert(CGImageDestinationFinalize(dest));CFRelease(dest);
}
static void caption(CGContextRef ctx,const char *text,int x,int y){
    CFStringRef string=CFStringCreateWithCString(NULL,text,kCFStringEncodingUTF8);
    CTFontRef font=CTFontCreateWithName(CFSTR("Menlo"),12,NULL);CGColorRef ink=CGColorCreateGenericRGB(.9,.9,.9,1);
    const void *keys[]={kCTFontAttributeName,kCTForegroundColorAttributeName},*values[]={font,ink};
    CFDictionaryRef attributes=CFDictionaryCreate(NULL,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed=CFAttributedStringCreate(NULL,string,attributes);CTLineRef line=CTLineCreateWithAttributedString(attributed);
    CGContextSetTextPosition(ctx,x,y);CTLineDraw(line,ctx);
    CFRelease(line);CFRelease(attributed);CFRelease(attributes);CGColorRelease(ink);CFRelease(font);CFRelease(string);
}
typedef struct {const char *name,*status;bool connected,error,progress,time,complete;} fixture_t;
static const fixture_t states[]={
    {"idle","idle",true,false,false,false,false},
    {"printing","printing",true,false,true,true,false},
    {"finished","finished",true,false,true,false,true},
    {"failed","failed",true,true,true,false,false},
    {"paused","paused",true,false,true,true,false},
    {"preparing","preparing",true,false,false,false,false},
    {"postprint","postprint",true,false,true,false,false},
    {"cancelled","cancelled",true,false,true,false,false},
    {"offline","printing",false,false,true,true,false},
    {"unknown","unknown",true,false,false,false,false},
    {"no-progress","printing",true,false,false,true,false},
    {"no-time","printing",true,false,true,false,false},
    {"standby","standby",true,false,false,false,false},
    {"error-with-time","printing",true,true,true,true,false}
};
static uint8_t thumbnail[32*32*2];
static c6_render_printer_t printer(unsigned state,unsigned mask,unsigned variant,bool english){
    const fixture_t *s=&states[state];
    c6_render_printer_t p={.formlabs=true,.name="Form 4",.status=s->status,.connected=s->connected,.is_error=s->error,
        .completed=s->complete,.progress=s->complete?100:74,.remaining=42,.remaining_seconds=2520,
        .progress_available=s->progress,.remaining_available=s->time,.show_task=(mask&1)!=0,
        .show_progress=(mask&2)!=0&&s->progress,.show_remaining=(mask&4)!=0,.show_image=(mask&8)!=0,
        .show_error=(mask&16)!=0,.show_status=(mask&32)!=0,.task="Bracket assembly",
        .layers=english?"LAYERS 148 / 200":"层数 148 / 200",.material="Clear V5 · 0.1mm",.error=s->error?(english?"PRINT FAILED / CHECK TANK":"打印失败 · 检查树脂槽"):NULL,
        .time_text=s->time?"ETA 42m":""};
    if(variant==1||variant==2){
        p.demo=true;p.name="Formlabs · 超长研发打印机名称 Long user printer name";
        p.task="长任务文件名称 Mechanical bracket assembly version 2026 final final.stl";
        p.layers=english?"LAYERS 9999 / 12000":"层数 9999 / 12000";p.material="Tough 2000 V2 / long custom material 0.050mm";
        if(s->error)p.error=english?"PRINT FAILED / Please check tank and resin before restarting":"打印失败 · 超长错误提示 Please check tank and resin before restarting";
        if(s->time)p.time_text="END 2026-10-14 23:59";
        if(variant==2){p.remaining_seconds=UINT32_MAX;p.remaining=INT32_MAX;p.progress=100;
            p.thumbnail_rgb565=thumbnail;p.thumbnail_width=p.thumbnail_height=32;p.thumbnail_stride=64;}
    }
    if(variant>=3){p.layers=p.material=NULL;p.name=variant==3?NULL:"Form 4";p.task=variant==3?NULL:"Short job";
        if(variant==4){p.demo=true;p.time_text="";p.error=s->error?"Tank error":NULL;}}
    return p;
}
static void render(c6_renderer_t *r,unsigned state,unsigned style,unsigned mask,unsigned variant){
    c6_render_printer_t p=printer(state,mask,variant,r->english);p.card_style=style;
    case_name=states[state].name;case_style=style;case_mask=mask;case_variant=variant;case_english=r->english;
    reset();c6_renderer_printer(r,&p);validate();
}
static void sheet(c6_renderer_t *r,const char *dir,bool english){
    // Six distinct statuses in columns, three selectable card styles in rows.
    const unsigned selection[]={0,1,2,3,4,8};const char *styles[]={"DETAIL","PERCENT","TIME"};
    const int cellw=252,cellh=278,width=cellw*6+12,height=cellh*3+12;
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx=CGBitmapContextCreate(NULL,width,height,8,0,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);assert(ctx);CGColorSpaceRelease(space);
    CGContextSetRGBFillColor(ctx,.065,.065,.065,1);CGContextFillRect(ctx,CGRectMake(0,0,width,height));
    CGContextSetInterpolationQuality(ctx,kCGInterpolationNone);r->english=english;
    for(unsigned row=0;row<3;row++)for(unsigned col=0;col<6;col++){
        unsigned state=selection[col];render(r,state,row,63,0);CGImageRef actual=image();
        int x=12+col*cellw,y=height-12-(row+1)*cellh;
        CGContextDrawImage(ctx,CGRectMake(x,y,240,240),actual);CGImageRelease(actual);
        char title[80];snprintf(title,sizeof(title),"%s / %s",states[state].name,styles[row]);caption(ctx,title,x,y+250);
        if(row==0){actual=image();char name[80];snprintf(name,sizeof(name),"layout-%s-%s",states[state].name,english?"en":"zh");png(dir,name,actual);CGImageRelease(actual);}
    }
    CGImageRef result=CGBitmapContextCreateImage(ctx);png(dir,english?"printer-layout-en":"printer-layout-zh",result);CGImageRelease(result);CGContextRelease(ctx);
}
int main(int argc,char **argv){
    assert(argc==2);c6_renderer_t r={0};assert(c6_renderer_init(&r,storage+32,C6_RENDER_BYTES));
    for(unsigned y=0;y<32;y++)for(unsigned x=0;x<32;x++){unsigned v=((x+y)%8<4)?0xffff:0xfaa0;thumbnail[(y*32+x)*2]=v>>8;thumbnail[(y*32+x)*2+1]=v;}
    for(unsigned smooth=0;smooth<2;smooth++)for(unsigned english=0;english<2;english++){
        r.smooth_digits=smooth;r.english=english;
        for(unsigned state=0;state<sizeof(states)/sizeof(states[0]);state++)for(unsigned style=0;style<3;style++)
            for(unsigned mask=0;mask<64;mask++)for(unsigned variant=0;variant<5;variant++)render(&r,state,style,mask,variant);
    }
    r.smooth_digits=false;sheet(&r,argv[1],false);sheet(&r,argv[1],true);
    // Stale task, progress and timing must never appear on an idle/offline card.
    for(unsigned state=0;state<2;state++)for(unsigned style=0;style<3;style++){
        c6_render_printer_t p=printer(state?8:0,63,0,true);p.card_style=style;r.english=true;reset();c6_renderer_printer(&r,&p);validate();
        uint8_t reference[C6_RENDER_BYTES];memcpy(reference,storage+32,sizeof(reference));
        p.task="Stale task must disappear";p.progress=13;p.remaining_seconds=1234;p.time_text="OLD 00:01";p.layers="old layers";
        reset();c6_renderer_printer(&r,&p);validate();assert(!memcmp(reference,storage+32,sizeof(reference)));
    }
    for(unsigned english=0;english<2;english++)for(unsigned count=2;count<=3;count++)for(unsigned state=0;state<14;state++)for(unsigned flags=0;flags<16;flags++){
        c6_render_printer_summary_t rows[3]={0};r.english=english;
        for(unsigned i=0;i<count;i++)rows[i]=(c6_render_printer_summary_t){.name="Formlabs · Long user defined printer name 超长设备名称",.status=states[(state+i)%14].status,
            .enabled=!(flags&1),.connected=!(flags&2),.progress_available=!(flags&4),.demo=(flags&8)!=0,.progress=i==0?100:i==1?0:74};
        case_name="overview";case_style=count;case_mask=flags;case_variant=state;case_english=english;
        reset();c6_renderer_printer_overview(&r,rows,count);validate();
    }
    printf("Actual printer layouts: %u frames, 14 states x 3 styles x 64 flag sets x 5 text/media cases x 2 languages x 2 numeral faces, plus 2/3-printer overview; no inter-region overlap, clipping or buffer overwrite; no unexpected Chinese in English fixed UI; idle/offline stale-data suppression passed\n",checks);
}
