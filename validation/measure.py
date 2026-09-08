"""Measure the collector against a local, fixed data copy; emit aggregate timings only."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--home', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--pricing', type=Path, required=True)
p.add_argument('--label', required=True)
p.add_argument('--clients', default='codex,claude,opencode')
p.add_argument('--today', action='store_true')
p.add_argument('--since')
p.add_argument('--repeat', type=int, default=1)
a = p.parse_args()
a.work.mkdir(parents=True, exist_ok=True)
cache = a.work / 'config' / 'cache'
cache.mkdir(parents=True, exist_ok=True)
# Pin one public dataset to separate filesystem costs from network latency.
for name, data in [('litellm', json.loads(a.pricing.read_text())), ('openrouter', {}), ('models-dev', {})]:
    (cache / f'pricing-{name}.json').write_text(json.dumps({'timestamp': int(time.time()), 'data': data}))
env = os.environ.copy()
env.update(TOKENS_CONFIG_DIR=str(a.work / 'config'), RAYON_NUM_THREADS='4', TOKIO_WORKER_THREADS='2')
results = []
for i in range(a.repeat):
    label = f'{a.label}-{i}'
    cmd = ['/usr/bin/time', '-l', str(a.binary), '--home', str(a.home), '--clients', a.clients,
           '--timezone', 'Asia/Shanghai', '--output', str(a.work / f'{label}.graph.json')]
    if a.today:
        cmd += ['--today']
    if a.since:
        cmd += ['--since', a.since]
    started = time.monotonic()
    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=240)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, err = proc.communicate()
        raise RuntimeError(f'{label}: timed out after 240 seconds')
    (a.work / f'{label}.stdout.json').write_text(out)
    (a.work / f'{label}.time.txt').write_text(err)
    if proc.returncode:
        raise RuntimeError(f'{label}: exited {proc.returncode}; inspect local stderr file')
    timing = re.search(r'([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys', err)
    rss = re.search(r'(\d+)\s+maximum resident set size', err)
    row = {'label': label, 'wallSeconds': time.monotonic()-started,
           'userSeconds': float(timing[2]) if timing else None,
           'systemSeconds': float(timing[3]) if timing else None,
           'peakRssBytes': int(rss[1]) if rss else None,
           'coreElapsedMs': json.loads(out)['elapsedMs']}
    for field, text in [('blockInputs', 'block input operations'), ('blockOutputs', 'block output operations'),
                        ('instructions', 'instructions retired'), ('cycles', 'cycles elapsed')]:
        m = re.search(r'(\d+)\s+' + text, err)
        row[field] = int(m[1]) if m else None
    results.append(row)
    print(json.dumps(row), flush=True)
(a.work / f'{a.label}.metrics.json').write_text(json.dumps(results, indent=2)+'\n')
