//! MCP tool definitions and handlers.
//!
//! Phase 1 tools: index_repository, list_projects, search, get_graph_schema.
//! Phase 2 tools: search_graph, get_code_snippet, query_graph.
//! Phase 3 tools: detect_changes, delete_project.
//! Phase 4 tools: trace_call_path, get_architecture, manage_adr.
//! Phase 5 tools: detect_communities, rename_symbol, ingest_traces.
//! Phase 6 tools: (merged into search with mode param).
//! v0.6.0: consolidated 30 -> 23 tools.

const std = @import("std");
const protocol = @import("protocol.zig");
const indexer = @import("../../core/indexer/indexer.zig");
const incremental = @import("../../core/indexer/incremental.zig");
const scanner = @import("../../core/scanner/scanner.zig");
const storage = @import("../../core/storage/index.zig");
const search_engine = @import("../../core/search/engine.zig");
const graph_db = @import("../../core/storage/graph_db.zig");
const project_store = @import("../../core/project_store.zig");
const pipeline_mod = @import("../../core/parser/pipeline.zig");
const call_graph = @import("../../core/graph/call_graph.zig");
const arch_mod = @import("../../core/analysis/arch.zig");
const leiden_mod = @import("../../core/graph/leiden.zig");
const cypher_lexer = @import("../../core/graph/cypher/lexer.zig");
const cypher_parser = @import("../../core/graph/cypher/parser.zig");
const cypher_executor = @import("../../core/graph/cypher/executor.zig");
const semantic_mod = @import("../../core/search/semantic.zig");
const ai_context = @import("../../core/ai/context.zig");
const ai_summarize = @import("../../core/ai/summarize.zig");
const ai_query = @import("../../core/ai/query.zig");
const ai_window = @import("../../core/ai/window.zig");
const config_mod = @import("../../core/config.zig");

/// MCP tool descriptor — matches the tools/list response format.
pub const Descriptor = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: []const u8, // JSON literal
};

/// All tools registered (v0.6.0 — 23 tools).
pub const ALL = [_]Descriptor{
    index_repository,
    update_index,
    detect_changes,
    list_projects,
    delete_project,
    get_graph_schema,
    health_check,
    search,
    search_graph,
    get_code_snippet,
    query_graph,
    read_file,
    list_files,
    file_outline,
    get_context,
    summarize_symbol,
    trace_call_path,
    get_architecture,
    detect_communities,
    rename_symbol,
    manage_adr,
    ingest_traces,
    config,
};

/// Apply detected file changes incrementally: updates the SQLite graph DB
/// and rebuilds the BM25 delta overlay so search reflects the new state
/// without a full re-index.
pub const update_index = Descriptor{
    .name = "update_index",
    .description = "Apply added/modified/deleted files to the graph DB and rebuild the BM25 overlay incrementally. Much faster than index_repository on small deltas.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {},
    \\  "additionalProperties": false
    \\}
    ,
};

pub const index_repository = Descriptor{
    .name = "index_repository",
    .description = "Index a repository into the knowledge graph. BM25 full-text search (the `search` tool, mode=keyword) works across 20+ languages. AST-level symbol and edge extraction (calls, imports, types — powering search_graph, trace_call_path, get_architecture) is available for Zig, Python, JavaScript, TypeScript, TSX, Go, Rust, Java, C, and C++. If the repo is already indexed, only changed files are re-processed (fast); pass force:true for a full rebuild.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Absolute path to the repository root directory"
    \\    },
    \\    "force": {
    \\      "type": "boolean",
    \\      "description": "Force a full re-index even if the repo is already indexed (default: incremental update of changed files only)"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub const list_projects = Descriptor{
    .name = "list_projects",
    .description = "List all indexed repositories in the project store.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {}
    \\}
    ,
};

pub const search = Descriptor{
    .name = "search",
    .description = "Search indexed source files. mode=\"keyword\" uses BM25 ranking with scored snippets (optional stream); mode=\"semantic\" uses document-embedding cosine similarity; mode=\"hybrid\" (default) fuses BM25 + semantic via Reciprocal Rank Fusion. Falls back to keyword when no embeddings are available.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "query": {
    \\      "type": "string",
    \\      "description": "Search query string"
    \\    },
    \\    "mode": {
    \\      "type": "string",
    \\      "enum": ["keyword", "semantic", "hybrid"],
    \\      "description": "Search mode: keyword (BM25), semantic (embeddings), or hybrid (default, RRF fusion)"
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum number of results (default 10, max 100)"
    \\    },
    \\    "stream": {
    \\      "type": "boolean",
    \\      "description": "When true (keyword/hybrid only), server emits batched JSON-RPC notifications and replies with {streamed:true,total,query}."
    \\    }
    \\  },
    \\  "required": ["query"],
    \\  "additionalProperties": false
    \\}
    ,
};

pub const get_graph_schema = Descriptor{
    .name = "get_graph_schema",
    .description = "Return the knowledge graph schema including node and edge types with current counts.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {}
    \\}
    ,
};

pub const search_graph = Descriptor{
    .name = "search_graph",
    .description = "Search symbols in the knowledge graph by name pattern, kind, or degree. Returns matching symbols with file location and edge counts.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "name_pattern": {
    \\      "type": "string",
    \\      "description": "SQL LIKE pattern for symbol name (e.g. '%init%', 'main')"
    \\    },
    \\    "kind": {
    \\      "type": "string",
    \\      "description": "Filter by symbol kind: function, method, struct_type, enum_type, const_value, etc."
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum results (default 20, max 100)"
    \\    }
    \\  },
    \\  "required": ["name_pattern"]
    \\}
    ,
};

pub const get_code_snippet = Descriptor{
    .name = "get_code_snippet",
    .description = "Retrieve a source code snippet for a symbol by name. Returns the symbol's definition with surrounding context lines.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "name": {
    \\      "type": "string",
    \\      "description": "Exact symbol name to look up"
    \\    },
    \\    "context_lines": {
    \\      "type": "integer",
    \\      "description": "Number of context lines before and after the symbol (default 5)"
    \\    }
    \\  },
    \\  "required": ["name"]
    \\}
    ,
};

pub const query_graph = Descriptor{
    .name = "query_graph",
    .description = "Run a read-only query against the knowledge graph database. Accepts either a SQL SELECT (tables: documents, symbols, edges) or a Cypher query starting with MATCH (e.g. MATCH (a)-[r:CALLS]->(b) RETURN a.name, b.name LIMIT 20). Queries beginning with MATCH are routed to the Cypher executor; everything else is treated as SQL. Only read-only queries are allowed.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "query": {
    \\      "type": "string",
    \\      "description": "SQL SELECT against documents/symbols/edges, or a Cypher MATCH ... RETURN query"
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum rows to return (default 50, max 200)"
    \\    }
    \\  },
    \\  "required": ["query"]
    \\}
    ,
};

pub const detect_changes = Descriptor{
    .name = "detect_changes",
    .description = "Compare the current filesystem state against the last index to detect added, modified, and deleted files. Returns lists of changed files without re-indexing.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Repository root path (uses loaded project if omitted)"
    \\    }
    \\  },
    \\  "required": []
    \\}
    ,
};

pub const delete_project = Descriptor{
    .name = "delete_project",
    .description = "Remove a project from the index store, deleting all indexed data.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Repository root path of the project to delete"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub const trace_call_path = Descriptor{
    .name = "trace_call_path",
    .description = "Trace the call graph from a symbol: inbound (who calls it), outbound (what it calls), or both. Detects cycles and optionally includes edge confidence scores.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "name": {
    \\      "type": "string",
    \\      "description": "Exact symbol name to trace from"
    \\    },
    \\    "direction": {
    \\      "type": "string",
    \\      "enum": ["inbound", "outbound", "both"],
    \\      "description": "Traversal direction (default: both)"
    \\    },
    \\    "max_depth": {
    \\      "type": "integer",
    \\      "description": "Maximum BFS depth (default 5, max 10)"
    \\    },
    \\    "include_confidence": {
    \\      "type": "boolean",
    \\      "description": "Include edge confidence scores in output (default: false)"
    \\    }
    \\  },
    \\  "required": ["name"]
    \\}
    ,
};

pub const get_architecture = Descriptor{
    .name = "get_architecture",
    .description = "Analyze the codebase architecture: modules, entry points, high fan-in/fan-out symbols, hotspots, module coupling, and overall stats.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum entries per category (default 10)"
    \\    }
    \\  }
    \\}
    ,
};

pub const manage_adr = Descriptor{
    .name = "manage_adr",
    .description = "Manage Architecture Decision Records (ADRs): list, get, or create decisions.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "action": {
    \\      "type": "string",
    \\      "enum": ["list", "get", "create"],
    \\      "description": "Action to perform"
    \\    },
    \\    "title": {
    \\      "type": "string",
    \\      "description": "ADR title (required for create, optional for get)"
    \\    },
    \\    "context": {
    \\      "type": "string",
    \\      "description": "Background context (for create)"
    \\    },
    \\    "decision": {
    \\      "type": "string",
    \\      "description": "The decision made (for create)"
    \\    }
    \\  },
    \\  "required": ["action"]
    \\}
    ,
};

pub const rename_symbol = Descriptor{
    .name = "rename_symbol",
    .description = "Rename a symbol across all files (in-place text replacement), using the graph to find all occurences. Dry-run by default.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "old_name": {
    \\      "type": "string",
    \\      "description": "Current symbol name to rename"
    \\    },
    \\    "new_name": {
    \\      "type": "string",
    \\      "description": "New symbol name"
    \\    },
    \\    "dry_run": {
    \\      "type": "boolean",
    \\      "description": "Preview changes without applying (default: true)"
    \\    }
    \\  },
    \\  "required": ["old_name", "new_name"]
    \\}
    ,
};

pub const ingest_traces = Descriptor{
    .name = "ingest_traces",
    .description = "Ingest runtime trace data (call stacks, execution traces) into the graph for analysis.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "data": {
    \\      "type": "string",
    \\      "description": "Trace data as JSON string (array of {caller, callee, file, line} objects)"
    \\    },
    \\    "format": {
    \\      "type": "string",
    \\      "description": "Format of trace data (json, text). Default: json"
    \\    },
    \\    "source": {
    \\      "type": "string",
    \\      "description": "Trace source identifier (e.g., 'llvm-cov', 'perf', 'manual'). Default: 'runtime'"
    \\    }
    \\  },
    \\  "required": ["data"]
    \\}
    ,
};

pub const detect_communities = Descriptor{
    .name = "detect_communities",
    .description = "Community operations on the symbol graph. action=\"run\" (default) runs Leiden detection and assigns community_id to each symbol; action=\"list\" lists detected communities with member counts and samples; action=\"get\" returns the community and members for a specific symbol.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "action": {
    \\      "type": "string",
    \\      "enum": ["run", "list", "get"],
    \\      "description": "Action to perform: run (detect), list (all communities), get (symbol's community). Default: run."
    \\    },
    \\    "resolution": {
    \\      "type": "number",
    \\      "description": "Resolution parameter for community granularity (default 1.0, higher = more communities). Used by action=run."
    \\    },
    \\    "symbol_name": {
    \\      "type": "string",
    \\      "description": "Exact symbol name to look up. Required for action=get."
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum number of communities to return (default 20). Used by action=list."
    \\    }
    \\  },
    \\  "additionalProperties": false
    \\}
    ,
};

pub const health_check = Descriptor{
    .name = "health_check",
    .description = "Check the health of the indexed project. Returns document/symbol/edge/embedding/community counts, last indexed time, and uptime.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {}
    \\}
    ,
};

pub const get_context = Descriptor{
    .name = "get_context",
    .description = "Assemble rich AI-prompt context from search results, call graphs, and architecture overviews. Enforces a token budget — low-priority sections are dropped when the budget is exceeded.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "query": {
    \\      "type": "string",
    \\      "description": "The search query or natural-language question"
    \\    },
    \\    "max_tokens": {
    \\      "type": "integer",
    \\      "description": "Maximum token budget for the assembled context (default: 4000)"
    \\    },
    \\    "include_call_graph": {
    \\      "type": "boolean",
    \\      "description": "Whether to include call graph context for matched symbols (default: true)"
    \\    },
    \\    "include_architecture": {
    \\      "type": "boolean",
    \\      "description": "Whether to include an architecture overview (default: false)"
    \\    }
    \\  },
    \\  "required": ["query"]
    \\}
    ,
};

pub const summarize_symbol = Descriptor{
    .name = "summarize_symbol",
    .description = "Summarise a code symbol: extracts signature, purpose (from doc comments), key operations, dependencies, and a rough complexity score. Supports Zig, Python, JavaScript, Rust, Go, C, C++, Java.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "symbol_name": {
    \\      "type": "string",
    \\      "description": "Name of the symbol to summarise"
    \\    },
    \\    "language": {
    \\      "type": "string",
    \\      "description": "Source language (e.g. 'zig', 'python', 'javascript')"
    \\    }
    \\  },
    \\  "required": ["symbol_name"]
    \\}
    ,
};

