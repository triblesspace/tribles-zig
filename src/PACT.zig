const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const ByteBitset = @import("ByteBitset.zig").ByteBitset;

const mem = std.mem;

// TODO: change hash set index to boolean or at least make set -> 1, unset -> 0

// Uninitialized memory initialized by init()
var instance_secret: [16]u8 = undefined;

pub fn init() void {
    // XXX: (crest) Should this be a deterministic pseudo-RNG seeded by a constant for reproducable tests?
    std.crypto.random.bytes(&instance_secret);
}

const Hash = struct {
    data: [16]u8,

    pub fn xor(left: Hash, right: Hash) Hash { // TODO make this vector SIMD stuff?
        var hash: Hash = undefined;
        for (hash.data) |*byte, i| {
            byte.* = left.data[i] ^ right.data[i];
        }
        return hash;
    }

    pub fn equal(left: Hash, right: Hash) bool {
        return std.mem.eql(u8, &left.data, &right.data);
    }
};
// const Vector = std.meta.Vector;
// const Hash = Vector(16, u8);

fn keyHash(key: []const u8) Hash {
    const siphash = comptime std.hash.SipHash128(2, 4);
    var hash: Hash = undefined;
    siphash.create(&hash.data, key, &instance_secret);
    return hash;
}

/// The Tries branching factor, fixed to the number of elements
/// that can be represented by a byte/8bit.
const BRANCH_FACTOR = 256;

/// The number of hashes used in the cuckoo table.
const HASH_COUNT = 2;

/// The maximum number of cuckoo displacements atempted during
/// insert before the size of the table is increased.
const MAX_ATTEMPTS = 8;

/// A byte -> byte lookup table used in hashes as permutations.
const Byte_LUT = [256]u8;

/// The permutation LUTs of multiple hashes arranged for better
/// memory locality.
const Hash_LUT = [256][HASH_COUNT]u8;

/// Checks if a LUT is a permutation
fn is_permutation(lut: *const Byte_LUT) bool {
    var seen = ByteBitset.initEmpty();
    for (lut) |x| {
        seen.set(x);
    }

    return std.meta.eql(seen, ByteBitset.initFull());
}

/// Choose a random element from a bitset.
/// Generate a LUT where each input maps to itself.
fn generate_identity_LUT() Byte_LUT {
    var lut: Byte_LUT = undefined;
    for (lut) |*element, i| {
        element.* = @intCast(u8, i);
    }
    return lut;
}

/// Generate a LUT where each input maps to the input in reverse
/// bit order, e.g. 0b00110101 -> 0b10101100
fn generate_bitReverse_LUT() Byte_LUT {
    var lut: Byte_LUT = undefined;
    for (lut) |*element, i| {
        element.* = @bitReverse(u8, @intCast(u8, i));
    }
    assert(is_permutation(&lut));
    return lut;
}

fn random_choice(rng: std.rand.Random, set: ByteBitset) ?u8 {
    if (set.count() == 0) return null;

    var possible_values: [256]u8 = undefined;
    var possible_values_len: usize = 0;

    var iter = set.iterator(.{});
    while (iter.next()) |b| {
        possible_values[possible_values_len] = @intCast(u8, b);
        possible_values_len += 1;
    }

    const rand_index: u8 = @intCast(u8, rng.uintLessThan(usize, possible_values_len));
    return possible_values[rand_index];
}

fn generate_rand_LUT_helper(rng: std.rand.Random, dependencies: []const Byte_LUT, i: usize, remaining: ByteBitset, mask: u8, lut: *Byte_LUT) bool {
    if (i == 256) return true;

    var candidates = remaining;
    var iter = remaining.iterator(.{});
    while (iter.next()) |candidate| {
        for (dependencies) |d| {
            if ((d[i] & mask) == (candidate & mask)) {
                candidates.unset(candidate);
            }
        }
    }
    while (random_choice(rng, candidates)) |candidate| {
        var new_remaining = remaining;
        new_remaining.unset(candidate);
        candidates.unset(candidate);
        lut[i] = candidate;
        if (generate_rand_LUT_helper(rng, dependencies, i + 1, new_remaining, mask, lut)) {
            return true;
        }
    } else {
        return false;
    }
}

fn generate_rand_LUT(
    rng: std.rand.Random,
    dependencies: []const Byte_LUT,
    mask: u8,
) Byte_LUT {
    var lut: Byte_LUT = undefined;
    if (!generate_rand_LUT_helper(rng, dependencies, 0, ByteBitset.initFull(), mask, &lut)) unreachable;
    return lut;
}

fn generate_hash_LUTs(comptime rng: std.rand.Random) Hash_LUT {
    var luts: [HASH_COUNT]Byte_LUT = undefined;

    luts[0] = generate_bitReverse_LUT();
    for (luts[1..]) |*lut, i| {
        lut.* = generate_rand_LUT(rng, luts[0..i], HASH_COUNT - 1);
    }

    var hash_lut: Hash_LUT = undefined;

    for (luts) |lut, i| {
        for (lut) |h, j| {
            hash_lut[j][i] = h;
        }
    }

    return hash_lut;
}

/// Generates a byte -> byte lookup table for pearson hashing.
fn generate_pearson_LUT(comptime rng: std.rand.Random) Byte_LUT {
    const no_deps = [0]Byte_LUT{};
    const lut = generate_rand_LUT(rng, no_deps[0..], 0b11111111);
    assert(is_permutation(&lut));
    return lut;
}

