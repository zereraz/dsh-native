import { mkdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
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
 execFileSync('codesign',['--force','--deep','--sign','-',dest]);
 execFileSync('codesign',['--verify','--deep','--strict',dest]);
 const version=execFileSync('/usr/libexec/PlistBuddy',['-c','Print :CFBundleShortVersionString',join(dest,'Contents/Info.plist')],{encoding:'utf8'}).trim();
 const path=join(homedir(),'.dsh/app-candidate.json');
 writeFileSync(path+'.tmp',JSON.stringify({path:dest,version,createdAt:new Date().toISOString()})+'\n',{mode:0o600});
 renameSync(path+'.tmp',path);
 console.log(`Staged v${version}; Reload Backend activates it when idle. Installed app is unchanged.`);
} catch(e) {rmSync(dest,{recursive:true,force:true}); throw e;}
