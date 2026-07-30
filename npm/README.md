# codedeebee

npm/npx launcher for [**codedb**](https://github.com/justrach/codedb) — a Zig code intelligence MCP server.

The package name is `codedeebee` (the bare `codedb` name is restricted on npm). The CLI it installs is named `codedb`.

## Quick start

```sh
npx -y codedeebee mcp
```

Or install once:

```sh
npm install -g codedeebee
codedb mcp
```

## MCP client config

### Claude Code / Cursor / opencode

```json
{
  "codedb": {
    "type": "local",
    "command": ["npx", "-y", "codedeebee"],
    "args": ["mcp"],
    "enabled": true
  }
}
```

### Claude Desktop

On macOS/Linux:

```json
{
  "mcpServers": {
    "codedb": {
      "command": "npx",
      "args": ["-y", "codedeebee", "mcp"]
    }
  }
}
```

On Windows (once a Windows-capable `codedeebee` is published — see [Supported platforms](#supported-platforms)):

```json
{
  "mcpServers": {
    "codedb": {
      "command": "npx.cmd",
      "args": ["-y", "codedeebee", "mcp"]
    }
  }
}
```

## How it works

`postinstall` downloads the matching native binary from the corresponding [GitHub Release](https://github.com/justrach/codedb/releases) and verifies it against `checksums.sha256`. The `codedb` command is a thin Node launcher that execs the native binary, preserving `cwd`, stdio, args, and environment.

## Supported platforms

| OS     | Arch                 |
|--------|----------------------|
| macOS  | arm64, x64 (Intel)   |
| Linux  | arm64, x64           |
| Windows | x64 (not on the published package yet) |

On Windows, the package downloads `codedb-windows-x86_64.exe`, installs it as `vendor/codedb.exe`, and launches it through the same `codedb` command used on other platforms.

Windows support is wired into the package but is not on npm yet: the currently published `codedeebee` predates the Windows release asset, so `npx -y codedeebee mcp` does not work on Windows today. It becomes available once the next release is published — check `npm view codedeebee version`, and until it reports a Windows-capable release use the checksum-verified PowerShell installer in the root [README](https://github.com/justrach/codedb#windows).

## Updating on Windows

Once a Windows-capable `codedeebee` is published, update through npm:

```powershell
npm install -g codedeebee@latest
codedb --version
```

Until then — and for non-npm Windows installs — the native Windows binary cannot self-update. Rerun the checksum-verifying PowerShell installer from the root [README](https://github.com/justrach/codedb#windows).

## Skipping the binary download

For sandboxed installs (or environments without GitHub access), set `CODEDEEBEE_SKIP_POSTINSTALL=1`. The package will install successfully but `codedb` will exit until a binary is placed at `node_modules/codedeebee/vendor/codedb` (`codedb.exe` on Windows).

## Links

- Source: https://github.com/justrach/codedb
- Issues: https://github.com/justrach/codedb/issues
- Releases: https://github.com/justrach/codedb/releases
