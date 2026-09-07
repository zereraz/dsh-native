import { promises as fs, realpathSync } from 'node:fs';
import { join, resolve, basename, dirname } from 'node:path';
import { homedir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const home = process.env.DSH_HOME || join(homedir(), '.dsh');
const profile = join(home, 'profiles/web');
const statePath = join(home, 'plugin-control.json');
const transaction = join(home, 'plugin-activation.json');
const read = async (p, fallback) => { try { return JSON.parse(await fs.readFile(p, 'utf8')); } catch (e) { if (e.code === 'ENOENT' && fallback !== undefined) return fallback; throw e; } };
const atomic = async (p, value) => { const t = p + '.tmp'; await fs.writeFile(t, JSON.stringify(value, null, 2)+'\n', {mode:0o600}); await fs.rename(t,p); };
function git(root, args) { const p=spawnSync('git',['-C',root,...args],{encoding:'utf8'}); if(p.status!==0) throw new Error(p.stderr.trim() || 'Git command failed'); return p.stdout.trim(); }
export async function fingerprint(root) {
 const hash=createHash('sha256');
 async function walk(dir, rel='') {
  for(const e of (await fs.readdir(dir,{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name))) {
   if(['node_modules','.git','.DS_Store'].includes(e.name) || (!rel && ['lib','dist','coverage','test-results','playwright-report'].includes(e.name))) continue;
   const r=join(rel,e.name), p=join(dir,e.name);
   if(e.isDirectory()) await walk(p,r);
   else if(e.isFile()) hash.update(r).update(await fs.readFile(p));
  }
 }
 await walk(root); return hash.digest('hex');
}
export async function status() {
 const manifest=await read(join(profile,'package.json'));
 const state=await read(statePath,{}); const rows=[];
 for(const [name, spec] of Object.entries(manifest.dependencies||{})) {
  if(!spec.startsWith('link:')) continue;
  const active=resolve(profile,spec.slice(5)); const saved=state[name]||{};
  const source=saved.source || active;
  try {
   const pkg=await read(join(source,'package.json')); const hash=await fingerprint(source);
   let revision='unversioned'; try { revision=git(source,['rev-parse','--short','HEAD']); if(git(source,['status','--porcelain'])) revision+=' + edits'; } catch {}
   rows.push({name,source,revision,canBuild:!!pkg.scripts?.build,
     detail:saved.pending ? (saved.sourceHash===hash ? 'Checked build staged • reload required' : 'Source changed since staged build') :
       saved.active ? 'Activated '+(saved.activeRevision||'local build')+' • behavior unverified' : 'Loaded revision unknown',
     staged:!!saved.pending});
  } catch(e) { rows.push({name,source,revision:'unavailable',canBuild:false,detail:e.message,staged:false}); }
 }
 return rows;
}
function run(cmd,args,cwd) { const p=spawnSync(cmd,args,{cwd,stdio:'inherit',env:{...process.env,CI:'true'}}); if(p.status!==0) throw new Error(`${cmd} failed (${p.status ?? p.signal})`); }
// Preserve dependency graph sharing/cycles while copying every resolved package.
export async function copyDependencies(source, target, seen=new Map()) {
 const real=await fs.realpath(source); const stat=await fs.stat(real);
 if(stat.isDirectory()) {
  if(seen.has(real)) { await fs.symlink(seen.get(real),target); return; }
  seen.set(real,target); await fs.mkdir(target,{recursive:true});
  for(const name of await fs.readdir(real)) await copyDependencies(join(real,name),join(target,name),seen);
 } else if(stat.isFile()) { await fs.copyFile(real,target); await fs.chmod(target,stat.mode); }
}
export async function prepare(name,update=false) {
 const row=(await status()).find(x=>x.name===name); if(!row) throw new Error('Plugin is not a linked web-profile dependency');
 if(!row.canBuild) throw new Error('No build script: use Reload Backend for this plugin');
 const before=await fingerprint(row.source);
 const releases=process.env.DSH_PLUGIN_RELEASES || join(homedir(),'Library/Application Support/DSH/plugin-releases'); await fs.mkdir(releases,{recursive:true,mode:0o700});
 const release=join(releases,randomUUID()); await fs.mkdir(release);
 let success=false;
 try {
  let revision=row.revision;
  if(update) {
   // Fetch in a private clone; never change the developer checkout.
   git(row.source,['rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}']);
   const branch=git(row.source,['symbolic-ref','--short','HEAD']);
   const remoteName=git(row.source,['config',`branch.${branch}.remote`]);
   const remote=git(row.source,['remote','get-url',remoteName]);
   const ref=git(row.source,['config',`branch.${branch}.merge`]);
   run('git',['clone','--quiet','--no-hardlinks',row.source,release]);
   git(release,['remote','set-url','origin',remote]);
   git(release,['fetch','--quiet','origin',ref]);
   git(release,['checkout','--quiet','--detach','FETCH_HEAD']);
   revision=git(release,['rev-parse','--short','HEAD']);
  } else {
   await fs.cp(row.source,release,{recursive:true,filter:p=>!['node_modules','.git'].includes(basename(p)) && !['lib','dist'].some(n=>p===join(row.source,n))});
  }
  const pkg=await read(join(release,'package.json'));
  if(!pkg.scripts?.build) throw new Error('Candidate has no build script');
  // Copy the resolved dependency tree, including local harness dependencies.
  // A changed dependency declaration requires a fresh frozen-lock install.
  const old=await read(join(row.source,'package.json'));
  const keys=['dependencies','devDependencies','optionalDependencies','peerDependencies'];
  const locks=['pnpm-lock.yaml','package-lock.json'];
  const same=keys.every(k=>JSON.stringify(old[k])===JSON.stringify(pkg[k])) && (await Promise.all(locks.map(async f=>(await fs.readFile(join(row.source,f),'utf8').catch(()=>''))===(await fs.readFile(join(release,f),'utf8').catch(()=>''))))).every(Boolean);
  const pm=(await fs.stat(join(release,'pnpm-lock.yaml')).catch(()=>null)) ? 'pnpm' : 'npm';
  if(same) await copyDependencies(join(row.source,'node_modules'),join(release,'node_modules'));
  else run(pm,pm==='pnpm'?['install','--frozen-lockfile']:['ci'],release);
  for(const step of ['build','typecheck','test']) {
   if(pkg.scripts?.[step]) run('npm',['run',step],release);
   else console.log(`${step}: not declared by plugin`);
  }
  // Import in a disposable process; never activate the plugin service.
  const entry=resolve(release,pkg.main||'lib/index.js');
  run(process.execPath,['--input-type=module','-e',`await import(${JSON.stringify(pathToFileURL(entry).href)})`],release);
  if(before!==await fingerprint(row.source)) throw new Error('Source changed during build; retry after edits finish');
  const state=await read(statePath,{});
  state[name]={...state[name],source:row.source,sourceHash:before,pending:release,pendingRevision:revision};
  await atomic(statePath,state); success=true;
  console.log(`${name}: checks passed; staged ${revision}. Reload Backend when idle to activate.`);
 } finally { if(!success) await fs.rm(release,{recursive:true,force:true}); }
}
export async function activate() {
 if(await fs.stat(transaction).catch(()=>null)) throw new Error('Previous plugin transaction needs rollback before another reload');
 const manifest=await read(join(profile,'package.json')); const state=await read(statePath,{}); const links=[];
 for(const [name,s] of Object.entries(state)) {
  if(!s.pending) continue;
  if(s.sourceHash!==await fingerprint(s.source)) throw new Error(`${name}: source changed after build; rebuild before reload`);
  const link=join(profile,'node_modules',name);
  const previous=await fs.readlink(link); // Refuse to replace a real directory.
  links.push({name,link,previous,next:s.pending});
 }
 if(!links.length) return;
 await atomic(transaction,{manifest,state,links});
 try {
  for(const item of links) {
   const temp=item.link+'.menubar-next'; await fs.symlink(item.next,temp); await fs.rename(temp,item.link);
   manifest.dependencies[item.name]='link:'+item.next;
  }
  await atomic(join(profile,'package.json'),manifest);
 } catch(e) { await rollback(); throw e; }
}
export async function rollback() {
 const tx=await read(transaction,null); if(!tx) return;
 for(const item of tx.links) {
  const temp=item.link+'.menubar-restore'; await fs.rm(temp,{force:true});
  await fs.symlink(item.previous,temp); await fs.rename(temp,item.link);
 }
 await atomic(join(profile,'package.json'),tx.manifest); await atomic(statePath,tx.state);
 await fs.rm(transaction);
}
export async function commit() {
 const tx=await read(transaction,null); if(!tx) return;
 const state=await read(statePath,{});
 for(const item of tx.links) { const s=state[item.name]; s.active=s.pending; s.activeRevision=s.pendingRevision; delete s.pending; delete s.pendingRevision; }
 await atomic(statePath,state); await fs.rm(transaction);
}
if(process.argv[1] && import.meta.url===pathToFileURL(realpathSync(process.argv[1])).href) {
 try {
  const [action,name]=process.argv.slice(2);
  if(action==='status') console.log(JSON.stringify(await status()));
  else if(action==='build'||action==='update') await prepare(name,action==='update');
  else if(action==='activate') await activate();
  else if(action==='rollback') await rollback();
  else if(action==='commit') await commit();
  else throw new Error('Expected status, build, update, activate, rollback, or commit');
 } catch(e) { console.error(e.message); process.exitCode=1; }
}
