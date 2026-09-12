#!/usr/bin/env python3
"""Installer failure paths must preserve the binary and avoid client config writes."""
import hashlib
import os
import json
import re
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import tomllib


def main():
    installer = Path(__file__).resolve().parents[1] / 'install/install.sh'
    payload = b'#!/bin/sh\nexit 0\n'
    digest = hashlib.sha256(payload).hexdigest()
    with tempfile.TemporaryDirectory(prefix='codedb-installer-') as directory:
        root = Path(directory)
        commands = root / 'commands'
        commands.mkdir()
        for command in ('mkdir', 'mktemp', 'awk', 'rm', 'mv', 'chmod'):
            (commands / command).symlink_to(shutil.which(command))
        (commands / 'uname').write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n')
        (commands / 'uname').chmod(0o755)
        curl = commands / 'curl'
        curl.write_text('#!' + sys.executable + '\n' + '''
import os,sys
from pathlib import Path
args=sys.argv[1:];scenario=os.environ['INSTALLER_TEST_SCENARIO']
digest=os.environ['INSTALLER_TEST_DIGEST']
if any(a.endswith('checksums.sha256') for a in args):
    if scenario=='unavailable':sys.exit(22)
    if scenario=='missing':print(digest+'  other-platform');sys.exit(0)
    if scenario=='malformed':print('not-a-hash  codedb-darwin-arm64');sys.exit(0)
    if scenario=='duplicate':print((digest+'  codedb-darwin-arm64\\n')*2);sys.exit(0)
    print(('0'*64 if scenario=='mismatch' else digest)+'  codedb-darwin-arm64')
else:
    if scenario=='download-failed':sys.exit(22)
    Path(args[args.index('-o')+1]).write_bytes(b'#!/bin/sh\\nexit 0\\n')
''')
        curl.chmod(0o755)
        for scenario in ('unavailable', 'missing', 'malformed', 'duplicate', 'mismatch', 'no-hash-tool', 'download-failed', 'valid'):
            target = root / (scenario + ' install with spaces')
            target.mkdir()
            binary = target / 'codedb'
            binary.write_bytes(b'existing installation\n')
            hash_tool = commands / 'shasum'
            if hash_tool.exists():
                hash_tool.unlink()
            if scenario != 'no-hash-tool':
                hash_tool.write_text('#!' + sys.executable + '\nimport hashlib,sys\nfrom pathlib import Path\nprint(hashlib.sha256(Path(sys.argv[-1]).read_bytes()).hexdigest()+"  binary")\n')
                hash_tool.chmod(0o755)
            env = {k: v for k, v in os.environ.items() if not k.startswith('CODEDB_')}
            env.update(PATH=str(commands), CODEDB_DIR=str(target), CODEDB_VERSION='0.2.5855',
                       CODEDB_NO_INTEGRATIONS='1', INSTALLER_TEST_SCENARIO=scenario,
                       INSTALLER_TEST_DIGEST=digest)
            done = subprocess.run(['/bin/bash', str(installer)], env=env, capture_output=True, text=True, timeout=20)
            success = scenario == 'valid'
            assert (done.returncode == 0) == success, (scenario, done.stdout, done.stderr)
            assert binary.read_bytes() == (payload if success else b'existing installation\n'), scenario
            assert not list(target.glob('.codedb-download.*')), scenario
            assert 'unbound variable' not in done.stderr, done.stderr
            print('PASS:', scenario)

        # Extract the installed hook verbatim. Relocate its HOME path reference
        # in the fixture only; never change the process HOME or real settings.
        hook_source = re.search(r'"codedb-block-legacy.sh": r\x27\x27\x27(.*?)\x27\x27\x27,', installer.read_text(), re.S).group(1)
        hook = root / 'hook.sh'
        hook.write_text(hook_source.replace('$HOME', '${CODEDB_INSTALL_TEST_ROOT}'))
        fixture_home = root / 'fixture-user'
        project = root / 'project'
        project.mkdir()
        project = project.resolve()
        registration = fixture_home / '.codedb/projects/test/project.txt'
        registration.parent.mkdir(parents=True)
        registration.write_text(str(project) + '\n')
        fake_codedb = commands / 'codedb'
        fake_codedb.write_bytes(payload)
        fake_codedb.chmod(0o755)
        hook_env = {k: v for k, v in os.environ.items() if not k.startswith('CODEDB_')}
        hook_env.update(CODEDB_INSTALL_TEST_ROOT=str(fixture_home), PATH=str(commands) + os.pathsep + os.environ['PATH'])
        for command, expected in [('sed -i s/old/new/ code.py', 0), ('awk "{print}" code.py', 0), ('rg handler .', 2), ('python3 edit.py', 0)]:
            done = subprocess.run(['/bin/bash', str(hook)], cwd=project, env=hook_env,
                                  input=json.dumps({'tool_input': {'command': command}}),
                                  capture_output=True, text=True, timeout=10)
            assert done.returncode == expected, (command, done.stderr)
            assert 'codedb_edit' not in done.stderr
            print('PASS: hook', command.split()[0])

        # Exercise fresh client registration against fixture config paths.
        # Existing unrelated MCP registrations must survive the additive writes.
        (fixture_home / '.claude.json').write_text(json.dumps({'mcpServers': {'other': {'command': 'other-tool'}}}))
        (fixture_home / '.codex').mkdir()
        (fixture_home / '.codex/config.toml').write_text('[mcp_servers.other]\ncommand = "other-tool"\n')
        definitions = installer.read_text().rsplit('\nmain\n', 1)[0]
        registration_script = root / 'register.sh'
        registration_script.write_text(definitions.replace('$HOME', '${CODEDB_INSTALL_TEST_ROOT}') +
                                       '\nregister_claude ' + shlex.quote(str(fake_codedb)) +
                                       '\nregister_codex ' + shlex.quote(str(fake_codedb)) + '\n')
        subprocess.run(['/bin/bash', str(registration_script)], env=hook_env, check=True, capture_output=True, text=True)
        claude = json.loads((fixture_home / '.claude.json').read_text())['mcpServers']
        codex = tomllib.loads((fixture_home / '.codex/config.toml').read_text())['mcp_servers']
        for name, config in [('claude', claude), ('codex', codex)]:
            assert config['other']['command'] == 'other-tool'
            assert config['codedb']['command'] == str(fake_codedb)
            assert config['codedb']['args'] == ['mcp']
            print('PASS: fresh', name, 'registration preserves other servers')


if __name__ == '__main__':
    main()
