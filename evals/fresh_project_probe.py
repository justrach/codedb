#!/usr/bin/env python3
"""Probe a full fresh repository without preselected files or prepared indexes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from e2e_mcp_test import MCPProcess, do_initialize, all_tool_text


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ('binary', 'source', 'dataset', 'root', 'out'):
        p.add_argument('--' + key, required=True)
    p.add_argument('--build-semantic', action='store_true', help='Explicitly build ANN before querying; this is the setup-required comparison')
    a = p.parse_args()
    binary, source, root, out = (Path(value).resolve() for value in (a.binary, a.source, a.root, a.out))
    if root.exists() or out.exists():
        p.error('Use a fresh root and report path')
    dataset = json.loads(Path(a.dataset).read_text())
    revision = dataset['source_revision']
    if not re.fullmatch('[0-9a-f]{40}', revision):
        p.error('Dataset must pin a full Git commit hash')
    root.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', 'clone', '--quiet', '--no-hardlinks', str(source), str(root)], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'core.hooksPath=/dev/null', 'checkout', '--quiet', '--detach', revision], check=True)
    # Keep the entire checkout. Hash verification validates the labeled files;
    # it does not remove other indexed source, documentation, or examples.
    for relative, expected in dataset['corpus_files'].items():
        target = (root / relative).resolve()
        if root not in target.parents or sha256(target) != expected:
            raise ValueError('Labeled source does not match the pinned dataset')
    if (root / 'codedb.snapshot').exists():
        raise ValueError('Fixture already contains a snapshot')
    env = {k: v for k, v in os.environ.items() if not k.startswith('CODEDB_')}
    env.update(CODEDB_NO_TELEMETRY='1', CODEDB_NO_AUTO_UPDATE='1', CODEDB_NO_CLI_DAEMON='1')
    report = {'binary_sha256': sha256(binary), 'dataset_sha256': sha256(a.dataset),
              'revision': revision, 'root': str(root),
              'mode': 'explicit ANN setup' if a.build_semantic else 'fresh project; no indexing commands',
              'limits': 'Observed diagnostic queries, not fresh holdout. Existing machine enrollment. No semantic/API-key override. Default token budget; JSON only for measurement.',
              'queries': [], 'failures': []}
    client = None
    try:
        if a.build_semantic:
            start = time.perf_counter()
            done = subprocess.run([str(binary), str(root), 'semantic-index'], env=env, capture_output=True, text=True, timeout=900)
            report['build'] = {'exit_code': done.returncode, 'seconds': time.perf_counter() - start, 'stdout': done.stdout}
            if done.returncode:
                raise RuntimeError('Semantic build failed: ' + done.stderr[-1000:])
        client = MCPProcess(str(binary), [], cwd=str(root), env=env)
        if not do_initialize(client, with_roots=False):
            raise RuntimeError('MCP initialization failed')
        for q in dataset['queries']:
            if q['kind'] != 'relevant':
                continue
            start = time.perf_counter()
            response = client.call_tool('codedb_context', {'task': q['query'], 'format': 'json'}, timeout=45)
            text = all_tool_text(response)
            payload = json.JSONDecoder().raw_decode(text[text.index('{'):])[0]
            paths = next((list(dict.fromkeys(i['path'] for i in section.get('items', []))) for section in payload['sections'] if section['id'] == 'most_relevant_files'), [])
            rank = next((i+1 for i, path in enumerate(paths[:5]) if q['gold'].get(path, 0) > 0), None)
            r = payload['retrieval']
            report['queries'].append({'id': q['id'], 'query': q['query'], 'gold': q['gold'], 'rank': rank,
                                      'top5': paths[:5], 'semantic': r['semantic'], 'detail': r['detail'],
                                      'documents_sent': r['documents_sent'], 'wall_ms': (time.perf_counter()-start)*1000})
        report['status'] = all_tool_text(client.call_tool('codedb_status', {}))
    except Exception as error:
        report['failures'].append({'type': type(error).__name__, 'detail': str(error)[:1500]})
    finally:
        if client:
            client.close()
        if sha256(binary) != report['binary_sha256']:
            report['failures'].append({'type': 'BinaryChanged'})
        with out.open('x') as stream:
            json.dump(report, stream, indent=2)
            stream.write('\n')
    print(json.dumps({'questions': len(report['queries']), 'first': sum(q['rank'] == 1 for q in report['queries']),
                      'top5': sum(q['rank'] is not None for q in report['queries']), 'failures': report['failures']}))
    return int(bool(report['failures']))


if __name__ == '__main__':
    raise SystemExit(main())
