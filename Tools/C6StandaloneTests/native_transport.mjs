import http from 'node:http';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
const statuses=[200,204,404,401,500,200,200,200];let requests=0;
const address='127.0.0.1';
const server=http.createServer(async (req,res)=>{
 try {
  assert.equal(req.method,'POST');assert.equal(req.url,'/api/card');
  assert.equal(req.headers.authorization,'Bearer 1234abcd1234abcd');
  assert.equal(req.headers.cookie,undefined);
  if(requests<5||requests===7){
   assert.equal(req.headers['x-lingxi-card'],'printer');
   assert.equal(req.headers['x-lingxi-serial'],'same-serial');
   assert.equal(req.headers['x-lingxi-brand'],'formlabs');
   assert.equal(req.headers['x-lingxi-source'],'formlabs');
   assert.equal(req.headers['x-lingxi-origin'],'fixture-cloud-client');
  }else if(requests===5)assert.equal(req.headers['x-lingxi-card'],'clock');
  else{assert.equal(req.headers['x-lingxi-card'],'ha');assert.equal(req.headers['x-lingxi-group'],'1');assert.equal(req.headers['x-lingxi-origin'],'192.168.1.10:8123:0');}
  assert.equal(req.headers['x-lingxi-native'],requests>=5?'1':undefined);
  const chunks=[];for await(const chunk of req)chunks.push(chunk);
  assert.equal(Buffer.concat(chunks).length,0);
  res.writeHead(statuses[requests++]);res.end();
 }catch(error){res.destroy(error);throw error;}
});
await new Promise(resolve=>server.listen(0,address,resolve));
try {
 const child=spawn(process.argv[2],[`${address}:${server.address().port}`],{stdio:'inherit'});
 const result=await new Promise(resolve=>child.on('exit',(code)=>resolve(code)));
 assert.equal(result,0);assert.equal(requests,8);
}finally{server.close();}
