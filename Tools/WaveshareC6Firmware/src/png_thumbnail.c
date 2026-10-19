#include "png_thumbnail.h"
#include "miniz.h"
#include <stdlib.h>
#include <string.h>
typedef struct {
    tinfl_decompressor decoder;
    uint8_t dictionary[32768],input[512],palette[768],alpha[256];
    uint8_t *previous,*row,*pixels;
    unsigned width,height,channels,color,out_width,out_height,rows,row_used,out_row,palette_count;
    size_t dictionary_position;
} png_t;
static uint32_t be32(const uint8_t *p){return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];}
static uint32_t crc32(uint32_t crc,const uint8_t *p,size_t n){for(size_t i=0;i<n;i++){crc^=p[i];for(unsigned k=0;k<8;k++)crc=(crc>>1)^(0xedb88320U&-(crc&1U));}return crc;}
static bool exact(c6_image_reader_t read,void *context,uint8_t *out,size_t count){size_t n=0;while(n<count){size_t got=read(context,out+n,count-n);if(!got||got>count-n)return false;n+=got;}return true;}
static unsigned paeth(unsigned a,unsigned b,unsigned c){int p=(int)a+(int)b-(int)c,pa=abs(p-(int)a),pb=abs(p-(int)b),pc=abs(p-(int)c);return pa<=pb&&pa<=pc?a:pb<=pc?b:c;}
static bool scanline(png_t *p,const uint8_t *bytes,size_t count){
    size_t row_size=(size_t)p->width*p->channels+1;
    for(size_t n=0;n<count;n++){
        if(p->rows>=p->height)return false;
        p->row[p->row_used++]=bytes[n];if(p->row_used<row_size)continue;
        unsigned filter=p->row[0];if(filter>4)return false;
        for(size_t i=1;i<row_size;i++){
            unsigned left=i>p->channels?p->row[i-p->channels]:0,up=p->previous[i],corner=i>p->channels?p->previous[i-p->channels]:0;
            unsigned delta=filter==0?0:filter==1?left:filter==2?up:filter==3?(left+up)/2:paeth(left,up,corner);
            p->row[i]=(uint8_t)(p->row[i]+delta);
        }
        if(p->out_row<p->out_height&&p->rows==p->out_row*p->height/p->out_height){
            for(unsigned x=0;x<p->out_width;x++){
                const uint8_t *s=p->row+1+(x*p->width/p->out_width)*p->channels;unsigned r,g,b,a=255;
                if(p->color==3){if(s[0]>=p->palette_count)return false;r=p->palette[s[0]*3];g=p->palette[s[0]*3+1];b=p->palette[s[0]*3+2];a=p->alpha[s[0]];}
                else if(p->color==0||p->color==4){r=g=b=s[0];if(p->color==4)a=s[1];}
                else {r=s[0];g=s[1];b=s[2];if(p->color==6)a=s[3];}
                r=r*a/255;g=g*a/255;b=b*a/255;uint16_t color=((r&248)<<8)|((g&252)<<3)|(b>>3);unsigned offset=(p->out_row*p->out_width+x)*2;
                p->pixels[offset]=color>>8;p->pixels[offset+1]=color&255;
            }p->out_row++;
        }
        uint8_t *swap=p->previous;p->previous=p->row;p->row=swap;p->row_used=0;p->rows++;
    }return true;
}
bool c6_png_thumbnail(c6_image_reader_t read,void *context,uint8_t *pixels,unsigned *width,unsigned *height){
    if(!read||!pixels||!width||!height)return false;
    *width=*height=0;
    uint8_t head[13];const uint8_t signature[]={137,80,78,71,13,10,26,10};
    if(!exact(read,context,head,8)||memcmp(head,signature,8))return false;
    png_t *p=calloc(1,sizeof(*p));if(!p)return false;p->pixels=pixels;memset(p->alpha,255,sizeof(p->alpha));tinfl_init(&p->decoder);
    bool ok=false,have_header=false,started=false,finished=false,ended=false;unsigned chunks=0;
    while(!ended&&chunks++<1024){
        if(!exact(read,context,head,8))break;
        uint32_t length=be32(head),crc=crc32(UINT32_MAX,head+4,4);char type[5];memcpy(type,head+4,4);type[4]=0;
        if(length>131072||(!have_header&&strcmp(type,"IHDR")))break;
        if(!strcmp(type,"IHDR")){
            if(have_header||length!=13||!exact(read,context,head,13))break;
            crc=crc32(crc,head,13);
            p->width=be32(head);p->height=be32(head+4);p->color=head[9];
            if(!p->width||!p->height||p->width>1024||p->height>1024||head[8]!=8||head[10]||head[11]||head[12])break;
            p->channels=p->color==0||p->color==3?1:p->color==2?3:p->color==4?2:p->color==6?4:0;if(!p->channels)break;
            size_t row_size=(size_t)p->width*p->channels+1;p->previous=calloc(1,row_size);p->row=malloc(row_size);if(!p->row||!p->previous)break;
            if(p->width>=p->height){p->out_width=80;p->out_height=p->height*80/p->width;}else{p->out_height=80;p->out_width=p->width*80/p->height;}
            // Do not upscale tiny source thumbnails; final renderer does smooth scaling.
            if(p->width<=80&&p->height<=80){p->out_width=p->width;p->out_height=p->height;}
            if(!p->out_width)p->out_width=1;
            if(!p->out_height)p->out_height=1;
            have_header=true;
        }else if(!strcmp(type,"PLTE")){
            if(started||length%3||length>768||!length||!exact(read,context,p->palette,length))break;
            crc=crc32(crc,p->palette,length);p->palette_count=length/3;
        }else if(!strcmp(type,"tRNS")){
            if(started||length>256||!exact(read,context,p->input,length))break;
            crc=crc32(crc,p->input,length);
            if(p->color==3)memcpy(p->alpha,p->input,length);
        }else if(!strcmp(type,"IDAT")){
            if(finished||(p->color==3&&!p->palette_count))break;
            started=true;bool valid=true;
            while(length&&valid){
                unsigned n=length>sizeof(p->input)?sizeof(p->input):length;if(!exact(read,context,p->input,n)){valid=false;break;}crc=crc32(crc,p->input,n);length-=n;size_t offset=0;
                bool drain=false;while(offset<n||drain){
                    size_t in=n-offset,out=32768-p->dictionary_position;
                    tinfl_status result=tinfl_decompress(&p->decoder,p->input+offset,&in,p->dictionary,p->dictionary+p->dictionary_position,&out,TINFL_FLAG_PARSE_ZLIB_HEADER|TINFL_FLAG_HAS_MORE_INPUT);
                    if(!in&&!out&&result==TINFL_STATUS_NEEDS_MORE_INPUT&&offset==n){drain=false;break;}
                    if(result<0||(!in&&!out)||!scanline(p,p->dictionary+p->dictionary_position,out)){valid=false;break;}
                    offset+=in;p->dictionary_position=(p->dictionary_position+out)%32768;
                    drain=result==TINFL_STATUS_HAS_MORE_OUTPUT;
                    if(result==TINFL_STATUS_DONE){finished=true;if(offset!=n||length)valid=false;break;}
                }
            }if(!valid)break;
        }else if(!strcmp(type,"IEND")){
            if(length||!finished||p->rows!=p->height||p->row_used||p->out_row!=p->out_height)break;
            ended=true;
        }else {
            if(!(type[0]&32))break; // Reject unsupported critical chunks; ancillary animation data is ignored.
            bool valid=true;while(length){unsigned n=length>sizeof(p->input)?sizeof(p->input):length;if(!exact(read,context,p->input,n)){valid=false;break;}crc=crc32(crc,p->input,n);length-=n;}if(!valid)break;
        }
        if(!exact(read,context,head,4)||be32(head)!=(crc^UINT32_MAX))break;
        if(ended){ok=true;*width=p->out_width;*height=p->out_height;}
    }
    free(p->previous);free(p->row);memset(&p->decoder,0,sizeof(p->decoder));free(p);return ok;
}
