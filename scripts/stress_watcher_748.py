#!/usr/bin/env python3
"""Stress live watcher correctness under excluded-file churn and watch overflow.

Run with a frozen ReleaseFast binary and a new --out report beneath an indexable
scratch directory (for example ~/tmp). Same-size rewrites restore mtime, not
ctime; the Zig regression suite separately covers fully colliding metadata.
"""
import sys, os, json, time, tempfile, subprocess, threading, hashlib, re, argparse
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from e2e_mcp_test import MCPProcess, do_initialize, all_tool_text
from repro_watcher_748 import cpu_seconds

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', required=True)
parser.add_argument('--out', required=True)
parser.add_argument('--seconds', type=float, default=20)
args = parser.parse_args()
if args.seconds <= 0: parser.error('--seconds must be positive')
REPORT_PATH = Path(args.out).resolve()
if REPORT_PATH.exists(): parser.error('Use a new output filename')
OUT = REPORT_PATH.parent
OUT.mkdir(parents=True, exist_ok=True)
BINARY = str(Path(args.binary).resolve())
report = {'binary': BINARY, 'sha256': hashlib.sha256(Path(BINARY).read_bytes()).hexdigest(), 'cases': []}

def text(p, name, args):
    r = p.call_tool(name, args, timeout=15)
    if not r or r.get('error') or r.get('result', {}).get('isError'):
        raise RuntimeError(str(r)[:400])
    return all_tool_text(r)

def run(budget, count):
    case = {'budget': budget, 'clients': count, 'directories': 1200, 'source_files': 4800, 'checks': [], 'failures': []}
    report['cases'].append(case)
    clients = []
    stop = threading.Event()
    churn_count = [0]
    with tempfile.TemporaryDirectory(prefix='codedb-brute-corpus-', dir=OUT) as tmp:
        root = Path(tmp)
        subprocess.run(['git', 'init', '-q', tmp], check=True)
        (root / '.gitignore').write_text('codedb.snapshot\n.zigrep_archive\n.codedb*\n')
        (root / '.codedbrc').write_text(f'max_watched = {budget}\n')
        for d in range(1200):
            folder = root / f'd{d:04}'
            folder.mkdir()
            for f in range(4):
                (folder / f'f{f}.py').write_text(f'def original_{d:04}_{f}():\n    return 0\n' + '# padding\n' * 600)
        env = dict(os.environ, CODEDB_NO_AUTO_UPDATE='1', CODEDB_NO_TELEMETRY='1', CODEDB_NO_CLI_DAEMON='1')
        env.pop('CODEDB_LAZY_MCP', None)
        try:
            for _ in range(count):
                p = MCPProcess(BINARY, [], tmp, command=[BINARY, tmp, 'mcp', f'--config-file={root / ".codedbrc"}', '--no-telemetry'], env=env)
                clients.append(p)
                assert do_initialize(p, with_roots=False)
                deadline = time.monotonic() + 120
                while 'scan: ready' not in text(p, 'codedb_status', {}).lower():
                    assert time.monotonic() < deadline, 'scan timeout'
                    time.sleep(.2)
            time.sleep(4)
            def noise():
                try:
                    while not stop.is_set():
                        for folder in (root, root/'d0000', root/'d1199'):
                            path = folder / 'ignored.lock'
                            path.write_text('excluded churn')
                            path.unlink()
                            churn_count[0] += 1
                        stop.wait(.005)
                except Exception as e:
                    case['failures'].append('churn thread: ' + repr(e))
            before = [text(p, 'codedb_status', {}) for p in clients]
            phases = []
            for label in ('quiet', 'churn'):
                if label == 'churn':
                    worker = threading.Thread(target=noise)
                    worker.start()
                cpus = [cpu_seconds(p.proc.pid) for p in clients]
                start = time.monotonic()
                time.sleep(args.seconds)
                wall = time.monotonic() - start
                phases.append({'phase': label, 'cpu_percent_per_client': [100*(cpu_seconds(p.proc.pid)-c)/wall for p,c in zip(clients,cpus)], 'wall_seconds': wall})
            case['phases'] = phases
            after = [text(p, 'codedb_status', {}) for p in clients]
            stable = lambda s: re.findall(r'(?:files|seq)\s*[:=]\s*\d+', s.lower())
            case['unchanged_under_excluded_churn'] = all(bool(stable(a)) and stable(a)==stable(b) for a,b in zip(before, after))
            case['status_before'] = before
            case['status_after_churn'] = after
            if not case['unchanged_under_excluded_churn']:
                case['failures'].append('index changed during excluded churn')
            def await_symbol(name, path, present=True):
                started = time.monotonic()
                pending = set(range(len(clients)))
                while pending and time.monotonic()-started < 15:
                    for i in list(pending):
                        value = text(clients[i], 'codedb_symbol', {'name': name})
                        found = path in value and name in value
                        if found == present:
                            pending.remove(i)
                    if pending: time.sleep(.1)
                check = {'symbol': name, 'path': path, 'present': present, 'latency_ms': round(1000*(time.monotonic()-started),2), 'passed': not pending}
                case['checks'].append(check)
                if pending: case['failures'].append(check)
            for n in range(10):
                folder = root / f'd{1190+n:04}'
                path = folder / 'f0.py'
                old = path.read_text()
                name = f'mutation_{1190+n:04}_0'
                changed = old.replace(f'original_{1190+n:04}_0', name)
                assert len(changed) == len(old)
                st = path.stat()
                path.write_text(changed)
                os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
                await_symbol(name, str(path.relative_to(root)))
                await_symbol(f'original_{1190+n:04}_0', str(path.relative_to(root)), False)
                new = folder / f'created{n}.py'
                symbol = f'new_symbol_{n}'
                new.write_text(f'def {symbol}():\n    return {n}\n')
                await_symbol(symbol, str(new.relative_to(root)))
                renamed = folder / f'renamed{n}.py'
                new.rename(renamed)
                await_symbol(symbol, str(renamed.relative_to(root)))
                await_symbol(symbol, str(new.relative_to(root)), False)
                renamed.unlink()
                await_symbol(symbol, str(renamed.relative_to(root)), False)
            # Discovery of a new nested directory while root and overflow paths churn.
            deep = root / 'fresh' / 'nested'
            deep.mkdir(parents=True)
            (deep / 'probe.py').write_text('def nested_created():\n    return 3\n')
            await_symbol('nested_created', 'fresh/nested/probe.py')
            stop.set()
            worker.join()
            case['churn_pairs'] = churn_count[0]
            case['alive'] = all(p.proc.poll() is None for p in clients)
            case['rss_kib'] = [int(subprocess.check_output(['ps','-p',str(p.proc.pid),'-o','rss='],text=True)) for p in clients]
        except Exception as e:
            case['failures'].append(repr(e))
        finally:
            stop.set()
            if 'worker' in locals(): worker.join()
            for p in clients: p.close()
            REPORT_PATH.write_text(json.dumps(report, indent=2)+'\n')
            print(json.dumps({k:v for k,v in case.items() if k not in ('status_before','status_after_churn','checks')}), flush=True)

run(32, 3)
run(1024, 1)
sys.exit(int(any(c['failures'] for c in report['cases'])))
