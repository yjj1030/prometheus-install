#!/usr/bin/env python3
"""Exercise documented staging/replacement/rollback locally; never reload a live service."""
from pathlib import Path
import argparse,re,subprocess,tempfile,shutil
parser=argparse.ArgumentParser();parser.add_argument('--promtool',default='promtool');args=parser.parse_args()
root=Path(__file__).resolve().parents[1];blocks=re.findall(r'```bash\n(.*?)```',(root/'DEPLOY.md').read_text(),re.S)
promtool=shutil.which(args.promtool);assert promtool, 'promtool is required'
version=(root/'VERSION').read_text().strip()
def block_starting(prefix):
 matches=[b for b in blocks if b.startswith(prefix)]
 assert len(matches)==1, f'Deployment block missing or ambiguous: {prefix}'
 return matches[0]
setup_block=block_starting('set -euo pipefail')
replace_block=block_starting('OLD_RULES=')
config_block=block_starting('"$PROMTOOL" check rules "$RULE_DIR"')
rollback_block=block_starting('mkdir -p "$BACKUP_DIR/failed-new"')
for i,block in enumerate(blocks):
 check=subprocess.run(['bash','-n'],input=block,text=True,capture_output=True);assert check.returncode==0,(i,check.stderr)
def snapshot(p):return {x.name:x.read_bytes() for x in p.iterdir() if x.is_file()}
for partial in [False,True]:
 with tempfile.TemporaryDirectory() as tmp:
  tmp=Path(tmp);rules=tmp/'rules';rules.mkdir();conf=tmp/'prometheus.yml'
  conf.write_text('global:\n  scrape_interval: 30s\nrule_files:\n  - '+str(rules)+'/*.yml\nscrape_configs: []\n')
  names=[f'node_prod_v{version}.yml',f'recording_prod_v{version}.yml',f'prometheus_prod_v{version}.yml'] if partial else ['node_alerts.yml','node_recording.yml','prometheus_self.yml']
  for i,name in enumerate(names+['business_custom.yml']):
   (rules/name).write_text(f'groups:\n- name: previous{i}\n  rules:\n  - record: previous_metric_{i}\n    expr: vector({i})\n')
  before=snapshot(rules)
  setup=setup_block.replace('/填写仓库绝对路径',str(root)).replace('/填写Prometheus实际主配置绝对路径',str(conf)).replace('/填写主配置实际加载的规则目录',str(rules)).replace('/填写现场配套promtool绝对路径',str(promtool)).replace('WITH_TLS=1','WITH_TLS=0')
  replacement=replace_block
  if partial:replacement=replacement.replace('  install -m 0644 "$source" "$RULE_DIR/$file"','  install -m 0644 "$source" "$RULE_DIR/$file"\n  exit 77')
  run=subprocess.run(['bash'],input=setup+'\n'+replacement+('\n'+config_block if not partial else ''),text=True,capture_output=True)
  assert run.returncode==(77 if partial else 0),run.stdout+run.stderr
  stage=re.search(r'暂存目录：(.*)',run.stdout).group(1);backup=re.search(r'回退备份：(.*)',run.stdout).group(1)
  assert (rules/'business_custom.yml').read_bytes()==before['business_custom.yml']
  if not partial:assert set(snapshot(rules))=={'business_custom.yml',f'node_prod_v{version}.yml',f'recording_prod_v{version}.yml',f'prometheus_prod_v{version}.yml'}
  restore=f'set -euo pipefail\nRULE_DIR={str(rules)!r}\nSTAGE_DIR={stage!r}\nBACKUP_DIR={backup!r}\nPROM_CONFIG={str(conf)!r}\nPROMTOOL={str(promtool)!r}\n'+rollback_block
  back=subprocess.run(['bash'],input=restore,text=True,capture_output=True)
  assert back.returncode==0,back.stdout+back.stderr
  assert snapshot(rules)==before,'Rollback failed to restore exact original rule files'
  shutil.rmtree(stage);shutil.rmtree(backup)
  print('PASS:', 'partial-copy failure rollback' if partial else 'normal replacement + rollback','; custom business rule preserved; original files restored exactly')
