/* Test-only fixture for the actual v3 structs in Pico's pico_reader_records.inc.
 * Field order/constants follow that Apache-2.0 firmware source; no device code is executed.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <stddef.h>
typedef struct { uint16_t x,y; } ink_t;
typedef struct {
    uint32_t version,offset,end,chapter,file_low,file_high,text_bytes;
    uint8_t book,type,ink_count,reserved;
    char quote[512],path[288],title[96];
    ink_t ink[64];
} object_t;
typedef struct { uint32_t id,bytes; } ref_t;
typedef struct { uint32_t version,count,sequence,next_id; ref_t object[1024]; } index_t;
_Static_assert(sizeof(object_t)==1184,"Pico v3 object ABI");
_Static_assert(offsetof(object_t,ink)==928,"Pico v3 ink offset");
_Static_assert(sizeof(index_t)==8208,"Pico v3 index ABI");
static uint32_t crc32(const unsigned char *p,size_t n){uint32_t c=~0u;for(size_t i=0;i<n;i++){c^=p[i];for(int j=0;j<8;j++)c=(c>>1)^(0xedb88320u&-(c&1u));}return ~c;}
static void save(const char *path,const void *data,size_t n){FILE *f=fopen(path,"wb");if(!f)exit(2);uint32_t h[3]={0x31535058u,(uint32_t)n,crc32(data,n)};if(fwrite(h,1,12,f)!=12||fwrite(data,1,n,f)!=n||fclose(f))exit(3);}
int main(int argc,char **argv){
    if(argc!=2)return 1;char path[2048];mkdir(argv[1],0700);snprintf(path,sizeof(path),"%s/books",argv[1]);mkdir(path,0700);snprintf(path,sizeof(path),"%s/books/.pico-system",argv[1]);mkdir(path,0700);
    index_t index={.version=3,.count=4,.sequence=7,.next_id=9};
    for(unsigned i=0;i<4;i++){
        const char *text=i==1?"读后感：\n这条私人批注不应自动公开。":i==2?"读后感：\n同一选区的第二条批注要保留。":"";
        object_t header={.version=3,.offset=12,.end=42,.chapter=2,.file_low=123456,.text_bytes=(uint32_t)strlen(text)+1,.book=255,.type=i==0?1:i==3?2:0};
        strcpy(header.path,"/sdcard/books/真实图书.epub");strcpy(header.title,"真实图书");if(i!=3)strcpy(header.quote,"从眼前的一页开始，留下真实的阅读记录。");
        size_t bytes=sizeof(header)+strlen(text)+1;unsigned char *object=calloc(1,bytes);memcpy(object,&header,sizeof(header));memcpy(object+sizeof(header),text,strlen(text)+1);
        index.object[i]=(ref_t){i+1,(uint32_t)bytes};snprintf(path,sizeof(path),"%s/books/.pico-system/reader-r3-o-%u.dat",argv[1],i+1);save(path,object,bytes);free(object);
    }
    snprintf(path,sizeof(path),"%s/books/.pico-system/reader-r3-index.dat",argv[1]);save(path,&index,sizeof(index));
    return 0;
}
