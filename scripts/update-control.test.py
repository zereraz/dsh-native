import os,pathlib,shutil,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parent
class UpdateTests(unittest.TestCase):
 def scenario(self,fail=False,restart=False):
  with tempfile.TemporaryDirectory(prefix='dsh-update-test-') as tmp:
   t=pathlib.Path(tmp); (t/'scripts').mkdir(); home=t/'home'; (home/'.dsh').mkdir(parents=True); bin=t/'bin';bin.mkdir()
   shutil.copy(ROOT/'update-app.sh',t/'scripts/update-app.sh')
   (t/'scripts/restart-app.sh').write_text('test ! -d "$HOME/.dsh/app-update.lock.d" || exit 99\necho restarted >> "$TEST_ROOT/events"\n')
   config=t/'zig-out/package/dsh-native.app/Contents/Resources/config';config.mkdir(parents=True);(config/'cordis.patch.yml').write_text('[]')
   dst=t/'installed.app';dst.mkdir();(dst/'untouched').write_text('old')
   cmds={'node':'''case "$1" in
 *sync-runtime.mjs) echo sync >> "$TEST_ROOT/events";;
 *stage-app.mjs) echo staged >> "$TEST_ROOT/events";;
 */dsh/lib/bin.js) echo 'dsh web: http://127.0.0.1:41799/?token=fixture'; exec /bin/sleep 20;;
 esac''', 'git':'exit 0','pnpm':'exit 0','lsof':'exit 1','sleep':'/bin/sleep 0.01',
   'curl':'''[ "$FAIL_GATE" = 0 ] || { printf failed; exit 0; }
printf '__DSH_BOOT__ __ModuleLoader__=' '''}
   for n,s in cmds.items(): p=bin/n;p.write_text('#!/bin/bash\n'+s+'\n');p.chmod(0o755)
   env={**os.environ,'HOME':str(home),'HARNESS_REPO':str(t/'harness'),'DST':str(dst),'TEST_ROOT':str(t),'FAIL_GATE':str(int(fail)),'DSH_CONTROL_PATH':str(bin),'PATH':str(bin)+':'+os.environ['PATH']}
   result=subprocess.run(['/bin/bash',str(t/'scripts/update-app.sh')]+(['--restart'] if restart else []),env=env,capture_output=True,text=True,timeout=15)
   events=(t/'events').read_text();self.assertFalse((home/'.dsh/app-update.lock.d').exists());self.assertEqual((dst/'untouched').read_text(),'old')
   return result,events
 def test_stage_leaves_installed_bundle_untouched(self):
  p,e=self.scenario();self.assertEqual(p.returncode,0,p.stdout+p.stderr);self.assertIn('staged',e)
 def test_failed_gate_releases_lock(self):
  p,e=self.scenario(fail=True);self.assertNotEqual(p.returncode,0);self.assertNotIn('staged',e)
 def test_combined_restart_releases_parent_lock(self):
  p,e=self.scenario(restart=True);self.assertEqual(p.returncode,0,p.stdout+p.stderr);self.assertIn('restarted',e)
if __name__=='__main__':unittest.main()
