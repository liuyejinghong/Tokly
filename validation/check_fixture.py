"""Check upstream cache/append/dedup and today's mtime shortcut with synthetic data."""
import argparse
from datetime import datetime,timedelta
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from zoneinfo import ZoneInfo

p=argparse.ArgumentParser()
p.add_argument('--binary',type=Path,required=True)
p.add_argument('--work',type=Path,required=True)
a=p.parse_args()
root=a.work
sessions=root/'home/.codex/sessions'
sessions.mkdir(parents=True,exist_ok=True)
cache=root/'config/cache'
cache.mkdir(parents=True,exist_ok=True)
for name in ('litellm','openrouter','models-dev'):
    (cache/f'pricing-{name}.json').write_text(json.dumps({'timestamp':int(time.time()),'data':{}}))
env=os.environ.copy()
env.update(TOKENS_CONFIG_DIR=str(root/'config'), RAYON_NUM_THREADS='4', TOKIO_WORKER_THREADS='2')
now=datetime.now(ZoneInfo('Asia/Shanghai'))
stamp=now.isoformat()
f=sessions/'rollout-fixture.jsonl'
usage={'input_tokens':100,'output_tokens':50,'cached_input_tokens':20,'reasoning_output_tokens':10,'total_tokens':150}
def event(total):
    return {'timestamp':stamp,'type':'event_msg','payload':{'type':'token_count','info':{'model':'fixture-model','last_token_usage':usage,'total_token_usage':total}}}
rows=[{'timestamp':stamp,'type':'session_meta','payload':{'id':'fixture-session','model_provider':'openai'}},event(usage),event(usage)]
f.write_text(''.join(json.dumps(row)+'\n' for row in rows))
def run(label,today=False):
    output=root/f'{label}.json'
    cmd=[str(a.binary),'--home',str(root/'home'),'--clients','codex','--output',str(output),'--timezone','Asia/Shanghai']
    if today:cmd+=['--today']
    subprocess.run(cmd,env=env,check=True,capture_output=True,text=True)
    return json.loads(output.read_text())
def tokens(g):return g['summary']['total_tokens']
cold=run('cold')
warm=run('warm')
assert tokens(cold)==160, tokens(cold)
assert tokens(warm)==160, tokens(warm)
with f.open('a') as out:out.write(json.dumps(event({k:v*2 for k,v in usage.items()}))+'\n')
appended=run('appended')
assert tokens(appended)==320, tokens(appended)
archive=root/'home/.codex/archived_sessions'
archive.mkdir(parents=True,exist_ok=True)
shutil.copy2(f,archive/f.name)
duplicate=run('archive-duplicate')
assert tokens(duplicate)==320, tokens(duplicate)
fast=run('today-normal',True)
assert tokens(fast)==320, tokens(fast)
# A restored file can retain an older filesystem timestamp despite today's event timestamp.
old=(now-timedelta(days=2)).timestamp()
for path in (f,archive/f.name):os.utime(path,(old,old))
full_old=run('full-old-mtime')
fast_old=run('today-old-mtime',True)
assert tokens(full_old)==320
result={'coldWarmExpectedTokens':160,'appendExpectedTokens':320,'archiveDuplicateCountedOnce':True,
        'todayNormalMatchesFull':True,'oldMtimeFullTokens':tokens(full_old),'oldMtimeTodayTokens':tokens(fast_old),
        'mtimeShortcutEquivalent':tokens(full_old)==tokens(fast_old)}
(root/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
