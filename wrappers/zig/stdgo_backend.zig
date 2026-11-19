const std = @import("std");
const s = @import("shuttle");

// Shuttle runs one Zig continuation at a time. A schedule point followed by
// one uninterrupted native atomic operation models sequential consistency.
pub fn Value(comptime T: type) type {
    return struct {
        raw: std.atomic.Value(T),
        const Self = @This();
        const Order = std.builtin.AtomicOrder;
        pub fn init(v: T) Self {
            return .{ .raw = .init(v) };
        }
        pub fn load(self: *const Self, comptime order: Order) T {
            s.yield();
            return self.raw.load(order);
        }
        pub fn store(self: *Self, v: T, comptime order: Order) void {
            s.yield();
            self.raw.store(v, order);
        }
        pub fn swap(self: *Self, v: T, comptime order: Order) T {
            s.yield();
            return self.raw.swap(v, order);
        }
        pub fn fetchAdd(self: *Self, v: T, comptime order: Order) T {
            s.yield();
            return self.raw.fetchAdd(v, order);
        }
        pub fn cmpxchgStrong(self: *Self, old: T, new: T, comptime success: Order, comptime failure: Order) ?T {
            s.yield();
            return self.raw.cmpxchgStrong(old, new, success, failure);
        }
    };
}

pub const Thread = struct {
    task: s.Thread,
    pub fn spawn(_: std.Thread.SpawnConfig, comptime f: anytype, args: anytype) !Thread {
        const Arg = @TypeOf(args[0]);
        const Worker = struct {
            fn run(ctx: Arg) !void {
                f(ctx);
            }
        };
        return .{ .task = s.Thread.spawn(args[0], Worker.run) };
    }
    pub fn yield() !void {
        s.yield();
    }
    pub fn join(self: Thread) void {
        self.task.join();
    }
    pub fn detach(self: Thread) void {
        self.task.detach();
    }
};
