#!/usr/bin/env python3
"""Compare frozen binaries across pinned live-Jina datasets without mixing holdout into tuning."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--suite', default=str(Path(__file__).parent / 'suites/jina-accuracy-round3.json'))
    p.add_argument('--baseline', required=True)
    p.add_argument('--candidate', required=True)
    p.add_argument('--out-dir', required=True)
    p.add_argument('--group', choices=('development', 'holdout'), default='development')
    p.add_argument('--repos', help='Optional comma-separated subset within the selected group')
    p.add_argument('--repeats', type=int, default=2)
    p.add_argument('--freeze', help='Required for the single held-out repository')
    a = p.parse_args()
    if a.repeats < 1:
        p.error('repeats must be positive')
    base = Path(__file__).resolve().parent
    suite = json.loads(Path(a.suite).read_text())
    repos = [r for r in suite['repositories'] if r['group'] == a.group]
    if a.repos:
        names = set(a.repos.split(','))
        if not names.issubset({r['name'] for r in repos}):
            p.error('Requested repository is not in the selected group')
        repos = [r for r in repos if r['name'] in names]
    if a.group == 'holdout' and (not a.freeze or len(repos) != 1):
        p.error('Holdout comparison requires one repository and a pre-evaluation freeze')
    out = Path(a.out_dir).resolve()
    out.mkdir(parents=True, exist_ok=False)
    results = {}
    failed = False
    for repo in repos:
        result = out / (repo['name'] + '.json')
        command = [sys.executable, str(base / 'jina_sidecar_compare.py'),
                   '--baseline', str(Path(a.baseline).resolve()), '--candidate', str(Path(a.candidate).resolve()),
                   '--dataset', str(base / repo['dataset']), '--corpus-report', str(base / repo['corpus_report']),
                   '--split', 'held_out' if a.group == 'holdout' else 'all',
                   '--repeats', str(a.repeats), '--out', str(result)]
        if a.freeze:
            command += ['--freeze', str(Path(a.freeze).resolve())]
        with (out / (repo['name'] + '.log')).open('w') as log:
            done = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        if done.returncode or not result.exists():
            failed = True
            results[repo['name']] = {'execution_failed': True}
        else:
            report = json.loads(result.read_text())
            results[repo['name']] = {k: report[k] for k in ('summary', 'complete', 'failures', 'recall_regressions', 'ranking_regressions')}
        print(repo['name'] + ': ' + ('failed' if 'execution_failed' in results[repo['name']] else 'complete'), flush=True)
    summary = {'group': a.group, 'repositories': results, 'complete': not failed}
    if not failed:
        summary['macro_average'] = {
            arm: {metric: statistics.mean(r['summary'][arm][metric] for r in results.values())
                  for metric in ('top1_rate', 'ndcg_at_5', 'recall_at_5')}
            for arm in ('baseline', 'candidate')}
        summary['recall_regressions'] = {name: r['recall_regressions'] for name, r in results.items() if r['recall_regressions']}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
