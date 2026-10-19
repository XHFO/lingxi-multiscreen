// Shared, allocation-free font renderer. The caller owns pixel() and the buffer.
typedef struct { char character; int width; const char *data; } glyph_t;
#include "clock_fonts.h"
static const glyph_t *glyph(char c,bool large) {
    if(!large)c=toupper((unsigned char)c);
    const glyph_t *font=large?font7:font2;
    size_t count=large?sizeof(font7)/sizeof(font7[0]):sizeof(font2)/sizeof(font2[0]);
    for(size_t i=0;i<count;i++)if(font[i].character==c)return &font[i];
    return NULL;
}
static void fallback_letter(char character,int x,int y,uint16_t color) {
    // Compact Latin fallback for diagnostic labels absent from the clock subset.
    static const uint8_t rows[26][7]={
        {14,17,17,31,17,17,17},{30,17,17,30,17,17,30},{14,17,16,16,16,17,14},
        {30,17,17,17,17,17,30},{31,16,16,30,16,16,31},{31,16,16,30,16,16,16},
        {14,17,16,23,17,17,15},{17,17,17,31,17,17,17},{31,4,4,4,4,4,31},
        {7,2,2,2,18,18,12},{17,18,20,24,20,18,17},{16,16,16,16,16,16,31},
        {17,27,21,21,17,17,17},{17,25,21,19,17,17,17},{14,17,17,17,17,17,14},
        {30,17,17,30,16,16,16},{14,17,17,17,21,18,13},{30,17,17,30,20,18,17},
        {15,16,16,14,1,1,30},{31,4,4,4,4,4,4},{17,17,17,17,17,17,14},
        {17,17,17,17,17,10,4},{17,17,17,21,21,21,10},{17,17,10,4,10,17,17},
        {17,17,10,4,4,4,4},{31,1,2,4,8,16,31}
    };
    int c=toupper((unsigned char)character)-'A';
    if(c<0||c>=26)return;
    for(int r=0;r<7;r++)for(int col=0;col<5;col++)
        if(rows[c][r]&(16>>col))pixel(x+col,y+4+r,color);
}
static void clock_text(const char *text,int x,int y,bool large,bool centered,uint16_t color) {
    if(centered){int width=0;for(const char *p=text;*p;p++){const glyph_t *g=glyph(*p,large);width+=g?g->width:6;}x-=width/2;y-=large?24:8;}
    for(const char *p=text;*p;p++){
        const glyph_t *g=glyph(*p,large);if(!g){fallback_letter(*p,x,y,color);x+=6;continue;}
        unsigned char data[384];size_t size=0;
        if(mbedtls_base64_decode(data,sizeof(data),&size,(const unsigned char*)g->data,strlen(g->data))!=0)continue;
        if(large){int pos=0;for(size_t i=0;i<size&&pos<g->width*48;i++){
            int count=(data[i]&127)+1;
            if(data[i]&128)for(int k=0;k<count&&pos+k<g->width*48;k++)pixel(x+(pos+k)%g->width,y+(pos+k)/g->width,color);
            pos+=count;
        }}else{int stride=(g->width+6)/8;for(int row=0;row<16;row++)for(int col=0;col<g->width;col++){
            int index=row*stride+col/8;if(index<(int)size&&(data[index]&(128>>(col%8))))pixel(x+col,y+row,color);
        }}
        x+=g->width;
    }
}