/// Define a PACT datastructure with the given parameters.
pub fn makePACT(comptime key_length: u8, comptime T: type) type {
    return packed struct {
        const allocError = std.mem.Allocator.Error;

        const NodeTag = enum(u8) {
            none,
            inner1,
            inner2,
            inner4,
            inner8,
            inner16,
            inner32,
            leaf,
        };

        const Node = union(NodeTag) {
            none,
            inner1: InnerNode(1),
            inner2: InnerNode(2),
            inner4: InnerNode(4),
            inner8: InnerNode(8),
            inner16: InnerNode(16),
            inner32: InnerNode(32),
            leaf: LeafNode,

            fn bucketCountToTag(comptime bucket_count: byte) NodeTag {
                return switch (self) {
                    1 => NodeTag.inner1,
                    2 => NodeTag.inner2,
                    4 => NodeTag.inner4,
                    8 => NodeTag.inner8,
                    16 => NodeTag.inner16,
                    32 => NodeTag.inner32,
                    else => @panic("Bad bucket count for tag."),
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

                switch (self) {
                    .none => try writer.print("none", .{}),
                    .inner1 => |node| try writer.print("{s}", .{node}),
                    .inner2 => |node| try writer.print("{s}", .{node}),
                    .inner4 => |node| try writer.print("{s}", .{node}),
                    .inner8 => |node| try writer.print("{s}", .{node}),
                    .inner16 => |node| try writer.print("{s}", .{node}),
                    .inner32 => |node| try writer.print("{s}", .{node}),
                    .leaf => |node| try writer.print("{s}", .{node}),
                }
                try writer.writeAll("");
            }

            pub fn from(comptime variantType: type, variant: anytype) Node {
                return switch (variantType) {
                    LeafNode => Node{ .leaf = variant },
                    InnerNodeHead(1) => Node{ .inner1 = variant },
                    InnerNodeHead(2) => Node{ .inner2 = variant },
                    InnerNodeHead(4) => Node{ .inner4 = variant },
                    InnerNodeHead(8) => Node{ .inner8 = variant },
                    InnerNodeHead(16) => Node{ .inner16 = variant },
                    InnerNodeHead(32) => Node{ .inner32 = variant },
                    else => @panic("Can't create node from provided type."),
                };
            }

            pub fn ref(self: Node, allocator: std.mem.Allocator) allocError!Node {
                return switch (self) {
                    .none => @panic("Called `ref` on none."),
                    .inner1 => |node| node.ref(allocator),
                    .inner2 => |node| node.ref(allocator),
                    .inner4 => |node| node.ref(allocator),
                    .inner8 => |node| node.ref(allocator),
                    .inner16 => |node| node.ref(allocator),
                    .inner32 => |node| node.ref(allocator),
                    .leaf => |node| node.ref(allocator),
                };
            }

            pub fn rel(self: Node, allocator: std.mem.Allocator) void {
                switch (self) {
                    .none => @panic("Called `rel` on none."),
                    .inner1 => |node| node.rel(allocator),
                    .inner2 => |node| node.rel(allocator),
                    .inner4 => |node| node.rel(allocator),
                    .inner8 => |node| node.rel(allocator),
                    .inner16 => |node| node.rel(allocator),
                    .inner32 => |node| node.rel(allocator),
                    .leaf => |node| node.rel(allocator),
                }
            }

            pub fn discriminant(self: Node) u40 {
                return switch (self) {
                    .none => @panic("Called `discriminant` on none."),
                    .inner1 => |node| node.discriminant(),
                    .inner2 => |node| node.discriminant(),
                    .inner4 => |node| node.discriminant(),
                    .inner8 => |node| node.discriminant(),
                    .inner16 => |node| node.discriminant(),
                    .inner32 => |node| node.discriminant(),
                    .leaf => |node| node.discriminant(),
                };
            }

            pub fn count(self: Node) u40 {
                return switch (self) {
                    .none => @panic("Called `count` on none."),
                    .inner1 => |node| node.count(),
                    .inner2 => |node| node.count(),
                    .inner4 => |node| node.count(),
                    .inner8 => |node| node.count(),
                    .inner16 => |node| node.count(),
                    .inner32 => |node| node.count(),
                    .leaf => |node| node.count(),
                };
            }

            pub fn hash(self: Node) Hash {
                return switch (self) {
                    .none => @panic("Called `hash` on none."),
                    .inner1 => |node| node.hash(),
                    .inner2 => |node| node.hash(),
                    .inner4 => |node| node.hash(),
                    .inner8 => |node| node.hash(),
                    .inner16 => |node| node.hash(),
                    .inner32 => |node| node.hash(),
                    .leaf => |node| node.hash(),
                };
            }

            pub fn depth(self: Node) u8 {
                return switch (self) {
                    .none => @panic("Called `depth` on none."),
                    .inner1 => |node| node.depth(),
                    .inner2 => |node| node.depth(),
                    .inner4 => |node| node.depth(),
                    .inner8 => |node| node.depth(),
                    .inner16 => |node| node.depth(),
                    .inner32 => |node| node.depth(),
                    .leaf => |node| node.depth(),
                };
            }

            pub fn peek(self: Node, at_depth: u8) ?u8 {
                return switch (self) {
                    .none => @panic("Called `peek` on none."),
                    .inner1 => |node| node.peek(at_depth),
                    .inner2 => |node| node.peek(at_depth),
                    .inner4 => |node| node.peek(at_depth),
                    .inner8 => |node| node.peek(at_depth),
                    .inner16 => |node| node.peek(at_depth),
                    .inner32 => |node| node.peek(at_depth),
                    .leaf => |node| node.peek(at_depth),
                };
            }

            pub fn propose(self: Node, at_depth: u8, result_set: *ByteBitset) void {
                return switch (self) {
                    .none => @panic("Called `propose` on none."),
                    .inner1 => |node| node.propose(at_depth, result_set),
                    .inner2 => |node| node.propose(at_depth, result_set),
                    .inner4 => |node| node.propose(at_depth, result_set),
                    .inner8 => |node| node.propose(at_depth, result_set),
                    .inner16 => |node| node.propose(at_depth, result_set),
                    .inner32 => |node| node.propose(at_depth, result_set),
                    .leaf => |node| node.propose(at_depth, result_set),
                };
            }

            pub fn get(self: Node, at_depth: u8, byte_key: u8) ?Node {
                return switch (self) {
                    .none => @panic("Called `get` on none."),
                    .inner1 => |node| node.get(at_depth, byte_key),
                    .inner2 => |node| node.get(at_depth, byte_key),
                    .inner4 => |node| node.get(at_depth, byte_key),
                    .inner8 => |node| node.get(at_depth, byte_key),
                    .inner16 => |node| node.get(at_depth, byte_key),
                    .inner32 => |node| node.get(at_depth, byte_key),
                    .leaf => |node| node.get(at_depth, byte_key),
                };
            }

            pub fn put(self: Node, at_depth: u8, key: *const [key_length]u8, value: T, single_owner: bool, allocator: std.mem.Allocator) allocError!*NodeHeader {
                return switch (self) {
                    .none => @panic("Called `put` on none."),
                    .inner1 => |node| node.put(at_depth, key, value, single_owner, allocator),
                    .inner2 => |node| node.put(at_depth, key, value, single_owner, allocator),
                    .inner4 => |node| node.put(at_depth, key, value, single_owner, allocator),
                    .inner8 => |node| node.put(at_depth, key, value, single_owner, allocator),
                    .inner16 => |node| node.put(at_depth, key, value, single_owner, allocator),
                    .inner32 => |node| node.put(at_depth, key, value, single_owner, allocator),
                    .leaf => |node| node.put(at_depth, key, value, single_owner, allocator),
                };
            }
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
            assert(@popCount(u8, c) == 1);
            @setEvalBranchQuota(1000000);
            const luts = comptime blk: {
                @setEvalBranchQuota(1000000);
                var rand_state = std.rand.Xoroshiro128.init(0);
                break :blk generate_hash_LUTs(rand_state.random());
            };
            const mask = c - 1;
            const pi: u8 = if (p) 1 else 0;
            return mask & luts[v][pi];
        }

        const max_bucket_count = 32; // BRANCH_FACTOR / Bucket.SLOT_COUNT;

        fn InnerNode(comptime bucket_count: byte) type {
            comptime type_tag = bucketCountToTag(bucket_count);

            const NextGrownHead = InnerNode(@minimum(bucket_count << 1, max_bucket_count));

            const InnerNodeHead = packed struct {
                /// The address of the pointer associated with the key.
                ptr: u48 align(@alignOf(u64)) = 0,
                /// The key stored in this entry.
                key: u8 = 0,

                const BODY_ALIGNMENT = 64;
                const Body = packed struct {
                    //   ┌──5:count
                    //   │  ┌──1:branch depth
                    //   │  │ ┌───2:refcount
                    //   │  │ │  ┌───5:segment count
                    //   │  │ │  │
                    //   │  │ │  │
                    // ┌───┐╻┌┐┌───┐┌─────────────────────────────────┐┌──────────────┐
                    // │   │┃│││   ││          35:key infix           ││   16:hash    │
                    // └───┘╹└┘└───┘└─────────────────────────────────┘└──────────────┘
                    // ┌──────────────────────────────┐┌──────────────────────────────┐
                    // │     32:has-child bitset      ││     32:child hash-choice     │
                    // └──────────────────────────────┘└──────────────────────────────┘
                    // ┌──────────────────────────────────────────────────────────────┐
                    // │                           bucket 0                           │
                    // └──────────────────────────────────────────────────────────────┘
                    // ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
                    //                          bucket 1...31                         │
                    // └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

                    leaf_count: u40 = 1,
                    branch_depth: u8,
                    ref_count: u16 = 1,
                    segment_count: u40,
                    key_infix: [35]u8,
                    child_sum_hash: Hash = .{ .data = [_]u8{0} ** 16 },
                    child_set: ByteBitset = ByteBitset.initEmpty(),
                    rand_hash_used: ByteBitset = ByteBitset.initEmpty(),
                    buckets: [bucket_count]Bucket = if (bucket_count == 1) [_]Node{Node{.none}} ** bucket_count else undefined,

                    const Bucket = packed struct {
                        const SLOT_COUNT = 8;

                        slots: [SLOT_COUNT]Node = [_]Node{Node{.none}} ** SLOT_COUNT,
                        /// Checks if the bucket slot is free to use, either
                        /// because it is empty, or because it stores a value
                        /// that is no longer pigeonholed to this index
                        fn isFreeSlot(
                            node: Node,
                            uses_rand_hash: bool, // /Answers which hash was used for this entry.
                            current_count: u8, // / Current bucket count.
                            current_index: u8, // / This buckets current index.
                        ) bool {
                            return switch (self) {
                                .none => true,
                                else => |node| current_index != hashByteKey(uses_rand_hash, current_count, node.discriminant()),
                            };
                        }

                        pub fn format(
                            self: Bucket,
                            comptime fmt: []const u8,
                            options: std.fmt.FormatOptions,
                            writer: anytype,
                        ) !void {
                            _ = fmt;
                            _ = options;

                            for (self.slots) |slot, i| {
                                switch (slot) {
                                    .none => try writer.print("|_", .{}),
                                    else => try writer.print("| {d}: {d:3}", .{ i, slot.discriminant() }),
                                }
                            }
                            try writer.writeAll("|");
                        }

                        /// Retrieve the value stored, value must exist.
                        pub fn get(self: *const Bucket, byte_key: u8) Node {
                            for (self.slots) |slot| {
                                if (slot != .none and slot.discriminant() == byte_key) {
                                    return slot;
                                }
                            }
                            std.debug.print("Constraint violation, byte key {d} not found in: {s}\n", .{ byte_key, self });
                            unreachable;
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
                            bucket_count: u8,
                            // / The current index the bucket has. Is used to detect outdated (free) slots.
                            bucket_index: u8,
                            // / The entry to be stored in the bucket.
                            entry: Node,
                        ) bool {
                            for (self.slots) |*slot| {
                                if (slot != .none and slot.discriminant() == entry.discriminant()) {
                                    slot.* = entry;
                                    return true;
                                }
                            }
                            for (self.slots) |*slot| {
                                if (isFreeSlot(slot, rand_hash_used.isSet(slot.discriminant()), bucket_count, bucket_index)) {
                                    slot.* = entry;
                                    return true;
                                }
                            }
                            return false;
                        }

                        /// Updates the pointer for the key stored in this bucket.
                        pub fn update(
                            self: *Bucket,
                            // / The new entry value.
                            entry: Node,
                        ) void {
                            for (self.slots) |*slot| {
                                if (slots != .none and slot.discriminant() == entry.discriminant()) {
                                    slot.* = entry;
                                    return;
                                }
                            }
                        }

                        /// Displaces a random existing slot.
                        pub fn displaceRandomly(
                            self: *Bucket,
                            // / A random value to determine the slot to displace.
                            random_value: u8,
                            // / The entry that displaces an existing entry.
                            entry: Node,
                        ) Node {
                            const index = random_value & (SLOT_COUNT - 1);
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
                                if (rand_hash_used.isSet(slot.discriminant())) {
                                    const prev = slot.*;
                                    slot.* = entry;
                                    return prev;
                                }
                            }
                            std.debug.print("Something went wrong alt-displacing {d} in: {s}\n", .{ entry.discriminant(), self });
                            unreachable;
                        }
                    };
                };

                fn body() *Body {
                    @intToPtr(*Body, self.ptr);
                }

                pub fn format(
                    self: InnerNodeHead,
                    comptime fmt: []const u8,
                    options: std.fmt.FormatOptions,
                    writer: anytype,
                ) !void {
                    _ = fmt;
                    _ = options;

                    try writer.print("{*} ◁{d}:\n", .{ &self, self.ref_count });
                    try writer.print("      depth: {d} | count: {d} | segment_count: {d}\n", .{ self.branch_depth, self.leaf_count, self.segment_count });
                    try writer.print("       hash: {s}\n", .{self.child_sum_hash});
                    try writer.print("  key_infix: {s}\n", .{self.key_infix});
                    try writer.print("  child_set: {s}\n", .{self.child_set});
                    try writer.print("   rand_hash_used: {s}\n", .{self.rand_hash_used});
                    try writer.print("   children: ", .{});

                    var child_iterator = self.child_set.iterator(.{ .direction = .forward });
                    while (child_iterator.next()) |child_byte_key| {
                        const cast_child_byte_key = @intCast(u8, child_byte_key);
                        const use_rand_hash = self.rand_hash_used.isSet(cast_child_byte_key);
                        const bucket_index = hashByteKey(use_rand_hash, self.bucket_count, cast_child_byte_key);
                        const hash_name = @as([]const u8, if (use_rand_hash) "rnd" else "seq");
                        try writer.print("|{d}:{s}@{d}", .{ cast_child_byte_key, hash_name, bucket_index });
                    }
                    try writer.print("|\n", .{});
                    try writer.print("    buckets:\n", .{});
                    for (self.bucketSliceView()) |bucket, i| {
                        try writer.print("        {d}: {s}\n", .{ i, bucket });
                    }
                }

                pub fn init(parent_branch_depth: u8, branch_depth: u8, key: *const [key_length]u8, allocator: std.mem.Allocator) !Node {
                    const allocation = try allocator.allocWithOptions(Body, 1, BODY_ALIGNMENT, null);
                    const new = @ptrCast(*Body, allocation);
                    new.* = Body{ .ref_count = 1, .branch_depth = branch_depth, .leaf_count = 1, .segment_count = 1, .key_infix = undefined };
                    const segmentLength = @minimum(branch_depth, new.key_infix.len);
                    const segmentStart = new.key_infix.len - segmentLength;
                    const keyStart = branch_depth - segmentLength;
                    mem.set(u8, new.key_infix[0..segmentStart], 0);
                    mem.copy(u8, new.key_infix[segmentStart..new.key_infix.len], key[keyStart..branch_depth]);

                    return InnerNodeHead{ .key = key[parent_branch_depth], .ptr = @intCast(u48, allocation) };
                }

                /// TODO: document this!
                pub fn ref(self: InnerNodeHead, allocator: std.mem.Allocator) allocError!Node {
                    if (self.ref_count == std.math.maxInt(@TypeOf(self.ref_count))) {
                        // Reference counter exhausted, we need to make a copy of this node.
                        return try self.copy(allocator);
                    } else {
                        self.ref_count += 1;
                        return Node.from(InnerNodeHead, self);
                    }
                }

                pub fn rel(self: *InnerNode, allocator: std.mem.Allocator) void {
                    self.ref_count -= 1;
                    if (self.ref_count == 0) {
                        //std.debug.print("Releasing:\n{s}\n", .{self});
                        defer allocator.free(self.raw());
                        var child_iterator = self.child_set.iterator(.{ .direction = .forward });
                        while (child_iterator.next()) |child_byte_key| {
                            self.cuckooGet(@intCast(u8, child_byte_key)).rel(allocator);
                        }
                    }
                }

                pub fn discriminant(self: InnerNodeHead) byte {
                    return self.key;
                }

                pub fn count(self: *InnerNode) u40 {
                    return self.leaf_count;
                }

                pub fn hash(self: *InnerNode) Hash {
                    return self.child_sum_hash;
                }

                pub fn depth(self: *InnerNode) u8 {
                    return self.branch_depth;
                }

                fn copy(self: InnerNodeHead, allocator: std.mem.Allocator) !InnerNodeHead {
                    const allocation = try allocator.allocWithOptions(Body, 1, BODY_ALIGNMENT, null);
                    var new = InnerNodeHead{ .key = self.key, .ptr = @intCast(u48, allocation) };

                    new.body().* = self.body().*;
                    new.body().ref_count = 1;

                    var child_iterator = new.body().child_set.iterator(.{ .direction = .forward });
                    while (child_iterator.next()) |child_byte_key| {
                        const cast_child_byte_key = @intCast(u8, child_byte_key);
                        const child = new.cuckooGet(cast_child_byte_key);
                        const new_child = try child.ref(allocator);
                        if (child != new_child) {
                            new.cuckooUpdate(cast_child_byte_key, new_child);
                        }
                    }

                    return new;
                }

                pub fn put(self: InnerNodeHead, at_depth: u8, key: *const [key_length]u8, value: T, parent_single_owner: bool, allocator: std.mem.Allocator) allocError!Node {
                    const single_owner = parent_single_owner and self.body().ref_count == 1;

                    var branch_depth = at_depth;
                    var infix_index: u8 = (at_depth + @as(u8, self.body().key_infix.len)) - self.body().branch_depth;
                    while (branch_depth < self.body().branch_depth) : ({
                        branch_depth += 1;
                        infix_index += 1;
                    }) {
                        if (key[branch_depth] != self.body().key_infix[infix_index]) break;
                    } else {
                        // The entire compressed infix above this node matched with the key.
                        const byte_key = key[branch_depth];
                        if (self.cuckooHas(byte_key)) {
                            // The node already has a child branch with the same byte discriminant as the one in the key.
                            const old_child = self.cuckooGet(byte_key);
                            const old_child_hash = old_child.hash();
                            const old_child_count = old_child.count();
                            const old_child_segment_count = 1; // TODO old_child.segmentCount(branch_depth);
                            const new_child = try old_child.put(branch_depth + 1, key, value, single_owner, allocator);
                            if (Hash.equal(old_child_hash, new_child.hash())) {
                                return Node.from(InnerNodeHead, self);
                            }
                            const new_hash = Hash.xor(Hash.xor(self.hash(), old_child_hash), new_child.hash());
                            const new_count = self.body().leaf_count - old_child_count + new_child.count();
                            const new_segment_count =
                                self.body().segment_count -
                                old_child_segment_count +
                                1; // TODO new_child.segmentCount(branch_depth);

                            var self_or_copy = self;
                            if (!single_owner) {
                                self_or_copy = try self.copy(allocator);
                                old_child.rel(allocator);
                            }
                            self_or_copy.body().child_sum_hash = new_hash;
                            self_or_copy.body().leaf_count = new_count;
                            self_or_copy.body().segment_count = new_segment_count;
                            return self_or_copy.cuckooUpdate(byte_key, new_child);
                        } else {
                            const new_child = try LeafNode.init(branch_depth, key, value, keyHash(key), allocator);
                            const new_hash = Hash.xor(self.hash(), new_child.hash());
                            const new_count = self.body().leaf_count + 1;
                            const new_segment_count = self.body().segment_count + 1;

                            var self_or_copy = if (single_owner) self else try self.copy(allocator);

                            self_or_copy.body().child_sum_hash = new_hash;
                            self_or_copy.body().leaf_count = new_count;
                            self_or_copy.body().segment_count = new_segment_count;

                            return try self_or_copy.cuckooPut(byte_key, Node.from(LeafNode, new_child), allocator);
                        }
                    }

                    const branch_node = try InnerNode(1).init(branch_depth, key, allocator);
                    const sibling_node = try LeafNode.init(branch_depth, key, value, keyHash(key), allocator);

                    const self_byte_key = self.body().key_infix[infix_index];
                    const sibling_byte_key = key[branch_depth];
 
                    //TODO: We need to change our own InnerNodeHead Discriminant to match the self_byte_key! and we need to set the discriminant on the newly created inner node
                    // to our old self.discriminant(), this means that passing a parent branch depth is not possible I think as we don't have that data anymore, however we still have
                    // the discriminant itself.

                    _ = try branch_node.cuckooPut(self_byte_key, Node.from(InnerNodeHead, self), allocator); // We know that these can't fail and won't reallocate.
                    _ = try branch_node.cuckooPut(sibling_byte_key, Node.from(LeafNode, sibling_node), allocator);
                    branch_node.body().child_sum_hash = Hash.xor(self.hash(), sibling_node.hash());
                    branch_node.body().leaf_count = self.body().leaf_count + 1;
                    branch_node.body().segment_count = 3;
                    // We need to check if this insered moved our branchDepth across a segment boundary.
                    // const segmentCount =
                    //     SEGMENT_LUT[depth] === SEGMENT_LUT[this.branchDepth]
                    //     ? this._segmentCount + 1
                    //     : 2;

                    return Node.from(InnerNode(1), branch_node);
                }

                pub fn get(self: *InnerNodeHead, at_depth: u8, byte_key: u8) ?Node {
                    if (at_depth < self.branch_depth) {
                        const index: u8 = (at_depth + @as(u8, self.key_infix.len)) - self.branch_depth;
                        const infix_key = self.key_infix[index];
                        if (infix_key == byte_key) {
                            return Node.from(InnerNodeHead, self);
                        }
                    } else {
                        if (self.cuckooHas(byte_key)) {
                            return self.cuckooGet(byte_key);
                        }
                    }
                    return null;
                }

                fn grow(self: *InnerNodeHead, allocator: std.mem.Allocator) !*NextGrownHead {
                    if (bucket_count == max_bucket_count) {
                        return self;
                    } else {
                        const allocation = try allocator.reallocAdvanced(std.mem.asBytes(self), BODY_ALIGNMENT, @sizeOf(NextGrownHead.Body), .exact);
                        const new = @ptrCast(*NextGrownHead.Body, allocation);
                        new.bucket_count = new_bucket_count;
                        const buckets = new.bucketSlice();
                        mem.copy(Bucket, buckets[buckets.len / 2 .. buckets.len], buckets[0 .. buckets.len / 2]);
                        return new;
                    }
                }

                fn cuckooPut(self: *Body, node: Node, allocator: std.mem.Allocator) !Node {
                    var discriminant = node.discriminant();
                    if (self.child_set.isSet(byte_key)) {
                        const index = hashByteKey(self.rand_hash_used.isSet(byte_key), self.bucket_count, byte_key);
                        self.buckets[index].update(node);
                        return self;
                    } else {
                        const growable = (bucket_count != max_bucket_count);
                        const base_size = (bucket_count == 1);
                        var use_rand_hash = false;
                        var entry = node;
                        var attempts: u8 = 0;
                        while (true) {
                            random = rand_lut[random ^ discriminant];
                            const bucket_index = hashByteKey(use_rand_hash, bucket_count, discriminant);

                            self.child_set.set(discriminant);
                            self.rand_hash_used.setValue(discriminant, use_rand_hash);

                            if (self.buckets[bucket_index].put(&self.rand_hash_used, bucket_count, bucket_index, entry)) {
                                return Node.from(self);
                            }

                            if (base_size or attempts == MAX_ATTEMPTS) {
                                const grown = try self.grow(allocator);
                                return grown.cuckooPut(entry);
                            }

                            if (growable) {
                                attempts += 1;
                                entry = buckets[bucket_index].displaceRandomly(random, entry);
                                discriminant = entry.discriminant();
                                use_rand_hash = !self.rand_hash_used.isSet(discriminant);
                            } else {
                                entry = buckets[bucket_index].displaceRandHashOnly(&self.rand_hash_used, entry);
                                use_rand_hash = false;
                            }
                        }
                    }
                    unreachable;
                }

                fn cuckooHas(self: *Body, discriminant: u8) bool {
                    return self.child_set.isSet(discriminant);
                }

                // Contract: Key looked up must exist. Ensure with cuckooHas.
                fn cuckooGet(self: *Body, discriminant: u8) Node {
                    assert(self.child_set.isSet(discriminant));
                    const bucket_index = hashByteKey(self.rand_hash_used.isSet(discriminant), bucket_count, discriminant);
                    return self.buckets[bucket_index].get(discriminant);
                }

                fn cuckooUpdate(self: *Body, node: Node) void {
                    const discriminant = node.discriminant();
                    const bucket_index = hashByteKey(self.rand_hash_used.isSet(discriminant), bucket_count, discriminant);
                    return self.buckets[bucket_index].update(node);
                }
            };

            return InnerNodeHead;
        }

        const LeafNode = packed struct {
            /// The address of the pointer associated with the key.
            ptr: u48 align(@alignOf(u64)) = 0,
            /// The key stored in this entry.
            key: u8 = 0,

            const Body = packed struct {

                //                     ┌───────8:value ptr
                //                     │    ┌──────2:refcount
                //                     │    │
                //                     │    │
                // ┌──────────────┐┌──────┐┌┐┌────────────────────────────────────┐
                // │   16:hash    ││      ││││           38:key suffix            │
                // └──────────────┘└──────┘└┘└────────────────────────────────────┘

                key_hash: Hash,
                value: *T,
                ref_count: u16 = 1,
                key_suffix: [38]u8 = undefined,
            };

            fn body() *Body {
                @intToPtr(*Body, self.ptr);
            }

            pub fn init(parent_branch_depth: u8, branch_depth: u8, key: *const [key_length]u8, value: T, key_hash: Hash, allocator: std.mem.Allocator) !LeafNode {
                const allocation = try allocator.allocWithOptions(Body, 1, @alignOf(Body), null);
                const new_body = @ptrCast(*Body, allocation);
                new_body.* = LeafNode{.key_hash = key_hash, .value = value };
                mem.copy(u8, new_body.key_suffix[0..new_body.key_suffix.len], key[(key_length - new_body.key_suffix.len)..key_length]);
                
                return LeafNode{ .key = key[parent_branch_depth], .ptr = @intCast(u48, allocation) };
            }

            pub fn format(
                self: LeafNode,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = self;
                _ = fmt;
                _ = options;
                try writer.writeAll("LEAF! (TODO)");
            }

            fn raw(self: *LeafNode) []u8 {
                return @ptrCast([*]align(@alignOf(LeafNode)) u8, self)[0..byte_size(self.suffix_len)]; // TODO add alignment
            }

            fn head(self: *LeafNode) *NodeHeader {
                return &self.header;
            }

            pub fn ref(self: *LeafNode, allocator: std.mem.Allocator) allocError!*NodeHeader {
                if (self.ref_count == std.math.maxInt(@TypeOf(self.ref_count))) {
                    // Reference counter exhausted, we need to make a copy of this node.
                    const byte_count = byte_size(self.suffix_len);
                    const allocation = try allocator.allocWithOptions(u8, byte_count, @alignOf(LeafNode), null);
                    const new = @ptrCast(*LeafNode, allocation);
                    mem.copy(u8, new.raw(), self.raw());
                    new.ref_count = 1;
                    return new.head();
                } else {
                    self.ref_count += 1;
                    return self.head();
                }
            }

            pub fn rel(self: *LeafNode, allocator: std.mem.Allocator) void {
                self.ref_count -= 1;
                if (self.ref_count == 0) {
                    defer allocator.free(self.raw());
                }
            }

            fn suffixSlice(self: *LeafNode) []u8 {
                const ptr = @intToPtr([*]u8, @ptrToInt(self) + @sizeOf(LeafNode));
                return ptr[0..self.suffix_len];
            }

            pub fn count(self: *LeafNode) u40 {
                _ = self;
                return 1;
            }

            pub fn hash(self: *LeafNode) Hash {
                return self.key_hash;
            }

            pub fn depth(self: *LeafNode) u8 {
                _ = self;
                return key_length;
            }

            pub fn peek(self: *LeafNode, at_depth: u8) ?u8 {
                if (depth < key_length) return self.key[at_depth];
                return null;
            }

            pub fn propose(self: *LeafNode, at_depth: u8, result_set: *ByteBitset) void {
                var set = ByteBitset.initEmpty();
                set.set(self.key[at_depth]);
                result_set.setIntersection(set);
            }

            pub fn get(self: *LeafNode, at_depth: u8, key: u8) ?*NodeHeader {
                const index = at_depth - (key_length - self.suffix_len);
                // The formula used here is different from the one of the inner node as key_length > suffix_length.
                if (at_depth < key_length and self.suffixSlice()[index] == key) return self.head();
                return null;
            }

            pub fn put(self: *LeafNode, at_depth: u8, key: *const [key_length]u8, value: T, single_owner: bool, allocator: std.mem.Allocator) allocError!*NodeHeader {
                _ = single_owner;
                const suffix = self.suffixSlice();
                var branch_depth = at_depth;
                var suffix_index: u8 = at_depth - (key_length - self.suffix_len);
                while (branch_depth < key_length) : ({
                    branch_depth += 1;
                    suffix_index += 1;
                }) {
                    if (key[branch_depth] != suffix[suffix_index]) break;
                } else {
                    return self.head();
                }

                const branch_node = try InnerNode.init(branch_depth, key, allocator);
                const sibling_node = try LeafNode.init(branch_depth + 1, key, value, keyHash(key), allocator);

                const self_byte_key = suffix[suffix_index];
                const sibling_byte_key = key[branch_depth];

                _ = try branch_node.cuckooPut(self_byte_key, self.head(), allocator); // We know that these can't fail and won't reallocate.
                _ = try branch_node.cuckooPut(sibling_byte_key, sibling_node.head(), allocator);
                branch_node.child_sum_hash = Hash.xor(self.hash(), sibling_node.hash());
                branch_node.leaf_count = 2;
                branch_node.segment_count = 2;

                return branch_node.head();
            }
        };

        const Tree = struct {
            child: ?*NodeHeader = null,
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator) Tree {
                return Tree{ .allocator = allocator };
            }

            pub fn deinit(self: *Tree) void {
                if (self.child) |child| {
                    child.rel(self.allocator);
                }
            }

            pub fn fork(self: *Tree) !Tree {
                var own_child = self.child;
                if (own_child) |*c| {
                    c.* = try c.*.ref(self.allocator);
                }
                return Tree{ .child = own_child, .allocator = self.allocator };
            }

            pub fn count(self: *Tree) u40 {
                return if (self.child) |child| child.count() else 0;
            }

            pub fn put(self: *Tree, key: *const [key_length]u8, value: T) !void {
                if (self.child) |*child| {
                    //std.debug.print("tree put old: {*}\n", .{child.*});
                    child.* = try child.*.put(0, key, value, true, self.allocator);
                    //std.debug.print("tree put new: {*}\n", .{child.*});
                } else {
                    self.child = (try LeafNode.init(0, key, value, keyHash(key), self.allocator)).head();
                }
            }
            // get(key) {
            //   let node = this.child;
            //   if (node === null) return undefined;
            //   for (let depth = 0; depth < KEY_LENGTH; depth++) {
            //     const sought = key[depth];
            //     node = node.get(depth, sought);
            //     if (node === null) return undefined;
            //   }
            //   return node.value;
            // }

            // cursor() {
            //   return new PACTCursor(this);
            // }

            // isEmpty() {
            //   return this.child === null;
            // }

            // isEqual(other) {
            //   return (
            //     this.child === other.child ||
            //     (this.keyLength === other.keyLength &&
            //       !!this.child &&
            //       !!other.child &&
            //       hash_equal(this.child.hash, other.child.hash))
            //   );
            // }

            // isSubsetOf(other) {
            //   return (
            //     this.keyLength === other.keyLength &&
            //     (!this.child || (!!other.child && _isSubsetOf(this.child, other.child)))
            //   );
            // }

            // isIntersecting(other) {
            //   return (
            //     this.keyLength === other.keyLength &&
            //     !!this.child &&
            //     !!other.child &&
            //     (this.child === other.child ||
            //       hash_equal(this.child.hash, other.child.hash) ||
            //       _isIntersecting(this.child, other.child))
            //   );
            // }

            // union(other) {
            //   const thisNode = this.child;
            //   const otherNode = other.child;
            //   if (thisNode === null) {
            //     return new PACTTree(otherNode);
            //   }
            //   if (otherNode === null) {
            //     return new PACTTree(thisNode);
            //   }
            //   return new PACTTree(_union(thisNode, otherNode));
            // }

            // subtract(other) {
            //   const thisNode = this.child;
            //   const otherNode = other.child;
            //   if (otherNode === null) {
            //     return new PACTTree(thisNode);
            //   }
            //   if (
            //     this.child === null ||
            //     hash_equal(this.child.hash, other.child.hash)
            //   ) {
            //     return new PACTTree();
            //   } else {
            //     return new PACTTree(_subtract(thisNode, otherNode));
            //   }
            // }

            // intersect(other) {
            //   const thisNode = this.child;
            //   const otherNode = other.child;

            //   if (thisNode === null || otherNode === null) {
            //     return new PACTTree(null);
            //   }
            //   if (thisNode === otherNode || hash_equal(thisNode.hash, otherNode.hash)) {
            //     return new PACTTree(otherNode);
            //   }
            //   return new PACTTree(_intersect(thisNode, otherNode));
            // }

            // difference(other) {
            //   const thisNode = this.child;
            //   const otherNode = other.child;

            //   if (thisNode === null) {
            //     return new PACTTree(otherNode);
            //   }
            //   if (otherNode === null) {
            //     return new PACTTree(thisNode);
            //   }
            //   if (thisNode === otherNode || hash_equal(thisNode.hash, otherNode.hash)) {
            //     return new PACTTree(null);
            //   }
            //   return new PACTTree(_difference(thisNode, otherNode));
            // }

            // *entries() {
            //   if (this.child === null) return;
            //   for (const [k, v] of _walk(this.child)) {
            //     yield [k.slice(), v];
            //   }
            // }

            // *keys() {
            //   if (this.child === null) return;
            //   for (const [k, v] of _walk(this.child)) {
            //     yield k.slice();
            //   }
            // }

            // *values() {
            //   if (this.child === null) return;
            //   for (const [k, v] of _walk(this.child)) {
            //     yield v;
            //   }
            // }
        };
    };
}

