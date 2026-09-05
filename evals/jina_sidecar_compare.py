#!/usr/bin/env python3
"""Real persistent-MCP comparison: hosted Jina on every default hybrid call."""
import argparse,json,math,os,statistics,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from e2e_mcp_test import MCPProcess,do_initialize,all_tool_text
from jina_eval import relevance,sha256


def run(a):
    a.baseline=str(Path(a.baseline).resolve())
    a.candidate=str(Path(a.candidate).resolve())
    report_source=json.loads(Path(a.corpus_report).read_text());root=report_source['corpus_root']
    if report_source['sidecar']['model']!='jinaai/jina-embeddings-v2-base-code':raise ValueError('Jina sidecar required')
    dataset=json.loads(Path(a.dataset).read_text())
    corpus=Path(root).resolve()
    for relative,expected in dataset['corpus_files'].items():
        path=(corpus/relative).resolve()
        if corpus not in path.parents or sha256(path)!=expected:
            raise ValueError('Corpus does not match the pinned dataset')
    queries=[q for q in dataset['queries'] if (a.split=='all' or q['split']==a.split) and q['kind']=='relevant']
    if not queries:raise ValueError('No relevant queries in selected split')
    target=Path(a.out)
    if target.exists():raise ValueError('Use a new result filename')
    for key in list(os.environ):
        if key.startswith('CODEDB_EMBEDDINGS_'):del os.environ[key]
    os.environ['CODEDB_NO_TELEMETRY']='1'
    freeze=None
    if a.freeze:
        freeze=json.loads(Path(a.freeze).read_text())
        if sha256(a.candidate)!=freeze['candidate_sha256'] or sha256(a.baseline)!=freeze['baseline_sha256'] or sha256(a.dataset)!=freeze['dataset_sha256']:
            raise ValueError('Frozen candidate, baseline, or holdout changed')
        if a.split!='held_out':raise ValueError('Frozen holdout requires held_out split')
    report={'mode':'persistent MCP; default hybrid; live embedding service per query; same Jina mmap sidecar',
            'scope':'frozen cross-repository holdout' if freeze else 'previously seen diagnostic queries; not held-out evidence',
            'freeze_sha256':sha256(a.freeze) if a.freeze else None,
            'baseline_sha256':sha256(a.baseline),'candidate_sha256':sha256(a.candidate),
            'dataset_sha256':sha256(a.dataset),'corpus_report_sha256':sha256(a.corpus_report),
            'sidecar':report_source['sidecar'],'rows':[],'failures':[]}
    clients={}
    try:
        for name,binary in [('baseline',a.baseline),('candidate',a.candidate)]:
            clients[name]=MCPProcess(binary,[],cwd=root,command=[binary,root,'mcp'])
            if not do_initialize(clients[name],with_roots=False):raise RuntimeError('MCP initialization failed')
        for q in queries:
            row={'id':q['id'],'samples':[]};report['rows'].append(row)
            for repeat in range(a.repeats):
                sample={};row['samples'].append(sample)
                for name in (['baseline','candidate'] if repeat%2==0 else ['candidate','baseline']):
                    start=time.perf_counter()
                    reply=clients[name].call_tool('codedb_context',{'task':q['query'],'format':'json','max_tokens':12000},timeout=45)
                    elapsed=(time.perf_counter()-start)*1000
                    text=all_tool_text(reply)
                    payload=json.JSONDecoder().raw_decode(text[text.index('{'):])[0]
                    paths=next((list(dict.fromkeys(i['path'] for i in s.get('items',[]))) for s in payload.get('sections',[]) if s['id']=='most_relevant_files'),[])
                    retrieval=payload['retrieval']
                    sample[name]={'paths':paths,'wall_ms':elapsed,'retrieval':retrieval,'metrics':relevance(paths,q['gold'])}
                    if retrieval['semantic']!='ann_applied' or retrieval['documents_sent']!=2 or not retrieval['ann_mmap_backed']:
                        report['failures'].append({'id':q['id'],'mode':name,'reason':'Jina sidecar path not used','status':retrieval['semantic']})
    except (RuntimeError,ValueError,KeyError) as e:
        report['failures'].append({'error':type(e).__name__,'reason':str(e)[:160]})
    finally:
        for client in clients.values():client.close()
    for name,binary in [('baseline',a.baseline),('candidate',a.candidate)]:
        if sha256(binary)!=report[name+'_sha256']:
            report['failures'].append({'mode':name,'reason':'Binary changed during evaluation'})
    report['summary']={}
    for name in ('baseline','candidate'):
        samples=[s[name] for r in report['rows'] for s in r['samples'] if name in s]
        if samples:
            times=sorted(s['wall_ms'] for s in samples)
            report['summary'][name]={'samples':len(samples),'ndcg_at_5':statistics.mean(s['metrics']['ndcg_at_5'] for s in samples),
                'recall_at_5':statistics.mean(s['metrics']['recall_at_5'] for s in samples),
                'top1_rate':statistics.mean(s['metrics']['mrr_at_5']==1 for s in samples),
                'median_ms':statistics.median(times),'p95_ms':times[math.ceil(.95*len(times))-1],
                'mean_ann_files':statistics.mean(len(s['retrieval']['candidates']) for s in samples),
                'mean_search_ns':statistics.mean(s['retrieval']['ann_search_ns'] for s in samples),
                'cache_hits':sum(s['retrieval']['ann_cache_hit'] for s in samples)}
    report['complete'] = len(report['rows']) == len(queries) and all(len(r['samples']) == a.repeats and all(set(s)=={'baseline','candidate'} for s in r['samples']) for r in report['rows'])
    report['recall_regressions'] = [r['id'] for r in report['rows'] if any(s.get('candidate',{}).get('metrics',{}).get('recall_at_5',0) < s.get('baseline',{}).get('metrics',{}).get('recall_at_5',0) for s in r['samples'])]
    report['ranking_regressions'] = [r['id'] for r in report['rows'] if any(s.get('candidate',{}).get('metrics',{}).get('mrr_at_5',0) < s.get('baseline',{}).get('metrics',{}).get('mrr_at_5',0) for s in r['samples'])]
    target.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'summary':report['summary'],'failures':report['failures']},indent=2))
    return int(bool(report['failures']) or not report['complete'])


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for n in ('baseline','candidate','dataset','corpus-report','out'):p.add_argument('--'+n,required=True)
    p.add_argument('--repeats',type=int,default=3)
    p.add_argument('--split',choices=('train','held_out','all'),default='train')
    p.add_argument('--freeze',help='Verify candidate and dataset hashes against the pre-evaluation freeze')
    a=p.parse_args()
    if a.repeats<1:p.error('positive repeats required')
    raise SystemExit(run(a))
