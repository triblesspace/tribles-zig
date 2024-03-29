const std = @import("std");
const testing = std.testing;
const time = std.time;

//const coz = @import("./coz.zig");

const Trible = @import("Trible.zig").Trible;
const pact = @import("./PACT.zig");
const TribleSet = @import("./TribleSet.zig").TribleSet;
const keyHash = @import("./PACT.zig").keyHash;
const ByteBitset = @import("./ByteBitset.zig").ByteBitset;
const commit = @import("./commit.zig");
//const FUCID = @import("./FUCID.zig");


const sample_size: usize = 1;
const change_prob = 0.1;

const PACT = pact.PACT(&[_]u8{16, 16, 32}, u32);

pub fn main() !void {
    const n = 1000000;
    pact.init();
    
    //var prng = std.rand.DefaultPrng.init(0);
    //var rnd = prng.random();

    //FUCID.init(rnd);
    
    //try benchmark_pact_small_write(n);
    //try benchmark_pact_cursor_iterate(n);
    //try benchmark_pact_write(n);
    try benchmark_tribleset_write(n);
    //try benchmark_commit(n);
    //try benchmark_hashing(n);
    //try benchmark_std(n);
}

pub fn benchmark_tribleset_write(data_size: usize) !void {
    //var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const allocator = gpa.allocator();
    //defer { _ = gpa.deinit();}

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();

    var set = try TribleSet.init(std.heap.c_allocator);
    defer set.deinit();

    std.debug.print("Inserting {d} tribles into TribleSet.\n", .{data_size});

    var i: u64 = 0;
    var t = Trible.initAribitrary(rnd);

    //coz.begin("insert");
    while (i < data_size) : (i += 1) {
        t = Trible.initAribitraryLike(rnd, change_prob, t);
        //const value = rnd.int(usize);

        timer.reset();

        try set.put(&t);
        //cpz.progress("put");

        t_total += timer.lap();
    }
    //coz.end("insert");

    std.debug.print("Inserted {d} in {d}ns\n", .{ i, t_total });
    //std.debug.print("{s}\n", .{set.mem_info()});

    //std.debug.print("{s}\n", .{set});
}

pub fn benchmark_pact_write(data_size: usize) !void {

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();

    var tree = PACT.Tree.init();
    defer tree.deinit(std.heap.c_allocator);

    std.debug.print("Inserting {d} tribles into PACT.\n", .{data_size});

    var i: u64 = 0;
    var t = Trible.initAribitrary(rnd);

    //coz.begin("insert");
    while (i < data_size) : (i += 1) {
        t = Trible.initAribitraryLike(rnd, change_prob, t);
        //const value = rnd.int(usize);

        timer.reset();

        // var node_iter = tree.nodes();
        // while(node_iter.next()) |res| {
        //     std.debug.print("Depth: {d}\n{s}\n", .{res.start_depth, res.node});
        // }

        try tree.put(t.data, null, std.heap.c_allocator);
        //cpz.progress("put");

        t_total += timer.lap();
    }
    //coz.end("insert");

    std.debug.print("Inserted {d} with {d} unique in {d}ns\n", .{ i, tree.count(), t_total });

    var node_iter = tree.nodes();
    while(node_iter.next()) |res| {
         if(res.node.diagnostics()) {
            std.debug.print("{s}\n", .{ res.node });
         }
    }

    std.debug.print("{s}\n", .{tree});
}

