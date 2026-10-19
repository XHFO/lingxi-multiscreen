// One canonical device frame, no web imitation or sample data. Serial requests
// and revision-based 204 responses bound the HTTP/display owner's workload.
let previewBusy=false,previewAlive=true,previewRevision='',previewTimer,previewAbort;
function previewOptions(config){
    const select=$('previewCard'),previous=select.value;select.replaceChildren();
    function option(value,label){const o=document.createElement('option');o.value=value;o.textContent=label;select.append(o);}
    option('auto',t('当前画面'));if(config.clock)option('clock',t('翻页钟'));if(config.weather)option('weather',t('天气'));
    if(config.printers.length>=2)option('overview',t('打印机总览'));
    config.printers.forEach((p,i)=>{if(p.enabled)option('printer:'+i,p.name||p.serial);});
    select.value=Array.from(select.options).some(o=>o.value===previous)?previous:'auto';
}
function previewPixels(bytes,rotation){
    if(bytes.length!==115200||![0,90,180,270].includes(rotation))throw Error(t('预览画面无效'));
    const rgba=new Uint8ClampedArray(240*240*4);
    for(let y=0;y<240;y++)for(let x=0;x<240;x++){
        let sx=x,sy=y;if(rotation===90){sx=y;sy=239-x;}else if(rotation===180){sx=239-x;sy=239-y;}else if(rotation===270){sx=239-y;sy=x;}
        const from=(sy*240+sx)*2,to=(y*240+x)*4,v=bytes[from]*256+bytes[from+1];
        rgba[to]=Math.round((v>>11)*255/31);rgba[to+1]=Math.round(((v>>5)&63)*255/63);rgba[to+2]=Math.round((v&31)*255/31);rgba[to+3]=255;
    }return rgba;
}
async function refreshPreview(force=false){
    if(!previewAlive||previewBusy||busy||document.hidden||!token)return;
    previewBusy=true;previewAbort=new AbortController();const timeout=setTimeout(()=>previewAbort?.abort(),4000);
    try{
        const path='/api/frame'+(!force&&previewRevision?'?rev='+encodeURIComponent(previewRevision):'');
        const r=await fetch(path,{cache:'no-store',headers:{Authorization:'Bearer '+token},signal:previewAbort.signal});
        if(!previewAlive)return;if(r.status===401){token='';throw Error(t('请重新读取设备配置'));}
        if(!r.ok)throw Error(t('无法读取设备画面'));
        if(r.status!==204){const bytes=new Uint8Array(await r.arrayBuffer());if(!previewAlive)return;
            const pixels=previewPixels(bytes,Number(r.headers.get('X-Lingxi-Rotation')||0));
            const canvas=$('screenPreview'),context=canvas.getContext('2d');const data=context.createImageData(240,240);data.data.set(pixels);context.putImageData(data,0,0);
        }
        previewRevision=r.headers.get('X-Lingxi-Frame-Revision')||'';
        translatedText($('previewStatus'),r.headers.get('X-Lingxi-Asleep')==='1'?'设备已休眠 · 显示休眠前画面':'设备实际画面 · 每 3 秒刷新');
    }catch(e){if(previewAlive)translatedText($('previewStatus'),'预览连接中断，保留最近画面');}
    finally{clearTimeout(timeout);previewAbort=null;previewBusy=false;}
}
async function showPreviewCard(card){
    if(busy||!token)return false;
    if(previewBusy){previewAbort?.abort();while(previewBusy&&previewAlive)await new Promise(resolve=>setTimeout(resolve,30));}
    const [kind,index]=card.split(':');const query=new URLSearchParams({card:kind});if(index!==undefined)query.set('index',index);
    previewBusy=true;
    try{const r=await request('/api/view?'+query,{method:'POST',headers:{Authorization:'Bearer '+token}});
        if(!r.ok)throw Error(t(r.status===409?'请先退出设备设置，并确认卡片已保存启用':'无法切换设备画面'));
        previewRevision='';
    }catch(e){translatedText($('previewStatus'),e.message);return false;}
    finally{previewBusy=false;}
    await refreshPreview(true);return true;
}
$('previewShow').onclick=()=>showPreviewCard($('previewCard').value);
$('previewAuto').onclick=()=>showPreviewCard('auto');$('previewRefresh').onclick=()=>refreshPreview(true);
async function previewLoop(){await refreshPreview();if(previewAlive)previewTimer=setTimeout(previewLoop,3000);}
previewTimer=setTimeout(previewLoop,1000);
window.addEventListener('pagehide',()=>{previewAlive=false;clearTimeout(previewTimer);previewAbort?.abort();});
// Every quick link names a real section on the dedicated page. Do not reuse
// generic C6 anchors (#home, #bambu, #weatherSection) or a stale .local host.
for(const link of document.querySelectorAll('nav a'))link.addEventListener('click',()=>{
    if(link.hash)for(const other of document.querySelectorAll('nav a')){other.removeAttribute('aria-current');if(other===link)other.setAttribute('aria-current','location');}
});
