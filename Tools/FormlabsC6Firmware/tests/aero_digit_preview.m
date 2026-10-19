// Use the real RGB565 renderer and its clock parity tests for both variants.
#define main clock_preview_main
#include "clock_preview.m"
#undef main
int main(int argc,char **argv){
    int result=clock_preview_main(argc,argv);if(result)return result;
    c6_renderer_t r={0};assert(c6_renderer_init(&r,frame,sizeof(frame)));r.english=true;
#ifdef TEST_SMOOTH_DIGITS
    r.smooth_digits=true;
#endif
    c6_render_weather_t weather={.city="SINGAPORE",.temperature=-12,.code=0,.valid=true,.humidity=58,.wind=3.2,.humidity_valid=true,.wind_valid=true};
    c6_renderer_weather(&r,&weather);write_png(argv[1],"temperature-negative");
    c6_render_printer_t printer={.name="FORM 4",.status="finished",.progress=100,.remaining=0,.connected=true,.show_status=true,.show_progress=true,.show_remaining=true,.time_text="COMPLETED",.formlabs=true};
    c6_renderer_printer(&r,&printer);write_png(argv[1],"progress-100");
    const c6_render_clock_t digits[]={{2026,10,10,6,1,23,58},{2026,10,10,6,4,56,58},{2026,10,10,6,7,89,58}};
    const char *names[]={"digits-0123","digits-0456","digits-0789"};
    // The final clock is a glyph-only stress fixture, not a valid real time.
    for(unsigned i=0;i<3;i++){c6_renderer_clock(&r,&digits[i],NULL,1000);write_png(argv[1],names[i]);}
    puts("Aerospace numeral preview: scoped clock/temperature/progress fixtures rendered");return 0;
}
