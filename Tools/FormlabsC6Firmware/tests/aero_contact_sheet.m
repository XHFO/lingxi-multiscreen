#import <AppKit/AppKit.h>
// Contact sheet only. Each panel is an unmodified actual 240x240 frame.
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=2&&argc!=4)return 1;NSString *root=[NSString stringWithUTF8String:argv[1]];
    NSImage *sheet=[[NSImage alloc]initWithSize:NSMakeSize(796,628)];[sheet lockFocus];
    [[NSColor colorWithWhite:0.12 alpha:1]setFill];NSRectFill(NSMakeRect(0,0,796,628));
    NSDictionary *label=@{NSFontAttributeName:[NSFont systemFontOfSize:16 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.whiteColor};
    NSArray *names=@[@"clock",@"weather",@"printer"],*titles=@[@"主时钟",@"天气温度",@"打印进度百分比"];
    for(unsigned row=0;row<2;row++){
        NSString *variant=row?@"aero":@"current",*heading=row?@"航天仪表字形 · 预览方案":@"当前字形";
        if(argc==4)heading=[NSString stringWithUTF8String:argv[row+2]];
        CGFloat bottom=row?18:326;[heading drawAtPoint:NSMakePoint(20,bottom+255)withAttributes:label];
        for(unsigned col=0;col<3;col++){
            NSString *path=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.png",variant,names[col]]];
            NSImage *panel=[[NSImage alloc]initWithContentsOfFile:path];if(!panel)return 2;
            [panel drawInRect:NSMakeRect(20+col*258,bottom,240,240)fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
            if(row==0)[titles[col] drawAtPoint:NSMakePoint(20+col*258,605)withAttributes:label];
        }
    }
    [sheet unlockFocus];NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc]initWithData:[sheet TIFFRepresentation]];
    NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:[root stringByAppendingPathComponent:@"comparison.png"]atomically:YES]?0:3;
}}
