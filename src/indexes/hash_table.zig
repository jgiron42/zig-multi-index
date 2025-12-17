const std = @import("std");

pub const Node = struct {
    next_: ?*Node = null,

    pub fn next(_: *Node) ?*Node {
        return null;
    }
};

pub const Hint = *?*Node;

const Config = struct {
    Context: type,
    unique: bool,
    max_load_factor: f32 = 2,
    resize_factor: f32 = 1.5,
    base_cap: usize = 10,
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

        // todo: make this function safe
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
                    try new_self.insert(node);
                    current = node.next_;
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

        pub fn insert(self: *Self, n: *Node) std.mem.Allocator.Error!void {
            try self.ensure_load_factor();
            const bucket_idx = self.get_bucket_idx(n);
            if (self.table[bucket_idx]) |bucket| {
                var tmp = bucket;
                while (tmp.next_) |next| {
                    tmp = next;
                }
                tmp.next_ = n;
            } else {
                self.table[bucket_idx] = n;
            }
            n.next_ = null;
        }

        pub fn prepare_insert(self: *Self, n: *Node) (std.mem.Allocator.Error || error{Duplicate})!Hint {
            try self.ensure_load_factor();
            const bucket_idx = self.get_bucket_idx(n);
            if (config.unique and self.find_in_bucket(self.table[bucket_idx], n) != null)
                return error.Duplicate;
            return &self.table[bucket_idx];
        }

        pub fn finish_insert(self: *Self, hint: Hint, n: *Node) !void {
            if (hint.*) |hint_node| {
                n.next_ = hint_node;
            } else {
                n.next_ = null;
            }
            hint.* = n;
            self.size += 1;
        }

        fn is_same_bucket(self: Self, a: *Node, b: *Node) bool {
            return self.get_bucket_idx(a) == self.get_bucket_idx(b);
        }

        pub fn prepare_update(self: *Self, n: *Node, new_node: *Node) !?Hint {
            if (self.hash_context.eql(n, new_node) or self.is_same_bucket(n, new_node))
                return null;
            return self.prepare_insert(new_node) catch |e| e;
        }

        pub fn finish_update(self: *Self, hint: Hint, n: *Node) !void {
            self.erase(n);
            return self.finish_insert(hint, n) catch self.insert(n);
        }

        pub fn erase(self: *Self, node: *Node) void {
            const bucket = self.get_bucket_idx(node);
            if (self.table[bucket]) |first| {
                if (self.hash_context.eql(first, node)) {
                    self.table[bucket] = first.next_;
                } else {
                    var tmp = first;
                    while (tmp.next_) |next| {
                        if (self.hash_context.eql(next, node)) {
                            tmp.next_ = next.next_;
                            return;
                        } else {
                            tmp = next;
                        }
                    }
                }
            }
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

        pub fn find(self: Self, node: *Node) ?*Node {
            const bucket_idx = self.get_bucket_idx(node);
            return self.find_in_bucket(self.table[bucket_idx], node);
        }

        pub fn print(_: *Self) void {}
    };
}