pub const config = Descriptor{
    .name = "config",
    .description = "Get or set zindeks configuration. When called with no params, returns the current configuration. When any param is provided, updates those fields, persists to file, and returns the updated configuration.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "colors_enabled": {
    \\      "type": "string",
    \\      "description": "Enable/disable color output (true|false)"
    \\    },
    \\    "max_results": {
    \\      "type": "string",
    \\      "description": "Default max search results"
    \\    },
    \\    "default_repo": {
    \\      "type": "string",
    \\      "description": "Default GitHub repo for updates"
    \\    },
    \\    "embedding_model": {
    \\      "type": "string",
    \\      "description": "Embedding model name"
    \\    },
    \\    "store_root": {
    \\      "type": "string",
    \\      "description": "Custom index store root path"
    \\    }
    \\  },
    \\  "additionalProperties": false
    \\}
    ,
};

pub const read_file = Descriptor{
    .name = "read_file",
    .description = "Read a file by path with line numbers (compressed cat -n: tab-delimited line numbers, blank-line runs collapsed, content byte-exact). offset/limit page like Claude's Read. Prefer this over shell cat/Read for indexed repos.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path (absolute, or relative to project root)"
    \\    },
    \\    "offset": {
    \\      "type": "integer",
    \\      "description": "1-based first line to show (default 1)"
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Max lines to show (default 2000)"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

pub const list_files = Descriptor{
    .name = "list_files",
    .description = "List indexed files, optionally filtered by glob pattern or directory prefix. Replaces Glob for the indexed repo. Returns paths only (token-cheap).",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {
    \\      "type": "string",
    \\      "description": "Glob pattern (e.g. *.zig) or substring to filter paths"
    \\    },
    \\    "dir": {
    \\      "type": "string",
    \\      "description": "Directory prefix filter (e.g. src/api)"
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Max results (default 200)"
    \\    }
    \\  },
    \\  "required": []
    \\}
    ,
};

pub const file_outline = Descriptor{
    .name = "file_outline",
    .description = "Structural outline of one file: symbol names, kinds, and line ranges, without full content. Cheapest way to understand a file before reading it.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path (absolute or relative to project root)"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
    ,
};

// ██████████████████████████████████████████████████████████████████████████
// Tool JSON serialization (for tools/list response)
// ██████████████████████████████████████████████████████████████████████████

pub fn writeToolsListJson(writer: anytype) !void {
    try writer.writeByte('[');
    for (ALL, 0..) |tool, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try protocol.writeJsonString(writer, tool.name);
        try writer.writeAll(",\"description\":");
        try protocol.writeJsonString(writer, tool.description);
        try writer.writeAll(",\"inputSchema\":");
        try writeCompactJson(writer, tool.inputSchema);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

/// Pass-through writer that strips embedded `\n` / `\r` from a raw JSON
/// blob so the result fits on a single line.  The MCP spec mandates
/// newline-free messages on the stdio transport — our tool schemas are
/// authored as Zig multi-line literals for readability, and would
/// otherwise emit several physical lines and corrupt framing.  All
/// non-newline whitespace is preserved (it stays semantically equivalent
/// JSON).
fn writeCompactJson(writer: anytype, raw: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\n' or c == '\r') {
            if (i > start) try writer.writeAll(raw[start..i]);
            // Replace the newline with a single space so the surrounding
            // tokens stay separated (e.g. `}\n  ,` must not collapse to `},`).
            try writer.writeByte(' ');
            start = i + 1;
        }
    }
    if (start < raw.len) try writer.writeAll(raw[start..]);
}

// ██████████████████████████████████████████████████████████████████████████
// Shared context passed to every tool handler
// ██████████████████████████████████████████████████████████████████████████

pub const Context = struct {
    allocator: std.mem.Allocator,
    engine: ?*search_engine.Engine = null,
    gdb: ?*graph_db.GraphDb = null,
    project_path: ?[]const u8 = null,
    /// Resolved index directory for the currently loaded project.  Required
    /// by `update_index` to know where to rebuild the overlay sub-index.
    index_dir: ?[]const u8 = null,
    /// Custom store root override, forwarded from the CLI `--store-root` flag.
    store_root: ?[]const u8 = null,
    /// Optional transport pointer.  When present, handlers that support
    /// streaming may emit JSON-RPC notifications via the transport so the
    /// client sees partial results before the final tool response.  Nil
    /// when the caller does not want streaming (e.g., embedded use).
    transport: ?*protocol.Transport = null,
    /// JSON-RPC id of the in-flight request.  Used by streaming handlers
    /// to tag each notification's `params.request_id` so the client can
    /// demux when multiple tool calls overlap.
    request_id: ?std.json.Value = null,
    /// Optional parser pool — when non-null, incremental updates reuse
    /// TSParser instances instead of allocating/freeing per file.
    parser_pool: ?*incremental.ParserPool = null,
};

// ██████████████████████████████████████████████████████████████████████████
// Tool dispatch
// ██████████████████████████████████████████████████████████████████████████

pub fn dispatch(
    ctx: *Context,
    tool_name: []const u8,
    params_obj: ?std.json.ObjectMap,
    writer: anytype,
) !void {
    if (std.mem.eql(u8, tool_name, "index_repository")) {
        try handleIndexRepository(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "list_projects")) {
        try handleListProjects(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "search")) {
        try handleSearch(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "get_graph_schema")) {
        try handleGetGraphSchema(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "search_graph")) {
        try handleSearchGraph(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "get_code_snippet")) {
        try handleGetCodeSnippet(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "query_graph")) {
        try handleQueryGraph(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "detect_changes")) {
        try handleDetectChanges(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "update_index")) {
        try handleUpdateIndex(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "delete_project")) {
        try handleDeleteProject(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "trace_call_path")) {
        try handleTraceCallPath(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "get_architecture")) {
        try handleGetArchitecture(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "manage_adr")) {
        try handleManageAdr(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "rename_symbol")) {
        try handleRenameSymbol(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "ingest_traces")) {
        try handleIngestTraces(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "detect_communities")) {
        try handleDetectCommunities(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "health_check")) {
        try handleHealthCheck(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "get_context")) {
        try handleGetContext(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "summarize_symbol")) {
        try handleSummarizeSymbol(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "config")) {
        try handleConfig(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "read_file")) {
        try handleReadFile(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "list_files")) {
        try handleListFiles(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "file_outline")) {
        try handleFileOutline(ctx, params_obj, writer);
    } else {
        // Propagate as an error so the caller emits an MCP-compliant
        // `result.isError: true` envelope.  Embedding the tool name as a
        // properly-escaped JSON string keeps the body well-formed.
        try writer.writeAll("{\"error\":\"Unknown tool: ");
        try writeJsonStringContents(writer, tool_name);
        try writer.writeAll("\"}");
        return error.UnknownTool;
    }
}

/// Like `protocol.writeJsonString` but emits the *escaped contents* only —
/// no surrounding quote bytes.  Used when embedding a string inside a
/// JSON value we're constructing piece-by-piece.
fn writeJsonStringContents(writer: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: index_repository
// ██████████████████████████████████████████████████████████████████████████

fn handleIndexRepository(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.path\"}");
        return;
    };
    const repo_path = getString(params, "path") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: path\"}");
        return;
    };
    const force = getBool(params, "force") orelse false;

    // Incremental path: if already indexed and not forced, apply only changes.
    var read_loc = project_store.resolveRead(ctx.allocator, repo_path, .{ .store_root = ctx.store_root }) catch null;
    if (!force) {
        if (read_loc) |*rl| {
            var pbuf: [std.fs.max_path_bytes]u8 = undefined;
            const project_path = try std.fs.cwd().realpath(repo_path, &pbuf);
            const graph_path = try std.fs.path.join(ctx.allocator, &.{ rl.index_dir, "graph.db" });
            defer ctx.allocator.free(graph_path);
            const graph_path_z = try ctx.allocator.dupeZ(u8, graph_path);
            defer ctx.allocator.free(graph_path_z);
            var gdb = try graph_db.GraphDb.open(graph_path_z);
            try gdb.migrate();
            defer gdb.close();
            var diff = incremental.detectChanges(ctx.allocator, &gdb, project_path) catch {
                rl.deinit();
                try writer.writeAll("{\"error\":\"Failed to detect changes.\"}");
                return;
            };
            defer diff.deinit();
            const stats = incremental.applyChangesWithOverlayPooled(ctx.allocator, &gdb, project_path, rl.index_dir, &diff, ctx.parser_pool) catch |err| {
                rl.deinit();
                try writer.print("{{\"error\":\"applyChangesWithOverlay failed: {s}\"}}", .{@errorName(err)});
                return;
            };
            try writer.print(
                \\{{"project":"{s}","mode":"incremental","added":{},"modified":{},"deleted":{},"symbols_added":{},"edges_added":{},"errors":{},"duration_ms":{}}}
            , .{ project_path, stats.added, stats.modified, stats.deleted, stats.symbols_added, stats.edges_added, stats.errors, stats.duration_ms });
            rl.deinit();
            return;
        }
    } else {
        if (read_loc) |*rl| rl.deinit();
    }

    // Full build path (force=true or not yet indexed).
    var loc = try project_store.prepareWrite(ctx.allocator, repo_path, .{ .store_root = ctx.store_root });
    defer loc.deinit();

    try indexer.indexPath(ctx.allocator, repo_path, loc.index_dir);
    try loc.commit();

    var project_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_dir = try std.fs.cwd().realpath(repo_path, &project_dir_buf);
    var index_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_dir = try std.fs.cwd().realpath(loc.index_dir, &index_dir_buf);

    const graph_path = try std.fs.path.join(ctx.allocator, &.{ index_dir, "graph.db" });
    defer ctx.allocator.free(graph_path);
    const graph_path_z = try ctx.allocator.dupeZ(u8, graph_path);
    defer ctx.allocator.free(graph_path_z);

    var gdb = try graph_db.GraphDb.open(graph_path_z);
    try gdb.migrate();
    defer gdb.close();

    var pipe = pipeline_mod.Pipeline.init(ctx.allocator, gdb, project_dir);
    const pipe_result = try pipe.run();

    // Build and persist HNSW ANN index from the freshly-written embeddings.
    // Non-fatal: projects below MIN_ANN_DOCS threshold simply skip this.
    semantic_mod.buildAndSaveAnn(&gdb, index_dir, ctx.allocator) catch |err| {
        std.log.warn("ANN build skipped: {s}", .{@errorName(err)});
    };

    try writer.print(
        \\{{"project":"{s}","mode":"full","files_indexed":{},"symbols":{},"edges":{},"pipeline_ms":{}}}
    , .{ project_dir, pipe_result.files_scanned, pipe_result.symbols_extracted, pipe_result.edges_extracted, pipe_result.duration_ms });
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: list_projects
// ██████████████████████████████████████████████████████████████████████████

fn handleListProjects(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    _ = params_obj;

    const store_root = try project_store.defaultStoreRoot(ctx.allocator, ctx.store_root);
    defer ctx.allocator.free(store_root);

    const projects_dir = try std.fs.path.join(ctx.allocator, &.{ store_root, "projects" });
    defer ctx.allocator.free(projects_dir);

    var dir = std.fs.cwd().openDir(projects_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.writeAll("[]");
            return;
        },
        else => |e| return e,
    };
    defer dir.close();

    var results = std.ArrayList([]const u8).initCapacity(ctx.allocator, 32) catch @panic("OOM");
    defer {
        for (results.items) |s| ctx.allocator.free(s);
        results.deinit(ctx.allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        const proj_dir_path = try std.fs.path.join(ctx.allocator, &.{ projects_dir, entry.name });
        defer ctx.allocator.free(proj_dir_path);

        const proj_json_path = try std.fs.path.join(ctx.allocator, &.{ proj_dir_path, "project.json" });
        defer ctx.allocator.free(proj_json_path);

        const raw = std.fs.cwd().readFileAlloc(ctx.allocator, proj_json_path, 4096) catch continue;
        defer ctx.allocator.free(raw);

        try results.append(ctx.allocator, try ctx.allocator.dupe(u8, raw));
    }

    try writer.writeByte('[');
    for (results.items, 0..) |raw, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll(raw);
    }
    try writer.writeByte(']');
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: search  (unified — routes to keyword/semantic/hybrid by mode param)
// ██████████████████████████████████████████████████████████████████████████

fn handleSearch(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.query\"}");
        return;
    };
    const mode = getString(params, "mode") orelse "hybrid";

    if (std.mem.eql(u8, mode, "keyword")) {
        try handleSearchCode(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, mode, "semantic")) {
        try handleSemanticSearch(ctx, params_obj, writer);
    } else {
        // "hybrid" (default) — try hybrid; gracefully fall back to keyword
        // when the engine has no embeddings (hybridSearch degrades internally).
        try handleHybridSearch(ctx, params_obj, writer);
    }
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: search_code (internal — called by handleSearch)
// ██████████████████████████████████████████████████████████████████████████

