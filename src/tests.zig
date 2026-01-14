// Test entry point - imports all test modules
//
// Test files are organized by functionality:
// - test_helpers.zig: Shared infrastructure (oracles, runners, setup/cleanup)
// - test_storage.zig: Storage layer tests (dependencies, ID resolution, validation)
// - test_cli_commands.zig: Basic CLI tests (init, add, purge, search, import)
// - test_slugify.zig: Slugify functionality tests
// - test_ordering.zig: Peer-index ordering tests
// - test_property.zig: Property-based tests using oracles
// - test_snapshots.zig: Snapshot tests for output formats

test {
    _ = @import("test_storage.zig");
    _ = @import("test_cli_commands.zig");
    _ = @import("test_slugify.zig");
    _ = @import("test_ordering.zig");
    _ = @import("test_property.zig");
    _ = @import("test_snapshots.zig");
}
