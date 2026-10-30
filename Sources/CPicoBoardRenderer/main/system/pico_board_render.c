/*
 * SPDX-License-Identifier: Apache-2.0
 * 中文：设备原生16灰语义卡片排版；相同布局可供桌面原生预览使用。
 * English: Native gray16 semantic cards, with one layout implementation for device and native desktop previews.
 * 冻结：只绘制传入模型；不分配内存、读盘、联网、修改状态或加载交互应用。
 * Frozen: Paint only the supplied model; never allocate, read files, network, mutate state or load an interactive app.
 */
#include "pico_board_data.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#ifndef PICO_BOARD_PORTABLE
#include "pico_system.h"
#include "ttf_font.h"
#include "epdiy.h"
#endif

typedef struct { int x, y, w, h; } rect_t;
typedef struct { const ps_board_painter_t *ops; int ink, muted, border, background, font_shift; } paint_t;
static int min(int a, int b) { return a < b ? a : b; }
static size_t utf8_bytes(unsigned char c) { return c < 128 ? 1 : c < 224 ? 2 : c < 240 ? 3 : 4; }
static int text_width(const paint_t *p, int size, const char *text) {
    return p->ops->measure(p->ops->context, size, text);
}
static void fill(const paint_t *p, rect_t r, int gray) {
    if (r.w > 0 && r.h > 0) p->ops->fill(p->ops->context, r.x, r.y, r.w, r.h, gray);
}
// 中文：以实际字宽断行并在卡片边界内省略，不缩成不可读的小字。
// English: Wrap using measured glyph widths and ellipsize within each card rather than shrinking text.
static int wrapped(const paint_t *p, rect_t r, int size, int lines, const char *text, int gray) {
    size += p->font_shift;
    if(size<15)size=15;
    if (!text || !*text || r.w < size || r.h < size || lines < 1) return 0;
    const char *s = text;
    int used = 0, pitch = size + 5;
    for (int row = 0; row < lines && *s && used + size <= r.h; row++, used += pitch) {
        char line[512];
        size_t n = 0;
        while (*s && *s != '\n') {
            size_t c = utf8_bytes((unsigned char)*s);
            if (n + c >= sizeof(line)) break;
            memcpy(line + n, s, c); line[n + c] = 0;
            if (text_width(p, size, line) > r.w) { line[n] = 0; break; }
            n += c; s += c;
        }
        line[n] = 0;
        if (!n && *s && *s != '\n') { s += utf8_bytes((unsigned char)*s); continue; }
        if (*s == '\n') s++;
        bool last = row + 1 == lines || used + pitch + size > r.h;
        if (last && *s) {
            while (n && (n + 4 >= sizeof(line) || text_width(p, size, line) + text_width(p, size, "…") > r.w)) {
                do { n--; } while (n && ((unsigned char)line[n] & 0xc0) == 0x80);
                line[n] = 0;
            }
            if (n + 4 < sizeof(line) && text_width(p, size, "…") <= r.w) memcpy(line + n, "…", 4);
        }
        p->ops->text(p->ops->context, r.x, r.y + used, size, line, gray);
    }
    return used;
}
static int one(const paint_t *p, rect_t r, int size, const char *text, int gray) {
    return wrapped(p, r, size, 1, text, gray);
}
static rect_t below(rect_t r, int dy) { r.y += dy; r.h -= dy; return r; }
static void asset(const paint_t *p, const ps_board_asset_t *a, rect_t r) {
    if (!p->ops->image || r.w < 1 || r.h < 1) return;
    int w = r.w, h = (int)((int64_t)w * a->height / a->width);
    if (h > r.h) { h = r.h; w = (int)((int64_t)h * a->width / a->height); }
    if (w > 0 && h > 0) p->ops->image(p->ops->context, a, r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h);
}
static void plot(const paint_t *p, const ps_board_module_t *m, rect_t r) {
    if (m->series_count < 2 || r.w < 2 || r.h < 12) return;
    float low = m->series[0], high = low;
    for (unsigned i = 1; i < m->series_count; i++) {
        if (m->series[i] < low) low = m->series[i];
        if (m->series[i] > high) high = m->series[i];
    }
    double span = (double)high - low;
    if (span <= 0) span = 1;
    fill(p, (rect_t){r.x, r.y + r.h - 1, r.w, 1}, p->border);
    int px = r.x, py = r.y + r.h - 2 - (int)(((double)m->series[0] - low) / span * (r.h - 3));
    for (unsigned i = 1; i < m->series_count; i++) {
        int x = r.x + (int)((uint32_t)i * (r.w - 1) / (m->series_count - 1));
        int y = r.y + r.h - 2 - (int)(((double)m->series[i] - low) / span * (r.h - 3));
        p->ops->line(p->ops->context, px, py, x, y, p->ink); px = x; py = y;
    }
}
static double progress(const ps_board_model_t *model, const ps_board_module_t *m) {
    double result = m->progress;
    if (m->running && m->duration > 0 && m->timestamp > 0 && model->display_time > m->timestamp)
        result += (model->display_time - m->timestamp) / m->duration * 100.;
    return result < 0 ? 0 : result > 100 ? 100 : result;
}
static int metrics(const paint_t *p, const ps_board_module_t *m, rect_t r) {
    if (!m->metric_count || r.h < 20) return 0;
    unsigned cols = m->metric_count == 1 ? 1 : r.w >= 440 ? 3 : r.w >= 220 ? 2 : 1;
    int cellw = r.w / (int)cols, size = r.h > 100 ? 28 : r.h > 54 ? 23 : 18;
    int pitch = size + 24;
    unsigned visible = (unsigned)(r.h / pitch) * cols;
    if (!visible) visible = cols;
    if (visible > m->metric_count) visible = m->metric_count;
    for (unsigned i = 0; i < visible; i++) {
        int offset = (int)(i / cols) * pitch;
        rect_t c = {r.x + (int)(i % cols) * cellw, r.y + offset, cellw - 8, min(pitch, r.h - offset)};
        char value[160];
        snprintf(value, sizeof(value), "%s%s%s", m->metrics[i].value,
            *m->metrics[i].unit ? " " : "", m->metrics[i].unit);
        one(p, c, size, value, p->ink);
        one(p, below(c, size + 3), 14, m->metrics[i].label, p->muted);
    }
    return (int)((visible + cols - 1) / cols) * pitch;
}
static int rows(const paint_t *p, const ps_board_module_t *m, rect_t r) {
    unsigned count = (unsigned)(r.h > 0 ? r.h / 25 : 0);
    if (count > m->row_count) count = m->row_count;
    for (unsigned i = 0; i < count; i++) {
        rect_t row = {r.x, r.y + (int)i * 25, r.w, 23};
        int split = r.w * 48 / 100;
        one(p, (rect_t){row.x, row.y, split - 6, row.h}, 16, m->rows[i].label, p->muted);
        one(p, (rect_t){row.x + split, row.y, row.w - split, row.h}, 16, m->rows[i].value, p->ink);
    }
    return (int)count * 25;
}
static uint16_t map_u16(const uint8_t *p){return (uint16_t)(p[0]|p[1]<<8);}
static void region_value(char *out,size_t bytes,double value,bool traffic){
    const char *suffix="";
    if(value>=1e12){value/=1e12;suffix="T";}
    else if(value>=1e9){value/=1e9;suffix="G";}
    else if(value>=1e6){value/=1e6;suffix="M";}
    else if(value>=1e3){value/=1e3;suffix="k";}
    snprintf(out,bytes,value>=1000?"%.3g%s%s":value>=100?"%.0f%s%s":"%.1f%s%s",value,suffix,traffic?"B":"");
}
static void ranking(const paint_t *p,const ps_board_module_t *m,rect_t r){
    unsigned count=(unsigned)(r.h>0?r.h/27:0);if(count>m->region_count)count=m->region_count;
    uint16_t order[250];
    for(unsigned i=0;i<m->region_count;i++)order[i]=(uint16_t)i;
    double maximum=0;for(unsigned i=0;i<m->region_count;i++)if(m->regions[i].value>maximum)maximum=m->regions[i].value;
    for(unsigned i=0;i<count;i++){
        unsigned best=i;for(unsigned j=i+1;j<m->region_count;j++)if(m->regions[order[j]].value>m->regions[order[best]].value)best=j;
        uint16_t swap=order[i];order[i]=order[best];order[best]=swap;
        const ps_board_region_t *region=&m->regions[order[i]];
        rect_t row={r.x,r.y+(int)i*27,r.w,24};
        int bar=maximum>0?(int)(region->value/maximum*(r.w-2)):0;
        fill(p,(rect_t){row.x,row.y+22,bar,2},p->border);
        int left=min(r.w/2,110);char value[40];region_value(value,sizeof(value),region->value,m->rank_traffic);
        one(p,(rect_t){row.x,row.y,left-5,21},15,region->code,p->muted);
        one(p,(rect_t){row.x+left,row.y,row.w-left,21},15,value,p->ink);
    }
}
static void world_map(const paint_t *p,const ps_board_model_t *model,const ps_board_module_t *m,rect_t r){
    if(!model->world_map){wrapped(p,r,16,2,"地图资源未就绪 / Map unavailable",p->muted);return;}
    const uint8_t *map=model->world_map;unsigned countries=map_u16(map+12);
    const uint8_t *dots=map+24+countries*6;
    double maximum=0;for(unsigned i=0;i<m->region_count;i++)if(m->regions[i].value>maximum)maximum=m->regions[i].value;
    int w=r.w,h=w*52/120;if(h>r.h){h=r.h;w=h*120/52;}
    int x=r.x+(r.w-w)/2,y=r.y+(r.h-h)/2;
    for(unsigned i=0;i<countries;i++){
        const uint8_t *country=map+24+i*6;double value=0;
        for(unsigned j=0;j<m->region_count;j++){
            const char *code=m->regions[j].code;
            if(code[0]==country[0]&&code[1]==country[1]&&!code[2]){value=m->regions[j].value;break;}
        }
        double ratio=maximum>0?value/maximum:0;
        int gray=p->border,dot=min(w/120,h/52);
        if(dot<1)dot=1;
        if(value>0){int level=ratio>.5?0:ratio>.1?1:ratio>.01?3:4;gray=p->background?level:15-level;}
        else if(dot>1)dot--;
        unsigned start=map_u16(country+2),count=map_u16(country+4);
        for(unsigned j=0;j<count;j++){
            unsigned point=map_u16(dots+(start+j)*2),col=point%120,row=point/120;
            int xx=x+(int)(col*(unsigned)w/120),yy=y+(int)(row*(unsigned)h/52);
            fill(p,(rect_t){xx,yy,min(dot,x+w-xx),min(dot,y+h-yy)},gray);
        }
    }
}
static void cloudflare(const paint_t *p,const ps_board_model_t *model,const ps_board_module_t *m,rect_t r){
    int chart=m->series_count>1&&r.h>115?min(100,r.h/4):0;
    rect_t body=r;body.h-=chart?chart+10:0;
    if(m->metric_count){rect_t stats=body;stats.h=min(stats.h,68);body=below(body,metrics(p,m,stats)+8);}
    if(body.h>24&&m->region_count){
        if(m->region_ranking)ranking(p,m,body);
        else{
            int map_height=min(body.h,body.w*52/120);
            world_map(p,model,m,(rect_t){body.x,body.y,body.w,map_height});
            body=below(body,map_height+10);if(body.h>=27)ranking(p,m,body);
        }
    }else if(*m->body&&body.h>20)wrapped(p,body,18,body.h/23,m->body,p->ink);
    if(chart)plot(p,m,(rect_t){r.x,r.y+r.h-chart,r.w,chart});
}
static void card(const paint_t *p, const ps_board_model_t *model, const ps_board_module_t *m, rect_t r) {
    if (r.h < 13 || r.w < 40) return;
    int bottom = r.y + r.h;
    const char *title = *m->title ? m->title : ps_board_kind_name(m->kind);
    if(r.h<45){
        char summary[320];const char *detail=m->metric_count?m->metrics[0].value:*m->subtitle?m->subtitle:m->body;
        snprintf(summary,sizeof(summary),"%s%s%s",title,*detail?" · ":"",detail);
        one(p,r,14,summary,p->ink);return;
    }
    one(p, r, 16, title, p->muted);
    r = below(r, 25);
    if (m->kind == PS_BOARD_IMAGE) {
        asset(p, &model->assets[m->asset_index], r); return;
    }
    if (*m->footer && r.h > 90) {
        one(p, (rect_t){r.x, bottom - 18, r.w, 18}, 13, m->footer, p->muted);
        r.h -= 24;
    }
    if (m->has_progress && r.h > 50) {
        rect_t bar = {r.x, r.y + r.h - 5, r.w, 4};
        fill(p, bar, p->border); bar.w = (int)(bar.w * progress(model, m) / 100.);
        fill(p, bar, p->ink); r.h -= 15;
    }
    if (m->kind == PS_BOARD_CLOCK || m->kind == PS_BOARD_DATE) {
        time_t epoch = (time_t)(model->display_time + model->utc_offset_minutes * 60.);
        struct tm local;
        char value[64];
        if (gmtime_r(&epoch, &local)) {
            strftime(value, sizeof(value), m->kind == PS_BOARD_CLOCK ? "%H:%M" : "%Y-%m-%d", &local);
            int size = m->kind == PS_BOARD_CLOCK ? min(76, min(r.h - 4, r.w / 3)) : min(32, r.h - 4);
            if (size >= 18) {
                int y = r.y + (r.h > 130 ? (r.h - size) / 3 : 0);
                one(p, (rect_t){r.x, y, r.w, size + 4}, size, value, p->ink);
                r = below(r, y - r.y + size + 9);
            }
        }
    }
    if (m->asset_index >= 0 && r.w >= 80 && r.h >= 24) {
        if(m->media_vertical){
            int height=min(r.h/2,r.w);asset(p,&model->assets[m->asset_index],(rect_t){r.x,r.y,r.w,height});r=below(r,height+8);
        }else{
            int side = min(min(r.w / 3, r.h), 112);
            asset(p, &model->assets[m->asset_index], (rect_t){r.x + r.w - side, r.y, side, side});
            r.w -= side + 10;
        }
    }
    if (*m->subtitle && r.h >= 20 && (!m->metric_count || r.h >= 80))
        r = below(r, wrapped(p, r, 18, r.h > 130 ? 2 : 1, m->subtitle, p->ink) + 5);
    if(m->kind==PS_BOARD_CLOUDFLARE){cloudflare(p,model,m,r);return;}
    int chart = m->series_count > 1 && r.h > 90 ? min(100, r.h / 3) : 0;
    rect_t content = r; content.h -= chart ? chart + 10 : 0;
    if (m->metric_count) content = below(content, metrics(p, m, content));
    if (*m->body && content.h >= 19) {
        int size = content.w > 260 && content.h > 130 ? 22 : 18;
        int available = content.h;
        if (m->row_count && available > 110) available /= 2;
        rect_t body = content; body.h = available;
        content = below(content, wrapped(p, body, size, available / (size + 5), m->body, p->ink) + 5);
    }
    if (m->row_count && content.h >= 25) rows(p, m, content);
    if (chart) plot(p, m, (rect_t){r.x, r.y + r.h - chart, r.w, chart});
}
static unsigned layout_rows(const ps_board_model_t *model,unsigned columns){
    unsigned row=0,col=0;
    for(unsigned i=0;i<model->module_count;i++){
        unsigned span=model->modules[i].span==2?columns:1;
        if(col+span>columns){row++;col=0;}
        col+=span;if(col==columns){row++;col=0;}
    }
    return row+(col?1:0);
}
void ps_board_model_paint(const ps_board_model_t *model, const ps_board_painter_t *ops) {
    if (!model || !model->module_count || !ops || !ops->fill || !ops->line || !ops->text || !ops->measure
        || ops->width < 120 || ops->height < 120) return;
    paint_t p = {ops, model->dark ? 15 : 0, model->dark ? 11 : 4, model->dark ? 5 : 10, model->dark ? 0 : 15, ((int)model->text_scale-3)*2};
    fill(&p, (rect_t){0, 0, ops->width, ops->height}, p.background);
    // 中文：顶部40、底部36逻辑像素留给系统状态栏及两角入口。
    // English: Reserve 40 logical pixels above and 36 below for system status and corner controls.
    int content_height = ops->height - 76;
    unsigned columns = model->module_count < model->columns ? model->module_count : model->columns;
    // 中文：横屏多卡保持至少两列；每张卡根据可用面积选择信息密度。
    // English: Multi-card landscape views use at least two columns; each card adjusts density to its available area.
    if (ops->width > ops->height && model->module_count > 1 && columns < 2) columns = 2;
    while (columns < 3 && columns < model->module_count) {
        unsigned row_count = layout_rows(model,columns);
        int cell_height = (content_height - ((int)row_count - 1) * 16) / (int)row_count;
        int next_width = (ops->width - 28 - (int)columns * 16) / (int)(columns + 1);
        if (cell_height >= 72 || next_width < 64) break;
        columns++;
    }
    unsigned row_count = layout_rows(model,columns);
    int pad = 14, gap = row_count>6?8:16;
    // 中文：密集整行卡片先压缩留白，保留至少一行可读摘要。
    // English: Dense full-width cards reduce whitespace first, retaining one readable summary line.
    if(row_count>1){
        int available_gap=(content_height-(int)row_count*17)/((int)row_count-1);
        gap=min(gap,available_gap>0?available_gap:0);
    }
    int w = (ops->width - pad * 2 - ((int)columns - 1) * gap) / (int)columns;
    int h = (content_height - ((int)row_count - 1) * gap) / (int)row_count;
    unsigned row=0,col=0;
    for (unsigned i = 0; i < model->module_count; i++) {
        unsigned span=model->modules[i].span==2?columns:1;
        if(col+span>columns){row++;col=0;}
        int x = pad + (int)col * (w + gap), y = 40 + (int)row * (h + gap);
        int width=span==columns?ops->width-pad*2:w;
        card(&p, model, &model->modules[i], (rect_t){x, y, width, h});
        if (row + 1 < row_count) fill(&p, (rect_t){x, y + h + gap / 2, width, 1}, p.border);
        col+=span;if(col==columns){row++;col=0;}
    }
}

