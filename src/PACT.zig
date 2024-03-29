const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const ByteBitset = @import("ByteBitset.zig").ByteBitset;
const Card = @import("Card.zig").Card;
const MemInfo = @import("./MemInfo.zig").MemInfo;
const hash = @import("./PACT/Hash.zig");
const query = @import("./query.zig");
const Hash = hash.Hash;
const mem = std.mem;
const CursorIterator = query.CursorIterator;

pub fn init() void {
    hash.init();
}

/// The Tries branching factor, fixed to the number of elements
/// that can be represented by a byte/8bit.
const branch_factor = 256;

/// The number of hashes used in the cuckoo table.
const hash_count = 2;

/// The size of a cache line in bytes.
const cache_line_size = 64;

/// The size of node heads/fat pointers.
const node_size = 16;

/// The number of slots per bucket.
const bucket_slot_count = cache_line_size / node_size;

/// The maximum number of buckets per branch node.
const max_bucket_count = branch_factor / bucket_slot_count;

/// Infix nodes will be allocated so that their body sizes are multiples
/// of the chunk size.
const infix_chunk_size = 16;


/// The maximum number of cuckoo displacements atempted during
/// insert before the size of the table is increased.
const max_retries = 4;

/// A byte -> byte lookup table used in hashes as permutations.
const Byte_LUT = [256]u8;

/// Checks if a LUT is a permutation
fn is_permutation(lut: *const Byte_LUT) bool {
    var seen = ByteBitset.initEmpty();
    for (lut) |x| {
        seen.set(x);
    }

    return std.meta.eql(seen, ByteBitset.initFull());
}

/// Generate a LUT where each input maps to the input in reverse
/// bit order, e.g. 0b00110101 -> 0b10101100
fn generate_bitReverse_LUT() Byte_LUT {
    var lut: Byte_LUT = undefined;
    for (lut) |*element, i| {
        element.* = @bitReverse(@intCast(u8, i));
    }
    assert(is_permutation(&lut));
    return lut;
}

fn random_choice(rng: std.rand.Random, set: ByteBitset) ?u8 {
    if (set.isEmpty()) return null;

    var possible_values: [256]u8 = undefined;
    var possible_values_len: usize = 0;

    var set_iterator = set;
    while (set_iterator.drainNextAscending()) |b| {
        possible_values[possible_values_len] = @intCast(u8, b);
        possible_values_len += 1;
    }

    const rand_index: u8 = @intCast(u8, rng.uintLessThan(usize, possible_values_len));
    return possible_values[rand_index];
}

fn generate_rand_LUT_helper(rng: std.rand.Random, i: usize, remaining: ByteBitset, mask: u8, lut: *Byte_LUT) bool {
    if (i == 256) return true;

    var candidates = remaining;
    var iter = remaining;
    while (iter.drainNextAscending()) |candidate| {
        if ((@bitReverse(@intCast(u8, i)) & mask) == (candidate & mask)) {
            candidates.unset(candidate);
        }
    }
    while (random_choice(rng, candidates)) |candidate| {
        var new_remaining = remaining;
        new_remaining.unset(candidate);
        candidates.unset(candidate);
        lut[i] = candidate;
        if (generate_rand_LUT_helper(rng, i + 1, new_remaining, mask, lut)) {
            return true;
        }
    } else {
        return false;
    }
}

fn generate_rand_LUT(
    rng: std.rand.Random,
    mask: u8,
) Byte_LUT {
    var lut: Byte_LUT = undefined;
    if (!generate_rand_LUT_helper(rng, 0, ByteBitset.initFull(), mask, &lut)) unreachable;
    return lut;
}

/// Generates a byte -> byte lookup table for pearson hashing.
fn generate_pearson_LUT(comptime rng: std.rand.Random) Byte_LUT {
    var lut: Byte_LUT = undefined;
    var candidates = ByteBitset.initFull();

    for(lut) |*item| {
        const choice = random_choice(rng, candidates).?;
        candidates.unset(choice);
        item.* = choice;
    }
    assert(is_permutation(&lut));
    return lut;
}

fn index_start(infix_start: u8, index: u8) u8 {
    return (index - infix_start);
}

fn index_end(comptime infix_len: u8, infix_end: u8, index: u8) u8 {
    return (index + infix_len) - infix_end;
}

fn copy_start(target: []u8, source: []const u8, start_index: u8) void {
    const used_len = @min(source.len - start_index, target.len);
    mem.copy(u8, target[0 .. used_len], source[start_index .. start_index + used_len]);
}

fn copy_end(target: []u8, source: []const u8, end_index: u8) void {
    const used_len = @min(end_index, target.len);
    mem.copy(u8, target[target.len - used_len ..], source[end_index - used_len .. end_index]);
}

const allocError = std.mem.Allocator.Error;

const NodeTag = enum(u8) {
    none,
    branch1,
    branch2,
    branch4,
    branch8,
    branch16,
    branch32,
    branch64,
    infix2,
    infix3,
    infix4,
    leaf,
};

const rand_lut = blk: {
    @setEvalBranchQuota(1000000);
    var rand_state = std.rand.Xoroshiro128.init(0);
    break :blk generate_pearson_LUT(rand_state.random());
};

var random: u8 = 4; // Chosen by fair dice roll.

/// Hashes the value provided with the selected permuation and provided compression.
fn hashByteKey(
    // / Use alternative permuation.
    p: bool,
    // / Bucket count to parameterize the compression used to pigeonhole the items. Must be a power of 2.
    c: u8,
    // / The value to hash.
    v: u8,
) u8 {
    assert(@popCount(c) == 1);
    @setEvalBranchQuota(1000000);
    const random_lut = comptime blk: {
        @setEvalBranchQuota(1000000);
        var rand_state = std.rand.Xoroshiro128.init(0);
        break :blk generate_rand_LUT(rand_state.random(), hash_count-1);
    };
    const mask = c - 1;
    return mask & if (p) random_lut[v] else @bitReverse(v);
}

