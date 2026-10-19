#if C6_FORMLABS_ONLY
// Small, original 5×7 terminal glyphs. Integer blocks; no smoothing or assets.
typedef struct { unsigned code; uint8_t rows[7]; } terminal_pixel_glyph_t;
static const terminal_pixel_glyph_t terminal_pixel_glyphs[]={
 {' ',{0}}, {'!',{4,4,4,4,4,0,4}}, {'"',{10,10,10,0,0,0,0}},
 {'#',{10,31,10,10,31,10,0}}, {'$',{4,15,20,14,5,30,4}},
 {'%',{25,26,2,4,8,11,19}}, {'&',{12,18,20,8,21,18,13}},
 {'\'',{4,4,8,0,0,0,0}}, {'(',{2,4,8,8,8,4,2}}, {')',{8,4,2,2,2,4,8}},
 {'*',{0,21,14,31,14,21,0}}, {'+',{0,4,4,31,4,4,0}}, {',',{0,0,0,0,4,4,8}},
 {'-',{0,0,0,31,0,0,0}}, {'.',{0,0,0,0,0,12,12}}, {'/',{1,2,2,4,8,8,16}},
 {'0',{14,17,17,17,17,17,14}}, {'1',{4,12,4,4,4,4,14}},
 {'2',{14,17,1,2,4,8,31}}, {'3',{30,1,1,14,1,1,30}},
 {'4',{2,6,10,18,31,2,2}}, {'5',{31,16,16,30,1,1,30}},
 {'6',{14,16,16,30,17,17,14}}, {'7',{31,1,2,4,8,8,8}},
 {'8',{14,17,17,14,17,17,14}}, {'9',{14,17,17,15,1,1,14}},
 {':',{0,12,12,0,12,12,0}}, {';',{0,12,12,0,4,4,8}},
 {'<',{2,4,8,16,8,4,2}}, {'=',{0,31,0,31,0,0,0}}, {'>',{8,4,2,1,2,4,8}},
 {'?',{14,17,1,2,4,0,4}}, {'@',{14,17,23,21,23,16,14}},
 {'A',{14,17,17,31,17,17,17}}, {'B',{30,17,17,30,17,17,30}},
 {'C',{14,17,16,16,16,17,14}}, {'D',{30,17,17,17,17,17,30}},
 {'E',{31,16,16,30,16,16,31}}, {'F',{31,16,16,30,16,16,16}},
 {'G',{14,17,16,23,17,17,15}}, {'H',{17,17,17,31,17,17,17}},
 {'I',{14,4,4,4,4,4,14}}, {'J',{7,2,2,2,2,18,12}},
 {'K',{17,18,20,24,20,18,17}}, {'L',{16,16,16,16,16,16,31}},
 {'M',{17,27,21,21,17,17,17}}, {'N',{17,25,25,21,19,19,17}},
 {'O',{14,17,17,17,17,17,14}}, {'P',{30,17,17,30,16,16,16}},
 {'Q',{14,17,17,17,21,18,13}}, {'R',{30,17,17,30,20,18,17}},
 {'S',{15,16,16,14,1,1,30}}, {'T',{31,4,4,4,4,4,4}},
 {'U',{17,17,17,17,17,17,14}}, {'V',{17,17,17,17,17,10,4}},
 {'W',{17,17,17,21,21,27,17}}, {'X',{17,17,10,4,10,17,17}},
 {'Y',{17,17,10,4,4,4,4}}, {'Z',{31,1,2,4,8,16,31}},
 {'[',{14,8,8,8,8,8,14}}, {'\\',{16,8,8,4,2,2,1}}, {']',{14,2,2,2,2,2,14}},
 {'^',{4,10,17,0,0,0,0}}, {'_',{0,0,0,0,0,0,31}}, {'`',{8,4,2,0,0,0,0}},
 {'a',{0,0,14,1,15,17,15}}, {'b',{16,16,30,17,17,17,30}},
 {'c',{0,0,14,16,16,17,14}}, {'d',{1,1,15,17,17,17,15}},
 {'e',{0,0,14,17,31,16,14}}, {'f',{6,8,8,28,8,8,8}},
 {'g',{0,0,15,17,15,1,14}}, {'h',{16,16,30,17,17,17,17}},
 {'i',{4,0,12,4,4,4,14}}, {'j',{2,0,6,2,2,18,12}},
 {'k',{16,16,18,20,24,20,18}}, {'l',{12,4,4,4,4,4,14}},
 {'m',{0,0,26,21,21,21,21}}, {'n',{0,0,30,17,17,17,17}},
 {'o',{0,0,14,17,17,17,14}}, {'p',{0,0,30,17,30,16,16}},
 {'q',{0,0,15,17,15,1,1}}, {'r',{0,0,22,25,16,16,16}},
 {'s',{0,0,15,16,14,1,30}}, {'t',{8,8,28,8,8,9,6}},
 {'u',{0,0,17,17,17,19,13}}, {'v',{0,0,17,17,17,10,4}},
 {'w',{0,0,17,17,21,21,10}}, {'x',{0,0,17,10,4,10,17}},
 {'y',{0,0,17,17,15,1,14}}, {'z',{0,0,31,2,4,8,31}},
 {'{',{2,4,4,8,4,4,2}}, {'|',{4,4,4,4,4,4,4}}, {'}',{8,4,4,2,4,4,8}},
 {'~',{0,0,8,21,2,0,0}}, {176,{6,9,9,6,0,0,0}},
};
static const uint8_t *terminal_pixel_rows(unsigned code){for(unsigned i=0;i<sizeof(terminal_pixel_glyphs)/sizeof(*terminal_pixel_glyphs);i++)if(terminal_pixel_glyphs[i].code==code)return terminal_pixel_glyphs[i].rows;return NULL;}
static unsigned terminal_pixel_scale(unsigned size){return size>=11?(size+3)/7:1;}
static int terminal_pixel_advance(unsigned size){return (int)terminal_pixel_scale(size)*6;}
// Original 12x20 heavy display numerals: chamfered corners, broad strokes and
// finer steps than stretching the 5x7 utility face. Shared by clock/temp/progress.
static const uint16_t terminal_hero_digits[10][20]={
 {0x3fc,0x7fe,0xfff,0xfff,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xfff,0xfff,0x7fe,0x3fc},
 {0x0f0,0x1f0,0x3f0,0x7f0,0x7f0,0x0f0,0x0f0,0x0f0,0x0f0,0x0f0,0x0f0,0x0f0,0x0f0,0x0f0,0x0f0,0x0f0,0x0f0,0x7fc,0x7fc,0x7fc},
 {0x3fc,0x7fe,0xfff,0xf0f,0xf0f,0xf0f,0x00f,0x01f,0x03e,0x07c,0x0f8,0x1f0,0x3e0,0x7c0,0xf80,0xf00,0xfff,0xfff,0xfff,0xfff},
 {0xffc,0xffe,0xfff,0x00f,0x00f,0x00f,0x00f,0x00f,0x3fe,0x3ff,0x3fe,0x00f,0x00f,0x00f,0x00f,0x00f,0xf0f,0xfff,0x7fe,0x3fc},
 {0x01f,0x03f,0x07f,0x0ff,0x1ef,0x3cf,0x78f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xfff,0xfff,0xfff,0xfff,0x00f,0x00f,0x00f,0x00f},
 {0xfff,0xfff,0xfff,0xfff,0xf00,0xf00,0xf00,0xf00,0xffc,0xffe,0x00f,0x00f,0x00f,0x00f,0x00f,0x00f,0xf0f,0xfff,0x7fe,0x3fc},
 {0x3fc,0x7fe,0xfff,0xf0f,0xf0f,0xf00,0xf00,0xf00,0xffc,0xffe,0xfff,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xfff,0xfff,0x7fe,0x3fc},
 {0xfff,0xfff,0xfff,0xfff,0x01f,0x03e,0x03c,0x078,0x078,0x0f0,0x0f0,0x1e0,0x1e0,0x3c0,0x3c0,0x3c0,0x780,0x780,0x780,0x780},
 {0x3fc,0x7fe,0xfff,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0x7fe,0x3fc,0x7fe,0xfff,0xf0f,0xf0f,0xf0f,0xf0f,0xfff,0xfff,0x7fe,0x3fc},
 {0x3fc,0x7fe,0xfff,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xf0f,0xfff,0x7ff,0x3ff,0x00f,0x00f,0x00f,0xf0f,0xfff,0x7fe,0x3fc}
};
static bool terminal_hero_code(unsigned code,unsigned size){return code>='0'&&code<='9'&&size>=28;}
static unsigned terminal_hero_scale(unsigned size){unsigned scale=(size+10)/20;return scale?scale:1;}
static void terminal_hero_text(c6_renderer_t *r,unsigned code,int x,int baseline,unsigned size,uint32_t ink){unsigned scale=terminal_hero_scale(size);int top=baseline-(int)scale*20;uint16_t color=color24(ink);
    for(unsigned y=0;y<20;y++)for(unsigned xx=0;xx<12;xx++)if(terminal_hero_digits[code-'0'][y]&(0x800>>xx))for(unsigned dy=0;dy<scale;dy++)for(unsigned dx=0;dx<scale;dx++)pixel(r,x+(int)(xx*scale+dx),top+(int)(y*scale+dy),color);
}
static void terminal_pixel_text(c6_renderer_t *r,const uint8_t *rows,int x,int baseline,unsigned size,uint32_t ink){unsigned scale=terminal_pixel_scale(size);int top=baseline-(int)scale*7;uint16_t color=color24(ink);
    for(unsigned y=0;y<7;y++)for(unsigned xx=0;xx<5;xx++)if(rows[y]&(16>>xx))for(unsigned dy=0;dy<scale;dy++)for(unsigned dx=0;dx<scale;dx++)pixel(r,x+(int)(xx*scale+dx),top+(int)(y*scale+dy),color);
}
#endif