#ifndef PICO_BOARD_PORTABLE
static void device_fill(void *fb, int x, int y, int w, int h, int gray) { ps_fill(fb, x, y, w, h, gray); }
static void device_line(void *fb, int x0, int y0, int x1, int y1, int gray) { ps_line(fb, x0, y0, x1, y1, gray); }
static void device_text(void *fb, int x, int y, int size, const char *text, int gray) {
    ps_body_text(fb, x, y, size, text, gray);
}
static int device_measure(void *unused, int size, const char *text) {
    (void)unused;
    int previous = ttf_get_weight();
    if (previous < 600) ttf_set_weight(600);
    int width = ttf_text_width_px((size * 19 + 5) / 10, text);
    ttf_set_weight(previous);
    return (width * 10 + 18) / 19;
}
static void device_image(void *fb, const ps_board_asset_t *asset, int x, int y, int w, int h) {
    EpdRect r = ps_rect(x, y, w, h);
    for (int yy = 0; yy < r.height; yy++) {
        unsigned sy = (unsigned)((int64_t)yy * asset->height / r.height);
        const uint8_t *row = asset->pixels + sy * ((asset->width + 1u) / 2u);
        for (int xx = 0; xx < r.width; xx++) {
            unsigned sx = (unsigned)((int64_t)xx * asset->width / r.width);
            unsigned gray = sx & 1 ? row[sx / 2] & 15 : row[sx / 2] >> 4;
            epd_draw_pixel(r.x + xx, r.y + yy, (uint8_t)(gray * 17), fb);
        }
    }
}
void ps_board_model_render(uint8_t *fb, const ps_board_model_t *model) {
    if (!fb) return;
    ps_view_t v = ps_view();
    ps_board_painter_t painter = {fb, v.w, v.h, device_fill, device_line, device_text, device_measure, device_image};
    ps_board_model_paint(model, &painter);
}
#endif