pub fn PACT(comptime segs: []const u8, comptime Value: type) type {
    return struct {
        pub const segments = segs;
        pub const key_length = blk: {
            var segment_sum = 0;
            for (segments) |segment| {
                segment_sum += segment;
            }
            break :blk segment_sum;
        };
        pub const value_type = Value;

        const segment_lut: [key_length + 1]u8 = blk: {
            var lut: [key_length + 1]u8 = undefined;

            var s = 0;
            var i = 0;
            for (segments) |segment| {
                var j = 0;
                while (j < segment) : ({
                    i += 1;
                    j += 1;
                }) {
                    lut[i] = s;
                }
                s += 1;
            }
            lut[key_length] = lut[key_length - 1];

            break :blk lut;
        };

        pub const Node = extern union {
            unknown: extern struct {
                tag: NodeTag,
                branch: u8,
                padding: [node_size - (@sizeOf(NodeTag) + @sizeOf(u8))]u8 = undefined,
            },
            none: extern struct {
                tag: NodeTag = .none,
                padding: [node_size - @sizeOf(NodeTag)]u8 = undefined,

                pub fn diagnostics(self: @This()) bool {
                    _ = self;
                    return false;
                }
            },
            branch1: BranchNodeBase,
            branch2: BranchNode(2),
            branch4: BranchNode(4),
            branch8: BranchNode(8),
            branch16: BranchNode(16),
            branch32: BranchNode(32),
            branch64: BranchNode(64),
            infix2: InfixNode(2),
            infix3: InfixNode(3),
            infix4: InfixNode(4),
            leaf: LeafNode,

            fn branchNodeTag(comptime bucket_count: u8) NodeTag {
                return switch (bucket_count) {
                    1 => NodeTag.branch1,
                    2 => NodeTag.branch2,
                    4 => NodeTag.branch4,
                    8 => NodeTag.branch8,
                    16 => NodeTag.branch16,
                    32 => NodeTag.branch32,
                    64 => NodeTag.branch64,
                    else => @panic("Bad bucket count for tag."),
                };
            }

            fn infixNodeTag(comptime infix_len: u8) NodeTag {
                return switch (infix_len) {
                    2 => NodeTag.infix2,
                    3 => NodeTag.infix3,
                    4 => NodeTag.infix4,
                    else => @panic("Bad infix count for infix tag."),
                };
            }

            pub fn format(
                self: Node,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = fmt;
                _ = options;

                switch (self.unknown.tag) {
                    .none => try writer.print("none", .{}),
                    .branch1 => try writer.print("{s}", .{self.branch1}),
                    .branch2 => try writer.print("{s}", .{self.branch2}),
                    .branch4 => try writer.print("{s}", .{self.branch4}),
                    .branch8 => try writer.print("{s}", .{self.branch8}),
                    .branch16 => try writer.print("{s}", .{self.branch16}),
                    .branch32 => try writer.print("{s}", .{self.branch32}),
                    .branch64 => try writer.print("{s}", .{self.branch64}),
                    .infix2 => try writer.print("{s}", .{self.infix2}),
                    .infix3 => try writer.print("{s}", .{self.infix3}),
                    .infix4 => try writer.print("{s}", .{self.infix4}),
                    .leaf => try writer.print("{s}", .{self.leaf}),
                }
                try writer.writeAll("");
            }

            pub fn isNone(self: Node) bool {
                return self.unknown.tag == .none;
            }

            pub fn ref(self: Node, allocator: std.mem.Allocator) allocError!?Node {
                return switch (self.unknown.tag) {
                    .none => Node{ .none = .{} },
                    .branch1 => self.branch1.ref(allocator),
                    .branch2 => self.branch2.ref(allocator),
                    .branch4 => self.branch4.ref(allocator),
                    .branch8 => self.branch8.ref(allocator),
                    .branch16 => self.branch16.ref(allocator),
                    .branch32 => self.branch32.ref(allocator),
                    .branch64 => self.branch64.ref(allocator),
                    .infix2 => self.infix2.ref(allocator),
                    .infix3 => self.infix3.ref(allocator),
                    .infix4 => self.infix4.ref(allocator),
                    .leaf => self.leaf.ref(allocator),
                };
            }

            pub fn rel(self: Node, allocator: std.mem.Allocator) void {
                switch (self.unknown.tag) {
                    .none => {},
                    .branch1 => self.branch1.rel(allocator),
                    .branch2 => self.branch2.rel(allocator),
                    .branch4 => self.branch4.rel(allocator),
                    .branch8 => self.branch8.rel(allocator),
                    .branch16 => self.branch16.rel(allocator),
                    .branch32 => self.branch32.rel(allocator),
                    .branch64 => self.branch64.rel(allocator),
                    .infix2 => self.infix2.rel(allocator),
                    .infix3 => self.infix3.rel(allocator),
                    .infix4 => self.infix4.rel(allocator),
                    .leaf => self.leaf.rel(allocator),
                }
            }

            pub fn count(self: Node) u64 {
                return switch (self.unknown.tag) {
                    .none => 0,
                    .branch1 => self.branch1.count(),
                    .branch2 => self.branch2.count(),
                    .branch4 => self.branch4.count(),
                    .branch8 => self.branch8.count(),
                    .branch16 => self.branch16.count(),
                    .branch32 => self.branch32.count(),
                    .branch64 => self.branch64.count(),
                    .infix2 => self.infix2.count(),
                    .infix3 => self.infix3.count(),
                    .infix4 => self.infix4.count(),
                    .leaf => self.leaf.count(),
                };
            }

            pub fn segmentCount(self: Node, depth: u8) u32 {
                return switch (self.unknown.tag) {
                    .none => 0,
                    .branch1 => self.branch1.segmentCount(depth),
                    .branch2 => self.branch2.segmentCount(depth),
                    .branch4 => self.branch4.segmentCount(depth),
                    .branch8 => self.branch8.segmentCount(depth),
                    .branch16 => self.branch16.segmentCount(depth),
                    .branch32 => self.branch32.segmentCount(depth),
                    .branch64 => self.branch64.segmentCount(depth),
                    .infix2 => self.infix2.segmentCount(depth),
                    .infix3 => self.infix3.segmentCount(depth),
                    .infix4 => self.infix4.segmentCount(depth),
                    .leaf => self.leaf.segmentCount(depth),
                };
            }

            pub fn hash(self: Node, prefix: [key_length]u8) Hash {
                return switch (self.unknown.tag) {
                    .none => Hash{},
                    .branch1 => self.branch1.hash(prefix),
                    .branch2 => self.branch2.hash(prefix),
                    .branch4 => self.branch4.hash(prefix),
                    .branch8 => self.branch8.hash(prefix),
                    .branch16 => self.branch16.hash(prefix),
                    .branch32 => self.branch32.hash(prefix),
                    .branch64 => self.branch64.hash(prefix),
                    .infix2 => self.infix2.hash(prefix),
                    .infix3 => self.infix3.hash(prefix),
                    .infix4 => self.infix4.hash(prefix),
                    .leaf => self.leaf.hash(prefix),
                };
            }

            pub fn start(self: Node) u8 {
                return switch (self.unknown.tag) {
                    .none => @panic("Called `start` on none."),
                    .branch1 => self.branch1.start_depth,
                    .branch2 => self.branch2.start_depth,
                    .branch4 => self.branch4.start_depth,
                    .branch8 => self.branch8.start_depth,
                    .branch16 => self.branch16.start_depth,
                    .branch32 => self.branch32.start_depth,
                    .branch64 => self.branch64.start_depth,
                    .infix2 => self.infix2.start_depth,
                    .infix3 => self.infix3.start_depth,
                    .infix4 => self.infix4.start_depth,
                    .leaf => self.leaf.start_depth,
                };
            }

            pub fn range(self: Node) u8 {
                return switch (self.unknown.tag) {
                    .none => @panic("Called `range` on none."),
                    .branch1 => self.branch1.range(),
                    .branch2 => self.branch2.range(),
                    .branch4 => self.branch4.range(),
                    .branch8 => self.branch8.range(),
                    .branch16 => self.branch16.range(),
                    .branch32 => self.branch32.range(),
                    .branch64 => self.branch64.range(),
                    .infix2 => self.infix2.range(),
                    .infix3 => self.infix3.range(),
                    .infix4 => self.infix4.range(),
                    .leaf => self.leaf.range(),
                };
            }


            pub fn initAt(self: Node, start_depth: u8, key: [key_length]u8) Node {
                return switch (self.unknown.tag) {
                    .none => @panic("Called `initAt` on none."),
                    .leaf => self.leaf.initAt(start_depth, key),
                    .branch1 => self.branch1.initAt(start_depth, key),
                    .branch2 => self.branch2.initAt(start_depth, key),
                    .branch4 => self.branch4.initAt(start_depth, key),
                    .branch8 => self.branch8.initAt(start_depth, key),
                    .branch16 => self.branch16.initAt(start_depth, key),
                    .branch32 => self.branch32.initAt(start_depth, key),
                    .branch64 => self.branch64.initAt(start_depth, key),
                    .infix2 => self.infix2.initAt(start_depth, key),
                    .infix3 => self.infix3.initAt(start_depth, key),
                    .infix4 => self.infix4.initAt(start_depth, key),
                };
            }

            pub fn peek(self: Node, at_depth: u8) ?u8 {
                return switch (self.unknown.tag) {
                    .none => null,
                    .branch1 => self.branch1.peek(at_depth),
                    .branch2 => self.branch2.peek(at_depth),
                    .branch4 => self.branch4.peek(at_depth),
                    .branch8 => self.branch8.peek(at_depth),
                    .branch16 => self.branch16.peek(at_depth),
                    .branch32 => self.branch32.peek(at_depth),
                    .branch64 => self.branch64.peek(at_depth),
                    .infix2 => self.infix2.peek(at_depth),
                    .infix3 => self.infix3.peek(at_depth),
                    .infix4 => self.infix4.peek(at_depth),
                    .leaf => self.leaf.peek(at_depth),
                };
            }

            pub fn propose(self: Node, at_depth: u8, result_set: *ByteBitset) void {
                return switch (self.unknown.tag) {
                    .none => result_set.unsetAll(),
                    .branch1 => self.branch1.propose(at_depth, result_set),
                    .branch2 => self.branch2.propose(at_depth, result_set),
                    .branch4 => self.branch4.propose(at_depth, result_set),
                    .branch8 => self.branch8.propose(at_depth, result_set),
                    .branch16 => self.branch16.propose(at_depth, result_set),
                    .branch32 => self.branch32.propose(at_depth, result_set),
                    .branch64 => self.branch64.propose(at_depth, result_set),
                    .infix2 => self.infix2.propose(at_depth, result_set),
                    .infix3 => self.infix3.propose(at_depth, result_set),
                    .infix4 => self.infix4.propose(at_depth, result_set),
                    .leaf => self.leaf.propose(at_depth, result_set),
                };
            }

            pub fn get(self: Node, at_depth: u8, byte_key: u8) Node {
                return switch (self.unknown.tag) {
                    .none => self,
                    .branch1 => self.branch1.get(at_depth, byte_key),
                    .branch2 => self.branch2.get(at_depth, byte_key),
                    .branch4 => self.branch4.get(at_depth, byte_key),
                    .branch8 => self.branch8.get(at_depth, byte_key),
                    .branch16 => self.branch16.get(at_depth, byte_key),
                    .branch32 => self.branch32.get(at_depth, byte_key),
                    .branch64 => self.branch64.get(at_depth, byte_key),
                    .infix2 => self.infix2.get(at_depth, byte_key),
                    .infix3 => self.infix3.get(at_depth, byte_key),
                    .infix4 => self.infix4.get(at_depth, byte_key),
                    .leaf => self.leaf.get(at_depth, byte_key),
                };
            }

            pub fn put(self: Node, start_depth: u8, key: [key_length]u8, value: Value, single_owner: bool, allocator: std.mem.Allocator) allocError!Node {
                return switch (self.unknown.tag) {
                    .none => @panic("Called `put` on none."),
                    .branch1 => self.branch1.put(start_depth, key, value, single_owner, allocator),
                    .branch2 => self.branch2.put(start_depth, key, value, single_owner, allocator),
                    .branch4 => self.branch4.put(start_depth, key, value, single_owner, allocator),
                    .branch8 => self.branch8.put(start_depth, key, value, single_owner, allocator),
                    .branch16 => self.branch16.put(start_depth, key, value, single_owner, allocator),
                    .branch32 => self.branch32.put(start_depth, key, value, single_owner, allocator),
                    .branch64 => self.branch64.put(start_depth, key, value, single_owner, allocator),
                    .infix2 => self.infix2.put(start_depth, key, value, single_owner, allocator),
                    .infix3 => self.infix3.put(start_depth, key, value, single_owner, allocator),
                    .infix4 => self.infix4.put(start_depth, key, value, single_owner, allocator),
                    .leaf => self.leaf.put(start_depth, key, value, single_owner, allocator),
                };
            }

            fn createBranch(self: Node, child: Node, at_depth: u8, prefix: [key_length]u8) ?Node {
                return switch (self.unknown.tag) {
                    .branch1 => self.branch1.createBranch(child, at_depth, prefix),
                    .branch2 => self.branch2.createBranch(child, at_depth, prefix),
                    .branch4 => self.branch4.createBranch(child, at_depth, prefix),
                    .branch8 => self.branch8.createBranch(child, at_depth, prefix),
                    .branch16 => self.branch16.createBranch(child, at_depth, prefix),
                    .branch32 => self.branch32.createBranch(child, at_depth, prefix),
                    .branch64 => self.branch64.createBranch(child, at_depth, prefix),
                    .none => @panic("Called `createBranch` on none."),
                    else => @panic("Called `createBranch` on non-branch node."),
                };
            }

            fn reinsertBranch(self: Node, node: Node) ?Node {
                return switch (self.unknown.tag) {
                    .branch1 => self.branch1.reinsertBranch(node),
                    .branch2 => self.branch2.reinsertBranch(node),
                    .branch4 => self.branch4.reinsertBranch(node),
                    .branch8 => self.branch8.reinsertBranch(node),
                    .branch16 => self.branch16.reinsertBranch(node),
                    .branch32 => self.branch32.reinsertBranch(node),
                    .branch64 => self.branch64.reinsertBranch(node),
                    .none => @panic("Called `reinsertBranch` on none."),
                    else => @panic("Called `reinsertBranch` on non-branch node."),
                };
            }

            fn grow(self: Node, allocator: std.mem.Allocator) allocError!Node {
                return switch (self.unknown.tag) {
                    .branch1 => self.branch1.grow(allocator),
                    .branch2 => self.branch2.grow(allocator),
                    .branch4 => self.branch4.grow(allocator),
                    .branch8 => self.branch8.grow(allocator),
                    .branch16 => self.branch16.grow(allocator),
                    .branch32 => self.branch32.grow(allocator),
                    .branch64 => self.branch64.grow(allocator),
                    .none => @panic("Called `grow` on none."),
                    else => @panic("Called `grow` on non-branch node."),
                };
            }

            pub fn getValue(self: Node) Value {
                return switch (self.unknown.tag) {
                    .none => null,
                    .leaf => self.leaf.value,
                    else => @panic("Called `value` on non-terminal node."),
                };
            }

            pub fn coveredDepth(self: Node) u8 {
                return switch (self.unknown.tag) {
                    .none => 0,
                    .branch1 => self.branch1.branch_depth,
                    .branch2 => self.branch2.branch_depth,
                    .branch4 => self.branch4.branch_depth,
                    .branch8 => self.branch8.branch_depth,
                    .branch16 => self.branch16.branch_depth,
                    .branch32 => self.branch32.branch_depth,
                    .branch64 => self.branch64.branch_depth,
                    .infix2 => self.infix2.body.child.coveredDepth(),
                    .infix3 => self.infix3.body.child.coveredDepth(),
                    .infix4 => self.infix4.body.child.coveredDepth(),
                    .leaf => key_length,
                };
            }

            pub fn diagnostics(self: Node) bool {
                return switch (self.unknown.tag) {
                    .none => self.none.diagnostics(),
                    .branch1 => self.branch1.diagnostics(),
                    .branch2 => self.branch2.diagnostics(),
                    .branch4 => self.branch4.diagnostics(),
                    .branch8 => self.branch8.diagnostics(),
                    .branch16 => self.branch16.diagnostics(),
                    .branch32 => self.branch32.diagnostics(),
                    .branch64 => self.branch64.diagnostics(),
                    .infix2 => self.infix2.diagnostics(),
                    .infix3 => self.infix3.diagnostics(),
                    .infix4 => self.infix4.diagnostics(),
                    .leaf => self.leaf.diagnostics(),
                };
            }

            pub fn mem_info(self: Node) MemInfo {
                return switch (self.unknown.tag) {
                    .none => @panic("Called 'mem_info' on none."),
                    .branch1 => self.branch1.mem_info(),
                    .branch2 => self.branch2.mem_info(),
                    .branch4 => self.branch4.mem_info(),
                    .branch8 => self.branch8.mem_info(),
                    .branch16 => self.branch16.mem_info(),
                    .branch32 => self.branch32.mem_info(),
                    .branch64 => self.branch64.mem_info(),
                    .infix2 => self.infix2.mem_info(),
                    .infix3 => self.infix3.mem_info(),
                    .infix4 => self.infix4.mem_info(),
                    .leaf => self.leaf.mem_info(),
                };
            }
        };

        const Bucket = extern struct {
            slots: [bucket_slot_count]Node = [_]Node{Node{ .none = .{} }} ** bucket_slot_count,

            pub fn get(self: *const Bucket, byte_key: u8) Node {
                for (self.slots) |slot| {
                    if (slot.unknown.tag != .none and (slot.unknown.branch == byte_key)) {
                        return slot;
                    }
                }
                return Node{ .none = .{} };
            }

            /// Attempt to store a new node in this bucket,
            /// the key must not exist in this bucket beforehand.
            /// If there is no free slot the attempt will fail.
            /// Returns true iff it succeeds.
            pub fn put(
                self: *Bucket,
                // / Determines the hash function used for each key and is used to detect outdated (free) slots.
                rand_hash_used: *ByteBitset,
                // / The current bucket count. Is used to detect outdated (free) slots.
                current_count: u8,
                // / The current index the bucket has. Is used to detect outdated (free) slots.
                bucket_index: u8,
                // / The entry to be stored in the bucket.
                entry: Node,
            ) bool {
                return self.putIntoSame(entry) or self.putIntoEmpty(entry) or self.putIntoOutdated(rand_hash_used, current_count, bucket_index, entry);
            }

            /// Updates the pointer for the key stored in this bucket.
            pub fn putIntoEmpty(
                self: *Bucket,
                // / The new entry value.
                entry: Node,
            ) bool {
                for (self.slots) |*slot| {
                    if (slot.isNone()) {
                        slot.* = entry;
                        return true;
                    }
                }
                return false;
            }

            /// Updates the pointer for the key stored in this bucket.
            pub fn putIntoSame(
                self: *Bucket,
                // / The new entry value.
                entry: Node,
            ) bool {
                for (self.slots) |*slot| {
                    if (slot.unknown.tag != .none and (slot.unknown.branch == entry.unknown.branch)) {
                        slot.* = entry;
                        return true;
                    }
                }
                return false;
            }

            pub fn putIntoOutdated(
                self: *Bucket,
                // / Determines the hash function used for each key and is used to detect outdated (free) slots.
                rand_hash_used: *ByteBitset,
                // / The current bucket count. Is used to detect outdated (free) slots.
                current_count: u8,
                // / The current index the bucket has. Is used to detect outdated (free) slots.
                bucket_index: u8,
                // / The entry to be stored in the bucket.
                entry: Node,
            ) bool {
                for (self.slots) |*slot| {
                    const slot_key = slot.unknown.branch;
                    if (bucket_index != hashByteKey(rand_hash_used.isSet(slot_key), current_count, slot_key)) {
                        slot.* = entry;
                        return true;
                    }
                }
                return false;
            }

            /// Displaces a random existing slot.
            pub fn displaceRandomly(
                self: *Bucket,
                // / A random value to determine the slot to displace.
                random_value: u8,
                // / The entry that displaces an existing entry.
                entry: Node,
            ) Node {
                const index = random_value & (bucket_slot_count - 1);
                const prev = self.slots[index];
                self.slots[index] = entry;
                return prev;
            }

            /// Displaces the first slot that is using the alternate hash function.
            pub fn displaceRandHashOnly(
                self: *Bucket,
                // / Determines the hash function used for each key and is used to detect outdated (free) slots.
                rand_hash_used: *ByteBitset,
                // / The entry to be stored in the bucket.
                entry: Node,
            ) Node {
                for (self.slots) |*slot| {
                    if (rand_hash_used.isSet(slot.unknown.branch)) {
                        const prev = slot.*;
                        slot.* = entry;
                        return prev;
                    }
                }
                unreachable;
            }
        };

        const BranchNodeBase = extern struct {
            const head_infix_len = node_size - (@sizeOf(NodeTag)
                                              + @sizeOf(u8)
                                              + @sizeOf(u8)
                                              + @sizeOf(usize));
            const body_infix_len = 32;
            const infix_len = head_infix_len + body_infix_len;

            tag: NodeTag = .branch1,
            /// The infix stored in this head.
            infix: [head_infix_len]u8 = [_]u8{0} ** head_infix_len,
            /// The start depth of the head infix.
            start_depth: u8,
            /// The branch depth of the body.
            branch_depth: u8,
            /// The address of the pointer associated with the key.
            body: *Body,

            const Head = @This();

            const GrownHead = BranchNode(2);

            const Body = extern struct {
                leaf_count: u64 = 0,
                ref_count: u16 = 1,
                padding: [2]u8 = undefined,
                segment_count: u32 = 0,
                node_hash: Hash = Hash{},
                infix: [body_infix_len]u8 = [_]u8{0} ** body_infix_len,
                bucket: Bucket = Bucket{},
            };

            pub fn format(
                self: Head,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = fmt;
                _ = options;

                _ = self;

                try writer.writeAll("Branch One");
            }

            pub fn diagnostics(self: Head) bool {
                var has_errors = false;
                //Infix start consitency.
                const peek_branch = self.peek(self.start_depth).?;
                const unknown_branch = @bitCast(Node, self).unknown.branch;
                if(peek_branch != unknown_branch) {
                    has_errors = true;
                    std.debug.print("Diagnostics - Inconsistent infix start; peek():{x} != unknown.branch:{x}\n", .{peek_branch,  unknown_branch});
                }

                //Child depth consistency.
                for (self.body.bucket.slots) |slot| {
                    if (!slot.isNone()) {
                        const child_start = slot.start();
                        if(self.branch_depth != child_start) {
                            has_errors = true;
                            std.debug.print("Diagnostics - Inconsistent child depth for {s}; branch_depth:{d} != child.start():{d}\n", .{slot.unknown.tag, self.branch_depth,  child_start });
                        }
                    }
                }

                return has_errors;
            }


            pub fn init(start_depth: u8, branch_depth: u8, key: [key_length]u8, allocator: std.mem.Allocator) allocError!Head {
                const allocation = try allocator.alignedAlloc(u8, cache_line_size, @sizeOf(Body));
                const new_body = std.mem.bytesAsValue(Body, allocation[0..@sizeOf(Body)]);
                new_body.* = Body{};

                var new_head = Head{ .start_depth = start_depth, .branch_depth = branch_depth, .body = new_body };

                copy_start(new_head.infix[0..], key[0..], start_depth);
                copy_end(new_body.infix[0..], key[0..], branch_depth);

                return new_head;
            }

            pub fn initBranch(start_depth: u8, branch_depth: u8, key: [key_length]u8, left: Node, right: Node, allocator: std.mem.Allocator) allocError!Node {
                assert(start_depth <= branch_depth);

                const max_start_depth = branch_depth - @min(branch_depth, infix_len);
                const actual_start_depth = @max(start_depth, max_start_depth);

                const branch_node = try BranchNodeBase.init(actual_start_depth, branch_depth, key, allocator);

                // Note that these can't fail.
                _ = branch_node.createBranch(left, branch_depth, key);
                _ = branch_node.createBranch(right, branch_depth, key);

                return @bitCast(Node, branch_node);
            }

            pub fn initAt(self: Head, start_depth: u8, key: [key_length]u8) Node {
                assert(start_depth <= self.branch_depth);
                assert(start_depth + infix_len >= self.branch_depth);
                
                var new_head = self;
                new_head.start_depth = start_depth;
                for(new_head.infix) |*v, i| {
                    const depth = @intCast(u8, start_depth + i);
                    if(depth < self.start_depth) {
                        v.* = key[depth];
                        continue;
                    }
                    if(self.branch_depth <= depth) break;
                    v.* = self.peek(depth).?;
                }
                return @bitCast(Node, new_head);
            }

            pub fn ref(self: Head, allocator: std.mem.Allocator) allocError!?Node {
                if (self.body.ref_count == std.math.maxInt(@TypeOf(self.body.ref_count))) {
                    // Reference counter exhausted, we need to make a copy of this node.
                    return @bitCast(Node, try self.copy(allocator));
                } else {
                    self.body.ref_count += 1;
                    return null;
                }
            }

            pub fn rel(self: Head, allocator: std.mem.Allocator) void {
                self.body.ref_count -= 1;
                if (self.body.ref_count == 0) {
                    defer allocator.free(std.mem.asBytes(self.body));
                    for (self.body.bucket.slots) |slot| {
                        if (slot.unknown.tag != .none) {
                            slot.rel(allocator);
                        }
                    }
                }
            }

            pub fn count(self: Head) u64 {
                return self.body.leaf_count;
            }

            pub fn segmentCount(self: Head, depth: u8) u32 {
                if (segment_lut[depth] == segment_lut[self.branch_depth]) {
                    return self.body.segment_count;
                } else {
                    return 1;
                }
            }

            pub fn hash(self: Head, prefix: [key_length]u8) Hash {
                _ = prefix;
                return self.body.node_hash;
            }

            pub fn range(self: Head) u8 {
                return self.branch_depth - @min(self.branch_depth, infix_len);
            }

            pub fn peek(self: Head, at_depth: u8) ?u8 {
                if (at_depth < self.start_depth or self.branch_depth <= at_depth) return null;
                if (at_depth < self.start_depth + head_infix_len)
                    return self.infix[index_start(self.start_depth, at_depth)];
                return self.body.infix[index_end(body_infix_len, self.branch_depth, at_depth)];  
            }

            pub fn propose(self: Head, at_depth: u8, result_set: *ByteBitset) void {
                result_set.unsetAll();
                if (at_depth == self.branch_depth) {
                    for (self.body.bucket.slots) |slot| {
                        if (!slot.isNone()) {
                            result_set.set(slot.peek(at_depth).?);
                        }
                    }
                    return;
                }

                if (self.peek(at_depth)) |byte_key| {
                    result_set.set(byte_key);
                    return;
                }
            }

            pub fn put(self: Head, start_depth: u8, key: [key_length]u8, value: Value, parent_single_owner: bool, allocator: std.mem.Allocator) allocError!Node {
                const single_owner = parent_single_owner and self.body.ref_count == 1;

                var branch_depth = start_depth;
                while (branch_depth < self.branch_depth) : (branch_depth += 1) {
                    if (key[branch_depth] != self.peek(branch_depth).?) break;
                } else {
                    // The entire compressed infix above this node matched with the key.
                    const byte_key = key[branch_depth];

                    const old_child = self.body.bucket.get(byte_key);
                    if (old_child.unknown.tag != .none) {
                        // The node already has a child branch with the same byte byte_key as the one in the key.
                        const old_child_hash = old_child.hash(key);
                        const old_child_leaf_count = old_child.count();
                        const old_child_segment_count = old_child.segmentCount(branch_depth);
                        const new_child = try old_child.put(branch_depth, key, value, single_owner, allocator);
                        const new_child_hash = new_child.hash(key);
                        if (Hash.equal(old_child_hash, new_child_hash)) {
                            return @bitCast(Node, self);
                        }
                        const new_hash = self.body.node_hash.update(old_child_hash, new_child_hash);
                        const new_leaf_count = self.body.leaf_count - old_child_leaf_count + new_child.count();
                        const new_segment_count = self.body.segment_count - old_child_segment_count + new_child.segmentCount(branch_depth);

                        var self_or_copy = self;
                        if (!single_owner) {
                            self_or_copy = try self.copy(allocator);
                            old_child.rel(allocator);
                        }
                        self_or_copy.body.node_hash = new_hash;
                        self_or_copy.body.leaf_count = new_leaf_count;
                        self_or_copy.body.segment_count = new_segment_count;

                        _ = self_or_copy.body.bucket.putIntoSame(new_child);
                        return @bitCast(Node, self_or_copy);
                    } else {
                        const new_child_node = try WrapInfixNode(branch_depth, key, InitLeaf(branch_depth, key, value), allocator);

                        var self_or_copy = if (single_owner) self else try self.copy(allocator);

                        var displaced = self_or_copy.createBranch(new_child_node, branch_depth, key);
                        var grown = @bitCast(Node, self_or_copy);
                        while (displaced) |entry| {
                            grown = try grown.grow(allocator);
                            displaced = grown.reinsertBranch(entry);
                        }
                        return grown;
                    }
                }

                const sibling_leaf_node = try WrapInfixNode(branch_depth, key, InitLeaf(branch_depth, key, value), allocator);

                return try BranchNodeBase.initBranch(start_depth, branch_depth, key, sibling_leaf_node, self.initAt(branch_depth, key), allocator);
            }

            pub fn get(self: Head, at_depth: u8, byte_key: u8) Node {
                if (at_depth == self.branch_depth) {
                    return self.body.bucket.get(byte_key);
                }
                if (self.peek(at_depth)) |own_key| {
                    if (own_key == byte_key) return @bitCast(Node, self);
                }
                return Node{ .none = .{} };
            }

            fn copy(self: Head, allocator: std.mem.Allocator) allocError!Head {
                const allocation = try allocator.alignedAlloc(u8, cache_line_size, @sizeOf(Body));
                const new_body = std.mem.bytesAsValue(Body, allocation[0..@sizeOf(Body)]);

                new_body.* = self.body.*;
                new_body.ref_count = 1;

                var new_head = self;
                new_head.body = new_body;

                for (new_head.body.bucket.slots) |*child| {
                    if (!child.isNone()) {
                        const potential_child_copy = try child.ref(allocator);
                        if (potential_child_copy) |new_child| {
                            child.* = new_child;
                        }
                    }
                }

                return new_head;
            }

            fn grow(self: Head, allocator: std.mem.Allocator) allocError!Node {
                const bucket = self.body.bucket;

                const allocation: []align(cache_line_size) u8 = try allocator.alignedAlloc(std.mem.span(std.mem.asBytes(self.body)), cache_line_size, @sizeOf(GrownHead.Body));
                const new_body = std.mem.bytesAsValue(GrownHead.Body, allocation[0..@sizeOf(GrownHead.Body)]);

                new_body.buckets[0] = bucket;
                new_body.buckets[1] = bucket;

                new_body.child_set.unsetAll();
                new_body.rand_hash_used.unsetAll();

                for (bucket.slots) |child| {
                    new_body.child_set.set(child.peek(self.branch_depth).?);
                }

                return @bitCast(Node, GrownHead{.start_depth = self.start_depth,
                                                .branch_depth = self.branch_depth,
                                                .infix = self.infix,
                                                .body = new_body});
            }

            fn createBranch(self: Head, child: Node, at_depth: u8, prefix: [key_length]u8) ?Node {
                self.body.node_hash = self.body.node_hash.combine(child.hash(prefix));
                self.body.leaf_count += child.count();
                self.body.segment_count += child.segmentCount(at_depth);

                return self.reinsertBranch(child);
            }

            fn reinsertBranch(self: Head, node: Node) ?Node { //TODO get rid of this and make the other one return Node{ .none = .{} }
                if (self.body.bucket.putIntoEmpty(node)) {
                    return null; //TODO use none.
                }
                return node;
            }

            fn mem_info(self: Head) MemInfo {
                var unused_slots: u8 = 0;
                var wasted_infix_bytes: usize = 0;
                for (self.body.bucket.slots) |child| {
                    if (child.isNone()) {
                        unused_slots += 1;
                    } else {
                        wasted_infix_bytes += (self.branch_depth - child.range());
                    }
                }

                return MemInfo{ .active_memory = @sizeOf(Body), .wasted_memory = (@sizeOf(Node) * unused_slots) + wasted_infix_bytes, .passive_memory = @sizeOf(Head), .allocation_count = 1 };
            }
        };

        fn BranchNode(comptime bucket_count: u8) type {
            const head_infix_len = node_size - (@sizeOf(NodeTag)
                                              + @sizeOf(u8)
                                              + @sizeOf(u8)
                                              + @sizeOf(usize));
            const body_infix_len = 32;
            const infix_len = head_infix_len + body_infix_len;

            return extern struct {
                tag: NodeTag = Node.branchNodeTag(bucket_count),
                /// The infix stored in this head.
                infix: [head_infix_len]u8 = [_]u8{0} ** head_infix_len,
                /// The start depth of the head infix.
                start_depth: u8,
                /// The branch depth of the body.
                branch_depth: u8,
                /// The address of the pointer associated with the key.
                body: *Body,

                const Head = @This();

                const GrownHead = if (bucket_count == max_bucket_count) Head else BranchNode(bucket_count << 1);

                const Body = extern struct {
                    leaf_count: u64 = 0,
                    ref_count: u16 = 1,
                    padding: [2]u8 = undefined,
                    segment_count: u32 = 0,
                    node_hash: Hash = Hash{},
                    infix: [body_infix_len]u8 = [_]u8{0} ** body_infix_len,
                    child_set: ByteBitset = ByteBitset.initEmpty(),
                    rand_hash_used: ByteBitset = ByteBitset.initEmpty(),
                    buckets: Buckets = if (bucket_count == 1) [_]Bucket{Bucket{}} else undefined,

                    const Buckets = [bucket_count]Bucket;
                };

                pub fn format(
                    self: Head,
                    comptime fmt: []const u8,
                    options: std.fmt.FormatOptions,
                    writer: anytype,
                ) !void {
                    _ = fmt;
                    _ = options;
                            
                    var card = (Card.init(std.heap.c_allocator) catch @panic("Error allocating card!")).from(
\\┌────────────────────────────────────────────────────────────────────────────────┐
\\│ Branch Node @░░░░░░░░░░░░░░░░                                                  │
\\│━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                                                  │
\\│                                                                                │
\\│ Metadata                                                                       │
\\│ ═════════                                                                      │
\\│                                                                                │
\\│    Ref#: ░░░░░                                  Leafs: ░░░░░░░░░░░░░░░░░░░░    │
\\│    Hash: ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░    Segments: ░░░░░░░░░░░░░░░░░░░░    │
\\│                                                                                │
\\│ Infix                                                                          │
\\│ ══════                                                                         │
\\│         ┌──────────────────────────┐                                           │
\\│         ▼                          │                                           │
\\│   Head: ░░░░░░░░░░   Start depth: ░░░              Branch depth: ░░░────┐      │
\\│         ▔▔  ▔▔  ▔▔                                                      ▼      │
\\│   Body: ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░       │
\\│         ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔  ▔▔         │
\\│ Children                                                                       │
\\│ ══════════                                                                     │
\\│                                         0123456789ABCDEF     0123456789ABCDEF  │
\\│  ▼                                     ┌────────────────┐   ┌────────────────┐ │
\\│  ┌           ● Seq Hash      ░░░     0_│░░░░░░░░░░░░░░░░│ 8_│░░░░░░░░░░░░░░░░│ │
\\│  │░          ◆ Rand Hash     ░░░     1_│░░░░░░░░░░░░░░░░│ 9_│░░░░░░░░░░░░░░░░│ │
\\│  │░          ○ Seq Missing   ░░░     2_│░░░░░░░░░░░░░░░░│ A_│░░░░░░░░░░░░░░░░│ │
\\│  │░░         ◇ Rand Missing  ░░░     3_│░░░░░░░░░░░░░░░░│ B_│░░░░░░░░░░░░░░░░│ │
\\│  │░░░░                               4_│░░░░░░░░░░░░░░░░│ C_│░░░░░░░░░░░░░░░░│ │
\\│  │░░░░░░░░                           5_│░░░░░░░░░░░░░░░░│ D_│░░░░░░░░░░░░░░░░│ │
\\│  │░░░░░░░░░░░░░░░░                   6_│░░░░░░░░░░░░░░░░│ E_│░░░░░░░░░░░░░░░░│ │
\\│  │░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   7_│░░░░░░░░░░░░░░░░│ F_│░░░░░░░░░░░░░░░░│ │
\\│  └                                     └────────────────┘   └────────────────┘ │
\\└────────────────────────────────────────────────────────────────────────────────┘
                    ) catch unreachable;
                    defer card.deinit();

                    card.labelFmt(14, 0, "{x:0>16}", .{@ptrToInt(self.body)}) catch @panic("Error writing to card!");
                    
                    card.labelFmt(10, 6, "{d:_>5}", .{self.body.ref_count}) catch @panic("Error writing to card!");
                    card.labelFmt(10, 7, "{s:_>32}", .{self.body.node_hash}) catch @panic("Error writing to card!");
                    card.labelFmt(56, 6, "{d:_>20}", .{self.body.leaf_count}) catch @panic("Error writing to card!");
                    card.labelFmt(56, 7, "{d:_>20}", .{self.body.segment_count}) catch @panic("Error writing to card!");

                    card.labelFmt(35, 13,  "{d:_>3}",  .{self.start_depth}) catch @panic("Error writing to card!");
                    card.labelFmt(66, 13,  "{d:_>3}",  .{self.branch_depth}) catch @panic("Error writing to card!");
                    card.labelFmt( 9, 13, "{s:_>10}", .{std.fmt.fmtSliceHexUpper(&self.infix)}) catch @panic("Error writing to card!");
                    card.labelFmt( 9, 15, "{s:_>64}", .{std.fmt.fmtSliceHexUpper(&self.body.infix)}) catch @panic("Error writing to card!");

                    card.label( 3, 22, if (bucket_count >= 1) "█" else "░") catch @panic("Error writing to card!");
                    card.label( 3, 23, if (bucket_count >= 2) "█" else "░") catch @panic("Error writing to card!");
                    card.label( 3, 24, if (bucket_count >= 4) "█"**2 else "░"**2) catch @panic("Error writing to card!");
                    card.label( 3, 25, if (bucket_count >= 8) "█"**4 else "░"**4) catch @panic("Error writing to card!");
                    card.label( 3, 26, if (bucket_count >= 16) "█"**8 else "░"**8) catch @panic("Error writing to card!");
                    card.label( 3, 27, if (bucket_count >= 32) "█"**16 else "░"**16) catch @panic("Error writing to card!");
                    card.label( 3, 28, if (bucket_count >= 64) "█"**32 else "░"**32) catch @panic("Error writing to card!");

                    var seq_child_count: usize = 0;
                    var rand_child_count: usize = 0;   
                    var seq_miss_child_count: usize = 0;                 
                    var rand_miss_child_count: usize = 0;   

                    const children_map_start_y: usize = 21;
                    const children_map_left_start_x: usize = 41;
                    const children_map_right_start_x: usize = 62;

                    var byte_key: usize = 0;
                    while(byte_key < 256):(byte_key += 1) {
                        const byte_key_u8 = @truncate(u8, byte_key);

                        const x: usize = if(byte_key < 128) (byte_key & 0b1111) + children_map_left_start_x
                                         else (byte_key & 0b1111) + children_map_right_start_x;
                        const y: usize = ((byte_key >> 4) & 0b111) + children_map_start_y;

                        if (!self.body.child_set.isSet(byte_key_u8)) {
                            card.at(x, y).* = ' ';
                            continue;
                        }

                        const rand_hash_used = self.body.rand_hash_used.isSet(byte_key_u8);

                        const bucket_index = hashByteKey(rand_hash_used, bucket_count, byte_key_u8);
                        const entry_was_found = !self.body.buckets[bucket_index].get(self.branch_depth, byte_key_u8).isNone();

                        if (entry_was_found) {
                            if (rand_hash_used) {
                                    rand_child_count += 1;
                                    card.at(x, y).* = '◆';
                                } else {
                                    seq_child_count += 1;
                                    card.at(x, y).* = '●';
                                }
                        } else {
                            if (rand_hash_used) {
                                card.at(x, y).* = '◇';
                                rand_miss_child_count += 1;
                             } else {
                                card.at(x, y).* = '○';
                                seq_miss_child_count += 1;
                             }
                        }
                    }

                    card.labelFmt(30, 21,  "{d:_>3}",  .{seq_child_count}) catch @panic("Error writing to card!");
                    card.labelFmt(30, 22,  "{d:_>3}",  .{rand_child_count}) catch @panic("Error writing to card!");
                    card.labelFmt(30, 23,  "{d:_>3}",  .{seq_miss_child_count}) catch @panic("Error writing to card!");
                    card.labelFmt(30, 24,  "{d:_>3}",  .{rand_miss_child_count}) catch @panic("Error writing to card!");

                    try writer.print("{s}\n", .{card});
                }

                pub fn diagnostics(self: Head) bool {
                    var has_errors = false;

                    //Infix start consitency.
                    const peek_branch = self.peek(self.start_depth).?;
                    const unknown_branch = @bitCast(Node, self).unknown.branch;
                    if(peek_branch != unknown_branch) {
                        has_errors = true;
                        std.debug.print("Diagnostics - Inconsistent infix start; peek():{x} != unknown.branch:{x}\n", .{peek_branch,  unknown_branch});
                    }

                    //Child depth consistency.
                    var child_iterator = self.body.child_set;
                    while (child_iterator.drainNextAscending()) |child_byte_key| {
                        const child = self.getBranch(@intCast(u8, child_byte_key));
                        const child_start = child.start();
                        if(self.branch_depth != child_start) {
                            has_errors = true;
                            std.debug.print("Diagnostics - Inconsistent child dept for {s}; branch_depth:{d} != child.start():{d}\n", .{child.unknown.tag, self.branch_depth,  child_start });
                        }
                    }

                    return has_errors;
                }

                pub fn init(start_depth: u8, branch_depth: u8, key: [key_length]u8, allocator: std.mem.Allocator) allocError!Head {
                    const allocation = try allocator.alignedAlloc(u8, cache_line_size, @sizeOf(Body));
                    const new_body = std.mem.bytesAsValue(Body, allocation[0..@sizeOf(Body)]);
                    new_body.* = Body{};

                    var new_head = Head{ .start_depth = start_depth, .branch_depth = branch_depth, .body = new_body };

                    copy_start(new_head.infix[0..], key[0..], start_depth);
                    copy_end(new_body.infix[0..], key[0..], branch_depth);

                    return new_head;
                }

                pub fn initAt(self: Head, start_depth: u8, key: [key_length]u8) Node {
                    assert(start_depth <= self.branch_depth);
                    assert(start_depth + infix_len >= self.branch_depth);

                    var new_head = self;
                    new_head.start_depth = start_depth;
                    for(new_head.infix) |*v, i| {
                        const depth = @intCast(u8, start_depth + i);
                        if(depth < self.start_depth) {
                            v.* = key[depth];
                            continue;
                        }
                        if(self.branch_depth <= depth) break;
                        v.* = self.peek(depth).?;
                    }
                    return @bitCast(Node, new_head);
                }

                pub fn ref(self: Head, allocator: std.mem.Allocator) allocError!?Node {
                    if (self.body.ref_count == std.math.maxInt(@TypeOf(self.body.ref_count))) {
                        // Reference counter exhausted, we need to make a copy of this node.
                        return @bitCast(Node, try self.copy(allocator));
                    } else {
                        self.body.ref_count += 1;
                        return null;
                    }
                }

                pub fn rel(self: Head, allocator: std.mem.Allocator) void {
                    self.body.ref_count -= 1;
                    if (self.body.ref_count == 0) {
                        defer allocator.free(std.mem.asBytes(self.body));
                        var child_iterator = self.body.child_set;
                        while (child_iterator.drainNextAscending()) |child_byte_key| {
                            self.getBranch(@intCast(u8, child_byte_key)).rel(allocator);
                        }
                    }
                }

                pub fn count(self: Head) u64 {
                    return self.body.leaf_count;
                }

                pub fn segmentCount(self: Head, depth: u8) u32 {
                    if (segment_lut[depth] == segment_lut[self.branch_depth]) {
                        return self.body.segment_count;
                    } else {
                        return 1;
                    }
                }

                pub fn hash(self: Head, prefix: [key_length]u8) Hash {
                    _ = prefix;
                    return self.body.node_hash;
                }

                pub fn range(self: Head) u8 {
                    return self.branch_depth - @min(self.branch_depth, infix_len);
                }

                pub fn peek(self: Head, at_depth: u8) ?u8 {
                    if (at_depth < self.start_depth or self.branch_depth <= at_depth) return null;
                    if (at_depth < self.start_depth + head_infix_len)
                        return self.infix[index_start(self.start_depth, at_depth)];
                    return self.body.infix[index_end(body_infix_len, self.branch_depth, at_depth)];    
                }

                pub fn propose(self: Head, at_depth: u8, result_set: *ByteBitset) void {
                    if (at_depth == self.branch_depth) {
                        result_set.* = self.body.child_set;
                        return;
                    }

                    result_set.unsetAll();
                    if (self.peek(at_depth)) |byte_key| {
                        result_set.set(byte_key);
                        return;
                    }
                }

                pub fn put(self: Head, start_depth: u8, key: [key_length]u8, value: Value, parent_single_owner: bool, allocator: std.mem.Allocator) allocError!Node {
                    const single_owner = parent_single_owner and self.body.ref_count == 1;

                    var branch_depth = start_depth;
                    while (branch_depth < self.branch_depth) : (branch_depth += 1) {
                        if (key[branch_depth] != self.peek(branch_depth).?) break;
                    } else {
                        // The entire compressed infix above this node matched with the key.
                        const byte_key = key[branch_depth];
                        if (self.hasBranch(byte_key)) {
                            // The node already has a child branch with the same byte byte_key as the one in the key.
                            const old_child = self.getBranch(byte_key);
                            const old_child_hash = old_child.hash(key);
                            const old_child_leaf_count = old_child.count();
                            const old_child_segment_count = old_child.segmentCount(branch_depth);
                            const new_child = try old_child.put(branch_depth, key, value, single_owner, allocator);
                            const new_child_hash = new_child.hash(key);
                            if (old_child_hash.equal(new_child_hash)) {
                                return @bitCast(Node, self);
                            }
                            const new_hash = self.body.node_hash.update(old_child_hash, new_child_hash);
                            const new_leaf_count = self.body.leaf_count - old_child_leaf_count + new_child.count();
                            const new_segment_count = self.body.segment_count - old_child_segment_count + new_child.segmentCount(branch_depth);

                            var self_or_copy = self;
                            if (!single_owner) {
                                self_or_copy = try self.copy(allocator);
                                old_child.rel(allocator);
                            }
                            self_or_copy.body.node_hash = new_hash;
                            self_or_copy.body.leaf_count = new_leaf_count;
                            self_or_copy.body.segment_count = new_segment_count;

                            self_or_copy.updateBranch(new_child);
                            return @bitCast(Node, self_or_copy);
                        } else {
                            const new_child_node = try WrapInfixNode(branch_depth, key, InitLeaf(branch_depth, key, value), allocator);

                            var self_or_copy = if (single_owner) self else try self.copy(allocator);

                            var displaced = self_or_copy.createBranch(new_child_node, branch_depth, key);
                            var grown = @bitCast(Node, self_or_copy);
                            while (displaced) |entry| {
                                grown = try grown.grow(allocator);
                                displaced = grown.reinsertBranch(entry);
                            }
                            return grown;
                        }
                    }

                    const sibling_leaf_node = try WrapInfixNode(branch_depth, key, InitLeaf(branch_depth, key, value), allocator);

                    return try BranchNodeBase.initBranch(start_depth, branch_depth, key, sibling_leaf_node, self.initAt(branch_depth, key), allocator);
                }

                pub fn get(self: Head, at_depth: u8, byte_key: u8) Node {
                    if (at_depth == self.branch_depth) {
                        if (self.hasBranch(byte_key)) {
                            return self.getBranch(byte_key);
                        } else {
                            return Node{ .none = .{} };
                        }
                    }
                    if (self.peek(at_depth)) |own_key| {
                        if (own_key == byte_key) return @bitCast(Node, self);
                    }
                    return Node{ .none = .{} };
                }

                fn copy(self: Head, allocator: std.mem.Allocator) allocError!Head {
                    const allocation = try allocator.alignedAlloc(u8, cache_line_size, @sizeOf(Body));
                    const new_body = std.mem.bytesAsValue(Body, allocation[0..@sizeOf(Body)]);

                    new_body.* = self.body.*;
                    new_body.ref_count = 1;

                    var new_head = self;
                    new_head.body = new_body;

                    var child_iterator = new_body.child_set;
                    while (child_iterator.drainNextAscending()) |child_byte_key| {
                        const cast_child_byte_key = @intCast(u8, child_byte_key);
                        const child = new_head.getBranch(cast_child_byte_key);
                        const potential_child_copy = try child.ref(allocator);
                        if (potential_child_copy) |new_child| {
                            new_head.updateBranch(new_child);
                        }
                    }

                    return new_head;
                }

                fn grow(self: Head, allocator: std.mem.Allocator) allocError!Node {
                    if (bucket_count == max_bucket_count) {
                        return @bitCast(Node, self);
                    } else {
                        //std.debug.print("Grow:{*}\n {} -> {} : {} -> {} \n", .{ self.body, Head, GrownHead, @sizeOf(Body), @sizeOf(GrownHead.Body) });
                        const allocation: []align(cache_line_size) u8 = try allocator.realloc(self.body, @sizeOf(GrownHead.Body));
                        const new_body = std.mem.bytesAsValue(GrownHead.Body, allocation[0..@sizeOf(GrownHead.Body)]);
                        //std.debug.print("Growed:{*}\n", .{new_body});
                        new_body.buckets[new_body.buckets.len / 2 .. new_body.buckets.len].* = new_body.buckets[0 .. new_body.buckets.len / 2].*;
                        return @bitCast(Node, GrownHead{ .start_depth = self.start_depth, .branch_depth = self.branch_depth, .infix = self.infix, .body = new_body });
                    }
                }

                fn createBranch(self: Head, child: Node, at_depth: u8, prefix: [key_length]u8) ?Node {
                    self.body.node_hash = self.body.node_hash.combine(child.hash(prefix));
                    self.body.leaf_count += child.count();
                    self.body.segment_count += child.segmentCount(at_depth);

                    return self.reinsertBranch(child);
                }

                fn reinsertBranch(self: Head, node: Node) ?Node {
                    var byte_key = node.peek(self.branch_depth).?;
                    self.body.child_set.set(byte_key);

                    const growable = (bucket_count != max_bucket_count);
                    const base_size = (bucket_count == 1);
                    var use_rand_hash = false;
                    var entry = node;
                    var retries: usize = 0;
                    while (true) {
                        random = rand_lut[random ^ byte_key];
                        const bucket_index = hashByteKey(use_rand_hash, bucket_count, byte_key);

                        if (self.body.buckets[bucket_index].put(&self.body.rand_hash_used, bucket_count, bucket_index, entry)) {
                            self.body.rand_hash_used.setValue(byte_key, use_rand_hash);
                            return null;
                        }

                        if (base_size or retries == max_retries) {
                            return entry;
                        }

                        if (growable) {
                            retries += 1;
                            entry = self.body.buckets[bucket_index].displaceRandomly(random, entry);
                            self.body.rand_hash_used.setValue(byte_key, use_rand_hash);
                            byte_key = entry.peek(self.branch_depth).?;
                            use_rand_hash = !self.body.rand_hash_used.isSet(byte_key);
                        } else {
                            entry = self.body.buckets[bucket_index].displaceRandHashOnly(&self.body.rand_hash_used, entry);
                            self.body.rand_hash_used.setValue(byte_key, use_rand_hash);
                            byte_key = entry.peek(self.branch_depth).?;
                        }
                    }
                    unreachable;
                }

                fn hasBranch(self: Head, byte_key: u8) bool {
                    return self.body.child_set.isSet(byte_key);
                }

                // Contract: Key looked up must exist. Ensure with hasBranch.
                fn getBranch(self: Head, byte_key: u8) Node {
                    assert(self.body.child_set.isSet(byte_key));
                    const bucket_index = hashByteKey(self.body.rand_hash_used.isSet(byte_key), bucket_count, byte_key);
                    return self.body.buckets[bucket_index].get(byte_key);
                }

                fn updateBranch(self: Head, node: Node) void {
                    const byte_key = node.peek(self.branch_depth).?;
                    const bucket_index = hashByteKey(self.body.rand_hash_used.isSet(byte_key), bucket_count, byte_key);
                    _ = self.body.buckets[bucket_index].putIntoSame(node);
                }

                fn mem_info(self: Head) MemInfo {
                    const child_count = self.body.child_set.count();
                    const total_slot_count = @as(usize, bucket_count) * @as(usize, bucket_slot_count);
                    const unused_slots = total_slot_count - child_count;

                    var wasted_infix_bytes: usize = 0;
                    var child_iterator = self.body.child_set;
                    while (child_iterator.drainNextAscending()) |child_byte_key| {
                        const child = self.getBranch(@intCast(u8, child_byte_key));
                        wasted_infix_bytes += (self.branch_depth - child.range());
                    }

                    return MemInfo{ .active_memory = @sizeOf(Body), .wasted_memory = (@sizeOf(Node) * unused_slots) + wasted_infix_bytes, .passive_memory = @sizeOf(Head), .allocation_count = 1 };
                }
            };
        }

        fn WrapInfixNode(start_depth: u8, key: [key_length]u8, child: Node, allocator: std.mem.Allocator) allocError!Node {

            var branch_depth = child.start();
            
            if (branch_depth <= start_depth) {
                return child;
            }

            const child_range = @max(start_depth, child.range());

            const child_or_raised = if(child_range < branch_depth) child.initAt(child_range, key)
                                    else child;
            
            branch_depth = child_range;

            if (branch_depth == start_depth) {
                return child_or_raised;
            }

            const infix_length = branch_depth - start_depth;

            comptime var i = 2; // We need to start at two, because nodes are already 16 byte.
            inline while (i <= 4) : (i += 1) {
                if (infix_length <= InfixNode(i).infix_len) {
                    return @bitCast(Node, try InfixNode(i).init(start_depth, branch_depth, key, child_or_raised, allocator));
                }
            }

            @panic("Infix not long enough.");
        }

        fn InfixNode(comptime chunk_count: u8) type {
            return extern struct {
                const head_infix_len = node_size - (@sizeOf(NodeTag)
                                              + @sizeOf(u8)
                                              + @sizeOf(u8)
                                              + @sizeOf(usize));
                const body_infix_len = (chunk_count * infix_chunk_size)
                                    - (node_size + @sizeOf(u8));
                const infix_len = head_infix_len + body_infix_len;

                tag: NodeTag = Node.infixNodeTag(chunk_count),
                infix: [head_infix_len]u8 = [_]u8{0} ** head_infix_len,

                start_depth: u8,
                branch_depth: u8,

                body: *Body,

                const Head = @This();
                const Body = extern struct {
                    child: Node = Node{ .none = .{} },
                    ref_count: u8 = 1,
                    infix: [body_infix_len]u8 = undefined,
                };

                pub fn diagnostics(self: Head) bool {
                    var has_errors = false;

                    //Infix start consitency.
                    const peek_branch = self.peek(self.start_depth).?;
                    const unknown_branch = @bitCast(Node, self).unknown.branch;
                    if(peek_branch != unknown_branch) {
                        has_errors = true;
                        std.debug.print("Diagnostics - Inconsistent infix start; peek():{x} != unknown.branch:{x}\n", .{peek_branch,  unknown_branch});
                    }

                    //Child depth consistency.
                    const child = self.body.child;
                    const child_start = child.start();
                    if(self.branch_depth != child_start) {
                        has_errors = true;
                        std.debug.print("Diagnostics - Inconsistent child dept for {s}; branch_depth:{d} != child.start():{d}\n", .{child.unknown.tag, self.branch_depth,  child_start });
                    }

                    return has_errors;
                }

                pub fn init(start_depth: u8, branch_depth: u8, key: [key_length]u8, child: Node, allocator: std.mem.Allocator) allocError!Head {
                    const allocation = try allocator.alignedAlloc(u8, @alignOf(Body), @sizeOf(Body));
                    const new_body = std.mem.bytesAsValue(Body, allocation[0..@sizeOf(Body)]);

                    new_body.* = Body{ .child = child };
                    var new_head = Head{ .start_depth = start_depth, .branch_depth = branch_depth, .body = new_body };

                    copy_start(new_head.infix[0..], key[0..], start_depth);
                    copy_end(new_body.infix[0..], key[0..], branch_depth);

                    return new_head;
                }

                pub fn initAt(self: Head, start_depth: u8, key: [key_length]u8) Node {
                    assert(start_depth <= self.branch_depth);
                    assert(start_depth + infix_len >= self.branch_depth);

                    var new_head = self;
                    new_head.start_depth = start_depth;
                    for(new_head.infix) |*v, i| {
                        const depth = @intCast(u8, start_depth + i);
                        if(depth < self.start_depth) {
                            v.* = key[depth];
                            continue;
                        }
                        if(self.branch_depth <= depth) break;
                        v.* = self.peek(depth).?;
                    }
                    return @bitCast(Node, new_head);
                }
                
                pub fn format(
                    self: Head,
                    comptime fmt: []const u8,
                    options: std.fmt.FormatOptions,
                    writer: anytype,
                ) !void {
                    _ = fmt;
                    _ = options;
                    try writer.print("{*} �{d}:\n", .{ self.body, self.body.ref_count });
                    try writer.print("  infixes: {[2]s:_>[0]} > {[3]s:_>[1]}\n", .{ head_infix_len, body_infix_len, std.fmt.fmtSliceHexUpper(&self.infix), std.fmt.fmtSliceHexUpper(&self.body.infix) });
                }

                fn copy(self: Head, allocator: std.mem.Allocator) allocError!Head {
                    const allocation = try allocator.alignedAlloc(u8, @alignOf(Body), @sizeOf(Body));
                    const new_body = std.mem.bytesAsValue(Body, allocation[0..@sizeOf(Body)]);
                    new_body.* = self.body.*;
                    new_body.ref_count = 1;

                    if (try new_body.child.ref(allocator)) |new_child| {
                        new_body.child = new_child;
                    }

                    return Head{ .start_depth = self.start_depth, .branch_depth = self.branch_depth, .infix = self.infix, .body = new_body };
                }

                pub fn ref(self: Head, allocator: std.mem.Allocator) allocError!?Node {
                    if (self.body.ref_count == std.math.maxInt(@TypeOf(self.body.ref_count))) {
                        // Reference counter exhausted, we need to make a copy of this node.
                        return @bitCast(Node, try self.copy(allocator));
                    } else {
                        self.body.ref_count += 1;
                        return null;
                    }
                }

                pub fn rel(self: Head, allocator: std.mem.Allocator) void {
                    self.body.ref_count -= 1;
                    if (self.body.ref_count == 0) {
                        self.body.child.rel(allocator);
                        allocator.free(std.mem.asBytes(self.body));
                    }
                }

                pub fn count(self: Head) u64 {
                    return self.body.child.count();
                }

                pub fn segmentCount(self: Head, depth: u8) u32 {
                    if (segment_lut[depth] == segment_lut[self.branch_depth]) {
                        return self.body.child.segmentCount(depth);
                    } else {
                        return 1;
                    }
                }

                pub fn hash(self: Head, prefix: [key_length]u8) Hash {
                    var key = prefix;

                    var i = self.start_depth;
                    while(i < self.branch_depth):(i += 1) {
                        key[i] = self.peek(i).?;
                    }

                    return self.body.child.hash(key);
                }

                pub fn range(self: Head) u8 {
                    return self.branch_depth - @min(self.branch_depth, infix_len);
                }

                pub fn peek(self: Head, at_depth: u8) ?u8 {
                    if (at_depth < self.start_depth or self.branch_depth <= at_depth) return null;
                    if (at_depth < self.start_depth + head_infix_len)
                        return self.infix[index_start(self.start_depth, at_depth)];
                    return self.body.infix[index_end(body_infix_len, self.branch_depth, at_depth)];
                }

                pub fn propose(self: Head, at_depth: u8, result_set: *ByteBitset) void {
                    result_set.unsetAll();
                    if (at_depth == self.branch_depth) {
                        // We know that the child has its range maxed out otherwise
                        // there wouldn't be a infix node, so this access is easy and
                        // also cheap.
                        result_set.set(self.body.child.peek(at_depth).?);
                        return;
                    }

                    if (self.peek(at_depth)) |byte_key| {
                        result_set.set(byte_key);
                        return;
                    }
                }

                pub fn get(self: Head, at_depth: u8, key: u8) Node {
                    if (at_depth == self.branch_depth) {
                        if (self.body.child.peek(at_depth).? == key) {
                            return self.body.child;
                        } else {
                            return Node{ .none = .{} };
                        }
                    }
                    if (self.peek(at_depth)) |own_key| {
                        if (own_key == key) {
                            return @bitCast(Node, self);
                        }
                    }

                    return Node{ .none = .{} };
                }

                pub fn put(self: Head, start_depth: u8, key: [key_length]u8, value: Value, parent_single_owner: bool, allocator: std.mem.Allocator) allocError!Node {
                    const single_owner = parent_single_owner and self.body.ref_count == 1;

                    var branch_depth = start_depth;
                    while (branch_depth < self.branch_depth) : (branch_depth += 1) {
                        if (key[branch_depth] != (self.peek(branch_depth).?)) break;
                    } else {
                        // The entire infix matched with the key, i.e. branch_depth == self.branch_depth.
                        const old_child = self.body.child;
                        const old_child_hash = old_child.hash(key);
                        const new_child = try old_child.put(branch_depth, key, value, single_owner, allocator);
                        const new_child_hash = new_child.hash(key);
                        if (Hash.equal(old_child_hash, new_child_hash)) {
                            return @bitCast(Node, self);
                        }

                        // TODO: this is packed with broken edge cases...
                        if (new_child.range() != (self.branch_depth)) {
                            const new_node = try WrapInfixNode(start_depth, key, new_child, allocator);
                            if (single_owner) {
                                allocator.free(std.mem.asBytes(self.body));
                            }
                            return new_node;
                        }

                        var self_or_copy = self;
                        if (!single_owner) {
                            self_or_copy = try self.copy(allocator);
                            old_child.rel(allocator);
                        }
                        self_or_copy.body.child = new_child;
                        return @bitCast(Node, self_or_copy);
                    }

                    const sibling_leaf_node = try WrapInfixNode(branch_depth, key, InitLeaf(branch_depth, key, value), allocator);

                    const branch_node_above = try BranchNodeBase.initBranch(start_depth, branch_depth, key, sibling_leaf_node, self.initAt(branch_depth, key), allocator);

                    return try WrapInfixNode(start_depth, key, branch_node_above, allocator);
                }

                fn mem_info(self: Head) MemInfo {
                    _ = self;

                    return MemInfo{
                        .active_memory = @sizeOf(Body),
                        .wasted_memory = 0, // TODO this could be more accurate with parent depth info.
                        .passive_memory = @sizeOf(Head),
                        .allocation_count = 1,
                    };
                }
            };
        }

        inline fn InitLeaf(start_depth: u8, key: [key_length]u8, value: Value) Node {
            return @bitCast(Node, LeafNode.init(start_depth, key, value));
        }

        const LeafNode = extern struct {
            pub const infix_len = node_size
                                    - (@sizeOf(NodeTag)
                                     + @sizeOf(u8)
                                     + @sizeOf(Value));
            const max_start_depth = key_length - infix_len;

            tag: NodeTag = .leaf,
            /// The key stored in this entry.
            infix: [infix_len]u8 = [_]u8{0} ** infix_len,
            start_depth: u8,
            value: Value,

            const Head = @This();

            pub fn diagnostics(self: Head) bool {
                var has_errors = false;

                //Infix start consitency.
                const peek_branch = self.peek(self.start_depth).?;
                const unknown_branch = @bitCast(Node, self).unknown.branch;
                if(peek_branch != unknown_branch) {
                    has_errors = true;
                    std.debug.print("Diagnostics - Inconsistent infix start; peek():{x} != unknown.branch:{x}\n", .{peek_branch,  unknown_branch});
                }

                return has_errors;
            }

            pub fn init(start_depth: u8, key: [key_length]u8, value: Value) Head {
                const actual_start_depth = @max(start_depth, max_start_depth);

                var new_head = Head{ .start_depth = actual_start_depth, .value = value };

                copy_start(&new_head.infix, &key, actual_start_depth);

                return new_head;
            }

            pub fn initAt(self: Head, start_depth: u8, key: [key_length]u8) Node {
                assert(start_depth <= key_length);
                assert(start_depth + infix_len >= key_length);

                var new_head = self;
                new_head.start_depth = start_depth;
                for(new_head.infix) |*v, i| {
                    const depth = @intCast(u8, start_depth + i);
                    if(depth < self.start_depth) {
                        v.* = key[depth];
                        continue;
                    }
                    if(key_length <= depth) break;
                    v.* = self.peek(depth).?;
                }
                return @bitCast(Node, new_head);
            }

            pub fn format(
                self: Head,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = fmt;
                _ = options;
                try writer.print("Twig infix: {[1]s:_>[0]}\n", .{ infix_len, std.fmt.fmtSliceHexUpper(&self.infix) });
            }

            pub fn ref(self: Head, allocator: std.mem.Allocator) allocError!?Node {
                _ = self;
                _ = allocator;
                return null;
            }

            pub fn rel(self: Head, allocator: std.mem.Allocator) void {
                _ = self;
                _ = allocator;
            }

            pub fn count(self: Head) u64 {
                _ = self;
                return 1;
            }

            pub fn segmentCount(self: Head, depth: u8) u32 {
                _ = self;
                _ = depth;
                return 1;
            }

            pub fn hash(self: Head, prefix: [key_length]u8) Hash {
                var key = prefix;

                var i = self.start_depth;
                while(i < key_length):(i += 1) {
                    key[i] = self.peek(i).?;
                }

                return Hash.init(&key);
            }

            pub fn range(self: Head) u8 {
                _ = self;
                return key_length - infix_len;
            }

            pub fn peek(self: Head, at_depth: u8) ?u8 {
                if (key_length <= at_depth) return null;
                return self.infix[index_start(self.start_depth, at_depth)];
            }

            pub fn propose(self: Head, at_depth: u8, result_set: *ByteBitset) void {
                result_set.unsetAll();
                if (self.peek(at_depth)) |byte_key| {
                    result_set.set(byte_key);
                    return;
                }
            }

            pub fn get(self: Head, at_depth: u8, key: u8) Node {
                if (self.peek(at_depth)) |own_key| {
                    if (own_key == key) return @bitCast(Node, self);
                }
                return Node{ .none = .{} };
            }

            pub fn put(self: Head, start_depth: u8, key: [key_length]u8, value: Value, single_owner: bool, allocator: std.mem.Allocator) allocError!Node {
                _ = single_owner;

                var branch_depth = start_depth;
                while (branch_depth < key_length) : (branch_depth += 1) {
                    if (key[branch_depth] != (self.peek(branch_depth).?)) break;
                } else {
                    return @bitCast(Node, self);
                }

                const sibling_leaf_node = InitLeaf(branch_depth, key, value);

                return try BranchNodeBase.initBranch(start_depth, branch_depth, key, sibling_leaf_node, self.initAt(branch_depth, key), allocator);
            }

            fn mem_info(self: Head) MemInfo {
                _ = self;

                return MemInfo{
                    .active_memory = 0,
                    .wasted_memory = 0, // TODO this could be more accurate with parent depth info.
                    .passive_memory = @sizeOf(Head),
                    .allocation_count = 0,
                };
            }
        };

        pub const Tree = struct {
            child: Node = Node{ .none = .{} },

            const NodeIterator = struct {
                start_points: ByteBitset = ByteBitset.initEmpty(),
                path: [key_length]Node = [_]Node{Node{ .none = .{} }} ** key_length,
                key: [key_length]u8 = [_]u8{0} ** key_length,
                branch_state: [key_length]ByteBitset = [_]ByteBitset{ByteBitset.initEmpty()} ** key_length,

                const IterationResult = struct {
                    node: Node,
                    start_depth: u8,
                    key: [key_length]u8,
                };

                pub fn next(self: *NodeIterator) ?IterationResult {
                    var start_depth = self.start_points.findLastSet() orelse return null;
                    var node = self.path[start_depth];

                    var branch_depth = start_depth;

                    infix: while (branch_depth < key_length) : (branch_depth += 1) {
                        self.key[branch_depth] = node.peek(branch_depth) orelse break :infix;
                    } else {
                        var exhausted_depth = self.start_points.drainNextDescending().?;
                        while (self.start_points.findLastSet()) |parent_depth| {
                            var branches = &self.branch_state[exhausted_depth];
                            if (branches.drainNextAscending()) |branch_key| {
                                self.start_points.set(exhausted_depth);
                                self.path[exhausted_depth] = self.path[parent_depth].get(exhausted_depth, branch_key);
                                assert(self.path[exhausted_depth].unknown.tag != .none);
                                break;
                            } else {
                                exhausted_depth = self.start_points.drainNextDescending().?;
                            }
                        }
                        return IterationResult{ .start_depth = start_depth, .node = node, .key = self.key };
                    }

                    var branches = &self.branch_state[branch_depth];
                    node.propose(branch_depth, branches);

                    const branch_key = branches.drainNextAscending().?;
                    self.key[branch_depth] = branch_key;
                    self.path[branch_depth] = node.get(branch_depth, branch_key);

                    self.start_points.set(branch_depth);
                    return IterationResult{ .start_depth = start_depth, .node = node, .key = self.key };
                }
            };

            pub fn nodes(self: *const Tree) NodeIterator {
                var iterator = NodeIterator{};
                if (self.child.unknown.tag != .none) {
                    iterator.start_points.set(0);
                    iterator.path[0] = self.child;
                }
                return iterator;
            }

            pub const Cursor = struct {
                depth: u8 = 0,
                path: [key_length + 1]Node = [_]Node{Node{ .none = .{} }} ** (key_length + 1),

                pub fn init(tree: *const Tree) @This() {
                    var self = @This(){};
                    self.path[0] = tree.child;
                    return self;
                }

                // Interface API >>>

                pub fn peek(self: *Cursor) ?u8 {
                    //std.debug.print("peek()@{d}\n", .{self.depth});
                    return self.path[self.depth].peek(self.depth);
                }

                pub fn propose(self: *Cursor, bitset: *ByteBitset) void {
                    //std.debug.print("propose()@{d}\n", .{self.depth});
                    self.path[self.depth].propose(self.depth, bitset);
                }

                pub fn pop(self: *Cursor) void {
                    //std.debug.print("pop()@{d}\n", .{self.depth});
                    self.depth -= 1;
                }

                pub fn push(self: *Cursor, byte: u8) void {
                    //std.debug.print("push({d})@{d}\n", .{byte, self.depth});
                    self.path[self.depth + 1] = self.path[self.depth].get(self.depth, byte);
                    self.depth += 1;
                }

                pub fn segmentCount(self: *Cursor) u32 {
                    return self.path[self.depth].segmentCount(self.depth);
                }

                // <<< Interface API

                pub fn node(self: *Cursor) Node {
                    return self.path[self.depth];
                }

                pub fn iterate(self: Cursor) CursorIterator(Cursor, key_length) {
                    return CursorIterator(Cursor, key_length).init(self);
                }
            };

            pub fn cursor(self: *const Tree) Cursor {
                return Cursor.init(self);
            }

            pub fn init() Tree {
                return Tree{};
            }

            pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
                self.child.rel(allocator);
            }

            pub fn branch(self: *Tree, allocator: std.mem.Allocator) allocError!Tree {
                return Tree{ .child = (try self.child.ref(allocator)) orelse self.child };
            }

            pub fn format(
                self: Tree,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = fmt;
                _ = options;

                var card = (Card.init(std.heap.c_allocator) catch @panic("Failed to allocate card!")).from(
\\┌────────────────────────────────────────────────────────────────────────────────┐
\\│ Tree                                                                           │
\\│━━━━━━                                                                          │
\\│        Count: ░░░░░░░░░░░░░░░░      Memory (keys): ░░░░░░░░░░░░░░░░            │
\\│   Node Count: ░░░░░░░░░░░░░░░░    Memory (actual): ░░░░░░░░░░░░░░░░            │
\\│  Alloc Count: ░░░░░░░░░░░░░░░░   Overhead (ratio): ░░░░░░░░░░░░░░░░            │
\\│                                                                                │
\\│  Node Distribution                                                             │
\\│ ═══════════════════                                                            │
\\│                                                                                │
\\│                                                                                │
\\│                           branch1 ░░░░░░░░░░░░░░░░                             │
\\│                           branch2 ░░░░░░░░░░░░░░░░                             │
\\│                           branch4 ░░░░░░░░░░░░░░░░                             │
\\│                           branch8 ░░░░░░░░░░░░░░░░                             │
\\│                          branch16 ░░░░░░░░░░░░░░░░  infix2 ░░░░░░░░░░░░░░░░    │
\\│   none ░░░░░░░░░░░░░░░░  branch32 ░░░░░░░░░░░░░░░░  infix3 ░░░░░░░░░░░░░░░░    │
\\│   leaf ░░░░░░░░░░░░░░░░  branch64 ░░░░░░░░░░░░░░░░  infix4 ░░░░░░░░░░░░░░░░    │
\\│                                                                                │
\\│  Density                                                                       │
\\│ ═════════                                                                      │
\\│                                                                                │
\\│       ┐░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░        │
\\│       │░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░        │
\\│       │░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░        │
\\│       │░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░        │
\\│       │░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░        │
\\│       │░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░        │
\\│       │░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░        │
\\│       ┘░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░        │
\\│       0┌──────────────┬───────────────┬───────────────┬───────────────┐63      │
\\└────────────────────────────────────────────────────────────────────────────────┘
                ) catch unreachable;
                defer card.deinit();

                const item_count = self.count();

                var node_count: u64 = 0;

                var mem_keys: u64 = item_count * key_length;

                var none_count: u64 = 0;
                var leaf_count: u64 = 0;
                var branch_1_count: u64 = 0;
                var branch_2_count: u64 = 0;
                var branch_4_count: u64 = 0;
                var branch_8_count: u64 = 0;
                var branch_16_count: u64 = 0;
                var branch_32_count: u64 = 0;
                var branch_64_count: u64 = 0;
                var infix_2_count: u64 = 0;
                var infix_3_count: u64 = 0;
                var infix_4_count: u64 = 0;

                var density_at_depth: [key_length]u64 = [_]u64{0} ** key_length;

                var node_iter = self.nodes();
                while (node_iter.next()) |res| {
                    node_count += 1;
                    density_at_depth[res.start_depth] += 1;
                    switch (res.node.unknown.tag) {
                        .none => {none_count += 1;},
                        .leaf => {leaf_count += 1;},
                        .branch1 => {branch_1_count += 1;},
                        .branch2 => {branch_2_count += 1;},
                        .branch4 => {branch_4_count += 1;},
                        .branch8 => {branch_8_count += 1;},
                        .branch16 => {branch_16_count += 1;},
                        .branch32 => {branch_32_count += 1;},
                        .branch64 => {branch_64_count += 1;},
                        .infix2 => {infix_2_count += 1;},
                        .infix3 => {infix_3_count += 1;},
                        .infix4 => {infix_4_count += 1;},
                    }
                }

                var max_density: u64 = 0;
                for (density_at_depth) |density| {
                    max_density = std.math.max(max_density, density);
                }

                const mem_info_data = self.mem_info(); 

                const mem_overhead: f64 = (@intToFloat(f64, mem_info_data.active_memory)
                                        - @intToFloat(f64, mem_keys))
                                        / @intToFloat(f64, mem_keys);

                card.labelFmt(15, 2, "{d:_>16}", .{ item_count }) catch @panic("Error printing card!");
                card.labelFmt(15, 3, "{d:_>16}", .{node_count}) catch @panic("Error printing card!");
                card.labelFmt(15, 4, "{d:_>16}", .{mem_info_data.allocation_count}) catch @panic("Error printing card!");

                card.labelFmt(52, 2, "{d:_>16}", .{mem_keys}) catch @panic("Error printing card!");
                card.labelFmt(52, 3, "{d:_>16}", .{mem_info_data.active_memory}) catch @panic("Error printing card!");
                card.labelFmt(52, 4, "{d:_>16}", .{mem_overhead}) catch @panic("Error printing card!");

                card.labelFmt(8, 15, "{d:_>16}", .{none_count}) catch @panic("Error printing card!");
                card.labelFmt(8, 16, "{d:_>16}", .{leaf_count}) catch @panic("Error printing card!");

                card.labelFmt(35, 10, "{d:_>16}", .{branch_1_count}) catch @panic("Error printing card!");
                card.labelFmt(35, 11, "{d:_>16}", .{branch_2_count}) catch @panic("Error printing card!");
                card.labelFmt(35, 12, "{d:_>16}", .{branch_4_count}) catch @panic("Error printing card!");
                card.labelFmt(35, 13, "{d:_>16}", .{branch_8_count}) catch @panic("Error printing card!");
                card.labelFmt(35, 14, "{d:_>16}", .{branch_16_count}) catch @panic("Error printing card!");
                card.labelFmt(35, 15, "{d:_>16}", .{branch_32_count}) catch @panic("Error printing card!");
                card.labelFmt(35, 16, "{d:_>16}", .{branch_64_count}) catch @panic("Error printing card!");

                card.labelFmt(60, 13, "{d:_>16}", .{infix_2_count}) catch @panic("Error printing card!");
                card.labelFmt(60, 14, "{d:_>16}", .{infix_3_count}) catch @panic("Error printing card!");
                card.labelFmt(60, 15, "{d:_>16}", .{infix_4_count}) catch @panic("Error printing card!");

                const chart_start_x = 8;
                const chart_start_y = 21;
                const chart_width = 64;
                const chart_height = 8;

                var x: usize = 0;
                while(x < chart_width):(x += 1) {
                    var y: usize = 0;
                    while(y < chart_height):(y += 1) {
                        const density = @intToFloat(f64, density_at_depth[x]);
                        const norm_density = density / @intToFloat(f64, max_density);
                        const is_marked = norm_density > (@intToFloat(f64, (7 - y)) * (1.0 / 8.0));

                        card.at(chart_start_x + x, chart_start_y + y).* = if (is_marked) '█' else ' ';
                    }
                }

                try writer.print("{s}\n", .{card});
            }

            pub fn count(self: *const Tree) u64 {
                return self.child.count();
            }

            pub fn put(self: *Tree, key: [key_length]u8, value: Value, allocator: std.mem.Allocator) allocError!void {
                if (self.child.isNone()) {
                    self.child = try WrapInfixNode(0, key, InitLeaf(0, key, value), allocator);
                } else {
                    self.child = try self.child.put(0, key, value, true, allocator);
                }
            }
            
            pub fn get(self: *Tree, key: [key_length]u8) Value {
              var node = self.child;
              var depth: u8 = 0; 
              while (!node.isNone()) {
                node = node.get(depth, key[depth]);
                if(depth == (key_length - 1)) return node.getValue();
                depth += 1;
              }
              return null;
            }

            pub fn isEmpty(self: *Tree) bool {
                return self.child.isNone();
            }

            pub fn isEqual(self: *Tree, other: *Tree) bool {
                return self.child.hash(undefined).equal(other.child.hash(undefined));
            }

            pub fn mem_info(self: *const Tree) MemInfo {
                var total = MemInfo{ .active_memory = @sizeOf(Tree), .wasted_memory = 0, .passive_memory = 0, .allocation_count = 0 };

                var node_iter = self.nodes();
                while (node_iter.next()) |res| {
                    total = total.combine(res.node.mem_info());
                }

                return total;
            }

            fn recursiveIsSubsetOf(leftNode: Node, rightNode: Node, initial_depth: u8, prefix: [key_length]u8) bool {
                if (leftNode.hash(prefix).equal(rightNode.hash(prefix))) return true;

                const max_depth = std.math.min(leftNode.coveredDepth(), rightNode.coveredDepth());
                var depth = initial_depth;
                while (depth < max_depth):(depth += 1) {
                    const left_peek = leftNode.peek(depth);
                    const right_peek = rightNode.peek(depth);
                    if (left_peek != right_peek) break;
                    prefix[depth] = left_peek;
                }
                if (depth == key_length) return true;

                const left_childbits: ByteBitset = undefined;
                const right_childbits: ByteBitset = undefined;
                const intersect_childbits: ByteBitset = undefined;

                leftNode.propose(depth, &left_childbits);
                rightNode.propose(depth, &right_childbits);

                intersect_childbits.setIntersect(left_childbits, right_childbits);
                // The left _only_ child bits.
                left_childbits.setSubtract(left_childbits, intersect_childbits);

                // The existence of children that only exist in the left node,
                // is a witness that prooves that there is no subset relationship.
                if (!left_childbits.isEmpty()) return false;

                while (intersect_childbits.drainNextAscending()) | index | {
                    const left_child = leftNode.get(depth, index);
                    const right_child = rightNode.get(depth, index);
                    prefix[depth] = index;
                    if (!recursiveIsSubsetOf(left_child, right_child, depth + 1, prefix)) {
                        return false;
                    }
                }

                return true;
            }

            pub fn isSubsetOf(self: *const Tree, other: *const Tree ) bool {
                return self.child.isNone() or (!other.child.isNone() and recursiveIsSubsetOf(self.child, other.child, 0, undefined));
            }

            fn recursiveIsIntersecting(leftNode: Node, rightNode: Node, initial_depth: u8, prefix: [key_length]u8) bool {
                if (leftNode.hash(prefix).equal(rightNode.hash(prefix))) return true;

                const max_depth = std.math.min(leftNode.coveredDepth(), rightNode.coveredDepth());
                var depth = initial_depth;
                while (depth < max_depth):(depth += 1) {
                    const left_peek = leftNode.peek(depth);
                    const right_peek = rightNode.peek(depth);
                    if (left_peek != right_peek) break;
                    prefix[depth] = left_peek;
                }
                if (depth == key_length) return true;

                const left_childbits: ByteBitset = undefined;
                const right_childbits: ByteBitset = undefined;
                const intersect_childbits: ByteBitset = undefined;

                leftNode.propose(depth, &left_childbits);
                rightNode.propose(depth, &right_childbits);

                intersect_childbits.setIntersect(left_childbits, right_childbits);

                while (intersect_childbits.drainNextAscending()) | index | {
                    const left_child = leftNode.get(depth, index);
                    const right_child = rightNode.get(depth, index);
                    prefix[depth] = index;
                    if (recursiveIsIntersecting(left_child, right_child, depth + 1, prefix)) {
                        return true;
                    }
                }

                return false;
            }

            pub fn isIntersecting(self: *const Tree, other: *const Tree ) bool {
                return !self.child.isNone() and
                       !other.child.isNone() and
                       recursiveIsIntersecting(self.child, other.child, 0, undefined);
            }

            fn recursiveUnion(comptime initial_node_count: usize, unioned_nodes: []Node, initial_depth: u8, prefix: *[key_length]u8, allocator: std.mem.Allocator) allocError!Node {
                const first_node = unioned_nodes[0];
                const other_nodes = unioned_nodes[1..];

                const first_node_hash = first_node.hash(prefix.*);
                
                for(other_nodes) |other_node| {
                    if (!first_node_hash.equal(other_node.hash(prefix.*))) break;
                } else {
                    return (try first_node.ref(allocator)) orelse first_node;
                }

                var max_depth = first_node.coveredDepth();
                for (other_nodes) |other_node| {
                    max_depth = std.math.min(max_depth, other_node.coveredDepth());
                }

                var depth = initial_depth;
                outer: while (depth < max_depth):(depth += 1) {
                    const first_peek = first_node.peek(depth).?;
                    for (other_nodes) |other_node| {
                        const other_peek = other_node.peek(depth).?;
                        if (first_peek != other_peek) break :outer;
                    }
                    prefix[depth] = first_peek;
                }

                if (depth == key_length) return (try first_node.ref(allocator)) orelse first_node;

                var union_childbits = ByteBitset.initEmpty(); // TODO use to allocate a better fitting branch node.

                for (unioned_nodes) |node| {
                    var node_childbits: ByteBitset = undefined;
                    node.propose(depth, &node_childbits);
                    union_childbits.setUnion(&union_childbits, &node_childbits);
                }

                var branch_node = @bitCast(Node, try BranchNodeBase.init(depth, prefix.*, allocator));

                var children: [initial_node_count]Node = undefined;
                var children_len: u8 = 0;
                while (union_childbits.drainNextAscending()) | index | {
                    children_len = 0;
                    prefix[depth] = index;

                    for (unioned_nodes) |node| {
                        const child = node.get(depth, index);
                        if(!child.isNone()) {
                            children[children_len] = child;
                            children_len += 1;
                        }
                    }

                    const union_node = try recursiveUnion(initial_node_count, children[0..children_len], depth + 1, prefix, allocator);
                    const new_child_node = try WrapInfixNode(depth, prefix.*, union_node, allocator);

                    var displaced = branch_node.createBranch(new_child_node, depth, prefix.*);
                    while (displaced) |entry| {
                        branch_node = try branch_node.grow(allocator);
                        displaced = branch_node.reinsertBranch(entry);
                    }
                }

                return branch_node;
            }

            pub fn initUnion(comptime tree_count: usize, trees: []Tree, allocator: std.mem.Allocator) allocError!Tree {
                var children: [tree_count]Node = undefined;
                var children_len: usize = 0;
                for (trees) |tree| {
                    const child = tree.child;
                    if(!child.isNone()) {
                        children[children_len] = child;
                        children_len += 1;
                    }
                }
                
                if(children_len == 0) return Tree{ .allocator = allocator };
                if(children_len == 1) return Tree{ .child = (try children[0].ref(allocator)) orelse children[0], .allocator = allocator };
                
                var prefix: [key_length]u8 = undefined;

                return Tree{ .child = try recursiveUnion(tree_count, children[0..children_len], 0, &prefix, allocator), .allocator = allocator };
            }

            // fn recursiveIntersection(comptime initial_node_count: u8, nodes: []Node, initial_depth: u8, prefix: *[key_length]u8, allocator: std.mem.Allocator) allocError!Node {
            //     const first_node = nodes[0];
            //     const other_nodes = nodes[1..];

            //     const first_node_hash = first_node.hash(prefix.*);
                
            //     for(other_nodes) |other_node| {
            //         if (!first_node_hash.equal(other_node.hash(prefix.*))) break;
            //     } else {
            //         return (try first_node.ref(allocator)) orelse first_node;
            //     }

            //     var max_depth = first_node.coveredDepth();
            //     for (other_nodes) |other_node| {
            //         max_depth = std.math.min(max_depth, other_node.coveredDepth());
            //     }

            //     var depth = initial_depth;
            //     outer: while (depth < max_depth):(depth += 1) {
            //         const first_peek = first_node.peek(depth).?;
            //         for (other_nodes) |other_node| {
            //             const other_peek = other_node.peek(depth).?;
            //             if (first_peek != other_peek) break :outer;
            //         }
            //         prefix[depth] = first_peek;
            //     }

            //     if (depth == key_length) return (try first_node.ref(allocator)) orelse first_node;

            //     var intersection_childbits = ByteBitset.initFull(); // TODO use to allocate a better fitting branch node.

            //     for (nodes) |node| {
            //         node.propose(depth, &intersection_childbits);
            //     }

            //     var intersection_count = 0;
            //     var branch_node:Node = undefined;
            //     var buffered_child: Node = undefined;

            //     var children: [initial_node_count]Node = undefined;
            //     while (intersection_childbits.drainNextAscending()) | index | {
            //         prefix[depth] = index;

            //         for (nodes) |node, i| {
            //             const child = node.get(depth, index);
            //             children[i] = child;
            //         }

            //         const intersection_node = try recursiveIntersection(initial_node_count, children[0..], depth + 1, prefix, allocator);
                    
            //         if(!intersection_node.isNone()) {
            //             const new_child_node = try WrapInfixNode(depth, prefix.*, intersection_node, allocator);
            //             switch(intersection_count) {
            //                 0 => {
            //                     buffered_child = new_child_node;                            
            //                 },
            //                 1 => {
            //                     branch_node = @bitCast(Node, try BranchNodeBase.init(depth, prefix.*, allocator));
            //                     var displaced = branch_node.createBranch(buffered_child, depth, prefix.*);
            //                     while (displaced) |entry| {
            //                         branch_node = try branch_node.grow(allocator);
            //                         displaced = branch_node.reinsertBranch(entry);
            //                     }
            //                     buffered_child = new_child_node;
            //                 },
            //                 else => {
            //                     var displaced = branch_node.createBranch(buffered_child, depth, prefix.*);
            //                     while (displaced) |entry| {
            //                         branch_node = try branch_node.grow(allocator);
            //                         displaced = branch_node.reinsertBranch(entry);
            //                     }
            //                     buffered_child = new_child_node;
            //                 }
            //             }
            //             intersection_count += 1;
            //         }
            //     }

            //     switch(intersection_count) {
            //         0 => {
            //             buffered_child = new_child_node;                            
            //         },
            //         1 => {
            //             branch_node = @bitCast(Node, try BranchNodeBase.init(depth, prefix.*, allocator));
            //             var displaced = branch_node.createBranch(buffered_child, depth, prefix.*);
            //             while (displaced) |entry| {
            //                 branch_node = try branch_node.grow(allocator);
            //                 displaced = branch_node.reinsertBranch(entry);
            //             }
            //         },
            //         else => {
            //             var displaced = branch_node.createBranch(buffered_child, depth, prefix.*);
            //             while (displaced) |entry| {
            //                 branch_node = try branch_node.grow(allocator);
            //                 displaced = branch_node.reinsertBranch(entry);
            //             }
            //         }
            //     }
            //     if(intersection_count == 0) {
            //         branch_node.rel(allocator);
            //         return Node{ .none = .{} };
            //     }

            //     if(intersection_count == 1) {
            //         const index = intersection_childbits.findFirstSet().?;
            //         prefix[depth] = index;

            //         for (nodes) |node, i| {
            //             const child = node.get(depth, index);
            //             children[i] = child;
            //         }

            //         const intersection_node = try recursiveIntersection(initial_node_count, children[0..], depth + 1, prefix, allocator);
            //         return try WrapInfixNode(depth, prefix.*, intersection_node, allocator);
            //     }


            //     return branch_node;
            // }

            // pub fn initIntersection(comptime tree_count: u8, trees: []Tree, allocator: std.mem.Allocator) allocError!Tree {
            //     var children: [tree_count]Node = undefined;
            //     for (trees) |tree, i| {
            //         children[i] = tree.child;
            //     }

            //     var prefix: [key_length]u8 = undefined;

            //     return Tree{ .child = try recursiveUnion(tree_count, children[0..], 0, &prefix, allocator), .allocator = allocator };
            // }

        //     subtract(other) {
        //     const thisNode = this.child;
        //     const otherNode = other.child;
        //     if (otherNode === null) {
        //         return new PACTTree(thisNode);
        //     }
        //     if (
        //         this.child === null ||
        //         hash_equal(this.child.hash, other.child.hash)
        //     ) {
        //         return new PACTTree();
        //     } else {
        //         return new PACTTree(_subtract(thisNode, otherNode));
        //     }
        //     }

        //     intersect(other) {
        //     const thisNode = this.child;
        //     const otherNode = other.child;

        //     if (thisNode === null || otherNode === null) {
        //         return new PACTTree(null);
        //     }
        //     if (thisNode === otherNode || hash_equal(thisNode.hash, otherNode.hash)) {
        //         return new PACTTree(otherNode);
        //     }
        //     return new PACTTree(_intersect(thisNode, otherNode));
        //     }

        //     difference(other) {
        //     const thisNode = this.child;
        //     const otherNode = other.child;

        //     if (thisNode === null) {
        //         return new PACTTree(otherNode);
        //     }
        //     if (otherNode === null) {
        //         return new PACTTree(thisNode);
        //     }
        //     if (thisNode === otherNode || hash_equal(thisNode.hash, otherNode.hash)) {
        //         return new PACTTree(null);
        //     }
        //     return new PACTTree(_difference(thisNode, otherNode));
        //     }
        };

        test "Alignment & Size" {
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ Node, @sizeOf(Node), @alignOf(Node) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNodeBase.Head, @sizeOf(BranchNodeBase.Head), @alignOf(BranchNodeBase.Head) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(2).Head, @sizeOf(BranchNode(2).Head), @alignOf(BranchNode(2).Head) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(4).Head, @sizeOf(BranchNode(4).Head), @alignOf(BranchNode(4).Head) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(8).Head, @sizeOf(BranchNode(8).Head), @alignOf(BranchNode(8).Head) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(16).Head, @sizeOf(BranchNode(16).Head), @alignOf(BranchNode(16).Head) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(32).Head, @sizeOf(BranchNode(32).Head), @alignOf(BranchNode(32).Head) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(64).Head, @sizeOf(BranchNode(64).Head), @alignOf(BranchNode(64).Head) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNodeBase.Body, @sizeOf(BranchNodeBase.Body), @alignOf(BranchNodeBase.Body) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(2).Body, @sizeOf(BranchNode(2).Body), @alignOf(BranchNode(2).Body) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(4).Body, @sizeOf(BranchNode(4).Body), @alignOf(BranchNode(4).Body) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(8).Body, @sizeOf(BranchNode(8).Body), @alignOf(BranchNode(8).Body) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(16).Body, @sizeOf(BranchNode(16).Body), @alignOf(BranchNode(16).Body) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(32).Body, @sizeOf(BranchNode(32).Body), @alignOf(BranchNode(32).Body) });
            std.debug.print("{} Size: {}, Alignment: {}\n", .{ BranchNode(64).Body, @sizeOf(BranchNode(64).Body), @alignOf(BranchNode(64).Body) });
        }
    };
}

