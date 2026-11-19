const std = @import("std");
const c = @import("shuttle_c");

pub const Options = struct {
    iterations: usize = 100,
    seed: ?u64 = null,
    max_steps: usize = 1_000_000,
};

fn scenarioCallback(comptime scenario: fn () anyerror!void) c.shuttle_callback {
    return struct {
        fn run(_: ?*anyopaque) callconv(.c) [*c]const u8 {
            scenario() catch |err| return @errorName(err).ptr;
            return null;
        }
    }.run;
}

pub fn checkRandom(comptime scenario: fn () anyerror!void, options: Options) void {
    c.shuttle_run(scenarioCallback(scenario), options.iterations, if (options.seed) |*s| s else null, null, options.max_steps);
}

pub fn replay(comptime scenario: fn () anyerror!void, schedule: [:0]const u8, max_steps: usize) void {
    c.shuttle_run(scenarioCallback(scenario), 1, null, schedule.ptr, max_steps);
}

pub const Thread = struct {
    handle: *c.struct_shuttle_task,

    /// ctx must remain live until join returns.
    pub fn spawn(ctx: anytype, comptime worker: fn (@TypeOf(ctx)) anyerror!void) Thread {
        const Callback = struct {
            fn run(raw: ?*anyopaque) callconv(.c) [*c]const u8 {
                worker(@ptrCast(@alignCast(raw.?))) catch |err| return @errorName(err).ptr;
                return null;
            }
        };
        return .{ .handle = c.shuttle_spawn(Callback.run, ctx).? };
    }

    pub fn join(self: Thread) void {
        c.shuttle_join(self.handle);
    }

    pub fn detach(self: Thread) void {
        c.shuttle_detach(self.handle);
    }
};

pub fn yield() void {
    c.shuttle_yield();
}

pub const Mutex = struct {
    ptr: *c.struct_shuttle_mutex,

    pub fn init() Mutex {
        return .{ .ptr = c.shuttle_mutex_new().? };
    }
    pub fn deinit(self: Mutex) void {
        c.shuttle_mutex_free(self.ptr);
    }
    pub fn lock(self: Mutex) void {
        c.shuttle_mutex_lock(self.ptr);
    }
    pub fn tryLock(self: Mutex) bool {
        return c.shuttle_mutex_try(self.ptr);
    }
    pub fn unlock(self: Mutex) void {
        c.shuttle_mutex_unlock(self.ptr);
    }
};

/// Like Shuttle's Rust atomics, every ordering is modeled as sequentially consistent.
pub const AtomicU32 = struct {
    ptr: *c.struct_shuttle_u32,
    const Order = std.builtin.AtomicOrder;

    pub fn init(value: u32) AtomicU32 {
        return .{ .ptr = c.shuttle_u32_new(value).? };
    }
    pub fn deinit(self: AtomicU32) void {
        c.shuttle_u32_free(self.ptr);
    }
    pub fn load(self: AtomicU32, comptime order: Order) u32 {
        if (order == .release or order == .acq_rel) @compileError("invalid load order");
        return c.shuttle_u32_load(self.ptr);
    }
    pub fn store(self: AtomicU32, value: u32, comptime order: Order) void {
        if (order == .acquire or order == .acq_rel) @compileError("invalid store order");
        c.shuttle_u32_store(self.ptr, value);
    }
    pub fn swap(self: AtomicU32, value: u32, comptime _: Order) u32 {
        return c.shuttle_u32_swap(self.ptr, value);
    }
    pub fn fetchAdd(self: AtomicU32, value: u32, comptime _: Order) u32 {
        return c.shuttle_u32_add(self.ptr, value);
    }
    pub fn cmpxchgStrong(self: AtomicU32, old: u32, new: u32, comptime success: Order, comptime failure: Order) ?u32 {
        // Let the compiler apply the same ordering constraints as std.atomic.Value.
        comptime {
            var check: u32 = 0;
            _ = @cmpxchgStrong(u32, &check, 0, 1, success, failure);
        }
        const actual = c.shuttle_u32_cas(self.ptr, old, new);
        return if (actual == old) null else actual;
    }
};
