const std = @import("std");

// todo:
// past the end (superroot)
// find hint
// insert hint
// transaction insert
// unique key

// replace past the end by offset
// view template?
// copy

pub const Field = usize;

// pub fn Index(T : type) type {
//     return struct {
//         field : FieldEnum,
//         unique : bool = false,
//         compare_fn: ?fn()void = null,
//         pub const FieldEnum = std.meta.FieldEnum(T);
//     };
// }

pub fn Config(T : type) type {
    comptime var infos = @typeInfo(T);
    comptime var fields : [infos.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (0..infos.@"struct".fields.len) |i| {
        fields[i] = infos.@"struct".fields[i];
        fields[i].type = ?struct {
            unique : bool = false,
            compare_fn : ?fn (fields[i].type, fields[i].type) bool = null,
        };
        const null_constant : fields[i].type = null;
        fields[i].default_value_ptr = &null_constant;
    }
    infos.@"struct".fields = fields[0..];
    infos.@"struct".decls = &.{};
    return @Type(infos);
}

// pub fn Config(T: type) type {
//     const Row = struct {
//         field : FieldEnum,
//         unique : bool = false,
//         compare_fn: ?fn()void = null,
//     };
//     return struct {
//         keys: []const FieldEnum,
//         compare_fn: []?fn () void = &.{},
//
//         pub const FieldEnum = std.meta.FieldEnum(T);
//
//         const Self = @This();
//
//         pub fn key_index(comptime self: Self, comptime fieldEnum: FieldEnum) Field {
//             for (self.keys, 0..) |k, i| {
//                 if (fieldEnum == k)
//                     return i;
//             }
//             @compileError("no such key");
//         }
//
//         pub fn key_name(comptime self: Self, comptime field: Field) FieldEnum {
//             return self.keys[field];
//         }
//
//         pub fn key_type(comptime self: Self, comptime field: Field) type {
//             _ = self;
//             return std.meta.fieldInfo(T, @as(std.meta.FieldEnum(T), @enumFromInt(field))).type;
//             // return @TypeOf(@field(T, self.key_name(field)));
//         }
//     };
// }

pub fn MultiIndex(comptime T: type, comptime config: Config(T)) type {
    return struct {
        allocator: std.mem.Allocator,
        tree: [nkey]?*Node = .{null} ** nkey,
        item_count: usize = 0,

        const FieldEnum = std.meta.FieldEnum(T);

        const keys = b: {
            const fields = std.meta.fields(Config(T));
            var array : [fields.len]FieldEnum = undefined;
            var len : usize = 0;
            for (fields) |field| {
                if (@field(config, field.name) != null) {
                    array[len] = std.enums.nameCast(FieldEnum, field.name);
                    len += 1;
                }
            }
            const const_copy = array[0..len] ++ [0]FieldEnum{};
            break :b const_copy;
        };

        const nkey = keys.len;

        const Node = struct {
            /// one hdr for each avl keys/field
            avl: [nkey]AVL_hdr = [_]AVL_hdr{.{}} ** nkey,

            value: T,

            const AVL_hdr = struct {
                /// left node
                l: ?*Node = null,
                /// right node
                r: ?*Node = null,
                /// parent node
                p: ?*Node = null,
                /// balance factor used by the avl algorithm
                balance_factor: i8 = 0,

                pub fn node(self: *Self, field: Field) *Node {
                    return @fieldParentPtr("avl", @as([*]AVL_hdr, self)[-field]);
                }
            };
        };

        pub const BaseIterator = struct {
            node: ?*Node = null,
            field: Field,

            pub const ValueType = T;

            pub fn switch_field(self: *BaseIterator, comptime fieldEnum: FieldEnum) void {
                self.field = key_index(fieldEnum);
            }

            pub fn advance(self: *BaseIterator, n : isize) void {
                const abs_n : usize = @abs(n);
                for (0..abs_n) |_| {
                    if (self.node == null)
                        break;
                    if (n < 0) {
                        self.node = next_node(self.node.?, self.field, "l");
                    } else {
                        self.node = next_node(self.node.?, self.field, "r");
                    }
                }
            }

            pub fn next(self: *BaseIterator) ?ValueType {
                defer self.advance(1);
                return self.peek();
            }

            pub fn prev(self: *BaseIterator) ?ValueType {
                self.advance(-1);
                return self.peek();
            }

            pub fn eql(self : BaseIterator, other : BaseIterator) bool {
                return self.node == other.node;
            }

            pub fn peek(self: BaseIterator) ?ValueType {
                return if (self.is_valid()) self.node.?.value else null;
            }

            pub fn is_valid(self : BaseIterator) bool {
                return self.node != null;
            }
        };
        pub const Iterator = @import("view.zig").SafeIterator(@import("view.zig").BoundedIterator(BaseIterator));
        // pub const BoundedIterator = @import("view.zig").BoundedIterator(Iterator);

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
            };
        }

        pub fn deinit(self : *Self) void {
            var node = self.tree[0];

            while (node) |n| {
                if (n.avl[0].l) |l| {
                    n.avl[0].l = null;
                    node = l;
                } else if (n.avl[0].r) |r| {
                    n.avl[0].r = null;
                    node = r;
                } else {
                    const tmp = n.avl[0].p;
                    self.destroy_node(n);
                    node = tmp;
                }
            }
        }

        pub fn insert(self: *Self, value: T) !void {
            const n: *Node = try self.create_node(value);

            var hints : [nkey]Iterator = undefined;

            inline for (0..nkey) |f| {
                var last = self.upper_bound(key_name(f), get_field(value, f));
                last.advance(-1);
                if (key_config(f).unique and
                last.is_valid() and !self.compare_keys(f, get_field(last.base().node.?.value, f), get_field(value, f))) {
                    return error.Duplicate;
                }
                hints[f] = last;
            }

            inline for (0..nkey) |f| {
                self.add_to_tree_hint(n, hints[f], f);
            }
        }

        pub fn update(self: *Self, it : Iterator, value: T) !void {
            const n: *Node = it.base().node orelse return error.InvalidIt;

            var hints : [nkey]?Iterator = undefined;

            inline for (0..nkey) |f| {
                var prev = it;
                _ = prev.prev();
                var next = it;
                _ = next.next();
                if ((prev.is_valid() and self.compare_keys(f, get_field(value, f), get_field(prev.peek().?, f))) or
                    (next.is_valid() and self.compare_keys(f, get_field(next.peek().?, f), get_field(value, f)))) {
                    var last = self.upper_bound(key_name(f), get_field(value, f));
                    last.advance(-1);
                    if (key_config(f).unique and last.is_valid() and !self.compare_keys(f, get_field(last.base().node.?.value, f), get_field(value, f))) {
                        return error.Duplicate;
                    }
                    hints[f] = last;
                } else if (true and
                    ((prev.is_valid() and !self.compare_keys(f, get_field(prev.peek().?, f), get_field(value, f))) or
                    (next.is_valid() and !self.compare_keys(f, get_field(value, f), get_field(next.peek().?, f))))) {
                    var last = self.upper_bound(key_name(f), get_field(value, f));
                    last.advance(-1);
                    if (key_config(f).unique and last.is_valid() and !self.compare_keys(f, get_field(last.base().node.?.value, f), get_field(value, f))) {
                        return error.Duplicate;
                    }
                    hints[f] = last;
                } else {
                    hints[f] = null;
                }
            }

            n.value = value;

            inline for (0..nkey) |f| {
                if (hints[f]) |h| {
                    std.debug.print("update field {}\n", .{f});
                    self.remove_from_tree(n, f);
                    self.print();
                    // self.add_to_tree_hint(n, h, f);
                    _ = h;
                    self.add_to_tree(n, f);
                }
            }
        }

        pub fn erase(self : *Self, it : Iterator) void {
            if (it.is_valid()) {
                inline for (0..nkey) |f| {
                    self.remove_from_tree(it.base().node.?, f);
                }
                self.destroy_node(it.base().node.?);
            }
        }

        pub fn erase_range(self : *Self, it : Iterator) void {
            var it_copy = it;
            while (it_copy.peek()) |_| {
                const tmp = it_copy;
                _ = it_copy.next();
                self.erase(tmp);
            }
        }

        pub fn count(self: Self) usize {
            return self.item_count;
        }

        pub fn find_it(self: Self, comptime fieldEnum: FieldEnum, v: key_type(key_index(fieldEnum))) Iterator {
            const field = comptime key_index(fieldEnum);
            return Iterator.init(BaseIterator{
                .node = self.internal_find(field, v),
                .field = field,
            });
        }

        pub fn find(self: Self, comptime fieldEnum: FieldEnum, v: key_type(key_index(fieldEnum))) ?T {
            return self.find_it(fieldEnum, v).peek();
        }

        pub fn lower_bound(self: Self, comptime fieldEnum: FieldEnum, v: key_type(key_index(fieldEnum))) Iterator {
            const field = comptime key_index(fieldEnum);
            return Iterator.init(BaseIterator{
                .node = self.internal_lower_bound(field, v),
                .field = field,
            });
        }

        pub fn upper_bound(self: Self, comptime fieldEnum: FieldEnum, v: key_type(key_index(fieldEnum))) Iterator {
            const field = comptime key_index(fieldEnum);
            return Iterator.init(BaseIterator{
                .node = self.internal_upper_bound(field, v),
                .field = field,
            });
        }

        pub fn equal_range(self: Self, comptime fieldEnum: FieldEnum, v: key_type(key_index(fieldEnum))) Iterator {
            return self.range(fieldEnum, v, v);
        }

        pub fn range(self: Self, comptime fieldEnum: FieldEnum, v1: key_type(key_index(fieldEnum)), v2: key_type(key_index(fieldEnum))) Iterator {
            const field = comptime key_index(fieldEnum);
            const begin : BaseIterator = .{
                .node = self.internal_lower_bound(field, v1),
                .field = field,
            };
            const end : BaseIterator = .{
                .node = self.internal_upper_bound(field, v2),
                .field = field,
            };
            return .{
                .iterator = .{
                    .lower_bound = begin,
                    .iterator = begin,
                    .upper_bound = end,
                },
            };
        }

        /// AVL tree rotation, rotate the node `n` in the tree `field` in the direction `direction` ("l" or "r")
        fn rotate(self: *Self, n: *Node, field: Field, comptime direction: []const u8) void {
            const opposite_direction = comptime if (std.mem.eql(u8, direction, "l")) "r" else "l";
            const ref = self.node_ref(n, field);

            const l: *Node = @field(n.avl[field], direction) orelse return;
            const op: ?*Node = n.avl[field].p;

            const bn = n.avl[field].balance_factor;
            const bl = l.avl[field].balance_factor;
            if (comptime std.mem.eql(u8, direction, "l")) {
                if (bl > 0) {
                    n.avl[field].balance_factor -= 1 + bl;
                    l.avl[field].balance_factor = -1 + @min(bl, bn - 1);
                } else {
                    n.avl[field].balance_factor -= 1;
                    l.avl[field].balance_factor = bl - 1 + @min(0, bn - 1);
                }
            } else {
                if (bl < 0) {
                    n.avl[field].balance_factor += 1 - bl;
                    l.avl[field].balance_factor = 1 + @max(bn + 1, bl);
                } else {
                    n.avl[field].balance_factor += 1;
                    l.avl[field].balance_factor = bl + 1 + @max(bn + 1, 0);
                }
            }

            @field(n.avl[field], direction) = @field(l.avl[field], opposite_direction);
            if (@field(n.avl[field], direction)) |nl|
                nl.avl[field].p = n;

            @field(l.avl[field], opposite_direction) = n;
            if (@field(l.avl[field], opposite_direction)) |lr|
                lr.avl[field].p = l;

            ref.* = l;
            l.avl[field].p = op;
        }

        /// debug function, used to check that a tree respect the rules of the AVL algorithm,
        /// this function panic if the tree is invalid
        fn check_node(self: *Self, n: *Node, field: Field) i32 {
            const dl: i32 = if (n.avl[field].l) |l| self.check_node(l, field) else 0;
            const dr: i32 = if (n.avl[field].r) |r| self.check_node(r, field) else 0;
            if (dl - dr != n.avl[field].balance_factor or
                n.avl[field].balance_factor > 1 or
                n.avl[field].balance_factor < -1)
            {
                self.print();
                @panic("invalid tree in " ++ @typeName(Self));
            }
            return @max(dl, dr) + 1;
        }

        /// fix the node `n` in the tree `field`, the parameter `change` indicate the weight modification of the node,
        /// eg: 1 if the node is 1 node heavier than before or -1 if the node is 1 node lighter than before
        fn fix(self: *Self, n: *Node, field: Field, change: i8) void {
            if (n.avl[field].p) |p| {
                if (p.avl[field].l) |pl| if (pl == n) {
                    p.avl[field].balance_factor += change;
                };
                if (p.avl[field].r) |pr| if (pr == n) {
                    p.avl[field].balance_factor -= change;
                };

                if (p.avl[field].balance_factor == 0) {
                    if (change == -1) {
                        return self.fix(p, field, change);
                    }
                    return;
                } else if (p.avl[field].balance_factor == 1 or
                    p.avl[field].balance_factor == -1)
                {
                    if (change == 1) {
                        return self.fix(p, field, change);
                    }
                    return;
                } else if (p.avl[field].balance_factor == 2) {
                    if (p.avl[field].l) |l| if (l.avl[field].balance_factor < 0) {
                        self.rotate(l, field, "r");
                    };
                    self.rotate(p, field, "l");
                } else if (p.avl[field].balance_factor == -2) {
                    if (p.avl[field].r) |r| if (r.avl[field].balance_factor > 0) {
                        self.rotate(r, field, "l");
                    };
                    self.rotate(p, field, "r");
                } else unreachable;

                if (p.avl[field].p) |new_p| {
                    if (new_p.avl[field].balance_factor == 0) {
                        if (change == -1) {
                            return self.fix(new_p, field, change);
                        }
                        return;
                    }
                }
            }
        }

        fn add_to_tree_hint(self : *Self, n : *Node, hint: Iterator, comptime field: Field) void {
            var tmp = hint;
            _ = tmp.next();
            if (hint.is_valid() and
            (!tmp.is_valid() or self.compare_values_by_field(field, n.*, tmp.base().node.?.*)) and !self.compare_values_by_field(field, n.*, hint.base().node.?.*)

            ) {
                const node = hint.base().node.?;
                if (node.avl[field].r == null) {
                    node.avl[field].r = n;
                    n.avl[field].p = node;
                    self.fix(n, field, 1);
                } else {
                    const next = next_node(node, field, "r").?;
                    next.avl[field].l = n;
                    n.avl[field].p = next;
                    self.fix(n, field, 1);
                }
            } else return self.add_to_tree(n, field);
        }

        /// add the node `n` to the tree `field`
        fn add_to_tree(self: *Self, n: *Node, comptime field: Field) void {
            n.avl[field] = .{};

            if (self.tree[field]) |root| {
                var current_node: *Node = root;

                while (true) {
                    if (self.compare_values_by_field(field, n.*, current_node.*)) {
                        if (current_node.avl[field].l) |l| {
                            current_node = l;
                        } else {
                            current_node.avl[field].l = n;
                            n.avl[field].p = current_node;
                            break;
                        }
                    } else {
                        if (current_node.avl[field].r) |r| {
                            current_node = r;
                        } else {
                            current_node.avl[field].r = n;
                            n.avl[field].p = current_node;
                            break;
                        }
                    }
                }
            } else {
                self.tree[field] = n;
                n.avl[field].p = null;
            }
            self.fix(n, field, 1);
        }

        /// remove the node `n` from the tree `field`
        fn remove_from_tree(self: *Self, n: *Node, field: Field) void {
            const ref: *?*Node = self.node_ref(n, field);

            if (n.avl[field].l) |l| {
                if (n.avl[field].r) |_| {
                    if (next_node(n, field, "r")) |next| {
                        self.swap_nodes(n, next, field);
                        return self.remove_from_tree(n, field);
                    } else unreachable;
                } else {
                    self.fix(n, field, -1);
                    ref.* = l;
                    l.avl[field].p = n.avl[field].p;
                }
            } else if (n.avl[field].r) |r| {
                self.fix(n, field, -1);
                ref.* = r;
                r.avl[field].p = n.avl[field].p;
            } else {
                self.fix(n, field, -1);
                ref.* = null;
            }
        }

        fn internal_lower_bound(self: Self, comptime field: Field, v: key_type(field)) ?*Node {
            var next: ?*Node = self.tree[field];
            var ret: ?*Node = null;

            while (next) |current| {
                if (self.compare_keys(field, get_field(current.value, field), v)) {
                    next = current.avl[field].r;
                } else {
                    if (ret == null or !self.compare_values_by_field(field, ret.?.*, current.*)) {
                        ret = current;
                    }
                    next = current.avl[field].l;
                }
            }
            return ret;
        }

        fn internal_upper_bound(self: Self, comptime field: Field, v: key_type(field)) ?*Node {
            var next: ?*Node = self.tree[field];
            var ret: ?*Node = null;

            while (next) |current| {
                if (self.compare_keys(field, v, get_field(current.value, field))) {
                    if (ret == null or !self.compare_values_by_field(field, ret.?.*, current.*)) {
                        ret = current;
                    }
                    next = current.avl[field].l;
                } else {
                    next = current.avl[field].r;
                }
            }
            return ret;
        }

        fn internal_find(self: Self, comptime field: Field, v: key_type(field)) ?*Node {
            var next: ?*Node = self.tree[field];

            return while (next) |current| {
                if (self.compare_keys(field, get_field(current.value, field), v)) {
                    next = current.avl[field].r;
                } else if (self.compare_keys(field, v, get_field(current.value, field))) {
                    next = current.avl[field].l;
                } else {
                    break current;
                }
            } else null;
        }

        /// return the "reference" of a node (a pointer to the pointer to this node)
        fn node_ref(self: *Self, n: *Node, field: Field) *?*Node {
            if (n.avl[field].p) |p| {
                if (p.avl[field].l) |*pl| {
                    if (pl.* == n) {
                        return &p.avl[field].l;
                    }
                }
                if (p.avl[field].r) |*pr| {
                    if (pr.* == n) {
                        return &p.avl[field].r;
                    }
                }
                @panic("invalid tree");
            } else {
                return &self.tree[field];
            }
        }

        /// swap the nodes `a` and `b` in the tree `field`
        fn swap_nodes(self: *Self, a: *Node, b: *Node, field: Field) void {
            const a_ref = self.node_ref(a, field);
            const b_ref = self.node_ref(b, field);

            std.mem.swap(?*Node, a_ref, b_ref);
            std.mem.swap(i8, &a.avl[field].balance_factor, &b.avl[field].balance_factor);
            std.mem.swap(?*Node, &a.avl[field].p, &b.avl[field].p);
            std.mem.swap(?*Node, &a.avl[field].l, &b.avl[field].l);
            if (a.avl[field].l) |l| {
                l.avl[field].p = a;
            }
            if (b.avl[field].l) |l| {
                l.avl[field].p = b;
            }
            std.mem.swap(?*Node, &a.avl[field].r, &b.avl[field].r);
            if (a.avl[field].r) |r| {
                r.avl[field].p = a;
            }
            if (b.avl[field].r) |r| {
                r.avl[field].p = b;
            }
        }

        /// return the next node in the tree
        fn next_node(n: *Node, field: Field, comptime direction: []const u8) ?*Node {
            const opposite_direction = comptime if (std.mem.eql(u8, direction, "l")) "r" else "l";

            if (@field(n.avl[field], direction)) |d| {
                var ret = d;
                while (@field(ret.avl[field], opposite_direction)) |o| {
                    ret = o;
                } else {
                    return ret;
                }
            } else {
                var current: ?*Node = n;
                while (current) |c| {
                    if (c.avl[field].p) |p| {
                        if (c == @field(p.avl[field], direction)) {
                            current = p;
                        } else break;
                    } else break;
                }
                if (current) |c| {
                    return c.avl[field].p;
                }
                return null;
            }
        }

        fn get_field(v: T, comptime field: Field) key_type(field) {
            return @field(v, @tagName(key_name(field)));
        }

        fn compare_values_by_field(self: Self, comptime field: Field, l: Node, r: Node) bool {
            return self.compare_keys(field, get_field(l.value, field), get_field(r.value, field));
        }

        fn compare_keys(self: Self, comptime field: Field, l: key_type(field), r: key_type(field)) bool {
            _ = self;
            if (key_config(field).compare_fn) |f| {
                return f(l, r);
            }
            return l < r;
        }

        fn create_node(self : *Self, value : T) !*Node {
            const n: *Node = try self.allocator.create(Node);
            n.* = .{
                .value = value,
            };
            return n;
        }

        fn destroy_node(self : *Self, node : *Node) void {
            self.allocator.free(@as([*]Node, @ptrCast(node))[0..1]);
        }

        pub fn key_index(comptime fieldEnum: FieldEnum) Field {
            for (keys, 0..) |k, i| {
                if (fieldEnum == k)
                    return i;
            }
            @panic("no such key");
        }

        pub fn key_name(comptime field: Field) FieldEnum {
            return keys[field];
        }

        pub fn key_config(comptime field: Field) std.meta.Child(std.meta.FieldType(Config(T), key_name(field))) {
            return @field(config, @tagName(key_name(field))).?;
        }

        pub fn key_type(comptime field: Field) type {
            return std.meta.FieldType(T, key_name(field));
        }

        /// print recursively the content of a node in the tree `field`, `depth` is the depth of this node
        fn print_node(self: *Self, n: *Node, comptime field: Field, depth: u32) void {
            if (n.avl[field].l) |l| {
                self.print_node(l, field, depth + 1);
            }
            for (0..depth) |_| {
                std.debug.print(" ", .{});
            }
            std.debug.print("0x{x} (n: 0x{x:0>16} p: 0x{x:0>16}) balance_factor: {d}\n", .{
                @field(n.value, @tagName(key_name(field))),
                @as(usize, @intFromPtr(n)),
                @as(usize, @intFromPtr(n.avl[field].p)),
                n.avl[field].balance_factor,
            });
            if (n.avl[field].r) |r| {
                self.print_node(r, field, depth + 1);
            }
        }

        /// print the two AVLs using printk
        pub fn print(self: *Self) void {
            inline for (0..nkey) |k| {
                std.debug.print("coucou {} {?*}\n", .{k, self.tree[k]});
                if (self.tree[k]) |r| {
                    self.print_node(r, k, 0);
                    std.debug.print("\n", .{});
                }
            }
        }
    };
}
