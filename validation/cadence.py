"""Observe warm scans at real 0/5/10 minute boundaries; not an energy A/B test."""
from datetime import datetime
import json
from pathlib import Path
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

root=Path('/private/tmp/tokens-validation-20260908')
start=time.monotonic()
records=[]
for slot in (0,300,600):
    while time.monotonic()-start<slot:
        time.sleep(min(30,slot-(time.monotonic()-start)))
    if slot==300:
        stamp=datetime.now(ZoneInfo('Asia/Shanghai')).isoformat()
        usage={'input_tokens':100,'output_tokens':50,'cached_input_tokens':20,'reasoning_output_tokens':10,'total_tokens':150}
        rows=[{'timestamp':stamp,'type':'session_meta','payload':{'id':'cadence-synthetic-session','model_provider':'openai'}},
              {'timestamp':stamp,'type':'event_msg','payload':{'type':'token_count','info':{'model':'fixture-model','last_token_usage':usage,'total_token_usage':usage}}}]
        (root/'sample-home/.codex/sessions/rollout-cadence-synthetic.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    actual=time.monotonic()-start
    label=f'cadence-{slot}'
    cmd=[sys.executable,str(Path(__file__).with_name('measure.py')),'--binary',str(root/'target/release/tokens-macos-collector-probe'),
         '--home',str(root/'sample-home'),'--work',str(root/'full-measured'),'--pricing',str(root/'litellm.json'),'--label',label]
    subprocess.run(cmd,check=True)
    metrics=json.loads((root/'full-measured'/f'{label}.metrics.json').read_text())[0]
    records.append({'scheduledSeconds':slot,'actualStartSeconds':actual,'utc':datetime.now(ZoneInfo('UTC')).isoformat(),**metrics})
    (root/'cadence.metrics.json').write_text(json.dumps(records,indent=2)+'\n')
print('cadence observation complete',flush=True)
