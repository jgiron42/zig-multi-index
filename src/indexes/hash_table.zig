const std = @import("std");

pub const Node = struct {
    next : ?*Node,
};

pub const Hint = *?*Node;

const Config = struct {
    hash:  fn (*Node) usize,
    eql : fn (*Node, *Node, usize) bool,
    unique : bool,
    max_load_factor : f32 = 2,
};

pub fn HashTable(comptime config : Config) type{
    return struct {
        allocator: std.mem.Allocator,
        table: []?*Node = &.{},
        size: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
            };
        }

        pub fn deinit(_ : *Self) void {
        }

        pub fn begin(self : Self) ?*Node {
        }

        pub fn insert(self: *Self, n : *Node) !void {
            const bucket = config.hash(n) % self.table.len;
            var tmp = self.table[bucket];
            if (tmp != null) {
                while (tmp.next) |next| {
                    tmp = next;
                }
                tmp.next = n;
            } else {
                self.table[bucket] = n;
            }
            n.next = null;
        }

        pub fn prepare_insert(self: *Self, n : *Node) !Hint {
        }

        pub fn finish_insert(self: *Self, hint : Hint, n : *Node) !void {
        }

        pub fn prepare_update(self: *Self, n : *Node, new_node : *Node) !?Hint {
        }

        pub fn finish_update(self: *Self, hint : Hint, n : *Node) !void {
        }

        pub fn erase(self : *Self, node : *Node) void {
        }

        fn last(self : Self) ?*Node {
        }

		pub fn print(self: *Self) void {
        }
    };
}