// codedb — Zig module for semantic code intelligence
//
// Provides: symbol indexing, dependency graphs, version tracking,
// trigram/word search indexes, and file watching.
//
// Usage as a dependency:
//   const codedb = @import("codedb");
//   var store = codedb.Store.init(allocator);
//   var explorer = codedb.Explorer.init(allocator);
//   try codedb.watcher.initialScan(&store, &explorer, root, allocator);

pub const Store = @import("store.zig").Store;
pub const ChangeEntry = @import("store.zig").ChangeEntry;

pub const Explorer = @import("explore.zig").Explorer;
pub const FileOutline = @import("explore.zig").FileOutline;
pub const Symbol = @import("explore.zig").Symbol;
pub const SymbolKind = @import("explore.zig").SymbolKind;
pub const SymbolResult = @import("explore.zig").SymbolResult;
pub const SearchResult = @import("explore.zig").SearchResult;
pub const Language = @import("explore.zig").Language;

pub const WordIndex = @import("index.zig").WordIndex;
pub const TrigramIndex = @import("index.zig").TrigramIndex;
pub const SparseNgramIndex = @import("index.zig").SparseNgramIndex;
pub const SparseNgram = @import("index.zig").SparseNgram;
pub const pairWeight = @import("index.zig").pairWeight;
pub const extractSparseNgrams = @import("index.zig").extractSparseNgrams;
pub const buildCoveringSet = @import("index.zig").buildCoveringSet;
pub const setFrequencyTable = @import("index.zig").setFrequencyTable;
pub const resetFrequencyTable = @import("index.zig").resetFrequencyTable;
pub const buildFrequencyTable = @import("index.zig").buildFrequencyTable;
pub const buildFrequencyTableFromSlices = @import("index.zig").buildFrequencyTableFromSlices;
pub const buildFrequencyTableFromMap = @import("index.zig").buildFrequencyTableFromMap;
pub const writeFrequencyTable = @import("index.zig").writeFrequencyTable;
pub const readFrequencyTable = @import("index.zig").readFrequencyTable;
pub const default_pair_freq = @import("index.zig").default_pair_freq;

pub const WordHit = @import("index.zig").WordHit;
pub const WordTokenizer = @import("index.zig").WordTokenizer;

pub const AgentRegistry = @import("agent.zig").AgentRegistry;
pub const Agent = @import("agent.zig").Agent;
pub const AgentId = @import("agent.zig").AgentId;
pub const AgentState = @import("agent.zig").AgentState;

pub const Version = @import("version.zig").Version;
pub const FileVersions = @import("version.zig").FileVersions;
pub const Op = @import("version.zig").Op;

pub const EditRequest = @import("edit.zig").EditRequest;
pub const EditResult = @import("edit.zig").EditResult;
pub const applyEdit = @import("edit.zig").applyEdit;

pub const watcher = @import("watcher.zig");
pub const mcp = @import("mcp.zig");
pub const snapshot_json = @import("snapshot_json.zig");