// test "create tree" {
//     var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true, .retain_metadata = true, .safety = true }){};
//     defer _ = general_purpose_allocator.deinit();
//     const gpa = general_purpose_allocator.allocator();

//     var tree = Tree.init(gpa);
//     defer tree.deinit();
// }

// test "empty tree has count 0" {
//     var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true, .retain_metadata = true, .safety = true }){};
//     defer _ = general_purpose_allocator.deinit();
//     const gpa = general_purpose_allocator.allocator();

//     var tree = Tree.init(gpa);
//     defer tree.deinit();

//     try expectEqual(tree.count(), 0);
// }

// test "single item tree has count 1" {
//     var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true, .retain_metadata = true, .safety = true }){};
//     defer _ = general_purpose_allocator.deinit();
//     const gpa = general_purpose_allocator.allocator();

//     var tree = Tree.init(gpa);
//     defer tree.deinit();

//     const key: [key_length]u8 = [_]u8{0} ** key_length;
//     try tree.put(&key, 42);

//     try expectEqual(tree.count(), 1);
// }

// test "immutable tree fork" {
//     var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
//     defer _ = general_purpose_allocator.deinit();
//     const gpa = general_purpose_allocator.allocator();

//     var tree = Tree.init(gpa);
//     defer tree.deinit();

