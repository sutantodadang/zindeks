pub const storage = struct {
    pub const index = @import("core/storage/index.zig");
    pub const graph_db = @import("core/storage/graph_db.zig");
};

pub const scanner = struct {
    pub const scanner = @import("core/scanner/scanner.zig");
    pub const gitignore = @import("core/scanner/gitignore.zig");
};
pub const indexer = struct {
    pub const indexer = @import("core/indexer/indexer.zig");
    pub const incremental = @import("core/indexer/incremental.zig");
};
pub const project_store = @import("core/project_store.zig");
pub const project = struct {
    pub const watcher = @import("project/watcher.zig");
};
pub const graph = struct {
    pub const call_graph = @import("core/graph/call_graph.zig");
    pub const leiden = @import("core/graph/leiden.zig");
    pub const cypher = struct {
        pub const lexer = @import("core/graph/cypher/lexer.zig");
        pub const parser = @import("core/graph/cypher/parser.zig");
        pub const executor = @import("core/graph/cypher/executor.zig");
    };
};
pub const analysis = struct {
    pub const arch = @import("core/analysis/arch.zig");
};
pub const search = struct {
    pub const engine = @import("core/search/engine.zig");
    pub const tokenizer = @import("core/search/tokenizer.zig");
    pub const embeddings = @import("core/search/embeddings.zig");
    pub const semantic = @import("core/search/semantic.zig");
};

pub const parser = struct {
    pub const tree_sitter = @import("core/parser/tree_sitter.zig");
    pub const extractor = @import("core/parser/extractor.zig");
    pub const zig_extractor = @import("core/parser/zig_extractor.zig");
    pub const pipeline = @import("core/parser/pipeline.zig");
    pub const http_routes = @import("core/parser/http_routes.zig");
};

pub const api = struct {
    pub const mcp = struct {
        pub const server = @import("api/mcp/server.zig");
        pub const protocol = @import("api/mcp/protocol.zig");
        pub const tools = @import("api/mcp/tools.zig");
    };
    pub const cli = @import("api/cli/cli.zig");
};
