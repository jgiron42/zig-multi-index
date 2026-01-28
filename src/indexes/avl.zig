// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joachim Giron
const std = @import("std");

pub const Node = struct {
    /// left node
    l: ?*Node = null,
    /// right node
    r: ?*Node = null,
    /// parent node
    p: ?*Node = null,
    /// balance factor used by the avl algorithm
    balance_factor: i8 = 0,

    pub fn next(self: *Node) ?*Node {
        return self.next_with_direction("r");
    }

    /// return the next node in the tree
    pub fn next_with_direction(n: *Node, comptime direction: []const u8) ?*Node {
        const opposite_direction = comptime if (std.mem.eql(u8, direction, "l")) "r" else "l";

        if (@field(n, direction)) |d| {
            var ret = d;
            while (@field(ret, opposite_direction)) |o| {
                ret = o;
            } else {
                return ret;
            }
        } else {
            var current: ?*Node = n;
            while (current) |c| {
                if (c.p) |p| {
                    if (c == @field(p, direction)) {
                        current = p;
                    } else break;
                } else break;
            }
            if (current) |c| {
                return c.p;
            }
            return null;
        }
    }
};

pub const Hint = ?*Node;

const Config = struct {
    compare: fn (*Node, *Node) std.math.Order,
    unique: bool,
};

pub fn FromTypeConfig(
    T: type,
    adaptor: fn (*Node) T,
    config: @import("../config.zig").TypeConfig(T),
) type {
    if (config.compare_fn == null)
        @compileError("Index AVL needs a compare_fn");
    return AVL(.{
        .compare = struct {
            pub fn compare(left_node: *Node, right_node: *Node) std.math.Order {
                return config.compare_fn.?(adaptor(left_node), adaptor(right_node));
            }
        }.compare,
        .unique = config.unique,
    });
}

