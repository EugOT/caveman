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
//   caveman-claw        — lib-helper test binary (src/claw_tests.zig, R4b)
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

    // R4b stage 1 lib helpers ported from bin/lib/*.js. These are importable
    // MODULES the installer port (stage 2) `@import`s instead of shelling out:
    //   - openclaw.zig        ← bin/lib/openclaw.js  (frontmatter merge, SOUL
    //                            append/strip, install/uninstall)
    //   - nullclaw.zig        ← bin/lib/nullclaw.js  (workspace resolution +
    //                            always-on skill install; reuses openclaw merge)
    //   - opencode_agent.zig  ← bin/lib/opencode-agent.js (tools: frontmatter
    //                            strip)
    // openclaw.zig + nullclaw.zig depend on common.zig (the symlink-safe write
    // core) so the modules carry it as a named import; nullclaw also imports
    // openclaw for the shared frontmatter merge. All link libc (common.zig is
    // C-ABI).
    const common_dep_mod = b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    common_dep_mod.link_libc = true;
    common_dep_mod.addOptions("build_options", opts);

    const openclaw_module = b.addModule("openclaw", .{
        .root_source_file = b.path("src/openclaw.zig"),
        .target = target,
        .optimize = optimize,
    });
    openclaw_module.link_libc = true;
    openclaw_module.addImport("common.zig", common_dep_mod);

    const nullclaw_module = b.addModule("nullclaw", .{
        .root_source_file = b.path("src/nullclaw.zig"),
        .target = target,
        .optimize = optimize,
    });
    nullclaw_module.link_libc = true;
    nullclaw_module.addImport("common.zig", common_dep_mod);
    nullclaw_module.addImport("openclaw.zig", openclaw_module);

    const opencode_agent_module = b.addModule("opencode_agent", .{
        .root_source_file = b.path("src/opencode_agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    opencode_agent_module.link_libc = true;

    // R4b stage 2 — the installer port (src/install.zig). A single binary,
    // `caveman-install`, that detects installed agents and installs caveman for
    // each. It IMPORTS the stage-1 lib modules (openclaw/nullclaw/opencode_agent)
    // and the R4a settings module by the same names the source `@import`s, plus a
    // dedicated common.zig clone (the importable modules above are configured for
    // their own roots, so install gets its own wiring). All link libc.
    const installModules = struct {
        fn make(
            bld: *std.Build,
            tgt: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
            options: *std.Build.Step.Options,
            mod: *std.Build.Module,
        ) void {
            const inst_common = bld.createModule(.{
                .root_source_file = bld.path("src/common.zig"),
                .target = tgt,
                .optimize = opt,
            });
            inst_common.link_libc = true;
            inst_common.addOptions("build_options", options);

            const inst_settings = bld.createModule(.{
                .root_source_file = bld.path("src/settings.zig"),
                .target = tgt,
                .optimize = opt,
            });
            inst_settings.link_libc = true;

            const inst_openclaw = bld.createModule(.{
                .root_source_file = bld.path("src/openclaw.zig"),
                .target = tgt,
                .optimize = opt,
            });
            inst_openclaw.link_libc = true;
            inst_openclaw.addImport("common.zig", inst_common);

            const inst_nullclaw = bld.createModule(.{
                .root_source_file = bld.path("src/nullclaw.zig"),
                .target = tgt,
                .optimize = opt,
            });
            inst_nullclaw.link_libc = true;
            inst_nullclaw.addImport("common.zig", inst_common);
            inst_nullclaw.addImport("openclaw.zig", inst_openclaw);

            const inst_opencode_agent = bld.createModule(.{
                .root_source_file = bld.path("src/opencode_agent.zig"),
                .target = tgt,
                .optimize = opt,
            });
            inst_opencode_agent.link_libc = true;

            mod.link_libc = true;
            mod.addOptions("build_options", options);
            mod.addImport("common.zig", inst_common);
            mod.addImport("settings.zig", inst_settings);
            mod.addImport("openclaw.zig", inst_openclaw);
            mod.addImport("nullclaw.zig", inst_nullclaw);
            mod.addImport("opencode_agent.zig", inst_opencode_agent);
        }
    };

    const install_exe = b.addExecutable(.{
        .name = b.fmt("{s}-install", .{tool}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/install.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    installModules.make(b, target, optimize, opts, install_exe.root_module);
    b.installArtifact(install_exe);

    const run_install_step = b.step("run-install", "Run the caveman-install installer");
    const run_install = b.addRunArtifact(install_exe);
    if (b.args) |args| run_install.addArgs(args);
    run_install_step.dependOn(&run_install.step);

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

    // R4b stage 1 lib-helper test roots. Each is its own test artifact (a test
    // artifact's root module is distinct from the importable addModule above, so
    // their `common.zig` / `openclaw.zig` imports must be wired per-root). They
    // join the same `test` step. opencode_agent.zig is a pure transform with no
    // common.zig dependency. A dedicated `caveman-claw` test binary is also
    // installed so the three lib modules can be exercised by name.
    const ClawTestRoot = struct {
        name: []const u8,
        src: []const u8,
        needs_common: bool,
        needs_openclaw: bool,
    };
    const claw_roots = [_]ClawTestRoot{
        .{ .name = "openclaw", .src = "src/openclaw.zig", .needs_common = true, .needs_openclaw = false },
        .{ .name = "nullclaw", .src = "src/nullclaw.zig", .needs_common = true, .needs_openclaw = true },
        .{ .name = "opencode_agent", .src = "src/opencode_agent.zig", .needs_common = false, .needs_openclaw = false },
    };
    for (claw_roots) |root| {
        const claw_common = b.createModule(.{
            .root_source_file = b.path("src/common.zig"),
            .target = target,
            .optimize = optimize,
        });
        claw_common.link_libc = true;
        claw_common.addOptions("build_options", opts);

        const claw_openclaw = b.createModule(.{
            .root_source_file = b.path("src/openclaw.zig"),
            .target = target,
            .optimize = optimize,
        });
        claw_openclaw.link_libc = true;
        claw_openclaw.addImport("common.zig", claw_common);

        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root.src),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.link_libc = true;
        t.root_module.addOptions("build_options", opts);
        if (root.needs_common) t.root_module.addImport("common.zig", claw_common);
        if (root.needs_openclaw) t.root_module.addImport("openclaw.zig", claw_openclaw);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // caveman-claw — a tiny aggregate test binary that re-exports the three lib
    // modules so `zig build` produces a named artifact a maintainer can run the
    // lib tests against directly (`zig build test` covers them too).
    {
        const claw_common = b.createModule(.{
            .root_source_file = b.path("src/common.zig"),
            .target = target,
            .optimize = optimize,
        });
        claw_common.link_libc = true;
        claw_common.addOptions("build_options", opts);
        const claw_openclaw = b.createModule(.{
            .root_source_file = b.path("src/openclaw.zig"),
            .target = target,
            .optimize = optimize,
        });
        claw_openclaw.link_libc = true;
        claw_openclaw.addImport("common.zig", claw_common);

        const claw_nullclaw = b.createModule(.{
            .root_source_file = b.path("src/nullclaw.zig"),
            .target = target,
            .optimize = optimize,
        });
        claw_nullclaw.link_libc = true;
        claw_nullclaw.addImport("common.zig", claw_common);
        claw_nullclaw.addImport("openclaw.zig", claw_openclaw);

        const claw_opencode_agent = b.createModule(.{
            .root_source_file = b.path("src/opencode_agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        claw_opencode_agent.link_libc = true;

        const claw_test = b.addTest(.{
            .name = b.fmt("{s}-claw", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/claw_tests.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        claw_test.root_module.link_libc = true;
        claw_test.root_module.addOptions("build_options", opts);
        claw_test.root_module.addImport("openclaw.zig", claw_openclaw);
        claw_test.root_module.addImport("nullclaw.zig", claw_nullclaw);
        claw_test.root_module.addImport("opencode_agent.zig", claw_opencode_agent);
        b.installArtifact(claw_test);

        const run_claw_step = b.step("test-claw", "Run the caveman-claw lib-helper tests");
        run_claw_step.dependOn(&b.addRunArtifact(claw_test).step);
        test_step.dependOn(&b.addRunArtifact(claw_test).step);
    }

    // R4b stage 2 — installer test root. install.zig imports the lib modules by
    // the same names the source uses; wire them per-test-root (a test artifact's
    // root module is distinct from the importable addModule wiring above).
    {
        const inst_common = b.createModule(.{
            .root_source_file = b.path("src/common.zig"),
            .target = target,
            .optimize = optimize,
        });
        inst_common.link_libc = true;
        inst_common.addOptions("build_options", opts);

        const inst_settings = b.createModule(.{
            .root_source_file = b.path("src/settings.zig"),
            .target = target,
            .optimize = optimize,
        });
        inst_settings.link_libc = true;

        const inst_openclaw = b.createModule(.{
            .root_source_file = b.path("src/openclaw.zig"),
            .target = target,
            .optimize = optimize,
        });
        inst_openclaw.link_libc = true;
        inst_openclaw.addImport("common.zig", inst_common);

        const inst_nullclaw = b.createModule(.{
            .root_source_file = b.path("src/nullclaw.zig"),
            .target = target,
            .optimize = optimize,
        });
        inst_nullclaw.link_libc = true;
        inst_nullclaw.addImport("common.zig", inst_common);
        inst_nullclaw.addImport("openclaw.zig", inst_openclaw);

        const inst_opencode_agent = b.createModule(.{
            .root_source_file = b.path("src/opencode_agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        inst_opencode_agent.link_libc = true;

        const install_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/install.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        install_test.root_module.link_libc = true;
        install_test.root_module.addOptions("build_options", opts);
        install_test.root_module.addImport("common.zig", inst_common);
        install_test.root_module.addImport("settings.zig", inst_settings);
        install_test.root_module.addImport("openclaw.zig", inst_openclaw);
        install_test.root_module.addImport("nullclaw.zig", inst_nullclaw);
        install_test.root_module.addImport("opencode_agent.zig", inst_opencode_agent);
        test_step.dependOn(&b.addRunArtifact(install_test).step);
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
