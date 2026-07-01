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

    // ── Coverage (-Dtest-coverage) ────────────────────────────────────────────
    // When set, every test binary is run under kcov instead of directly, emitting
    // line+branch coverage into zig-out/coverage/. kcov is provisioned via the
    // project flake devShell (see ../flake.nix); CI runs `zig build test
    // -Dtest-coverage` on the self-hosted runners. The `--exclude-pattern` list
    // drops Zig constructs that must never execute (unreachable / @panic / the
    // test blocks themselves) so they don't count as uncovered lines.
    //
    // covRun() returns the build step to depend on for a given test artifact:
    //   - coverage off → a plain RunArtifact (unchanged behavior)
    //   - coverage on  → a kcov system command wrapping the emitted test binary
    // The merged report lives at zig-out/coverage/merged (kcov --merge).
    const test_coverage = b.option(bool, "test-coverage", "Run tests under kcov (line+branch coverage → zig-out/coverage/)") orelse false;
    const cov = CoverageCtx{ .b = b, .enabled = test_coverage, .merge = if (test_coverage) b.step("coverage-merge", "Merge kcov per-binary reports") else null };

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
        // R5: post-compression integrity validator (port of
        // skills/caveman-compress/scripts/validate.py). Pure logic — no libc,
        // no FS beyond reading the two argv files, allocator-only. Built as a
        // standalone CLI used by the differential check, AND exported as an
        // importable module below so the shrink proxy can call validate()
        // in-process.
        .{ .suffix = "compress-validate", .src = "src/compress_validate.zig" },
        // R5: caveman-compress file-type detection (port of
        // skills/caveman-compress/scripts/detect.py). Pure classification logic
        // — no LLM, no subprocess, allocator-only; reads files via std.fs only in
        // the no-extension content branch. Standalone CLI for the differential
        // check, AND exported as an importable module below so the compress
        // pipeline can call detectFileType() / shouldCompress() in-process.
        .{ .suffix = "detect", .src = "src/compress_detect.zig" },
    };

    // The UserPromptSubmit hook keeps the `run` step (it reads stdin); the stats
    // binary gets its own `run-stats` step (it takes --session-file args, used
    // by the differential check). activate / statusline are install-only.
    var hook_exe: ?*std.Build.Step.Compile = null;
    var stats_exe: ?*std.Build.Step.Compile = null;
    var shrink_exe: ?*std.Build.Step.Compile = null;
    var init_exe: ?*std.Build.Step.Compile = null;
    var settings_exe: ?*std.Build.Step.Compile = null;
    var compress_validate_exe: ?*std.Build.Step.Compile = null;
    var detect_exe: ?*std.Build.Step.Compile = null;

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
        if (std.mem.eql(u8, bin.suffix, "compress-validate")) compress_validate_exe = exe;
        if (std.mem.eql(u8, bin.suffix, "detect")) detect_exe = exe;
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

    // R5: the compress validator is also exported as an importable module so the
    // shrink proxy (or any in-process caller) can run validate() without shelling
    // out to the caveman-compress-validate CLI. Pure std; links libc only because
    // the CLI wrapper's writeOut uses std.c.write — the validate() core is libc-
    // free, but a single link flag keeps the module configuration uniform.
    const compress_validate_module = b.addModule("compress_validate", .{
        .root_source_file = b.path("src/compress_validate.zig"),
        .target = target,
        .optimize = optimize,
    });
    compress_validate_module.link_libc = true;

    // R5: the file-type detector is also exported as an importable module so the
    // compress pipeline (or any in-process caller) can run detectFileType() /
    // shouldCompress() without shelling out to the caveman-detect CLI. Pure std
    // (StaticStringMap tables, std.json.validate, byte-scanners); links libc only
    // to keep the module configuration uniform with the others — the detector
    // core is libc-free.
    const compress_detect_module = b.addModule("detect", .{
        .root_source_file = b.path("src/compress_detect.zig"),
        .target = target,
        .optimize = optimize,
    });
    compress_detect_module.link_libc = true;

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

    // R5 stage 1 — the compress-protect structural guards ported from
    // skills/caveman-compress/scripts/compress.py (split_frontmatter,
    // is_sensitive_path, strip_llm_wrapper). Pure string/path logic, no syscalls
    // (the CLI driver below adds the only I/O). Exported as a module so the
    // future compress orchestrator port can `@import` it, plus a standalone CLI
    // (`<tool>-compress-protect`) that the differential check feeds fixtures to.
    const compress_protect_module = b.addModule("compress_protect", .{
        .root_source_file = b.path("src/compress_protect.zig"),
        .target = target,
        .optimize = optimize,
    });

    const compress_protect_exe = b.addExecutable(.{
        .name = b.fmt("{s}-compress-protect", .{tool}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compress_protect_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compress_protect_exe.root_module.link_libc = true; // raw libc-fd stdio
    compress_protect_exe.root_module.addImport("compress_protect.zig", compress_protect_module);
    b.installArtifact(compress_protect_exe);

    const run_compress_protect_step = b.step("run-compress-protect", "Run the compress-protect differential CLI");
    const run_compress_protect = b.addRunArtifact(compress_protect_exe);
    if (b.args) |args| run_compress_protect.addArgs(args);
    run_compress_protect_step.dependOn(&run_compress_protect.step);

    // R5 stage 2 — the compress orchestrator (src/compress_cmd.zig), a port of
    // skills/caveman-compress/scripts/compress.py + cli.py. Binary
    // `<tool>-compress`: argv[1] = filepath, size-check + sensitive reject,
    // should_compress gate, frontmatter split, LLM call (`claude --print` via
    // fork+pipe with the prompt on stdin), validate+retry, backup + write +
    // restore-on-failure. It IMPORTS the three R5a modules (compress_protect,
    // detect, compress_validate) plus a dedicated common.zig clone (the
    // importable modules above are configured for their own roots; the
    // orchestrator gets its own wiring, like install.zig). All link libc — the
    // fork+pipe shim and the libc-fd file IO are C-ABI.
    const cmd_common = b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    cmd_common.link_libc = true;
    cmd_common.addOptions("build_options", opts);

    const compress_cmd_exe = b.addExecutable(.{
        .name = b.fmt("{s}-compress", .{tool}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compress_cmd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compress_cmd_exe.root_module.link_libc = true;
    compress_cmd_exe.root_module.addOptions("build_options", opts);
    compress_cmd_exe.root_module.addImport("common.zig", cmd_common);
    compress_cmd_exe.root_module.addImport("compress_protect.zig", compress_protect_module);
    compress_cmd_exe.root_module.addImport("detect", compress_detect_module);
    compress_cmd_exe.root_module.addImport("compress_validate", compress_validate_module);
    b.installArtifact(compress_cmd_exe);

    const run_compress_step = b.step("run-compress", "Run the caveman-compress orchestrator");
    const run_compress = b.addRunArtifact(compress_cmd_exe);
    if (b.args) |args| run_compress.addArgs(args);
    run_compress_step.dependOn(&run_compress.step);

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

    const run_compress_validate_step = b.step("run-compress-validate", "Run the caveman-compress-validate integrity checker");
    const run_compress_validate = b.addRunArtifact(compress_validate_exe.?);
    if (b.args) |args| run_compress_validate.addArgs(args);
    run_compress_validate_step.dependOn(&run_compress_validate.step);

    const run_detect_step = b.step("run-detect", "Run the caveman-detect file-type classifier");
    const run_detect = b.addRunArtifact(detect_exe.?);
    if (b.args) |args| run_detect.addArgs(args);
    run_detect_step.dependOn(&run_detect.step);

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
        test_step.dependOn(cov.run(t, bin.suffix));
    }

    // R5 compress-protect test root. Pure module — no common.zig, no libc, no
    // build_options. Joins the shared `test` step and also gets its own
    // `test-compress-protect` step so a maintainer can run just these.
    {
        const cp_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/compress_protect.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_cp_test_step = b.step("test-compress-protect", "Run the compress-protect unit tests");
        run_cp_test_step.dependOn(&b.addRunArtifact(cp_test).step);
        test_step.dependOn(cov.run(cp_test, "compress_protect"));
    }

    // R5 stage 2 — compress orchestrator test root. compress_cmd.zig imports the
    // three R5a modules + common.zig by the same names the source uses; wire them
    // per-test-root (a test artifact's root module is distinct from the
    // importable addModule wiring above). Joins the shared `test` step and gets
    // its own `test-compress-cmd` step.
    {
        const cmd_test_common = b.createModule(.{
            .root_source_file = b.path("src/common.zig"),
            .target = target,
            .optimize = optimize,
        });
        cmd_test_common.link_libc = true;
        cmd_test_common.addOptions("build_options", opts);

        const cmd_test_protect = b.addModule("compress_protect_t", .{
            .root_source_file = b.path("src/compress_protect.zig"),
            .target = target,
            .optimize = optimize,
        });
        const cmd_test_detect = b.addModule("detect_t", .{
            .root_source_file = b.path("src/compress_detect.zig"),
            .target = target,
            .optimize = optimize,
        });
        cmd_test_detect.link_libc = true;
        const cmd_test_validate = b.addModule("compress_validate_t", .{
            .root_source_file = b.path("src/compress_validate.zig"),
            .target = target,
            .optimize = optimize,
        });
        cmd_test_validate.link_libc = true;

        const cmd_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/compress_cmd.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        cmd_test.root_module.link_libc = true;
        cmd_test.root_module.addOptions("build_options", opts);
        cmd_test.root_module.addImport("common.zig", cmd_test_common);
        cmd_test.root_module.addImport("compress_protect.zig", cmd_test_protect);
        cmd_test.root_module.addImport("detect", cmd_test_detect);
        cmd_test.root_module.addImport("compress_validate", cmd_test_validate);

        const run_cmd_test_step = b.step("test-compress-cmd", "Run the compress orchestrator unit tests");
        run_cmd_test_step.dependOn(&b.addRunArtifact(cmd_test).step);
        test_step.dependOn(cov.run(cmd_test, "compress_cmd"));
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
        test_step.dependOn(cov.run(t, root.name));
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
        test_step.dependOn(cov.run(claw_test, "claw"));
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
        test_step.dependOn(cov.run(install_test, "install"));
    }
}

// ── Coverage helper ──────────────────────────────────────────────────────────
//
// Wraps a test artifact so `zig build test -Dtest-coverage` runs it under kcov.
// kcov must be on PATH (provisioned by ../flake.nix devShell or the CI runner);
// when it is absent the kcov command fails loudly with a clear message rather
// than silently producing no coverage. With coverage OFF, covRun is a plain
// RunArtifact — zero behavior change for the normal `zig build test`.
const CoverageCtx = struct {
    b: *std.Build,
    enabled: bool,
    merge: ?*std.Build.Step, // the `coverage-merge` step (only when enabled)

    // Lines/patterns kcov must treat as non-executable so they never count as
    // uncovered: Zig's unreachable / @panic / @compileError and the inline test
    // blocks themselves. kcov has no Zig awareness, so we exclude by pattern.
    const exclude_patterns = "unreachable,@panic,@compileError,SkipZigTest,error.SkipZigTest";

    // Returns the build.Step the caller should `dependOn` for this test artifact.
    fn run(self: CoverageCtx, t: *std.Build.Step.Compile, name: []const u8) *std.Build.Step {
        const b = self.b;
        if (!self.enabled) return &b.addRunArtifact(t).step;

        // kcov OUT_DIR TEST_BIN — instrument only our src/, drop the excludes.
        const out = b.fmt("{s}/coverage/{s}", .{ b.install_path, name });
        const kcov = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            "--include-pattern=/src/",
            b.fmt("--exclude-pattern={s}", .{exclude_patterns}),
        });
        kcov.addArg(out);
        kcov.addArtifactArg(t); // the emitted test binary becomes argv after OUT_DIR
        // kcov returns the wrapped program's exit code, so a failing test still
        // fails the build. Merge step aggregates every per-binary report.
        if (self.merge) |m| m.dependOn(&kcov.step);
        return &kcov.step;
    }
};

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
