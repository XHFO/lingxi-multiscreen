const char *c6_renderer_localized(c6_renderer_t *r,const char *zh){
    if(!zh)return zh;
    if(!r->english){
#if C6_FORMLABS_ONLY
        if(!strcmp(zh,"扫码连接热点"))return "连接热点";
        if(!strcmp(zh,"打开配网后台"))return "配网后台";
        if(!strcmp(zh,"联网成功 · 扫码设置"))return "联网成功";
        if(!strcmp(zh,"先切回同一 Wi-Fi · 单击指引"))return "同一网络扫码 · 单击指引";
        static const char *polished[][2]={{"轮询卡片","卡片轮转"},{"网页详细配置","网页设置"},{"手机扫码 · 无需 PIN","扫码打开设置"},{"动态翻页","翻页动画"},{"方向与时钟动画","方向、语言与休眠"},{"网页后台 OTA 更新","网页固件更新"}};
        for(unsigned i=0;i<sizeof(polished)/sizeof(*polished);i++)if(!strcmp(zh,polished[i][0]))return polished[i][1];
#endif
        return zh;
    }
    static const char *pairs[][2]={
        {"扫码连接热点","JOIN WI-FI"},{"打开配网后台","WI-FI SETUP"},
        {"单击切换二维码 · 长按设置","Tap: switch QR / hold: menu"},{"联网成功 · 扫码设置","WI-FI READY"},
        {"先切回同一 Wi-Fi · 单击指引","Same Wi-Fi / tap: help"},
        {"3 配置打印机与天气","3 Printers / weather"},{"在后台填写设备信息","Device settings on web"},
        {"1 手机切回同一 Wi-Fi","1 Rejoin home Wi-Fi"},{"2 扫码打开设备设置","2 Scan for settings"},
        {"配置热点即将关闭","Setup hotspot closes"},{"3 添加 Formlabs 打印机","3 Add Formlabs printer"},
        {"准备序列号与云端凭据","Serial / cloud credentials"},{"联网成功 · 接着配置","WI-FI READY / NEXT"},
        {"单击扫码 · 双击稍后配置","Tap: QR / double: later"},
        {"打印机总览","PRINTER OVERVIEW"},{"已禁用","DISABLED"},
        {"设备设置","SETTINGS"},{"屏幕显示","DISPLAY"},{"方向与时钟动画","Orientation / animation"},
        {"轮询卡片","CARD ROTATION"},{"选择参与自动轮转的卡片","Choose rotating cards"},
        {"网页详细配置","WEB SETTINGS"},{"手机扫码 · 无需 PIN","Scan QR / no PIN"},
        {"网络","NETWORK"},{"连接信息与重置 Wi-Fi","Wi-Fi / reset"},{"设备信息","DEVICE INFO"},{"固件与运行时间","Firmware / uptime"},
        {"屏幕翻转","ROTATION"},{"180° · 双击恢复","180 / double: reset"},{"正常 · 双击翻转","0 / double: rotate"},
        {"动态翻页","FLIP ANIMATION"},{"已开启 · 双击关闭","On / double: off"},{"已关闭 · 双击开启","Off / double: on"},
        {"显示语言","LANGUAGE"},{"桌面时钟","FLIP CLOCK"},{"天气","WEATHER"},
        {"屏幕方向","ORIENTATION"},{"自动休眠","AUTO SLEEP"},{"无操作休眠","After inactivity"},{"定时休眠","Scheduled"},{"关闭","Off"},
        {"休眠时段与显示参数","Sleep / display options"},
        {"已启用 · 双击关闭","On / double: off"},{"已关闭 · 双击启用","Off / double: on"},
        {"尚未配置 · 双击扫码","Not set / double: QR"},{"尚未启用 · 双击扫码","Disabled / double: QR"},
        {"连接同一 Wi-Fi","Same Wi-Fi network"},{"尚未连接局域网","LAN disconnected"},
        {"已连接 2.4 GHz Wi-Fi","2.4 GHz connected"},{"未连接 · 可使用配置热点","Offline / use hotspot"},
        {"IP 地址","IP ADDRESS"},{"重置 Wi-Fi","RESET WI-FI"},{"保留实体与打印机设置","Keep entities / printers"},
        {"确认重置 Wi-Fi","RESET WI-FI?"},{"取消","CANCEL"},{"不修改网络配置","Keep network settings"},
        {"仅清除网络 · 不恢复出厂","Clear network only"},{"设备名称","DEVICE NAME"},{"固件","FIRMWARE"},{"运行时间","UPTIME"},
        {"固件更新","FIRMWARE UPDATE"},{"网页后台 OTA 更新","Use web OTA"},{"时钟设置","CLOCK SETTINGS"},
        {"时间同步","TIME SYNC"},{"已同步","Synced"},{"等待网络校时","Waiting for NTP"},
        {"天气详情","WEATHER DETAILS"},{"最低 / 最高","LOW / HIGH"},{"刷新天气","REFRESH WEATHER"},
        {"至少间隔 5 分钟，失败后退避","5 min limit / retry"},{"城市与更新间隔","City / update interval"},
        {"打印机详情","PRINTER DETAILS"},{"任务名称","TASK"},{"打印状态","STATUS"},{"打印进度","PROGRESS"},
        {"剩余时间","REMAINING"},{"层数","LAYERS"},{"材料","MATERIAL"},{"等待打印数据","Waiting for printer"},
        {"数据源与显示项目","Source / display fields"},{"卡片详情","CARD DETAILS"},{"手机连接同一 Wi-Fi","Use same Wi-Fi"},
        {"长按返回 · 自动保存","Hold: back / autosave"},{"单击切换 · 双击确认 · 长按返回","Tap: next / 2x: OK / hold: back"},
        {"单击切换 · 双击确认","Tap: next / 2x: OK"},{"手机连接同一 Wi-Fi · 长按返回","Same Wi-Fi / hold: back"},
        {"等待天气更新","Waiting for weather"},{"在网页配置城市与位置","Set city on web page"},{"缓存","CACHED"},{"未设定城市","CITY NOT SET"},
        {"等待画面","NO IMAGE"},{"等待状态","WAITING"},{"空闲","IDLE"},{"打印中","PRINTING"},{"已暂停","PAUSED"},
        {"报错","ERROR"},{"待机","STANDBY"},{"关机","OFF"},{"离线","OFFLINE"},{"已完成","DONE"},{"忙碌","BUSY"},
        {"准备中","PREPRINT"},{"初始化中","INIT"},{"切片中","SLICING"},{"退料中","UNLOADING"},{"进料中","LOADING"},
        {"冷却中","COOLING"},{"加热中","HEATING"},{"校准中","CALIBRATING"},{"失败","FAILED"},{"未知","UNKNOWN"},
        {"后处理中","POSTPRINT"},{"已取消","CANCELLED"},{"已终止","ABORTED"},
        {"配置已更新 · 重新打开设置","Changed / reopen settings"},{"保存失败 · 长按重试","Save failed / hold: retry"},
        {"已重置 · 请连接设备配置热点","Reset / use hotspot"},{"重置失败 · 请重试","Reset failed / retry"},
        {"已安排刷新","Refresh scheduled"},{"请等待 5 分钟间隔后重试","Retry after 5 min"},
        {"Wi-Fi 已连接","WI-FI CONNECTED"},{"局域网 IP 地址","LAN IP ADDRESS"},{"手机连接同一 Wi-Fi 后扫码","Same Wi-Fi / scan QR"},
        {"配置热点","SETUP HOTSPOT"},{"联网成功后自动关闭","Closes after connecting"},{"单击继续 · 长按设备设置","Tap: continue / hold: settings"},
        {"等待本地数据","WAITING FOR DATA"},{"请在软件中选择显示卡片","Enable cards on web"},
        {"可用内存","FREE MEMORY"},{"网络地址","NETWORK ADDRESS"},{"长按 BOOT 打开设置","Hold BOOT: settings"},
        {"单击翻页 · 双击详情 · 长按设置","Tap: next / 2x: details / hold: settings"},{"设备状态","DEVICE STATUS"},
        {"无法生成二维码","QR ERROR"},{"设备状态","DEVICE STATUS"},{"实体详情","ENTITY DETAILS"},{"名称","NAME"},{"状态","STATE"},{"状态 · 不可用","STATE / UNAVAILABLE"},{"数据更新","UPDATED"},{"尚未获取","Not received"},{"暂无实体","No entities"},{"请在 Mac 卡片页面选择","Choose entities on Mac"},{"选择实体与显示名称","Entities / labels"},{"实体已移除","Entity removed"},{"开","ON"},{"关","OFF"},{"无","NONE"},{"不可用","UNAVAILABLE"},{"请选择显示的实体","Choose displayed entities"},{"任务","TASK"},{"实况","LIVE"},{"等待显示","WAITING FOR DISPLAY"},{"等待软件推送最新画面","Waiting for software frame"},{"在电脑的设备管理中操作","Use device management on Mac"},
        {"打印机已移除或未同步","Printer not available"},{"请在网页添加打印机","Add printer on web"},
        {"请在 Mac 同步显示设置","Sync display on Mac"},{"正在恢复卡片","RESTORING CARD"},{"等待最新软件画面","Waiting for new frame"}
    };
    for(unsigned i=0;i<sizeof(pairs)/sizeof(*pairs);i++)if(!strcmp(zh,pairs[i][0]))return pairs[i][1];
    return zh;
}
