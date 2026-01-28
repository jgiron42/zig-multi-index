// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joachim Giron

const std = @import("std");

pub const Node = struct {
    next_: ?*Node = null,

    pub fn next(_: *Node) ?*Node {
        return null;
    }
};

pub const Hint = struct {
    dst: LinkRef,
    src: ?LinkRef = null,
    pub const LinkRef = *?*Node;
};

const Config = struct {
    Context: type,
    unique: bool,
    max_load_factor: f32 = 2,
    resize_factor: f32 = 1.5,
    base_cap: usize = 10,
};

pub const Range = struct {
    begin: ?*Node,
    end: ?*Node,
};

pub fn FromTypeConfig(
    T: type,
    adaptor: fn (*Node) T,
    config: @import("../config.zig").TypeConfig(T),
) type {
    if (config.hash_context == null)
        @compileError("Index hash_table needs a hash_context");
    return HashTable(.{
        .Context = struct {
            subContext: config.hash_context.? = .{},
            pub fn hash(self: @This(), node: *Node) u64 {
                return self.subContext.hash(adaptor(node));
            }
            pub fn eql(self: @This(), left_node: *Node, right_node: *Node) bool {
                return self.subContext.eql(adaptor(left_node), adaptor(right_node));
            }
        },
        .unique = config.unique,
    });
}

pub fn HashTable(comptime config: Config) type {
    return struct {
        allocator: std.mem.Allocator,
        table: []?*Node = &.{},
        size: usize = 0,
        hash_context: config.Context = .{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.table);
            self.table = &.{};
        }

        pub fn reset(self: *Self, allocator: std.mem.Allocator, comptime free_fn_opt: ?fn (allocator: std.mem.Allocator, *Node) void) void {
            if (free_fn_opt) |free_fn| {
                for (self.table) |opt_node| {
                    var current = opt_node;
                    while (current) |node| {
                        const tmp = node.next_;
                        free_fn(allocator, node);
                        current = tmp;
                    }
                }
            }
            @memset(self.table, null);
            self.size = 0;
        }

        fn get_bucket_idx(self: Self, node: *Node) usize {
            return @as(usize, @truncate(self.hash_context.hash(node))) % self.table.len;
        }

        fn rehash(self: *Self, new_cap: usize) std.mem.Allocator.Error!void {
            const new_table = try self.allocator.alloc(?*Node, new_cap);
            @memset(new_table, null);
            var new_self = Self{
                .allocator = self.allocator,
                .table = new_table,
            };
            errdefer new_self.deinit();
            for (self.table) |opt_node| {
                var current = opt_node;
                while (current) |node| {
                    current = node.next_;
                    try new_self.unsafe_insert(node);
                }
            }
            self.deinit();
            self.* = new_self;
        }

        fn ensure_load_factor(self: *Self) std.mem.Allocator.Error!void {
            if (self.table.len == 0) {
                try self.rehash(config.base_cap);
            } else if ((@as(f32, @floatFromInt(self.size)) * config.max_load_factor) >= @as(f32, @floatFromInt(self.table.len))) {
                try self.rehash(@intFromFloat(@ceil(@as(f32, @floatFromInt(self.size)) * config.max_load_factor * config.resize_factor)));
            }
        }

        pub fn unsafe_insert(self: *Self, n: *Node) std.mem.Allocator.Error!void {
            const hint = self.prepare_insert(n) catch |e| switch (e) {
                error.Duplicate => unreachable,
                else => |err| return err,
            };
            return self.finish_insert(hint, n);
        }

        pub fn prepare_insert(self: *Self, n: *Node) (std.mem.Allocator.Error || error{Duplicate})!Hint {
            try self.ensure_load_factor();
            const bucket_idx = self.get_bucket_idx(n);
            if (self.find_in_bucket(self.table[bucket_idx], n)) |node| {
                if (config.unique)
                    return error.Duplicate;
                return Hint{ .dst = &node.next_ };
            } else {
                return Hint{ .dst = &self.table[bucket_idx] };
            }
        }

        pub fn finish_insert(self: *Self, hint: Hint, n: *Node) error{}!void {
            n.next_ = hint.dst.*;
            hint.dst.* = n;
            self.size += 1;
        }

        fn is_same_bucket(self: Self, a: *Node, b: *Node) bool {
            return self.get_bucket_idx(a) == self.get_bucket_idx(b);
        }

        pub fn prepare_update(self: *Self, n: *Node, new_node: *Node) !?Hint {
            if (self.hash_context.eql(n, new_node)) // or self.is_same_bucket(n, new_node)
                return null;
            var tmp = try self.prepare_insert(new_node);
            tmp.src = self.get_ref(n) orelse @panic("Node not found");
            return tmp;
        }

        pub fn finish_update(self: *Self, hint: Hint, n: *Node) !void {
            if (hint.src == null)
                @panic("Invalid hint");
            if (hint.src.? == hint.dst)
                return;
            self.erase_ref(hint.src.?);
            return self.finish_insert(hint, n) catch unreachable;
        }

        pub fn erase(self: *Self, node: *Node) void {
            self.erase_ref(self.get_ref(node) orelse @panic("Node not found"));
        }

        pub fn erase_ref(self: *Self, ref: Hint.LinkRef) void {
            const node = ref.*.?;
            ref.* = node.next_;
            node.next_ = null;
            self.size -= 1;
        }

        fn get_ref(self: Self, node: *Node) ?Hint.LinkRef {
            const bucket_idx = self.get_bucket_idx(node);
            if (self.table[bucket_idx]) |first| {
                if (first == node) {
                    return &self.table[bucket_idx];
                } else {
                    var tmp = first;
                    while (tmp.next_) |next| {
                        if (next == node) {
                            return &tmp.next_;
                        } else {
                            tmp = next;
                        }
                    }
                }
            }
            return null;
        }

        fn find_in_bucket(self: Self, bucket: ?*Node, node: *Node) ?*Node {
            var tmp = bucket;
            while (tmp) |current| {
                if (self.hash_context.eql(current, node)) {
                    return current;
                }
                tmp = current.next_;
            }
            return null;
        }

        pub fn equal_range(self: Self, node: *Node) Range {
            const bucket_idx = self.get_bucket_idx(node);
            const begin = self.find_in_bucket(self.table[bucket_idx], node);
            var end = begin;
            while (self.hash_context.eql(begin, end)) {
                end = end.next_;
            }
            return Range{
                .begin = begin,
                .end = end,
            };
        }

        pub fn find(self: Self, node: *Node) ?*Node {
            const bucket_idx = self.get_bucket_idx(node);
            return self.find_in_bucket(self.table[bucket_idx], node);
        }

        pub fn print(self: *Self) void {
            std.debug.print("Hash Table:\n", .{});
            for (self.table) |opt_node| {
                var current = opt_node;
                while (current) |node| {
                    std.debug.print("0x{x:0>16} -> ", .{@as(usize, @intFromPtr(node))});
                    current = node.next_;
                }
                std.debug.print("null\n", .{});
            }
        }
    };
}
