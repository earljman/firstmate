import os, pathlib, socket, threading, subprocess, time, json, shutil
root=pathlib.Path.cwd(); lab=root/'.test-remote-live/home'; ev=pathlib.Path('/Users/j/.no-mistakes/evidence/01M3QWSPMYRD8Y2T3JVY58TE1Y')
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); s.settimeout(.2); port=s.getsockname()[1]; connections=[]; accepts=[]; stop=False
def serve():
 while not stop:
  try:
   c,a=s.accept(); connections.append(c); accepts.append(round(time.monotonic(),3))
  except socket.timeout: pass
thread=threading.Thread(target=serve); thread.start()
config=root/'.test-remote-live/ssh.config'
config.write_text(f'Host stalled\n HostName 127.0.0.1\n Port {port}\n User nobody\n BatchMode yes\n StrictHostKeyChecking yes\n UserKnownHostsFile /dev/null\n GlobalKnownHostsFile /dev/null\n')
wrapper=root/'.test-remote-live/ssh'; wrapper.write_text(f'#!/bin/sh\nexec /usr/bin/ssh -F "{config}" "$@"\n'); wrapper.chmod(0o755)
reg=[]
for id in ['a','b','c']:
 (lab/f'state/{id}.meta').write_text(f'window=remote:{id}\nkind=secondmate\nharness=claude\nremote_host=stalled\nhome=/remote/{id}\n')
 reg.append(f'- {id} - Mate (host: stalled; root: {root}; home: /remote/{id}; scope: tests; projects: alpha; added 2026-01-01)')
(lab/'data/secondmates.md').write_text('\n'.join(reg)+'\n')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k=='TMUX')}; env.update(FM_HOME=str(lab),FM_SSH_BIN=str(wrapper),FM_WATCH_REMOTE_TIMEOUT='2',FM_SECONDMATE_LIVENESS_SECS='1',FM_POLL='1',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999',FM_BACKEND='tmux')
results={}; p=None
try:
 for name,args in [('contributions',['bash','tests/.public-bound-selected.sh']),('crew',['bin/fm-crew-state.sh','a']),('reply',['bin/fm-procevent-remote-reply.sh','source','a'])]:
  start=time.monotonic(); r=subprocess.run(args,env=env,text=True,capture_output=True,timeout=10); results[name]={'seconds':round(time.monotonic()-start,2),'rc':r.returncode,'stdout':r.stdout,'stderr':r.stderr}
 assert results['contributions']['rc']==0,results
 assert 'unknown-remote' in results['crew']['stdout'],results
 assert results['reply']['rc']==124,results
 assert not (lab/'state/remote-replies/a.caught-up').exists()
 assert not (lab/'state/.last-watcher-beat').exists()
 with (ev/'live-watcher.stdout').open('w') as out,(ev/'live-watcher.stderr').open('w') as err:
  p=subprocess.Popen(['bin/fm-watch.sh'],env=env,stdout=out,stderr=err)
  samples=[]; start=time.monotonic()
  while time.monotonic()-start<25:
   time.sleep(.2); beat=lab/'state/.last-watcher-beat'
   if beat.exists(): samples.append({'elapsed':round(time.monotonic()-start,2),'age':round(time.time()-beat.stat().st_mtime,2)})
   assert p.poll() is None, 'watcher exited'
  results['watcher']={'seconds':25,'max_beacon_age':max(x['age'] for x in samples),'connections':len(accepts),'triage':(lab/'state/.watch-triage.log').read_text(),'relaunch_records':[x.name for x in (lab/'state').glob('.secondmate-relaunch-*')],'wake_queue':(lab/'state/.wake-queue').read_text() if (lab/'state/.wake-queue').exists() else ''}
  assert results['watcher']['max_beacon_age']<5
  assert len(accepts)>=8
  assert not results['watcher']['relaunch_records']
  assert results['watcher']['triage'].count('unreachable/ambiguous')==3
  (ev/'beacon-samples.json').write_text(json.dumps(samples,indent=2))
finally:
 if p and p.poll() is None:
  p.terminate()
  try:p.wait(timeout=10)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 stop=True; thread.join(); s.close()
 for c in connections:c.close()
 (ev/'live-remote-results.json').write_text(json.dumps(results,indent=2))
 shutil.rmtree(lab)
print(json.dumps(results,indent=2))