pub fn benchmark_pact_small_write(data_size: usize) !void {

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();

    var tree = pact.PACT(&[_]u8{8}, u32).Tree.init();
    defer tree.deinit(std.heap.c_allocator);

    std.debug.print("Inserting {d} u64 into PACT.\n", .{data_size});

    var i: u64 = 0;
    var t = Trible.initAribitrary(rnd);
    
    //coz.begin("insert");
    while (i < data_size) : (i += 1) {
        t = Trible.initAribitraryLike(rnd, change_prob, t);
        //const value = rnd.int(usize);

        timer.reset();

        const le_bytes = std.mem.asBytes(&i)[0..8].*;
        const be_bytes = [8]u8{le_bytes[7],
                               le_bytes[6],
                               le_bytes[5],
                               le_bytes[4],
                               le_bytes[3],
                               le_bytes[2],
                               le_bytes[1],
                               le_bytes[0]};

        try tree.put(be_bytes, null, std.heap.c_allocator);
        //cpz.progress("put");

        t_total += timer.lap();
    }
    //coz.end("insert");

    std.debug.print("Inserted {d} with {d} unique in {d}ns\n", .{ i, tree.count(), t_total });

    //std.debug.print("{s}\n", .{tree});

    std.debug.print("{s}\n", .{tree.mem_info()});
}

const union_tree_count = 1000;
pub fn benchmark_pact_union(data_size: usize) !void {
    const union_data_size = data_size / union_tree_count;

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();

    var trees: [union_tree_count]PACT.Tree = undefined;
    for( trees ) |*tree| {
        tree.* = PACT.Tree.init();

        var i: u64 = 0;
        var t = Trible.initAribitrary(rnd);
        while (i < union_data_size) : (i += 1) {
            t = Trible.initAribitraryLike(rnd, change_prob, t);
            try tree.put(t.data, null, std.heap.c_allocator);
        }
    }

    defer {
        for( trees ) |*tree| {
            tree.deinit();
        }
    }

    timer.reset();

    const union_tree = try PACT.Tree.initUnion(union_tree_count, trees[0..], std.heap.c_allocator);

    t_total += timer.lap();

    for( trees ) |tree| {
        std.debug.print("Tree with {d}\n", .{ tree.count() });
    }

    std.debug.print("Union {d} in {d}ns\n", .{ union_tree.count(), t_total });
}

const intersection_tree_count = 10;

pub fn benchmark_pact_intersection(data_size: usize) !void {

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();

    var trees: [union_tree_count]PACT.Tree = undefined;
    for( trees ) |*tree| {
        tree.* = PACT.Tree.init();

        var i: u64 = 0;
        var t = Trible.initAribitrary(rnd);
        while (i < data_size) : (i += 1) {
            t = Trible.initAribitraryLike(rnd, change_prob, t);
            try tree.put(t.data, null, std.heap.c_allocator);
        }
    }

    defer {
        for( trees ) |*tree| {
            tree.deinit();
        }
    }

    timer.reset();

    const intersection_tree = try PACT.Tree.initIntersection(intersection_tree_count, trees[0..], std.heap.c_allocator);

    t_total += timer.lap();

    for( trees ) |tree| {
        std.debug.print("Tree with {d}\n", .{ tree.count() });
    }

    std.debug.print("Intersection {d} in {d}ns\n", .{ intersection_tree.count(), t_total });
}

pub fn benchmark_pact_nodes_iterate(data_size: usize) !void {

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();

    var tree = PACT.Tree.init();
    defer tree.deinit();

    var t = Trible.initAribitrary(rnd);

    var i: u64 = 0;
    while (i < data_size) : (i += 1) {
        t = Trible.initAribitraryLike(rnd, change_prob, t);
        try tree.put(t.data, null, std.heap.c_allocator);

    }

    std.debug.print("Iterating nodes of PACT with {d} tribles.\n", .{data_size});
    timer.reset();
    //coz.begin("iterate");
    var j: u64 = 0;
    var iter = tree._nodes();
    while(iter.next()) |_| {
        j += 1;
        //coz.progress("next");
    }
    //coz.end("iterate");
    t_total += timer.lap();

    std.debug.print("Iterated {d} in {d}ns\n", .{ j, t_total });

}

