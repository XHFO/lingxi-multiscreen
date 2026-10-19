#if C6_FORMLABS_ONLY
// The dedicated profile only: real RGB565 renderers, never screenshot overlays.
enum { T_BG=0x000000,T_ORANGE=0xff5500,T_WHITE=0xffffff,T_MUTED=0x999999,T_LINE=0x333333 };
#ifdef C6_RENDER_LAYOUT_TEST
#define T_LAYOUT_GROUP(value) c6_layout_test_group(value)
#else
#define T_LAYOUT_GROUP(value) ((void)0)
#endif
// Restricted to weather temperature and printer percentage. All captions,
// menu values, seconds, dates and units retain the existing utility face.
static int terminal_number_width(c6_renderer_t *r,const char *s,unsigned size){
    if(terminal_use_smooth(r)||C6_TERMINAL_AERO_DIGITS==1){
    int width=0;while(*s){unsigned code=next_code(&s);width+=terminal_hero_code(code,size)?(int)terminal_hero_scale(size)*16:code_advance(code,size);}return width;
    }
    return c6_renderer_text_width(s,size);
}
static void terminal_number(c6_renderer_t *r,const char *s,int x,int baseline,unsigned size,int width,uint32_t ink){
    if(terminal_use_smooth(r)||C6_TERMINAL_AERO_DIGITS==1){
    int start=x;while(*s){const char *first=s;unsigned code=next_code(&s);bool aero=terminal_hero_code(code,size);unsigned scale=terminal_hero_scale(size);int advance=aero?(int)scale*16:code_advance(code,size);if(x+advance>start+width)break;
        if(aero){int top=baseline-(int)scale*20;
            if(terminal_use_smooth(r)){
            unsigned w=14*scale,h=20*scale;
            for(unsigned y=0;y<h;y++)for(unsigned xx=0;xx<w;xx++){
                int sx=(int)((xx*256+128)*42/w)-128,sy=(int)((y*256+128)*60/h)-128;
                unsigned alpha=terminal_smooth_alpha(code-'0',sx,sy);
                terminal_smooth_blend(r,x+(int)xx,top+(int)y,ink,alpha);
            }
            }
#if C6_TERMINAL_AERO_DIGITS == 1
            else{
            for(unsigned y=0;y<20;y++)for(unsigned xx=0;xx<14;xx++)if(terminal_aero_digits[code-'0'][y]&(0x2000>>xx))for(unsigned dy=0;dy<scale;dy++)for(unsigned dx=0;dx<scale;dx++)pixel(r,x+xx*scale+dx,top+y*scale+dy,color24(ink));
            }
#endif
        }
        else{char glyph[8];size_t bytes=s-first;if(bytes>7)bytes=7;memcpy(glyph,first,bytes);glyph[bytes]=0;text_weight(r,glyph,x,baseline,size,advance,ink,true);}x+=advance;
    }
    }else text_weight(r,s,x,baseline,size,width,ink,true);
}
static int terminal_width(const char *s,unsigned size){return c6_renderer_text_width(s,size);}
static void terminal_text(c6_renderer_t *r,const char *s,int x,int baseline,unsigned size,int width,uint32_t ink){
    int start=x;while(s&&*s){const char *first=s;unsigned code=next_code(&s);int advance=code_advance(code,size);if(x+advance>start+width)break;
        char glyph[8];size_t bytes=s-first;if(bytes>7)bytes=7;memcpy(glyph,first,bytes);glyph[bytes]=0;
        int natural=code_advance(code,size);
        text_weight(r,glyph,x+(advance-natural)/2,baseline,size,natural+2,ink,true);x+=advance;
    }
}
static void terminal_center(c6_renderer_t *r,const char *s,int baseline,unsigned size,uint32_t ink){while(size>12&&terminal_width(s,size)>208)size--;terminal_text(r,s,(240-terminal_width(s,size))/2,baseline,size,208,ink);}
static void terminal_base(c6_renderer_t *r){fill(r,T_BG);stroke_rect(r,4,4,232,232,0,T_LINE);}
static void terminal_rule(c6_renderer_t *r,int y){rect(r,16,y,208,1,0,T_LINE);}
static void terminal_heading(c6_renderer_t *r,const char *label){terminal_base(r);rect(r,16,16,4,16,0,T_ORANGE);terminal_text(r,label,28,30,14,196,T_WHITE);terminal_rule(r,43);}
static bool terminal_setup_qr(c6_renderer_t *r,const char *payload,const char *title,const char *address,const char *footer){
    // Same utility face, orange marker, square frame and rules as the clock.
    // Only the scan target is black/white: never tint, smooth or animate a QR.
    static uint8_t qr[qrcodegen_BUFFER_LEN_FOR_VERSION(4)],scratch[qrcodegen_BUFFER_LEN_FOR_VERSION(4)];
    bool lan=strncmp(payload,"WIFI:",5)&&strcmp(payload,"http://192.168.4.1/");
    terminal_base(r);rect(r,16,16,4,16,0,T_ORANGE);
    label_lines(r,title,28,12,18,14,152,1,false,T_WHITE,true);
    terminal_text(r,lan?"02/02":"01/02",190,28,10,30,T_ORANGE);terminal_rule(r,43);
    bool encoded=qrcodegen_encodeText(payload,scratch,qr,qrcodegen_Ecc_MEDIUM,1,4,qrcodegen_Mask_AUTO,true);
    if(encoded){
        int size=qrcodegen_getSize(qr),scale=140/(size+8),edge=(size+8)*scale,x=(240-edge)/2,y=48+(140-edge)/2;
        rect(r,x,y,edge,edge,0,T_WHITE);
        for(int yy=0;yy<size;yy++)for(int xx=0;xx<size;xx++)if(qrcodegen_getModule(qr,xx,yy))rect(r,x+(xx+4)*scale,y+(yy+4)*scale,scale,scale,0,T_BG);
    }else label_lines(r,c6_renderer_localized(r,"无法生成二维码"),16,100,18,14,208,2,true,T_WHITE,true);
    label_lines(r,address,16,192,14,10,208,1,true,T_ORANGE,false);
    terminal_rule(r,213);label_lines(r,footer,16,216,r->english?10:12,r->english?10:12,208,1,true,T_MUTED,false);
    return encoded;
}
static void terminal_clock(c6_renderer_t *r,const c6_render_clock_t *t){
    terminal_heading(r,r->english?"FLIP CLOCK":"桌面时钟");char digits[5];snprintf(digits,sizeof(digits),"%02d%02d",t->hour,t->minute);
    for(unsigned i=0;i<4;i++){int x=c6_flip_card_x(i);rect(r,x,72,46,86,7,0x555555);rect(r,x+1,73,44,84,6,0x111111);rect(r,x+1,115,44,42,5,0x0a0a0a);
        clock_digit(r,digits[i],x,85,0,30,0,30,T_WHITE);clock_digit(r,digits[i],x,85,30,30,30,30,T_WHITE);
        rect(r,x+1,114,44,2,0,T_BG);rect(r,x,111,3,8,0,0x555555);rect(r,x+43,111,3,8,0,0x555555);}
    dot(r,120,102,2,T_WHITE);dot(r,120,128,2,T_WHITE);char line[48];snprintf(line,sizeof(line),"%02d",t->second);terminal_center(r,line,183,24,T_ORANGE);terminal_rule(r,198);
    const char *days_en[]={"SUN","MON","TUE","WED","THU","FRI","SAT"},*days_zh[]={"周日","周一","周二","周三","周四","周五","周六"};const char **days=r->english?days_en:days_zh;int day=t->weekday<0||t->weekday>6?0:t->weekday;
    snprintf(line,sizeof(line),"%04d.%02d.%02d %s",t->year,t->month,t->day,days[day]);terminal_center(r,line,221,13,T_MUTED);
}
static void terminal_menu(c6_renderer_t *r,const char *title,const c6_render_menu_row_t *rows,unsigned count,unsigned selected,const char *footer){
    terminal_base(r);label_lines(r,title,16,12,18,14,count>3?164:208,1,false,T_WHITE,true);terminal_rule(r,43);
    bool selectable=selected<count;unsigned first=selectable?(selected/3)*3:0;
    if(count>3){char page[32];snprintf(page,sizeof(page),"%u/%u",first/3+1,(count+2)/3);terminal_text(r,page,190,29,12,34,T_MUTED);}
    for(unsigned i=first;i<count&&i<first+3;i++){int y=55+(i-first)*48;bool chosen=selectable&&i==selected;uint32_t ink=chosen?T_ORANGE:T_MUTED;
        // The prior 20px glyph advanced 18px into a 14px box and was clipped
        // entirely. Draw the arrow directly so it survives either language.
        if(chosen)for(int step=0;step<7;step++){rect(r,16+step,y+9+step,3,3,0,T_ORANGE);rect(r,16+step,y+21-step,3,3,0,T_ORANGE);}
        label_lines(r,rows[i].label,36,y,17,14,184,1,false,ink,true);
        if(rows[i].value&&*rows[i].value)label_lines(r,rows[i].value,36,y+22,r->english?10:13,r->english?10:12,184,1,false,chosen?T_WHITE:T_MUTED,false);
    }
    terminal_rule(r,206);label_lines(r,c6_renderer_localized(r,footer?footer:"单击切换 · 双击确认"),16,212,r->english?10:12,r->english?10:12,208,r->english?2:1,true,T_MUTED,false);
}
static const char *terminal_condition(int code){c6_weather_kind_t kind=c6_weather_style(code).kind;switch(kind){
    case C6_WEATHER_CLEAR:return "SUNNY";case C6_WEATHER_CLOUDY:return "CLOUDY";case C6_WEATHER_OVERCAST:return "OVERCAST";case C6_WEATHER_FOG:return "FOG";
    case C6_WEATHER_DRIZZLE:return "DRIZZLE";case C6_WEATHER_RAIN:return "RAIN";case C6_WEATHER_SNOW:return "SNOW";case C6_WEATHER_THUNDER:return "THUNDER";default:return "WEATHER";}}