test "create tree" {
    const key_length = 64;
    const PACT = makePACT(key_length, usize);
    var tree = PACT.Tree.init(std.testing.allocator);
    defer tree.deinit();
}

test "empty tree has count 0" {
    const key_length = 64;
    const PACT = makePACT(key_length, usize);
    var tree = PACT.Tree.init(std.testing.allocator);
    defer tree.deinit();

    try expectEqual(tree.count(), 0);
}

test "single item tree has count 1" {
    const key_length = 64;
    const PACT = makePACT(key_length, usize);
    var tree = PACT.Tree.init(std.testing.allocator);
    defer tree.deinit();

    const key: [key_length]u8 = [_]u8{0} ** key_length;
    try tree.put(&key, 42);

    try expectEqual(tree.count(), 1);
}

test "immutable tree fork" {
    const key_length = 64;
    const PACT = makePACT(key_length, usize);
    var tree = PACT.Tree.init(std.testing.allocator);
    defer tree.deinit();

    var new_tree = try tree.fork();
    defer new_tree.deinit();

    const key: [key_length]u8 = [_]u8{0} ** key_length;
    try new_tree.put(&key, 42);

    try expectEqual(tree.count(), 0);
    try expectEqual(new_tree.count(), 1);
}

test "multi item tree has correct count" {
    const total_runs = 10;

    var rnd = std.rand.DefaultPrng.init(0).random();

    const key_length = 64;
    const PACT = makePACT(key_length, usize);
    var tree = PACT.Tree.init(std.testing.allocator);
    defer tree.deinit();

    var key: [key_length]u8 = undefined;

    var i: u40 = 0;
    while (i < total_runs) : (i += 1) {
        try expectEqual(tree.count(), i);

        rnd.bytes(&key);
        try tree.put(&key, rnd.int(usize));
        //std.debug.print("Inserted {d} of {d}:{any}\n{s}\n", .{i+1, total_runs, key, tree.child.?.toNode()});
    }
    try expectEqual(tree.count(), total_runs);
}