fn handleSearchCode(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const engine = ctx.engine orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.query\"}");
        return;
    };
    const query = getString(params, "query") orelse "";
    const limit = getLimit(params, 10);
    const stream_requested = blk: {
        if (params.get("stream")) |v| switch (v) {
            .bool => |b| break :blk b,
            else => {},
        };
        break :blk false;
    };

    if (query.len == 0) {
        try writer.writeAll("{\"error\":\"Empty query\"}");
        return;
    }

    var results = try engine.search(ctx.allocator, query, limit);
    defer results.deinit(ctx.allocator);

    // Streaming path: when the caller has wired a transport AND requested
    // streaming, emit batched notifications so the client sees first hits
    // before the search finishes.  Falls back to the buffered inline path
    // when streaming is unavailable.
    if (stream_requested and ctx.transport != null) {
        try emitSearchStream(ctx, query, results.items);
        try writer.print(
            \\{{"streamed":true,"total":{d},"query":{f}}}
        , .{ results.items.len, std.json.fmt(query, .{}) });
        return;
    }

    try writer.writeByte('[');
    for (results.items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"path":{f},"score":{f},"snippet":{f}}}
        , .{
            std.json.fmt(item.path, .{}),
            std.json.fmt(item.score, .{}),
            std.json.fmt(item.snippet, .{}),
        });
    }
    try writer.writeByte(']');
}

/// Batch size for streaming search results.  Small enough that the first
/// notification fires quickly; large enough that we are not sending a
/// separate framed message per hit.
const STREAM_BATCH_SIZE: usize = 20;

/// Emit search results as a sequence of JSON-RPC notifications, each one
/// carrying up to `STREAM_BATCH_SIZE` result items plus a `request_id` /
/// `batch_index` for client-side demux.  Writes go straight through the
/// transport's write mutex — no shared response buffer involvement.
fn emitSearchStream(ctx: *Context, query: []const u8, items: []const search_engine.Result) !void {
    const transport = ctx.transport.?;
    var batch_buf = std.ArrayList(u8).initCapacity(ctx.allocator, 4096) catch @panic("OOM");
    defer batch_buf.deinit(ctx.allocator);

    var i: usize = 0;
    var batch_index: u32 = 0;
    while (i < items.len) : (batch_index += 1) {
        const end = @min(i + STREAM_BATCH_SIZE, items.len);
        batch_buf.shrinkRetainingCapacity(0);
        const w = batch_buf.writer(ctx.allocator);
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/zindeks/searchResult\",\"params\":{");
        try w.print("\"query\":{f},\"batch_index\":{d},\"is_last\":{s},", .{
            std.json.fmt(query, .{}),
            batch_index,
            if (end == items.len) "true" else "false",
        });
        if (ctx.request_id) |id_val| {
            try w.writeAll("\"request_id\":");
            try writeJsonValue(w, id_val);
            try w.writeByte(',');
        }
        try w.writeAll("\"results\":[");
        for (items[i..end], 0..) |item, j| {
            if (j > 0) try w.writeByte(',');
            try w.print(
                \\{{"path":{f},"score":{f},"snippet":{f}}}
            , .{
                std.json.fmt(item.path, .{}),
                std.json.fmt(item.score, .{}),
                std.json.fmt(item.snippet, .{}),
            });
        }
        try w.writeAll("]}}");
        try transport.writeMessage(batch_buf.items);
        i = end;
    }
}

fn writeJsonValue(writer: anytype, v: std.json.Value) !void {
    switch (v) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .string, .number_string => |s| try protocol.writeJsonString(writer, s),
        else => try writer.writeAll("null"),
    }
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: get_graph_schema
// ██████████████████████████████████████████████████████████████████████████

fn handleGetGraphSchema(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    _ = params_obj;

    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    try writer.writeAll("{\"tables\":[");

    var table_stmt = try gdb.prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    defer table_stmt.finalize();

    var first = true;
    while (try table_stmt.step()) {
        const table_name = try table_stmt.columnText(0);
        const count_sql = try std.fmt.allocPrint(ctx.allocator, "SELECT COUNT(*) FROM \"{s}\"", .{table_name});
        defer ctx.allocator.free(count_sql);

        const count = try gdb.queryScalar(try ctx.allocator.dupeZ(u8, count_sql));

        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print(
            \\{{"name":{f},"row_count":{}}}
        , .{ std.json.fmt(table_name, .{}), count });
    }
    try writer.writeAll("]}");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: search_graph
// ██████████████████████████████████████████████████████████████████████████

fn handleSearchGraph(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.name_pattern\"}");
        return;
    };
    const name_pattern = getString(params, "name_pattern") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: name_pattern\"}");
        return;
    };
    const kind_filter = getString(params, "kind");
    const limit = getLimit(params, 20);

    // Build query
    var sql_buf = std.ArrayList(u8).initCapacity(ctx.allocator, 512) catch @panic("OOM");
    defer sql_buf.deinit(ctx.allocator);
    const sql_writer = sql_buf.writer(ctx.allocator);

    try sql_writer.writeAll(
        \\SELECT s.id, s.name, s.kind, s.line_start, s.line_end, s.col_start, s.col_end, d.path,
        \\  (SELECT COUNT(*) FROM edges e WHERE e.source_symbol_id = s.id) AS out_degree,
        \\  (SELECT COUNT(*) FROM edges e WHERE e.target_symbol_id = s.id) AS in_degree
        \\FROM symbols s
        \\JOIN documents d ON d.id = s.document_id
        \\WHERE s.name LIKE ?
    );
    if (kind_filter) |kind| {
        try sql_writer.print(" AND s.kind = '{s}'", .{kind});
    }
    try sql_writer.print(" ORDER BY s.name LIMIT {}", .{limit});

    const sql = try sql_buf.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(sql);
    const sql_z = try ctx.allocator.dupeZ(u8, sql);
    defer ctx.allocator.free(sql_z);

    var stmt = try gdb.prepare(sql_z);
    defer stmt.finalize();

    // LIKE pattern needs SQL wildcards — wrap the pattern
    var pattern_buf = std.ArrayList(u8).initCapacity(ctx.allocator, name_pattern.len + 4) catch @panic("OOM");
    defer pattern_buf.deinit(ctx.allocator);
    // If pattern doesn't already contain %, add wildcards
    if (std.mem.indexOfScalar(u8, name_pattern, '%') == null and std.mem.indexOfScalar(u8, name_pattern, '_') == null) {
        try pattern_buf.append(ctx.allocator, '%');
        try pattern_buf.appendSlice(ctx.allocator, name_pattern);
        try pattern_buf.append(ctx.allocator, '%');
    } else {
        try pattern_buf.appendSlice(ctx.allocator, name_pattern);
    }
    try stmt.bindText(1, pattern_buf.items);

    try writer.writeByte('[');
    var first = true;
    while (try stmt.step()) {
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print(
            \\{{"id":{},"name":{f},"kind":{f},"line_start":{},"line_end":{},"col_start":{},"col_end":{},"path":{f},"out_degree":{},"in_degree":{}}}
        , .{
            try stmt.columnInt(0),
            std.json.fmt(try stmt.columnText(1), .{}),
            std.json.fmt(try stmt.columnText(2), .{}),
            try stmt.columnInt(3),
            try stmt.columnInt(4),
            try stmt.columnInt(5),
            try stmt.columnInt(6),
            std.json.fmt(try stmt.columnText(7), .{}),
            try stmt.columnInt(8),
            try stmt.columnInt(9),
        });
    }
    try writer.writeByte(']');
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: get_code_snippet
// ██████████████████████████████████████████████████████████████████████████

fn handleGetCodeSnippet(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.name\"}");
        return;
    };
    const symbol_name = getString(params, "name") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: name\"}");
        return;
    };
    const context_lines = blk: {
        if (params.get("context_lines")) |v| switch (v) {
            .integer => |i| if (i > 0) break :blk @as(u32, @intCast(i)),
            else => {},
        };
        break :blk 5;
    };

    // Look up the symbol
    var stmt = try gdb.prepare(
        \\SELECT s.name, s.kind, s.line_start, s.line_end, s.col_start, s.col_end, d.path
        \\FROM symbols s
        \\JOIN documents d ON d.id = s.document_id
        \\WHERE s.name = ?
        \\LIMIT 1
    );
    defer stmt.finalize();
    try stmt.bindText(1, symbol_name);

    if (!(try stmt.step())) {
        try writer.writeAll("{\"error\":\"Symbol not found: ");
    try protocol.writeJsonString(writer, symbol_name);
    try writer.writeAll("\"}");
        return;
    }

    const sym_name = try stmt.columnText(0);
    const sym_kind = try stmt.columnText(1);
    const line_start: u32 = @intCast(try stmt.columnInt(2));
    const line_end: u32 = @intCast(try stmt.columnInt(3));
    const col_start: u32 = @intCast(try stmt.columnInt(4));
    const col_end: u32 = @intCast(try stmt.columnInt(5));
    const file_path = try stmt.columnText(6);

    // Read the file and extract the snippet
    const project_path = ctx.project_path orelse {
        try writer.writeAll("{\"error\":\"No project path. Run index_repository first.\"}");
        return;
    };
    const abs_path = try std.fs.path.join(ctx.allocator, &.{ project_path, file_path });
    defer ctx.allocator.free(abs_path);

    const content = std.fs.cwd().readFileAlloc(ctx.allocator, abs_path, 10 * 1024 * 1024) catch {
        try writer.writeAll("{\"error\":\"Cannot read file: ");
    try protocol.writeJsonString(writer, abs_path);
    try writer.writeAll("\"}");
        return;
    };
    defer ctx.allocator.free(content);

    // Extract lines around the symbol
    const snippet_start = if (line_start > context_lines) line_start - context_lines else 1;
    const snippet_end = line_end + context_lines;

    var lines = std.ArrayList([]const u8).initCapacity(ctx.allocator, 64) catch @panic("OOM");
    defer lines.deinit(ctx.allocator);
    var line_iter = std.mem.splitSequence(u8, content, "\n");
    var line_num: u32 = 0;
    while (line_iter.next()) |line| {
        line_num += 1;
        if (line_num >= snippet_start and line_num <= snippet_end) {
            try lines.append(ctx.allocator, line);
        }
        if (line_num > snippet_end) break;
    }

    try writer.print(
        \\{{"name":{f},"kind":{f},"line_start":{},"line_end":{},"col_start":{},"col_end":{},"path":{f},"snippet":"
    , .{
        std.json.fmt(sym_name, .{}),
        std.json.fmt(sym_kind, .{}),
        line_start,
        line_end,
        col_start,
        col_end,
        std.json.fmt(file_path, .{}),
    });

    // Write snippet lines as JSON-escaped string
    for (lines.items, 0..) |line, i| {
        if (i > 0) try writer.writeByte('\n');
        // Escape special JSON characters
        for (line) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\t' => try writer.writeAll("\\t"),
                '\r' => try writer.writeAll("\\r"),
                else => try writer.writeByte(c),
            }
        }
    }

    try writer.writeAll("\"}");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: query_graph
// ██████████████████████████████████████████████████████████████████████████