static void terminal_weather(c6_renderer_t *r,const c6_render_weather_t *p){
    terminal_base(r);const char *condition=terminal_condition(p->valid?p->code:-1);
    const char *en[]={"SUNNY","CLOUDY","OVERCAST","FOG","DRIZZLE","RAIN","SNOW","THUNDER","WEATHER"};
    const char *zh[]={"晴","多云","阴","雾","小雨","雨","雪","雷雨","天气"};
    if(!r->english)for(unsigned i=0;i<9;i++)if(!strcmp(condition,en[i])){condition=zh[i];break;}
    terminal_text(r,condition,43,30,14,181,T_WHITE);
    c6_weather_kind_t kind=c6_weather_style(p->valid?p->code:-1).kind;
    if(kind==C6_WEATHER_CLEAR||kind==C6_WEATHER_CLOUDY){dot(r,26,23,6,T_ORANGE);for(unsigned i=0;i<8;i++){double a=i*0.78539816339;icon_line(r,26+(int)(10*cos(a)),23+(int)(10*sin(a)),26+(int)(13*cos(a)),23+(int)(13*sin(a)),T_ORANGE);}}
    else{rect(r,15,20,22,10,4,T_ORANGE);dot(r,25,19,6,T_ORANGE);if(c6_weather_wet(kind))icon_line(r,25,33,22,39,T_ORANGE);}
    terminal_rule(r,47);
    if(!p->valid){label_lines(r,c6_renderer_localized(r,"等待天气更新"),16,98,20,16,208,2,true,T_WHITE,true);label_lines(r,c6_renderer_localized(r,"在网页配置城市与位置"),16,148,14,12,208,1,true,T_MUTED,false);}
    else{
        char number[16];snprintf(number,sizeof(number),"%.0f",p->temperature);int number_width=terminal_number_width(r,number,64),unit_width=c6_renderer_text_width("°C",27),x=(240-number_width-unit_width-6)/2;
        terminal_number(r,number,x,137,64,160,T_WHITE);text_weight(r,"°C",x+number_width+6,108,27,60,T_WHITE,true);
        char left[32],right[32];if(p->humidity_valid)snprintf(left,sizeof(left),"%d%%",p->humidity);else snprintf(left,sizeof(left),"%.0f°C",p->low);
        if(p->wind_valid)snprintf(right,sizeof(right),"%.1fm/s",p->wind);else snprintf(right,sizeof(right),"%.0f°C",p->high);
        terminal_text(r,p->humidity_valid?(r->english?"HUM":"湿度"):(r->english?"LOW":"最低"),16,162,r->english?10:12,96,T_MUTED);terminal_text(r,p->wind_valid?(r->english?"WIND":"风速"):(r->english?"HIGH":"最高"),125,162,r->english?10:12,100,T_MUTED);
        terminal_text(r,left,16,184,14,96,T_WHITE);rect(r,115,153,1,34,0,T_LINE);terminal_text(r,right,125,184,12,100,T_WHITE);
        if(p->stale)terminal_center(r,c6_renderer_localized(r,"缓存"),198,12,T_MUTED);
    }
    terminal_rule(r,202);label_lines(r,p->city?p->city:c6_renderer_localized(r,"未设定城市"),16,208,14,12,208,1,false,T_MUTED,true);
}
static void terminal_printer_rest_icon(c6_renderer_t *r,int top,int bottom){
    // Geometry, not Unicode: no missing-glyph boxes, font dependency, bitmap
    // buffer, animation or change to the printer's actual power state.
    int edge=bottom-top;if(edge>72)edge=72;if(edge<24)edge=24;
    int x=(240-edge)/2,y=top+(bottom-top-edge)/2;
    for(int yy=0;yy<edge;yy++)for(int xx=0;xx<edge;xx++){
        int px=xx*64/edge,py=yy*64/edge;
        int dx=px-27,dy=py-35,cx=px-39,cy=py-25;
        if(dx*dx+dy*dy<=24*24&&cx*cx+cy*cy>23*23)pixel(r,x+xx,y+yy,color24(T_WHITE));
        // A bold Z in the upper-right, balanced with the moon.
        if(px>=44&&px<=59&&py>=3&&py<=19&&
           (py<=5||py>=17||abs((px-44)+(py-3)-15)<=2))pixel(r,x+xx,y+yy,color24(T_ORANGE));
    }
}
typedef enum { T_PRINT_ACTIVE,T_PRINT_IDLE,T_PRINT_OFFLINE,T_PRINT_ERROR,T_PRINT_PAUSED,T_PRINT_COMPLETE,T_PRINT_CANCELLED } terminal_print_state_t;
static terminal_print_state_t terminal_printer_state(const c6_render_printer_t *p){
    if(!p->connected)return T_PRINT_OFFLINE;
    const char *s=p->status?p->status:"";
    if(p->is_error||same_ascii(s,"failed")||same_ascii(s,"error"))return T_PRINT_ERROR;
    if(same_ascii(s,"idle")||same_ascii(s,"standby"))return T_PRINT_IDLE;
    if(same_ascii(s,"paused")||same_ascii(s,"pause"))return T_PRINT_PAUSED;
    if(same_ascii(s,"cancelled")||same_ascii(s,"canceled")||same_ascii(s,"aborted"))return T_PRINT_CANCELLED;
    if(p->completed||same_ascii(s,"finished")||same_ascii(s,"complete")||same_ascii(s,"completed")||same_ascii(s,"finish"))return T_PRINT_COMPLETE;
    return T_PRINT_ACTIVE;
}
static void terminal_printer_state_icon(c6_renderer_t *r,terminal_print_state_t state,int top,int bottom){
    // A ready printer, not a sleeping/powered-off device. Integer geometry
    // shares the utility font's weight and needs no extra bitmap or buffer.
    int edge=bottom-top-26;if(edge>72)edge=72;if(edge<24)edge=24;
    int x=(240-edge)/2,y=top+(bottom-top-edge-24)/2;
    for(int yy=0;yy<edge;yy++)for(int xx=0;xx<edge;xx++){
        int px=xx*24/edge,py=yy*24/edge;uint32_t ink=T_BG;
        if(state==T_PRINT_IDLE){
            if((px>=3&&px<=20&&(py==3||py==20))||(py>=3&&py<=20&&(px==3||px==20))||
               (px>=6&&px<=17&&py==7)||(px==12&&py>=7&&py<=12))ink=T_WHITE;
            if(px>=6&&px<=17&&py>=16&&py<=17)ink=T_ORANGE;
            if(px>=17&&px<=18&&py>=5&&py<=6)ink=T_ORANGE;
        }else if(state==T_PRINT_PAUSED){
            if(py>=4&&py<=19&&((px>=6&&px<=9)||(px>=14&&px<=17)))ink=T_ORANGE;
        }else if(state==T_PRINT_COMPLETE){
            if((px>=4&&px<=10&&abs(py-px-5)<=1)||(px>=10&&px<=21&&abs(py+px-25)<=1))ink=T_WHITE;
        }else if(state==T_PRINT_ERROR){
            if((py>=4&&py<=14&&px>=11&&px<=13)||(py>=18&&py<=20&&px>=11&&px<=13))ink=T_ORANGE;
            if((py>=3&&py<=21&&abs(abs(px-12)*2-(py-3))<=1)||(py==21&&px>=3&&px<=21))ink=T_WHITE;
        }else{
            if((px>=4&&px<=19&&(py==4||py==19))||(py>=4&&py<=19&&(px==4||px==19)))ink=T_MUTED;
            if(px>=6&&px<=17&&(abs(px-py)<=1||abs(px+py-23)<=1))ink=T_ORANGE;
        }
        if(ink)pixel(r,x+xx,y+yy,color24(ink));
    }
    const char *label=state==T_PRINT_IDLE?(r->english?"READY TO PRINT":"空闲中 · 等待新任务"):
        state==T_PRINT_OFFLINE?(r->english?"CHECK CONNECTION":"离线 · 检查网络连接"):
        state==T_PRINT_PAUSED?(r->english?"PRINT PAUSED":"打印已暂停"):
        state==T_PRINT_COMPLETE?(r->english?"PRINT COMPLETE":"打印已完成"):
        state==T_PRINT_CANCELLED?(r->english?"PRINT CANCELLED":"打印已取消"):(r->english?"PRINT ERROR":"打印出现错误");
    label_lines(r,label,16,y+edge+8,12,12,208,1,true,T_MUTED,true);
}
typedef struct {const char *text[4];uint32_t ink[4];unsigned count;int top;char timing[40],progress[32];} terminal_printer_details_t;
static void terminal_printer_details(c6_renderer_t *r,const c6_render_printer_t *p,terminal_print_state_t state,terminal_printer_details_t *d){
    memset(d,0,sizeof(*d));
    if(p->show_error&&p->is_error&&present(p->error)){d->text[d->count]=p->error;d->ink[d->count++]=T_ORANGE;}
    bool live=state!=T_PRINT_IDLE&&state!=T_PRINT_OFFLINE;
    if(live&&p->card_style==2){
        if(p->show_progress&&p->progress_available)snprintf(d->progress,sizeof(d->progress),r->english?"PROGRESS %d%%":"打印进度 %d%%",p->progress<0?0:p->progress>100?100:p->progress);
        if(*d->progress){d->text[d->count]=d->progress;d->ink[d->count++]=T_MUTED;}
    }else if(live&&p->show_remaining){
        const char *timing=p->time_text;
        if(!timing&&p->remaining_available){snprintf(d->timing,sizeof(d->timing),r->english?"ETA %dm":"剩余 %d分钟",p->remaining);timing=d->timing;}
        if(present(timing)){d->text[d->count]=timing;d->ink[d->count++]=T_MUTED;}
    }
    if(live&&present(p->layers)){d->text[d->count]=p->layers;d->ink[d->count++]=T_MUTED;}
    if(state!=T_PRINT_OFFLINE&&present(p->material)){d->text[d->count]=p->material;d->ink[d->count++]=T_MUTED;}
    d->top=228-(int)d->count*18;
}
static void terminal_printer_footer(c6_renderer_t *r,const terminal_printer_details_t *d){
    if(!d->count)return;
    T_LAYOUT_GROUP(12);terminal_rule(r,d->top-5);
    for(unsigned i=0;i<d->count;i++){T_LAYOUT_GROUP(8+i);label_lines(r,d->text[i],16,d->top+(int)i*18,13,12,208,1,true,d->ink[i],i==0);}
}
static void terminal_printer_bar(c6_renderer_t *r,int top,int percent){
    T_LAYOUT_GROUP(7);rect(r,16,top,208,5,0,0x222222);
    if(percent)rect(r,16,top,208*percent/100,5,0,T_ORANGE);
    stroke_rect(r,16,top,208,5,0,0x666666);
}
static void terminal_printer_hero(c6_renderer_t *r,const c6_render_printer_t *p,int cursor,const terminal_printer_details_t *d,terminal_print_state_t state){
    bool time_primary=p->card_style==2;
    int percent=p->progress<0?0:p->progress>100?100:p->progress;
    char number[32];int top=d->count?d->top:226;
    const char *unit="";bool numeric=true,resting=false;
    if(time_primary){
        if(state==T_PRINT_COMPLETE){snprintf(number,sizeof(number),"%s",r->english?"COMPLETE":"已完成");numeric=false;}
        else if(!p->remaining_available){number[0]=0;numeric=false;resting=true;}
        else{unsigned minutes=(unsigned)(((uint64_t)p->remaining_seconds+59)/60);
            if(minutes>=60){snprintf(number,sizeof(number),"%02u:%02u",minutes/60,minutes%60);unit=r->english?"HOURS : MINUTES":"小时 : 分钟";}
            else{snprintf(number,sizeof(number),"%u",minutes);unit=r->english?"MINUTES REMAINING":"剩余分钟";}}
    }else if(p->progress_available){snprintf(number,sizeof(number),"%d",percent);unit="%";}
    else{number[0]=0;numeric=false;resting=true;}
    int limit=top-(time_primary&&*unit?38:22)-cursor;unsigned size=limit>96?96:limit<24?24:(unsigned)limit;
    if(!numeric&&size>40)size=40;
    int width,unit_width;
    do{width=numeric?terminal_number_width(r,number,size):terminal_width(number,size);unit_width=!time_primary&&*unit?terminal_width(unit,size/2)+6:0;
        if(width+unit_width<=208||size<=18)break;
        size--;
    }while(true);
    int baseline=cursor+(limit+(int)size)/2;
    T_LAYOUT_GROUP(5);
    if(resting&&(state==T_PRINT_ERROR||state==T_PRINT_PAUSED||state==T_PRINT_CANCELLED||state==T_PRINT_COMPLETE))terminal_printer_state_icon(r,state,cursor,top-18);
    else if(resting)terminal_printer_rest_icon(r,cursor,top-22);
    else if(numeric)terminal_number(r,number,(240-width-unit_width)/2,baseline,size,208,T_WHITE);
    else terminal_text(r,number,(240-width)/2,baseline,size,208,T_WHITE);
    if(!time_primary&&*unit)terminal_text(r,unit,(240-width-unit_width)/2+width+6,baseline,size/2,48,T_WHITE);
    if(time_primary&&*unit)terminal_center(r,unit,baseline+20,r->english?10:12,T_MUTED);
    if(p->progress_available&&(p->show_progress||!time_primary)){
        terminal_printer_bar(r,top-14,percent);
    }
    terminal_printer_footer(r,d);
}
static void terminal_printer(c6_renderer_t *r,const c6_render_printer_t *p){
    T_LAYOUT_GROUP(0);terminal_base(r);rect(r,16,16,4,16,0,T_ORANGE);
    T_LAYOUT_GROUP(1);
    label_lines(r,present(p->name)?p->name:"Formlabs",28,13,16,12,p->show_status?112:192,1,false,T_WHITE,true);
    if(p->show_status){T_LAYOUT_GROUP(2);dot(r,156,24,3,p->connected?T_ORANGE:T_MUTED);label_lines(r,c6_renderer_localized(r,p->connected?c6_renderer_print_status(p->status):"离线"),166,15,r->english?10:12,r->english?10:11,58,1,false,T_MUTED,true);}
    T_LAYOUT_GROUP(0);terminal_rule(r,43);int cursor=52;
    terminal_print_state_t state=terminal_printer_state(p);terminal_printer_details_t d;terminal_printer_details(r,p,state,&d);
    if(p->demo){T_LAYOUT_GROUP(3);terminal_text(r,"DEMO / FIXED",16,cursor+10,10,208,T_ORANGE);cursor+=16;}
    if(state==T_PRINT_IDLE||state==T_PRINT_OFFLINE){T_LAYOUT_GROUP(5);terminal_printer_state_icon(r,state,cursor,d.top-12);terminal_printer_footer(r,&d);T_LAYOUT_GROUP(0);return;}
    if(p->show_task&&present(p->task)){T_LAYOUT_GROUP(4);unsigned lines=p->card_style||d.top-cursor<148?1:2;
        unsigned used=label_lines(r,p->task,16,cursor,14,12,208,lines,false,T_MUTED,true);cursor+=used*18+6;}
    if(p->card_style==1||p->card_style==2){terminal_printer_hero(r,p,cursor,&d,state);T_LAYOUT_GROUP(0);return;}
    bool image=p->show_image;int top=d.top,body_bottom=top-(p->show_progress?24:12);
    if(p->show_progress){int percent=p->progress<0?0:p->progress>100?100:p->progress;char number[16];snprintf(number,sizeof(number),"%d",percent);unsigned size=image?38:d.count?48:56;
        while(size>18&&((int)size>body_bottom-cursor||terminal_number_width(r,number,size)+c6_renderer_text_width("%",size/2)+4>(image?126:208)))size--;
        int w=terminal_number_width(r,number,size),unit=c6_renderer_text_width("%",size/2),x=image?16:(240-w-unit-4)/2;int baseline=cursor+(int)size;T_LAYOUT_GROUP(5);
        terminal_number(r,number,x,baseline,size,180,T_WHITE);text_weight(r,"%",x+w+4,baseline,size/2,48,T_WHITE,true);
        if(image){int edge=body_bottom-cursor;if(edge>68)edge=68;T_LAYOUT_GROUP(6);c6_render_picture_t legacy={p->thumbnail_rgb565,p->thumbnail_width,p->thumbnail_height,p->thumbnail_stride};c6_render_style_t c={.enabled=true,.background=T_BG,.inset=T_BG,.border=T_LINE,.primary_text=T_WHITE,.secondary_text=T_MUTED};
            if(edge>=24)picture_box(r,valid_picture(&p->cover)?&p->cover:&legacy,224-edge,cursor,edge,edge,2,false,false,NULL,&c);
            image=false;
        }
        terminal_printer_bar(r,top-14,percent);
    }
    if(image&&body_bottom-cursor>=24){T_LAYOUT_GROUP(6);c6_render_picture_t legacy={p->thumbnail_rgb565,p->thumbnail_width,p->thumbnail_height,p->thumbnail_stride};c6_render_style_t c={.enabled=true,.background=T_BG,.inset=T_BG,.border=T_LINE,.primary_text=T_WHITE,.secondary_text=T_MUTED};
        picture_box(r,valid_picture(&p->cover)?&p->cover:&legacy,16,cursor,208,body_bottom-cursor,2,false,false,NULL,&c);}
    if(!p->show_progress&&(!image||body_bottom-cursor<24)){T_LAYOUT_GROUP(5);
        if(state==T_PRINT_ERROR||state==T_PRINT_PAUSED||state==T_PRINT_COMPLETE||state==T_PRINT_CANCELLED)terminal_printer_state_icon(r,state,cursor,body_bottom);
        else terminal_printer_rest_icon(r,cursor,body_bottom);
    }
    terminal_printer_footer(r,&d);T_LAYOUT_GROUP(0);
}
void c6_renderer_printer_overview(c6_renderer_t *r,const c6_render_printer_summary_t *rows,unsigned count){
    T_LAYOUT_GROUP(0);
    terminal_heading(r,c6_renderer_localized(r,"打印机总览"));
    if(!rows)return;
    if(count>3)count=3;
    int height=count>2?56:82;
    for(unsigned i=0;i<count;i++){
        const c6_render_printer_summary_t *p=&rows[i];int top=54+(int)i*height;
        T_LAYOUT_GROUP(2+i*6);
        label_lines(r,present(p->name)?p->name:"Formlabs",16,top,count>2?16:18,14,p->demo?156:208,1,false,T_WHITE,true);
        if(p->demo){T_LAYOUT_GROUP(3+i*6);terminal_text(r,"DEMO",183,top+12,12,41,T_ORANGE);}
        const char *status=!p->enabled?"已禁用":!p->connected?"离线":c6_renderer_print_status(p->status);
        int status_top=top+(count>2?20:28),bar_top=top+(count>2?43:58);
        T_LAYOUT_GROUP(4+i*6);
        dot(r,19,status_top+6,3,p->enabled&&p->connected?T_ORANGE:T_MUTED);
        label_lines(r,c6_renderer_localized(r,status),28,status_top,14,12,196,1,false,T_MUTED,true);
        bool available=p->enabled&&p->progress_available;int progress=p->progress<0?0:p->progress>100?100:p->progress;
        T_LAYOUT_GROUP(5+i*6);
        rect(r,16,bar_top,146,5,0,0x222222);
        if(available&&progress)rect(r,16,bar_top,146*progress/100,5,0,T_ORANGE);
        stroke_rect(r,16,bar_top,146,5,0,0x666666);
        char value[12];if(available)snprintf(value,sizeof(value),"%d%%",progress);else snprintf(value,sizeof(value),"--%%");
        unsigned size=14;int width=terminal_width(value,size);
        T_LAYOUT_GROUP(6+i*6);
        terminal_text(r,value,224-width,bar_top+7,size,54,available?T_WHITE:T_MUTED);
        if(i+1<count){T_LAYOUT_GROUP(7+i*6);terminal_rule(r,top+height-4);}
    }
    T_LAYOUT_GROUP(0);
}
#endif
