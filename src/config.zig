const std = @import("std");
const utils = @import("utils.zig");

fn default_order(T: type) fn (T, T) std.math.Order {
    return struct {
        pub fn f(l: T, r: T) std.math.Order {
            return std.math.order(l, r);
        }
    }.f;
}

pub fn TypeConfig(T: type) type {
    return struct {
        unique: bool = false,
        ordered: bool = true,
        compare_fn: ?fn (T, T) std.math.Order = default_order(T),
        hash_context: ?type = if (T == []const u8) std.hash_map.StringContext else std.hash_map.AutoContext(T),
        custom: ?type = null,

        pub const Type = T;
    };
}

fn config_from_type(sf: std.builtin.Type.StructField, _: anytype) ?std.builtin.Type.StructField {
    const T = ?TypeConfig(sf.type);
    return utils.make_struct_field(sf.name, T, @as(T, null));
}

pub fn Config(comptime T: type) type {
    return utils.map_struct(T, config_from_type, {});
}