fn handleQueryGraph(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.query\"}");
        return;
    };
    const query = getString(params, "query") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: query\"}");
        return;
    };
    const limit = getLimit(params, 50);

    // Detect Cypher queries: if starts with MATCH, use Cypher executor
    if (isCypherQuery(query)) {
        var cypher_parser_inst = cypher_parser.Parser.init(ctx.allocator, query) catch {
            try writer.writeAll("{\"error\":\"Cypher parse error\"}");
            return;
        };
        defer cypher_parser_inst.deinit();

        const parsed = cypher_parser_inst.parseQuery() catch {
            try writer.writeAll("{\"error\":\"Cypher parse error\"}");
            return;
        };

        cypher_executor.execute(ctx.allocator, gdb, &parsed, writer) catch |err| {
            try writer.print("{{\"error\":\"Cypher execution failed: {s}\"}}", .{@errorName(err)});
        };
        return;
    }

    // Security: only allow SELECT queries (case-insensitive check)
    const query_trimmed = std.mem.trim(u8, query, " \t\n\r;");
    var prefix_buf: [6]u8 = undefined;
    const prefix_len = @min(query_trimmed.len, 6);
    for (prefix_buf[0..prefix_len], query_trimmed[0..prefix_len]) |*dst, src| {
        dst.* = std.ascii.toUpper(src);
    }
    if (!std.mem.eql(u8, prefix_buf[0..prefix_len], "SELECT"[0..prefix_len])) {
        try writer.writeAll("{\"error\":\"Only SELECT queries are allowed\"}");
        return;
    }

    // Add LIMIT if not present
    var sql = std.ArrayList(u8).initCapacity(ctx.allocator, query.len + 64) catch @panic("OOM");
    defer sql.deinit(ctx.allocator);
    const sql_writer = sql.writer(ctx.allocator);

    try sql_writer.writeAll(query);
    // Remove trailing semicolon if present
    if (sql.items.len > 0 and sql.items[sql.items.len - 1] == ';') {
        sql.items[sql.items.len - 1] = ' ';
    }
    // Add limit
    try sql_writer.print(" LIMIT {}", .{@min(limit, 200)});

    const sql_z = try ctx.allocator.dupeZ(u8, sql.items);
    defer ctx.allocator.free(sql_z);

    var stmt = gdb.prepare(sql_z) catch {
        try writer.writeAll("{\"error\":\"Invalid SQL query\"}");
        return;
    };
    defer stmt.finalize();

    const col_count = stmt.columnCount();

    try writer.writeByte('[');
    var first_row = true;
    while (stmt.step() catch {
        try writer.writeAll(",{\"error\":\"Query execution failed\"}]");
        return;
    }) {
        if (!first_row) try writer.writeByte(',');
        first_row = false;

        try writer.writeByte('{');
        for (0..col_count) |col| {
            if (col > 0) try writer.writeByte(',');
            const col_name = stmt.columnName(@intCast(col)) orelse "unknown";
            try writer.print("{f}:", .{std.json.fmt(col_name, .{})});

            const col_type = stmt.columnType(@intCast(col));
            switch (col_type) {
                .integer => try writer.print("{}", .{try stmt.columnInt(@intCast(col))}),
                .float => try writer.print("{d}", .{try stmt.columnFloat(@intCast(col))}),
                .text => try writer.print("{f}", .{std.json.fmt(try stmt.columnText(@intCast(col)), .{})}),
                .blob => try writer.writeAll("null"),
                .null => try writer.writeAll("null"),
            }
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}
// ██████████████████████████████████████████████████████████████████████████

// ██████████████████████████████████████████████████████████████████████████
// Tool: detect_changes
// ██████████████████████████████████████████████████████████████████████████

fn handleDetectChanges(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const project_path = ctx.project_path orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    _ = params_obj; // unused, future: path filter

    var diff = incremental.detectChanges(ctx.allocator, gdb, project_path) catch {
        try writer.writeAll("{\"error\":\"Failed to detect changes.\"}");
        return;
    };
    defer diff.deinit();

    try writer.print(
        \\{{"total_files":{},"added":{},"modified":{},"deleted":{},"details":{{}}
    , .{ diff.total_files, diff.added.len, diff.modified.len, diff.deleted.len });

    // Write added files
    try writer.writeAll("\"added_files\":[");
    for (diff.added, 0..) |change, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{f}", .{std.json.fmt(change.path, .{})});
    }
    try writer.writeAll("],");

    // Write modified files
    try writer.writeAll("\"modified_files\":[");
    for (diff.modified, 0..) |change, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{f}", .{std.json.fmt(change.path, .{})});
    }
    try writer.writeAll("],");

    // Write deleted files
    try writer.writeAll("\"deleted_files\":[");
    for (diff.deleted, 0..) |change, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{f}", .{std.json.fmt(change.path, .{})});
    }
    try writer.writeAll("]}}");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: update_index
// ██████████████████████████████████████████████████████████████████████████

fn handleUpdateIndex(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    _ = params_obj;
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };
    const project_path = ctx.project_path orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };
    const index_dir = ctx.index_dir orelse {
        try writer.writeAll("{\"error\":\"No index directory resolved for the loaded project.\"}");
        return;
    };

    var diff = incremental.detectChanges(ctx.allocator, gdb, project_path) catch {
        try writer.writeAll("{\"error\":\"Failed to detect changes.\"}");
        return;
    };
    defer diff.deinit();

    const stats = incremental.applyChangesWithOverlayPooled(ctx.allocator, gdb, project_path, index_dir, &diff, ctx.parser_pool) catch |err| {
        try writer.print("{{\"error\":\"applyChangesWithOverlay failed: {s}\"}}", .{@errorName(err)});
        return;
    };

    // Rebuild ANN index after embeddings may have changed.
    semantic_mod.buildAndSaveAnn(gdb, index_dir, ctx.allocator) catch |err| {
        std.log.warn("ANN build skipped: {s}", .{@errorName(err)});
    };

    try writer.print(
        \\{{"added":{},"modified":{},"deleted":{},"symbols_added":{},"edges_added":{},"errors":{},"overlay_docs":{},"overlay_tombstoned":{},"duration_ms":{}}}
    , .{
        stats.added,
        stats.modified,
        stats.deleted,
        stats.symbols_added,
        stats.edges_added,
        stats.errors,
        stats.overlay_docs,
        stats.overlay_tombstoned,
        stats.duration_ms,
    });
}

// ██████████████████████████████████████████████████████████████████████████
// index_status (internal only — MCP tool removed in v0.6.0; use health_check)
// ██████████████████████████████████████████████████████████████████████████

fn handleIndexStatus(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    _ = params_obj;

    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const doc_count = gdb.queryScalar("SELECT COUNT(*) FROM documents") catch 0;
    const sym_count = gdb.queryScalar("SELECT COUNT(*) FROM symbols") catch 0;
    const edge_count = gdb.queryScalar("SELECT COUNT(*) FROM edges") catch 0;
    const last_indexed: i64 = gdb.queryScalar("SELECT COALESCE(MAX(indexed_at), 0) FROM documents") catch 0;

    var lang_stmt = gdb.prepare(
        "SELECT language, COUNT(*) as cnt FROM documents GROUP BY language ORDER BY cnt DESC",
    ) catch {
        try writer.print(
            \\{{"documents":{},"symbols":{},"edges":{},"last_indexed":{},"languages":{{}}}}
        , .{ doc_count, sym_count, edge_count, last_indexed });
        return;
    };
    defer lang_stmt.finalize();

    try writer.print(
        \\{{"documents":{},"symbols":{},"edges":{},"last_indexed":{},"languages":{{}}
    , .{ doc_count, sym_count, edge_count, last_indexed });

    var first_lang = true;
    while (true) {
        const has_row = lang_stmt.step() catch false;
        if (!has_row) break;
        const lang = lang_stmt.columnText(0) catch continue;
        const cnt = lang_stmt.columnInt(1) catch continue;
        if (!first_lang) try writer.writeByte(',');
        first_lang = false;
        try writer.print("{f}:{}", .{ std.json.fmt(lang, .{}), cnt });
    }
    try writer.writeAll("}}");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: health_check
// ██████████████████████████████████████████████████████████████████████████

fn handleHealthCheck(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    _ = params_obj;

    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const doc_count = gdb.queryScalar("SELECT COUNT(*) FROM documents") catch 0;
    const sym_count = gdb.queryScalar("SELECT COUNT(*) FROM symbols") catch 0;
    const edge_count = gdb.queryScalar("SELECT COUNT(*) FROM edges") catch 0;
    const emb_count = gdb.queryScalar("SELECT COUNT(*) FROM document_embeddings") catch 0;
    const community_count = gdb.queryScalar("SELECT COUNT(DISTINCT community_id) FROM symbols WHERE community_id IS NOT NULL") catch 0;
    const last_indexed: i64 = gdb.queryScalar("SELECT COALESCE(MAX(indexed_at), 0) FROM documents") catch 0;

    const status: []const u8 = if (doc_count > 0) "healthy" else "needs_indexing";

    try writer.print(
        \\{{"status":{f},"counts":{{"documents":{},"symbols":{},"edges":{},"embeddings":{},"communities":{}}},"last_indexed":{},"uptime_seconds":0}}
    , .{
        std.json.fmt(status, .{}),
        doc_count,
        sym_count,
        edge_count,
        emb_count,
        community_count,
        last_indexed,
    });
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: delete_project
// ██████████████████████████████████████████████████████████████████████████

fn handleDeleteProject(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.path\"}");
        return;
    };
    const repo_path = getString(params, "path") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: path\"}");
        return;
    };

    // Resolve project root
    const project_root = std.fs.realpathAlloc(ctx.allocator, repo_path) catch {
        try writer.writeAll("{\"error\":\"Invalid repository path.\"}");
        return;
    };
    defer ctx.allocator.free(project_root);

    // Calculate project ID (same algorithm as project_store)
    const base = std.fs.path.basename(project_root);
    const hash = std.hash.Wyhash.hash(0x7a696e64656b73, project_root);
    const safe_base: []const u8 = blk: {
        if (base.len == 0) break :blk try ctx.allocator.dupe(u8, "p");
        var sb = std.ArrayList(u8).initCapacity(ctx.allocator, base.len) catch @panic("OOM");
        for (base) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') {
                sb.append(ctx.allocator, c) catch {};
            } else {
                sb.append(ctx.allocator, '-') catch {};
            }
        }
        break :blk try sb.toOwnedSlice(ctx.allocator);
    };
    defer ctx.allocator.free(safe_base);
    const project_id = try std.fmt.allocPrint(ctx.allocator, "{s}-{x:0>16}", .{ safe_base, hash });
    defer ctx.allocator.free(project_id);

    const store_root = try project_store.defaultStoreRoot(ctx.allocator, ctx.store_root);
    defer ctx.allocator.free(store_root);

    const project_dir = try std.fs.path.join(ctx.allocator, &.{ store_root, "projects", project_id });
    defer ctx.allocator.free(project_dir);

    // Delete the project directory tree
    std.fs.deleteTreeAbsolute(project_dir) catch |err| {
        if (err == error.FileNotFound) {
            try writer.writeAll("{\"message\":\"Project was not indexed. Nothing to delete.\"}");
            return;
        }
        try writer.writeAll("{\"error\":\"Failed to delete project data.\"}");
        return;
    };

    try writer.print(
        \\{{"message":{f}}}
    , .{std.json.fmt("Project deleted successfully.", .{})});
}
// ██████████████████████████████████████████████████████████████████████████

// ██████████████████████████████████████████████████████████████████████████
// Tool: trace_call_path
// ██████████████████████████████████████████████████████████████████████████

fn handleTraceCallPath(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };
    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.name\"}");
        return;
    };
    const name = getString(params, "name") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: name\"}");
        return;
    };

    const direction_str = getString(params, "direction") orelse "both";
    const dir: call_graph.Direction = if (std.mem.eql(u8, direction_str, "inbound"))
        .inbound
    else if (std.mem.eql(u8, direction_str, "outbound"))
        .outbound
    else
        .both;

    const max_depth: u32 = blk: {
        if (params.get("max_depth")) |v| switch (v) {
            .integer => |i| if (i > 0) break :blk @intCast(@min(i, 10)),
            else => {},
        };
        break :blk 5;
    };

    const include_confidence = blk: {
        if (params.get("include_confidence")) |v| switch (v) {
            .bool => |b| break :blk b,
            else => {},
        };
        break :blk false;
    };

    var result = call_graph.trace(ctx.allocator, gdb, name, dir, max_depth) catch {
        try writer.writeAll("{\"error\":\"Trace failed. Symbol may not exist or no edges found.\"}");
        return;
    };
    defer result.deinit(ctx.allocator);

    try writer.print(
        \\{{"has_cycle":{},"nodes":[
    , .{result.has_cycle});

    for (result.nodes, 0..) |node, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"name":{f},"kind":{f},"file_path":{f},"depth":{}}}
        , .{
            std.json.fmt(node.name, .{}),
            std.json.fmt(node.kind, .{}),
            std.json.fmt(node.file_path, .{}),
            node.depth,
        });
    }

    try writer.writeAll("],\"edges\":[");

    for (result.edges, 0..) |edge, i| {
        if (i > 0) try writer.writeByte(',');
        if (include_confidence) {
            try writer.print(
                \\{{"source":{f},"target":{f},"type":{f},"confidence":{}}}
            , .{
                std.json.fmt(edge.source_name, .{}),
                std.json.fmt(edge.target_name, .{}),
                std.json.fmt(edge.edge_type, .{}),
                edge.confidence,
            });
        } else {
            try writer.print(
                \\{{"source":{f},"target":{f},"type":{f}}}
            , .{
                std.json.fmt(edge.source_name, .{}),
                std.json.fmt(edge.target_name, .{}),
                std.json.fmt(edge.edge_type, .{}),
            });
        }
    }

    try writer.writeAll("]}");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: get_architecture
// ██████████████████████████████████████████████████████████████████████████

