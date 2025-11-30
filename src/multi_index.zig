const std = @import("std");
const avl = @import("indexes/avl.zig");
const hash_table = @import("indexes/hash_table.zig");

fn map_struct(S: anytype, f: fn (std.builtin.Type.StructField, anytype) ?std.builtin.Type.StructField, data: anytype) type {
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

fn config_from_type(sf: std.builtin.Type.StructField, _: anytype) ?std.builtin.Type.StructField {
    const T = ?struct {
        unique: bool = false,
        ordered: bool = true,
        compare_fn: ?fn (sf.type, sf.type) std.math.Order = null,
        hash_context: type = std.hash_map.AutoContext(sf.type),
        custom: ?type = null,
        pub const Type = sf.type;
    };
    const null_constant: T = null;
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
        allocator: std.mem.Allocator,
        indexes: Indexes = .{},
        item_count: usize = 0,

        const Indexes = map_struct(@TypeOf(config), index_from_config, config);

        const Node = struct {
            headers: Headers,
            value: T,
            pub const Headers = map_struct(@TypeOf(config), node_from_config, config);
            pub fn get_header(self: *Node, field: Field) std.meta.fieldInfo(Headers, field).type {
                return @field(self.headers, @tagName(field));
            }
            pub fn from_header(_: Field, _: anytype) void {}
        };

        pub const Field = std.meta.FieldEnum(Indexes);
        pub const Range = @import("view.zig").BoundedIterator(Iterator);

        pub const Iterator = struct {
            node: ?*Node,
            field: Field,

            pub const ValueType = T;

            pub fn next(self: *Iterator) ?T {
                defer switch (self.field) {
                    inline else => |f| {
                        if (self.node) |current| {
                            if (@field(current.headers, @tagName(f)).next()) |next_header| {
                                self.node = @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(f), next_header)));
                            } else self.node = null;
                        }
                    },
                };
                return self.peek();
            }

            pub fn peek(self: Iterator) ?T {
                return if (self.node) |n| n.value else null;
            }

            pub fn eql(self: Iterator, other: Iterator) bool {
                return self.node == other.node;
            }
        };

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            var self = Self{
                .allocator = allocator,
            };
            inline for (std.meta.fields(Indexes)) |f| {
                @field(self.indexes, f.name) = @TypeOf(@field(self.indexes, f.name)).init(allocator);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.reset();
            // todo: destroy all nodes
            inline for (std.meta.fields(Indexes)) |f| {
                @field(self.indexes, f.name).deinit();
            }
        }

        pub fn reset(self: *Self) void {
            inline for (std.meta.fields(Indexes)[0..std.meta.fields(Indexes).len - 1]) |f| {
                @field(self.indexes, f.name).reset(self.allocator, null);
            }
            const lastField = std.meta.fields(Indexes)[std.meta.fields(Indexes).len - 1];
            const free_fn = struct {
                pub fn f(allocator : std.mem.Allocator, field_node : *@FieldType(Node.Headers, lastField.name)) void {
                    const node : *Node = @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(lastField.name, field_node)));
                    allocator.destroy(node);
                }
            }.f;
            @field(self.indexes, lastField.name).reset(self.allocator, free_fn);
        }

        pub fn begin(self: Self, field: Field) Iterator {
            return .{
                .node = switch (field) {
                    inline else => |f| if (@field(self.indexes, @tagName(f)).begin()) |b|
                        @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(f), b)))
                    else
                        null,
                },
                .field = field,
            };
        }

        pub fn insert(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.value = value;
            node.headers = .{};

            const Hints = map_struct(@TypeOf(config), hint_from_config, false);
            var hints: Hints = undefined;

            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                const index_node = &@field(node.headers, f.name);
                const hint = &@field(hints, f.name);

                hint.* = try index.prepare_insert(index_node);
            }

            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                const index_node = &@field(node.headers, f.name);
                const hint = @field(hints, f.name);

                index.finish_insert(hint, index_node) catch unreachable;
            }

            self.item_count += 1;
        }

        // case 1: value change and need reorder/rehash -> hint
        // case 2: value change but no reorder/rehash -> no hint
        // case 3: value doesn't change -> no hint
        pub fn update(self: *Self, iterator: Iterator, value: T) !T {
            const node = iterator.node orelse return error.InvalidIterator;
            const Hints = map_struct(@TypeOf(config), hint_from_config, true);
            var hints: Hints = undefined;

            var tmp_node = Node{ .value = value, .headers = .{} };

            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                const index_node = &@field(node.headers, f.name);
                const index_tmp_node = &@field(tmp_node.headers, f.name);
                const hint = &@field(hints, f.name);

                hint.* = try index.prepare_update(index_node, index_tmp_node);
            }

            const old_value = node.value;
            node.value = value;

            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                const index_node = &@field(node.headers, f.name);
                const optional_hint = @field(hints, f.name);

                if (optional_hint) |hint|
                    index.finish_update(hint, index_node) catch unreachable;
            }

            return old_value;
        }

        pub fn erase_it(self: *Self, iterator: Iterator) void {
            const node = iterator.node orelse return;
            inline for (std.meta.fields(Indexes)) |f| {
                @field(self.indexes, f.name).erase(&@field(node.headers, f.name));
            }
            self.allocator.destroy(node);
        }

        pub fn erase_range(self: *Self, r: Range) void {
            var current = r.lower_bound orelse return;
            while (current.node != null and (r.upper_bound == null or !current.eql(r.upper_bound.?))) {
                const old = current;
                _ = current.next();
                self.erase_it(old);
            }
        }

        pub fn find_it(self: Self, comptime field: Field, v: key_type(field)) Iterator {
            var node: Node = undefined;
            @field(node.value, @tagName(field)) = v;

            return Iterator{
                .node = if (@field(self.indexes, @tagName(field)).find(&@field(node.headers, @tagName(field)))) |n|
                    @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(field), n)))
                else
                    null,
                .field = field,
            };
        }

        pub fn find(self: Self, comptime field: Field, v: key_type(field)) ?T {
            return self.find_it(field, v).peek();
        }

        pub fn lower_bound(self: Self, comptime field: Field, v: key_type(field)) Iterator {
            var node: Node = undefined;
            @field(node.value, @tagName(field)) = v;

            return Iterator{
                .node = if (@field(self.indexes, @tagName(field)).lower_bound(&@field(node.headers, @tagName(field)))) |n|
                    @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(field), n)))
                else
                    null,
                .field = field,
            };
        }

        pub fn upper_bound(self: Self, comptime field: Field, v: key_type(field)) Iterator {
            var node: Node = undefined;
            @field(node.value, @tagName(field)) = v;

            return Iterator{
                .node = if (@field(self.indexes, @tagName(field)).upper_bound(&@field(node.headers, @tagName(field)))) |n|
                    @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(@tagName(field), n)))
                else
                    null,
                .field = field,
            };
        }

        pub fn range(self: Self, comptime field: Field, v1: key_type(field), v2: key_type(field)) Range {
            const lb: Iterator = self.lower_bound(field, v1);
            const ub: Iterator = self.upper_bound(field, v2);
            return .{
                .lower_bound = lb,
                .upper_bound = ub,
                .iterator = lb,
            };
        }

        pub fn equal_range(self: Self, comptime field: Field, v: key_type(field)) Range {
            return self.range(field, v, v);
        }

        pub fn count(self: Self) usize {
            return self.item_count;
        }

        pub fn print(self: *Self) void {
            inline for (std.meta.fields(Indexes)) |f| {
                @field(self.indexes, f.name).print();
            }
        }

        fn key_type(comptime field: Field) type {
            return @FieldType(T, @tagName(field));
        }

        fn node_of_index_node(comptime fieldName: []const u8, indexNode : anytype) *Node {
            return @as(*Node, @fieldParentPtr("headers", @as(*Node.Headers, @fieldParentPtr(fieldName, indexNode))));
        }

        fn index_from_config(sf: std.builtin.Type.StructField, _: anytype) ?std.builtin.Type.StructField {
            if (@field(config, sf.name)) |c| {
                const index_type: type = c.custom orelse if (c.ordered)
                    avl.AVL(.{
                        .compare = struct {
                            pub fn compare(left_node: *avl.Node, right_node: *avl.Node) std.math.Order {
                                const left_val: T = node_of_index_node(sf.name, left_node).value;
                                const right_val: T = node_of_index_node(sf.name, right_node).value;
                                return (c.compare_fn orelse std.math.order)(@field(left_val, sf.name), @field(right_val, sf.name));
                            }
                        }.compare,
                        .unique = c.unique,
                    })
                else
                    hash_table.HashTable(.{
                        .Context = struct {
                            subContext : c.hash_context = .{},
                            pub fn hash(self: @This(), node: *hash_table.Node) u64 {
                                const val: T = node_of_index_node(sf.name, node).value;
                                return self.subContext.hash(@field(val, sf.name));
                            }
                            pub fn eql(self: @This(), left_node: *hash_table.Node, right_node: *hash_table.Node) bool {
                                const left_val: T = node_of_index_node(sf.name, left_node).value;
                                const right_val: T = node_of_index_node(sf.name, right_node).value;
                                return self.subContext.eql(@field(left_val, sf.name), @field(right_val, sf.name));
                            }
                        },
                        .unique = c.unique,
                    });
                const default_value = index_type{ .allocator = undefined };
                return .{
                    .name = sf.name,
                    .type = index_type,
                    .is_comptime = false,
                    .alignment = @alignOf(index_type),
                    .default_value_ptr = &default_value,
                };
            } else return null;
        }

        fn node_from_config(sf: std.builtin.Type.StructField, _: anytype) ?std.builtin.Type.StructField {
            if (@field(config, sf.name)) |field| {
                const Container = if (field.ordered) avl else hash_table;
                const default_value = Container.Node{};
                return .{
                    .name = sf.name,
                    .type = Container.Node,
                    .is_comptime = false,
                    .alignment = @alignOf(Container.Node),
                    .default_value_ptr = &default_value,
                };
            } else return null;
        }

        fn hint_from_config(sf: std.builtin.Type.StructField, is_optional: anytype) ?std.builtin.Type.StructField {
            if (@field(config, sf.name)) |field| {
                const Container = if (field.ordered) avl else hash_table;
                const t = if (is_optional) ?Container.Hint else Container.Hint;
                return .{
                    .name = sf.name,
                    .type = t,
                    .is_comptime = false,
                    .alignment = @alignOf(t),
                    .default_value_ptr = null,
                };
            } else return null;
        }
    };
}