pub fn benchmark_pact_cursor_iterate(data_size: usize) !void {

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();

    var tree = PACT.Tree.init();
    defer tree.deinit(std.heap.c_allocator);

    var t = Trible.initAribitrary(rnd);

    var i: u64 = 0;
    while (i < data_size) : (i += 1) {
        t = Trible.initAribitraryLike(rnd, change_prob, t);
        try tree.put(t.data, null, std.heap.c_allocator);

    }

    std.debug.print("Iterating cursor of PACT with {d} tribles.\n", .{data_size});
    timer.reset();
    //coz.begin("iterate");
    var j: u64 = 0;
    var iter = tree.cursor().iterate();
    while(iter.next()) |_| {
        j += 1;
        //coz.progress("next");
    }
    //coz.end("iterate");
    t_total += timer.lap();

    std.debug.print("Iterated {d} of {d} in {d}ns\n", .{ j, tree.count(), t_total });
    //std.debug.print("{s}\n", .{tree.mem_info()});

}

pub fn benchmark_hashing(data_size: usize) !void {
    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();

    std.debug.print("Hashing {d} tribles.\n", .{data_size});

    var i: u64 = 0;
    var t = Trible.initAribitrary(rnd);
    while (i < data_size) : (i += 1) {
        t = Trible.initAribitraryLike(rnd, change_prob, t);

        timer.reset();

        _ = keyHash(&t.data);

        t_total += timer.lap();
    }

    std.debug.print("Hashed {d} in {d}ns\n", .{ data_size, t_total });
}

pub fn benchmark_std(data_size: usize) !void {

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();
    
    var map = std.hash_map.AutoHashMap(Trible, ?usize).init(std.heap.c_allocator);
    defer map.deinit();

    std.debug.print("Inserting {d} tribles into AutoHashMap.\n", .{data_size});

    var i: u64 = 0;
    var t = Trible.initAribitrary(rnd);
    while (i < data_size) : (i += 1) {
        t = Trible.initAribitraryLike(rnd, change_prob, t);
        //const value = rnd.int(usize);

        timer.reset();

        try map.put(t, null);

        t_total += timer.lap();
    }

    std.debug.print("Inserted {d} in {d}ns\n", .{ data_size, t_total });

    std.debug.print("Iterating {d} tribles in AutoHashMap.\n", .{data_size});
    timer.reset();
    //coz.begin("iterate");
    var j: u64 = 0;
    var iter = map.iterator();
    while(iter.next()) |_| {
        j += 1;
        //coz.progress("next");
    }
    //coz.end("iterate");
    t_total += timer.lap();

    std.debug.print("Iterated {d} in {d}ns\n", .{ j, t_total });
}


pub fn benchmark_commit(data_size: usize) !void {
    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0);
    var rnd = prng.random();

    //FUCID.init(rnd);

    var set = try TribleSet.init(std.heap.c_allocator);
    defer set.deinit();

    std.debug.print("Inserting {d} tribles into TribleSet.\n", .{data_size});

    var i: u64 = 0;
    var t = Trible.initAribitrary(rnd);

    while (i < data_size) : (i += 1) {
        t = Trible.initAribitraryLike(rnd, change_prob, t);

        timer.reset();
        try set.put(&t);
        t_total += timer.lap();

    }
    
    std.debug.print("Inserted {d} in {d}ns\n", .{ i, t_total });


    var secret: [32]u8 = undefined;
    rnd.bytes(secret[0..]);
    const keypair = try commit.KeyPair.create(secret);

    var commit_id: [16]u8 = undefined;
    rnd.bytes(commit_id[0..]);

    //cpz.begin("create_commit");
    timer.reset();

    const com = try commit.Commit.initFromTribles(keypair, commit_id, set, std.heap.c_allocator);

    t_total = timer.lap();
    //cpz.end("create_commit");

    std.debug.print("Created commit for {d} triple in {d}ns\n", .{ i, t_total });

    //cpz.begin("load_commit");

    timer.reset();
    var read_set = try com.toTriblesetSet(std.heap.c_allocator);
    defer read_set.deinit();

    t_total = timer.lap();
    //cpz.end("load_commit");

    try com.deinit(std.heap.c_allocator);

    std.debug.print("Read commit for {d} triple in {d}ns\n", .{ read_set.count(), t_total });
}