fn handleGetArchitecture(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const limit: u32 = blk: {
        if (params_obj) |p| {
            if (p.get("limit")) |v| switch (v) {
                .integer => |i| if (i > 0) break :blk @intCast(@min(i, 50)),
                else => {},
            };
        }
        break :blk 10;
    };

    var arch = arch_mod.getArchitecture(ctx.allocator, gdb) catch {
        try writer.writeAll("{\"error\":\"Architecture analysis failed.\"}");
        return;
    };
    defer arch.deinit(ctx.allocator);

    const hotspots = arch_mod.getHotSpots(ctx.allocator, gdb, limit) catch {
        try writer.writeAll("{\"error\":\"Hotspot analysis failed.\"}");
        return;
    };
    defer ctx.allocator.free(hotspots);
    defer for (hotspots) |*h| h.deinit(ctx.allocator);

    const coupling = arch_mod.getModuleCoupling(gdb) catch {
        try writer.writeAll("{\"error\":\"Coupling analysis failed.\"}");
        return;
    };

    try writer.print(
        \\{{"total_files":{},"total_symbols":{},"total_edges":{},"modules":[
    , .{ arch.total_files, arch.total_symbols, arch.total_edges });

    for (arch.modules, 0..) |m, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"module":{f},"file_count":{},"symbol_count":{}}}
        , .{ std.json.fmt(m.module, .{}), m.file_count, m.symbol_count });
    }

    try writer.writeAll("],\"entry_points\":[");

    for (arch.entry_points, 0..) |e, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"name":{f},"kind":{f},"file":{f}}}
        , .{ std.json.fmt(e.name, .{}), std.json.fmt(e.kind, .{}), std.json.fmt(e.file_path, .{}) });
    }

    try writer.writeAll("],\"high_fan_out\":[");

    for (arch.high_fan_out, 0..) |h, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"name":{f},"kind":{f},"file":{f},"fan_out":{}}}
        , .{ std.json.fmt(h.name, .{}), std.json.fmt(h.kind, .{}), std.json.fmt(h.file_path, .{}), h.fan_out });
    }

    try writer.writeAll("],\"high_fan_in\":[");

    for (arch.high_fan_in, 0..) |h, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"name":{f},"kind":{f},"file":{f},"fan_in":{}}}
        , .{ std.json.fmt(h.name, .{}), std.json.fmt(h.kind, .{}), std.json.fmt(h.file_path, .{}), h.fan_in });
    }

    try writer.writeAll("],\"hotspots\":[");

    for (hotspots, 0..) |h, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"name":{f},"kind":{f},"file":{f},"fan_in":{},"fan_out":{},"total":{}}}
        , .{ std.json.fmt(h.name, .{}), std.json.fmt(h.kind, .{}), std.json.fmt(h.file_path, .{}), h.fan_in, h.fan_out, h.total });
    }

    try writer.print(
        \\],"_coupling":{{"internal":{},"external":{},"ratio":{}}}
    , .{ coupling.internal_edges, coupling.external_edges, coupling.couplingRatio() });

    try writer.writeByte('}');
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: manage_adr
// ██████████████████████████████████████████████████████████████████████████

fn handleManageAdr(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.action\"}");
        return;
    };
    const action = getString(params, "action") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: action\"}");
        return;
    };

    if (std.mem.eql(u8, action, "list")) {
        var stmt = try gdb.prepare(
            "SELECT id, title, status, created_at FROM adrs ORDER BY created_at DESC",
        );
        defer stmt.finalize();

        try writer.writeByte('[');
        var first = true;
        while (try stmt.step()) {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print(
                \\{{"id":{},"title":{f},"status":{f},"created":{f}}}
            , .{
                try stmt.columnInt(0),
                std.json.fmt(try stmt.columnText(1), .{}),
                std.json.fmt(try stmt.columnText(2), .{}),
                std.json.fmt(try stmt.columnText(3), .{}),
            });
        }
        try writer.writeByte(']');
    } else if (std.mem.eql(u8, action, "get")) {
        const title = getString(params, "title") orelse {
            try writer.writeAll("{\"error\":\"Missing param: title\"}");
            return;
        };

        var stmt = try gdb.prepare(
            "SELECT title, context, decision, status, created_at FROM adrs WHERE title = ? LIMIT 1",
        );
        defer stmt.finalize();
        try stmt.bindText(1, title);

        if (!(try stmt.step())) {
            try writer.writeAll("{\"error\":\"ADR not found\"}");
            return;
        }

        try writer.print(
            \\{{"title":{f},"context":{f},"decision":{f},"status":{f},"created_at":{f}}}
        , .{
            std.json.fmt(try stmt.columnText(0), .{}),
            std.json.fmt(try stmt.columnText(1), .{}),
            std.json.fmt(try stmt.columnText(2), .{}),
            std.json.fmt(try stmt.columnText(3), .{}),
            std.json.fmt(try stmt.columnText(4), .{}),
        });
    } else if (std.mem.eql(u8, action, "create")) {
        const title = getString(params, "title") orelse {
            try writer.writeAll("{\"error\":\"Missing required param: title\"}");
            return;
        };
        const context = getString(params, "context") orelse "";
        const decision = getString(params, "decision") orelse "";

        var stmt = try gdb.prepare(
            "INSERT INTO adrs (title, context, decision) VALUES (?, ?, ?)",
        );
        defer stmt.finalize();
        try stmt.bindText(1, title);
        try stmt.bindText(2, context);
        try stmt.bindText(3, decision);
        _ = try stmt.step();

        try writer.print(
            \\{{"created":true,"id":{},"title":{f}}}
        , .{ gdb.lastInsertRowid(), std.json.fmt(title, .{}) });
    } else {
        try writer.writeAll("{\"error\":\"Unknown action. Use list, get, or create.\"}");
    }
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: detect_communities  (routes on action: run | list | get)
// ██████████████████████████████████████████████████████████████████████████

fn handleDetectCommunities(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const action = if (params_obj) |p| getString(p, "action") orelse "run" else "run";

    if (std.mem.eql(u8, action, "list")) {
        // Delegate to the existing list-communities logic.
        try handleListCommunities(ctx, params_obj, writer);
        return;
    }

    if (std.mem.eql(u8, action, "get")) {
        // Delegate to the existing get-symbol-community logic.
        try handleGetSymbolCommunity(ctx, params_obj, writer);
        return;
    }

    // action == "run" (default): Leiden detection.
    const resolution: f64 = blk: {
        if (params_obj) |p| {
            if (p.get("resolution")) |v| switch (v) {
                .float => |f| if (f > 0.0) break :blk f,
                .integer => |i| if (i > 0) break :blk @floatFromInt(i),
                else => {},
            };
        }
        break :blk 1.0;
    };

    const result = leiden_mod.detect(ctx.allocator, gdb, resolution) catch {
        try writer.writeAll("{\"error\":\"Community detection failed.\"}");
        return;
    };

    // List top communities (up to 20)
    const top_communities = gdb.listCommunities(20, ctx.allocator) catch {
        try writer.print(
            \\{{"communities":{},"modularity":{},"top_communities":[]}}
        , .{ result.communities, result.modularity });
        return;
    };
    defer ctx.allocator.free(top_communities);

    try writer.print(
        \\{{"communities":{},"modularity":{},"top_communities":[
    , .{ result.communities, result.modularity });

    for (top_communities, 0..) |tc, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"community_id":{},"member_count":{}}}
        , .{ tc.community_id, tc.member_count });
    }

    try writer.writeAll("]}");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: list_communities (internal — called by handleDetectCommunities action=list)
// ██████████████████████████████████████████████████████████████████████████

fn handleListCommunities(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const limit: u32 = blk: {
        if (params_obj) |p| {
            if (p.get("limit")) |v| switch (v) {
                .integer => |i| if (i > 0) break :blk @intCast(@min(i, 100)),
                else => {},
            };
        }
        break :blk 20;
    };

    const communities = gdb.listCommunities(limit, ctx.allocator) catch {
        try writer.writeAll("{\"error\":\"Failed to list communities. Have you run detect_communities?\"}");
        return;
    };
    defer ctx.allocator.free(communities);

    try writer.writeAll("{\"communities\":[");

    for (communities, 0..) |c, i| {
        if (i > 0) try writer.writeByte(',');

        // Get sample members (up to 5)
        var members = gdb.getCommunityMembers(c.community_id, ctx.allocator) catch {
            try writer.print(
                \\{{"community_id":{},"member_count":{},"sample":[]}}
            , .{ c.community_id, c.member_count });
            continue;
        };
        defer {
            for (members) |*m| m.deinit(ctx.allocator);
            ctx.allocator.free(members);
        }

        try writer.print(
            \\{{"community_id":{},"member_count":{},"sample":[
        , .{ c.community_id, c.member_count });

        const sample_count = @min(@as(usize, 5), members.len);
        for (members[0..sample_count], 0..) |m, j| {
            if (j > 0) try writer.writeByte(',');
            try writer.print(
                \\{{"name":{f},"kind":{f},"file":{f}}}
            , .{ std.json.fmt(m.name, .{}), std.json.fmt(m.kind, .{}), std.json.fmt(m.file_path, .{}) });
        }

        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: get_symbol_community (internal — called by handleDetectCommunities action=get)
// ██████████████████████████████████████████████████████████████████████████

fn handleGetSymbolCommunity(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.symbol_name\"}");
        return;
    };
    const symbol_name = getString(params, "symbol_name") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: symbol_name\"}");
        return;
    };

    const community_id = gdb.getSymbolCommunity(symbol_name) catch {
        try writer.writeAll("{\"error\":\"Failed to query symbol community.\"}");
        return;
    };

    if (community_id == null) {
        try writer.print(
            \\{{"found":false,"community_id":null,"symbol_name":{f},"members":[]}}
        , .{std.json.fmt(symbol_name, .{})});
        return;
    }

    const cid = community_id.?;
    const members = gdb.getCommunityMembers(cid, ctx.allocator) catch {
        try writer.print(
            \\{{"found":true,"community_id":{},"symbol_name":{f},"members":[]}}
        , .{ cid, std.json.fmt(symbol_name, .{}) });
        return;
    };
    defer {
        for (members) |*m| m.deinit(ctx.allocator);
        ctx.allocator.free(members);
    }

    try writer.print(
        \\{{"found":true,"community_id":{},"symbol_name":{f},"members":[
    , .{ cid, std.json.fmt(symbol_name, .{}) });

    for (members, 0..) |m, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"name":{f},"kind":{f},"file":{f}}}
        , .{ std.json.fmt(m.name, .{}), std.json.fmt(m.kind, .{}), std.json.fmt(m.file_path, .{}) });
    }

    try writer.writeAll("]}");
}

// ██████████████████████████████████████████████████████████████████████████
// Helper: detect Cypher queries in query_graph
// ██████████████████████████████████████████████████████████████████████████

fn isCypherQuery(query: []const u8) bool {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len < 5) return false;
    return std.ascii.eqlIgnoreCase(trimmed[0..5], "MATCH");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: rename_symbol
// ██████████████████████████████████████████████████████████████████████████

fn handleRenameSymbol(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.old_name\"}");
        return;
    };
    const old_name = getString(params, "old_name") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: old_name\"}");
        return;
    };
    const new_name = getString(params, "new_name") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: new_name\"}");
        return;
    };

    const dry_run = blk: {
        if (params.get("dry_run")) |v| switch (v) {
            .bool => |b| break :blk b,
            else => {},
        };
        break :blk true;
    };

    // Find the symbol in the graph
    var sym_stmt = try gdb.prepare(
        \\SELECT s.id, s.name, s.kind, d.path
        \\FROM symbols s
        \\JOIN documents d ON d.id = s.document_id
        \\WHERE s.name = ?
        \\LIMIT 1
    );
    defer sym_stmt.finalize();
    try sym_stmt.bindText(1, old_name);

    const sym_id: ?i64 = blk: {
        if (!(try sym_stmt.step())) break :blk null;
        break :blk try sym_stmt.columnInt(0);
    };

    if (sym_id == null) {
        try writer.print(
            \\{{"error":"Symbol '{f}' not found"}}
        , .{std.json.fmt(old_name, .{})});
        return;
    }

    const sym_id_val = sym_id.?;
    const file_path = try sym_stmt.columnText(3);

    // Collect all unique files involved (symbol's own file + files from edges)
    var files = std.StringHashMap(void).init(ctx.allocator);
    defer files.deinit();
    try files.put(file_path, {});

    var edge_stmt = try gdb.prepare(
        \\SELECT DISTINCT d.path
        \\FROM edges e
        \\JOIN symbols s ON (s.id = e.source_symbol_id OR s.id = e.target_symbol_id)
        \\JOIN documents d ON d.id = s.document_id
        \\WHERE (e.source_symbol_id = ? OR e.target_symbol_id = ?)
    );
    defer edge_stmt.finalize();
    try edge_stmt.bindInt(1, sym_id_val);
    try edge_stmt.bindInt(2, sym_id_val);

    while (try edge_stmt.step()) {
        const p = try edge_stmt.columnText(0);
        if (!files.contains(p)) {
            try files.put(ctx.allocator.dupe(u8, p) catch continue, {});
        }
    }

    if (dry_run) {
        var it = files.keyIterator();
        try writer.writeAll("{\"dry_run\":true,\"files\":[");
        var first = true;
        while (it.next()) |file_ptr| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{f}", .{std.json.fmt(file_ptr.*, .{})});
        }
        try writer.writeAll("],\"changes\":0}");
        return;
    }

    // Perform actual file renames using the project path
    const project_path = ctx.project_path orelse {
        try writer.writeAll("{\"error\":\"No project path set\"}");
        return;
    };

    var changes: u32 = 0;
    var it = files.keyIterator();
    while (it.next()) |file_ptr| {
        const rel_path = file_ptr.*;
        const full_path = try std.fs.path.join(ctx.allocator, &.{ project_path, rel_path });
        defer ctx.allocator.free(full_path);

        const file = std.fs.openFileAbsolute(full_path, .{ .mode = .read_write }) catch continue;
        defer file.close();

        const original = file.readToEndAlloc(ctx.allocator, 10 * 1024 * 1024) catch continue;
        defer ctx.allocator.free(original);

        // Simple word-boundary replacement: replace all occurrences
        // In production, this should use the AST to be precise
        const replaced = try replaceWord(ctx.allocator, original, old_name, new_name);
        defer ctx.allocator.free(replaced);

        if (!std.mem.eql(u8, original, replaced)) {
            try file.seekTo(0);
            try file.writeAll(replaced);
            try file.setEndPos(replaced.len);
            changes += 1;
        }
    }

    // Update symbol name in graph DB
    var update_stmt = try gdb.prepare("UPDATE symbols SET name = ? WHERE id = ?");
    defer update_stmt.finalize();
    try update_stmt.bindText(1, new_name);
    try update_stmt.bindInt(2, sym_id_val);
    _ = try update_stmt.step();

    try writer.print(
        \\{{"files_scanned":{},"files_changed":{},"symbol_renamed":true}}
    , .{ files.count(), changes});
}

