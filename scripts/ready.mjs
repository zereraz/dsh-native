import { readFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
export async function ready(urlFile, origin, request=fetch) {
 try {
  const url=new URL((await readFile(urlFile,'utf8')).trim());
  if(url.origin!==origin) return false;
  const first=await request(url,{redirect:'manual',signal:AbortSignal.timeout(2000)});
  let response=first;
  if([302,303,307,308].includes(first.status)) {
   const location=new URL(first.headers.get('location'),url);
   if(location.origin!==url.origin) return false;
   response=await request(location,{headers:{cookie:first.headers.getSetCookie().map(c=>c.split(';')[0]).join('; ')},redirect:'error',signal:AbortSignal.timeout(2000)});
  }
  const page=await response.text();
  return response.status===200 && page.includes('__DSH_BOOT__') && page.includes('__ModuleLoader__=');
 } catch { return false; }
}
if(process.argv[1] && import.meta.url===pathToFileURL(realpathSync(process.argv[1])).href) {
 process.exitCode=await ready(process.env.DSH_WEB_URL_FILE || `${process.env.DSH_HOME || process.env.HOME+'/.dsh'}/web-url.txt`, `http://127.0.0.1:${process.env.PORT || '41730'}`) ? 0 : 1;
}
