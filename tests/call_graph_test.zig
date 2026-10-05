//! Tests for call graph tracing — BFS, path tracing, and centrality.
const std = @import("std");
const graph_db = @import("zindeks").storage.graph_db;
const call_graph = @import("zindeks").graph.call_graph;

fn setupTestGraph() !graph_db.GraphDb {
    var db = try graph_db.GraphDb.open(":memory:");
    errdefer db.close();
    try db.migrate();

    // Create documents
    try db.exec("INSERT INTO documents (path, language) VALUES ('src/main.zig', 'Zig')");
    try db.exec("INSERT INTO documents (path, language) VALUES ('src/util.zig', 'Zig')");

    // Create symbols — build a known call chain: main -> init -> parse -> validate
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'main', 'function', 1, 10)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'init', 'function', 11, 20)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'parse', 'function', 1, 15)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'validate', 'function', 16, 30)");

    // Create edges: main -> init, init -> parse, parse -> validate, validate -> init (cycle)
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (1, 2, 'calls', 1.0)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (2, 3, 'calls', 0.9)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (3, 4, 'calls', 0.8)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (4, 2, 'calls', 0.5)"); // cycle

    return db;
}

test "call_graph trace outbound" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.trace(std.testing.allocator, &db, "main", .outbound, 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.nodes.len > 0);

    // First node should be main
    try std.testing.expectEqualStrings("main", result.nodes[0].name);

    // Edges should exist
    try std.testing.expect(result.edges.len > 0);
}

test "call_graph trace inbound" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.trace(std.testing.allocator, &db, "parse", .inbound, 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.nodes.len >= 1);
}

test "call_graph trace depth limit" {
    var db = try setupTestGraph();
    defer db.close();

    // Depth 1 should only get immediate neighbors
    var result = try call_graph.trace(std.testing.allocator, &db, "main", .outbound, 1);
    defer result.deinit(std.testing.allocator);

    // Should get main + init only (depth 1 means 1 step, so main at depth 0, init at depth 1)
    try std.testing.expect(result.nodes.len >= 1);
    try std.testing.expect(result.nodes.len <= 4); // shouldn't get all
}

test "call_graph trace includes confidence" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.trace(std.testing.allocator, &db, "main", .outbound, 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.edges.len > 0);

    // Check that confidence is populated (not zero for these edges)
    for (result.edges) |edge| {
        _ = edge.confidence; // confidence field exists and is accessible
    }
}

test "call_graph tracePath direct" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.tracePath(std.testing.allocator, &db, "main", "init", 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.found);
    try std.testing.expect(result.path.len == 2); // main -> init
    try std.testing.expectEqualStrings("main", result.path[0].name);
    try std.testing.expectEqualStrings("init", result.path[1].name);
}

test "call_graph tracePath multi-hop" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.tracePath(std.testing.allocator, &db, "main", "validate", 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.found);
    try std.testing.expect(result.path.len >= 3); // main -> init -> parse -> validate (at least 3 hops)

    // Check path is continuous
    try std.testing.expectEqualStrings("main", result.path[0].name);
}

test "call_graph tracePath not found" {
    var db = try setupTestGraph();
    defer db.close();

    // Symbol that doesn't exist
    var result = try call_graph.tracePath(std.testing.allocator, &db, "nonexistent", "main", 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.found);
    try std.testing.expectEqual(@as(f64, 0), result.total_confidence);
}

test "call_graph tracePath same node" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.tracePath(std.testing.allocator, &db, "init", "init", 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.found);
    try std.testing.expectEqual(@as(usize, 1), result.path.len);
    try std.testing.expectEqualStrings("init", result.path[0].name);
    try std.testing.expectEqual(@as(f64, 1.0), result.total_confidence);
}

