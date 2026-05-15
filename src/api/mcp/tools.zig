//! MCP tool definitions and handlers.
//!
//! Phase 1 tools: index_repository, list_projects, search_code, get_graph_schema.
//! Phase 2 tools: search_graph, get_code_snippet, query_graph.
//! Phase 3 tools: detect_changes, index_status, delete_project.
//! Phase 4 tools: trace_call_path, get_architecture, manage_adr.
//! Phase 5 tools: detect_communities, rename_symbol, ingest_traces.
//! Phase 6 tools: semantic_search, hybrid_search.

const std = @import("std");
const protocol = @import("protocol.zig");
const indexer = @import("../../core/indexer/indexer.zig");
const incremental = @import("../../core/indexer/incremental.zig");
const scanner = @import("../../core/scanner/scanner.zig");
const storage = @import("../../core/storage/index.zig");
const search = @import("../../core/search/engine.zig");
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

/// MCP tool descriptor — matches the tools/list response format.
pub const Descriptor = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: []const u8, // JSON literal
};

/// All tools registered for Phase 1-6.
pub const ALL = [_]Descriptor{
    index_repository,
    list_projects,
    search_code,
    get_graph_schema,
    search_graph,
    get_code_snippet,
    query_graph,
    detect_changes,
    index_status,
    delete_project,
    trace_call_path,
    get_architecture,
    manage_adr,
    rename_symbol,
    ingest_traces,
    detect_communities,
    list_communities,
    get_symbol_community,
    semantic_search,
    hybrid_search,
};

pub const index_repository = Descriptor{
    .name = "index_repository",
    .description = "Index a repository into the knowledge graph. Supports Zig source files with AST-level symbol and import extraction.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Absolute path to the repository root directory"
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

pub const search_code = Descriptor{
    .name = "search_code",
    .description = "Search indexed source files using BM25 keyword ranking. Returns matching files with relevance scores and snippets.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "query": {
    \\      "type": "string",
    \\      "description": "Search query string"
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum number of results (default 10, max 100)"
    \\    }
    \\  },
    \\  "required": ["query"]
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
    .description = "Run a read-only SQL query against the knowledge graph database. Tables: documents, symbols, edges. Only SELECT queries are allowed.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "query": {
    \\      "type": "string",
    \\      "description": "SQL SELECT query against documents, symbols, or edges tables"
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

pub const index_status = Descriptor{
    .name = "index_status",
    .description = "Return current indexing statistics: document count, symbol count, edge count, last indexed timestamp.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {}
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
    .description = "Run Leiden community detection on the symbol graph. Assigns community_id to each symbol. Returns community count, modularity score, and top communities with member counts.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "resolution": {
    \\      "type": "number",
    \\      "description": "Resolution parameter for community granularity (default 1.0, higher = more communities)"
    \\    }
    \\  }
    \\}
    ,
};

pub const list_communities = Descriptor{
    .name = "list_communities",
    .description = "List all detected communities with member counts and sample member symbols. Requires detect_communities to have been run first.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum number of communities to return (default 20)"
    \\    }
    \\  }
    \\}
    ,
};

pub const get_symbol_community = Descriptor{
    .name = "get_symbol_community",
    .description = "Return the community ID and member symbols for a given symbol. Requires detect_communities to have been run first.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "symbol_name": {
    \\      "type": "string",
    \\      "description": "Exact symbol name to look up"
    \\    }
    \\  },
    \\  "required": ["symbol_name"]
    \\}
    ,
};

pub const semantic_search = Descriptor{
    .name = "semantic_search",
    .description = "Search indexed code by semantic similarity using document embeddings. Returns ranked results with cosine similarity scores.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "query": {
    \\      "type": "string",
    \\      "description": "Natural language query describing what to search for"
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum number of results (default 10, max 100)"
    \\    }
    \\  },
    \\  "required": ["query"]
    \\}
    ,
};

pub const hybrid_search = Descriptor{
    .name = "hybrid_search",
    .description = "Combined BM25 keyword and semantic search using Reciprocal Rank Fusion. Returns fused results with per-source scores.",
    .inputSchema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "query": {
    \\      "type": "string",
    \\      "description": "Search query string"
    \\    },
    \\    "limit": {
    \\      "type": "integer",
    \\      "description": "Maximum number of results (default 10, max 100)"
    \\    }
    \\  },
    \\  "required": ["query"]
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
        try writer.writeAll(tool.inputSchema);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

// ██████████████████████████████████████████████████████████████████████████
// Shared context passed to every tool handler
// ██████████████████████████████████████████████████████████████████████████