/// Replace all occurrences of `old_word` with `new_word` in text, respecting
/// word boundaries (identifier characters only adjacent).
fn replaceWord(allocator: std.mem.Allocator, haystack: []const u8, old_word: []const u8, new_word: []const u8) ![]const u8 {
    if (old_word.len == 0) return try allocator.dupe(u8, haystack);

    // Estimate capacity (worst case: all replacements make text bigger)
    var result = std.ArrayList(u8).initCapacity(allocator, haystack.len + new_word.len * 4) catch @panic("OOM");

    var pos: usize = 0;
    while (pos < haystack.len) {
        if (std.mem.indexOfPos(u8, haystack, pos, old_word)) |match_pos| {
            // Check word boundaries
            const before_ok = match_pos == 0 or !std.ascii.isAlphanumeric(haystack[match_pos - 1]) or haystack[match_pos - 1] == '_';
            const after_pos = match_pos + old_word.len;
            const after_ok = after_pos >= haystack.len or !std.ascii.isAlphanumeric(haystack[after_pos]) or haystack[after_pos] == '_';

            if (before_ok and after_ok) {
                try result.appendSlice(allocator, haystack[pos..match_pos]);
                try result.appendSlice(allocator, new_word);
                pos = after_pos;
                continue;
            }
        }
        try result.append(allocator, haystack[pos]);
        pos += 1;
    }

    return try result.toOwnedSlice(allocator);
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: ingest_traces
// ██████████████████████████████████████████████████████████████████████████

fn handleIngestTraces(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.data\"}");
        return;
    };
    const data = getString(params, "data") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: data\"}");
        return;
    };
    const format = getString(params, "format") orelse "json";
    const source = getString(params, "source") orelse "runtime";

    var stmt = try gdb.prepare(
        "INSERT INTO traces (trace_data, format, source) VALUES (?, ?, ?)",
    );
    defer stmt.finalize();
    try stmt.bindText(1, data);
    try stmt.bindText(2, format);
    try stmt.bindText(3, source);
    _ = try stmt.step();

    const id = gdb.lastInsertRowid();
    try writer.print(
        \\{{"ingested":true,"trace_id":{},"format":"{s}","source":"{s}"}}
    , .{ id, format, source });
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: semantic_search (internal — called by handleSearch mode=semantic)
// ██████████████████████████████████████████████████████████████████████████

fn handleSemanticSearch(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.query\"}");
        return;
    };
    const query = getString(params, "query") orelse "";
    const limit = getLimit(params, 10);

    if (query.len == 0) {
        try writer.writeAll("{\"error\":\"Empty query\"}");
        return;
    }

    var results = blk: {
        if (ctx.engine) |e| if (e.ann) |a| {
            break :blk semantic_mod.searchAnn(gdb, a, query, limit, ctx.allocator) catch {
                try writer.writeAll("{\"error\":\"Semantic search failed. Ensure embeddings have been generated.\"}");
                return;
            };
        };
        break :blk semantic_mod.search(gdb, query, limit, ctx.allocator) catch {
            try writer.writeAll("{\"error\":\"Semantic search failed. Ensure embeddings have been generated.\"}");
            return;
        };
    };
    defer results.deinit(ctx.allocator);

    try writer.writeByte('[');
    for (results.items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"document_path":{f},"score":{f},"doc_id":{}}}
        , .{
            std.json.fmt(item.document_path, .{}),
            std.json.fmt(item.score, .{}),
            item.doc_id,
        });
    }
    try writer.writeByte(']');
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: hybrid_search (internal — called by handleSearch mode=hybrid/default)
// ██████████████████████████████████████████████████████████████████████████

fn handleHybridSearch(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const engine = ctx.engine orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No graph database loaded. Run index_repository first.\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.query\"}");
        return;
    };
    const query = getString(params, "query") orelse "";
    const limit = getLimit(params, 10);

    if (query.len == 0) {
        try writer.writeAll("{\"error\":\"Empty query\"}");
        return;
    }

    var results = engine.hybridSearch(gdb, ctx.allocator, query, limit) catch {
        try writer.writeAll("{\"error\":\"Hybrid search failed.\"}");
        return;
    };
    defer results.deinit(ctx.allocator);

    try writer.writeByte('[');
    for (results.items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"doc_id":{},"path":{f},"bm25_score":{f},"semantic_score":{f},"fused_score":{f},"snippet":{f}}}
        , .{
            item.doc_id,
            std.json.fmt(item.path, .{}),
            std.json.fmt(item.bm25_score, .{}),
            std.json.fmt(item.semantic_score, .{}),
            std.json.fmt(item.fused_score, .{}),
            std.json.fmt(item.snippet, .{}),
        });
    }
    try writer.writeByte(']');
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: get_context
// ██████████████████████████████████████████████████████████████████████████

fn handleGetContext(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const engine = ctx.engine orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No graph database loaded. Run index_repository first.\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.query\"}");
        return;
    };
    const query = getString(params, "query") orelse "";
    if (query.len == 0) {
        try writer.writeAll("{\"error\":\"Empty query\"}");
        return;
    }

    const max_tokens: usize = blk: {
        if (params.get("max_tokens")) |v| switch (v) {
            .integer => |i| if (i > 0) break :blk @intCast(@min(i, 32000)),
            else => {},
        };
        break :blk 4000;
    };

    const include_call_graph = blk: {
        if (params.get("include_call_graph")) |v| switch (v) {
            .bool => |b| break :blk b,
            else => {},
        };
        break :blk true;
    };

    const include_arch = blk: {
        if (params.get("include_architecture")) |v| switch (v) {
            .bool => |b| break :blk b,
            else => {},
        };
        break :blk false;
    };

    var builder = ai_context.ContextBuilder.init(ctx.allocator);
    defer builder.deinit();

    // Run BM25 search
    var results = engine.search(ctx.allocator, query, 10) catch {
        try writer.writeAll("{\"error\":\"Search failed.\"}");
        return;
    };
    defer results.deinit(ctx.allocator);

    try builder.addSearchResults(query, results.items);

    // Optionally add architecture overview
    if (include_arch) {
        if (arch_mod.getArchitecture(ctx.allocator, gdb)) |arch| {
            var mutable_arch = arch;
            defer mutable_arch.deinit(ctx.allocator);
            try builder.addArchitectureOverview(mutable_arch);
        } else |_| {
            // Silently skip if architecture query fails
        }
    }

    // Optionally add call graph context for top result symbols
    if (include_call_graph) {
        for (results.items[0..@min(results.items.len, 3)]) |result| {
            // Extract symbol names from snippet or path
            _ = result;
            // Skips per-symbol trace to keep response fast.
            // Individual call graph queries should use trace_call_path.
        }
    }

    const assembled = try builder.build(max_tokens);
    defer ctx.allocator.free(assembled);

    const token_est = ai_window.estimateTokens(assembled);

    try writer.print(
        \\{{"context":{f},"token_estimate":{},"max_tokens":{}}}
    , .{
        std.json.fmt(assembled, .{}),
        token_est,
        max_tokens,
    });
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: summarize_symbol
// ██████████████████████████████████████████████████████████████████████████

fn handleSummarizeSymbol(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first (call list_projects to see already-indexed repos).\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.symbol_name\"}");
        return;
    };
    const symbol_name = getString(params, "symbol_name") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: symbol_name\"}");
        return;
    };
    const language = getString(params, "language") orelse "unknown";

    // Look up the symbol in the graph DB to get its code snippet
    var stmt = try gdb.prepare(
        \\SELECT s.name, s.kind, d.path, d.content
        \\FROM symbols s
        \\JOIN documents d ON d.id = s.document_id
        \\WHERE s.name = ?
        \\LIMIT 1
    );
    defer stmt.finalize();
    try stmt.bindText(1, symbol_name);

    if (!(try stmt.step())) {
        try writer.print(
            \\{{"error":"Symbol '{s}' not found."}}
        , .{symbol_name});
        return;
    }

    const name = try stmt.columnText(1); // skip s.name
    _ = name;
    _ = try stmt.columnText(2);
    const path = try stmt.columnText(3);
    const content = try stmt.columnText(4);
    _ = path;

    const summary = ai_summarize.summarizeSymbol(ctx.allocator, content, language) catch {
        try writer.writeAll("{\"error\":\"Failed to summarise symbol.\"}");
        return;
    };
    defer summary.deinit(ctx.allocator);

    // Serialise key_operations and dependencies as JSON arrays
    var ops_json = std.ArrayList(u8){};
    defer ops_json.deinit(ctx.allocator);
    try ops_json.append(ctx.allocator, '[');
    for (summary.key_operations, 0..) |op, i| {
        if (i > 0) try ops_json.append(ctx.allocator, ',');
        try ops_json.writer(ctx.allocator).print("{f}", .{std.json.fmt(op, .{})});
    }
    try ops_json.append(ctx.allocator, ']');

    var deps_json = std.ArrayList(u8){};
    defer deps_json.deinit(ctx.allocator);
    try deps_json.append(ctx.allocator, '[');
    for (summary.dependencies, 0..) |dep, i| {
        if (i > 0) try deps_json.append(ctx.allocator, ',');
        try deps_json.writer(ctx.allocator).print("{f}", .{std.json.fmt(dep, .{})});
    }
    try deps_json.append(ctx.allocator, ']');

    try writer.print(
        \\{{"name":{f},"kind":{f},"purpose":{f},"complexity":{f},"signature":{f},"key_operations":{s},"dependencies":{s}}}
    , .{
        std.json.fmt(summary.name, .{}),
        std.json.fmt(summary.kind, .{}),
        std.json.fmt(summary.purpose, .{}),
        std.json.fmt(summary.complexity_score, .{}),
        std.json.fmt(summary.signature, .{}),
        ops_json.items,
        deps_json.items,
    });
}

// ██████████████████████████████████████████████████████████████████████████
// explain_query (internal only — MCP tool removed in v0.6.0; module kept)
// ██████████████████████████████████████████████████████████████████████████

fn handleExplainQuery(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    _ = ctx.gdb; // no gdb needed for query parsing
    _ = ctx.engine;

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing params.query\"}");
        return;
    };
    const query = getString(params, "query") orelse "";
    if (query.len == 0) {
        try writer.writeAll("{\"error\":\"Empty query\"}");
        return;
    }

    const parsed = ai_query.parseQuery(ctx.allocator, query) catch {
        try writer.writeAll("{\"error\":\"Failed to parse query.\"}");
        return;
    };
    defer parsed.deinit(ctx.allocator);

    const intent_str = @tagName(parsed.intent);

    // Serialise target_symbols as JSON array
    var syms_json = std.ArrayList(u8){};
    defer syms_json.deinit(ctx.allocator);
    try syms_json.append(ctx.allocator, '[');
    for (parsed.target_symbols, 0..) |sym, i| {
        if (i > 0) try syms_json.append(ctx.allocator, ',');
        try syms_json.writer(ctx.allocator).print("{f}", .{std.json.fmt(sym, .{})});
    }
    try syms_json.append(ctx.allocator, ']');

    // Serialise constraints as JSON array
    var cons_json = std.ArrayList(u8){};
    defer cons_json.deinit(ctx.allocator);
    try cons_json.append(ctx.allocator, '[');
    for (parsed.constraints, 0..) |c, i| {
        if (i > 0) try cons_json.append(ctx.allocator, ',');
        try cons_json.writer(ctx.allocator).print(
            \\{{"kind":"{s}","value":{f}}}
        , .{ @tagName(c.kind), std.json.fmt(c.value, .{}) });
    }
    try cons_json.append(ctx.allocator, ']');

    // Suggested tools
    const tools = ai_query.suggestedTools(ctx.allocator, parsed.intent) catch {
        try writer.writeAll("{\"error\":\"Failed to get suggested tools.\"}");
        return;
    };
    defer {
        for (tools) |t| ctx.allocator.free(t);
        ctx.allocator.free(tools);
    }

    var tools_json = std.ArrayList(u8){};
    defer tools_json.deinit(ctx.allocator);
    try tools_json.append(ctx.allocator, '[');
    for (tools, 0..) |t, i| {
        if (i > 0) try tools_json.append(ctx.allocator, ',');
        try tools_json.writer(ctx.allocator).print("{f}", .{std.json.fmt(t, .{})});
    }
    try tools_json.append(ctx.allocator, ']');

    try writer.print(
        \\{{"intent":"{s}","target_symbols":{s},"constraints":{s},"suggested_tools":{s}}}
    , .{
        intent_str,
        syms_json.items,
        cons_json.items,
        tools_json.items,
    });
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: config  (unified get+set — no params = get, any param = set+return)
// ██████████████████████████████████████████████████████████████████████████

