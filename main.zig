const std = @import("std");
const MultiIndex = @import("src/multi_index.zig").MultiIndex;

const S = struct {
    a: usize,
    b: usize = 0,
    c: usize = 0,
    d: usize = 0,
};

fn hash_usize(val : usize) usize {
    return val;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = false }){};
    defer std.debug.print("leaks: {}", .{gpa.deinit()});

    var map = MultiIndex(S, .{
        .a = .{ .unique = true },
        .c = .{},
        .d = .{.ordered = false},
    }).init(gpa.allocator());
    defer map.deinit();

    map.insert(.{
        .a = 42,
        .c = 42,
    }) catch @panic("");
    map.insert(.{
        .a = 43,
        .c = 44,
    }) catch @panic("");
    map.insert(.{
        .a = 44,
        .c = 43,
    }) catch @panic("");
    map.insert(.{
        .a = 45,
        .c = 44,
    }) catch @panic("");
    map.insert(.{
        .a = 43,
        .c = 46,
    }) catch std.debug.print("duplicate key 43\n", .{});

    map.print();

    std.debug.print("{}\n", .{map.count()});
    std.debug.print("{any}\n", .{map.find_it(.a, 44).peek()});
    std.debug.print("{any}\n", .{map.find(.a, 44).?});
    // std.debug.print("{any}\n", .{map.find(.b, 44).?});
    std.debug.print("{any}\n", .{map.find(.c, 42).?});
    std.debug.print("\n", .{});

    {
        var it = map.lower_bound(.a, 42);
        std.debug.print("{any}\n", .{it.peek()});
        // std.debug.print("{?*}\n", .{it.node});
        while (it.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        std.debug.print("\n", .{});
    }
    {
        var view = map.equal_range(.a, 43);
        while (view.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        std.debug.print("\n", .{});

        view = map.equal_range(.c, 46);
        while (view.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        std.debug.print("\n", .{});

        view = map.equal_range(.c, 44);
        while (view.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("erase range\n", .{});
    map.erase_range(map.equal_range(.a, 43));
    {
        var view = map.lower_bound(.a, 42);
        while (view.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        //     std.debug.print("=> {?any}\n", .{view.peek()});
        //     view.advance(-1);
        //     std.debug.print("=> {?any}\n", .{view.peek()});
        //     view.advance(-1);
        //     std.debug.print("=> {?any}\n", .{view.peek()});
        //     view.advance(-1);
        //     std.debug.print("=> {?any}\n", .{view.peek()});
        //     view.advance(1234);
        //     view.advance(-1233);
        //     std.debug.print("=> {?any}\n", .{view.peek()});
        //     std.debug.print("\n", .{});
    }

    {
        const it = map.find_it(.a, 42);
        _ = map.update(it, .{
            .a = 12,
            .c = 43,
        }) catch @panic("failed to update");
    }

    {
        var it = map.lower_bound(.a, 0);
        std.debug.print("{any}\n", .{it.peek()});
        // std.debug.print("{?*}\n", .{it.node});
        while (it.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        std.debug.print("\n", .{});
    }
    {
        const it = map.find_it(.a, 12);
        _ = map.update(it, .{
            .a = 46,
            .c = 43,
        }) catch @panic("failed to update");
    }

    {
        var it = map.lower_bound(.a, 0);
        std.debug.print("{any}\n", .{it.peek()});
        // std.debug.print("{?*}\n", .{it.node});
        while (it.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        std.debug.print("\n", .{});
    }

    {
        const it = map.find_it(.a, 12);
        _ = map.update(it, .{
            .a = 44,
            .c = 50,
        }) catch std.debug.print("failed to update value \n", .{});
    }

    {
        var it = map.lower_bound(.a, 0);
        std.debug.print("{any}\n", .{it.peek()});
        // std.debug.print("{?*}\n", .{it.node});
        while (it.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        std.debug.print("\n", .{});
    }

    {
        var it = map.lower_bound(.c, 0);
        std.debug.print("{any}\n", .{it.peek()});
        // std.debug.print("{?*}\n", .{it.node});
        while (it.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        std.debug.print("\n", .{});
    }

    {
        var it = map.lower_bound(.a, 0);
        std.debug.print("{any}\n", .{it.peek()});
        // std.debug.print("{?*}\n", .{it.node});
        while (it.next()) |e| {
            std.debug.print("=> {any}\n", .{e});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("{any}\n", .{map.find(.a, 44).?});
    map.print();
}