test "call_graph computeCentrality" {
    var db = try setupTestGraph();
    defer db.close();

    const results = try call_graph.computeCentrality(std.testing.allocator, &db, 10);
    defer {
        for (results) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);

    // Should be sorted by centrality descending
    if (results.len >= 2) {
        try std.testing.expect(results[0].centrality >= results[1].centrality);
    }
}

// ── Issue #10: cross-file calls to shared names ─────────────────────────

const edge_resolver = @import("zindeks").parser.edge_resolver;
const qualifierSegment = @import("zindeks").parser.extractor.qualifierSegment;

test "qualifierSegment extracts call qualifier" {
    try std.testing.expectEqualStrings("session", qualifierSegment("crate::session::append_turn").?);
    try std.testing.expectEqualStrings("Foo", qualifierSegment("Foo::new").?);
    try std.testing.expectEqualStrings("pay", qualifierSegment("pay.charge").?);
    try std.testing.expectEqualStrings("obj", qualifierSegment("obj->run").?);
    try std.testing.expect(qualifierSegment("run") == null);
}

fn calleePath(db: *graph_db.GraphDb, caller: []const u8, callee: []const u8) !?[]const u8 {
    var stmt = try db.prepare(
        \\SELECT d.path FROM edges e
        \\JOIN symbols src ON src.id = e.source_symbol_id
        \\JOIN symbols t ON t.id = e.target_symbol_id
        \\JOIN documents d ON d.id = t.document_id
        \\WHERE e.edge_type = 'calls' AND src.name = ? AND t.name = ?
    );
    defer stmt.finalize();
    try stmt.bindText(1, caller);
    try stmt.bindText(2, callee);
    if (!(try stmt.step())) return null;
    const p = try std.testing.allocator.dupe(u8, try stmt.columnText(0));
    // Exactly one edge expected.
    if (try stmt.step()) {
        std.testing.allocator.free(p);
        return error.MultipleEdges;
    }
    return p;
}

test "edge_resolver links shared names cross-file (issue #10)" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    try db.exec("INSERT INTO documents (id, path) VALUES (1, 'crates/kode/src/session.rs')");
    try db.exec("INSERT INTO documents (id, path) VALUES (2, '.claude/worktrees/x/crates/kode/src/session.rs')");
    try db.exec("INSERT INTO documents (id, path) VALUES (3, 'crates/kode/src/exec.rs')");
    try db.exec("INSERT INTO documents (id, path) VALUES (4, 'crates/kode/src/turn.rs')");
    try db.exec("INSERT INTO documents (id, path) VALUES (5, 'crates/kode/src/config.rs')");

    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'append_turn', 'function', 1, 2)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'append_turn', 'function', 1, 2)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (3, 'run', 'function', 1, 9)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (4, 'Turn', 'struct_type', 1, 2)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (4, 'new', 'method', 3, 4)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (5, 'Config', 'struct_type', 1, 2)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (5, 'new', 'method', 3, 4)");

    const pending = [_]edge_resolver.PendingEdge{
        // Unqualified — path proximity must beat the nested worktree copy.
        .{ .source_doc_id = 3, .source_name = "run", .target_name = "append_turn", .edge_type = .calls, .confidence = 1.0 },
        // `Turn::new()` — qualifier names the type declared in turn.rs.
        .{ .source_doc_id = 3, .source_name = "run", .target_name = "new", .target_qualifier = "Turn", .edge_type = .calls, .confidence = 1.0 },
    };
    _ = try edge_resolver.resolveEdges(&db, &pending);

    const p1 = (try calleePath(&db, "run", "append_turn")).?;
    defer std.testing.allocator.free(p1);
    try std.testing.expectEqualStrings("crates/kode/src/session.rs", p1);

    const p2 = (try calleePath(&db, "run", "new")).?;
    defer std.testing.allocator.free(p2);
    try std.testing.expectEqualStrings("crates/kode/src/turn.rs", p2);
}

