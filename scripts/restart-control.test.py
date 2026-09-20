import os, pathlib, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parent
REAL_NODE=shutil.which('node')
class RestartTests(unittest.TestCase):
 def scenario(self, mode, staged=False, busy=False):
  with tempfile.TemporaryDirectory(prefix='dsh-restart-test-') as t:
   t=pathlib.Path(t); home=t/'home'; bin=t/'bin'; bin.mkdir()
   (home/'.dsh/sessions/x').mkdir(parents=True); (home/'Library/LaunchAgents').mkdir(parents=True)
   # profile-preflight (2026-09-14) sandbox-boots the real profile before
   # anything is touched; give it an (empty) profile and a fake boot line.
   (home/'.dsh/profiles/web').mkdir(parents=True)
   (home/'Library/LaunchAgents/com.zereraz.dsh-app.plist').write_text('fixture')
   dst=t/'installed.app'; rollback=t/'rollback.app'; candidate=t/'candidate.app'
   for p,v in [(dst,'old'),(rollback,'rollback'),(candidate,'new')]: p.mkdir(); (p/'version').write_text(v)
   (dst/'Contents/Resources/supervisor').mkdir(parents=True)  # preflight precondition
   if staged:
    import json
    (home/'.dsh/app-candidate.json').write_text(json.dumps({'path':str(candidate)}))
   if busy: (home/'.dsh/sessions/x/session.jsonl.zstd').touch()
   log=t/'app.log'; log.write_text('previous boot noise\n')  # offset marker for the tree-health check
   scripts={
    'launchctl': '''echo "launchctl $*" >> "$TEST_ROOT/events"
case "$1" in bootout) rm -f "$TEST_ROOT/up";; bootstrap) touch "$TEST_ROOT/up"; n=$(cat "$TEST_ROOT/boots" 2>/dev/null || echo 0); echo $((n+1)) > "$TEST_ROOT/boots"; [ "$MODE" != tree-dead ] || echo 'Error: dsh: plugin tree failed to load: failed to apply loader entry ui-chat-notes (dsh-chat-notes): webserver: duplicate prefix route' >> "$DSH_APP_LOG";; esac''',
    'lsof': '[ -f "$TEST_ROOT/up" ]',
    'sleep': 'exit 0', 'osascript':'echo gui-quit >> "$TEST_ROOT/events"',
    'open':'echo gui-open >> "$TEST_ROOT/events"', 'codesign':'exit 0',
    'ditto':'echo copy >> "$TEST_ROOT/events"; /bin/cp -R "$1" "$2"',
    'mv':'echo "move $*" >> "$TEST_ROOT/events"; /bin/mv "$@"',
    'node': '''case "$1" in
 *dsh/lib/bin.js) echo 'dsh web: http://127.0.0.1:41813/?token=fixture'; exec /bin/sleep 20;;
 *ready.mjs) n=$(cat "$TEST_ROOT/boots"); [ "$MODE" = happy ] || [ "$MODE" = ptc-fail ] || [ "$n" -ge 2 ];;
 *verify-ptc.mjs) n=$(cat "$TEST_ROOT/boots"); [ "$MODE" != ptc-fail ] || [ "$n" -ge 2 ];;
 *plugins.mjs) echo "plugin $2" >> "$TEST_ROOT/events";;
 *stamp-update-state.mjs) echo stamped >> "$TEST_ROOT/events";;
 *) exec "$REAL_NODE" "$@";; esac'''
   }
   for name,script in scripts.items(): p=bin/name;p.write_text('#!/bin/bash\n'+script+'\n');p.chmod(0o755)
   env={**os.environ,'HOME':str(home),'DSH_HOME':str(home/'.dsh'),'DST':str(dst),'ROLLBACK':str(rollback),'DSH_CONTROL_PATH':str(bin),'TEST_ROOT':str(t),'MODE':mode,'REAL_NODE':REAL_NODE,'DSH_APP_LOG':str(log)}
   p=subprocess.run(['/bin/bash',str(ROOT/'restart-app.sh')],env=env,capture_output=True,text=True,timeout=15)
   events=(t/'events').read_text() if (t/'events').exists() else ''
   return p.returncode,events,(dst/'version').read_text(),p.stdout+p.stderr
 def test_busy_does_not_touch_host(self):
  code,events,_,_=self.scenario('happy',busy=True);self.assertEqual(code,3);self.assertEqual(events,'')
 def test_staged_app_activates_only_after_drain(self):
  code,events,version,out=self.scenario('happy',staged=True);self.assertEqual(code,0,out);self.assertEqual(version,'new');self.assertLess(events.index('launchctl bootout'),events.index('move '));self.assertIn('stamped',events)
 def test_readiness_failure_drains_before_rollback(self):
  code,events,version,out=self.scenario('not-ready',staged=True);self.assertEqual(code,1,out);self.assertEqual(version,'old');self.assertEqual(events.count('launchctl bootout'),2);self.assertNotIn('stamped',events)
 def test_tree_death_rolls_back_after_ready_and_ptc_pass(self):
  # The Sep-16 incident class: boot line up, PTC green, plugin tree dead.
  # The activation must roll back instead of stamping 'applied'.
  code,events,version,out=self.scenario('tree-dead',staged=True);self.assertEqual(code,1,out);self.assertEqual(version,'old');self.assertNotIn('stamped',events)
 def test_ptc_failure_is_fatal_and_restores_previous_app(self):
  code,events,version,out=self.scenario('ptc-fail',staged=True);self.assertEqual(code,1,out);self.assertEqual(version,'old');self.assertNotIn('stamped',events)
if __name__=='__main__': unittest.main()
