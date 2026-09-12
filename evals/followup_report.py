#!/usr/bin/env python3
"""Build a portable, hash-verified view of frozen accuracy and live latency data.

No network, embedding requests, source snippets, or ranking changes. Diagnostic
timings stay separate from the frozen accuracy run. Repetitions are not counted
as independent questions. Existing output files are never overwritten.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def distribution(values):
    if not values or any(not math.isfinite(v) or v < 0 for v in values):
        raise ValueError('Expected nonempty finite nonnegative timing samples')
    ordered = sorted(values)
    return {'samples': len(values), 'median': statistics.median(values),
            'p95': ordered[math.ceil(.95 * len(ordered)) - 1]}


def rank(paths, gold):
    return next((i + 1 for i, path in enumerate(paths[:5]) if gold.get(path, 0) > 0), None)


def checked_report(path, expected_hash=None):
    if expected_hash and sha256(path) != expected_hash:
        raise ValueError(f'Raw report hash mismatch: {path}')
    raw = json.loads(Path(path).read_text())
    if not raw.get('complete') or raw.get('failures'):
        raise ValueError(f'Incomplete or failed run: {path}')
    for row in raw['rows']:
        if not row['samples']:
            raise ValueError('Missing paired samples')
        for sample in row['samples']:
            for arm in ('baseline', 'candidate'):
                r = sample[arm]['retrieval']
                if r['semantic'] != 'ann_applied' or r['documents_sent'] != 2 or not r['ann_mmap_backed']:
                    raise ValueError('Fallback samples cannot count as ANN evidence')
    return raw


def timing_report(raw):
    result = {}
    for arm in ('baseline', 'candidate'):
        # Warm-only: cold generation validation is a different workload.
        samples = [s[arm] for row in raw['rows'] for s in row['samples']
                   if s[arm]['retrieval']['ann_cache_hit']]
        stages = {key: [] for key in ('wall_ms', 'embed_ms', 'load_ms', 'ann_ms',
                                      'wall_minus_embed_ms', 'embed_share_percent')}
        for sample in samples:
            r = sample['retrieval']
            # Never interpret older reports without this field as zero time.
            embed = r['ann_embed_ns'] / 1e6
            wall = sample['wall_ms']
            stages['wall_ms'].append(wall)
            stages['embed_ms'].append(embed)
            stages['load_ms'].append(r['ann_load_ns'] / 1e6)
            stages['ann_ms'].append(r['ann_search_ns'] / 1e6)
            stages['wall_minus_embed_ms'].append(wall - embed)
            stages['embed_share_percent'].append(100 * embed / wall)
        result[arm] = {key: distribution(values) for key, values in stages.items()}
    result['flags'] = []
    for stage in ('wall_ms', 'embed_ms', 'load_ms', 'ann_ms', 'wall_minus_embed_ms'):
        for stat in ('median', 'p95'):
            before, after = result['baseline'][stage][stat], result['candidate'][stage][stat]
            if before > 0 and after > before * 1.1:
                result['flags'].append({'stage': stage, 'statistic': stat,
                                        'increase_percent': (after / before - 1) * 100,
                                        'increase_ms': after - before})
    return result


def build(summary_path, latency_dir=None):
    frozen = json.loads(Path(summary_path).read_text())
    diagnostic_binaries = None
    out = {'schema': 1, 'summary_sha256': sha256(summary_path),
           'accuracy_run': 'Frozen candidate c47e0224 versus released v0.2.5855; two repeats',
           'status': 'Candidate is unreleased; ranking regression and performance review remain open',
           'timing_note': 'Warm samples only. Embedding includes transport, service, decoding and bounded retry. Wall minus embedding includes local work, scheduling and MCP overhead; it is not a CPU profile.',
           'repositories': {}, 'queries': [], 'latency': {}, 'sources': [],
           'original_timing_flags': frozen['timing_flags']}
    for name, saved in frozen['repositories'].items():
        path = Path(saved['raw_report'])
        raw = checked_report(path, saved['raw_report_sha256'])
        for field in ('baseline_sha256', 'candidate_sha256', 'dataset_sha256'):
            if raw[field] != saved[field]:
                raise ValueError(f'{name}: inconsistent {field}')
        by_id = {r['id']: r for r in raw['rows']}
        if len(by_id) != len(raw['rows']) or set(by_id) != {q['id'] for q in saved['queries']}:
            raise ValueError(f'{name}: duplicate or missing query IDs')
        out['sources'].append({'repository': name, 'kind': 'accuracy',
                               'file': path.name, 'sha256': sha256(path)})
        queries = []
        for q in saved['queries']:
            row = by_id[q['id']]
            if len(row['samples']) != q['repeats']:
                raise ValueError('Missing repeats')
            for sample in row['samples']:
                for arm in ('baseline', 'candidate'):
                    if rank(sample[arm]['paths'], q['gold']) != q[arm + '_rank']:
                        raise ValueError('Repeated ranks differ; report distributions instead of a single rank')
            candidate = row['samples'][0]['candidate']['retrieval']
            evidence = [{k: c[k] for k in ('path', 'lexical_rank', 'semantic_rank',
                         'whole_query_rank', 'semantic_score', 'semantic_documentation') if k in c}
                        for c in candidate['candidates']]
            gold_evidence = [c for c in evidence if q['gold'].get(c['path'], 0) > 0]
            b, c = q['baseline_rank'] or 6, q['candidate_rank'] or 6
            status = 'regressed' if c > b else 'improved' if c < b else 'stable'
            category = 'correct first' if c == 1 else (
                'missing from top five' if c > 5 else
                'lexical first, semantic disagreement' if any(g.get('lexical_rank') == 0 for g in gold_evidence)
                else 'specific behavior outranked by related files')
            item = {**q, 'repository': name, 'status': status, 'diagnosis': category,
                    'gold_in_ann_candidates': bool(gold_evidence),
                    'candidate_evidence': evidence,
                    'rank_note': 'Result ranks are one-based; lane ranks are zero-based.'}
            queries.append(item)
        out['queries'].extend(queries)
        out['repositories'][name] = {
            'scope': saved['scope'] + '; now observed', 'questions': len(queries),
            'baseline_first': sum(q['baseline_rank'] == 1 for q in queries),
            'candidate_first': sum(q['candidate_rank'] == 1 for q in queries),
            'candidate_top5': sum(q['candidate_rank'] is not None for q in queries),
            'regressions': sum(q['status'] == 'regressed' for q in queries),
            'original_timings': {arm: {k: saved['summary'][arm][k] for k in ('median_ms', 'p95_ms')}
                                 for arm in ('baseline', 'candidate')}}
        if latency_dir:
            lp = Path(latency_dir) / (name + '.json')
            diagnostic = checked_report(lp)
            if diagnostic['dataset_sha256'] != saved['dataset_sha256']:
                raise ValueError('Diagnostic used a different dataset')
            pair = {arm: diagnostic[arm + '_sha256'] for arm in ('baseline', 'candidate')}
            if diagnostic_binaries is not None and pair != diagnostic_binaries:
                raise ValueError('Diagnostic binaries changed between repositories')
            diagnostic_binaries = pair
            if {r['id'] for r in diagnostic['rows']} != set(by_id):
                raise ValueError('Diagnostic query coverage differs from frozen run')
            out['latency'][name] = timing_report(diagnostic)
            frozen_queries = {q['id']: q for q in saved['queries']}
            out['latency'][name]['ranking_changes_from_frozen'] = [
                {'id': row['id'], 'arm': arm, 'repeat': repeat,
                 'frozen_rank': frozen_queries[row['id']][arm + '_rank'],
                 'diagnostic_rank': rank(sample[arm]['paths'], frozen_queries[row['id']]['gold'])}
                for row in diagnostic['rows'] for repeat, sample in enumerate(row['samples'])
                for arm in ('baseline', 'candidate')
                if rank(sample[arm]['paths'], frozen_queries[row['id']]['gold']) != frozen_queries[row['id']][arm + '_rank']]
            out['sources'].append({'repository': name, 'kind': 'timing diagnostic',
                                   'file': lp.name, 'sha256': sha256(lp),
                                   'baseline_sha256': diagnostic['baseline_sha256'],
                                   'candidate_sha256': diagnostic['candidate_sha256']})
    out['comparison_cases'] = [
        {'repository': q['repository'], 'id': q['id'], 'query': q['query'],
         'expected_paths': [p for p, grade in q['gold'].items() if grade > 0],
         'competing_first_path': q['candidate_top5'][0] if q['candidate_top5'] else None,
         'diagnosis': q['diagnosis'], 'regressed': q['status'] == 'regressed'}
        for q in out['queries'] if q['candidate_rank'] != 1]
    out['comparison_case_scope'] = 'Observed diagnostic pairs, not fresh validation or training evidence. No model is trained by this tool.'
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--summary', required=True)
    p.add_argument('--latency-dir')
    p.add_argument('--out', required=True)
    p.add_argument('--dashboard-out', help='Also write the interactive conversation fragment')
    args = p.parse_args()
    report = build(args.summary, args.latency_dir)
    with Path(args.out).open('x') as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
        stream.write('\n')
    if args.dashboard_out:
        template = Path(__file__).with_name('followup-dashboard.html').read_text()
        # Report strings are data, never markup or executable JavaScript.
        encoded = json.dumps(report, allow_nan=False).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
        with Path(args.dashboard_out).open('x') as stream:
            stream.write(template.replace('__CODEDB_REPORT_JSON__', encoded))
    print(f"Verified {len(report['queries'])} unique questions in {len(report['repositories'])} repositories")


if __name__ == '__main__':
    main()
