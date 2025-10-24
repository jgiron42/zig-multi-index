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

	pub fn next(self : *Node) ?*Node {
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

const Config = struct {
	compare : fn (*Node, *Node) std.math.Order,
	unique : bool,
};

pub fn AVL(comptime config : Config) type{
	return struct {
		allocator: std.mem.Allocator,
		tree: ?*Node = null,

		const Self = @This();

		pub fn init(allocator: std.mem.Allocator) Self {
			return Self{
				.allocator = allocator,
			};
		}

		pub fn deinit(_ : *Self) void {
		}

		pub fn begin(self : Self) ?*Node {
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

		pub fn insert(self: *Self, n : *Node) !void {
			return self.add_to_tree(n);
		}

		pub fn erase(self : *Self, node : *Node) void {
			self.remove_from_tree(node);
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

		pub fn find(self: Self, key : *Node) ?*Node {
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

		pub fn lower_bound(self: Self, key : *Node) ?*Node {
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
						return current_node;
					},
				}
			}
		}

		pub fn upper_bound(self: Self, key : *Node) ?*Node {
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