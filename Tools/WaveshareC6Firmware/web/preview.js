// Read the display owner's canonical RGB565 frame; no simulated HTML artwork.
let previewBusy=false,previewAlive=true,previewRevision='',previewTimer,previewAbort;
function previewOptions(config){const select=el('previewCard'),previous=select.value;select.replaceChildren();
    const option=(value,label)=>{const o=document.createElement('option');o.value=value;o.textContent=label;select.append(o);};
    option('auto',t('当前画面'));if(config.clock)option('clock',t(config.clock_style===1?'圆角粗数字':'翻页钟'));
    if(config.weather)option('weather',t('天气'));if(config.diagnostics)option('diagnostics',t('设备状态'));
    if(config.ha?.enabled&&config.ha.entities.length)for(let i=0;i<Math.ceil(config.ha.entities.length/4);i++)option('ha:'+i,'Home Assistant · '+(i+1));
    if(config.printers.filter(p=>p.enabled).length>=2)option('overview',t('打印机总览'));
    config.printers.forEach((p,i)=>{if(p.enabled)option('printer:'+i,(p.source_formlabs?'Formlabs':'Bambu Lab')+' · '+(p.name||p.serial));});
    select.value=Array.from(select.options||select.children).some(o=>o.value===previous)?previous:'auto';
}
function previewPixels(bytes,rotation){if(bytes.length!==115200||![0,90,180,270].includes(rotation))throw Error(t('预览画面无效'));
    const rgba=new Uint8ClampedArray(240*240*4);for(let y=0;y<240;y++)for(let x=0;x<240;x++){
        let sx=x,sy=y;if(rotation===90){sx=y;sy=239-x;}else if(rotation===180){sx=239-x;sy=239-y;}else if(rotation===270){sx=239-y;sy=x;}
        const from=(sy*240+sx)*2,to=(y*240+x)*4,v=bytes[from]*256+bytes[from+1];rgba[to]=Math.round((v>>11)*255/31);rgba[to+1]=Math.round(((v>>5)&63)*255/63);rgba[to+2]=Math.round((v&31)*255/31);rgba[to+3]=255;
    }return rgba;
}
async function refreshPreview(force=false){if(!previewAlive||previewBusy||busy||document.hidden||!authToken)return;
    previewBusy=true;previewAbort=new AbortController();const timeout=setTimeout(()=>previewAbort?.abort(),4000);
    try{const path='/api/frame'+(!force&&previewRevision?'?rev='+encodeURIComponent(previewRevision):'');
        const r=await fetch(path,{cache:'no-store',headers:{Authorization:'Bearer '+authToken},signal:previewAbort.signal});
        if(!previewAlive)return;if(r.status===401){authToken='';updateControls();throw Error(t('请重新读取设备配置'));}if(!r.ok)throw Error(t('无法读取设备画面'));
        if(r.status!==204){const bytes=new Uint8Array(await r.arrayBuffer());if(!previewAlive)return;const canvas=el('screenPreview'),context=canvas.getContext('2d'),data=context.createImageData(240,240);data.data.set(previewPixels(bytes,Number(r.headers.get('X-Lingxi-Rotation')||0)));context.putImageData(data,0,0);}
        previewRevision=r.headers.get('X-Lingxi-Frame-Revision')||'';
        translatedText(el('previewStatus'),r.headers.get('X-Lingxi-Asleep')==='1'?'设备已休眠 · 显示休眠前画面':'设备实际画面 · 每 3 秒刷新');
    }catch{if(previewAlive)translatedText(el('previewStatus'),'预览连接中断，保留最近画面');}finally{clearTimeout(timeout);previewAbort=null;previewBusy=false;}
}
async function showPreviewCard(card){if(busy||!authToken)return false;if(dirty)return status('请先保存当前修改，再切换设备画面。','error');
    if(previewBusy){previewAbort?.abort();while(previewBusy&&previewAlive)await new Promise(resolve=>setTimeout(resolve,30));}
    const [kind,index]=card.split(':'),query=new URLSearchParams({card:kind});if(index!==undefined)query.set('index',index);previewBusy=true;
    try{const r=await request('/api/view?'+query,{method:'POST',headers:{Authorization:'Bearer '+authToken}});if(!r.ok)throw Error(t(r.status===409?'请先退出设备设置，并确认卡片已保存启用':'无法切换设备画面'));previewRevision='';}
    catch(e){translatedText(el('previewStatus'),e.message);return false;}finally{previewBusy=false;}await refreshPreview(true);return true;
}
el('previewShow').onclick=()=>showPreviewCard(el('previewCard').value);el('previewAuto').onclick=()=>showPreviewCard('auto');el('previewRefresh').onclick=()=>refreshPreview(true);
async function previewLoop(){await refreshPreview();if(previewAlive)previewTimer=setTimeout(previewLoop,3000);}previewTimer=setTimeout(previewLoop,1000);
window.addEventListener('pagehide',()=>{previewAlive=false;clearTimeout(previewTimer);previewAbort?.abort();});
window.addEventListener('pageshow',event=>{if(event.persisted){previewAlive=true;previewRevision='';clearTimeout(previewTimer);previewTimer=setTimeout(previewLoop,1000);translatedText(el('previewStatus'),'请重新读取设备配置');}});
