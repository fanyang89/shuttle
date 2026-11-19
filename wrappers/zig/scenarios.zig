const std = @import("std");
const s = @import("shuttle");

const Counter = struct {
    mutex: s.Mutex,
    n: u32 = 0,

    fn inc(ctx: *Counter) !void {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        const n = ctx.n;
        s.yield();
        ctx.n = n + 1;
    }
};

fn locked() !void {
    var ctx = Counter{ .mutex = .init() };
    defer ctx.mutex.deinit();
    if (!ctx.mutex.tryLock()) return error.ExpectedUnlocked;
    if (ctx.mutex.tryLock()) return error.ExpectedLocked;
    ctx.mutex.unlock();
    const child = s.Thread.spawn(&ctx, Counter.inc);
    try Counter.inc(&ctx);
    child.join();
    if (ctx.n != 2) return error.WrongCount;
}

fn brokenInc(a: *s.AtomicU32) !void {
    a.store(a.load(.monotonic) + 1, .monotonic);
}

fn lostUpdate() !void {
    var a = s.AtomicU32.init(0);
    defer a.deinit();
    const t = s.Thread.spawn(&a, brokenInc);
    try brokenInc(&a);
    t.join();
    if (a.load(.acquire) != 2) return error.LostUpdate;
}

fn atomics() !void {
    const a = s.AtomicU32.init(1);
    defer a.deinit();
    if (a.fetchAdd(2, .monotonic) != 1 or a.swap(7, .seq_cst) != 3) return error.BadRmw;
    if (a.cmpxchgStrong(3, 9, .acq_rel, .acquire) != 7) return error.BadCas;
    if (a.cmpxchgStrong(7, 9, .acq_rel, .acquire) != null or a.load(.acquire) != 9) return error.BadCas;
}

fn deadlock() !void {
    const mutex = s.Mutex.init();
    defer mutex.deinit();
    mutex.lock();
    mutex.lock();
}

fn spin() !void {
    while (true) s.yield();
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return error.InvalidArguments;
    inline for (.{ "locked", "atomics", "lost-update", "deadlock", "spin" }, .{ locked, atomics, lostUpdate, deadlock, spin }) |name, scenario| {
        if (std.mem.eql(u8, args[1], name)) {
            const steps = 128;
            if (args.len == 3) s.replay(scenario, args[2], steps) else s.checkRandom(scenario, .{ .seed = 42, .max_steps = steps });
            return;
        }
    }
    return error.UnknownScenario;
}
