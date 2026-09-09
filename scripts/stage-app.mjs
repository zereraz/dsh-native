import { mkdirSync, renameSync, rmSync, writeFileSync, readdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';
const source=process.argv[2];
if(!source) throw new Error('Expected candidate bundle');
const root=join(homedir(),'Library/Application Support/DSH/app-releases');
mkdirSync(root,{recursive:true});
const dest=join(root,`candidate-${Date.now()}.app`);
try {
 execFileSync('ditto',[source,dest]);
 // dsh-local 2026-09-09 (incident 01a06e17): dependency-closure assertion.
 // sync-runtime once dropped bin-only platform addon packages behind a
 // lib/-only gate; the entry package booted fine and the crash surfaced
 // only on a user session resume (flock). Never again let a bundle with a
 // dangling @deepseek-ai internal dependency reach the staged state.
 // Cross-platform binary variants (-<os>-<arch>) are only required for the
 // host platform; every other @deepseek-ai dependency must be present.
 {
  const nm=join(dest,'Contents/Resources/supervisor/node_modules/@deepseek-ai');
  const installed=new Set(readdirSync(nm));
  const platformSuffix=/-(darwin|linux|win32)-(x64|arm64|universal)$/;
  const missing=[];
  for(const dir of installed){
   const pj=join(nm,dir,'package.json');
   if(!existsSync(pj)) continue;
   let pkg; try { pkg=JSON.parse(readFileSync(pj,'utf8')); } catch { continue; }
   const deps={...pkg.dependencies,...pkg.optionalDependencies};
   for(const dep of Object.keys(deps)){
    if(!dep.startsWith('@deepseek-ai/')) continue;
    const tail=dep.slice('@deepseek-ai/'.length);
    const m=tail.match(platformSuffix);
    if(m && !tail.endsWith(`-${process.platform}-${process.arch}`)) continue;
    if(!installed.has(tail)) missing.push(`${dir} → ${dep}`);
   }
  }
  if(missing.length) throw new Error(`dependency closure broken — missing @deepseek-ai packages in candidate:\n  ${missing.join('\n  ')}\n(sync-runtime walk or the release's package set changed; fix before staging)`);
  console.log(`closure: ${installed.size} @deepseek-ai packages, all internal deps resolve`);
 }
 execFileSync('codesign',['--force','--deep','--sign','-',dest]);
 execFileSync('codesign',['--verify','--deep','--strict',dest]);
 const version=execFileSync('/usr/libexec/PlistBuddy',['-c','Print :CFBundleShortVersionString',join(dest,'Contents/Info.plist')],{encoding:'utf8'}).trim();
 const path=join(homedir(),'.dsh/app-candidate.json');
 writeFileSync(path+'.tmp',JSON.stringify({path:dest,version,createdAt:new Date().toISOString()})+'\n',{mode:0o600});
 renameSync(path+'.tmp',path);
 console.log(`Staged v${version}; Reload Backend activates it when idle. Installed app is unchanged.`);
} catch(e) {rmSync(dest,{recursive:true,force:true}); throw e;}
