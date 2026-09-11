#!/usr/bin/env python3
"""Deterministic semantic failure/recovery checks, with no external service.

The loopback fixture returns synthetic vectors, not model inference. These tests
measure protocol and lifecycle contracts, never retrieval accuracy. Use a new
fixture root beneath an admitted project parent (for example ~/tmp).
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import threading
import time
import traceback

from e2e_mcp_test import MCPProcess, all_tool_text, do_initialize


class Provider:
    def __init__(self):
        self.lock = threading.Lock()
        self.mode = 'valid'
        self.requests = []
        self.all_inputs = []
        self.entered = threading.Event()
        self.release = threading.Event()

    def reset(self, mode='valid'):
        with self.lock:
            self.mode = mode
            self.requests = []
        self.entered.clear()
        self.release.clear()

    def count(self):
        with self.lock:
            return len(self.requests)

    def handler(self):
        provider = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                inputs = payload['input']
                assert isinstance(inputs, list)
                with provider.lock:
                    provider.requests.append(inputs)
                    provider.all_inputs.extend(inputs)
                    number = len(provider.requests)
                    mode = provider.mode
                is_chunk = any(s.startswith('Code snippet\nPath:') for s in inputs)
                if mode == 'pause_chunks' and is_chunk:
                    provider.entered.set()
                    if not provider.release.wait(15):
                        return
                if mode == 'slow' or (mode == 'drop_then_slow' and number > 1):
                    time.sleep(1)
                if mode == 'drop' or (mode in ('drop_once', 'drop_then_slow') and number == 1):
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                status = 200
                if mode.startswith('http_'):
                    status = int(mode.split('_')[1])
                if mode == 'reject_chunks' and is_chunk:
                    status = 503
                if mode == 'retry_chunks' and is_chunk and number == 2:
                    status = 429
                rows = []
                for i, text in enumerate(inputs):
                    seed = hashlib.sha512(text.encode()).digest()
                    vector = [(b - 127.5) / 128 for b in seed]
                    if mode == 'dimensions':
                        vector = vector[:-1]
                    elif mode == 'zero':
                        vector = [0.0] * 64
                    elif mode == 'nonfinite':
                        vector[0] = 1e100
                    rows.append({'index': 0 if mode == 'duplicate' else i, 'embedding': vector})
                response = {'model': 'wrong-model' if mode == 'model' else payload['model'], 'data': rows}
                body = b'{broken json' if mode == 'malformed' else json.dumps(response).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # Expected after timeout/cancellation.

        return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--root', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    root, out = Path(args.root).resolve(), Path(args.out).resolve()
    if root.exists() or out.exists():
        parser.error('Use new root and report paths')
    root.mkdir(parents=True)
    (root / 'src').mkdir()
    source = root / 'src/session.py'
    original = 'def resetSessionDeadline(session):\n    session.deadline = 0\n    return session\n'
    source.write_text(original)
    (root / 'src/format.py').write_text('def formatTimestamp(value):\n    return str(value)\n')
    marker = 'SYNTHETIC_PRIVATE_MUST_NOT_BE_SENT'
    for name in ['.env', 'credentials.json', 'private.key']:
        (root / name).write_text(marker)
    provider = Provider()
    server = ThreadingHTTPServer(('127.0.0.1', 0), provider.handler())
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = {k: v for k, v in os.environ.items() if not k.startswith('CODEDB_')}
    env.update(CODEDB_NO_TELEMETRY='1', CODEDB_NO_AUTO_UPDATE='1', CODEDB_NO_CLI_DAEMON='1',
               CODEDB_EMBEDDINGS_URL=f'http://127.0.0.1:{server.server_port}/v1/embeddings',
               CODEDB_EMBEDDINGS_MODEL='fault-fixture', CODEDB_EMBEDDINGS_TOKEN='synthetic-fixture-token',
               CODEDB_EMBEDDINGS_DIMENSIONS='64', CODEDB_EMBEDDINGS_TIMEOUT_MS='300',
               CODEDB_SEMANTIC_INDEX_CONCURRENCY='1')
    report = {'binary_sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
              'scope': 'Synthetic loopback transport and lifecycle checks. No model or live accuracy evaluation.',
              'checks': [], 'failures': []}
    clients, builders = [], []

    def check(name, **details):
        report['checks'].append({'name': name, **details})
        print('PASS:', name, flush=True)

    def start():
        p = MCPProcess(binary, [], cwd=str(root), env=env)
        clients.append(p)
        assert do_initialize(p, with_roots=False)
        return p

    def query(p, expected, detail=None, local=False):
        began = time.monotonic()
        request = {'task': 'Find the implementation of resetSessionDeadline', 'format': 'json'}
        if local:
            request['semantic'] = 'local'
        text = all_tool_text(p.call_tool('codedb_context', request, timeout=10))
        assert '{' in text, ('Missing structured context', text[:1000])
        value = json.JSONDecoder().raw_decode(text[text.index('{'):])[0]
        r = value['retrieval']
        paths = [i['path'] for s in value['sections'] if s['id'] == 'most_relevant_files' for i in s.get('items', [])]
        assert r['semantic'] == expected, (expected, r['semantic'], r['detail'])
        if detail:
            assert r['detail'] == detail, (detail, r['detail'])
        assert 'src/session.py' in paths, paths
        assert not any(x in paths for x in ['.env', 'credentials.json', 'private.key']), paths
        assert marker not in json.dumps(provider.all_inputs), 'Private fixture reached provider'
        return {'semantic': r['semantic'], 'detail': r['detail'], 'ann_cache_hit': r['ann_cache_hit'], 'wall_ms': round((time.monotonic()-began)*1000, 2)}

    def build_start():
        child_env = {**env, 'CODEDB_EMBEDDINGS_TIMEOUT_MS': '10000'}
        p = subprocess.Popen([binary, str(root), 'semantic-index'], env=child_env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        builders.append(p)
        return p

    def build_finish(p, expected=0):
        stdout, stderr = p.communicate(timeout=30)
        assert (p.returncode == 0) == (expected == 0), (p.returncode, stdout, stderr)
        return stdout, stderr

    def build():
        stdout, _ = build_finish(build_start())
        return Path(re.search(r'local sidecar: (.+?) \(', stdout).group(1))

    def generation(metadata):
        raw = metadata.read_bytes()
        model_len, slab_len = struct.unpack_from('<HH', raw, 32)
        name = raw[48+model_len:48+model_len+slab_len].decode()
        assert Path(name).name == name and name.startswith('semantic-chunks-v3-')
        return {metadata.name: hashlib.sha256(raw).hexdigest(),
                name: hashlib.sha256((metadata.parent/name).read_bytes()).hexdigest()}

    try:
        p = start()
        check('fresh project uses bounded fallback', **query(p, 'applied_exact_fallback', 'AnnIndexMissing'))
        provider.reset()
        result = query(p, 'not_requested', local=True)
        assert provider.count() == 0
        check('local-only query sends no request', **result)
        cases = [('http_401', 'EmbeddingProviderRejected'), ('http_429', 'EmbeddingRateLimited'),
                 ('http_503', 'EmbeddingProviderUnavailable'), ('malformed', None),
                 ('dimensions', 'InvalidEmbeddingDimensions'), ('duplicate', 'InvalidEmbeddingResponse'),
                 ('model', 'EmbeddingModelMismatch'), ('nonfinite', 'InvalidEmbeddingNumber'),
                 ('zero', 'InvalidEmbeddingVector'), ('slow', 'EmbeddingTimeout')]
        for mode, detail in cases:
            provider.reset(mode)
            result = query(p, 'unavailable', detail)
            assert result['wall_ms'] < 3000, (mode, result)
            assert provider.count() == 1, (mode, provider.count())
            provider.reset()
            query(p, 'applied_exact_fallback')
            check(mode + ' preserves local result and recovers in-session', **result)
        provider.reset('drop_once')
        result = query(p, 'applied_exact_fallback')
        assert provider.count() == 2
        check('one dropped connection recovers within retry budget', **result)
        provider.reset('drop')
        result = query(p, 'unavailable')
        assert provider.count() == 2
        check('persistent dropped connections stop after two attempts', **result)
        provider.reset('drop_then_slow')
        result = query(p, 'unavailable', 'EmbeddingTimeout')
        assert provider.count() == 2
        assert result['wall_ms'] < 1000, result  # 300 ms deadline plus scheduler tolerance
        check('timeout still bounds a retried connection', **result)
        provider.reset()
        metadata = build()
        assert (metadata.parent/'project.txt').read_text().strip() == str(root)
        check('valid fixture index activates ANN', **query(p, 'ann_applied'))
        before = generation(metadata)
        provider.reset('reject_chunks')
        stdout, stderr = build_finish(build_start(), expected=1)
        assert 'EmbeddingProviderUnavailable' in stdout + stderr, (stdout, stderr)
        assert provider.count() == 4, provider.requests  # calibration + three chunk attempts
        assert generation(metadata) == before
        provider.reset()
        query(p, 'ann_applied')
        check('exhausted build retries preserve prior index', attempts=3)
        provider.reset('retry_chunks')
        build()
        assert provider.count() == 3  # calibration + rejected chunk + successful retry
        check('transient build rate limit recovers', chunk_attempts=2)
        provider.reset()
        peers = [p, start(), start()]
        before = generation(metadata)
        provider.reset('pause_chunks')
        building = build_start()
        assert provider.entered.wait(5), 'Build did not reach chunks'
        with ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(lambda peer: query(peer, 'ann_applied'), peers))
        assert generation(metadata) == before
        provider.release.set()
        build_finish(building)
        provider.reset()
        for peer in peers:
            adopted = query(peer, 'ann_applied')
            assert not adopted['ann_cache_hit'], adopted
        check('three clients search during rebuild and adopt replacement', clients=len(results))
        before = generation(metadata)
        provider.reset('pause_chunks')
        building = build_start()
        assert provider.entered.wait(5)
        building.kill()
        building.communicate(timeout=5)
        provider.release.set()
        assert generation(metadata) == before
        provider.reset()
        query(p, 'ann_applied')
        check('killed embedding build preserves prior index')
        before = generation(metadata)
        provider.reset('pause_chunks')
        building = build_start()
        assert provider.entered.wait(5)
        source.write_text(original.replace('= 0', '= 7'))
        provider.release.set()
        stdout, stderr = build_finish(building, expected=1)
        assert 'RepositoryChangedDuringAnnBuild' in stdout + stderr, (stdout, stderr)
        assert generation(metadata) == before
        check('edit during build rejects publication and preserves prior bytes')
        provider.reset()
        build()
        # A new process forces a scan; old clients are already exercised above.
        check('rebuild after concurrent edit restores ANN', **query(start(), 'ann_applied'))
        assert not list(metadata.parent.glob('semantic-chunks-v3.meta.*.tmp'))
        check('no metadata temp files remain after controlled failures')
        assert marker not in json.dumps(provider.all_inputs), 'Private fixture reached provider'
        check('sensitive fixtures excluded from all query and build requests', request_inputs=len(provider.all_inputs))
    except Exception as error:
        report['failures'].append({'type': type(error).__name__, 'detail': str(error)[:1500],
                                   'site': traceback.extract_tb(error.__traceback__)[-1].lineno})
        print('FAIL:', report['failures'][-1], flush=True)
    finally:
        provider.release.set()
        for builder in builders:
            if builder.poll() is None:
                builder.kill()
                builder.communicate(timeout=5)
        for client in clients:
            client.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2)+'\n')
    return int(bool(report['failures']))


if __name__ == '__main__':
    raise SystemExit(main())
