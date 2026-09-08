import sqlite3,json,time,subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[2]
home=Path(__file__).resolve().parent/'Fixtures/home';db=home/'.local/share/opencode/opencode.db'
conn=sqlite3.connect(db);conn.execute('PRAGMA journal_mode=WAL');conn.execute('PRAGMA wal_autocheckpoint=0');conn.execute('CREATE TABLE IF NOT EXISTS message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT)')
row={'id':'sqlite-only','sessionID':'fixture-db','role':'assistant','modelID':'fixture-model','providerID':'fixture','cost':0,'tokens':{'input':70,'output':20,'reasoning':0,'cache':{'read':10,'write':0}},'time':{'created':1788825600000}}
conn.execute('INSERT OR REPLACE INTO message VALUES (?,?,?)',('sqlite-only','fixture-db',json.dumps(row)));conn.commit()
out=subprocess.check_output([str(root/'.build/collector-target/release/tokens-collector'),'scan','--home',str(home),'--config-dir',str(root/'.build/SandboxAccess/baseline-cache'),'--timezone','Asia/Shanghai','--since','2026-09-01','--until','2026-09-30','--hourly-date','2026-09-08','--clients','codex,claude,opencode'])
s=json.loads(out);total=sum(sum(m['tokens'].values()) for d in s['daily'] for c in d['clients'] for m in c['models']);print({'baselineWithLiveWal':total,'walExists':Path(str(db)+'-wal').exists(),'shmExists':Path(str(db)+'-shm').exists()},flush=True)
time.sleep(60)
conn.close()
