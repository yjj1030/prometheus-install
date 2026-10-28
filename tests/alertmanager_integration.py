#!/usr/bin/env python3
"""Exercise inhibition in an isolated real Alertmanager; no external receivers."""
from pathlib import Path
import argparse,datetime,json,os,socket,subprocess,tempfile,time,urllib.request
import yaml

ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--alertmanager',default=os.environ.get('ALERTMANAGER','alertmanager'));a=p.parse_args()
    config=yaml.safe_load((ROOT/'scenarios/sk-91/alertmanager.example.yml').read_text())
    config['route']={'receiver':'local-only','group_by':['alertname'],'group_wait':'1h'}
    config['receivers']=[{'name':'local-only'}]
    with tempfile.TemporaryDirectory() as tmp:
        tmp=Path(tmp);f=tmp/'alertmanager.yml';f.write_text(yaml.safe_dump(config))
        with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        url=f'http://127.0.0.1:{port}'
        with (tmp/'log').open('w+') as log:
            proc=subprocess.Popen([a.alertmanager,'--config.file='+str(f),'--storage.path='+str(tmp/'data'),'--web.listen-address=127.0.0.1:'+str(port),'--cluster.listen-address='],stdout=log,stderr=log)
            try:
                for _ in range(100):
                    try:
                        with urllib.request.urlopen(url+'/-/ready',timeout=1):break
                    except Exception:
                        if proc.poll() is not None:raise RuntimeError('Alertmanager exited before ready')
                        time.sleep(0.1)
                else:raise RuntimeError('Alertmanager not ready')
                base={'site':'example','origin_prometheus':'evaluator-a','environment_class':'prod','job':'node_exporter','instance':'host-a:9100','condition_id':'cpu','severity':'warning','asset_type':'server','alert_type':'threshold','category':'compute'}
                specs=[
                    ('CpuCritical',{'severity':'critical'},False),
                    ('CpuWarning',{},True),
                    ('OtherHost',{'instance':'host-b:9100'},False),
                    ('OtherSite',{'site':'another'},False),
                    ('OtherEvaluator',{'origin_prometheus':'evaluator-b'},False),
                    ('OtherCondition',{'condition_id':'memory'},False),
                    ('MissingIdentity',{'instance':''},False),
                    ('MissingScope',{'site':''},False),
                    ('DiskEmergency',{'severity':'emergency','condition_id':'disk','device':'/dev/vda1','mountpoint':'/'},False),
                    ('DiskCritical',{'severity':'critical','condition_id':'disk','device':'/dev/vda1','mountpoint':'/'},True),
                    ('OtherMount',{'condition_id':'disk','device':'/dev/vdb1','mountpoint':'/data'},False),
                    ('HostDown',{'condition_id':'node_down','severity':'critical','instance':'host-c:9100','category':'availability','alert_type':'state'},False),
                    ('HostResource',{'condition_id':'memory','instance':'host-c:9100','category':'memory'},True),
                    ('HostOOM',{'condition_id':'oom','instance':'host-c:9100','category':'memory','severity':'critical','alert_type':'event'},False),
                ]
                now=datetime.datetime.now(datetime.timezone.utc)
                payload=[{'labels':dict(base,alertname=n,**changes),'startsAt':(now-datetime.timedelta(minutes=1)).isoformat(),'endsAt':(now+datetime.timedelta(hours=1)).isoformat(),'annotations':{'summary':'Local inhibition test'}} for n,changes,_ in specs]
                request=urllib.request.Request(url+'/api/v2/alerts',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'},method='POST')
                with urllib.request.urlopen(request,timeout=5):pass
                expected={n:inhibited for n,_,inhibited in specs};last={}
                for _ in range(50):
                    with urllib.request.urlopen(url+'/api/v2/alerts',timeout=5) as response:data=json.load(response)
                    last={r['labels']['alertname']:bool(r['status']['inhibitedBy']) for r in data}
                    if last==expected:break
                    time.sleep(0.1)
                assert last==expected,f'Expected {expected}; got {last}'
                print(f'PASS: {len(expected)} inhibition assertions; no external receivers')
            finally:
                proc.terminate()
                try:proc.wait(timeout=5)
                except subprocess.TimeoutExpired:proc.kill();proc.wait()

if __name__=='__main__':main()