fn handleConfig(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    // Determine config path
    const config_path = config_mod.getDefaultPath(ctx.allocator) catch {
        try writer.writeAll("{\"error\":\"Cannot determine config path\"}");
        return;
    };
    defer ctx.allocator.free(config_path);

    // Check whether any settable param was provided.
    const has_updates: bool = if (params_obj) |p|
        p.get("store_root") != null or
        p.get("default_repo") != null or
        p.get("embedding_model") != null or
        p.get("colors_enabled") != null or
        p.get("max_results") != null
    else
        false;

    // Load existing config (or defaults)
    var cfg = config_mod.Config.load(ctx.allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => config_mod.Config{},
        else => {
            try writer.writeAll("{\"error\":\"Failed to load config\"}");
            return;
        },
    };
    defer cfg.deinit(ctx.allocator);

    if (has_updates) {
        // Apply provided updates using handleGetConfig internals via set path.
        const params = params_obj.?;
        if (getString(params, "store_root")) |v| {
            if (cfg.store_root) |old| ctx.allocator.free(old);
            cfg.store_root = try ctx.allocator.dupe(u8, v);
        }
        if (getString(params, "default_repo")) |v| {
            if (cfg.default_repo.len > 0) ctx.allocator.free(cfg.default_repo);
            cfg.default_repo = try ctx.allocator.dupe(u8, v);
        }
        if (getString(params, "embedding_model")) |v| {
            if (cfg.embedding_model.len > 0) ctx.allocator.free(cfg.embedding_model);
            cfg.embedding_model = try ctx.allocator.dupe(u8, v);
        }
        if (getString(params, "colors_enabled")) |v| {
            cfg.colors_enabled = std.mem.eql(u8, v, "true");
        }
        if (getString(params, "max_results")) |v| {
            cfg.max_results = std.fmt.parseUnsigned(u32, v, 10) catch cfg.max_results;
        }
        // Persist
        cfg.save(config_path) catch {
            try writer.writeAll("{\"error\":\"Failed to save config\"}");
            return;
        };
    }

    // Return current (possibly updated) config.
    const store_root_str = cfg.store_root orelse "null";
    const index_dir_str = cfg.index_dir orelse "null";

    try writer.print(
        \\{{"store_root":"{s}","index_dir":"{s}","default_repo":"{s}","colors_enabled":{},"max_results":{},"embedding_model":"{s}","config_path":"{s}"}}
    , .{
        store_root_str,
        index_dir_str,
        cfg.default_repo,
        cfg.colors_enabled,
        cfg.max_results,
        cfg.embedding_model,
        config_path,
    });
}

// handleGetConfig and handleSetConfig kept as thin aliases for any internal callers.
fn handleGetConfig(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    try handleConfig(ctx, params_obj, writer);
}

fn handleSetConfig(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    try handleConfig(ctx, params_obj, writer);
}

fn getString(params: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = params.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn getBool(params: std.json.ObjectMap, key: []const u8) ?bool {
    const value = params.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn getLimit(params: std.json.ObjectMap, default: usize) usize {
    const value = params.get("limit") orelse return default;
    return switch (value) {
        .integer => |i| if (i > 0) @intCast(@min(i, 100)) else default,
        else => default,
    };
}

fn symbolKindStr(kind: storage.SymbolKind) []const u8 {
    return @tagName(kind);
}

// ██████████████████████████████████████████████████████████████████████████
// Phase 7 helpers: read_file / list_files / file_outline
// ██████████████████████████████████████████████████████████████████████████

/// Stats returned by renderNumbered.
pub const RenderStats = struct {
    total_lines: usize,
    shown_start: usize, // 1-based
    shown_end: usize,   // 1-based, inclusive
    truncated: bool,
};

/// Max bytes emitted per line before truncation, mirroring Claude's native Read
/// tool. Guards against minified/bundled files where a single line can be
/// megabytes long and would otherwise blow up the response.
const MAX_LINE_BYTES = 2000;

/// Largest length <= `limit` that does not split a UTF-8 multi-byte sequence,
/// so the truncated slice stays valid UTF-8 for JSON encoding. Backs off over
/// any trailing continuation bytes (0b10xxxxxx) and the lead byte they follow.
fn utf8SafeCut(bytes: []const u8, limit: usize) usize {
    if (limit >= bytes.len) return bytes.len;
    var cut = limit;
    while (cut > 0 and (bytes[cut] & 0xC0) == 0x80) cut -= 1;
    return cut;
}

/// Emit a pending run of blank lines and reset the counter.  A run of >=2 is
/// collapsed into a single `⋮` marker; a lone blank line is emitted as an
/// empty numbered row.  No-op when the counter is zero.
fn flushBlankRun(out_w: anytype, start_line: usize, count: *usize) !void {
    if (count.* == 0) return;
    if (count.* >= 2) {
        try out_w.print("{d}\t⋮ ({d} blank lines)\n", .{ start_line, count.* });
    } else {
        try out_w.print("{d}\t\n", .{start_line});
    }
    count.* = 0;
}

/// Render file content as compressed cat-n output into `out`.
///
/// Format mirrors Claude's native Read tool: a 1-based line number, a single
/// TAB delimiter, then the byte-exact line.  TAB (one byte) is used instead of
/// a multi-byte arrow so the delimiter is cheap and matches the convention the
/// model already expects.  Runs of >=2 consecutive blank lines collapse into a
/// single marker.
///
/// `offset`: 1-based first line (clamped to >=1).  `limit`: max lines shown.
///
/// Streaming, single-pass: only the requested window is rendered and no
/// per-line slice table is retained, so auxiliary memory is O(1) in the file's
/// line count rather than O(N).  A one-element lookahead drops the trailing
/// empty element that `splitScalar` produces for files ending in '\n' (and for
/// the empty file), keeping `total_lines` aligned with the human-visible count.
pub fn renderNumbered(
    allocator: std.mem.Allocator,
    content: []const u8,
    offset_in: usize,
    limit_in: usize,
    out: *std.ArrayList(u8),
) !RenderStats {
    const offset = if (offset_in < 1) 1 else offset_in;
    const limit = if (limit_in < 1) 1 else limit_in;

    const win_start = offset - 1; // 0-based, inclusive
    const win_end = win_start +| limit; // 0-based, exclusive (saturating)

    const out_w = out.writer(allocator);

    // Pending blank-run state — only ever accumulated inside the window.
    var blank_start: usize = 0; // 1-based line number where the run began
    var blank_count: usize = 0;

    var total: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    var pending = iter.next();
    while (pending) |raw| {
        const next = iter.next();
        const is_last = next == null;

        // Strip a trailing \r for \r\n line endings.
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r')
            raw[0 .. raw.len - 1]
        else
            raw;

        // Drop the trailing empty element splitScalar yields for a file ending
        // in '\n' (and the lone element of the empty file).
        if (is_last and line.len == 0) break;

        const idx = total; // 0-based index of the current line
        total += 1;

        if (idx >= win_start and idx < win_end) {
            const is_blank = std.mem.trim(u8, line, " \t\r").len == 0;
            if (is_blank) {
                if (blank_count == 0) blank_start = idx + 1;
                blank_count += 1;
            } else {
                try flushBlankRun(out_w, blank_start, &blank_count);
                if (line.len > MAX_LINE_BYTES) {
                    const cut = utf8SafeCut(line, MAX_LINE_BYTES);
                    try out_w.print("{d}\t{s}… (+{d} chars)\n", .{ idx + 1, line[0..cut], line.len - cut });
                } else {
                    try out_w.print("{d}\t{s}\n", .{ idx + 1, line });
                }
            }
        } else if (idx >= win_end and blank_count > 0) {
            // First line past the window — flush any run that ended at the
            // window boundary, then keep counting for total_lines only.
            try flushBlankRun(out_w, blank_start, &blank_count);
        }

        pending = next;
    }
    // Flush a run that reached the end of the window or EOF.
    try flushBlankRun(out_w, blank_start, &blank_count);

    const ws = if (offset > total) total else offset - 1;
    const we = @min(total, ws + limit);

    return RenderStats{
        .total_lines = total,
        .shown_start = if (total == 0) 0 else ws + 1,
        .shown_end = we,
        .truncated = we < total,
    };
}

/// Simple glob matcher: supports `*` (matches within path component) and
/// `**` (matches across separators). Pattern and candidate are compared
/// after normalising separators to forward-slash.
pub fn globMatch(pattern: []const u8, candidate: []const u8) bool {
    return globMatchInner(pattern, candidate);
}

fn globMatchInner(pat: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    // Saved positions for backtracking on `*`
    var star_pi: usize = std.math.maxInt(usize);
    var star_si: usize = 0;

    while (si < str.len) {
        if (pi < pat.len and (pat[pi] == '?' or pat[pi] == str[si])) {
            pi += 1;
            si += 1;
        } else if (pi < pat.len and pat[pi] == '*') {
            // Check for `**` — treat same as `*` for our purposes
            var end = pi + 1;
            while (end < pat.len and pat[end] == '*') end += 1;
            star_pi = end;
            star_si = si;
            pi = end;
        } else if (star_pi != std.math.maxInt(usize)) {
            // Backtrack: advance the string position for the `*`
            star_si += 1;
            si = star_si;
            pi = star_pi;
        } else {
            return false;
        }
    }
    // Consume trailing `*`s
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

/// Normalise path separators to forward-slash.
fn normSep(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: read_file
// ██████████████████████████████████████████████████████████████████████████

fn handleReadFile(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const project_path = ctx.project_path orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first.\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing required param: path\"}");
        return;
    };
    const path = getString(params, "path") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: path\"}");
        return;
    };

    const offset: usize = blk: {
        if (params.get("offset")) |v| switch (v) {
            .integer => |i| if (i >= 1) break :blk @intCast(i),
            else => {},
        };
        break :blk 1;
    };
    const limit: usize = blk: {
        if (params.get("limit")) |v| switch (v) {
            .integer => |i| if (i > 0) break :blk @intCast(i),
            else => {},
        };
        break :blk 2000;
    };

    // Resolve absolute path
    const abs_path = if (std.fs.path.isAbsolute(path))
        try ctx.allocator.dupe(u8, path)
    else
        try std.fs.path.join(ctx.allocator, &.{ project_path, path });
    defer ctx.allocator.free(abs_path);

    // Read from disk
    const content = std.fs.cwd().readFileAlloc(ctx.allocator, abs_path, 10 * 1024 * 1024) catch {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(ctx.allocator);
        const bw = buf.writer(ctx.allocator);
        try bw.print("{{\"error\":\"Cannot read file: {f} (not on disk; if it was moved/deleted, re-run index_repository)\"}}", .{std.json.fmt(path, .{})});
        try writer.writeAll(buf.items);
        return;
    };
    defer ctx.allocator.free(content);

    // Render compressed cat-n output
    var rendered = std.ArrayList(u8){};
    defer rendered.deinit(ctx.allocator);
    const stats = try renderNumbered(ctx.allocator, content, offset, limit, &rendered);

    const shown_str = try std.fmt.allocPrint(ctx.allocator, "{d}-{d}", .{ stats.shown_start, stats.shown_end });
    defer ctx.allocator.free(shown_str);

    try writer.print(
        \\{{"path":{f},"total_lines":{d},"shown":{f},"truncated":{},"source":"disk","content":{f}}}
    , .{
        std.json.fmt(path, .{}),
        stats.total_lines,
        std.json.fmt(shown_str, .{}),
        stats.truncated,
        std.json.fmt(rendered.items, .{}),
    });
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: list_files
// ██████████████████████████████████████████████████████████████████████████

fn handleListFiles(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first.\"}");
        return;
    };

    const pattern_raw: ?[]const u8 = if (params_obj) |p| getString(p, "pattern") else null;
    const dir_raw: ?[]const u8 = if (params_obj) |p| getString(p, "dir") else null;
    const limit: usize = blk: {
        if (params_obj) |p| {
            if (p.get("limit")) |v| switch (v) {
                .integer => |i| if (i > 0) break :blk @as(usize, @intCast(i)),
                else => {},
            };
        }
        break :blk 200;
    };

    // Normalise user-supplied pattern and dir to forward-slash
    const pattern: ?[]u8 = if (pattern_raw) |pr| try normSep(ctx.allocator, pr) else null;
    defer if (pattern) |p| ctx.allocator.free(p);
    const dir: ?[]u8 = if (dir_raw) |dr| try normSep(ctx.allocator, dr) else null;
    defer if (dir) |d| ctx.allocator.free(d);

    var stmt = try gdb.prepare("SELECT path FROM documents ORDER BY path");
    defer stmt.finalize();

    var matched: usize = 0;
    var shown: usize = 0;

    var files = std.ArrayList([]const u8){};
    defer {
        for (files.items) |f| ctx.allocator.free(f);
        files.deinit(ctx.allocator);
    }

    while (try stmt.step()) {
        const raw_path = try stmt.columnText(0);

        // Normalise stored path to forward-slash for matching
        const norm = try normSep(ctx.allocator, raw_path);
        defer ctx.allocator.free(norm);

        // Dir prefix filter
        if (dir) |d| {
            if (!std.mem.startsWith(u8, norm, d)) continue;
        }

        // Pattern filter
        if (pattern) |pat| {
            const keep = blk: {
                // *.ext -> suffix match
                if (pat.len > 2 and pat[0] == '*' and pat[1] == '.') {
                    const ext = pat[1..]; // includes the dot
                    break :blk std.mem.endsWith(u8, norm, ext);
                }
                // contains glob wildcard -> globMatch
                if (std.mem.indexOfScalar(u8, pat, '*') != null) {
                    break :blk globMatch(pat, norm);
                }
                // plain substring
                break :blk std.mem.indexOf(u8, norm, pat) != null;
            };
            if (!keep) continue;
        }

        matched += 1;
        if (shown < limit) {
            try files.append(ctx.allocator, try ctx.allocator.dupe(u8, norm));
            shown += 1;
        }
    }

    try writer.print("{{\"count\":{d},\"total_matched\":{d},\"truncated\":{},\"files\":[", .{
        shown,
        matched,
        shown < matched,
    });
    for (files.items, 0..) |f, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{f}", .{std.json.fmt(f, .{})});
    }
    try writer.writeAll("]}");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: file_outline
