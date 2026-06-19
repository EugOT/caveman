const std = @import("std");

// Build all three hook binaries from one source tree, parameterized by -Dtool.
// Mirrors the real rewrite: one Zig codebase, comptime-selected tool identity.
//
//   caveman-hook        — UserPromptSubmit  (src/main.zig)
//   caveman-activate    — SessionStart      (src/activate.zig)
//   caveman-statusline  — statusline badge  (src/statusline.zig)
//
// All three share src/common.zig (TOOL identity, mode whitelist, config
// resolution, the symlink-safe flag write).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tool = b.option([]const u8, "tool", "caveman | ponytail") orelse "caveman";

    // Reject typos at configure time — an unknown -Dtool would silently build a
    // binary with a broken command prefix and flag filename.
    if (!std.mem.eql(u8, tool, "caveman") and !std.mem.eql(u8, tool, "ponytail")) {
        std.debug.print("error: -Dtool must be 'caveman' or 'ponytail', got '{s}'\n", .{tool});
        std.process.exit(1);
    }

    const opts = b.addOptions();
    opts.addOption([]const u8, "tool", tool);

    // ── Executables ─────────────────────────────────────────────────────────
    const Bin = struct {
        suffix: []const u8, // "hook" | "activate" | "statusline"
        src: []const u8, // root source file
    };
    const bins = [_]Bin{
        .{ .suffix = "hook", .src = "src/main.zig" },
        .{ .suffix = "activate", .src = "src/activate.zig" },
        .{ .suffix = "statusline", .src = "src/statusline.zig" },
    };

    // The UserPromptSubmit hook keeps the `run` step (it reads stdin), matching
    // the original build. The other two are install-only artifacts.
    var hook_exe: ?*std.Build.Step.Compile = null;

    for (bins) |bin| {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-{s}", .{ tool, bin.suffix }),
            .root_module = b.createModule(.{
                .root_source_file = b.path(bin.src),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.link_libc = true;
        b.installArtifact(exe);
        if (std.mem.eql(u8, bin.suffix, "hook")) hook_exe = exe;
    }

    const run_step = b.step("run", "Run the UserPromptSubmit hook");
    const run = b.addRunArtifact(hook_exe.?);
    if (b.args) |args| run.addArgs(args);
    run_step.dependOn(&run.step);

    // ── Tests ───────────────────────────────────────────────────────────────
    // One test artifact per source root; the `test` step runs them all. Each
    // root pulls in common.zig via refAllDecls, so the shared security core is
    // exercised regardless of which root is built.
    const test_step = b.step("test", "Run unit tests");
    for (bins) |bin| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(bin.src),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.addOptions("build_options", opts);
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
