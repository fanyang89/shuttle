const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "-p", "shuttle-ffi", "--profile", "zig-test", "--target-dir", "target" });
    cargo.setCwd(b.path("../.."));
    const header = b.addTranslateC(.{
        .root_source_file = b.path("../../shuttle-ffi/include/shuttle.h"),
        .target = target,
        .optimize = optimize,
    });
    const adapter = b.addModule("shuttle", .{ .root_source_file = b.path("shuttle.zig"), .target = target, .optimize = optimize });
    adapter.addImport("shuttle_c", header.createModule());
    adapter.addObjectFile(b.path("../../target/zig-test/libshuttle_ffi.a"));
    adapter.linkSystemLibrary("gcc_s", .{});
    const tests = b.step("test", "Run isolated Zig concurrency scenarios");
    const exe = b.addExecutable(.{ .name = "zig-scenarios", .root_module = b.createModule(.{
        .root_source_file = b.path("scenarios.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    exe.root_module.addImport("shuttle", adapter);
    exe.step.dependOn(&cargo.step);
    const verify = b.addSystemCommand(&.{"python3"});
    verify.addFileArg(b.path("verify.py"));
    verify.addArtifactArg(exe);
    tests.dependOn(&verify.step);

    const scenario_exe = if (b.option([]const u8, "scenario", "Zig scenario executable source path")) |path| blk: {
        const app = b.addExecutable(.{ .name = "shuttle-scenario", .root_module = b.createModule(.{
            .root_source_file = b.graph.cwdRelativePath(path),
            .target = target,
            .optimize = optimize,
        }) });
        app.root_module.addImport("shuttle", adapter);
        app.step.dependOn(&cargo.step);
        break :blk app;
    } else exe;
    const run = b.addRunArtifact(scenario_exe);
    run.addPassthruArgs();
    b.step("run", "Run a scenario in its own process").dependOn(&run.step);

    if (b.option([]const u8, "stdgo", "Path to the instrumentable stdgo fork")) |path| {
        const suite = b.addExecutable(.{ .name = "stdgo-sync", .root_module = b.createModule(.{
            .root_source_file = b.path("stdgo_sync.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        suite.root_module.addImport("shuttle", adapter);
        suite.root_module.addImport("stdgo", b.createModule(.{
            .root_source_file = b.graph.cwdRelativePath(b.pathJoin(&.{ path, "src/root.zig" })),
        }));
        suite.step.dependOn(&cargo.step);
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("verify.py"));
        check.addArtifactArg(suite);
        check.addArg("stdgo");
        tests.dependOn(&check.step);
        const reproduce = b.addRunArtifact(suite);
        reproduce.addPassthruArgs();
        b.step("stdgo-run", "Run or replay a stdgo scenario").dependOn(&reproduce.step);
    }
}
