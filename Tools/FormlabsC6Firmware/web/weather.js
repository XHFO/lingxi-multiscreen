// Browser geocoding only: no device tokens, credentials or forecast proxy.
function setupWeather(){
    const words={
        search:['查找城市','Find city'],hint:['输入城市名，选择匹配地点后自动填坐标、启用天气并加入轮转。','Enter a city, then choose a location to fill coordinates and enable weather rotation.'],
        privacy:['城市名发送至 Open-Meteo 查找地点，不发送设备凭据。','City names are sent to Open-Meteo for lookup. Device credentials are never sent.'],
        loading:['正在查找城市…','Looking up cities…'],choose:['请选择城市及所在地区：','Choose the city and region:'],empty:['未找到地点。试试英文名，或手动设置经纬度。','No locations found. Try an English name or set coordinates manually.'],
        error:['城市查询失败。请检查网络后重试，或手动设置经纬度。','City lookup failed. Check your network and retry, or set coordinates manually.'],
        selected:['坐标已填入，等待自动保存。','Coordinates filled. Waiting for automatic save.'],saved:['地点已保存。','Location saved.'],manual:['使用手动坐标，修改后自动保存。','Using manual coordinates. Changes save automatically.'],required:['请先选择匹配城市，或手动设置经纬度。','Choose a matching city or set coordinates manually.'],
        disabled:['天气未启用。','Weather is off.'],saving:['等待天气设置保存；未保存前不会改变设备查询地点。','Waiting for settings to save. Device location stays unchanged until saved.'],
        waiting_wifi:['设备等待 Wi-Fi 联网。','Device is waiting for Wi-Fi.'],waiting_memory:['设备等待可用资源。','Device is waiting for resources.'],fetching:['设备正在查询天气…','Device is fetching weather…'],cached:['设备已获取天气。','Device has received weather.'],retrying:['天气查询失败，设备稍后自动重试。','Weather lookup failed. Device will retry automatically.'],stale:['天气更新失败，保留最近数据并稍后重试。','Weather update failed. Last data retained; retrying later.'],offline:['无法读取设备天气状态，请检查设备连接。','Cannot read device weather status. Check the device connection.']
    };
    const w=key=>words[key][uiEnglish?1:0],city=$('city'),results=$('cityResults');
    let timer,controller,sequence=0,composing=false,required=false,key='hint',snapshot=null;
    function cancel(){clearTimeout(timer);controller?.abort();sequence++;}
    function render(){
        const match=saved&&saved.weather&&saved.weather_city===city.value.trim()&&saved.latitude===Number($('latitude').value)&&saved.longitude===Number($('longitude').value);
        $('citySearch').textContent=w('search');$('cityStatus').textContent=w(key==='selected'&&match?'saved':key);$('cityPrivacy').textContent=w('privacy');
        let phase='disabled';
        if($('weather_on').checked){
            phase=!match||required?'saving':!snapshot?'offline':snapshot.config_revision!==saved.revision?'fetching':snapshot.weather_phase;
            if(phase==='cached'&&!snapshot?.weather_cached)phase='fetching';
            if(phase==='retrying'&&snapshot?.weather_cached)phase='stale';
        }
        $('weatherStatus').textContent=w(words[phase]?phase:'fetching');
    }
    async function search(){
        cancel();const query=city.value.trim();results.replaceChildren();if(!query||composing){key='hint';render();return;}
        const current=sequence;controller=new AbortController();const abort=controller;
        const timeout=setTimeout(()=>abort.abort(),10000);key='loading';render();
        try{
            const url=new URL('https://geocoding-api.open-meteo.com/v1/search');url.search=new URLSearchParams({name:query,count:'5',language:uiEnglish?'en':'zh',format:'json'});
            const response=await fetch(url,{signal:abort.signal,credentials:'omit',referrerPolicy:'no-referrer'});
            if(!response.ok)throw Error();const data=await response.json();
            if(current!==sequence||!portalAlive)return;
            const places=(Array.isArray(data.results)?data.results:[]).filter(p=>typeof p.name==='string'&&encoder.encode(p.name).length<64&&Number.isFinite(p.latitude)&&Math.abs(p.latitude)<=90&&Number.isFinite(p.longitude)&&Math.abs(p.longitude)<=180).slice(0,5);
            key=places.length?'choose':'empty';
            for(const place of places){
                const button=document.createElement('button');button.type='button';
                const title=document.createElement('strong');title.textContent=place.name;
                const region=document.createElement('small');region.textContent=[...new Set([place.admin1,place.admin2,place.country].filter(Boolean))].join(' · ')+' · '+place.latitude.toFixed(4)+', '+place.longitude.toFixed(4);
                button.append(title,region);button.onclick=()=>{
                    cancel();city.value=place.name;$('latitude').value=place.latitude;$('longitude').value=place.longitude;
                    $('weather_on').checked=$('weather_rotate').checked=true;required=false;results.replaceChildren();key='selected';markDirty();render();
                };results.append(button);
            }
        }catch{if(current===sequence&&portalAlive)key='error';}
        finally{clearTimeout(timeout);if(current===sequence)render();}
    }
    function changed(){
        cancel();results.replaceChildren();required=!!city.value.trim()&&!(saved&&city.value.trim()===saved.weather_city&&Number($('latitude').value)===saved.latitude&&Number($('longitude').value)===saved.longitude);
        key='hint';render();if(!composing&&city.value.trim())timer=setTimeout(search,600);
    }
    city.addEventListener('input',changed);city.addEventListener('compositionstart',()=>{composing=true;cancel();results.replaceChildren();});city.addEventListener('compositionend',()=>{composing=false;changed();});
    city.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.isComposing&&!composing){e.preventDefault();search();}});
    $('citySearch').onclick=search;
    for(const id of ['latitude','longitude'])$(id).addEventListener('input',()=>{cancel();results.replaceChildren();required=false;key='manual';render();});
    $('weather_on').addEventListener('input',render);
    window.addEventListener('pagehide',cancel);render();
    return {render,health(result){snapshot=result;render();},reset(){cancel();required=false;key='hint';results.replaceChildren();},validate(){if(required)throw Error(w('required'));}};
}
