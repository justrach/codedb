#!/usr/bin/env python3
"""Measure real default hybrid requests and the hosted-Jina/OpenPuffer boundary."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time
from jina_eval import context, load_dataset, relevance, sha256


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',required=True)
    p.add_argument('--source',required=True)
    p.add_argument('--dataset',required=True)
    p.add_argument('--work-dir',required=True)
    p.add_argument('--out',required=True)
    p.add_argument('--repeats',type=int,default=2)
    p.add_argument('--limit',type=int,default=0)
    p.add_argument('--build-only',action='store_true',help='Prepare the verified Jina sidecar without opening evaluation queries')
    a=p.parse_args()
    if a.repeats < 1 or a.limit < 0:p.error("repeats must be positive and limit nonnegative")
    binary=Path(a.binary).resolve();source=Path(a.source).resolve()
    dataset=load_dataset(a.dataset,source)
    queries=[q for q in dataset['queries'] if q['split']=='train' and q['kind']=='relevant']
    if a.limit:queries=queries[:a.limit]
    if a.build_only:queries=[]
    output=Path(a.out)
    if output.exists():raise ValueError('Use a new report filename')
    env={k:v for k,v in os.environ.items() if not k.startswith('CODEDB_EMBEDDINGS_')}
    env.update(CODEDB_NO_CLI_DAEMON='1',CODEDB_NO_TELEMETRY='1',NO_COLOR='1')
    Path(a.work_dir).resolve().mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='codedb-jina-hybrid-',dir=Path(a.work_dir).resolve()))
    report={'binary':str(binary),'binary_sha256':sha256(binary),'version':subprocess.check_output([str(binary),'--version'],text=True).strip(),
            'corpus_root':str(root),'dataset':dataset['id'],'mode':'default hybrid; no semantic override; live service on every measured request',
            'scope':'sidecar preparation only' if a.build_only else 'diagnostic on previously seen queries; not fresh held-out evaluation','rows':[],'failures':[]}
    for relative in dataset['corpus_files']:
        target=root/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((source/relative).read_bytes())
    try:
        for phase in ('no_sidecar','openpuffer_sidecar'):
            if phase=='openpuffer_sidecar':
                start=time.perf_counter()
                done=subprocess.run([str(binary),str(root),'semantic-index'],env=env,capture_output=True,text=True,timeout=300)
                report['build']={'exit_code':done.returncode,'wall_ms':(time.perf_counter()-start)*1000,'stdout':done.stdout.strip()}
                if done.returncode:raise RuntimeError('semantic-index failed')
                match=re.search(r'local sidecar: (.+?) \(',done.stdout)
                if not match:raise RuntimeError('No sidecar path in build output')
                data=Path(match.group(1)).read_bytes()
                model_len=struct.unpack_from('<H',data,32)[0]
                model=data[48:48+model_len].decode()
                report['sidecar']={'model':model,'dimensions':struct.unpack_from('<H',data,10)[0],
                    'records':struct.unpack_from('<I',data,12)[0],'magic':data[:8].decode(),'metadata_sha256':sha256(match.group(1))}
                if model!='jinaai/jina-embeddings-v2-base-code':raise RuntimeError('Wrong embedding model')
            for q in queries:
                row={'id':q['id'],'phase':phase,'query':q['query'],'kind':q['kind'],'samples':[]};report['rows'].append(row)
                for repeat in range(a.repeats):
                    # No semantic flag: exercise the current hybrid default.
                    sample=context(binary,root,env,q['query'])
                    row['samples'].append(sample)
                    status=sample['retrieval']['semantic']
                    expected='ann_applied' if phase=='openpuffer_sidecar' else 'applied_exact_fallback'
                    if status!=expected:report['failures'].append({'id':q['id'],'phase':phase,'status':status,'detail':sample['retrieval'].get('detail')})
                    if q['kind']=='relevant':sample['metrics']=relevance(sample['paths'],q['gold'])
    except (RuntimeError,ValueError,subprocess.TimeoutExpired) as e:
        report['failures'].append({'error':str(e) if not isinstance(e,subprocess.TimeoutExpired) else 'CLI timeout'})
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='rows'},indent=2))
    return int(bool(report['failures']))


if __name__=='__main__':raise SystemExit(main())
