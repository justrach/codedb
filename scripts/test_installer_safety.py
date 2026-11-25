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

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from ed25519_pure import publickey, signature  # noqa: E402

TEST_SEED = bytes.fromhex("11" * 32)
TEST_PUB = publickey(TEST_SEED).hex()


def checksum_body(scenario: str, digest: str) -> bytes:
    if scenario == "missing":
        return (digest + "  other-platform\n").encode()
    if scenario == "malformed":
        return b"not-a-hash  codedb-darwin-arm64\n"
    if scenario == "trailing-field":
        return (digest + "  codedb-darwin-arm64 extra-field\n").encode()
    if scenario == "duplicate":
        return ((digest + "  codedb-darwin-arm64\n") * 2).encode()
    digest_out = ("0" * 64) if scenario == "mismatch" else digest
    return (digest_out + "  codedb-darwin-arm64\n").encode()


def main():
    installer = ROOT / "install/install.sh"
    src = installer.read_text()
    assert "xattr -c" not in src
    assert "mcp__codedb__*" not in src
    assert "CODEDB_INSTALL_CLIENTS" in src
    assert "CODEDB_INSTALL_HOOKS" in src
    payload = b"#!/bin/sh\nexit 0\n"
    digest = hashlib.sha256(payload).hexdigest()
    with tempfile.TemporaryDirectory(prefix="codedb-installer-") as directory:
        root = Path(directory)
        commands = root / "commands"
        commands.mkdir()
        for command in ("mkdir", "mktemp", "awk", "rm", "mv", "chmod", "cat", "file"):
            resolved = shutil.which(command)
            if resolved:
                (commands / command).symlink_to(resolved)
        (commands / "python3").symlink_to(sys.executable)
        (commands / "uname").write_text(
            '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n'
        )
        (commands / "uname").chmod(0o755)
        curl = commands / "curl"
        curl.write_text(
            "#!"
            + sys.executable
            + "\n"
            + f"""
import os, sys
from pathlib import Path
sys.path.insert(0, {str(ROOT / "scripts")!r})
from ed25519_pure import signature
args=sys.argv[1:]
scenario=os.environ['INSTALLER_TEST_SCENARIO']
digest=os.environ['INSTALLER_TEST_DIGEST']
seed=bytes.fromhex(os.environ['INSTALLER_TEST_SEED'])

def body():
    if scenario=='missing':
        return (digest+'  other-platform\\n').encode()
    if scenario=='malformed':
        return b'not-a-hash  codedb-darwin-arm64\\n'
    if scenario=='trailing-field':
        return (digest+'  codedb-darwin-arm64 extra-field\\n').encode()
    if scenario=='duplicate':
        return ((digest+'  codedb-darwin-arm64\\n')*2).encode()
    digest_out=('0'*64 if scenario=='mismatch' else digest)
    return (digest_out+'  codedb-darwin-arm64\\n').encode()

def write_out(data):
    if '-o' in args:
        Path(args[args.index('-o')+1]).write_bytes(data)
    else:
        sys.stdout.buffer.write(data)

url=' '.join(args)
if any(a.endswith('checksums.sha256.sig') for a in args):
    if scenario=='unsigned':
        sys.exit(22)
    write_out(signature(body(), seed))
elif any(a.endswith('checksums.sha256') for a in args):
    if scenario=='unavailable':
        sys.exit(22)
    write_out(body())
else:
    if scenario=='download-failed':
        sys.exit(22)
    write_out(b'#!/bin/sh\\nexit 0\\n')
"""
        )
        curl.chmod(0o755)

        def run_installer(scenario, target, fixture_home, extra_env=None, extra_path=""):
            env = {k: v for k, v in os.environ.items() if not k.startswith("CODEDB_")}
            env.update(
                HOME=str(fixture_home),
                PATH=str(commands) + extra_path,
                CODEDB_DIR=str(target),
                CODEDB_VERSION="0.2.5855",
                CODEDB_RELEASE_PUBKEY=TEST_PUB,
                INSTALLER_TEST_SCENARIO=scenario,
                INSTALLER_TEST_DIGEST=digest,
                INSTALLER_TEST_SEED=TEST_SEED.hex(),
            )
            if extra_env:
                env.update(extra_env)
            return subprocess.run(
                ["/bin/bash", str(installer)],
                env=env,
                capture_output=True,
                text=True,
                timeout=20,
            )

        for scenario in (
            "unavailable",
            "missing",
            "malformed",
            "trailing-field",
            "duplicate",
            "mismatch",
            "no-hash-tool",
            "download-failed",
            "unsigned",
            "valid",
        ):
            target = root / (scenario + " install with spaces")
            target.mkdir()
            binary = target / "codedb"
            binary.write_bytes(b"existing installation\n")
            hash_tool = commands / "shasum"
            if hash_tool.exists():
                hash_tool.unlink()
            if scenario != "no-hash-tool":
                hash_tool.write_text(
                    "#!"
                    + sys.executable
                    + "\nimport hashlib,sys\nfrom pathlib import Path\nprint(hashlib.sha256(Path(sys.argv[-1]).read_bytes()).hexdigest()+\"  binary\")\n"
                )
                hash_tool.chmod(0o755)
            fixture_home = root / (scenario + " home")
            fixture_home.mkdir()
            claude_config = fixture_home / ".claude.json"
            existing_config = json.dumps({"mcpServers": {"other": {"command": "other-tool"}}})
            extra = {}
            extra_path = ""
            if scenario in ("mismatch", "trailing-field"):
                claude_config.write_text(existing_config)
                extra = {"CODEDB_INSTALL_CLIENTS": "1", "CODEDB_INSTALL_DEEPWIKI": "0"}
                extra_path = os.pathsep + os.environ["PATH"]
            done = run_installer(scenario, target, fixture_home, extra_env=extra, extra_path=extra_path)
            success = scenario == "valid"
            assert (done.returncode == 0) == success, (scenario, done.stdout, done.stderr)
            assert binary.read_bytes() == (payload if success else b"existing installation\n"), scenario
            assert not list(target.glob(".codedb-download.*")), scenario
            assert "unbound variable" not in done.stderr, done.stderr
            if scenario in ("mismatch", "trailing-field"):
                assert claude_config.read_text() == existing_config, scenario
            else:
                assert not claude_config.exists(), scenario
            assert not (fixture_home / ".codex").exists(), scenario
            assert not (fixture_home / ".claude").exists(), scenario
            print("PASS:", scenario)

        fixture_home = root / "fixture-user"
        fixture_home.mkdir()
        project = root / "project"
        project.mkdir()
        project = project.resolve()
        registration = fixture_home / ".codedb/projects/test/project.txt"
        registration.parent.mkdir(parents=True)
        registration.write_text(str(project) + "\n")
        claude_config = fixture_home / ".claude.json"
        claude_config.write_text(json.dumps({"mcpServers": {"other": {"command": "other-tool"}}}))
        codex_config = fixture_home / ".codex/config.toml"
        codex_config.parent.mkdir()
        codex_config.write_text('[mcp_servers.other]\ncommand = "other-tool"\n')
        qwen_config = fixture_home / ".qwen/settings.json"
        qwen_config.parent.mkdir()
        qwen_config.write_text(json.dumps({"mcpServers": {"other": {"command": "other-tool"}}}))
        normal_target = root / "normal install with spaces"
        normal_target.mkdir()
        binary = normal_target / "codedb"
        binary.write_bytes(b"existing installation\n")
        fake_codedb = commands / "codedb"
        fake_codedb.write_bytes(payload)
        fake_codedb.chmod(0o755)
        hash_tool = commands / "shasum"
        hash_tool.write_text(
            "#!"
            + sys.executable
            + "\nimport hashlib,sys\nfrom pathlib import Path\nprint(hashlib.sha256(Path(sys.argv[-1]).read_bytes()).hexdigest()+\"  binary\")\n"
        )
        hash_tool.chmod(0o755)

        default_env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("CODEDB_")
        }
        default_env.update(
            HOME=str(fixture_home),
            PATH=str(commands) + os.pathsep + os.environ["PATH"],
            CODEDB_DIR=str(normal_target),
            CODEDB_VERSION="0.2.5855",
            CODEDB_RELEASE_PUBKEY=TEST_PUB,
            INSTALLER_TEST_SCENARIO="valid",
            INSTALLER_TEST_DIGEST=digest,
            INSTALLER_TEST_SEED=TEST_SEED.hex(),
        )
        done = subprocess.run(
            ["/bin/bash", str(installer)],
            env=default_env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        assert done.returncode == 0, (done.stdout, done.stderr)
        assert binary.read_bytes() == payload
        assert json.loads(claude_config.read_text())["mcpServers"]["other"]["command"] == "other-tool"
        assert "codedb" not in json.loads(claude_config.read_text())["mcpServers"]
        assert "codedb" not in tomllib.loads(codex_config.read_text()).get("mcp_servers", {})
        assert not (fixture_home / ".claude/hooks/codedb-block-legacy.sh").exists()
        print("PASS: default install does not write client configs or hooks")

        empty_home = root / "empty-claude-home"
        empty_home.mkdir()
        empty_target = root / "empty-claude-install"
        empty_target.mkdir()
        empty_env = dict(default_env)
        empty_env.update(HOME=str(empty_home), CODEDB_DIR=str(empty_target), CODEDB_INSTALL_CLIENTS="1")
        done = subprocess.run(
            ["/bin/bash", str(installer)],
            env=empty_env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        assert done.returncode == 0, (done.stdout, done.stderr)
        assert not (empty_home / ".claude.json").exists()
        assert not (empty_home / ".codex").exists()
        print("PASS: INSTALL_CLIENTS does not create ~/.claude.json when Claude is absent")

        hooks_home = root / "hooks-only-home"
        hooks_home.mkdir()
        hooks_target = root / "hooks-only-install"
        hooks_target.mkdir()
        hooks_env = dict(default_env)
        hooks_env.update(HOME=str(hooks_home), CODEDB_DIR=str(hooks_target), CODEDB_INSTALL_HOOKS="1")
        done = subprocess.run(
            ["/bin/bash", str(installer)],
            env=hooks_env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        assert done.returncode == 0, (done.stdout, done.stderr)
        assert not (hooks_home / ".claude.json").exists()
        assert not (hooks_home / ".claude").exists()
        print("PASS: INSTALL_HOOKS does not create ~/.claude when Claude is absent")

        opt_env = dict(default_env)
        opt_env.update(CODEDB_INSTALL_CLIENTS="1", CODEDB_INSTALL_HOOKS="1", CODEDB_INSTALL_DEEPWIKI="0")
        done = subprocess.run(
            ["/bin/bash", str(installer)],
            env=opt_env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        assert done.returncode == 0, (done.stdout, done.stderr)
        configs = [
            ("claude", json.loads(claude_config.read_text())["mcpServers"]),
            ("codex", tomllib.loads(codex_config.read_text())["mcp_servers"]),
            ("qwen detected client", json.loads(qwen_config.read_text())["mcpServers"]),
        ]
        for name, config in configs:
            assert config["other"]["command"] == "other-tool"
            assert config["codedb"]["command"] == str(binary)
            assert config["codedb"]["args"] == ["mcp"]
            print("PASS: opt-in", name, "registration preserves other servers")

        settings = json.loads((fixture_home / ".claude/settings.json").read_text())
        allow = settings.get("permissions", {}).get("allow", [])
        assert "mcp__codedb__*" not in allow
        hook = fixture_home / ".claude/hooks/codedb-block-legacy.sh"
        assert hook.is_file() and os.access(hook, os.X_OK)
        assert any(
            "codedb-block-legacy.sh" in entry["hooks"][0]["command"]
            for entry in settings["hooks"]["PreToolUse"]
        )
        for command, expected in [
            ("sed -i s/old/new/ code.py", 0),
            ('awk "{print}" code.py', 0),
            ("rg handler .", 2),
            ("python3 edit.py", 0),
        ]:
            done = subprocess.run(
                ["/bin/bash", str(hook)],
                cwd=project,
                env=opt_env,
                input=json.dumps({"tool_input": {"command": command}}),
                capture_output=True,
                text=True,
                timeout=10,
            )
            assert done.returncode == expected, (command, done.stderr)
            assert "codedb_edit" not in done.stderr
            print("PASS: installed hook", command.split()[0])


if __name__ == "__main__":
    main()
