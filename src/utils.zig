// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joachim Giron
const std = @import("std");

/// Creates a new struct type by mapping a function `f` over the fields of an input struct type `S`.
/// `f` is called for each field of `S` and must return a `?std.builtin.Type.StructField`.
/// If `f` returns `null`, the field is omitted from the resulting struct.
/// `data` is an arbitrary payload passed to `f`.
pub fn map_struct(S: anytype, f: fn (std.builtin.Type.StructField, anytype) ?std.builtin.Type.StructField, data: anytype) type {
    const infos = @typeInfo(S);
    var fields: [infos.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    var len = 0;
    for (infos.@"struct".fields) |field| {
        if (f(field, data)) |new_field| {
            fields[len] = new_field;
            len += 1;
        }
    }
    return @Type(std.builtin.Type{ .@"struct" = .{
        .layout = .auto,
        .fields = fields[0..len],
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Helper function to create a `std.builtin.Type.StructField` with default options.
/// Useful when returning from the mapping function in `map_struct`.
pub fn make_struct_field(name: [:0]const u8, T: type, default_val: ?T) std.builtin.Type.StructField {
    return .{
        .name = name,
        .type = T,
        .is_comptime = false,
        .alignment = @alignOf(T),
        .default_value_ptr = if (default_val) |val| &val else null,
    };
}