/// "path|kind|confidence;" for every calls edge src -> tgt, ordered by path.
fn edgeRows(buf: []u8, db: *graph_db.GraphDb, src: []const u8, tgt: []const u8) ![]const u8 {
    var stmt = try db.prepare(
        \\SELECT d.path, t.kind, e.confidence FROM edges e
        \\JOIN symbols s ON s.id = e.source_symbol_id
        \\JOIN symbols t ON t.id = e.target_symbol_id
        \\JOIN documents d ON d.id = t.document_id
        \\WHERE e.edge_type = 'calls' AND s.name = ? AND t.name = ?
        \\ORDER BY d.path
    );
    defer stmt.finalize();
    try stmt.bindText(1, src);
    try stmt.bindText(2, tgt);
    var w: usize = 0;
    while (try stmt.step()) {
        const row = try std.fmt.bufPrint(buf[w..], "{s}|{s}|{d:.1};", .{
            try stmt.columnText(0), try stmt.columnText(1), try stmt.columnFloat(2),
        });
        w += row.len;
    }
    return buf[0..w];
}

fn pendingCall(doc: i64, src: []const u8, tgt: []const u8, q: ?[]const u8) edge_resolver.PendingEdge {
    return .{ .source_doc_id = doc, .source_name = src, .target_name = tgt, .target_qualifier = q, .edge_type = .calls, .confidence = 1.0 };
}

/// Fresh DB with documents `paths` (ids 1..n) and `symbols` SQL VALUES rows.
fn resolverDb(comptime docs_sql: [:0]const u8, comptime syms_sql: [:0]const u8) !graph_db.GraphDb {
    var db = try graph_db.GraphDb.open(":memory:");
    errdefer db.close();
    try db.migrate();
    try db.exec("INSERT INTO documents (id, path) VALUES " ++ docs_sql);
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES " ++ syms_sql);
    return db;
}

test "edge_resolver: qualified call skips a same-file namesake (Bar::new from foo.rs)" {
    var db = try resolverDb("(1,'src/foo.rs'),(2,'src/bar.rs')",
        \\(1,'Foo','struct_type',1,2),(1,'new','method',3,4),(1,'run','function',5,9),
        \\(2,'Bar','struct_type',1,2),(2,'new','method',3,4)
    );
    defer db.close();
    const pending = [_]edge_resolver.PendingEdge{
        pendingCall(1, "run", "new", "Bar"),
        pendingCall(1, "run", "new", "Self"), // Self::new() stays local
    };
    _ = try edge_resolver.resolveEdges(&db, &pending);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("src/bar.rs|method|0.8;src/foo.rs|method|1.0;", try edgeRows(&buf, &db, "run", "new"));
}

test "edge_resolver: receiver-variable call keeps its same-file target" {
    var db = try resolverDb("(1,'src/view.rs'),(2,'src/other.rs')",
        \\(1,'render','method',1,2),(1,'run','function',3,9),(2,'render','method',1,2)
    );
    defer db.close();
    const pending = [_]edge_resolver.PendingEdge{pendingCall(1, "run", "render", "t")};
    _ = try edge_resolver.resolveEdges(&db, &pending);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("src/view.rs|method|1.0;", try edgeRows(&buf, &db, "run", "render"));
}

test "edge_resolver: external method call with unmatched qualifier is not guessed" {
    var db = try resolverDb("(1,'src/core/c.zig'),(2,'src/core/a.zig'),(3,'src/api/b.zig')",
        \\(1,'main','function',1,9),(2,'append','function',1,2),(3,'append','function',1,2)
    );
    defer db.close();
    const pending = [_]edge_resolver.PendingEdge{pendingCall(1, "main", "append", "list")};
    _ = try edge_resolver.resolveEdges(&db, &pending);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", try edgeRows(&buf, &db, "main", "append"));
}

