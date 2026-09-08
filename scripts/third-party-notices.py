#!/usr/bin/env python3
"""Collect license texts for the locked Store collector dependency graph."""
from pathlib import Path
import json,os,subprocess

root=Path(__file__).resolve().parents[1]
env=os.environ.copy();env['CARGO_HOME']=str(root/'.build/cargo-home');env['CARGO_NET_OFFLINE']='true'
metadata=json.loads(subprocess.check_output(['cargo','metadata','--manifest-path',str(root/'Collector/Cargo.toml'),'--format-version','1','--no-default-features','--filter-platform','aarch64-apple-darwin','--locked','--offline'],env=env))
nodes={n['id']:n for n in metadata['resolve']['nodes']};packages={p['id']:p for p in metadata['packages']}
pending=[metadata['resolve']['root']];seen=set()
while pending:
 key=pending.pop()
 if key in seen:continue
 seen.add(key)
 pending.extend(d['pkg'] for d in nodes[key]['deps'] if any(k['kind']!='dev' for k in d['dep_kinds']))
texts=['Tokly third-party notices\n\nGenerated from the locked macOS Store dependency graph. Includes build-time components conservatively. Apple system libraries are not redistributed in this app.\n']
missing=[];inventory=[]
for p in sorted((packages[key] for key in seen),key=lambda p:p['name']):
 if p['name']=='tokens-collector':continue
 base=Path(p['manifest_path']).parent
 files=sorted({f for pattern in ['LICENSE*','LICENCE*','COPYING*','NOTICE*'] for f in base.glob(pattern) if f.is_file()})
 if p.get('license_file'):
  f=base/p['license_file']
  if f.is_file() and f not in files:files.append(f)
 if p['name']=='tokens-core':files=[root/'Collector/vendor/LICENSE']
 inventory.append({'name':p['name'],'version':p['version'],'license':p.get('license'),'textsFound':len(files)})
 if not files:missing.append(p['name']);continue
 texts.append(f"\n{'='*60}\n{p['name']} {p['version']} ({p.get('license','unspecified')})\n")
 for f in files:texts.append(f'\n--- {f.name} ---\n'+f.read_text(errors='replace'))
out=root/'distribution';out.mkdir(exist_ok=True)
(out/'ThirdPartyNotices.txt').write_text('\n'.join(texts))
(out/'license-inventory.json').write_text(json.dumps({'packages':inventory,'missingTexts':missing},indent=2)+'\n')
print(json.dumps({'packages':len(inventory),'missingTexts':missing}))
if missing:raise SystemExit(1)
