#!/usr/bin/env python3
"""Live default-hybrid lifecycle: fresh root, index, edit, loss, restart, offline.

Uses generated non-private source and the hosted service; no model/API-key
override for live calls. Credentials use the existing machine enrollment.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time

from e2e_mcp_test import MCPProcess, do_initialize, reply_roots, all_tool_text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--root', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    root = Path(args.root).resolve()
    out = Path(args.out)
    if out.exists() or root.exists():
        parser.error('Use new root and report paths')
    root.mkdir(parents=True)
    (root / 'src').mkdir()
    source = root / 'src/session.py'
    source.write_text('def resetSessionDeadline(session):\n    session.deadline = 0\n    return session\n')
    (root / 'src/format.py').write_text('def formatTimestamp(value):\n    return str(value)\n')
    (root / '.env').write_text('FIXTURE_PRIVATE_MARKER=not-a-real-secret\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith('CODEDB_')}
    env.update(CODEDB_NO_TELEMETRY='1', CODEDB_NO_AUTO_UPDATE='1', CODEDB_NO_CLI_DAEMON='1')
    report = {'binary_sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(), 'checks': [], 'builds': [], 'failures': []}
    clients = []

    def start(roots=False, offline=False):
        child_env = dict(env)
        if offline:
            child_env['CODEDB_EMBEDDINGS_URL'] = 'http://127.0.0.1:1/v1/embeddings'
        p = MCPProcess(binary, [], cwd='/' if roots else str(root), env=child_env)
        clients.append(p)
        assert do_initialize(p, with_roots=roots)
        if roots:
            assert reply_roots(p, str(root))
        return p

    def query(p, label, expected, symbol='resetSessionDeadline', local=False):
        request = {'task': 'Find the implementation of ' + symbol, 'format': 'json'}
        if local:
            request['semantic'] = 'local'
        began = time.perf_counter()
        response = p.call_tool('codedb_context', request, timeout=45)
        text = all_tool_text(response)
        value = json.JSONDecoder().raw_decode(text[text.index('{'):])[0]
        retrieval = value['retrieval']
        paths = [item['path'] for section in value['sections'] if section['id'] == 'most_relevant_files' for item in section.get('items', [])]
        check = {'name': label, 'semantic': retrieval['semantic'], 'detail': retrieval['detail'],
                 'wall_ms': (time.perf_counter() - began) * 1000, 'paths': paths,
                 'ann_cache_hit': retrieval['ann_cache_hit']}
        report['checks'].append(check)
        assert retrieval['semantic'] == expected, check
        assert 'src/session.py' in paths and '.env' not in paths, check
        assert all(c['path'] != '.env' for c in retrieval['candidates'])
        print('PASS:', label, check['semantic'], check['detail'], flush=True)
        return check

    def build():
        began = time.perf_counter()
        done = subprocess.run([binary, str(root), 'semantic-index'], env=env, capture_output=True, text=True, timeout=180)
        report['builds'].append({'exit_code': done.returncode, 'seconds': time.perf_counter()-began})
        assert done.returncode == 0, done.stderr
        metadata = Path(re.search(r'local sidecar: (.+?) \(', done.stdout).group(1))
        assert (metadata.parent / 'project.txt').read_text().strip() == str(root)
        return metadata

    try:
        p = start(roots=True)
        query(p, 'fresh roots handshake, no setup', 'applied_exact_fallback')
        metadata = build()
        query(p, 'explicit index activates ANN in existing MCP session', 'ann_applied')
        assert query(p, 'second ANN query uses cache', 'ann_applied')['ann_cache_hit']
        source.write_text('def extendSessionDeadline(session):\n    session.deadline += 3600\n    return session\n')
        deadline = time.monotonic() + 10
        while True:
            symbols = all_tool_text(p.call_tool('codedb_symbol', {'name': 'extendSessionDeadline'}))
            if 'src/session.py' in symbols and 'extendSessionDeadline' in symbols:
                break
            assert time.monotonic() < deadline, 'Watcher did not observe edit'
            time.sleep(.1)
        query(p, 'edit preserves search through fallback', 'applied_exact_fallback', 'extendSessionDeadline')
        metadata = build()
        query(p, 'rebuild replaces stale generation in same session', 'ann_applied', 'extendSessionDeadline')
        raw = metadata.read_bytes()
        model_len, slab_len = struct.unpack_from('<HH', raw, 32)
        slab_name = raw[48+model_len:48+model_len+slab_len].decode()
        assert Path(slab_name).name == slab_name and slab_name.startswith('semantic-chunks-v3-')
        (metadata.parent / slab_name).unlink()
        query(p, 'missing graph falls back', 'applied_exact_fallback', 'extendSessionDeadline')
        metadata.unlink()
        query(p, 'missing metadata falls back after warm use', 'applied_exact_fallback', 'extendSessionDeadline')
        metadata.write_bytes(b'corrupt test sidecar')
        query(p, 'corrupt metadata falls back', 'applied_exact_fallback', 'extendSessionDeadline')
        build()
        p.close()
        clients.remove(p)
        p = start()
        query(p, 'restart reuses rebuilt ANN', 'ann_applied', 'extendSessionDeadline')
        offline = start(offline=True)
        query(offline, 'unreachable provider keeps local result', 'unavailable', 'extendSessionDeadline')
        query(offline, 'explicit local mode needs no provider', 'not_requested', 'extendSessionDeadline', local=True)
    except Exception as error:
        report['failures'].append({'type': type(error).__name__, 'detail': str(error)[:1500]})
    finally:
        for p in clients:
            p.close()
        out.write_text(json.dumps(report, indent=2) + '\n')
    return int(bool(report['failures']))


if __name__ == '__main__':
    raise SystemExit(main())
