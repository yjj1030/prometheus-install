#!/usr/bin/env python3
"""Check policy isolation, test references, metadata and local document links."""
from pathlib import Path
import re,yaml
ROOT=Path(__file__).resolve().parents[1]
def data(path):return yaml.safe_load(path.read_text())
def rules(path):return [r for g in data(path)['groups'] for r in g['rules']]
def alerts(path):return [r for r in rules(path) if 'alert' in r]
sc=ROOT/'scenarios/sk-91'
recommended=alerts(sc/'test-recommended/node_alerts.yml');quiet=alerts(sc/'test-memory-oom-only/node_alerts.yml')
assert [r for r in recommended if r['labels']['category']!='memory']==[r for r in quiet if r['labels']['category']!='memory'],'Non-memory policies differ'
assert [r['alert'] for r in quiet if r['labels']['category']=='memory']==['NodeOOMKillDetected'],'OOM-only contains another memory alert'
assert set(r['alert'] for r in recommended if r['labels']['category']=='memory')=={'NodeOOMKillDetected','NodeMemoryUsageHighWarning','NodeMemoryUsageHighCritical','NodeSwapPressureWarning'}
for profile in ['production','test-recommended','test-memory-oom-only']:
    all_alerts=[]
    for f in (sc/profile).glob('*.yml'):all_alerts+=alerts(f)
    for r in all_alerts:
        assert '{{' not in str(r['labels']),'Dynamic template in identity labels'
        assert all(r['labels'].get(k) for k in ['severity','category','condition_id','alert_type'])
        assert r['annotations'].get('action') and r['annotations'].get('summary')
        if r['labels'].get('asset_type')=='server':assert r['annotations'].get('hostname')
    for r in all_alerts:
        if r['labels']['condition_id']=='node_down':assert 'group_left' not in r['expr'],'Down identity enriched with dynamic hostname'
for f in (ROOT/'tests/alert-rules').glob('*.test.yml'):
    d=data(f);known=set()
    for ref in d['rule_files']:known.update(r['alert'] for r in alerts((f.parent/ref).resolve()))
    for t in d['tests']:
        for check in t.get('promql_expr_test',[]):
            for name in re.findall(r'alertname="([^"]+)"',check['expr']):
                # Explicit negative tests for absent memory/TCP alerts are intentional.
                assert name in known or name in {'NodeMemoryUsageHighCritical','NodeMemoryUsageHighWarning','NodeSwapPressureWarning','NodeTCPRetransmissionCritical'},f'Unknown test alert {name} in {f}'
for f in list((ROOT/'catalog').rglob('*.md'))+list(sc.rglob('*.md')):
    for link in re.findall(r'\]\(([^)]+)\)',f.read_text()):
        if '://' in link or link.startswith('#'):continue
        target=link.split('#')[0]
        assert (f.parent/target).exists(),f'Broken local link {link} in {f}'
print('PASS: policy isolation, stable identity metadata, test references and document links')
