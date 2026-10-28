#!/usr/bin/env python3
"""Versioned naming, taxonomy and reproducible file baseline."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess
import yaml
R=Path(__file__).resolve().parents[1]
CATEGORIES=set('availability compute memory filesystem storage network system_limit time certificate monitoring database messaging container kubernetes application backup slo'.split())
ROOT_FILES=['VERSION','BASELINE.md','AGENTS.md','README.md','CHANGELOG.md','.github/workflows/alert-rules.yml']
TOOLS=['build_alert_rules.py','check_alert_contracts.py','validate_alert_rules.sh','check_alert_baseline.py']
def files():
    paths=[R/p for p in ROOT_FILES]+[R/'tools'/p for p in TOOLS]
    for folder in ['catalog','scenarios/sk-91','tests/alert-rules']:
        paths += [p for p in (R/folder).rglob('*') if p.is_file() and p.suffix in {'.md','.yml','.json'}]
    paths += [R/'tests/alertmanager_integration.py']
    return sorted(set(paths))
def manifest():
    v=(R/'VERSION').read_text().strip();assert re.fullmatch(r'\d+\.\d+\.\d+',v)
    counts={'alerts':0,'recordings':0,'severity':{},'category':{}}
    for p in files():
        if p.suffix!='.yml' or not (p.is_relative_to(R/'catalog') or p.is_relative_to(R/'scenarios')):continue
        assert re.fullmatch(r'[a-z0-9_]+_(prod|nonprod|common)_v'+re.escape(v)+r'\.yml',p.name),f'Invalid template name/version: {p}'
        d=yaml.safe_load(p.read_text())
        for g in d.get('groups',[]):
            for a in g['rules']:
                if 'alert' not in a:
                    if p.is_relative_to(R/'catalog'):counts['recordings']+=1
                    continue
                labels=a['labels'];assert labels['category'] in CATEGORIES,(p,a['alert'],'category')
                assert labels['severity'] in {'emergency','critical','warning','info','none'},(p,a['alert'],'severity')
                assert labels['severity']!='none' or a['alert']=='Watchdog'
                assert labels.get('condition_id') and a['annotations'].get('action')
                if p.is_relative_to(R/'catalog'):
                    counts['alerts']+=1
                    for k in ['severity','category']:counts[k][labels[k]]=counts[k].get(labels[k],0)+1
    return {'version':v,'scope':'catalog, scenarios/sk-91 and supporting alert tools/tests','catalog_counts':counts,'files':{str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files()}}
def main():
    p=argparse.ArgumentParser();p.add_argument('--write',action='store_true');p.add_argument('--bump');a=p.parse_args()
    if a.bump:
        assert re.fullmatch(r'\d+\.\d+\.\d+',a.bump)
        old=(R/'VERSION').read_text().strip();assert tuple(map(int,a.bump.split('.')))>tuple(map(int,old.split('.')))
        paths=files()
        for f in paths:
            if f.name=='VERSION':continue
            s=f.read_text();updated=s.replace('_v'+old,'_v'+a.bump)
            if s!=updated:f.write_text(updated)
        for f in paths:
            if '_v'+old in f.name:f.rename(f.with_name(f.name.replace('_v'+old,'_v'+a.bump)))
        (R/'VERSION').write_text(a.bump+'\n')
        subprocess.run(['python3',str(R/'tools/build_alert_rules.py')],check=True)
        print('Version advanced; update change records, validate, then --write baseline.');return
    d=manifest();path=R/'BASELINE.json'
    if a.write:path.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
    else:assert json.loads(path.read_text())==d,'Baseline drift: review changes, update version/change records and run --write'
    print(f'PASS: baseline {d["version"]}, {len(d["files"])} files, naming and taxonomy')
if __name__=='__main__':main()
