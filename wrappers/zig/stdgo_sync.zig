const std = @import("std");
const s = @import("shuttle");
const go = @import("stdgo");
const sync = go.sync;
const clients = @import("stdgo_consumers.zig");
pub const stdgo_sync_backend = @import("stdgo_backend.zig");
const alloc = std.heap.page_allocator;

fn pair(ctx: anytype, comptime work: fn (@TypeOf(ctx)) anyerror!void) !void {
    const t = s.Thread.spawn(ctx, work);
    defer t.join();
    try work(ctx);
}

const Basic = struct {
    mu: sync.Mutex = .{},
    once: sync.Once = .{},
    wg: sync.WaitGroup = .{},
    n: usize = 0,
    initialized: usize = 0,
    fn initialize(b: *Basic) void {
        s.yield();
        b.initialized += 1;
    }
    fn worker(b: *Basic) !void {
        defer b.wg.done();
        b.once.do(initialize, .{b});
        if (b.initialized != 1) return error.Once;
        b.mu.lock();
        defer b.mu.unlock();
        if (b.mu.tryLock()) return error.Nonexclusive;
        const prev = b.n;
        s.yield();
        b.n = prev + 1;
    }
};

fn basics() !void {
    var b = Basic{};
    b.wg.add(2);
    const a = s.Thread.spawn(&b, Basic.worker);
    const c = s.Thread.spawn(&b, Basic.worker);
    b.wg.wait();
    if (b.n != 2) return error.EarlyWait;
    a.join();
    c.join();
}

const Pool = sync.Pool(u32);
fn poolWorker(p: *Pool) !void {
    if (try p.get()) |item| {
        const old = item.*;
        s.yield();
        item.* = old + 1;
        try p.put(item);
    }
}
fn pool() !void {
    var p = Pool.init(alloc, null);
    defer p.deinit(null);
    var first: u32 = 0;
    var second: u32 = 0;
    try p.put(&first);
    try p.put(&second);
    try pair(&p, poolWorker);
    const a = try p.get() orelse return error.Missing;
    const b = try p.get() orelse return error.Missing;
    if (a == b or first + second != 2 or try p.get() != null) return error.PoolOwnership;
}

const Sem = struct {
    sem: sync.Semaphore = .init(2, null),
    inside: u8 = 0,
    fn worker(ctx: *Sem) !void {
        try ctx.sem.acquire(go.context.background(), 2);
        defer ctx.sem.release(2);
        ctx.inside += 1;
        s.yield();
        if (ctx.inside != 1 or ctx.sem.tryAcquire(1)) return error.Capacity;
        ctx.inside -= 1;
    }
};
fn semaphore() !void {
    var ctx = Sem{};
    try pair(&ctx, Sem.worker);
    if (!ctx.sem.tryAcquire(2)) return error.LeakedPermit;
    ctx.sem.release(2);
}
fn canceled() !void {
    var sem = sync.Semaphore.init(1, null);
    const ctx = try go.context.withCancel(alloc, go.context.background());
    defer ctx.deinit(alloc);
    ctx.cancel();
    sem.acquire(ctx.context(), 1) catch |err| {
        if (err == error.Canceled) return;
        return err;
    };
    sem.release(1);
    return error.AcquiredAfterCancellation;
}

fn groupWork(n: *usize) !void {
    const prev = n.*;
    s.yield();
    n.* = prev + 1;
    return error.WorkerError;
}
fn errgroup() !void {
    var g = sync.ErrGroup.init(alloc);
    defer g.deinit();
    g.setLimit(1);
    var n: usize = 0;
    try g.spawn(groupWork, .{&n});
    try g.spawn(groupWork, .{&n});
    const err = g.wait() orelse return error.MissingError;
    if (err != error.WorkerError or n != 2) return error.GroupResult;
}

const Flight = struct {
    group: sync.SingleFlight(u32),
    calls: usize = 0,
    shared: usize = 0,
    fn compute(ctx: *Flight) u32 {
        ctx.calls += 1;
        s.yield();
        return 17;
    }
    fn worker(ctx: *Flight) !void {
        const result = try ctx.group.do("same", compute, .{ctx});
        if (result.val != 17) return error.BadResult;
        if (result.shared) ctx.shared += 1;
    }
};
fn flight() !void {
    var ctx = Flight{ .group = .init(alloc) };
    defer ctx.group.deinit();
    try pair(&ctx, Flight.worker);
    if (ctx.group.forget("same")) return error.RetainedCall;
    if (ctx.shared != (if (ctx.calls == 1) @as(usize, 2) else 0)) return error.IncorrectShared;
}

fn groupOom() !void {
    var storage: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var g = sync.ErrGroup.init(fba.allocator());
    defer g.deinit();
    g.setLimit(1);
    var n: usize = 0;
    if (g.spawn(groupWork, .{&n})) |_| return error.ExpectedOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    // No task was created: wait must return without waiting for a worker.
    if (g.wait() != null) return error.UnexpectedWorker;
}

fn flightOom() !void {
    var storage: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var ctx = Flight{ .group = .init(fba.allocator()) };
    if (ctx.group.do("same", Flight.compute, .{&ctx})) |_| return error.ExpectedOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    // No calls are outstanding. Check the lock directly before deinit would spin.
    if (!ctx.group.mu.tryLock()) return error.LockHeldAfterAllocationFailure;
    ctx.group.mu.unlock();
    ctx.group.deinit();
}

fn groupDeinit() !void {
    var g = sync.ErrGroup.init(alloc);
    var n: usize = 0;
    try g.spawn(groupWork, .{&n});
    g.deinit();
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return error.InvalidArguments;
    inline for (.{ "basic", "pool", "semaphore", "errgroup", "singleflight", "canceled", "group-oom", "flight-oom", "group-deinit", "clients", "pipe", "db" }, .{ basics, pool, semaphore, errgroup, flight, canceled, groupOom, flightOom, groupDeinit, clients.consumers, clients.pipe, clients.database }) |name, scenario| {
        if (std.mem.eql(u8, args[1], name)) {
            const limit = if (comptime std.mem.eql(u8, name, "group-oom") or std.mem.eql(u8, name, "group-deinit")) 64 else 4096;
            if (args.len == 3) s.replay(scenario, args[2], limit) else s.checkRandom(scenario, .{ .seed = 42, .iterations = 200, .max_steps = limit });
            return;
        }
    }
    return error.UnknownScenario;
}
