// UI translations only. Never translate device names, serials or task content.
let uiEnglish=typeof navigator!=='undefined'&&/^en\b/i.test(navigator.language||'');
const uiStrings={
'手动设置经纬度':'Set coordinates manually',
'Wi-Fi 已连接':'Wi-Fi connected',
'手机切回同一 Wi-Fi，扫描小屏上的新二维码进入后台。':'Rejoin the same Wi-Fi and scan the new QR on the display to open settings.',
'数据来源：Open-Meteo。用城市与经纬度设置天气数据位置。':'Source: Open-Meteo. Set the weather location using the city and coordinates.',
'热点正在收尾，稍等片刻就能继续设置…':'The setup hotspot is closing. Settings will open shortly…',
'先让小屏找到家':'Give your screen a home',
'顶部可切换 中文 / English。扫描屏幕的热点二维码连接设备；若后台没有自动弹出，请打开 http://192.168.4.1。':'Choose Chinese / English above. Scan the Wi-Fi QR on the screen to join the setup hotspot. If the portal does not open, visit http://192.168.4.1.',
'联网完成，接着折腾':'Connected. Let’s make it yours',
'将手机切回刚才配置的同一 Wi-Fi。':'Rejoin the same Wi-Fi you configured.',
'扫描小屏上新的局域网二维码，或打开下方地址。':'Scan the new LAN QR on the screen, or open the address below.',
'在设备设置中添加打印机；也可以先用时钟和天气。':'Add printers in Device settings, or start with the clock and weather.',
'继续配置设备':'Continue device setup',
'热点会自动关闭。后台入口已更新为设备的实际局域网 IP，不再是 192.168.4.1。':'The setup hotspot closes automatically. Settings now use the device’s actual LAN IP, not 192.168.4.1.',
'Wi-Fi 已连接。切回同一网络，扫描新二维码继续配置。':'Wi-Fi connected. Rejoin the same network and scan the new QR to continue.',
'暂未确认联网。检查密码后重试；若热点已关闭，请查看屏幕的新二维码。':'Connection not confirmed. Check your password and retry. If the hotspot has closed, use the new QR on the screen.',
'网络已保存，正在等待设备取得局域网 IP…':'Network saved. Waiting for a LAN IP…',
'网页与小屏使用同一语言，切换后自动保存。':'One language for web and display. Changes save automatically.',
'正在同步小屏语言…':'Syncing display language…',
'网页与小屏语言已同步':'Web and display language synced',
'网页已切换，小屏尚未同步，请重试':'Web language changed. Display not synced; retry.',
'设备配置已变化，语言未同步。请重试；其他修改仍保留。':'Device settings changed. Language not synced; retry. Other edits are retained.',
'重试同步':'Retry sync',
'语言响应无效':'Invalid language response',
'连上网了，让小屏有点内容':'Online. Give your screen something to show',
'准备 Formlabs 应用的 Client ID、Client Secret 与打印机序列号。':'Prepare your Formlabs app’s Client ID, Client Secret and printer serial.',
'选择“添加打印机”，填好信息后自动保存；也可点击“立即保存 / 重试”。':'Choose Add printer. Completed settings save automatically; Save now / Retry is also available.',
'查看“实时连接状态”，出现“已连接”后再核对设备显示的真实任务。':'Check Live connection status. Once Connected, verify the real task shown on the device.',
'也可以先使用翻页钟和天气。此项目仍在开发中，保存成功不代表云端验证成功。':'You can start with the flip clock and weather. This project is in development; saved settings do not prove cloud authentication succeeded.',
'配置第一台打印机':'Set up your first printer',
'设备配置已读取。下一步：添加打印机，或先体验时钟。':'Settings loaded. Next: add a printer, or try the clock first.',
'打印机总览':'Printer overview','添加两台或更多打印机后，自动显示总览卡片并加入轮转，集中展示各台设备的状态与进度。':'With two or more printers, an overview card automatically joins rotation and shows each printer’s status and progress.',
'卡片详细选项':'Card details','卡片样式':'Card style','标准 · 任务封面':'Standard · task cover','超大百分比 · 无缩略图':'Large percentage · no image','剩余打印时间 · 无缩略图':'Remaining time · no image','卡片样式无效':'Invalid card style',
'新样式自动隐藏任务封面，切回标准样式保留原选项；剩余时间样式始终显示剩余时长。':'New styles hide the cover without changing your saved options. Remaining-time style always shows the remaining duration.',
 '显示内容':'Content','设备':'Device','主数字风格':'Hero numeral style','像素 · 复古仪表':'Pixel · retro instrument','平滑 · 航天曲线':'Smooth · aerospace curves','主数字风格无效':'Invalid numeral style',
 '仅影响翻页钟主数字、天气温度和打印进度百分比。其他文字保持不变，选择后自动保存并应用。':'Applies only to the main clock, weather temperature and print percentage. Other text stays unchanged. Changes save and apply automatically.',
'预览说明':'About preview',
'网页外观':'Web appearance','跟随系统':'System','浅色':'Light','深色':'Dark','立即保存 / 重试':'Save now / Retry',
'演示序列号':'Demo serial numbers','模拟数据 · 固定不更新':'Simulated data · fixed snapshot',
'添加打印机时，序列号填入 ;;tex_1（空闲）、;;tex_2（打印中）、;;tex_3（已完成）或 ;;tex_4（出错）。无需云端凭据；作为普通打印机保存、轮转并加入总览，数据固定不更新。最多同时添加 3 台，可移除后更换状态。真实序列号仍需有效凭据。':'Add a printer with serial ;;tex_1 (idle), ;;tex_2 (printing), ;;tex_3 (completed) or ;;tex_4 (error). No cloud credentials needed. Saved and included in rotation/overview like any printer, but never updated. Up to 3 at once; remove one to try another state. Real serials still require valid credentials.',
'未保存 · 将自动保存':'Unsaved · automatic save pending','设置已保存 · 自动应用':'Saved · applied automatically','保存失败 · 修改仍保留，请重试':'Save failed · edits retained. Please retry.',
'屏幕预览':'Screen preview','设备屏幕实时画面':'Live device display','当前画面':'Current view','预览卡片':'Preview card','切换设备画面':'Show on device','刷新预览':'Refresh preview','恢复轮转':'Resume rotation',
'正在连接预览…':'Connecting to preview…','预览画面无效':'Invalid preview frame','请重新读取设备配置':'Read device settings again','无法读取设备画面':'Cannot read device display',
'设备已休眠 · 显示休眠前画面':'Device asleep · last visible frame','设备实际画面 · 每 3 秒刷新':'Actual device frame · every 3 seconds',
'预览连接中断，保留最近画面':'Preview disconnected. Last frame retained.','请先退出设备设置，并确认卡片已保存启用':'Close device settings and ensure the card is saved and enabled.','无法切换设备画面':'Cannot change device view',
'预览直接读取设备画面，每 3 秒刷新。切换画面会在设备上显示 90 秒，不修改已保存设置。':'Reads the actual device frame every 3 seconds. Selected cards appear on the device for 90 seconds without changing saved settings.',
'自动休眠':'Auto sleep','休眠策略':'Sleep policy','关闭':'Off','无操作休眠':'After inactivity','定时休眠':'Scheduled','无操作时长（分钟）':'Idle timeout (minutes)','休眠开始':'Sleep starts','休眠结束':'Sleep ends','打印期间保持亮屏':'Keep awake while printing',
'休眠时关闭背光并暂停画面渲染，网络连接与数据更新保持运行。按 BOOT 唤醒；定时休眠期间，手动唤醒后保持所设无操作时长。休眠时段使用设备时区，支持跨午夜；开始与结束时间不能相同。':'Sleep turns off the backlight and pauses rendering; networking and data updates continue. BOOT wakes the device for the idle timeout. Scheduled sleep uses the device time zone, supports midnight crossing, and requires different start and end times.',
'休眠策略无效':'Invalid sleep policy','请设置有效的休眠时间':'Enter a valid sleep time','休眠开始与结束时间不能相同':'Sleep start and end must differ','屏幕方向无效':'Invalid orientation',
'支持独立监看最多 3 台打印机，通过 Formlabs 云端 API 更新任务信息。仅提供状态监看，不执行暂停或停止打印等操作。':'Independently monitor up to 3 printers through the Formlabs cloud API. Monitoring only; no pause or stop commands.',
'获取云端访问凭据':'Cloud access credentials','在 Formlabs Developer Platform 创建应用，填写 Client ID、Client Secret 和打印机序列号。凭据按打印机独立保存，同一账户可复用。已保存的 Secret 不回显；留空保留，变更序列号或 Client ID 后需重新填写。':'Create an app on the Formlabs Developer Platform. Enter Client ID, Client Secret and serial. Credentials are stored per printer and may be shared by one account. Saved secrets are not displayed; blank keeps them. Re-enter after changing serial or Client ID.',
'仅支持 2.4 GHz Wi-Fi，不支持 5 GHz 或 6 GHz。':'Only 2.4 GHz Wi-Fi is supported, not 5 or 6 GHz.',
'连接状态':'Connection status','选择网络':'Choose network','扫描附近 Wi-Fi':'Scan nearby Wi-Fi','Wi-Fi 名称（SSID）':'Wi-Fi name (SSID)','Wi-Fi 密码':'Wi-Fi password',
'开放网络可留空；密码不会回显，也不保存到浏览器。':'Leave blank for open networks. Passwords are not shown or stored in the browser.',
'保存并连接':'Save & connect','检查连接状态':'Check connection','选择网络或填写 SSID，然后保存。':'Choose a network or enter an SSID, then save.',
'联网成功后，屏幕显示局域网 IP，配置热点自动关闭。请切回同一 Wi-Fi，再打开设备设置。':'Once connected, the display shows the LAN IP and the hotspot closes. Rejoin the same Wi-Fi and open device settings.',
'正在扫描附近的 2.4 GHz 网络…':'Scanning nearby 2.4 GHz networks…','扫描失败，请稍后重试或手动填写 SSID。':'Scan failed. Retry later or enter the SSID manually.',
'请选择网络并填写密码。':'Choose a network and enter its password.','没有发现网络，可手动填写 SSID。':'No networks found. Enter the SSID manually.',
'SSID 必须为 1–32 个 UTF-8 字节。':'SSID must be 1–32 UTF-8 bytes.','密码应为 8–63 个字节，开放网络可留空。':'Password must be 8–63 bytes; leave blank for an open network.',
'网络已保存。热点会关闭，请切回同一 Wi-Fi，打开屏幕上的 IP 地址。':'Network saved. The hotspot will close. Rejoin the same Wi-Fi and open the IP on the display.',
'多屏灵犀':'Lingxi Multiscreen','监看屏':'Monitor','ESP32-C6 · 专用测试固件':'ESP32-C6 · Dedicated test firmware',
'设置导航':'Settings navigation','打印机':'Printers','翻页钟':'Flip clock','天气':'Weather','屏幕与轮转':'Display & rotation','固件更新':'Firmware update','Wi-Fi 配网':'Wi-Fi setup',
'设备设置':'Device settings','正在读取设备信息…':'Reading device information…','读取配置':'Read configuration','保存设置':'Save settings',
'连接同一局域网后读取配置。网络仅支持 2.4 GHz。':'Connect to the same LAN to read settings. Only 2.4 GHz Wi-Fi is supported.',
'Formlabs 打印机':'Formlabs printers','最多同时监看 3 台。使用 Formlabs 云端 API，电脑退出后仍可更新。这里只监看，不发送暂停、停止等打印指令。':'Monitor up to 3 printers using the Formlabs cloud API, even with the computer off. Monitoring only; no pause or stop commands.',
'添加打印机':'Add printer','云端凭据从哪里获取？':'Where do I get cloud credentials?',
'在 Formlabs Developer Platform 创建应用，填写 Client ID、Client Secret，以及打印机序列号。云端凭据按打印机分别保存；同一账户可以使用同一组凭据。已保存的 Secret 不会回显，留空可保留；变更序列号或 Client ID 时需要重新输入。':'Create an app on the Formlabs Developer Platform. Enter its Client ID, Client Secret and printer serial. Credentials are stored per printer; one account can share credentials. Saved secrets are not shown; leave blank to keep them. Re-enter when changing serial or Client ID.',
'实时连接状态':'Live connection status','尚未获取':'Not available yet','显示时钟':'Show clock','翻页动画':'Flip animation','加入轮转':'Include in rotation',
'设备自行校时与渲染。只在分钟变化时播放约 720 毫秒的折页动画，空闲每秒刷新。':'The device syncs and renders time locally. A 720 ms fold plays on minute changes; otherwise it refreshes once per second.',
'时区（相对 UTC 的秒数）':'Time zone (seconds from UTC)','中国大陆使用 28800。设备未联网校时时会显示等待校时。':'Use 28800 for mainland China. Until network time is synced, the device shows a waiting message.',
'显示天气':'Show weather','城市名称':'City name','纬度':'Latitude','经度':'Longitude','更新间隔（分钟）':'Update interval (minutes)',
'启用后会将所填经纬度发送至 Open-Meteo 获取天气，默认每 30 分钟更新。失败保留最近数据并退避重试。':'When enabled, your coordinates are sent to Open-Meteo. Default: every 30 minutes. On failure, the last data is retained with retry backoff.',
'显示语言':'Language','屏幕方向':'Orientation','正常':'Normal','翻转 180°':'Rotate 180°','亮度（0–100）':'Brightness (0–100)','轮转间隔（秒）':'Rotation interval (seconds)','饱和度（50–200%）':'Saturation (50–200%)','对比度（75–150%）':'Contrast (75–150%)',
'仅轮转勾选的时钟、天气与打印机卡片；打印机空闲或离线时仍保留卡片，便于检查连接。已完成任务保留至下一项任务。':'Only selected clock, weather and printer cards rotate. Idle and offline printers remain visible for connection checks. Completed tasks remain until the next task.',
'BOOT 单击翻页，双击详情或确认，长按约 1.5 秒进入设置或返回。RST 只用于重启。':'BOOT: tap for next page, double-tap for details or confirm, hold 1.5 s for settings or back. RST only restarts.',
'只选择本专用版的 OTA .bin 文件。普通 C6、ESP8266 或其他开发板固件会被拒绝。更新保留 Wi-Fi 与设备设置。':'Use only this dedicated profile’s OTA .bin. Generic C6, ESP8266 and other firmware are rejected. Wi-Fi and device settings are retained.',
'OTA 固件文件':'OTA firmware file','更新固件…':'Update firmware…',
'这是独立测试分支，不替换多屏灵犀应用内置的通用 C6 固件。配置保存在这台设备内；云端授权仅在内存中缓存。':'This separate test branch does not replace the app’s generic C6 firmware. Settings are stored on this device; cloud authorization tokens are cached in memory only.',
'新的打印机':'New printer','移除':'Remove','设备名称':'Device name','打印机序列号':'Printer serial','Client Secret（留空保留）':'Client Secret (blank to keep)',
'启用':'Enabled','任务名称':'Task name','打印状态':'Print status','进度':'Progress','时间':'Time','任务封面':'Task cover','层数':'Layers','材料':'Material','品牌强调色':'Brand accent',
'剩余时间':'Remaining time','预计结束时间':'Estimated finish','时间显示':'Time display',
'请先读取设备配置':'Read device settings first','序列号需要 1–39 个英文字母、数字、下划线或连字符':'Serial requires 1–39 letters, digits, underscores or hyphens',
'不能重复添加同一打印机':'Cannot add the same printer twice','请至少启用一张参与轮转的卡片':'Enable at least one rotating card','配置过大':'Configuration too large',
'请连接设备所在的局域网；首次配网完成后热点会关闭。':'Connect to the device’s LAN. The hotspot closes after setup.','授权响应无效':'Invalid authorization response',
'重新读取会丢弃未保存的修改，继续吗？':'Reading again discards unsaved edits. Continue?','正在保存…':'Saving…','正在读取…':'Reading…',
'配置已在其他页面更新，请重新读取后再修改。':'Settings changed elsewhere. Read them again before editing.','设置已保存到这台设备。':'Settings saved on this device.','设备配置已读取。':'Device settings loaded.',
'连接超时，请检查设备网络。':'Connection timed out. Check the device network.',
'等待联网':'Waiting for network','已连接':'Connected','正在重试':'Retrying','凭据被拒绝':'Credentials rejected','等待内存':'Waiting for memory','等待数据':'Waiting for data','未知':'Unknown','尚未添加打印机':'No printers added',
'请选择本专用版 OTA .bin 文件':'Select the dedicated OTA .bin','固件文件大小不正确':'Invalid firmware size','将更新这台设备并重启，继续吗？':'Update and restart this device?','正在写入固件，请勿断电…':'Writing firmware. Keep power connected…',
'固件已写入，设备正在重启。稍后重新读取配置。':'Firmware written. Restarting; read settings again shortly.','等待联网':'Waiting for network','专用测试版':'Dedicated test build','暂未连接设备':'Device unavailable'
};
const uiChinese={
'连接同一局域网后读取配置。网络仅支持 2.4 GHz。':'连接设备所在局域网后可读取配置。仅支持 2.4 GHz Wi-Fi。',
'新的打印机':'新打印机','云端凭据从哪里获取？':'获取云端访问凭据',
'设备自行校时与渲染。只在分钟变化时播放约 720 毫秒的折页动画，空闲每秒刷新。':'设备独立校时与渲染，分钟切换时播放约 720 毫秒折页动画，其余时间每秒刷新。',
'中国大陆使用 28800。设备未联网校时时会显示等待校时。':'中国标准时间为 UTC+8（28800 秒）。网络校时完成前显示同步状态。',
'启用后会将所填经纬度发送至 Open-Meteo 获取天气，默认每 30 分钟更新。失败保留最近数据并退避重试。':'启用后向 Open-Meteo 发送所设经纬度，默认每 30 分钟更新天气。请求失败时保留最近数据并延后重试。',
'仅轮转勾选的时钟、天气与打印机卡片；打印机空闲或离线时仍保留卡片，便于检查连接。已完成任务保留至下一项任务。':'自动轮转仅包含已选择的卡片。空闲或离线打印机保留显示；已完成任务由下一项任务替换。',
'设置已保存到这台设备。':'设备设置已保存。','设备配置已读取。':'设备设置已读取。',
'等待内存':'内存不足，等待重试','凭据被拒绝':'访问凭据无效',
'这是独立测试分支，不替换多屏灵犀应用内置的通用 C6 固件。配置保存在这台设备内；云端授权仅在内存中缓存。':'Formlabs 专用测试固件，与多屏灵犀通用 C6 固件独立。设置保存在设备内，云端授权令牌仅缓存在运行内存中。',
'选择网络或填写 SSID，然后保存。':'选择或输入 Wi-Fi 名称后保存连接设置。',
'联网成功后，屏幕显示局域网 IP，配置热点自动关闭。请切回同一 Wi-Fi，再打开设备设置。':'连接成功后显示局域网 IP 并关闭配置热点。将手机或电脑连接至同一局域网，再访问设备设置。',
'开放网络可留空；密码不会回显，也不保存到浏览器。':'开放网络无需密码。密码不回显，不保存在浏览器中。'
};
function t(text){if(!uiEnglish)return uiChinese[text]||text;return uiStrings[text]||text;}
function printState(raw){
    if(!raw)return t('未知');
    const states={idle:['空闲','Idle'],printing:['打印中','Printing'],running:['打印中','Printing'],paused:['已暂停','Paused'],preprint:['准备中','Preparing'],postprint:['后处理中','Post-processing'],complete:['已完成','Complete'],completed:['已完成','Complete'],finished:['已完成','Complete'],offline:['离线','Offline'],error:['报错','Error'],cancelled:['已取消','Cancelled'],failed:['失败','Failed']};
    return states[raw.toLowerCase()]?.[uiEnglish?1:0]||raw;
}
const staticText=new WeakMap();
function applyLanguage(){
    if(document.documentElement)document.documentElement.lang=uiEnglish?'en':'zh-CN';
    if(!document.createTreeWalker)return;
    document.title='XH Multiscreen · Form Monitor C6';
    const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
    while(walker.nextNode()){
        const node=walker.currentNode,parent=node.parentElement;
        if(!parent||parent.closest('script,style,[data-no-i18n],#printerList,#status,#identity,#health,#networks,#previewStatus,#previewCard,#languageStatus'))continue;
        if(!staticText.has(node))staticText.set(node,node.nodeValue);
        const original=staticText.get(node),trimmed=original.trim();
        node.nodeValue=original.replace(trimmed,t(trimmed));
    }
    const nav=document.querySelector('nav');if(nav)nav.setAttribute('aria-label',t('设置导航'));
    for(const element of document.querySelectorAll('[data-i18n]'))element.textContent=t(element.dataset.i18n);
    const preview=document.getElementById('screenPreview');if(preview)preview.setAttribute('aria-label',t('设备屏幕实时画面'));
}
function labelText(parent,text){const span=document.createElement('span');span.dataset.i18n=text;span.textContent=t(text);parent.append(span);return span;}
function translatedText(element,text){element.dataset.i18n=text;element.textContent=t(text);}
function languageStatus(text,retry=false){const status=document.getElementById('languageStatus');status.textContent=t(text);status.dataset.state=retry?'error':'ready';document.getElementById('languageRetry').hidden=!retry;}
// No complete form submission: invalid/unfinished inputs must never prevent
// changing language, and this request cannot alter names, secrets or Wi-Fi.
async function saveDeviceLanguage(wanted){
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),12000);
    try{
        const info=await fetch('/api/info',{cache:'no-store',signal:controller.signal});
        if(!info.ok)throw Error(t('网页已切换，小屏尚未同步，请重试'));
        const before=await info.json();
        if(!Number.isInteger(before.revision)||before.revision<0)throw Error(t('语言响应无效'));
        const response=await fetch('/api/language',{method:'POST',cache:'no-store',signal:controller.signal,
            headers:{'Content-Type':'application/json','X-XH-Language':'1','X-Lingxi-LAN':'1'},body:JSON.stringify({revision:before.revision,language:wanted})});
        if(!response.ok){const e=Error(t(response.status===409?'设备配置已变化，语言未同步。请重试；其他修改仍保留。':'网页已切换，小屏尚未同步，请重试'));e.conflict=response.status===409;throw e;}
        const result=await response.json();
        if(!Number.isInteger(result.revision)||result.revision<before.revision||result.language!==wanted)throw Error(t('语言响应无效'));
        return {...result,previousRevision:before.revision};
    }finally{clearTimeout(timer);}
}
function setupAppearance(){const select=document.getElementById('appearance');if(!select)return;select.onchange=()=>{if(select.value==='system')document.documentElement.removeAttribute('data-theme');else document.documentElement.setAttribute('data-theme',select.value);};}
