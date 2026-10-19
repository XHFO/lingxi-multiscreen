import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source=readFileSync(new URL('../web/preview.js',import.meta.url),'utf8');
const els=new Map();const element=id=>{if(!els.has(id))els.set(id,{textContent:'',value:'auto',options:[],replaceChildren(){this.options=[];},append(o){this.options.push(o);},getContext(){return {createImageData:()=>({data:new Uint8ClampedArray(230400)}),putImageData(data){assert.equal(data.data.length,230400);}};}});return els.get(id);};
let hidden=false,calls=0,resolveFetch,lastOptions;const timers=[];
const context=vm.createContext({Uint8ClampedArray,Uint8Array,URLSearchParams,AbortController,encodeURIComponent,
    $:element,t:text=>text,translatedText:(el,text)=>{el.textContent=text;},token:'fixture-only',busy:false,
    document:{get hidden(){return hidden;},createElement:()=>({}),querySelectorAll:()=>[]},window:{addEventListener(){}},
    setTimeout(fn){timers.push(fn);return timers.length;},clearTimeout(){},
    request:async()=>({ok:true}),fetch(path,options){calls++;lastOptions=options;return new Promise(r=>{resolveFetch=r;});}
});vm.runInContext(source,context);
for(const count of [0,1,2,3]){
    context.config={clock:true,weather:true,printers:Array.from({length:count},(_,i)=>({enabled:i===0,name:'User '+i}))};
    vm.runInContext('previewOptions(config)',context);
    assert.equal(element('previewCard').options.filter(o=>o.value==='overview').length,count>=2?1:0);
}
element('previewCard').value='overview';context.config={printers:[{enabled:true,name:'User'}]};
vm.runInContext('previewOptions(config)',context);assert.equal(element('previewCard').value,'auto');
assert(!element('previewCard').options.some(o=>o.value==='demo'));
context.config={printers:[{enabled:true,name:'',serial:';;tex_2'},{enabled:true,name:'Real',serial:'FORM_REAL'}]};
vm.runInContext('previewOptions(config)',context);
assert(element('previewCard').options.some(o=>o.value==='printer:0'&&o.textContent===';;tex_2'));
assert(element('previewCard').options.some(o=>o.value==='overview'));
const bytes=new Uint8Array(115200);for(let i=0;i<57600;i++){const v=i%65536;bytes[i*2]=v>>8;bytes[i*2+1]=v&255;}context.bytes=bytes;
for(const angle of [0,90,180,270]){
    context.angle=angle;const rgba=vm.runInContext('previewPixels(bytes,angle)',context);assert.equal(rgba.length,230400);
    for(const [x,y] of [[0,0],[239,0],[0,239],[239,239],[72,158],[120,115]]){
        let index=y*240+x;if(angle===90)index=(239-x)*240+y;if(angle===180)index=(239-y)*240+239-x;if(angle===270)index=x*240+239-y;
        const v=index%65536,to=(y*240+x)*4;assert.equal(rgba[to],Math.round((v>>11)*255/31));assert.equal(rgba[to+1],Math.round(((v>>5)&63)*255/63));assert.equal(rgba[to+2],Math.round((v&31)*255/31));assert.equal(rgba[to+3],255);
    }
}assert.throws(()=>vm.runInContext('previewPixels(bytes,45)',context));
const p=vm.runInContext('refreshPreview()',context);await vm.runInContext('refreshPreview()',context);assert.equal(calls,1);
resolveFetch({ok:true,status:200,headers:new Map([['X-Lingxi-Rotation','90'],['X-Lingxi-Frame-Revision','10'],['X-Lingxi-Asleep','0']]),arrayBuffer:async()=>bytes.buffer});await p;
const q=vm.runInContext('refreshPreview()',context);resolveFetch({ok:true,status:204,headers:new Map([['X-Lingxi-Frame-Revision','10'],['X-Lingxi-Asleep','1']])});await q;
assert(element('previewStatus').textContent.includes('休眠'));assert.equal(lastOptions.headers.Authorization,'Bearer fixture-only');
hidden=true;await vm.runInContext('refreshPreview()',context);assert.equal(calls,2);hidden=false;
vm.runInContext('previewAlive=false',context);await vm.runInContext('refreshPreview()',context);assert.equal(calls,2);
assert(!/localStorage|sessionStorage|Math.random|new Date/.test(source));
console.log('Formlabs real-frame preview: exact RGB565/4 rotations, single in-flight request, 204, sleep and hidden/pagehide guards passed');
