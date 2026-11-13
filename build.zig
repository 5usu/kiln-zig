const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("kiln", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const cli_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    cli_module.addImport("kiln", module);
    const cli = b.addExecutable(.{ .name = "kiln", .root_module = cli_module });
    b.installArtifact(cli);
    const run = b.addRunArtifact(cli);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Parse a JSON file and optionally look up a root key").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run parser and allocator-failure tests").dependOn(&run_tests.step);
    const lib = b.addLibrary(.{ .name = "kiln", .linkage = .dynamic, .root_module = b.createModule(.{ .root_source_file = b.path("src/c_api.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    b.installArtifact(lib);
}
