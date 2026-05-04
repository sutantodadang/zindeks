pub const storage = @import("core/storage/index.zig");
pub const scanner = @import("core/scanner/scanner.zig");
pub const indexer = @import("core/indexer/indexer.zig");
pub const project_store = @import("core/project_store.zig");
pub const search = @import("core/search/engine.zig");

pub const parser = struct {
    pub const symbols = @import("parser/symbols.zig");
};

pub const api = struct {
    pub const mcp = @import("api/mcp/server.zig");
    pub const cli = @import("api/cli/cli.zig");
};
