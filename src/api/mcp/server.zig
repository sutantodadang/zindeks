//! MCP-compliant JSON-RPC server over stdio.
//!
//! Handles the initialize handshake, tools/list, tools/call dispatch,
//! and ping.  Maintains optional project state (binary index + graph DB).

const std = @import("std");
const protocol = @import("protocol.zig");
const tools = @import("tools.zig");
const storage = @import("../../core/storage/index.zig");
const search = @import("../../core/search/engine.zig");
const graph_db = @import("../../core/storage/graph_db.zig");
const pool = @import("../../core/storage/pool.zig");
const project_store = @import("../../core/project_store.zig");

const ServerInfo = struct {
    name: []const u8 = "zindeks",
    version: []const u8 = "0.1.1",
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    transport: protocol.Transport,
    info: ServerInfo,
    initialized: bool,
    project_path: ?[]const u8,
    idx: ?storage.Index,
    engine: ?search.Engine,
    gdb: ?graph_db.GraphDb,
    connection_pool: ?*pool.ConnectionPool,
    response_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, info: ServerInfo) Server {
        return .{
            .allocator = allocator,
            .transport = protocol.Transport.init(allocator),
            .info = info,
            .initialized = false,
            .project_path = null,
            .idx = null,
            .engine = null,
            .gdb = null,
            .connection_pool = null,
            .response_buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch @panic("OOM"),
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.connection_pool) |cp| cp.deinit();
        if (self.gdb) |*gdb| gdb.close();
        if (self.idx) |*idx| idx.close();
        if (self.project_path) |p| self.allocator.free(p);
        self.response_buf.deinit(self.allocator);
        self.transport.deinit();
    }

    /// Set a connection pool for this server. The pool must outlive the server.
    /// When set, handlers can acquire pooled connections for parallel queries.
    pub fn setConnectionPool(self: *Server, cp: *pool.ConnectionPool) void {
        self.connection_pool = cp;
    }

    /// Run the server event loop.  Blocks until stdin closes.
    pub fn serve(self: *Server) !void {
        while (try self.transport.readMessage()) |raw| {
            defer self.allocator.free(raw);
            try self.handleMessage(raw);
        }
    }

    fn handleMessage(self: *Server, raw: []const u8) !void {
        var req = (try protocol.parseRequest(self.allocator, raw)) orelse {
            // Not a valid JSON-RPC request — send parse error if id present
            try self.respondErrorMaybe(raw, .parse_error);
            return;
        };
        defer req.deinit();

        const is_notification = protocol.isNotification(req);

        if (self.initialized) {
            // Main loop: handle tools/list, tools/call, ping
            try self.handleInitialized(req, is_notification);
        } else {
            // Pre-initialize: only allow initialize
            try self.handlePreInit(req, is_notification);
        }
    }

    // ██████████████████████████████████████████████████████████████████████
    // Pre-initialize: only accept "initialize"
    // ██████████████████████████████████████████████████████████████████████

    fn handlePreInit(self: *Server, req: protocol.ParsedRequest, is_notification: bool) !void {
        if (is_notification) return;

        if (std.mem.eql(u8, req.method, "initialize")) {
            try self.handleInitialize(req);
        } else {
            try self.respondError(req.id, .invalid_request);
        }
    }

    fn handleInitialize(self: *Server, req: protocol.ParsedRequest) !void {
        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);
        try protocol.writeInitializeResult(writer, req.id, self.info.name, self.info.version);
        try self.transport.writeMessage(self.response_buf.items);
        self.initialized = true;
    }

    // ██████████████████████████████████████████████████████████████████████
    // Post-initialize: tools/list, tools/call, ping, notifications
    // ██████████████████████████████████████████████████████████████████████

    fn handleInitialized(self: *Server, req: protocol.ParsedRequest, is_notification: bool) !void {
        if (std.mem.eql(u8, req.method, "notifications/initialized")) return;

        if (is_notification) return;

        if (std.mem.eql(u8, req.method, "tools/list")) {
            try self.handleToolsList(req);
        } else if (std.mem.eql(u8, req.method, "tools/call")) {
            try self.handleToolsCall(req);
        } else if (std.mem.eql(u8, req.method, "ping")) {
            try self.handlePing(req);
        } else {
            try self.respondError(req.id, .method_not_found);
        }
    }

    fn handleToolsList(self: *Server, req: protocol.ParsedRequest) !void {
        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);

        // Write tools JSON into a temp buffer
        var tools_buf = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch @panic("OOM");
        defer tools_buf.deinit(self.allocator);
        try tools.writeToolsListJson(tools_buf.writer(self.allocator));

        try protocol.writeToolsList(writer, req.id, tools_buf.items);
        try self.transport.writeMessage(self.response_buf.items);
    }

    fn handleToolsCall(self: *Server, req: protocol.ParsedRequest) !void {
        const params = req.params orelse {
            try self.respondError(req.id, .invalid_params);
            return;
        };

        const tool_name_val = params.get("name") orelse {
            try self.respondError(req.id, .invalid_params);
            return;
        };
        const tool_name = switch (tool_name_val) {
            .string => |s| s,
            else => {
                try self.respondError(req.id, .invalid_params);
                return;
            },
        };

        const args_val = params.get("arguments");
        const args = if (args_val) |a| switch (a) {
            .object => |o| o,
            else => null,
        } else null;

        // Write tool result
        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);
        try protocol.writeToolResultBegin(writer, req.id);

        // Build tool context
        var ctx = tools.Context{
            .allocator = self.allocator,
            .engine = if (self.engine != null) &self.engine.? else null,
            .gdb = if (self.gdb != null) &self.gdb.? else null,
            .project_path = self.project_path,
        };
        try tools.dispatch(&ctx, tool_name, args, writer);

        try protocol.writeToolResultEnd(writer);
        try self.transport.writeMessage(self.response_buf.items);

        // After index_repository, load the project
        if (std.mem.eql(u8, tool_name, "index_repository")) {
            try self.loadProject(args);
        }
    }

    fn handlePing(self: *Server, req: protocol.ParsedRequest) !void {
        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);
        try protocol.writePingResult(writer, req.id);
        try self.transport.writeMessage(self.response_buf.items);
    }

    // ██████████████████████████████████████████████████████████████████████
    // Project loading / error responders
    // ██████████████████████████████████████████████████████████████████████

    fn loadProject(self: *Server, args: ?std.json.ObjectMap) !void {
        const path_val = if (args) |a| a.get("path") else null;
        const path = if (path_val) |v| switch (v) {
            .string => |s| s,
            else => return,
        } else return;

        // Resolve project store read location
        var loc = project_store.resolveRead(self.allocator, path, .{}) catch {
            return;
        };
        defer loc.deinit();

        // Close any previously loaded project
        if (self.gdb) |*gdb| gdb.close();
        if (self.idx) |*idx| idx.close();
        if (self.project_path) |p| self.allocator.free(p);

        self.gdb = null;
        self.idx = null;
        self.engine = null;
        self.project_path = null;

        // Open binary index
        var idx = storage.Index.open(self.allocator, std.fs.cwd(), loc.index_dir) catch return;
        errdefer idx.close();

        // Open graph DB
        const graph_path = std.fs.path.join(self.allocator, &.{ loc.index_dir, "graph.db" }) catch return;
        errdefer self.allocator.free(graph_path);

        const gpz = self.allocator.dupeZ(u8, graph_path) catch {
            self.allocator.free(graph_path);
            return;
        };
        defer self.allocator.free(graph_path);

        var gdb = graph_db.GraphDb.open(gpz) catch {
            self.allocator.free(gpz);
            idx.close();
            return;
        };

        const projected_path = self.allocator.dupe(u8, path) catch {
            gdb.close();
            idx.close();
            self.allocator.free(gpz);
            return;
        };

        self.idx = idx;
        self.gdb = gdb;
        self.project_path = projected_path;
        // Re-borrow after move
        self.engine = search.Engine.init(&self.idx.?);
    }

    fn respondError(self: *Server, id: ?std.json.Value, code: protocol.ErrorCode) !void {
        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);
        try protocol.writeErrorNoData(writer, id, code);
        try self.transport.writeMessage(self.response_buf.items);
    }

    fn respondErrorMaybe(self: *Server, raw: []const u8, code: protocol.ErrorCode) !void {
        const id: ?std.json.Value = if (std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{})) |parsed| blk: {
            defer parsed.deinit();
            break :blk parsed.value.object.get("id");
        } else |_| null;
        try self.respondError(id, code);
    }
};
