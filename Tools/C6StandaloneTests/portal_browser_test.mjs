// Isolated browser checks: all URLs use local fixtures; no C6 or cloud is contacted.
import {readFileSync,mkdirSync} from 'node:fs';
import {strict as assert} from 'node:assert';
import {pathToFileURL} from 'node:url';
let runtime;
try { runtime=await import('playwright'); }
catch (cause) {
 const runtimePath=process.env.LINGXI_PLAYWRIGHT_PATH;
 if(!runtimePath)throw new Error('Install playwright or set LINGXI_PLAYWRIGHT_PATH to its module entry point',{cause});
 runtime=await import(pathToFileURL(runtimePath));
}
const output=process.argv[2]||'/private/tmp/lingxi-c6-web-review';mkdirSync(output,{recursive:true});
const directory=new URL('../WaveshareC6Firmware/src/',import.meta.url);
const decode=name=>[...readFileSync(new URL(name+'_portal.h',directory),'utf8').matchAll(/^"(?:[^"\\]|\\.)*"/gm)].map(m=>JSON.parse(m[0])).join('');
const pages={standalone:decode('standalone'),wifi:decode('wifi')};
const original={schema_version:2,revision:4,enabled:true,local_first:false,card_mask:15,clock:true,clock_style:1,digit_style:1,language:0,flip_animation:true,saturation_percent:100,contrast_percent:100,diagnostics:true,rotation:0,brightness:80,interval:15,timezone:28800,weather:true,latitude:31.23,longitude:121.47,weather_city:'上海',weather_minutes:30,sleep_mode:0,sleep_idle_minutes:5,sleep_start:1380,sleep_end:420,sleep_keep_printing:true,
ha:{enabled:true,host:'192.168.1.10',port:8123,tls:false,token_set:true,entities:[{id:'sensor.living_room_temperature',name:'客厅温度'},{id:'sensor.study_humidity',name:'书房湿度'}]},
printers:[{enabled:true,rotate:true,name:'工作室 X2D',serial:'fixture_x2d',source_ha:true,source_formlabs:false,host:'',trust_lan:false,certificate:'',status_entity:'sensor.x2d_print_status',progress_entity:'sensor.x2d_print_progress',task_entity:'sensor.x2d_task_name',remaining_entity:'sensor.x2d_remaining_time',image_entity:'image.x2d_cover',show_status:true,show_progress:true,show_task:true,show_remaining:true,show_image:true,access_code_set:false,card_style:0,time_mode:0}]};
const engine=process.env.LINGXI_WEBKIT==='1'?'webkit':'chromium';
const browser=await runtime[engine].launch(engine==='webkit'?{headless:true}:{headless:true,executablePath:process.env.LINGXI_CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args:['--disable-background-networking','--disable-sync','--no-first-run']});
try{
for(const appearance of ['light','dark'])for(const width of [1280,390,320].filter(w=>!process.env.LINGXI_WEB_WIDTH||w===Number(process.env.LINGXI_WEB_WIDTH))){
 let cfg=structuredClone(original),lastSaved,wifiBody,scanCount=0,putCount=0,activeWrites=0,maxWrites=0,failNext=0,writeDelay=0,frameCount=0,viewCount=0,lastView,languageWrites=0;
 const context=await browser.newContext({viewport:{width,height:900},colorScheme:appearance,reducedMotion:'reduce'}),page=await context.newPage(),errors=[],external=[];
 page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
 // A generated display fixture makes screenshots readable, but is not a real device capture.
 const frame=Buffer.from(await page.evaluate(()=>{
  const c=document.createElement('canvas');c.width=c.height=240;const x=c.getContext('2d');x.fillStyle='#090b0e';x.fillRect(0,0,240,240);x.fillStyle='#c2c7ce';x.font='600 16px system-ui';x.fillText('XH MULTISCREEN',16,28);x.fillStyle='#ff7e35';x.font='900 72px system-ui';x.fillText('74',18,119);x.font='700 24px system-ui';x.fillText('%',118,119);x.fillStyle='#282d35';x.fillRect(16,140,208,4);x.fillStyle='#ff7e35';x.fillRect(16,140,154,4);x.fillStyle='#eff1f5';x.font='600 18px system-ui';x.fillText('FORM 4 · PRINTING',16,177);x.fillStyle='#aeb6c1';x.font='16px system-ui';x.fillText('ETA 14 min',16,213);const rgba=x.getImageData(0,0,240,240).data,out=[];for(let i=0;i<rgba.length;i+=4){const v=(Math.round(rgba[i]*31/255)<<11)|(Math.round(rgba[i+1]*63/255)<<5)|Math.round(rgba[i+2]*31/255);out.push(v>>8,v&255);}out[0]=0xf8;out[1]=0;out[478]=0;out[479]=0x1f;out[114720]=7;out[114721]=0xe0;out[115198]=255;out[115199]=255;return out;
 }));
 await page.route('**/*',async route=>{
  const request=route.request(),url=new URL(request.url()),json=(body,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)});
  if(url.hostname!=='c6.test'){external.push(request.url());return route.abort();}
  if(url.pathname==='/standalone')return route.fulfill({contentType:'text/html',body:pages.standalone});
  if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:pages.wifi});
  if(url.pathname==='/api/info')return json({ip:'192.168.1.24',fw:'2.0.0-alpha.19',wifi_connected:true,setup_ap:false,language:cfg.language,revision:cfg.revision});
  if(url.pathname==='/api/pair'){assert.deepEqual(JSON.parse(request.postData()),{mode:'lan'});assert.equal(request.headers()['x-lingxi-lan'],'1');return json({token:'1234abcd1234abcd'});}
  if(url.pathname==='/api/language'){languageWrites++;const body=JSON.parse(request.postData());assert.equal(request.headers()['x-xh-language'],'1');if(body.revision!==cfg.revision)return json({error:'conflict'},409);cfg.language=body.language;cfg.revision++;return json({language:cfg.language,revision:cfg.revision});}
  if(url.pathname==='/api/standalone'){
   assert.equal(request.headers().authorization,'Bearer 1234abcd1234abcd');
   if(request.method()==='PUT'){putCount++;activeWrites++;maxWrites=Math.max(maxWrites,activeWrites);const body=JSON.parse(request.postData());if(writeDelay)await new Promise(r=>setTimeout(r,writeDelay));activeWrites--;
    if(failNext){const failure=failNext;failNext=0;if(failure===409)cfg.revision++;return json({reason:failure===500?'low_memory':'conflict'},failure);}
    if(body.revision!==cfg.revision)return json({reason:'conflict'},409);
    lastSaved=structuredClone(body);cfg=structuredClone(body);cfg.revision++;if(cfg.ha.token)cfg.ha.token_set=true;delete cfg.ha.token;for(const p of cfg.printers){if(p.access_code)p.access_code_set=true;if(p.form_client_secret)p.form_credentials_set=true;delete p.access_code;delete p.form_client_secret;}
   }return json(cfg);
  }
  if(url.pathname==='/api/health')return json({snapshot_available:true,printers:cfg.printers.map(p=>({brand:p.brand||(p.source_formlabs?'formlabs':'bambu'),name:p.name,serial:p.serial,phase:'connected',connected:true,status:'printing',progress:74,progress_valid:true}))});
  if(url.pathname==='/api/frame'){frameCount++;const headers={'X-Lingxi-Rotation':String(cfg.rotation),'X-Lingxi-Frame-Revision':'12','X-Lingxi-Asleep':'0'};if(url.searchParams.get('rev')==='12')return route.fulfill({status:204,headers});return route.fulfill({contentType:'application/octet-stream',headers,body:frame});}
  if(url.pathname==='/api/view'){viewCount++;lastView=url.searchParams;return json({ok:true});}
  if(url.pathname==='/api/wifi/scan')return json(++scanCount===1?{busy:true}:{busy:false,networks:[{ssid:'Studio 2.4G',rssi:-40,open:false},{ssid:'W'.repeat(32),rssi:-68,open:true},{ssid:'<img src=x onerror=alert(1)>',rssi:-80,open:false}]});
  if(url.pathname==='/wifi'){wifiBody=new URLSearchParams(request.postData());assert.equal(request.headers()['x-xh-wifi'],'1');return route.fulfill({body:'Saved'});}
  return route.abort();
 });
 await page.goto('http://c6.test/standalone');await page.waitForFunction(()=>!document.getElementById('options').disabled);await page.waitForTimeout(1000);assert.equal(putCount,0,'initial loading must never save');
 assert.equal(await page.locator('#pin').count(),0);assert.equal(await page.locator('#ota').count(),0,'OTA stays in app Device management');assert.equal(await page.locator('#ha_token').inputValue(),'');
 await page.locator('#previewRefresh').click();await page.waitForFunction(()=>document.getElementById('previewStatus').textContent.includes('设备实际画面'));assert.ok(frameCount>0);
 assert.deepEqual(await page.locator('#screenPreview').evaluate(c=>Array.from(c.getContext('2d').getImageData(0,0,1,1).data)),[255,0,0,255]);
 assert.equal(await page.locator('#previewCard option[value=overview]').count(),0);
 // Valid edits automatically save; manual retry isn't needed.
 await page.locator('#weather_city').fill('自动保存测试');await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已保存'));assert.equal(cfg.weather_city,'自动保存测试');assert.ok(putCount>0);
 // A background save must not steal newly selected focus or rebuild controls.
 await page.locator('.printer-details').first().locator('summary').click();
 const retainedSource=await page.locator('#p_source_0').elementHandle(),retainedDetails=await page.locator('.printer-details').first().elementHandle();
 writeDelay=500;await page.locator('#weather_city').fill('背景保存保留焦点');
 await page.waitForFunction(()=>document.getElementById('status').textContent.includes('正在保存'));
 await page.locator('#clock_style').focus();
 await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已保存'));
 assert.equal(await page.evaluate(()=>document.activeElement.id),'clock_style','background saving must not restore the field that was focused at request start');
 assert.equal(await retainedSource.evaluate(e=>e===document.getElementById('p_source_0')),true,'save completion retains the actual source select node');
 assert.equal(await retainedDetails.evaluate(e=>e===document.querySelector('.printer-details')&&e.open),true,'save completion retains an open details node');
 await page.locator('.printer-details').first().locator('summary').click();writeDelay=0;
 // Edit while the first save is in flight; the older response may not overwrite it.
 writeDelay=500;const count=putCount;await page.locator('#weather_city').fill('第一轮');
 await page.waitForFunction(()=>document.getElementById('status').textContent.includes('正在保存'));await page.locator('#weather_city').fill('最新一轮');await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已保存'));await page.waitForTimeout(350);
 assert.equal(cfg.weather_city,'最新一轮');assert.equal(await page.locator('#weather_city').inputValue(),'最新一轮');assert.ok(putCount>=count+2);assert.equal(maxWrites,1);writeDelay=0;
 failNext=500;await page.locator('#weather_city').fill('失败保留草稿');await page.waitForFunction(()=>document.getElementById('status').textContent.includes('内存不足'));assert.equal(await page.locator('#weather_city').inputValue(),'失败保留草稿');assert.equal(await page.evaluate(()=>dirty),true);await page.locator('#save').click();await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已保存'));assert.equal(cfg.weather_city,'失败保留草稿');
 failNext=409;await page.locator('#weather_city').fill('冲突保留草稿');await page.waitForFunction(()=>document.getElementById('status').textContent.includes('重新读取'));const conflicts=putCount;await page.waitForTimeout(1000);assert.equal(putCount,conflicts,'CAS conflict must not auto overwrite');assert.equal(await page.locator('#weather_city').inputValue(),'冲突保留草稿');await page.locator('#reload').click();await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已读取'));
 // Incomplete HA credentials may report an error, but never pull focus away
 // from the clock style or scroll the user back to the credentials section.
 const incompleteHAWrites=putCount;await page.locator('#ha_host').fill('192.168.1.11');await page.locator('#clock_style').selectOption('0');await page.locator('#clock_style').focus();const incompleteHAScroll=await page.evaluate(()=>window.scrollY);
 await page.waitForFunction(()=>document.getElementById('status').textContent.includes('长期访问令牌'));
 assert.equal(await page.evaluate(()=>document.activeElement.id),'clock_style','automatic HA validation does not steal focus');
 assert.ok(Math.abs(await page.evaluate(()=>window.scrollY)-incompleteHAScroll)<=1,'automatic HA validation does not scroll');assert.equal(putCount,incompleteHAWrites);assert.equal(await page.locator('#clock_style').inputValue(),'0');
 await page.locator('#reload').click();await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已读取'));
 await page.locator('#ha_host').fill('8.8.8.8');await page.locator('#saveBottom').click();assert.equal(await page.evaluate(()=>document.activeElement.id),'ha_host');assert.ok(await page.locator('#fieldError').isVisible());
 // Language uses its own CAS write even with an unfinished/invalid configuration.
 const fullWrites=putCount;await page.locator('#pageLanguage').selectOption('1');await page.waitForFunction(()=>document.getElementById('languageStatus').textContent.includes('synced'));assert.equal(languageWrites,1);assert.equal(putCount,fullWrites);assert.equal(await page.locator('h1').textContent(),'Device settings');assert.equal(cfg.language,1);await page.locator('#reload').click();await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('Device settings loaded'));
 await page.locator('#pageLanguage').selectOption('0');await page.waitForFunction(()=>document.getElementById('languageStatus').textContent.includes('已同步'));
 assert.match(await page.locator('#addPrinter').textContent(),/Bambu Lab/);assert.match(await page.locator('#addFormPrinter').textContent(),/Formlabs/);
 await page.locator('#addFormPrinter').click();assert.equal(await page.locator('#p_source_1').inputValue(),'formlabs');assert.equal(await page.locator('#p_form_1').isVisible(),true);assert.equal(await page.locator('#p_ha_1').isVisible(),false);assert.equal(await page.locator('#p_mqtt_1').isVisible(),false);
 await page.locator('#p_name_1').fill('工作室 Form 4');await page.locator('#p_form_serial_1').fill('fixture_x2d');const incompleteFormWrites=putCount;
 await page.locator('#clock_style').selectOption('0');await page.locator('#clock_style').focus();const incompleteFormScroll=await page.evaluate(()=>window.scrollY);
 await page.waitForFunction(()=>document.getElementById('status').textContent.includes('Client ID'));
 assert.equal(await page.evaluate(()=>document.activeElement.id),'clock_style','unfinished Formlabs credentials do not steal focus');assert.ok(Math.abs(await page.evaluate(()=>window.scrollY)-incompleteFormScroll)<=1,'unfinished Formlabs credentials do not scroll');assert.equal(putCount,incompleteFormWrites);assert.equal(await page.locator('#clock_style').inputValue(),'0');
 await page.locator('#p_form_id_1').fill('fixture-client');await page.locator('#clock_style').selectOption('1');await page.locator('#clock_style').focus();
 await page.waitForFunction(()=>document.getElementById('status').textContent.includes('Client Secret'));assert.equal(await page.evaluate(()=>document.activeElement.id),'clock_style','missing Formlabs Secret does not steal focus');assert.equal(putCount,incompleteFormWrites);
 const retainedFormSecret=await page.locator('#p_form_secret_1').elementHandle(),retainedFormSecretHelp=await page.locator('#p_form_secret_1_help').elementHandle();
 await page.locator('#p_form_secret_1').fill('fixture-secret');await page.locator('#save').click();await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已保存'));
 assert.equal(cfg.printers.length,2);assert.equal(lastSaved.printers[0].brand,'bambu');assert.equal(lastSaved.printers[1].brand,'formlabs');assert.equal(lastSaved.printers[0].serial,lastSaved.printers[1].serial);assert.equal(lastSaved.printers[1].access_code,undefined);assert.equal(lastSaved.printers[1].status_entity,'');assert.equal(await page.locator('#p_form_secret_1').inputValue(),'');assert.ok(!(await page.locator('#json').textContent()).includes('fixture-secret'));
 assert.equal(await page.locator('#p_brandlabel_1').textContent(),'Formlabs · 工作室 Form 4','save updates the user device name in the printer heading');assert.match(await page.locator('#p_form_secret_1_help').textContent(),/同一打印机与 Client ID 留空保留/,'saved Secret indicator updates immediately');
 assert.equal(await retainedFormSecret.evaluate(e=>e===document.getElementById('p_form_secret_1')),true,'metadata feedback never replaces the Secret input');assert.equal(await retainedFormSecretHelp.evaluate(e=>e===document.getElementById('p_form_secret_1_help')),true,'metadata feedback changes existing helper text in place');
 assert.equal(await page.locator('#previewCard option[value=overview]').count(),1);await page.locator('#previewCard').selectOption('overview');const viewWrites=putCount;await page.locator('#previewShow').click();assert.ok(viewCount>0);assert.equal(lastView.get('card'),'overview');assert.equal(putCount,viewWrites,'preview selection never saves configuration');
 await page.locator('.printer-details').first().locator('summary').click();await page.locator('#p_card_style_0').selectOption('1');await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已保存'));assert.equal(cfg.printers[0].card_style,1);assert.equal(await page.locator('#p_show_image_0').isDisabled(),true);assert.equal(cfg.printers[0].show_image,true,'style must retain saved image choice');
 await page.locator('#rotation').selectOption('90');await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已保存'));await page.locator('#previewRefresh').click();await page.waitForFunction(()=>document.getElementById('screenPreview').getContext('2d').getImageData(0,0,1,1).data[1]===255);assert.equal(cfg.rotation,90);
 await page.locator('#sleep_mode').selectOption('2');await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已保存'));assert.equal(cfg.sleep_mode,2);assert.equal(cfg.sleep_start,1380);assert.equal(cfg.sleep_end,420);
 for(const anchor of await page.locator('nav a[href^="#"]').evaluateAll(es=>es.map(e=>e.hash.slice(1))))assert.equal(await page.locator('#'+anchor).count(),1,'every quick link exists');
 const overflow=()=>page.evaluate(()=>document.documentElement.scrollWidth>document.documentElement.clientWidth+1);assert.equal(await overflow(),false,appearance+' '+width+' no overflow');
 const minimum=await page.locator('button,input:not([type=checkbox]),select').evaluateAll(es=>Math.min(...es.filter(e=>e.getBoundingClientRect().height>0).map(e=>e.getBoundingClientRect().height)));assert.ok(minimum>=43.9,'44px controls');
 await page.locator('#ha_host').focus();assert.equal(await page.locator('#ha_host').evaluate(e=>getComputedStyle(e).outlineWidth),'3px');
 if(width===320){await page.evaluate(()=>document.documentElement.style.fontSize='32px');if(await overflow())console.log(await page.evaluate(()=>({scroll:document.documentElement.scrollWidth,client:document.documentElement.clientWidth,nav:{rect:document.querySelector('nav').getBoundingClientRect().toJSON(),overflow:getComputedStyle(document.querySelector('nav')).overflow},outside:[...document.querySelectorAll('body *')].filter(e=>e.getBoundingClientRect().right>321&&e.getBoundingClientRect().height>0).map(e=>({tag:e.tagName,id:e.id,class:e.className,right:e.getBoundingClientRect().right,text:e.textContent.slice(0,80)}))})));assert.equal(await overflow(),false,'200% text at 320px');await page.evaluate(()=>document.documentElement.style.fontSize='');}
 // Representative screenshots show the default readable orientation, not the 90° assertion state.
 await page.locator('#rotation').selectOption('0');await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('已保存'));await page.locator('#previewRefresh').click();await page.waitForFunction(()=>document.getElementById('screenPreview').getContext('2d').getImageData(0,0,1,1).data[0]===255);
 await page.locator('#bambu').screenshot({path:output+'/printer-brands-'+appearance+'-'+width+'.png'});await page.evaluate(()=>{document.activeElement?.blur();document.querySelector('nav').scrollLeft=0;window.scrollTo(0,0);});await page.screenshot({path:output+'/standalone-top-'+appearance+'-'+width+'.png'});await page.screenshot({path:output+'/standalone-'+appearance+'-'+width+'.png',fullPage:true});
 await page.goto('http://c6.test/');await page.locator('#scan').click();await page.waitForFunction(()=>document.querySelectorAll('#networks button').length===3);assert.equal(await page.locator('#networks img').count(),0);
 assert.equal(await page.locator('#continueSetup').getAttribute('href'),'http://192.168.1.24/standalone#preview');assert.equal(await page.locator('nav a[href$="#home"]').getAttribute('href'),'http://192.168.1.24/standalone#home','LAN handoff never keeps setup AP address');
 await page.locator('#password').fill('must-clear');await page.getByRole('button',{name:/Studio 2.4G/}).click();assert.equal(await page.locator('#password').inputValue(),'');await page.locator('#password').fill('test-password');await page.locator('#connect').click();await page.waitForFunction(()=>document.getElementById('status').textContent.startsWith('网络设置已保存'));assert.equal(wifiBody.get('ssid'),'Studio 2.4G');assert.equal(wifiBody.get('password'),'test-password');assert.equal(await page.locator('#password').inputValue(),'');assert.equal(await overflow(),false,'Wi-Fi and legal SSID no overflow');
 await page.locator('#pageLanguage').selectOption('1');await page.waitForFunction(()=>document.getElementById('languageStatus').textContent.includes('synced'));assert.equal(await page.locator('h1').textContent(),'Wi-Fi setup');await page.locator('#pageLanguage').selectOption('0');await page.waitForFunction(()=>document.getElementById('languageStatus').textContent.includes('已同步'));
 await page.evaluate(()=>{document.activeElement?.blur();document.querySelector('nav').scrollLeft=0;window.scrollTo(0,0);});
 assert.equal(await page.locator('nav').evaluate(nav=>{const link=nav.querySelector('a'),n=nav.getBoundingClientRect(),a=link.getBoundingClientRect();return a.left>=n.left-1&&a.right<=n.right+1;}),true,'first mobile navigation item remains visible');
 await page.screenshot({path:output+'/wifi-'+appearance+'-'+width+'.png',fullPage:true});await page.screenshot({path:output+'/wifi-top-'+appearance+'-'+width+'.png'});
 assert.deepEqual(errors,[]);assert.deepEqual(external,[]);await context.close();console.log('C6 '+engine+' '+appearance+' '+width+': stable nodes/focus, non-stealing HA/Formlabs validation, direct cloud entry, autosave/CAS/failed drafts, language, RGB565/90°/overview, keyboard/44px/overflow passed');
}
}finally{await browser.close();}
console.log('All network responses and display frames were fixtures, not physical hardware. Screenshots: '+output);
