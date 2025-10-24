const std = @import("std");
const avl = @import("indexes/avl.zig");

fn map_struct(S : anytype, f : fn (std.builtin.Type.StructField, anytype) ?std.builtin.Type.StructField, data : anytype) type {
    const infos = @typeInfo(S);
    var fields : [infos.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    var len = 0;
    for (infos.@"struct".fields) |field| {
        if (f(field, data)) |new_field| {
            fields[len] = new_field;
            len += 1;
        }
    }
    return @Type(std.builtin.Type{
        .@"struct" = .{
            .layout = .auto,
            .fields = fields[0..len],
            .decls = &.{},
            .is_tuple = false,
        }
    });
}

fn node_from_config(sf : std.builtin.Type.StructField, config : anytype)?std.builtin.Type.StructField {
    if (@field(config, sf.name)) |_| {
        const default_value = avl.Node{};
        return .{
            .name = sf.name,
            .type = avl.Node,
            .is_comptime = false,
            .alignment = @alignOf(avl.Node),
            .default_value_ptr = &default_value,
        };
    } else return null;
}

fn config_from_type(sf : std.builtin.Type.StructField, _ : anytype) ?std.builtin.Type.StructField {
    const T = ? struct {
        unique : bool = false,
        compare_fn : ?fn (sf.type, sf.type) std.math.Order = null,
        custom : ?type = null,
        pub const Type = sf.type;
    };
    const null_constant : T = null;
    return .{
        .name = sf.name,
        .type = T,
        .default_value_ptr = &null_constant,
        .is_comptime = false,
        .alignment = @alignOf(T),
    };
}

pub fn Config(comptime T: type) type {
    return map_struct(T, config_from_type, {});
}

pub fn MultiIndex(comptime T: type, comptime config: Config(T)) type {
	return struct {
        allocator : std.mem.Allocator,
        indexes : Indexes = .{},
        item_count : usize = 0,

        const Indexes = map_struct(@TypeOf(config), index_from_config, config);

        const Node = struct {
            headers : Headers,
            value : T,
            pub const Headers = map_struct(@TypeOf(config), node_from_config, config);
            pub fn get_header(self : *Node, field : Field) std.meta.fieldInfo(Headers, field).type {
                return @field(self.headers, @tagName(field));
            }
            pub fn from_header(_ : Field, _ : anytype) void {}
        };

        pub const Field = std.meta.FieldEnum(Indexes);
        pub const Range = @import("view.zig").BoundedIterator(Iterator);

        pub const Iterator = struct {
            node : ?*Node,
            field : Field,

            pub const ValueType = T;

            pub fn next(self : *Iterator) ?T {
                defer switch (self.field) {
                    inline else => |f| {
                        if (self.node) |current| {
                            if (@field(current.headers, @tagName(f)).next()) |next_header| {
                                self.node = @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(f), next_header)));
                            } else self.node = null;
                        }
                    }
                };
                return self.peek();
            }

            pub fn peek(self : Iterator) ?T {
                return if (self.node) |n| n.value else null;
            }

            pub fn eql(self : Iterator, other : Iterator) bool {
                return self.node == other.node;
            }
        };

        const Self = @This();

        pub fn init(allocator : std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self : *Self) void {
            // todo: destroy all nodes
            inline for (std.meta.fields(Indexes)) |f| {
                @field(self.indexes, f.name).deinit();
            }
        }

        pub fn begin(self: Self, field : Field) Iterator {
            return .{
                .node = switch (field) {
                    inline else => |f|
                        if (@field(self.indexes, @tagName(f)).begin()) |b|
                            @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(f), b)))
                        else
                            null,
                },
                .field = field,
            };
        }

        pub fn insert(self : *Self, value : T) !void {
            const node = try self.allocator.create(Node);
            node.value = value;
            node.headers = .{};
            inline for (std.meta.fields(Indexes)) |f| {
                try @field(self.indexes, f.name).insert(&@field(node.headers, f.name));
            }
            self.item_count += 1;
        }

        pub fn erase_it(self : *Self, iterator : Iterator) void {
            const node = iterator.node orelse return;
            inline for (std.meta.fields(Indexes)) |f| {
                @field(self.indexes, f.name).erase(&@field(node.headers, f.name));
            }
            self.allocator.destroy(node);
        }

        pub fn erase_range(self : *Self, r : Range) void {
            var current = r.lower_bound orelse return;
            while (current.node != null and (r.upper_bound == null or !current.eql(r.upper_bound.?))) {
                const old = current;
                _ = current.next();
                self.erase_it(old);
            }
        }

        pub fn find_it(self: Self, comptime field: Field, v: key_type(field)) Iterator {
            var node : Node = undefined;
            @field(node.value, @tagName(field)) = v;

            return Iterator{
                .node = if (@field(self.indexes, @tagName(field)).find(&@field(node.headers, @tagName(field)))) |n|
                        @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(field), n)))
                    else null,
                .field = field,
            };
        }

        pub fn find(self: Self, comptime field: Field, v: key_type(field)) ?T {
            return self.find_it(field, v).peek();
        }

        pub fn lower_bound(self: Self, comptime field: Field, v: key_type(field)) Iterator {
            var node : Node = undefined;
            @field(node.value, @tagName(field)) = v;

            return Iterator{
                .node = if (@field(self.indexes, @tagName(field)).lower_bound(&@field(node.headers, @tagName(field)))) |n|
                    @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(field), n)))
                else null,
                .field = field,
            };
        }

        pub fn upper_bound(self: Self, comptime field: Field, v: key_type(field)) Iterator {
            var node : Node = undefined;
            @field(node.value, @tagName(field)) = v;

            return Iterator{
                .node = if (@field(self.indexes, @tagName(field)).upper_bound(&@field(node.headers, @tagName(field)))) |n|
                    @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(field), n)))
                else null,
                .field = field,
            };
        }

        pub fn range(self: Self, comptime field: Field, v1: key_type(field), v2: key_type(field)) Range {
            const lb : Iterator = self.lower_bound(field, v1);
            const ub : Iterator = self.upper_bound(field, v2);
            return .{
                .lower_bound = lb,
                .upper_bound = ub,
                .iterator = lb,
            };
        }

        pub fn equal_range(self: Self, comptime field: Field, v: key_type(field)) Range {
            return self.range(field, v, v);
        }

        pub fn count(self : Self) usize {
            return self.item_count;
        }

        pub fn print(self : *Self) void {
            inline for (std.meta.fields(Indexes)) |f| {
                @field(self.indexes, f.name).print();
            }
        }

        fn key_type(comptime field: Field) type {
            return @FieldType(T, @tagName(field));
        }

        fn index_from_config(sf : std.builtin.Type.StructField, _ : anytype) ?std.builtin.Type.StructField {
            if (@field(config, sf.name)) |c| {

                const index_type = c.custom orelse
                    avl.AVL(.{
                    .compare = struct {
                        pub fn compare(left_node : *avl.Node, right_node : *avl.Node) std.math.Order {
                            const left_val : T = @as(*Node, @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(sf.name, left_node)))).value;
                            const right_val : T = @as(*Node, @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(sf.name, right_node)))).value;
                            return (c.compare_fn orelse std.math.order)(@field(left_val, sf.name), @field(right_val, sf.name));
                        }
                    }.compare,
                    .unique = c.unique,
                });
                const default_value = index_type{.allocator = undefined};
                return .{
                    .name = sf.name,
                    .type = index_type,
                    .is_comptime = false,
                    .alignment = @alignOf(index_type),
                    .default_value_ptr = &default_value,
                };
            } else return null;
        }
	};
}