const time = std.time;

//                        | <------ 48 bit -------->|
// kernel space: | 1....1 | significant | alignment |
// user space:   | 0....1 | significant | alignemnt |

// 8:tag = 0 | 56:suffix
// 8:tag = 1 | 8:infix | 48:leaf ptr
// 8:tag = 2 | 8:infix | 48:inner ptr

test "benchmark" {
    const total_runs: usize = 10000000;

    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var rnd = std.rand.DefaultPrng.init(0).random();

    const key_length = 64;
    const PACT = makePACT(key_length, usize);
    var tree = PACT.Tree.init(gpa);
    defer tree.deinit();

    var key: [key_length]u8 = undefined;

    var i: u40 = 0;
    while (i < total_runs) : (i += 1) {
        rnd.bytes(&key);
        const value = rnd.int(usize);

        timer.reset();

        try tree.put(&key, value);

        t_total += timer.lap();
    }

    std.debug.print("Inserted {d} in {d}ns\n", .{ total_runs, t_total });
}

test "benchmark std" {
    const total_runs: usize = 100000;

    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = general_purpose_allocator.allocator();

    var timer = try time.Timer.start();
    var t_total: u64 = 0;

    var rnd = std.rand.DefaultPrng.init(0).random();

    const key_length = 64;

    var key: [key_length]u8 = undefined;

    var map = std.hash_map.AutoHashMap([key_length]u8, usize).init(gpa);
    defer map.deinit();

    var i: u40 = 0;
    while (i < total_runs) : (i += 1) {
        rnd.bytes(&key);
        const value = rnd.int(usize);

        timer.reset();

        try map.put(key, value);

        t_total += timer.lap();
    }

    std.debug.print("Inserted {d} in {d}ns\n", .{ total_runs, t_total });
}