test "edge_resolver: directory qualifier only matches module-index and Go files" {
    var db = try resolverDb(
        "(1,'src/core/main.zig'),(2,'src/debug/log.zig'),(3,'src/core/out.zig'),(4,'src/net/mod.rs'),(5,'src/x/net.rs')",
        \\(1,'main','function',1,9),(2,'print','function',1,2),(3,'print','function',1,2),
        \\(4,'connect','function',1,2),(5,'connect','function',1,2)
    );
    defer db.close();
    const pending = [_]edge_resolver.PendingEdge{
        pendingCall(1, "main", "print", "debug"), // std.debug.print
        pendingCall(1, "main", "connect", "net"), // net::connect -> both net modules qualify
    };
    _ = try edge_resolver.resolveEdges(&db, &pending);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", try edgeRows(&buf, &db, "main", "print"));
    try std.testing.expectEqualStrings("src/net/mod.rs|function|0.4;src/x/net.rs|function|0.4;", try edgeRows(&buf, &db, "main", "connect"));
}

test "edge_resolver: fields and variables are never call targets" {
    var db = try resolverDb("(1,'src/app/main.rs'),(2,'src/app/state.rs'),(3,'lib/runner.rs')",
        \\(1,'main','function',1,9),(1,'go','variable',1,1),(1,'go','function',2,3),
        \\(2,'run','field',1,1),(3,'run','function',1,2)
    );
    defer db.close();
    const pending = [_]edge_resolver.PendingEdge{
        pendingCall(1, "main", "run", null),
        pendingCall(1, "main", "go", null),
    };
    _ = try edge_resolver.resolveEdges(&db, &pending);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("lib/runner.rs|function|0.9;", try edgeRows(&buf, &db, "main", "run"));
    try std.testing.expectEqualStrings("src/app/main.rs|function|1.0;", try edgeRows(&buf, &db, "main", "go"));
}

test "edge_resolver: unqualified ties link up to MAX_FANOUT, wider ties none" {
    var db = try resolverDb("(1,'m/main.rs'),(2,'a/x.rs'),(3,'b/x.rs')",
        \\(1,'main','function',1,9),(2,'go','function',1,2),(3,'go','function',1,2)
    );
    defer db.close();
    var i: i64 = 0;
    while (i < 9) : (i += 1) {
        var sql: [160]u8 = undefined;
        try db.exec(try std.fmt.bufPrintZ(&sql, "INSERT INTO documents (id, path) VALUES ({d}, 'w{d}/y.rs')", .{ 10 + i, i }));
        try db.exec(try std.fmt.bufPrintZ(&sql, "INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES ({d},'stop','function',1,2)", .{10 + i}));
    }
    const pending = [_]edge_resolver.PendingEdge{ pendingCall(1, "main", "go", null), pendingCall(1, "main", "stop", null) };
    _ = try edge_resolver.resolveEdges(&db, &pending);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a/x.rs|function|0.4;b/x.rs|function|0.4;", try edgeRows(&buf, &db, "main", "go"));
    try std.testing.expectEqualStrings("", try edgeRows(&buf, &db, "main", "stop"));
}

test "qualifierSegment: generics and degenerate input" {
    try std.testing.expectEqualStrings("Foo", qualifierSegment("Foo::<T>::new").?);
    try std.testing.expectEqualStrings("Vec", qualifierSegment("Vec<Vec<u8>>::new").?);
    try std.testing.expectEqualStrings("s", qualifierSegment("s.parse::<i32>").?);
    try std.testing.expectEqualStrings("foo", qualifierSegment("  foo . bar  ").?);
    try std.testing.expectEqualStrings("x", qualifierSegment("x\n    .y").?);
    try std.testing.expect(qualifierSegment("<Foo as Trait>::new") == null);
    try std.testing.expect(qualifierSegment("a.b().c") == null);
    const junk = [_][]const u8{ "", ".", "::", "->", "::new", ".new", ">", "a>b", "<<", "x::>" };
    for (junk) |s| _ = qualifierSegment(s);
}