// ██████████████████████████████████████████████████████████████████████████

fn handleFileOutline(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository with an absolute repo path first.\"}");
        return;
    };

    const params = params_obj orelse {
        try writer.writeAll("{\"error\":\"Missing required param: path\"}");
        return;
    };
    const path_in = getString(params, "path") orelse {
        try writer.writeAll("{\"error\":\"Missing required param: path\"}");
        return;
    };

    // Normalise: if absolute and starts with project_path, strip prefix.
    // Convert to OS-native separators for DB lookup.
    const project_path = ctx.project_path orelse "";

    const rel_path: []u8 = blk: {
        if (std.fs.path.isAbsolute(path_in) and project_path.len > 0) {
            // Try to strip project_path prefix
            var pp = project_path;
            // Ensure no trailing separator in project_path for comparison
            if (pp.len > 0 and (pp[pp.len - 1] == '/' or pp[pp.len - 1] == '\\'))
                pp = pp[0 .. pp.len - 1];

            if (std.ascii.startsWithIgnoreCase(path_in, pp)) {
                const rest = path_in[pp.len..];
                const trimmed = if (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\'))
                    rest[1..]
                else
                    rest;
                break :blk try ctx.allocator.dupe(u8, trimmed);
            }
        }
        break :blk try ctx.allocator.dupe(u8, path_in);
    };
    defer ctx.allocator.free(rel_path);

    // Convert separators to OS native for the initial query
    const os_path = try ctx.allocator.dupe(u8, rel_path);
    defer ctx.allocator.free(os_path);
    if (std.fs.path.sep == '\\') {
        for (os_path) |*c| if (c.* == '/') { c.* = '\\'; };
    } else {
        for (os_path) |*c| if (c.* == '\\') { c.* = '/'; };
    }

    const query =
        \\SELECT s.name, s.kind, s.line_start, s.line_end
        \\FROM symbols s JOIN documents d ON d.id = s.document_id
        \\WHERE d.path = ? ORDER BY s.line_start
    ;

    const SymbolEntry = struct {
        name: []u8,
        kind: []u8,
        line_start: i64,
        line_end: i64,
    };
    var symbols = std.ArrayList(SymbolEntry){};
    defer {
        for (symbols.items) |*s| {
            ctx.allocator.free(s.name);
            ctx.allocator.free(s.kind);
        }
        symbols.deinit(ctx.allocator);
    }

    // Helper: run query with a given path string, append results
    const runQuery = struct {
        fn run(
            alloc: std.mem.Allocator,
            db: *graph_db.GraphDb,
            q: []const u8,
            bind_path: []const u8,
            out: *std.ArrayList(SymbolEntry),
        ) !bool {
            const q_z = try alloc.dupeZ(u8, q);
            defer alloc.free(q_z);
            var st = try db.prepare(q_z);
            defer st.finalize();
            try st.bindText(1, bind_path);
            var found = false;
            while (try st.step()) {
                found = true;
                try out.append(alloc, .{
                    .name = try alloc.dupe(u8, try st.columnText(0)),
                    .kind = try alloc.dupe(u8, try st.columnText(1)),
                    .line_start = try st.columnInt(2),
                    .line_end = try st.columnInt(3),
                });
            }
            return found;
        }
    }.run;

    const found1 = try runQuery(ctx.allocator, gdb, query, os_path, &symbols);

    if (!found1) {
        // Retry with swapped separators
        const alt_path = try ctx.allocator.dupe(u8, os_path);
        defer ctx.allocator.free(alt_path);
        if (std.fs.path.sep == '\\') {
            for (alt_path) |*c| if (c.* == '\\') { c.* = '/'; };
        } else {
            for (alt_path) |*c| if (c.* == '/') { c.* = '\\'; };
        }
        const found2 = try runQuery(ctx.allocator, gdb, query, alt_path, &symbols);

        if (!found2) {
            // Suffix / LIKE match using basename
            const basename = std.fs.path.basename(path_in);
            const like_pat = try std.fmt.allocPrint(ctx.allocator, "%{s}", .{basename});
            defer ctx.allocator.free(like_pat);
            const like_query =
                \\SELECT s.name, s.kind, s.line_start, s.line_end
                \\FROM symbols s JOIN documents d ON d.id = s.document_id
                \\WHERE d.path LIKE ? ORDER BY s.line_start
            ;
            _ = try runQuery(ctx.allocator, gdb, like_query, like_pat, &symbols);
        }
    }

    try writer.print("{{\"path\":{f},\"count\":{d},\"symbols\":[", .{
        std.json.fmt(path_in, .{}),
        symbols.items.len,
    });
    for (symbols.items, 0..) |s, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            \\{{"name":{f},"kind":{f},"line":{d},"end":{d}}}
        , .{
            std.json.fmt(s.name, .{}),
            std.json.fmt(s.kind, .{}),
            s.line_start,
            s.line_end,
        });
    }
    if (symbols.items.len == 0) {
        try writer.writeAll("],\"note\":\"no indexed symbols for this path (check path or re-index)\"}");
    } else {
        try writer.writeAll("]}");
    }
}

// ██████████████████████████████████████████████████████████████████████████
// Phase 7 tests (pure helpers — no MCP round-trip needed)
// ██████████████████████████████████████████████████████████████████████████

test "renderNumbered: blank-run compression" {
    const alloc = std.testing.allocator;

    const input =
        \\line1
        \\line2
        \\
        \\
        \\
        \\line6
        \\line7
    ;

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    const stats = try renderNumbered(alloc, input, 1, 2000, &out);

    // total_lines: 7 (line1..line7; trailing newline stripped)
    try std.testing.expectEqual(@as(usize, 7), stats.total_lines);
    try std.testing.expect(!stats.truncated);

    const rendered = out.items;
    // Must contain the 3-blank-line marker
    try std.testing.expect(std.mem.indexOf(u8, rendered, "⋮ (3 blank lines)") != null);
    // Non-blank lines must keep exact content, tab-delimited.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1\tline1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "6\tline6") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "7\tline7") != null);
    // The 3 blank lines (3,4,5) collapse into one marker — no lone blank rows.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "3\t\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "4\t\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "5\t\n") == null);
    // The marker is anchored at the first blank line of the run.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "3\t⋮ (3 blank lines)") != null);
}

test "renderNumbered: offset and limit paging" {
    const alloc = std.testing.allocator;
    const input = "a\nb\nc\nd\ne";
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    const stats = try renderNumbered(alloc, input, 2, 2, &out);
    try std.testing.expectEqual(@as(usize, 5), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 2), stats.shown_start);
    try std.testing.expectEqual(@as(usize, 4), stats.shown_end);
    try std.testing.expect(stats.truncated);
    // Window = lines 2-3 (tab-delimited); lines outside must not appear.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "2\tb") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "3\tc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "1\ta") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "4\td") == null);
}

test "renderNumbered: trailing newline does not add a phantom line" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    // "a\nb\n" is two lines, not three.
    const stats = try renderNumbered(allocator, "a\nb\n", 1, 100, &out);
    try std.testing.expectEqual(@as(usize, 2), stats.total_lines);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "2\tb") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "3\t") == null);

    // No trailing newline: still two lines.
    out.clearRetainingCapacity();
    const stats2 = try renderNumbered(allocator, "a\nb", 1, 100, &out);
    try std.testing.expectEqual(@as(usize, 2), stats2.total_lines);
}

test "renderNumbered: empty file yields zero lines" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    const stats = try renderNumbered(allocator, "", 1, 100, &out);
    try std.testing.expectEqual(@as(usize, 0), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 0), stats.shown_start);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(stats.truncated == false);
}

test "renderNumbered: a single newline is one blank line" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    const stats = try renderNumbered(allocator, "\n", 1, 100, &out);
    try std.testing.expectEqual(@as(usize, 1), stats.total_lines);
    // One blank line is emitted as "1\t\n" (not collapsed — needs >=2).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "1\t\n") != null);
}

test "renderNumbered: offset past EOF renders nothing" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    const stats = try renderNumbered(allocator, "a\nb\nc\n", 99, 10, &out);
    try std.testing.expectEqual(@as(usize, 3), stats.total_lines);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(stats.truncated == false);
}

test "renderNumbered: blank run at window end is flushed" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    // Lines: x(1) blank(2) blank(3) y(4).  Window = lines 1-3, so the run of
    // two blanks ends exactly at the window boundary and must still flush.
    const stats = try renderNumbered(allocator, "x\n\n\ny\n", 1, 3, &out);
    try std.testing.expectEqual(@as(usize, 4), stats.total_lines);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "2\t⋮ (2 blank lines)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "4\ty") == null);
    try std.testing.expect(stats.truncated == true);
}

test "renderNumbered: over-long line is truncated at MAX_LINE_BYTES" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    // One line of 2050 'a's — 50 bytes over the cap.
    const long = "a" ** (MAX_LINE_BYTES + 50);
    const stats = try renderNumbered(allocator, long, 1, 100, &out);
    try std.testing.expectEqual(@as(usize, 1), stats.total_lines);
    // Exactly MAX_LINE_BYTES content bytes emitted, then the overflow marker.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "… (+50 chars)") != null);
    // Body must not contain all 2050 'a's: the rendered slice is the prefix only.
    const expected_prefix = "1\t" ++ ("a" ** MAX_LINE_BYTES) ++ "…";
    try std.testing.expect(std.mem.indexOf(u8, out.items, expected_prefix) != null);
}

test "renderNumbered: truncation backs off to a UTF-8 boundary" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    // (MAX_LINE_BYTES - 1) ASCII bytes, then a 3-byte char (€ = E2 82 AC) that
    // straddles the cap. The cut must back off to before €, not split it.
    const line = ("a" ** (MAX_LINE_BYTES - 1)) ++ "€" ++ "tail";
    const stats = try renderNumbered(allocator, line, 1, 100, &out);
    try std.testing.expectEqual(@as(usize, 1), stats.total_lines);
    // Output remains valid UTF-8 (no split multi-byte sequence).
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.items));
    // The € (3 bytes) plus "tail" (4 bytes) = 7 dropped bytes.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "… (+7 chars)") != null);
}

test "globMatch: basic patterns" {
    try std.testing.expect(globMatch("*.zig", "src/main.zig"));
    try std.testing.expect(!globMatch("*.zig", "a.py"));
    try std.testing.expect(globMatch("src/**/*.zig", "src/api/mcp/tools.zig"));
    try std.testing.expect(globMatch("*.py", "a.py"));
    try std.testing.expect(!globMatch("*.py", "a.zig"));
    try std.testing.expect(globMatch("tools*", "tools.zig"));
    try std.testing.expect(globMatch("*tools*", "src/tools/main.zig"));
}
