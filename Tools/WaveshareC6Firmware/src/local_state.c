#include "local_state.h"
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <math.h>
#include <inttypes.h>
#include <stdlib.h>
uint64_t c6_parse_end_epoch(const char *text){
    if(!text||!*text)return 0;
    char *end;unsigned long long raw=strtoull(text,&end,10);
    if(end!=text&&!*end)return raw>0&&raw<=4102444800ULL?raw:0;
    int y,m,d,h,n,s,used=0;if(sscanf(text,"%d-%d-%dT%d:%d:%d%n",&y,&m,&d,&h,&n,&s,&used)!=6||y<1970||y>2100||m<1||m>12||h<0||h>23||n<0||n>59||s<0||s>59)return 0;
    bool leap=y%4==0&&(y%100!=0||y%400==0);const int lengths[]={31,28,31,30,31,30,31,31,30,31,30,31};int limit=lengths[m-1]+(m==2&&leap);if(d<1||d>limit)return 0;
    const char *tail=text+used;if(*tail=='.'){tail++;if(*tail<'0'||*tail>'9')return 0;while(*tail>='0'&&*tail<='9')tail++;}
    int offset=0;if(*tail=='Z'&&!tail[1]){}else if(*tail=='+'||*tail=='-'){int oh,on,read=0;if(sscanf(tail+1,"%d:%d%n",&oh,&on,&read)!=2||tail[1+read]||oh<0||oh>14||on<0||on>59||(oh==14&&on))return 0;offset=(oh*3600+on*60)*(*tail=='-'?-1:1);}else return 0;
    int days=0;for(int year=1970;year<y;year++)days+=365+(year%4==0&&(year%100!=0||year%400==0));for(int month=1;month<m;month++)days+=lengths[month-1]+(month==2&&leap);
    int64_t epoch=(int64_t)(days+d-1)*86400+h*3600+n*60+s-offset;return epoch>0?(uint64_t)epoch:0;
}
static void numeric_text(cJSON *j,const char *key,char *out,size_t size){
    cJSON *v=cJSON_GetObjectItemCaseSensitive(j,key);if(!v)return;
    if(cJSON_IsNumber(v)&&isfinite(v->valuedouble))snprintf(out,size,"%.0f",v->valuedouble);
    else if(cJSON_IsString(v)&&strcmp(v->valuestring,"unknown")&&strcmp(v->valuestring,"unavailable"))snprintf(out,size,"%s",v->valuestring);else *out=0;
}
void c6_task_key(const char *source,const char *value,char out[17]) {
    out[0]=0;if(!source||!value||!*value||!strcmp(value,"unknown")||!strcmp(value,"unavailable"))return;
    uint64_t hash=UINT64_C(14695981039346656037);
    for(const unsigned char *p=(const unsigned char*)source;*p;p++){hash^=*p;hash*=UINT64_C(1099511628211);}
    hash^=':';hash*=UINT64_C(1099511628211);
    for(const unsigned char *p=(const unsigned char*)value;*p;p++){hash^=*p;hash*=UINT64_C(1099511628211);}
    snprintf(out,17,"%016" PRIx64,hash);
}
static unsigned mqtt_key_rank(cJSON *j,char out[17]) {
    const char *fields[]={"subtask_id","task_id","gcode_file","subtask_name"};out[0]=0;
    for(unsigned i=0;i<4;i++) {
        cJSON *v=cJSON_GetObjectItemCaseSensitive(j,fields[i]);char number[32];const char *text=NULL;
        if(cJSON_IsString(v))text=v->valuestring;
        else if(cJSON_IsNumber(v)&&isfinite(v->valuedouble)&&floor(v->valuedouble)==v->valuedouble){snprintf(number,sizeof(number),"%.0f",v->valuedouble);text=number;}
        if(text&&*text&&(i>=2||strcmp(text,"0"))){c6_task_key(fields[i],text,out);if(*out)return i+1;}
    }
    return 0;
}
void c6_mqtt_task_key(cJSON *j,char out[17]){mqtt_key_rank(j,out);}
bool c6_private_ip(const char *text) {
    unsigned a,b,c,d; int end=0;
    if(!text || sscanf(text,"%u.%u.%u.%u%n",&a,&b,&c,&d,&end)!=4 || text[end] || a>255||b>255||c>255||d>255)return false;
    return a==10||(a==192&&b==168)||(a==172&&b>=16&&b<=31);
}
bool c6_print_active(const char *s) {
    return !strcasecmp(s,"RUNNING")||!strcasecmp(s,"PRINTING")||!strcasecmp(s,"PAUSE")||!strcasecmp(s,"PAUSED")||!strcasecmp(s,"PREPARE")||!strcasecmp(s,"PREPARING")||!strcasecmp(s,"SLICING")||!strcasecmp(s,"HEATING")||!strcasecmp(s,"PREPRINT")||!strcasecmp(s,"PRE_PRINT")||!strcasecmp(s,"POSTPRINT")||!strcasecmp(s,"POST_PRINT");
}
bool c6_print_finished(const char *s) { return !strcasecmp(s,"FINISH")||!strcasecmp(s,"FINISHED")||!strcasecmp(s,"COMPLETED")||!strcasecmp(s,"COMPLETE"); }
static void copy(cJSON *j,const char *key,char *out,size_t size) {
    cJSON *v=cJSON_GetObjectItemCaseSensitive(j,key);
    if(cJSON_IsString(v))snprintf(out,size,"%s",v->valuestring);
}
void c6_print_update(c6_printer_state_t *s,cJSON *j,uint64_t now) {
    if(!cJSON_IsObject(j))return;
    bool was_finished=c6_print_finished(s->status),was_active=c6_print_active(s->status);
    char old_job[80];snprintf(old_job,sizeof(old_job),"%s",s->job);
    char next_key[17];unsigned next_rank=mqtt_key_rank(j,next_key);
    cJSON *ha_key=cJSON_GetObjectItemCaseSensitive(j,"thumbnail_key");
    if(cJSON_IsString(ha_key)) {
        if(strlen(ha_key->valuestring)==16){snprintf(next_key,sizeof(next_key),"%s",ha_key->valuestring);next_rank=1;}
        else {next_key[0]=0;s->thumbnail_key[0]=0;s->thumbnail_key_rank=0;}
    }
    copy(j,"task_id",s->job,sizeof(s->job));
    bool new_job=*s->job&&*old_job&&strcmp(old_job,s->job);
    if(*next_key&&(new_job||!s->thumbnail_key_rank||next_rank<=s->thumbnail_key_rank)){snprintf(s->thumbnail_key,sizeof(s->thumbnail_key),"%s",next_key);s->thumbnail_key_rank=next_rank;}
    if(new_job){s->progress=0;s->remaining=0;s->progress_valid=s->remaining_valid=false;s->end_epoch=0;s->error[0]=0;if(was_finished&&!cJSON_HasObjectItem(j,"gcode_state"))snprintf(s->status,sizeof(s->status),"PREPARE");}
    copy(j,"subtask_name",s->task,sizeof(s->task));
    copy(j,"gcode_state",s->status,sizeof(s->status));
    if(c6_print_active(s->status)&&!was_active&&!cJSON_HasObjectItem(j,"mc_percent")){s->progress=0;s->remaining=0;s->progress_valid=s->remaining_valid=false;s->end_epoch=0;}
    cJSON *p=cJSON_GetObjectItemCaseSensitive(j,"mc_percent");
    if(p){s->progress_valid=cJSON_IsNumber(p)&&isfinite(p->valuedouble);if(s->progress_valid)s->progress=p->valueint<0?0:p->valueint>100?100:p->valueint;}
    p=cJSON_GetObjectItemCaseSensitive(j,"mc_remaining_time");
    if(p){s->remaining_valid=cJSON_IsNumber(p)&&isfinite(p->valuedouble)&&p->valuedouble>=0&&p->valuedouble<=525600;if(s->remaining_valid){s->remaining=p->valueint;s->remaining_updated=now;}}
    numeric_text(j,"nozzle_temper",s->nozzle,sizeof(s->nozzle));numeric_text(j,"bed_temper",s->bed,sizeof(s->bed));
    p=cJSON_GetObjectItemCaseSensitive(j,"print_error");if(p){if(cJSON_IsString(p))snprintf(s->error,sizeof(s->error),"%s",p->valuestring);else if(cJSON_IsNumber(p)&&isfinite(p->valuedouble))snprintf(s->error,sizeof(s->error),"%.0f",p->valuedouble);else s->error[0]=0;}
    p=cJSON_GetObjectItemCaseSensitive(j,"end_time");if(p)s->end_epoch=cJSON_IsString(p)?c6_parse_end_epoch(p->valuestring):0;
    if(new_job||c6_print_active(s->status))s->completed_at=0;
    if(c6_print_finished(s->status)&&(!was_finished||new_job)&&!s->completed_at)s->completed_at=now;
    // A printer commonly switches FINISH -> IDLE. Keep the completed job for its original window.
    if(was_active&&!c6_print_finished(s->status)&&!c6_print_active(s->status))s->completed_at=0;
    s->known=*s->status!=0;s->updated=now;
}
bool c6_print_eligible(const c6_printer_state_t *s,uint64_t now) {
    if(!s->known)return false;
    if(!strcasecmp(s->status,"error")||!strcasecmp(s->status,"failed"))return s->connected||(now>=s->updated&&now-s->updated<1800);
    if(c6_print_active(s->status))return s->connected || (now>=s->updated&&now-s->updated<1800);
    return s->completed_at>0&&now>=s->completed_at&&now-s->completed_at<1800;
}
bool c6_software_wins(bool enabled,bool local_first,bool local_available,uint64_t heartbeat,uint64_t now) {
    bool online=heartbeat>0&&now>=heartbeat&&now-heartbeat<30;
    return !enabled||(online&&(!local_first||!local_available));
}