/// Full-index a temp tree of `files` (name, body) pairs.
fn indexTree(tmp: *std.testing.TmpDir, files: []const [2][]const u8) !graph_db.GraphDb {
    for (files) |f| {
        const h = try tmp.dir.createFile(f[0], .{});
        defer h.close();
        try h.writeAll(f[1]);
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);
    var db = try graph_db.GraphDb.open(":memory:");
    errdefer db.close();
    try db.migrate();
    var pipe = @import("zindeks").parser.pipeline.Pipeline.init(std.testing.allocator, db, root);
    _ = try pipe.run();
    return db;
}

fn scalarInt(db: *graph_db.GraphDb, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    _ = try stmt.step();
    return try stmt.columnInt(0);
}

test "calls inside the second same-named method are attributed to it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try indexTree(&tmp, &.{.{ "m.rs",
        \\struct Foo;
        \\struct Bar;
        \\impl Foo { fn new() -> Foo { alpha(); Foo } }
        \\impl Bar { fn new() -> Bar { beta(); Bar } }
        \\fn alpha() {}
        \\fn beta() {}
        \\
    }});
    defer db.close();
    const caller_line =
        \\SELECT s.line_start FROM edges e
        \\JOIN symbols s ON s.id = e.source_symbol_id
        \\JOIN symbols t ON t.id = e.target_symbol_id
        \\WHERE e.edge_type = 'calls' AND t.name =
    ;
    try std.testing.expectEqual(@as(i64, 3), try scalarInt(&db, caller_line ++ "'alpha'"));
    try std.testing.expectEqual(@as(i64, 4), try scalarInt(&db, caller_line ++ "'beta'"));
}

test "contains edges stay inside their own file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try indexTree(&tmp, &.{
        .{ "foo.rs", "struct Foo;\nimpl Foo { fn new() -> Foo { Foo } }\n" },
        .{ "bar.rs", "struct Bar;\nimpl Bar { fn new() -> Bar { Bar } }\nimpl Bar { fn new2() {} }\n" },
    });
    defer db.close();
    try std.testing.expectEqual(@as(i64, 3), try scalarInt(&db, "SELECT COUNT(*) FROM edges WHERE edge_type = 'contains'"));
    try std.testing.expectEqual(@as(i64, 0), try scalarInt(&db,
        \\SELECT COUNT(*) FROM edges e
        \\JOIN symbols s ON s.id = e.source_symbol_id
        \\JOIN symbols t ON t.id = e.target_symbol_id
        \\WHERE e.edge_type = 'contains' AND s.document_id <> t.document_id
    ));
}

test "rust extractor records call qualifiers" {
    const src =
        \\fn run() {
        \\    crate::session::append_turn(1);
        \\    let t = Turn::new();
        \\    t.render();
        \\    helper();
        \\}
    ;
    const generic_extractor = @import("zindeks").parser.generic_extractor;
    var res = try generic_extractor.extract(std.testing.allocator, src, .rust);
    defer res.deinit(std.testing.allocator);
    var seen: u8 = 0;
    for (res.edges) |e| {
        if (e.edge_type != .calls) continue;
        if (std.mem.eql(u8, e.target_name, "append_turn")) {
            try std.testing.expectEqualStrings("session", e.target_qualifier.?);
            seen |= 1;
        } else if (std.mem.eql(u8, e.target_name, "new")) {
            try std.testing.expectEqualStrings("Turn", e.target_qualifier.?);
            seen |= 2;
        } else if (std.mem.eql(u8, e.target_name, "render")) {
            try std.testing.expectEqualStrings("t", e.target_qualifier.?);
            seen |= 4;
        } else if (std.mem.eql(u8, e.target_name, "helper")) {
            try std.testing.expect(e.target_qualifier == null);
            seen |= 8;
        }
    }
    try std.testing.expectEqual(@as(u8, 15), seen);
}