pub const Context = struct {
    allocator: std.mem.Allocator,
    engine: ?*search.Engine = null,
    gdb: ?*graph_db.GraphDb = null,
    project_path: ?[]const u8 = null,
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
    } else if (std.mem.eql(u8, tool_name, "search_code")) {
        try handleSearchCode(ctx, params_obj, writer);
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
    } else if (std.mem.eql(u8, tool_name, "index_status")) {
        try handleIndexStatus(ctx, params_obj, writer);
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
    } else if (std.mem.eql(u8, tool_name, "list_communities")) {
        try handleListCommunities(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "get_symbol_community")) {
        try handleGetSymbolCommunity(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "semantic_search")) {
        try handleSemanticSearch(ctx, params_obj, writer);
    } else if (std.mem.eql(u8, tool_name, "hybrid_search")) {
        try handleHybridSearch(ctx, params_obj, writer);
    } else {
        try writer.writeAll("{\"message\":\"Unknown tool: ");
        try protocol.writeJsonString(writer, tool_name);
        try writer.writeAll("\"}");
    }
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

    // Prepare project store write location
    var loc = try project_store.prepareWrite(ctx.allocator, repo_path, .{});
    defer loc.deinit();

    // Run binary indexer (for BM25 search)
    try indexer.indexPath(ctx.allocator, repo_path, loc.index_dir);
    loc.committed = true; // prevent cleanup on deinit

    // Open graph DB and run pipeline (for structural knowledge graph)
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

    // Run the multi-pass pipeline to extract symbols + edges via tree-sitter
    var pipe = pipeline_mod.Pipeline.init(ctx.allocator, gdb, project_dir);
    const pipe_result = pipe.run() catch blk: {
        break :blk pipeline_mod.PipelineResult{
            .files_scanned = 0,
            .symbols_extracted = 0,
            .edges_extracted = 0,
            .files_with_errors = 0,
            .files_skipped = 0,
            .duration_ms = 0,
        };
    };

    gdb.close();

    try writer.print(
        \\{{"project":"{s}","files_indexed":{},"symbols":{},"edges":{},"pipeline_ms":{}}}
    , .{ project_dir, pipe_result.files_scanned, pipe_result.symbols_extracted, pipe_result.edges_extracted, pipe_result.duration_ms });
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: list_projects
// ██████████████████████████████████████████████████████████████████████████

fn handleListProjects(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    _ = params_obj;

    const store_root = try project_store.defaultStoreRoot(ctx.allocator, null);
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
// Tool: search_code
// ██████████████████████████████████████████████████████████████████████████

fn handleSearchCode(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const engine = ctx.engine orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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

    var results = try engine.search(ctx.allocator, query, limit);
    defer results.deinit(ctx.allocator);

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

// ██████████████████████████████████████████████████████████████████████████
// Tool: get_graph_schema
// ██████████████████████████████████████████████████████████████████████████

fn handleGetGraphSchema(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    _ = params_obj;

    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
            \\{{"name":{any},"row_count":{}}}
        , .{ std.json.fmt(table_name, .{}), count });
    }
    try writer.writeAll("]}");
}

// ██████████████████████████████████████████████████████████████████████████
// Tool: search_graph
// ██████████████████████████████████████████████████████████████████████████

fn handleSearchGraph(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
        return;
    };

    const project_path = ctx.project_path orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
// Tool: index_status
// ██████████████████████████████████████████████████████████████████████████

fn handleIndexStatus(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    _ = params_obj;

    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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

    const store_root = try project_store.defaultStoreRoot(ctx.allocator, null);
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
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
    defer for (hotspots) |*h| h.deinit(ctx.allocator);
    defer ctx.allocator.free(hotspots);

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
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
// Tool: detect_communities
// ██████████████████████████████████████████████████████████████████████████

fn handleDetectCommunities(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
        return;
    };

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
// Tool: list_communities
// ██████████████████████████████████████████████████████████████████████████

fn handleListCommunities(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
// Tool: get_symbol_community
// ██████████████████████████████████████████████████████████████████████████

fn handleGetSymbolCommunity(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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
// Tool: semantic_search
// ██████████████████████████████████████████████████████████████████████████

fn handleSemanticSearch(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const gdb = ctx.gdb orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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

    var results = semantic_mod.search(gdb, query, limit, ctx.allocator) catch {
        try writer.writeAll("{\"error\":\"Semantic search failed. Ensure embeddings have been generated.\"}");
        return;
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
// Tool: hybrid_search
// ██████████████████████████████████████████████████████████████████████████

fn handleHybridSearch(ctx: *Context, params_obj: ?std.json.ObjectMap, writer: anytype) !void {
    const engine = ctx.engine orelse {
        try writer.writeAll("{\"error\":\"No project loaded. Run index_repository first.\"}");
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

fn getString(params: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = params.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
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
