// A static procedural sky: no decoded artwork, extra framebuffer or animation.
// The same code is included by the host RGB565 preview test.
static uint32_t weather_mix24(uint32_t base,uint32_t overlay,unsigned alpha){
    if(alpha>255)alpha=255;
    uint32_t result=0;
    for(int shift=16;shift>=0;shift-=8){unsigned a=(base>>shift)&255,b=(overlay>>shift)&255;result|=((a*(255-alpha)+b*alpha+127)/255)<<shift;}return result;
}
static uint16_t weather_rgb565(uint32_t color,int x,int y){
    // 16-byte ordered dithering smooths the 5/6/5-bit LCD's broad sky bands.
    // It is deterministic: no noise texture, random work, or moving grain.
    static const uint8_t matrix[16]={0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5};
    unsigned threshold=matrix[(y&3)*4+(x&3)];
    unsigned r=(((color>>16)&255)*31*16+threshold*255)/(255*16);
    unsigned g=(((color>>8)&255)*63*16+threshold*255)/(255*16);
    unsigned b=((color&255)*31*16+threshold*255)/(255*16);
    return (r<<11)|(g<<5)|b;
}
static uint32_t weather_pixel24(c6_renderer_t *r,int x,int y){
    size_t i=(y*240+x)*2;uint16_t c=((uint16_t)r->frame[i]<<8)|r->frame[i+1];
    return (((c>>11)*255/31)<<16)|((((c>>5)&63)*255/63)<<8)|((c&31)*255/31);
}
static unsigned weather_ease(unsigned value){if(value>255)value=255;return value*value*(765-2*value)/65025;}
static unsigned weather_clearance(int y){return y<47?0:y<60?weather_ease((y-47)*255/13):255;}
static void weather_blend_pixel(c6_renderer_t *r,int x,int y,uint32_t color,unsigned alpha){
    if(x<0||x>=240||y<0||y>=240||!alpha)return;
    pixel(r,x,y,weather_rgb565(weather_mix24(weather_pixel24(r,x,y),color,alpha),x,y));
}
static unsigned weather_ellipse(int x,int y,int cx,int cy,int rx,int ry){
    int dx=x-cx,dy=y-cy;unsigned q=(unsigned)(dx*dx*1024/(rx*rx)+dy*dy*1024/(ry*ry));
    return q>=1120?0:q<=870?255:weather_ease((1120-q)*255/250);
}
static unsigned weather_cloud_alpha(int x,int y,int width,int height){
    // Overlapping soft lobes form one continuous cloud, not outlined circles.
    static const uint8_t points[][4]={{25,57,24,31},{46,37,26,33},{70,55,23,28},{47,67,44,20},{82,66,18,22}};
    unsigned alpha=0;
    for(unsigned i=0;i<5;i++){
        unsigned part=weather_ellipse(x,y,width*points[i][0]/100,height*points[i][1]/100,
            width*points[i][2]/100,height*points[i][3]/100);
        alpha=255-(255-alpha)*(255-part)/255;
    }return alpha;
}
static void weather_soft_cloud(c6_renderer_t *r,c6_weather_style_t style,int left,int top,int width,int height,unsigned opacity,bool backdrop){
    bool storm=style.kind==C6_WEATHER_THUNDER;
    int first_x=left<0?0:left,last_x=left+width>240?240:left+width;
    int first_y=top<0?0:top,last_y=top+height+5>240?240:top+height+5;
    uint32_t highlight=storm?0x626d85:0xffffff,mid=style.cloud,shadow=storm?0x323f5b:0xbdd1e2;
    for(int y=first_y;y<last_y;y++)for(int x=first_x;x<last_x;x++){
        unsigned clearance=backdrop?weather_clearance(y):255;
        // A subdued cool underside supplies depth without a hard outline.
        unsigned down=weather_cloud_alpha(x-left,y-top-3,width,height)*opacity/255;
        weather_blend_pixel(r,x,y,storm?0x19253f:0x244766,down*clearance/255/9);
        unsigned coverage=weather_cloud_alpha(x-left,y-top,width,height)*opacity/255;
        if(!coverage)continue;
        unsigned blend=(unsigned)(y-top)*255/(unsigned)height;
        uint32_t color=blend<115?weather_mix24(highlight,mid,blend*255/115):weather_mix24(mid,shadow,(blend-115)*255/140);
        // Side light follows the sun; the opposite side remains slightly cool.
        if(!storm&&x<left+width/2)color=weather_mix24(color,0xfff7e1,12);
        weather_blend_pixel(r,x,y,color,coverage*clearance/255);
    }
}
static void weather_soft_light(c6_renderer_t *r,c6_weather_style_t style,int cx,int cy,int radius,uint32_t color,unsigned opacity){
    (void)style;
    for(int y=0;y<240;y++)for(int x=0;x<240;x++){
        int dx=x-cx,dy=y-cy,r2=radius*radius,q=dx*dx+dy*dy;if(q>=r2)continue;
        unsigned alpha=(unsigned)((r2-q)*255/r2);alpha=alpha*alpha/255;
        alpha=alpha*opacity/255*weather_clearance(y)/255;
        weather_blend_pixel(r,x,y,color,alpha);
    }
}
static void weather_backdrop(c6_renderer_t *r,c6_weather_style_t style){
    for(int y=0;y<240;y++){uint32_t sky=c6_weather_background_at(style,y);for(int x=0;x<240;x++)pixel(r,x,y,weather_rgb565(sky,x,y));}
    // Constant geometry shared with the software weather composition.
    unsigned warm=style.kind==C6_WEATHER_CLEAR||style.kind==C6_WEATHER_CLOUDY?82:style.kind==C6_WEATHER_THUNDER?8:24;
    weather_soft_light(r,style,194,62,94,0xffeaa6,warm);
    if(style.kind!=C6_WEATHER_CLEAR){
        weather_soft_cloud(r,style,91,29,145,62,51,true);
        weather_soft_cloud(r,style,140,43,145,62,115,true);
    }
}
static void weather_soft_sun(c6_renderer_t *r,int cx,int cy,int radius){
    int outer=radius+14;
    for(int y=cy-outer;y<=cy+outer;y++)for(int x=cx-outer;x<=cx+outer;x++){
        int dx=x-cx,dy=y-cy,q=dx*dx+dy*dy,r2=radius*radius;
        if(q>(outer*outer))continue;
        if(q>r2){unsigned a=(unsigned)(outer*outer-q)*92/(unsigned)(outer*outer-r2);weather_blend_pixel(r,x,y,0xffeba5,a*a/92);continue;}
        // Rounded volume: pale warm light at top-left, amber on the underside.
        unsigned shade=(unsigned)(dy+radius)*255/(unsigned)(radius*2);
        uint32_t color=shade<150?weather_mix24(0xfff2ad,0xffd761,shade*255/150):weather_mix24(0xffd761,0xffbd43,(shade-150)*255/105);
        unsigned edge=q>r2-radius?((r2-q)*255/(unsigned)radius):255;
        weather_blend_pixel(r,x,y,color,edge);
    }
}
