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

fn make_struct_field(name: [:0]const u8, T: type, default_val: ?T) std.builtin.Type.StructField {
    return .{
        .name = name,
        .type = T,
        .is_comptime = false,
        .alignment = @alignOf(T),
        .default_value_ptr = if (default_val) |val| &val else null,
    };
}

fn default_order(T: type) fn (T, T) std.math.Order {
    return struct {
        pub fn f(l: T, r: T) std.math.Order {
            return std.math.order(l, r);
        }
    }.f;
}

fn config_from_type(sf: std.builtin.Type.StructField, _: anytype) ?std.builtin.Type.StructField {
    const T = ?struct {
        unique: bool = false,
        ordered: bool = true,
        compare_fn: ?fn (sf.type, sf.type) std.math.Order = default_order(sf.type),
        hash_context: type = if (sf.type == []const u8) std.hash_map.StringContext else std.hash_map.AutoContext(sf.type),
        custom: ?type = null,
        pub const Type = sf.type;
    };
    return make_struct_field(sf.name, T, @as(T, null));
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
            pub fn get_header(self: *Node, comptime field: Field) *std.meta.fieldInfo(Headers, field).type {
                return &@field(self.headers, @tagName(field));
            }
            pub fn from_header(comptime field: Field, ptr: *std.meta.fieldInfo(Headers, field).type) *Node {
                const header_struct: *Node.Headers = @fieldParentPtr(@tagName(field), ptr);
                return @fieldParentPtr("headers", header_struct);
            }
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
                            self.node = if (current.get_header(f).next()) |next_header|
                                Node.from_header(f, next_header)
                            else
                                null;
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

        // =========================================== General ===========================================

        pub fn init(allocator: std.mem.Allocator) Self {
            var self = Self{ .allocator = allocator };
            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                index.* = @TypeOf(index.*).init(allocator);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.reset();
            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                index.deinit();
            }
        }

        pub fn reset(self: *Self) void {
            inline for (std.meta.fields(Indexes)[0 .. std.meta.fields(Indexes).len - 1]) |f| {
                @field(self.indexes, f.name).reset(self.allocator, null);
            }
            const lastField = std.meta.fields(Indexes)[std.meta.fields(Indexes).len - 1];
            const free_fn = struct {
                pub fn f(allocator: std.mem.Allocator, field_node: *@FieldType(Node.Headers, lastField.name)) void {
                    const node: *Node = Node.from_header(@field(Field, lastField.name), field_node);
                    allocator.destroy(node);
                }
            }.f;
            @field(self.indexes, lastField.name).reset(self.allocator, free_fn);
        }

        pub fn count(self: Self) usize {
            return self.item_count;
        }

        pub fn insert(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.value = value;
            node.headers = .{};

            const Hints = map_struct(@TypeOf(config), hint_from_config, false);
            var hints: Hints = undefined;

            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                const index_node = node.get_header(@field(Field, f.name));
                const hint = &@field(hints, f.name);

                hint.* = try index.prepare_insert(index_node);
            }

            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                const index_node = node.get_header(@field(Field, f.name));
                const hint = @field(hints, f.name);

                index.finish_insert(hint, index_node) catch unreachable;
            }

            self.item_count += 1;
        }

        pub fn update(self: *Self, iterator: Iterator, value: T) !T {
            const node = iterator.node orelse return error.InvalidIterator;
            const Hints = map_struct(@TypeOf(config), hint_from_config, true);
            var hints: Hints = undefined;

            var tmp_node = Node{ .value = value, .headers = .{} };

            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                const index_node = node.get_header(@field(Field, f.name));
                const index_tmp_node = tmp_node.get_header(@field(Field, f.name));
                const hint = &@field(hints, f.name);

                hint.* = try index.prepare_update(index_node, index_tmp_node);
            }

            const old_value = node.value;
            node.value = value;

            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                const index_node = node.get_header(@field(Field, f.name));
                const optional_hint = @field(hints, f.name);

                if (optional_hint) |hint|
                    index.finish_update(hint, index_node) catch unreachable;
            }

            return old_value;
        }

        pub fn erase_it(self: *Self, iterator: Iterator) void {
            const node = iterator.node orelse return;
            inline for (std.meta.fields(Indexes)) |f| {
                const index = &@field(self.indexes, f.name);
                const index_node = &@field(node.headers, f.name);
                index.erase(index_node);
            }
            self.allocator.destroy(node);
        }

        // =========================================== Iterable ===========================================

        pub fn begin(self: Self, field: Field) Iterator {
            return .{
                .node = switch (field) {
                    inline else => |f| if (@field(self.indexes, @tagName(f)).begin()) |b|
                        Node.from_header(@tagName(f), b)
                    else
                        null,
                },
                .field = field,
            };
        }

        pub fn find_it(self: Self, comptime field: Field, v: key_type(field)) Iterator {
            var node: Node = undefined;
            @field(node.value, @tagName(field)) = v;

            const index = &@field(self.indexes, @tagName(field));
            const index_node = node.get_header(field);

            return Iterator{
                .node = if (index.find(index_node)) |n|
                    Node.from_header(field, n)
                else
                    null,
                .field = field,
            };
        }

        pub fn find(self: Self, comptime field: Field, v: key_type(field)) ?T {
            return self.find_it(field, v).peek();
        }

        // =========================================== Ordered ===========================================

        pub fn lower_bound(self: Self, comptime field: Field, v: key_type(field)) Iterator {
            var node: Node = undefined;
            @field(node.value, @tagName(field)) = v;

            const index = &@field(self.indexes, @tagName(field));
            const index_node = node.get_header(field);

            return Iterator{
                .node = if (index.lower_bound(index_node)) |n|
                    Node.from_header(field, n)
                else
                    null,
                .field = field,
            };
        }

        pub fn upper_bound(self: Self, comptime field: Field, v: key_type(field)) Iterator {
            var node: Node = undefined;
            @field(node.value, @tagName(field)) = v;

            const index = &@field(self.indexes, @tagName(field));
            const index_node = node.get_header(field);

            return Iterator{
                .node = if (index.upper_bound(index_node)) |n|
                    Node.from_header(field, n)
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

        pub fn erase_range(self: *Self, r: Range) void {
            var current = r.lower_bound orelse return;
            while (current.node != null and (r.upper_bound == null or !current.eql(r.upper_bound.?))) {
                const old = current;
                _ = current.next();
                self.erase_it(old);
            }
        }

        pub fn print(self: *Self) void {
            inline for (std.meta.fields(Indexes)) |f| {
                @field(self.indexes, f.name).print();
            }
        }

        // =========================================== Helpers ===========================================

        fn key_type(comptime field: Field) type {
            return @FieldType(T, @tagName(field));
        }

        fn get_adaptor(f: []const u8) fn (*@FieldType(Node.Headers, f)) @FieldType(T, f) {
            return struct {
                pub fn adaptor(node_header: *@FieldType(Node.Headers, f)) @FieldType(T, f) {
                    const val: T = Node.from_header(@field(Field, f), node_header).value;
                    return @field(val, f);
                }
            }.adaptor;
        }

        fn index_from_config(sf: std.builtin.Type.StructField, _: anytype) ?std.builtin.Type.StructField {
            if (@field(config, sf.name)) |c| {
                const index_type: type = c.custom orelse if (c.ordered)
                    avl.AVL(avl.DefaultConfig(T, sf.name, get_adaptor(sf.name), c))
                else
                    hash_table.HashTable(hash_table.DefaultConfig(T, sf.name, get_adaptor(sf.name), c));
                return make_struct_field(sf.name, index_type, .{ .allocator = undefined });
            } else return null;
        }

        fn node_from_config(sf: std.builtin.Type.StructField, _: anytype) ?std.builtin.Type.StructField {
            if (@field(config, sf.name)) |field| {
                const Container = if (field.ordered) avl else hash_table;
                return make_struct_field(sf.name, Container.Node, .{});
            } else return null;
        }

        fn hint_from_config(sf: std.builtin.Type.StructField, is_optional: anytype) ?std.builtin.Type.StructField {
            if (@field(config, sf.name)) |field| {
                const Container = if (field.ordered) avl else hash_table;
                const t = if (is_optional) ?Container.Hint else Container.Hint;
                return make_struct_field(sf.name, t, null);
            } else return null;
        }
    };
}
