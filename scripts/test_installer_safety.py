#!/usr/bin/env python3
"""Installer failure paths must preserve the binary and avoid client config writes."""
import hashlib
import os
import json
from pathlib import Path
import shutil
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
    if scenario=='trailing-field':print(digest+'  codedb-darwin-arm64 extra-field');sys.exit(0)
    if scenario=='duplicate':print((digest+'  codedb-darwin-arm64\\n')*2);sys.exit(0)
    print(('0'*64 if scenario=='mismatch' else digest)+'  codedb-darwin-arm64')
else:
    if scenario=='download-failed':sys.exit(22)
    Path(args[args.index('-o')+1]).write_bytes(b'#!/bin/sh\\nexit 0\\n')
''')
        curl.chmod(0o755)
        for scenario in ('unavailable', 'missing', 'malformed', 'trailing-field', 'duplicate', 'mismatch', 'no-hash-tool', 'download-failed', 'valid'):
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
            fixture_home = root / (scenario + ' home')
            fixture_home.mkdir()
            claude_config = fixture_home / '.claude.json'
            existing_config = json.dumps({'mcpServers': {'other': {'command': 'other-tool'}}})
            if scenario in ('mismatch', 'trailing-field'):
                claude_config.write_text(existing_config)
            env = {k: v for k, v in os.environ.items() if not k.startswith('CODEDB_')}
            env.update(HOME=str(fixture_home), PATH=str(commands), CODEDB_DIR=str(target),
                       CODEDB_VERSION='0.2.5855', CODEDB_NO_INTEGRATIONS='1',
                       INSTALLER_TEST_SCENARIO=scenario, INSTALLER_TEST_DIGEST=digest)
            if scenario in ('mismatch', 'trailing-field'):
                # A checksum failure must stop before normal client registration.
                env.pop('CODEDB_NO_INTEGRATIONS')
                env['CODEDB_INSTALL_DEEPWIKI'] = '0'
                env['PATH'] += os.pathsep + os.environ['PATH']
            done = subprocess.run(['/bin/bash', str(installer)], env=env, capture_output=True, text=True, timeout=20)
            success = scenario == 'valid'
            assert (done.returncode == 0) == success, (scenario, done.stdout, done.stderr)
            assert binary.read_bytes() == (payload if success else b'existing installation\n'), scenario
            assert not list(target.glob('.codedb-download.*')), scenario
            assert 'unbound variable' not in done.stderr, done.stderr
            if scenario in ('mismatch', 'trailing-field'):
                assert claude_config.read_text() == existing_config, scenario
            else:
                assert not claude_config.exists(), scenario
            assert not (fixture_home / '.codex').exists(), scenario
            assert not (fixture_home / '.claude').exists(), scenario
            print('PASS:', scenario)

        # Drive the normal main() path inside a disposable HOME. This must
        # reach detected-client registration and install the hook we exercise.
        fixture_home = root / 'fixture-user'
        fixture_home.mkdir()
        project = root / 'project'
        project.mkdir()
        project = project.resolve()
        registration = fixture_home / '.codedb/projects/test/project.txt'
        registration.parent.mkdir(parents=True)
        registration.write_text(str(project) + '\n')
        claude_config = fixture_home / '.claude.json'
        claude_config.write_text(json.dumps({'mcpServers': {'other': {'command': 'other-tool'}}}))
        codex_config = fixture_home / '.codex/config.toml'
        codex_config.parent.mkdir()
        codex_config.write_text('[mcp_servers.other]\ncommand = "other-tool"\n')
        qwen_config = fixture_home / '.qwen/settings.json'
        qwen_config.parent.mkdir()
        qwen_config.write_text(json.dumps({'mcpServers': {'other': {'command': 'other-tool'}}}))
        normal_target = root / 'normal install with spaces'
        normal_target.mkdir()
        binary = normal_target / 'codedb'
        binary.write_bytes(b'existing installation\n')
        fake_codedb = commands / 'codedb'
        fake_codedb.write_bytes(payload)
        fake_codedb.chmod(0o755)
        normal_env = {k: v for k, v in os.environ.items() if not k.startswith('CODEDB_')}
        normal_env.update(HOME=str(fixture_home), PATH=str(commands) + os.pathsep + os.environ['PATH'],
                          CODEDB_DIR=str(normal_target), CODEDB_VERSION='0.2.5855',
                          CODEDB_INSTALL_DEEPWIKI='0', INSTALLER_TEST_SCENARIO='valid',
                          INSTALLER_TEST_DIGEST=digest)
        done = subprocess.run(['/bin/bash', str(installer)], env=normal_env,
                              capture_output=True, text=True, timeout=20)
        assert done.returncode == 0, (done.stdout, done.stderr)
        assert binary.read_bytes() == payload
        assert not list(normal_target.glob('.codedb-download.*'))
        print('PASS: normal install through main')

        configs = [
            ('claude', json.loads(claude_config.read_text())['mcpServers']),
            ('codex', tomllib.loads(codex_config.read_text())['mcp_servers']),
            ('qwen detected client', json.loads(qwen_config.read_text())['mcpServers']),
        ]
        for name, config in configs:
            assert config['other']['command'] == 'other-tool'
            assert config['codedb']['command'] == str(binary)
            assert config['codedb']['args'] == ['mcp']
            print('PASS: normal', name, 'registration preserves other servers')

        hook = fixture_home / '.claude/hooks/codedb-block-legacy.sh'
        assert hook.is_file() and os.access(hook, os.X_OK)
        settings = json.loads((fixture_home / '.claude/settings.json').read_text())
        assert any('codedb-block-legacy.sh' in entry['hooks'][0]['command']
                   for entry in settings['hooks']['PreToolUse'])
        for command, expected in [('sed -i s/old/new/ code.py', 0), ('awk "{print}" code.py', 0),
                                  ('rg handler .', 2), ('python3 edit.py', 0)]:
            done = subprocess.run(['/bin/bash', str(hook)], cwd=project, env=normal_env,
                                  input=json.dumps({'tool_input': {'command': command}}),
                                  capture_output=True, text=True, timeout=10)
            assert done.returncode == expected, (command, done.stderr)
            assert 'codedb_edit' not in done.stderr
            print('PASS: installed hook', command.split()[0])


if __name__ == '__main__':
    main()
