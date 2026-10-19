// Check actual ESP32-C6 compiler stack-usage reports after a firmware build.
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const root=new URL('../',import.meta.url).pathname;
const build=root+'Tools/WaveshareC6Firmware/.pio/build/waveshare-c6/';
function frames(file){return readFileSync(build+file,'utf8').trim().split('\n').map(line=>{
  const [location,bytes,kind]=line.split('\t');return {name:location.split(':').at(-1),bytes:Number(bytes),kind};
});}
// -Os may inline a helper or emit .constprop/.part clones. Check the actual
// surviving caller's combined frame instead; never silently skip missing names.
// The local-display dispatcher now includes unified sleep/options bookkeeping:
// its measured 272B frame is bounded at 320B; this is not a total task-stack check.
const limits={menu_build:512,menu_gesture:512,menu_render:512,local_display:768,local_display_work:320,native_card_handler:512,base_software_allowed:256,standalone_lan_pairing_allowed:512,health_handler:256,preview_frame_handler:256,terminal_view_handler:256,draw_clock:256};
const all=[...frames('src/main.c.su'),...frames('src/local_updates.c.su')];
const commands=JSON.parse(readFileSync(build+'compile_commands.json','utf8'));
const sizeOptimized=commands.filter(x=>/\/(main|standalone|local_updates)\.c$/.test(x.file)).length===3
  && commands.filter(x=>/\/(main|standalone|local_updates)\.c$/.test(x.file)).every(x=>/\s-Os(?:\s|$)/.test(x.command));
const inlined={menu_gesture:[['button_handler',512]],menu_render:[['local_display',768]],
  base_software_allowed:[['software_allowed',256],['software_handler',256],['simulation_handler',256],['native_card_handler',512]]};
function checkedFrame(reports,name,limit){
  const matches=reports.filter(x=>x.name.split('.')[0]===name);assert(matches.length,`Missing stack report for ${name}`);
  // Conservatively sum split/clone frames: even if exclusive, all remain bounded.
  for(const f of matches)assert.equal(f.kind,'static',`${name}: unbounded task stack`);
  const bytes=matches.reduce((sum,f)=>sum+f.bytes,0);
  assert(bytes<=limit,`${name}: ${bytes} exceeds ${limit} byte budget`);
  console.log(`${name}: ${bytes} bytes (budget ${limit})`);
}
for(const [name,limit] of Object.entries(limits)){
  if(all.some(x=>x.name.split('.')[0]===name))checkedFrame(all,name,limit);
  else {
    assert(sizeOptimized&&inlined[name],`Missing stack report for ${name}`);
    for(const [caller,budget]of inlined[name])checkedFrame(all,caller,budget);
    console.log(`${name}: inlined; actual -Os callers verified`);
  }
}
console.log('C6 actual compiler: bounded menu/display/health stack budgets passed');
const configFrames=frames('src/standalone.c.su');
for(const [name,limit] of Object.entries({handler:256,standalone_save_display:256,config_json_encode:128,config_json_document:128})){
  checkedFrame(configFrames,name,limit);
}
// The display wrapper delegates to this new unified-options saver under -Os.
if(sizeOptimized)checkedFrame(configFrames,'standalone_save_monitor_display',256);
