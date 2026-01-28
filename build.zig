// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joachim Giron
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("multi-index", .{
        .root_source_file = b.path("src/multi_index.zig"),
        .target = target,
        .optimize = optimize,
    });
}