pub fn AVL(comptime config: Config) type {
    return struct {
        allocator: std.mem.Allocator,
        tree: ?*Node = null,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
            };
        }

        pub fn deinit(_: *Self) void {}

        pub fn reset(self: *Self, allocator: std.mem.Allocator, comptime free_fn_opt: ?fn (std.mem.Allocator, *Node) void) void {
            var current = self.tree orelse return;
            if (free_fn_opt) |free_fn| {
                while (true) {
                    if (current.l) |left| {
                        current = left;
                    } else if (current.r) |right| {
                        current = right;
                    } else if (current.p) |parent| {
                        if (parent.l == current) {
                            parent.l = null;
                        } else {
                            parent.r = null;
                        }
                        free_fn(allocator, current);
                        current = parent;
                    } else {
                        free_fn(allocator, current);
                        return;
                    }
                }
            }
            self.tree = null;
        }

        pub fn begin(self: Self) ?*Node {
            if (self.tree) |tree| {
                var node = tree;
                while (node.l) |l| {
                    node = l;
                }
                return node;
            } else {
                return null;
            }
        }

        pub fn insert(self: *Self, n: *Node) !void {
            return self.add_to_tree(n);
        }

        pub fn prepare_insert(self: *Self, n: *Node) !Hint {
            if (self.tree == null)
                return null;
            if (self.upper_bound(n)) |next| {
                if (next_node(next, "l")) |prev| {
                    if (config.unique and compare_nodes(prev, n) == .eq)
                        return error.Duplicate;
                }
                return next;
            } else if (self.last()) |prev| {
                if (config.unique and compare_nodes(prev, n) == .eq)
                    return error.Duplicate;
                return prev;
            } else unreachable;
        }

        pub fn finish_insert(self: *Self, hint: Hint, n: *Node) error{InvalidHint}!void {
            return self.add_to_tree_hint(hint, n);
        }

        fn need_reorder(n: *Node, new_node: *Node) bool {
            if (next_node(n, "l")) |prev|
                if (compare_nodes(prev, new_node) != .lt)
                    return true;
            if (next_node(n, "r")) |next|
                if (compare_nodes(new_node, next) != .lt)
                    return true;
            return false;
        }

        pub fn prepare_update(self: *Self, n: *Node, new_node: *Node) !?Hint {
            if (compare_nodes(n, new_node) == .eq or !need_reorder(n, new_node))
                return null;
            return self.prepare_insert(new_node) catch |e| e;
        }

        pub fn finish_update(self: *Self, hint: Hint, n: *Node) !void {
            self.erase(n);
            return self.finish_insert(hint, n) catch self.insert(n);
        }

        pub fn erase(self: *Self, node: *Node) void {
            self.remove_from_tree(node);
        }

        fn last(self: Self) ?*Node {
            var node = self.tree;
            while (node) |n| {
                if (n.r) |r| {
                    node = r;
                } else return n;
            }
            return null;
        }

        /// AVL tree rotation, rotate the node `n` in the direction `direction` ("l" or "r")
        fn rotate(self: *Self, n: *Node, comptime direction: []const u8) void {
            const opposite_direction = comptime if (std.mem.eql(u8, direction, "l")) "r" else "l";
            const ref = self.node_ref(n);

            const l: *Node = @field(n, direction) orelse return;
            const op: ?*Node = n.p;

            const bn = n.balance_factor;
            const bl = l.balance_factor;
            if (comptime std.mem.eql(u8, direction, "l")) {
                if (bl > 0) {
                    n.balance_factor -= 1 + bl;
                    l.balance_factor = -1 + @min(bl, bn - 1);
                } else {
                    n.balance_factor -= 1;
                    l.balance_factor = bl - 1 + @min(0, bn - 1);
                }
            } else {
                if (bl < 0) {
                    n.balance_factor += 1 - bl;
                    l.balance_factor = 1 + @max(bn + 1, bl);
                } else {
                    n.balance_factor += 1;
                    l.balance_factor = bl + 1 + @max(bn + 1, 0);
                }
            }

            @field(n, direction) = @field(l, opposite_direction);
            if (@field(n, direction)) |nl|
                nl.p = n;

            @field(l, opposite_direction) = n;
            if (@field(l, opposite_direction)) |lr|
                lr.p = l;

            ref.* = l;
            l.p = op;
        }

        /// debug function, used to check that a tree respect the rules of the AVL algorithm,
        /// this function panic if the tree is invalid
        fn check_node(self: *Self, n: *Node) i32 {
            const dl: i32 = if (n.l) |l| self.check_node(l) else 0;
            const dr: i32 = if (n.r) |r| self.check_node(r) else 0;
            if (dl - dr != n.balance_factor or
                n.balance_factor > 1 or
                n.balance_factor < -1)
            {
                self.print();
                @panic("invalid tree in " ++ @typeName(Self));
            }
            return @max(dl, dr) + 1;
        }

        /// fix the node `n` in the tree `field`, the parameter `change` indicate the weight modification of the node,
        /// eg: 1 if the node is 1 node heavier than before or -1 if the node is 1 node lighter than before
        fn fix(self: *Self, n: *Node, change: i8) void {
            if (n.p) |p| {
                if (p.l) |pl| if (pl == n) {
                    p.balance_factor += change;
                };
                if (p.r) |pr| if (pr == n) {
                    p.balance_factor -= change;
                };

                if (p.balance_factor == 0) {
                    if (change == -1) {
                        return self.fix(p, change);
                    }
                    return;
                } else if (p.balance_factor == 1 or
                    p.balance_factor == -1)
                {
                    if (change == 1) {
                        return self.fix(p, change);
                    }
                    return;
                } else if (p.balance_factor == 2) {
                    if (p.l) |l| if (l.balance_factor < 0) {
                        self.rotate(l, "r");
                    };
                    self.rotate(p, "l");
                } else if (p.balance_factor == -2) {
                    if (p.r) |r| if (r.balance_factor > 0) {
                        self.rotate(r, "l");
                    };
                    self.rotate(p, "r");
                } else unreachable;

                if (p.p) |new_p| {
                    if (new_p.balance_factor == 0) {
                        if (change == -1) {
                            return self.fix(new_p, change);
                        }
                        return;
                    }
                }
            }
        }

        fn check_hint(self: *Self, hint: Hint, n: *Node) bool {
            if (hint) |h| {
                switch (compare_nodes(n, h)) {
                    .lt => {
                        const next = compare_nodes(n, next_node(h, "l"));
                        return if (config.unique) next == .gt else next != .lt;
                    },
                    .gt => {
                        const prev = compare_nodes(n, next_node(h, "r"));
                        return if (config.unique) prev == .lt else prev != .gt;
                    },
                    .eq => {
                        return !config.unique;
                    },
                }
            } else {
                return self.tree == null;
            }
        }

        fn add_between_nodes_unsafe(n: *Node, prev: ?*Node, next: ?*Node) void {
            if (prev != null and prev.?.r == null) {
                prev.?.r = n;
                n.p = prev;
            } else if (next != null and next.?.l == null) {
                next.?.l = n;
                n.p = next;
            } else unreachable;
        }

        fn add_to_tree_hint(self: *Self, hint: Hint, n: *Node) error{InvalidHint}!void {
            if (hint) |h| {
                switch (compare_nodes(n, h)) {
                    .lt => {
                        const prev = next_node(h, "l");
                        if (prev != null) {
                            const prev_compare = compare_nodes(n, prev.?);
                            if ((config.unique and prev_compare != .gt) or (!config.unique and prev_compare == .lt))
                                return error.InvalidHint;
                        }
                        add_between_nodes_unsafe(n, prev, h);
                    },
                    .gt => {
                        const next = next_node(h, "r");
                        if (next != null) {
                            const next_compare = compare_nodes(n, next.?);
                            if ((config.unique and next_compare != .lt) or (!config.unique and next_compare == .gt))
                                return error.InvalidHint;
                        }
                        add_between_nodes_unsafe(n, h, next);
                    },
                    .eq => {
                        if (config.unique)
                            return error.InvalidHint;
                        add_between_nodes_unsafe(n, h, next_node(h, "r"));
                    },
                }
            } else if (self.tree == null) {
                self.tree = n;
                n.p = null;
            } else return error.InvalidHint;
            self.fix(n, 1);
        }

        /// add the node `n` to the tree
        fn add_to_tree(self: *Self, n: *Node) !void {
            n.* = .{};

            if (self.tree) |root| {
                var current_node: *Node = root;

                while (true) {
                    switch (compare_nodes(n, current_node)) {
                        .lt => {
                            if (current_node.l) |l| {
                                current_node = l;
                            } else {
                                current_node.l = n;
                                n.p = current_node;
                                break;
                            }
                        },
                        .gt, .eq => |comparison_result| {
                            if (config.unique and comparison_result == .eq) {
                                return error.Duplicate;
                            }
                            if (current_node.r) |r| {
                                current_node = r;
                            } else {
                                current_node.r = n;
                                n.p = current_node;
                                break;
                            }
                        },
                    }
                }
            } else {
                if (self.tree != null)
                    @panic("invalid hint");
                self.tree = n;
                n.p = null;
            }
            self.fix(n, 1);
        }

        /// remove the node `n` from the tree
        fn remove_from_tree(self: *Self, n: *Node) void {
            const ref: *?*Node = self.node_ref(n);

            if (n.l) |l| {
                if (n.r) |_| {
                    if (next_node(n, "r")) |next| {
                        self.swap_nodes(n, next);
                        return self.remove_from_tree(n);
                    } else unreachable;
                } else {
                    self.fix(n, -1);
                    ref.* = l;
                    l.p = n.p;
                }
            } else if (n.r) |r| {
                self.fix(n, -1);
                ref.* = r;
                r.p = n.p;
            } else {
                self.fix(n, -1);
                ref.* = null;
            }
        }

        pub fn find(self: Self, key: *Node) ?*Node {
            var current_node: *Node = self.tree orelse return null;

            while (true) {
                switch (compare_nodes(key, current_node)) {
                    .lt => {
                        if (current_node.l) |l| {
                            current_node = l;
                        } else return null;
                    },
                    .gt => {
                        if (current_node.r) |r| {
                            current_node = r;
                        } else return null;
                    },
                    .eq => {
                        return current_node;
                    },
                }
            }
        }

        pub fn lower_bound(self: Self, key: *Node) ?*Node {
            var current_node: *Node = self.tree orelse return null;
            var current_lower_bound: ?*Node = null;

            while (true) {
                switch (compare_nodes(key, current_node)) {
                    .lt => {
                        current_lower_bound = current_node;
                        if (current_node.l) |l| {
                            current_node = l;
                        } else return current_lower_bound;
                    },
                    .gt => {
                        if (current_node.r) |r| {
                            current_node = r;
                        } else return current_lower_bound;
                    },
                    .eq => {
                        if (config.unique) {
                            return current_node;
                        } else {
                            current_lower_bound = current_node;
                            if (current_node.l) |l| {
                                current_node = l;
                            } else return current_lower_bound;
                        }
                    },
                }
            }
        }

        pub fn upper_bound(self: Self, key: *Node) ?*Node {
            var current_node: *Node = self.tree orelse return null;
            var current_upper_bound: ?*Node = null;

            while (true) {
                switch (compare_nodes(key, current_node)) {
                    .lt => {
                        current_upper_bound = current_node;
                        if (current_node.l) |l| {
                            current_node = l;
                        } else return current_upper_bound;
                    },
                    .gt, .eq => {
                        if (current_node.r) |r| {
                            current_node = r;
                        } else return current_upper_bound;
                    },
                }
            }
        }

        /// return the "reference" of a node (a pointer to the pointer to this node)
        fn node_ref(self: *Self, n: *Node) *?*Node {
            if (n.p) |p| {
                if (p.l) |*pl| {
                    if (pl.* == n) {
                        return &p.l;
                    }
                }
                if (p.r) |*pr| {
                    if (pr.* == n) {
                        return &p.r;
                    }
                }
                @panic("invalid tree");
            } else {
                return &self.tree;
            }
        }

        /// swap the nodes `a` and `b`
        fn swap_nodes(self: *Self, a: *Node, b: *Node) void {
            const a_ref = self.node_ref(a);
            const b_ref = self.node_ref(b);

            std.mem.swap(?*Node, a_ref, b_ref);
            std.mem.swap(i8, &a.balance_factor, &b.balance_factor);
            std.mem.swap(?*Node, &a.p, &b.p);
            std.mem.swap(?*Node, &a.l, &b.l);
            if (a.l) |l| {
                l.p = a;
            }
            if (b.l) |l| {
                l.p = b;
            }
            std.mem.swap(?*Node, &a.r, &b.r);
            if (a.r) |r| {
                r.p = a;
            }
            if (b.r) |r| {
                r.p = b;
            }
        }

        /// return the next node in the tree
        fn next_node(n: *Node, comptime direction: []const u8) ?*Node {
            const opposite_direction = comptime if (std.mem.eql(u8, direction, "l")) "r" else "l";

            if (@field(n, direction)) |d| {
                var ret = d;
                while (@field(ret, opposite_direction)) |o| {
                    ret = o;
                } else {
                    return ret;
                }
            } else {
                var current: ?*Node = n;
                while (current) |c| {
                    if (c.p) |p| {
                        if (c == @field(p, direction)) {
                            current = p;
                        } else break;
                    } else break;
                }
                if (current) |c| {
                    return c.p;
                }
                return null;
            }
        }

        fn compare_nodes(l: *Node, r: *Node) std.math.Order {
            return config.compare(l, r);
        }

        /// print recursively the content of a node in the tree `field`, `depth` is the depth of this node
        fn print_node(self: *Self, n: *Node, depth: u32) void {
            if (n.l) |l| {
                self.print_node(l, depth + 1);
            }
            for (0..depth) |_| {
                std.debug.print(" ", .{});
            }
            // std.debug.print("0x{x} (n: 0x{x:0>16} p: 0x{x:0>16}) balance_factor: {d}\n", .{
            // @field(n.value, @tagName(key_name(field))),
            // @as(usize, @intFromPtr(n)),
            // @as(usize, @intFromPtr(n.p)),
            // n.balance_factor,
            // });
            std.debug.print("(n: 0x{x:0>16} p: 0x{x:0>16}) balance_factor: {d}\n", .{
                @as(usize, @intFromPtr(n)),
                @as(usize, @intFromPtr(n.p)),
                n.balance_factor,
            });
            if (n.r) |r| {
                self.print_node(r, depth + 1);
            }
        }

        /// print the two AVLs using printk
        pub fn print(self: *Self) void {
            if (self.tree) |r| {
                self.print_node(r, 0);
                std.debug.print("\n", .{});
            }
        }
    };
}
