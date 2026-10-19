#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "c6_display_renderer.h"
#include "qrcodegen.h"

static uint8_t frame[C6_RENDER_BYTES],reference[C6_RENDER_BYTES];
static unsigned value(int x,int y){return (frame[(y*240+x)*2]<<8)|frame[(y*240+x)*2+1];}
static CGImageRef image(void){
    uint8_t rgb[240*240*3];
    for(int y=0;y<240;y++)for(int x=0;x<240;x++){unsigned p=value(x,y),i=(y*240+x)*3;rgb[i]=((p>>11)&31)*255/31;rgb[i+1]=((p>>5)&63)*255/63;rgb[i+2]=(p&31)*255/31;}
    CFDataRef data=CFDataCreate(NULL,rgb,sizeof(rgb));CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef result=CGImageCreate(240,240,8,24,720,space,(CGBitmapInfo)kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);CGDataProviderRelease(provider);CFRelease(data);return result;
}
static void verify_qr(const char *payload){
    uint8_t qr[qrcodegen_BUFFER_LEN_FOR_VERSION(4)],scratch[qrcodegen_BUFFER_LEN_FOR_VERSION(4)];
    assert(qrcodegen_encodeText(payload,scratch,qr,qrcodegen_Ecc_MEDIUM,1,4,qrcodegen_Mask_AUTO,true));
    int size=qrcodegen_getSize(qr),scale=140/(size+8),edge=(size+8)*scale,x=(240-edge)/2,y=48+(140-edge)/2;
    for(int yy=0;yy<edge;yy++)for(int xx=0;xx<edge;xx++){
        int row=yy/scale-4,col=xx/scale-4;bool on=row>=0&&row<size&&col>=0&&col<size&&qrcodegen_getModule(qr,col,row);
        assert(value(x+xx,y+yy)==(on?0:0xffff));
    }
    CGImageRef rendered=image();CIImage *input=[[CIImage alloc] initWithCGImage:rendered];
    input=[[input imageByCroppingToRect:CGRectMake(x,240-y-edge,edge,edge)] imageByApplyingTransform:CGAffineTransformMakeScale(4,4)];
    CIContext *context=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    CIDetector *detector=[CIDetector detectorOfType:CIDetectorTypeQRCode context:context options:@{CIDetectorAccuracy:CIDetectorAccuracyHigh}];
    NSArray *features=[detector featuresInImage:input];assert(features.count==1);
    assert(!strcmp(((CIQRCodeFeature *)features.firstObject).messageString.UTF8String,payload));CGImageRelease(rendered);
}
static void write_png(const char *dir,const char *name){
    char path[1024];snprintf(path,sizeof(path),"%s/%s.png",dir,name);CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)path,strlen(path),false);
    CGImageDestinationRef dest=CGImageDestinationCreateWithURL(url,CFSTR("public.png"),1,NULL);CGImageRef rendered=image();
    assert(dest);CGImageDestinationAddImage(dest,rendered,NULL);assert(CGImageDestinationFinalize(dest));CGImageRelease(rendered);CFRelease(dest);CFRelease(url);
}
int main(int argc,char **argv){@autoreleasepool{
    assert(argc==2);c6_renderer_t r={0};assert(c6_renderer_init(&r,frame,sizeof(frame)));
    const char *payloads[]={"WIFI:T:nopass;S:XH-Multiscreen-ABC123;;","http://192.168.4.1/","http://192.168.8.42/standalone#printers"};
    const char *titles[]={"扫码连接热点","打开配网后台","联网成功 · 扫码设置"};
    const char *addresses[]={"XH-Multiscreen-ABC123","192.168.4.1","192.168.8.42"};
    const char *footers[]={"单击切换二维码 · 长按设置","单击切换二维码 · 长按设置","先切回同一 Wi-Fi · 单击指引"};
    const char *names[]={"setup-hotspot","setup-web","setup-lan"};
    for(unsigned english=0;english<2;english++)for(unsigned i=0;i<3;i++){
        r.english=english;assert(c6_renderer_setup_qr(&r,payloads[i],titles[i],addresses[i],footers[i],NULL));
        assert(c6_renderer_text_width(c6_renderer_localized(&r,footers[i]),english?10:12)<=208);
        assert(value(0,0)==0&&value(4,4)==0x3186&&value(16,16)==0xfaa0);
        verify_qr(payloads[i]);memcpy(reference,frame,sizeof(frame));r.smooth_digits=true;
        assert(c6_renderer_setup_qr(&r,payloads[i],titles[i],addresses[i],footers[i],NULL));assert(!memcmp(frame,reference,sizeof(frame)));r.smooth_digits=false;
        char name[64];snprintf(name,sizeof(name),"%s-%s",names[i],english?"en":"zh");write_png(argv[1],name);
    }
    puts("Setup RGB565: shared orange/black terminal theme, bilingual, fixed QR quiet zone/integer pixels, six independently decoded payloads, utility-font parity passed. Not physical LCD/phone acceptance.");return 0;
}}
