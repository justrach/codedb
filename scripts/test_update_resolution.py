#!/usr/bin/env python3
"""Exercise update resolution without network access or replacing a binary."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
original_hash = hashlib.sha256(Path(binary).read_bytes()).digest()
version = subprocess.check_output([binary, '--version'], text=True).strip().split()[-1]
with tempfile.TemporaryDirectory() as directory:
    curl = Path(directory) / 'curl'
    curl.write_text('''#!/usr/bin/env python3
import os, sys
url = sys.argv[-1]
if url.endswith('/releases/latest'):
    if os.environ['SCENARIO'] == 'equal':
        print(os.environ['LATEST_JSON'])
        sys.exit(0)
    sys.exit(22)
if url.endswith('/latest.json'):
    if os.environ['SCENARIO'] == 'stale':
        print('{"version":"0.2.56"}')
        sys.exit(0)
    sys.exit(22)
print('UNEXPECTED_DOWNLOAD', file=sys.stderr)
sys.exit(99)
''')
    curl.chmod(0o755)
    env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'], NO_COLOR='1')
    env.pop('CODEDB_VERSION', None)
    env.pop('CODEDB_URL', None)
    for scenario, code, expected in [
        ('equal', 0, 'already up to date'),
        ('stale', 1, 'cannot confirm the latest release'),
        ('unavailable', 1, 'CouldNotResolveLatestVersion'),
        ('explicit', 1, 'requested by CODEDB_VERSION'),
    ]:
        case = dict(env, SCENARIO=scenario, LATEST_JSON=json.dumps({'tag_name': 'v' + version}))
        if scenario == 'explicit':
            case['CODEDB_VERSION'] = '0.2.56'
        result = subprocess.run([binary, 'update'], env=case, capture_output=True, text=True)
        assert result.returncode == code, (scenario, result)
        assert expected in result.stdout, (scenario, result)
        assert hashlib.sha256(Path(binary).read_bytes()).digest() == original_hash
        print(f'PASS: {scenario}')
