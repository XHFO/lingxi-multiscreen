import {readFileSync, writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {gzipSync} from 'node:zlib';
import vm from 'node:vm';
const web = new URL('../Tools/WaveshareC6Firmware/web/', import.meta.url);
const style = readFileSync(new URL('portal.css', web), 'utf8');
const check = process.argv.includes('--check');
for (const [page, variable, header] of [['standalone', 'standalone_portal', 'standalone_portal.h'], ['wifi', 'portal', 'wifi_portal.h']]) {
    let html = readFileSync(new URL(page+'.html', web), 'utf8').replace('/* PORTAL_STYLE */', style);
    for(const [marker,file] of [['AUTOSAVE','autosave.js'],['PREVIEW','preview.js']]){
        if(html.includes('/* PORTAL_'+marker+' */'))html=html.replace('/* PORTAL_'+marker+' */',readFileSync(new URL(file,web),'utf8'));
    }
    let i18n=readFileSync(new URL('i18n.js',web),'utf8');
    const dictionary=i18n.match(/const uiStrings=(\{[\s\S]*?\n\});/);
    if(!dictionary)throw Error('Missing UI dictionary');
    const extra=i18n.match(/Object\.assign\(uiStrings,(\{[\s\S]*?\n\})\);/);
    const strings=vm.runInNewContext('('+dictionary[1]+')');if(extra)Object.assign(strings,vm.runInNewContext('('+extra[1]+')'));
    const shared=i18n.slice(dictionary.index+dictionary[0].length).replace(extra?.[0]||'','');
    const used=Object.fromEntries(Object.entries(strings).filter(([key])=>(html+shared).includes(key)));
    i18n=i18n.replace(dictionary[0],'const uiStrings='+JSON.stringify(used)+';').replace(extra?.[0]||'','');
    html=html.replace('/* PORTAL_I18N */',i18n);
    // Browser-side gzip avoids a large firmware image without an on-device
    // decompression buffer. Host tests keep the same readable page contract.
    const compressed=gzipSync(Buffer.from(html),{level:9,mtime:0});
    const encoded = '// Generated from web assets. Run scripts/embed-c6-portals.mjs.\n'
        + '#if defined(ESP_PLATFORM) && !C6_FORMLABS_ONLY\n#define C6_PORTAL_GZIP 1\n'
        + 'static const unsigned char '+variable+'[] = {\n'
        + Array.from({length:Math.ceil(compressed.length/24)},(_,i)=>'    '+Array.from(compressed.subarray(i*24,i*24+24),v=>'0x'+v.toString(16).padStart(2,'0')).join(',')+',').join('\n')+'\n};\n#else\n'
        + 'static const char '+variable+'[] =\n'
        + html.split('\n').map(line=>JSON.stringify(line+'\n')).join('\n')+';\n#endif\n';
    const target = new URL('../Tools/WaveshareC6Firmware/src/'+header, import.meta.url);
    if(check){if(readFileSync(target,'utf8')!==encoded)throw Error(header+' is out of date');}
    else writeFileSync(target, encoded);
    console.log((check?'Verified ':'Embedded ')+header+' · '+Buffer.byteLength(html)+' bytes → '+compressed.length+' gzip bytes');
}
