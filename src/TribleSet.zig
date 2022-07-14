const std = @import("std");
const PACT = @import("./PACT.zig").PACT;
const MemInfo = @import("./MemInfo.zig").MemInfo;
const Trible = @import("./Trible.zig").Trible;
const mem = std.mem;
const allocError = std.mem.Allocator.Error;


const EAVIndex = PACT(&[_]u8{16, 16, 32}, u8).Tree;
const EVAIndex = PACT(&[_]u8{16, 32, 16}, u8).Tree;
const AEVIndex = PACT(&[_]u8{16, 16, 32}, u8).Tree;
const AVEIndex = PACT(&[_]u8{16, 32, 16}, u8).Tree;
const VEAIndex = PACT(&[_]u8{32, 16, 16}, u8).Tree;
const VAEIndex = PACT(&[_]u8{32, 16, 16}, u8).Tree;

pub const TribleSet = struct {
    eav: EAVIndex,
    eva: EVAIndex,
    aev: AEVIndex,
    ave: AVEIndex,
    vea: VEAIndex,
    vae: VAEIndex,

    const TribleConstraint = struct {
        const State = enum {
            stack_empty,
            stack_e, stack_a, stack_v,
            stack_ea, stack_ev, stack_ae, stack_av, stack_ve, stack_va,
            stack_eav, stack_eva, stack_aev, stack_ave, stack_vea, stack_vae,
        }

        eVar: u8,
        aVar: u8,
        vVar: u8,
        state: State,

        eavCursor: PaddedCursor(EAVIndex.Cursor, 32),
        evaCursor: PaddedCursor(EVAIndex.Cursor, 32),
        aevCursor: PaddedCursor(AEVIndex.Cursor, 32),
        aveCursor: PaddedCursor(AVEIndex.Cursor, 32),
        veaCursor: PaddedCursor(VEAIndex.Cursor, 32),
        vaeCursor: PaddedCursor(VAEIndex.Cursor, 32),

        pub fn peekByte(self: *@This()) ?u8 {
            return switch(self.state) {
                .stack_empty => unreachable,

                .stack_e => self.eavCursor.peek(),
                .stack_a => self.aevCursor.peek(),
                .stack_v => self.veaCursor.peek(),

                .stack_ea => self.eavCursor.peek(),
                .stack_ev => self.evaCursor.peek(),
                .stack_ae => self.aevCursor.peek(),
                .stack_av => self.aveCursor.peek(),
                .stack_ve => self.veaCursor.peek(),
                .stack_va => self.vaeCursor.peek(),

                .stack_eav => self.eavCursor.peek(),
                .stack_eva => self.evaCursor.peek(),
                .stack_aev => self.aevCursor.peek(),
                .stack_ave => self.aveCursor.peek(),
                .stack_vea => self.veaCursor.peek(),
                .stack_vae => self.vaeCursor.peek(),
            };
        }

        pub fn proposeByte(self: *@This(), bitset: *ByteBitset) void {
            switch(self.state) {
                .stack_empty => unreachable,

                .stack_e => self.eavCursor.propose(bitset),
                .stack_a => self.aevCursor.propose(bitset),
                .stack_v => self.veaCursor.propose(bitset),

                .stack_ea => self.eavCursor.propose(bitset),
                .stack_ev => self.evaCursor.propose(bitset),
                .stack_ae => self.aevCursor.propose(bitset),
                .stack_av => self.aveCursor.propose(bitset),
                .stack_ve => self.veaCursor.propose(bitset),
                .stack_va => self.vaeCursor.propose(bitset),

                .stack_eav => self.eavCursor.propose(bitset),
                .stack_eva => self.evaCursor.propose(bitset),
                .stack_aev => self.aevCursor.propose(bitset),
                .stack_ave => self.aveCursor.propose(bitset),
                .stack_vea => self.veaCursor.propose(bitset),
                .stack_vae => self.vaeCursor.propose(bitset),
            };
        }

        pub fn pushByte(self: *@This(), key_fragment: u8) void {
            switch(self.state) {
                .stack_empty => unreachable,

                .stack_e => {
                    self.eavCursor.push(key_fragment);
                    self.evaCursor.push(key_fragment);
                },
                .stack_a => {
                    self.aevCursor.push(key_fragment);
                    self.aveCursor.push(key_fragment);
                },
                .stack_v => {
                    self.veaCursor.push(key_fragment);
                    self.vaeCursor.push(key_fragment);
                },

                .stack_ea => self.eavCursor.push(key_fragment),
                .stack_ev => self.evaCursor.push(key_fragment),
                .stack_ae => self.aevCursor.push(key_fragment),
                .stack_av => self.aveCursor.push(key_fragment),
                .stack_ve => self.veaCursor.push(key_fragment),
                .stack_va => self.vaeCursor.push(key_fragment),

                .stack_eav => self.eavCursor.push(key_fragment),
                .stack_eva => self.evaCursor.push(key_fragment),
                .stack_aev => self.aevCursor.push(key_fragment),
                .stack_ave => self.aveCursor.push(key_fragment),
                .stack_vea => self.veaCursor.push(key_fragment),
                .stack_vae => self.vaeCursor.push(key_fragment),
            };
        }

        pub fn popByte(self: *@This()) void {
            switch(self.state) {
                .stack_empty => unreachable,

                .stack_e => {
                    self.eavCursor.pop();
                    self.evaCursor.pop();
                },
                .stack_a => {
                    self.aevCursor.pop();
                    self.aveCursor.pop();
                },
                .stack_v => {
                    self.veaCursor.pop();
                    self.vaeCursor.pop();
                },

                .stack_ea => self.eavCursor.pop(),
                .stack_ev => self.evaCursor.pop(),
                .stack_ae => self.aevCursor.pop(),
                .stack_av => self.aveCursor.pop(),
                .stack_ve => self.veaCursor.pop(),
                .stack_va => self.vaeCursor.pop(),

                .stack_eav => self.eavCursor.pop(),
                .stack_eva => self.evaCursor.pop(),
                .stack_aev => self.aevCursor.pop(),
                .stack_ave => self.aveCursor.pop(),
                .stack_vea => self.veaCursor.pop(),
                .stack_vae => self.vaeCursor.pop(),
            }
        }

        pub fn variables(self: *@This(), bitset: *ByteBitset) void {
            bitset.unsetAll();
            bitset.set(self.eVar);
            bitset.set(self.aVar);
            bitset.set(self.vVar);
        }

        pub fn pushVariable(self: *@This(), variable: u8) bool {
            if(self.eVar == variable) {
                self.state = switch(self.state) {
                    .stack_empty => .stack_e,

                    .stack_a => .stack_ae,
                    .stack_v => .stack_ve,

                    .stack_av => .stack_ave,
                    .stack_va => .stack_vae,

                    else => unreachable,
                }
                return;
            }
            if(self.aVar == variable) {
                self.state = switch(self.state) {
                    .stack_empty => .stack_a,

                    .stack_e => .stack_ea,
                    .stack_v => .stack_va,

                    .stack_ev => .stack_eva,
                    .stack_ve => .stack_vea,

                    else => unreachable,
                }
                return;
            }
            if(self.vVar == variable) {
                self.state = switch(self.state) {
                    .stack_empty => .stack_v,

                    .stack_e => .stack_ev,
                    .stack_a => .stack_av,

                    .stack_ea => .stack_eav,
                    .stack_ae => .stack_aev,

                    else => unreachable,
                }
                return;
            }

        }
        
        pub fn popVariable(self: *@This()) bool {
            switch(self.state) {
                .stack_empty => unreachable,

                .stack_e =>   .stack_empty,
                .stack_a =>   .stack_empty,
                .stack_v =>   .stack_empty,

                .stack_ea =>  .stack_e,
                .stack_ev =>  .stack_e,
                .stack_ae =>  .stack_a,
                .stack_av =>  .stack_a,
                .stack_ve =>  .stack_v,
                .stack_va =>  .stack_v,

                .stack_eav => .stack_ea,
                .stack_eva => .stack_ev,
                .stack_aev => .stack_ae,
                .stack_ave => .stack_av,
                .stack_vea => .stack_ve,
                .stack_vae => .stack_va,
            }
        }

        pub fn countVariable(self: *@This(), variable: u8) usize {
            if(self.eVar == variable) {
                return switch(self.state) {
                    .stack_empty => self.eavCursor.segmentCount(),

                    .stack_a => self.aevCursor.segmentCount(),
                    .stack_v => self.veaCursor.segmentCount(),

                    .stack_av => self.aveCursor.segmentCount(),
                    .stack_va => self.vaeCursor.segmentCount(),

                    else => unreachable,
                }
            }
            if(self.aVar == variable) {
                return switch(self.state) {
                    .stack_empty => self.aevCursor.segmentCount(),

                    .stack_e => self.eavCursor.segmentCount(),
                    .stack_v => self.vaeCursor.segmentCount(),

                    .stack_ev => self.evaCursor.segmentCount(),
                    .stack_ve => self.veaCursor.segmentCount(),

                    else => unreachable,
                }
            }
            if(self.vVar == variable) {
                return switch(self.state) {
                    .stack_empty => self.veaCursor.segmentCount(),

                    .stack_e => self.evaCursor.segmentCount(),
                    .stack_a => self.aveCursor.segmentCount(),

                    .stack_ea => self.eavCursor.segmentCount(),
                    .stack_ae => self.aevCursor.segmentCount(),

                    else => unreachable,
                }
            }
        }

        pub fn sampleVariable(self: *@This(), variable: u8) usize {
            if(self.eVar == variable) {
                return switch(self.state) {
                    .stack_empty => self.eavCursor.minhash(),

                    .stack_a => self.aevCursor.minhash(),
                    .stack_v => self.veaCursor.minhash(),

                    .stack_av => self.aveCursor.minhash(),
                    .stack_va => self.vaeCursor.minhash(),

                    else => unreachable,
                }
            }
            if(self.aVar == variable) {
                return switch(self.state) {
                    .stack_empty => self.aevCursor.minhash(),

                    .stack_e => self.eavCursor.minhash(),
                    .stack_v => self.vaeCursor.minhash(),

                    .stack_ev => self.evaCursor.minhash(),
                    .stack_ve => self.veaCursor.minhash(),

                    else => unreachable,
                }
            }
            if(self.vVar == variable) {
                return switch(self.state) {
                    .stack_empty => self.veaCursor.minhash(),

                    .stack_e => self.evaCursor.minhash(),
                    .stack_a => self.aveCursor.minhash(),

                    .stack_ea => self.eavCursor.minhash(),
                    .stack_ae => self.aevCursor.minhash(),

                    else => unreachable,
                }
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) TribleSet {
        return TribleSet{
            .eav = EAVIndex.init(allocator),
            .eva = EVAIndex.init(allocator),
            .aev = AEVIndex.init(allocator),
            .ave = AVEIndex.init(allocator),
            .vea = VEAIndex.init(allocator),
            .vae = VAEIndex.init(allocator),
        };
    }

    pub fn deinit(self: *TribleSet) void {
        self.eav.deinit();
        self.eva.deinit();
        self.aev.deinit();
        self.ave.deinit();
        self.vea.deinit();
        self.vae.deinit();
    }

    pub fn fork(self: *TribleSet) allocError!TribleSet {
        return TribleSet{
            .eav = self.eav.fork(),
            .eva = self.eva.fork(),
            .aev = self.aev.fork(),
            .ave = self.ave.fork(),
            .vea = self.vea.fork(),
            .vae = self.vae.fork(),
        };
    }

    pub fn count(self: *const TribleSet) u64 {
        return self.eav.count();
    }

    pub fn put(self: *TribleSet, trible: *const Trible) allocError!void {
        try self.eav.put(trible.ordered(.eav), null);
        try self.eva.put(trible.ordered(.eva), null);
        try self.aev.put(trible.ordered(.aev), null);
        try self.ave.put(trible.ordered(.ave), null);
        try self.vea.put(trible.ordered(.vea), null);
        try self.vae.put(trible.ordered(.vae), null);
    }

    pub fn mem_info(self: *TribleSet) MemInfo {
        var total = MemInfo{};

        total = total.combine(self.eav.mem_info());
        total = total.combine(self.eva.mem_info());
        total = total.combine(self.aev.mem_info());
        total = total.combine(self.ave.mem_info());
        total = total.combine(self.vea.mem_info());
        total = total.combine(self.vae.mem_info());

        return total;
    }
};
