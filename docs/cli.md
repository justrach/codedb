# codedb CLI

A daemon + thin CLI client for codedb. Same code intelligence as MCP, usable from any shell.

## Why

codedb's MCP server is designed for AI agents over JSON-RPC stdio. The CLI gives you the same indexes and query speed from a normal terminal — composable with pipes, grep, scripts, and CI.

| | MCP | CLI |
|---|---|---|
| Designed for | AI agents (JSON-RPC) | Humans + scripts |
| Composable | No — locked inside agent | Yes — pipes, grep, jq |
| Debuggable | Opaque stdio | curl, jq, logs |
| Requires | MCP client (Claude, Cursor, etc.) | Just a shell |

## How It Works

```
codedb <root> serve              # HTTP daemon on localhost:7719
  ↕ HTTP
codedb-cli <command>             # bash + curl + jq
```

The daemon holds all indexes in memory and watches the filesystem for changes. The CLI is a ~120 line bash script that sends HTTP requests and formats the JSON output.

## Install

### 1. Build codedb

```bash
zig build -Doptimize=ReleaseFast
cp zig-out/bin/codedb ~/.local/bin/codedb
```

### 2. Install the CLI wrapper

```bash
cp scripts/codedb-cli ~/.local/bin/codedb-cli
chmod +x ~/.local/bin/codedb-cli
```

### 3. (Optional) Persistent daemon via systemd

```bash
cp scripts/codedb.service ~/.config/systemd/user/codedb.service
# Edit the service file: set WorkingDirectory and ExecStart to your project/binary
systemctl --user daemon-reload
systemctl --user enable --now codedb
```

Or just run queries — the CLI auto-starts the daemon if it's not running.

## Commands

```
codedb-cli [root] <command> [args...]
```

| Command | Description | Example |
|---------|-------------|---------|
| `tree` | File tree with language, line counts, symbol counts | `codedb-cli tree` |
| `outline <path>` | Symbols in a file (functions, structs, imports) | `codedb-cli outline src/main.zig` |
| `find <symbol>` | Find symbol definitions across codebase | `codedb-cli find Explorer` |
| `search <query> [max]` | Trigram full-text search | `codedb-cli search "handleAuth" 20` |
| `word <identifier>` | O(1) inverted index exact word lookup | `codedb-cli word allocator` |
| `hot [limit]` | Recently modified files | `codedb-cli hot 5` |
| `deps <path>` | Reverse dependency graph | `codedb-cli deps src/store.zig` |
| `read <path> [start] [end]` | Read file content with optional line range | `codedb-cli read src/main.zig 1 30` |
| `status` | Index health and sequence number | `codedb-cli status` |
| `start [root]` | Start the daemon | `codedb-cli start .` |
| `stop` | Stop the daemon | `codedb-cli stop` |

The native binary also exposes the task composer directly:

```bash
# Force a fresh filesystem scan and rebuild the local indexes
codedb /path/to/repo reindex

# Default: Pareto-frontier hybrid retrieval with local BM25/symbol first
codedb /path/to/repo context "find the request authentication path"

# Explicit opt-out: entirely local BM25/symbol/graph retrieval
codedb /path/to/repo context --local "find the request authentication path"

# Explicit one-time build: bounded code chunks become a local OpenPuffer ANN
codedb /path/to/repo semantic-index

# Machine-readable privacy, byte-count, ranks, and retention metadata
codedb /path/to/repo context --json "find the request authentication path"
```

Hybrid retrieval uses a fresh local OpenPuffer sidecar when one exists: the task and
a fixed public calibration string leave the machine in one embedding request,
then vector-space verification, mmap-backed graph search, and fusion run
locally. Without a sidecar, it sends the task and up to 24 locally selected
relative paths with bounded snippets for an exact rerank. It never uploads a
repository archive or creates a server-side index. If the provider fails, the
command returns the local result and does not run an embedding model on CPU.
`--semantic` and `--hybrid` remain accepted compatibility aliases for the
default; `--local` (or `--no-semantic`) is the explicit on-device-only mode.

`semantic-index` is the only ANN build trigger. It sends bounded 832-byte code
chunks using four concurrent 25-item requests by default (configurable from one
to eight) and stores a small mapping plus a generation-named, validated `.hmls`
mmap slab under codedb's local per-project data directory (0700/0600 on POSIX).
Queries verify vector-space identity and repository freshness before
mmap. Metadata heap use is capped at 64 MiB, graph validation at 128 MiB, and
the vector slab stays demand-paged instead of being copied into RSS.
The default managed semantic lane is free and needs no token or setup. CodeDB
automatically creates a local Ed25519 installation key, enrolls its public key,
renews the server-signed certificate, and signs every request. The private seed
stays in `~/.codedb/credentials.json` (0600 on POSIX). Every cloud-bound path is rechecked against
the sensitive-file denylist; `.env`, `.env.*`, `.envrc`, credentials, private keys, and unsafe
paths cannot enter a batch even from a stale index.

## Daemon Management

```bash
# systemd (if installed as a service)
systemctl --user status codedb
systemctl --user restart codedb       # re-indexes from scratch
systemctl --user stop codedb
journalctl --user -u codedb -f        # tail logs

# manual
codedb-cli start /path/to/project     # start daemon
codedb-cli stop                       # stop daemon
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CODEDB_PORT` | `7719` | HTTP port for the daemon |
| `CODEDB_BINARY` | `codedb` | Path to the codedb binary |
| `CODEDB_EMBEDDINGS_URL` | `https://embeddings.wiki.codes/v1/codedb/embeddings` | Free bounded hosted lane; may be overridden with another HTTPS endpoint |
| `CODEDB_EMBEDDINGS_MODEL` | managed | Provider deployment/model identifier; set only with a custom endpoint |
| `CODEDB_EMBEDDINGS_DIMENSIONS` | managed | Requested custom-provider dimensions (64-4096) |
| `CODEDB_EMBEDDINGS_TOKEN` | unset | Optional legacy bearer token for protected/custom endpoints; the hosted lane enrolls automatically |
| `CODEDB_EMBEDDINGS_TIMEOUT_MS` | `15000` | Per-request deadline in milliseconds (10-120000) |
| `CODEDB_SEMANTIC_INDEX_CONCURRENCY` | `4` | Parallel 25-item index batches (clamped to 1-8) |

## Performance

Benchmarked on the codedb repo itself (~75 files, Zig project):

| Command | Daemon CLI | Cold process | Speedup |
|---------|-----------|-------------|---------|
| `tree` | **17ms** | 8,145ms | **479x** |
| `word` | **16ms** | 7,403ms | **462x** |
| `search` | **15ms** | n/a* | — |
| `find` | **14ms** | — | — |
| `outline` | **20ms** | — | — |
| `read` | **17ms** | — | — |

\* Cold search requires async trigram index build, so no fair comparison.

The CLI overhead is ~7ms (curl + jq) on top of the raw HTTP query time (~8ms).

## Requirements

- `curl` and `jq` (both standard on most systems)
- `codedb` binary (build with Zig 0.15+)

## Examples

```bash
# Explore a project
codedb-cli tree | head -20
codedb-cli outline src/main.zig

# Find where a symbol is defined
codedb-cli find Store
# src/store.zig:16  struct_def  pub const Store = struct {
# src/explore.zig:2 import      const Store = @import("store.zig").Store;

# Search and pipe to other tools
codedb-cli search "error" | grep "server.zig"
codedb-cli word "allocator" | wc -l

# Read specific lines
codedb-cli read src/explore.zig 106 130
```