//     var new_tree = try tree.branch();
//     defer new_tree.deinit();

//     const key: [key_length]u8 = [_]u8{0} ** key_length;
//     try new_tree.put(&key, 42);

//     try expectEqual(tree.count(), 0);
//     try expectEqual(new_tree.count(), 1);
// }

// test "multi item tree has correct count" {
//     var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true, .retain_metadata = true, .safety = true }){};
//     defer _ = general_purpose_allocator.deinit();
//     const gpa = general_purpose_allocator.allocator();

//     const total_runs = 10;

//     var rnd = std.rand.DefaultPrng.init(0).random();

//     var tree = Tree.init(gpa);
//     defer tree.deinit();

//     var key: [key_length]u8 = undefined;

//     var i: u64 = 0;
//     while (i < total_runs) : (i += 1) {
//         try expectEqual(tree.count(), i);

//         rnd.bytes(&key);
//         try tree.put(&key, rnd.int(usize));
//         std.debug.print("Inserted {d} of {d}:{s}\n{s}\n", .{ i + 1, total_runs, std.fmt.fmtSliceHexUpper(&key), tree.child });
//     }
//     try expectEqual(tree.count(), total_runs);
// }

pub fn PaddedCursor(comptime cursor_type: type, comptime segment_size: u8) type {
    const segments = cursor_type.segments;
    return struct {
        depth: u8 = 0,
        cursor: cursor_type,

        const padded_size = segments.len * segment_size;

        pub const padding = blk: {
            var g = ByteBitset.initFull();

            var depth = 0;
            for (segments) | s | {
                const pad = segment_size - s;

                depth += pad;

                var j = pad;
                while (j < segment_size):(j += 1) {
                    g.unset(depth);
                    depth += 1;
                }
            }

            break :blk g;
        };

        pub fn init(cursor_to_pad: cursor_type) @This() {
            return @This(){.cursor = cursor_to_pad};
        }

        // Interface API >>>

        pub fn peek(self: *@This()) ?u8 {
            if (padding.isSet(self.depth)) return 0;
            return self.cursor.peek();
        }

        pub fn propose(self: *@This(), bitset: *ByteBitset) void {
            if (padding.isSet(self.depth)) {
                bitset.unsetAll();
                bitset.set(0);
            } else {
                self.cursor.propose(bitset);
            }
        }

        pub fn pop(self: *@This()) void {
            self.depth -= 1;
            if (padding.isUnset(self.depth)) {
                self.cursor.pop();
            }
        }

        pub fn push(self: *@This(), key_fragment: u8) void {
            if (padding.isUnset(self.depth)) {
                self.cursor.push(key_fragment);
            }
            self.depth += 1;
        }

        pub fn segmentCount(self: *@This()) u32 {
            return self.cursor.segmentCount();
        }

        // <<< Interface API

        pub fn iterate(self: *cursor_type) CursorIterator(@This(), padded_size) {
            return CursorIterator(@This(), padded_size).init(self);
        }
    };
}