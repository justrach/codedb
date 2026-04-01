---
name: codedb-install
description: Install codedb for Codex users and register it as an MCP server. Use when someone wants to install the hosted release build, build codedb from source, re-register a local codedb binary in Codex, or switch Codex to a different codedb executable.
---

# codedb Install

Use this skill when a Codex user wants `codedb` available as an MCP server.

Prefer the hosted installer for normal setup:

```bash
curl -fsSL https://codedb.codegraff.com/install.sh | sh
```

Use a source build when the user wants local changes, debug builds, or a branch that is not yet released:

```bash
git clone https://github.com/justrach/codedb.git
cd codedb
zig build -Doptimize=ReleaseFast
```

The built binary will usually be at `zig-out/bin/codedb`.

After either path, verify the binary starts:

```bash
/absolute/path/to/codedb --help
```

Then register that binary in Codex with the helper script:

```bash
./skills/codedb-install/scripts/register_codex_mcp.sh /absolute/path/to/codedb
```

The script appends this MCP entry only when it is not already present:

```toml
[mcp_servers.codedb]
command = "/absolute/path/to/codedb"
args = ["mcp"]
startup_timeout_sec = 30
```

If the user wants to replace an existing `codedb` entry with a different binary, edit `~/.codex/config.toml` directly after checking the current value.
