const std = @import("std");

// Build all three hook binaries from one source tree, parameterized by -Dtool.
// Mirrors the real rewrite: one Zig codebase, comptime-selected tool identity.
//
//   caveman-hook        — UserPromptSubmit  (src/main.zig)
//   caveman-activate    — SessionStart      (src/activate.zig)
//   caveman-statusline  — statusline badge  (src/statusline.zig)
//   caveman-stats       — /caveman-stats    (src/stats.zig)
//   caveman-shrink      — MCP proxy         (src/shrink.zig)
//   caveman-init        — per-repo rule writer (src/init.zig)
//   caveman-settings    — settings.json transform CLI (src/settings.zig)
//
// The hook/activate/statusline/stats/init binaries share src/common.zig (TOOL
// identity, mode whitelist, config resolution, the symlink-safe flag write,
// history append/read). The shrink proxy is tool-agnostic (src/shrink.zig +
// src/compress.zig) but is built per -Dtool so it carries the right binary name
// prefix. settings.zig is a standalone module (used by the future installer
// port) plus a tiny CLI for the differential check.
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
        .{ .suffix = "stats", .src = "src/stats.zig" },
        .{ .suffix = "shrink", .src = "src/shrink.zig" },
        .{ .suffix = "init", .src = "src/init.zig" },
        .{ .suffix = "settings", .src = "src/settings.zig" },
    };

    // The UserPromptSubmit hook keeps the `run` step (it reads stdin); the stats
    // binary gets its own `run-stats` step (it takes --session-file args, used
    // by the differential check). activate / statusline are install-only.
    var hook_exe: ?*std.Build.Step.Compile = null;
    var stats_exe: ?*std.Build.Step.Compile = null;
    var shrink_exe: ?*std.Build.Step.Compile = null;
    var init_exe: ?*std.Build.Step.Compile = null;
    var settings_exe: ?*std.Build.Step.Compile = null;

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
        // init.zig @embedFile's the rule + skill sources, which live OUTSIDE the
        // zig/ package root (src/rules/, skills/). Zig refuses cross-package
        // embeds via a relative path, so expose them as named anonymous imports
        // the module CAN reach. init.zig imports them with @import("...").
        if (std.mem.eql(u8, bin.suffix, "init")) addInitEmbeds(b, exe.root_module);
        b.installArtifact(exe);
        if (std.mem.eql(u8, bin.suffix, "hook")) hook_exe = exe;
        if (std.mem.eql(u8, bin.suffix, "stats")) stats_exe = exe;
        if (std.mem.eql(u8, bin.suffix, "shrink")) shrink_exe = exe;
        if (std.mem.eql(u8, bin.suffix, "init")) init_exe = exe;
        if (std.mem.eql(u8, bin.suffix, "settings")) settings_exe = exe;
    }

    // settings.zig is also exported as an importable module so the future
    // installer port (R4b) can `@import` the JSONC reader / hook validators
    // directly instead of shelling out to the caveman-settings CLI.
    const settings_module = b.addModule("settings", .{
        .root_source_file = b.path("src/settings.zig"),
        .target = target,
        .optimize = optimize,
    });
    settings_module.link_libc = true;

    const run_step = b.step("run", "Run the UserPromptSubmit hook");
    const run = b.addRunArtifact(hook_exe.?);
    if (b.args) |args| run.addArgs(args);
    run_step.dependOn(&run.step);

    const run_stats_step = b.step("run-stats", "Run the caveman-stats binary");
    const run_stats = b.addRunArtifact(stats_exe.?);
    if (b.args) |args| run_stats.addArgs(args);
    run_stats_step.dependOn(&run_stats.step);

    const run_shrink_step = b.step("run-shrink", "Run the caveman-shrink MCP proxy");
    const run_shrink = b.addRunArtifact(shrink_exe.?);
    if (b.args) |args| run_shrink.addArgs(args);
    run_shrink_step.dependOn(&run_shrink.step);

    const run_init_step = b.step("run-init", "Run the caveman-init per-repo rule writer");
    const run_init = b.addRunArtifact(init_exe.?);
    if (b.args) |args| run_init.addArgs(args);
    run_init_step.dependOn(&run_init.step);

    const run_settings_step = b.step("run-settings", "Run the caveman-settings transform CLI");
    const run_settings = b.addRunArtifact(settings_exe.?);
    if (b.args) |args| run_settings.addArgs(args);
    run_settings_step.dependOn(&run_settings.step);

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
        if (std.mem.eql(u8, bin.suffix, "init")) addInitEmbeds(b, t.root_module);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

// Wire the two cross-package source-of-truth files init.zig embeds. The rule
// body lives at src/rules/caveman-activate.md and the skill body at
// skills/caveman/SKILL.md — both above the zig/ package root, so they reach
// init.zig as named imports rather than a relative @embedFile. Paths are
// relative to the build root (zig/), hence the `../` hop into the repo.
fn addInitEmbeds(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("rule_body", .{
        .root_source_file = b.path("../src/rules/caveman-activate.md"),
    });
    module.addAnonymousImport("skill_body", .{
        .root_source_file = b.path("../skills/caveman/SKILL.md"),
    });
}
