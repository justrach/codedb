#!/usr/bin/env python3
import subprocess, json, time, os, select, statistics, math

OLD  = "/tmp/codedb-0.2.572"
NEW  = "/Users/rachpradhan/codedb2/zig-out/bin/codedb"
REPO = "/Users/rachpradhan/codedb"
ITERS = 25
MAX_RESULTS = 20

W,G,C,D,Y,R,N='\033[1;37m','\033[0;32m','\033[0;36m','\033[0;90m','\033[0;33m','\033[0;31m','\033[0m'

class McpClient:
    def __init__(self, binary, repo):
        self.proc = subprocess.Popen([binary,"mcp",repo], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.id = 0; self.buf = b""; self._init()
    def _send(self, obj):
        body = json.dumps(obj)+"\n"; self.proc.stdin.write(body.encode()); self.proc.stdin.flush()
    def _recv(self, timeout=15):
        deadline = time.time()+timeout
        while time.time()<deadline:
            if select.select([self.proc.stdout],[],[],0.05)[0]:
                chunk=os.read(self.proc.stdout.fileno(),65536)
                if chunk: self.buf+=chunk
            text=self.buf.decode(errors="replace")
            while "\n" in text:
                line,rest=text.split("\n",1); line=line.strip()
                if not line: text=rest; self.buf=rest.encode(); continue
                try:
                    obj=json.loads(line); self.buf=rest.encode(); return obj
                except: text=rest; self.buf=rest.encode(); continue
        return None
    def _init(self):
        self._send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
            "protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bench","version":"1.0"}}})
        self._recv()
        self._send({"jsonrpc":"2.0","method":"notifications/initialized"})
        time.sleep(0.8)
    def call(self, tool, args):
        self.id+=1; self._send({"jsonrpc":"2.0","id":self.id,"method":"tools/call","params":{"name":tool,"arguments":args}}); return self._recv()
    def search(self, query): return self.call("codedb_search",{"query":query,"max_results":MAX_RESULTS})
    def close(self): self.proc.terminate(); self.proc.wait()

def grep_truth(query, src_dir):
    files=set(); q=query.lower()
    for root,dirs,fnames in os.walk(src_dir):
        dirs[:]=[d for d in dirs if d not in {'.git','node_modules','zig-cache','.zig-cache','zig-out'}]
        for f in fnames:
            path=os.path.join(root,f)
            try:
                content=open(path,errors='ignore').read().lower()
                if q in content: files.add(path)
            except: pass
    return len(files)

def parse_files(resp):
    if not resp: return set()
    import re
    try:
        files = set()
        for c in resp.get("result",{}).get("content",[]):
            if c.get("type")!="text": continue
            text = re.sub(r'\x1b\[[0-9;]*m','',c.get("text",""))
            for line in text.split('\n'):
                line = line.strip()
                if not line: continue
                if 'results for' in line or line.startswith('Found'): continue
                if line.startswith(('\u2192','\u26a1','\u2713','!','#')): continue  # hint/header
                if ':' in line:
                    path = line.split(':')[0]
                    # must look like a real path: contains . or /
                    if ('.' in path or '/' in path) and not path.startswith('\u2192'):
                        files.add(path)
        return files
    except: return set()

def time_search(client, query, iters=ITERS):
    client.search(query)
    s=[]
    for _ in range(iters):
        t0=time.perf_counter(); client.search(query); s.append((time.perf_counter()-t0)*1000)
    return statistics.median(s)

def geomean(vals):
    return math.exp(sum(math.log(max(v,0.001)) for v in vals)/len(vals))

cpu=subprocess.run(["sysctl","-n","machdep.cpu.brand_string"],capture_output=True,text=True).stdout.strip()
ram=int(subprocess.run(["sysctl","-n","hw.memsize"],capture_output=True,text=True).stdout.strip())//(1024**3)

print(f"\n{W}{'='*72}{N}")
print(f"{W}  codedb v0.2.572 vs v0.2.58 — identifier-splitting benchmark{N}")
print(f"{W}{'='*72}{N}")
print(f"{D}  Repo:    {REPO}  |  {cpu} {ram}GB{N}")
print(f"{D}  Method:  MCP stdio warm, p50 of {ITERS} iters{N}")
print(f"{D}  SUB = camelCase/snake sub-token (Tier-0 in v0.2.58, trigram scan in v0.2.572){N}")
print(f"{D}  FULL = full identifier word (Tier-0 hit in both versions){N}",flush=True)

QUERIES=[
    ("search",  "SUB","sub-token of searchContent, searchDeduped"),
    ("index",   "SUB","sub-token of indexFile, TrigramIndex"),
    ("word",    "SUB","sub-token of word_index, WordTokenizer"),
    ("init",    "SUB","sub-token of initExplorer, initTrigram"),
    ("get",     "SUB","sub-token of getOrPut, getEntry"),
    ("remove",  "SUB","sub-token of removeFile"),
    ("content", "SUB","sub-token of searchContent, readContent"),
    ("file",    "SUB","sub-token of indexFile, removeFile"),
    ("allocator","FULL","common standalone word"),
    ("wordindex","FULL","full lowercased camelCase identifier"),
    ("xyzzy99", "FULL","nonexistent — miss latency"),
]

src_dir=os.path.join(REPO,"src")
print(f"\n{D}  Computing grep ground truth...{N}",flush=True)
truth={q:grep_truth(q,src_dir) for q,_,_ in QUERIES}
print(f"{D}  Starting MCP servers...{N}",flush=True)
oc=McpClient(OLD,REPO); nc=McpClient(NEW,REPO)
print(f"  {G}OK{N} Both servers ready\n",flush=True)

print(f"  {'Query':<14} {'Grp':<4} {'v0.2.572':>10}  {'v0.2.58':>9}  {'Spdup':>6}  {'GT':>4}  {'old':>4}  {'new':>4}  {'dR':>3}")
print("  "+"-"*70)
rows=[]
for query,group,desc in QUERIES:
    old_ms=time_search(oc,query); new_ms=time_search(nc,query)
    old_f=parse_files(oc.search(query)); new_f=parse_files(nc.search(query))
    gt=truth[query]; spd=old_ms/new_ms if new_ms>0 else 99
    dr=len(new_f)-len(old_f)
    cs=G if spd>=1.3 else (Y if spd>=0.9 else R)
    cr=G if dr>0 else (N if dr==0 else R)
    gc=C if group=="SUB" else D
    print(f"  {query:<14} {gc}{group:<4}{N} {D}{old_ms:>9.2f}ms{N}  {G}{new_ms:>8.2f}ms{N}  {cs}{spd:>5.1f}x{N}  {D}{gt:>4}{N}  {D}{len(old_f):>4}{N}  {G}{len(new_f):>4}{N}  {cr}{dr:>+3}{N}",flush=True)
    rows.append((query,group,old_ms,new_ms,spd,gt,len(old_f),len(new_f),dr))

sub=[r for r in rows if r[1]=="SUB"]; full=[r for r in rows if r[1]=="FULL"]
print(f"\n{W}  Summary{N}")
print(f"  {'-'*55}")
print(f"  SUB-TOKEN:  speedup {G}{geomean([r[4] for r in sub]):.1f}x{N}  recall gain {G}{sum(r[8] for r in sub):+d} files{N}")
print(f"  FULL ident: speedup {Y}{geomean([r[4] for r in full]):.1f}x{N}  recall gain {sum(r[8] for r in full):+d} files\n")

oc.close(); nc.close()
