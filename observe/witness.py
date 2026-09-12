#!/usr/bin/env python3
"""witness：30s 采样 NMS 四端点（/nodes /alerts /agent-deploy /topology）→ $SOAK_ENV/evidence/witness.jsonl（阶段一全程运行）。
拓扑采样（D8 卫生批）：parent 映射 {target: source} 逐样本入档，树形时间线可回放
（挂接/重挂/疏散全过程不再只靠 g5 终态验收一件）。
证据根经 SOAK_ENV 注入（运行时目录，含 evidence/）；用法：
  SOAK_ENV=<运行时目录> python3 scripts/soak/observe/witness.py
"""
import json, os, subprocess, sys, time, datetime

SOAK_ENV = os.environ.get('SOAK_ENV')
if not SOAK_ENV:
    sys.exit('SOAK_ENV 未设置：export SOAK_ENV=<运行时目录>（含 evidence/，用法见 scripts/soak/README.md）')
EV = os.path.join(SOAK_ENV, 'evidence')
os.makedirs(EV, exist_ok=True)
OUT = os.path.join(EV, 'witness.jsonl')

def ip():
    return open(os.path.join(EV, 'nms-ip.txt')).read().strip()

def get(path):
    r = subprocess.run(['curl', '-sS', '-m', '10', f'http://{ip()}/api/v1{path}'],
                       capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None

while True:
    rec = {'ts': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}
    try:
        nodes = get('/nodes')
        if nodes:
            items = nodes.get('items', [])
            rec['nodes_total'] = len(items)
            rec['by_state'] = {f'{r}|{s}|{c}': sum(1 for n in items if n['role'] == r and n['status'] == s and n['collection_state'] == c)
                               for r, s, c in {(n['role'], n['status'], n['collection_state']) for n in items}}
        alerts = get('/alerts?status=active&limit=200')
        if alerts is not None:
            rec['active_alerts'] = alerts.get('total', len(alerts.get('items', [])))
        dep = get('/agent-deploy')
        if dep is not None:
            rec['deploy_rounds'] = [(i.get('deploy_id'), i.get('status'), i.get('nodes')) for i in dep.get('items', [])]
        topo = get('/topology')
        if topo:
            links = topo.get('links', [])
            rec['topo_links'] = len(links)
            rec['topo_parents'] = {l['target']: l['source'] for l in links}
    except Exception as e:
        rec['error'] = repr(e)
    with open(OUT, 'a') as f:
        f.write(json.dumps(rec, ensure_ascii=False) + '\n')
    time.sleep(30)
