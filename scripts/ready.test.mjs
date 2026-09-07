import {ready} from './ready.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
test('readiness requires authenticated boot, not bare liveness',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'dsh-ready-test-'));const file=join(dir,'url');
 try {
  await writeFile(file,'http://127.0.0.1:41730/?token=fixture');
  const origin='http://127.0.0.1:41730';
  assert.equal(await ready(file,origin,async()=>new Response('Unauthorized',{status:401})),false);
  assert.equal(await ready(file,origin,async()=>new Response('ordinary page')),false);
  let calls=0;
  assert.equal(await ready(file,origin,async(url,options)=>{
   if(calls++===0) return new Response('',{status:303,headers:{location:'/', 'set-cookie':'session=fixture; HttpOnly'}});
   assert.equal(options.headers.cookie,'session=fixture');
   return new Response('__DSH_BOOT__ __ModuleLoader__=');
  }),true);
  assert.equal(await ready(file,origin,async()=>new Response('',{status:303,headers:{location:'https://example.com/'}})),false);
 } finally {await rm(dir,{recursive:true,force:true});}
});
