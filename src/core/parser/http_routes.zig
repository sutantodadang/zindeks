//! HTTP route detection — extracts API endpoint definitions from source code.
//!
//! Scans for common web framework route patterns during the indexing pipeline.
//! Recognizes: Express (app.get/post/put/delete), FastAPI (@app.route),
//! Go (mux.HandleFunc), Rust (actix-web #[get]), Flask (@app.route).
//!
//! Results are stored as edges in the graph (file -> HTTP_CALLS -> route).

const std = @import("std");
const extractor_mod = @import("extractor.zig");

const ExtractedEdge = extractor_mod.ExtractedEdge;
const EdgeKind = extractor_mod.EdgeKind;

/// Known HTTP framework route patterns.
const RoutePattern = struct {
    regex: []const u8,
    description: []const u8,
};

const PATTERNS = [_]RoutePattern{
    // Express-style: app.get('/path', handler)
    .{ .regex = "app\\.(get|post|put|delete|patch|use)\\s*\\(\\s*['\"]([^'\"]+)['\"]",
      .description = "Express-style route" },
    // Router-style: router.get('/path', handler)
    .{ .regex = "router\\.(get|post|put|delete|patch)\\s*\\(\\s*['\"]([^'\"]+)['\"]",
      .description = "Express Router route" },
    // FastAPI/Flask decorator: @app.route('/path', methods=['GET'])
    .{ .regex = "@app\\.route\\s*\\(\\s*['\"]([^'\"]+)['\"]",
      .description = "FastAPI/Flask route decorator" },
    // FastAPI decorator: @app.get('/path')
    .{ .regex = "@(app|router)\\.(get|post|put|delete|patch)\\s*\\(\\s*['\"]([^'\"]+)['\"]",
      .description = "FastAPI method decorator" },
    // Go net/http: mux.HandleFunc("/path", handler)
    .{ .regex = "\\.(HandleFunc|Handle)\\s*\\(\\s*['\"]([^'\"]+)['\"]",
      .description = "Go HTTP handler" },
    // Rust actix-web: #[get("/path")]
    .{ .regex = "#\\[(get|post|put|delete|patch|head|route)\\s*\\(\\s*['\"]([^'\"]+)['\"]",
      .description = "Rust actix-web route attribute" },
    // PHP Laravel: Route::get('/path', [Controller::class, 'method'])
    .{ .regex = "Route::(get|post|put|delete|patch|any)\\s*\\(\\s*['\"]([^'\"]+)['\"]",
      .description = "Laravel route" },
};

/// Scan source code for HTTP route definitions and return edges.
pub fn extractRoutes(allocator: std.mem.Allocator, source: []const u8, file_path: []const u8) ![]ExtractedEdge {
    var edges = std.ArrayList(ExtractedEdge).initCapacity(allocator, 16) catch @panic("OOM");

    for (PATTERNS) |pattern| {
        var pos: usize = 0;
        while (pos < source.len) {
            // Find method/route pattern
            const method_start = if (std.mem.indexOfPos(u8, source, pos, pattern.regex[0..2])) |idx| idx else break;

            // Scan for quote after method name
            const quote_start = std.mem.indexOfScalarPos(u8, source, method_start + 2, '\'') orelse
                std.mem.indexOfScalarPos(u8, source, method_start + 2, '"') orelse break;
            if (quote_start >= source.len) break;

            const quote_char = source[quote_start];
            const quote_end = std.mem.indexOfScalarPos(u8, source, quote_start + 1, quote_char) orelse break;

            const route_path = source[quote_start + 1 .. quote_end];

            if (route_path.len > 0 and route_path.len < 256) {
                try edges.append(allocator, .{
                    .source_name = try allocator.dupe(u8, file_path),
                    .source_kind = .module,
                    .target_name = try allocator.dupe(u8, route_path),
                    .target_kind = .module,
                    .edge_type = .http_calls,
                    .confidence = 0.8,
                });
            }

            pos = quote_end + 1;
        }
    }

    return try edges.toOwnedSlice(allocator);
}
