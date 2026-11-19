const std = @import("std");
const s = @import("shuttle");
const go = @import("stdgo");
const alloc = std.heap.page_allocator;

const State = struct {
    counter: go.expvar.Float = .{},
    limiter: go.time.rate.Limiter = .init(1, 1),
    allowed: usize = 0,
    jar: go.net.http.CookieJar,
    ctx: *go.context.CancelContext,
    fn work(self: *State) !void {
        self.ctx.cancel();
        if (!self.ctx.isDone()) return error.CancelLost;
        self.counter.add(1);
        if (self.limiter.allowN(go.time.Time.unix(1, 0), 1)) self.allowed += 1;
        try self.jar.setCookiesFromHeader("example.org", "a=1");
        const header = try self.jar.formatCookieHeader(alloc, "example.org") orelse return error.CookieLost;
        defer alloc.free(header);
        if (!std.mem.eql(u8, header, "a=1")) return error.CookieCorrupt;
    }
};

pub fn consumers() !void {
    const ctx = try go.context.withCancel(alloc, go.context.background());
    defer ctx.deinit(alloc);
    var state = State{ .jar = go.net.http.CookieJar.init(alloc), .ctx = ctx };
    defer state.jar.deinit();
    const t = s.Thread.spawn(&state, State.work);
    try state.work();
    t.join();
    if (state.allowed != 1 or state.counter.value() != 2) return error.WrongCount;
}

fn write(p: *go.net.PipePair) !void {
    defer p.conn1.close();
    if (try p.conn1.write("x") != 1) return error.ShortWrite;
}
pub fn pipe() !void {
    var p = try go.net.pipe(alloc);
    defer p.conn2.close();
    const t = s.Thread.spawn(&p, write);
    defer t.join();
    var buf: [1]u8 = undefined;
    if (try p.conn2.read(&buf) != 1 or buf[0] != 'x') return error.WrongByte;
    if (try p.conn2.read(&buf) != 0) return error.MissingEof;
}

const sql = go.database.sql;
fn query(db: *sql.DB) !void {
    const conn = try db.conn();
    defer conn.release();
    s.yield();
}
pub fn database() !void {
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var state = sql.MockDriver.State.init(alloc);
    defer state.deinit();
    var mock = sql.MockDriver{ .state = &state };
    const db = try sql.DB.open(alloc, threaded.io(), mock.driver(), "mock");
    const t = s.Thread.spawn(db, query);
    try query(db);
    t.join();
    db.close();
    if (state.open_count == 0 or state.open_count != state.close_count) return error.LeakedConnection;
}
