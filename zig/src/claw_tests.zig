//! caveman-claw — aggregate test root for the R4b stage 1 lib helpers.
//!
//! Re-references the three ported modules so a single `caveman-claw` test
//! binary exercises every test in openclaw.zig, nullclaw.zig, and
//! opencode_agent.zig. `zig build test` also runs each module's tests directly;
//! this binary exists so a maintainer can run the lib tests by name
//! (`zig build test-claw`) without spinning up the hook/installer roots.

const std = @import("std");

pub const openclaw = @import("openclaw.zig");
pub const nullclaw = @import("nullclaw.zig");
pub const opencode_agent = @import("opencode_agent.zig");

test {
    std.testing.refAllDecls(openclaw);
    std.testing.refAllDecls(nullclaw);
    std.testing.refAllDecls(opencode_agent);
}
