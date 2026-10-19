#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
// Original numeral paths inspired by continuous aerospace lettering, not a
// reproduction of the NASA trademark. Logical canvas is 14x20, tabular.
static void move(CGMutablePathRef p,double x,double y){CGPathMoveToPoint(p,NULL,x,y);}
static void line(CGMutablePathRef p,double x,double y){CGPathAddLineToPoint(p,NULL,x,y);}
static void curve(CGMutablePathRef p,double a,double b,double c,double d,double x,double y){CGPathAddCurveToPoint(p,NULL,a,b,c,d,x,y);}
static void loop(CGMutablePathRef p,double top,double bottom){
    move(p,5,top);line(p,9,top);curve(p,11.4,top,12.4,top+1.7,12.4,top+4);line(p,12.4,bottom-4);
    curve(p,12.4,bottom-1.7,11.4,bottom,9,bottom);line(p,5,bottom);curve(p,2.6,bottom,1.6,bottom-1.7,1.6,bottom-4);
    line(p,1.6,top+4);curve(p,1.6,top+1.7,2.6,top,5,top);CGPathCloseSubpath(p);
}
static CGPathRef glyph(unsigned digit){CGMutablePathRef p=CGPathCreateMutable();switch(digit){
    case 0:loop(p,1.6,18.4);break;
    case 1:move(p,3.4,5);line(p,8,1.6);line(p,8,18.4);move(p,3.8,18.4);line(p,12.2,18.4);break;
    case 2:move(p,1.6,5.5);curve(p,1.6,2.7,3.6,1.6,6,1.6);line(p,8,1.6);curve(p,10.6,1.6,12.4,3,12.4,5.4);
        curve(p,12.4,7.5,11.2,8.8,9.2,10.4);line(p,3.1,15.2);curve(p,2,16.1,1.6,16.8,1.6,18.4);line(p,12.4,18.4);break;
    case 3:move(p,1.6,1.6);line(p,8,1.6);curve(p,11,1.6,12.4,3,12.4,5.4);curve(p,12.4,8.1,10.7,9.6,8,9.6);line(p,5.2,9.6);
        move(p,8,9.6);curve(p,11,9.6,12.4,11.3,12.4,14);curve(p,12.4,16.9,10.7,18.4,8,18.4);line(p,1.6,18.4);break;
    case 4:move(p,9.5,18.4);line(p,9.5,1.6);line(p,2,11.5);curve(p,1.4,12.3,1.4,13.1,2.5,13.1);line(p,12.6,13.1);move(p,6.9,18.4);line(p,12.2,18.4);break;
    case 5:move(p,12.4,1.6);line(p,1.6,1.6);line(p,1.6,9.4);line(p,8.1,9.4);curve(p,11,9.4,12.4,11.1,12.4,14);
        curve(p,12.4,16.9,10.7,18.4,8,18.4);line(p,1.6,18.4);break;
    case 6:move(p,12.4,1.6);line(p,6.1,1.6);curve(p,3,1.6,1.6,3.5,1.6,6.5);line(p,1.6,14);
        curve(p,1.6,17,3.4,18.4,6,18.4);line(p,8.1,18.4);curve(p,11,18.4,12.4,16.7,12.4,14);curve(p,12.4,11.3,10.8,9.6,8.1,9.6);line(p,1.6,9.6);break;
    case 7:move(p,2,1.6);line(p,11.8,1.6);line(p,5.1,18.4);break;
    case 8:move(p,7,1.6);curve(p,3.5,1.6,1.6,3,1.6,5.8);curve(p,1.6,8.6,3.7,10,7,10);
        curve(p,10.3,10,12.4,11.4,12.4,14.2);curve(p,12.4,17,10.5,18.4,7,18.4);curve(p,3.5,18.4,1.6,17,1.6,14.2);
        curve(p,1.6,11.4,3.7,10,7,10);curve(p,10.3,10,12.4,8.6,12.4,5.8);curve(p,12.4,3,10.5,1.6,7,1.6);CGPathCloseSubpath(p);break;
    case 9:move(p,1.6,18.4);line(p,7.9,18.4);curve(p,11,18.4,12.4,16.5,12.4,13.5);line(p,12.4,6);
        curve(p,12.4,3,10.6,1.6,8,1.6);line(p,5.9,1.6);curve(p,3,1.6,1.6,3.3,1.6,5.8);curve(p,1.6,8.3,3.2,10,5.9,10);line(p,12.4,10);break;
}return p;}
int main(void){
    // 3x supersampling at native 42x60; packed 4-bit coverage is 12,600 B.
    enum { W=126,H=180 };uint8_t pixels[W*H];CGColorSpaceRef space=CGColorSpaceCreateDeviceGray();
    puts("// Generated from original Bezier paths in generate_smooth_aero.m.\n// 42x60, top-to-bottom, packed 4-bit alpha. No external font assets.\nstatic const uint8_t terminal_smooth_aero[10][1260]={");
    for(unsigned d=0;d<10;d++){
        CGContextRef c=CGBitmapContextCreate(pixels,W,H,8,W,space,(CGBitmapInfo)kCGImageAlphaNone);assert(c);CGContextSetGrayFillColor(c,0,1);CGContextFillRect(c,CGRectMake(0,0,W,H));
        CGContextTranslateCTM(c,0,H);CGContextScaleCTM(c,9,-9);CGContextSetShouldAntialias(c,true);CGContextSetGrayStrokeColor(c,1,1);CGContextSetLineWidth(c,3.3);
        CGContextSetLineCap(c,kCGLineCapButt);CGContextSetLineJoin(c,kCGLineJoinRound);CGPathRef p=glyph(d);CGContextAddPath(c,p);CGContextStrokePath(c);CGPathRelease(p);CGContextRelease(c);
        printf(" { // %u\n  ",d);for(unsigned y=0;y<60;y++)for(unsigned x=0;x<42;x+=2){unsigned packed=0;
            for(unsigned n=0;n<2;n++){unsigned sum=0;for(unsigned yy=0;yy<3;yy++)for(unsigned xx=0;xx<3;xx++)sum+=pixels[(y*3+yy)*W+(x+n)*3+xx];unsigned alpha=(sum*15+1147)/(9*255);packed=(packed<<4)|alpha;}
            printf("0x%02x,",packed);if((y*21+x/2+1)%21==0)printf("\n  ");
        }puts("},");
    }puts("};");CGColorSpaceRelease(space);return 0;
}
