import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
let calls=0,resolve,errors=0,active=0,max=0;const timers=new Map();let n=0;
const ctx=vm.createContext({setTimeout(fn){timers.set(++n,fn);return n;},clearTimeout(id){timers.delete(id);},
    save:async()=>{calls++;active++;max=Math.max(max,active);await new Promise(r=>resolve=r);active--;},report:()=>errors++});
vm.runInContext(readFileSync(new URL('../web/autosave.js',import.meta.url),'utf8')+';var a=new AutoSave(save,report)',ctx);
vm.runInContext('a.change();a.change();a.change()',ctx);assert.equal(timers.size,1);
const p=vm.runInContext('a.flush()',ctx);vm.runInContext('a.change()',ctx);await vm.runInContext('a.flush()',ctx);assert.equal(calls,1);resolve();await p;assert.equal(max,1);assert.equal(vm.runInContext('a.pending',ctx),true);
const q=vm.runInContext('a.flush()',ctx);resolve();await q;assert.equal(calls,2);
vm.runInContext('a.composing=true;a.change()',ctx);await vm.runInContext('a.flush()',ctx);assert.equal(calls,2);
vm.runInContext('a.composing=false;a.save=async()=>{const e=Error("conflict");e.conflict=true;throw e}',ctx);await vm.runInContext('a.flush()',ctx);assert.equal(errors,1);assert(vm.runInContext('a.blocked&&a.pending',ctx));
vm.runInContext('a.change()',ctx);await vm.runInContext('a.flush()',ctx);assert.equal(errors,1);
vm.runInContext('a.reset()',ctx);assert(!vm.runInContext('a.blocked||a.pending',ctx));
console.log('Autosave: debounce, serial writes, queued edits, IME guard and conflict stop passed');
