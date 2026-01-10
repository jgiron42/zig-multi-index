const std = @import("std");
const MultiIndex = @import("src/multi_index.zig").MultiIndex;
const avl = @import("src/indexes/avl.zig");

const Human = struct {
    name: []const u8,
    age: u8,
    description: []const u8,

    pub fn format(value: Human, writer: anytype) !void {
        return writer.print("{s} ({}): {s}", .{ value.name, value.age, value.description });
    }
};

const samples = [_]Human{
    .{ .name = "Timmy Timeless", .age = 255, .description = "Might be older than the universe but acts like a 5-year-old" },
    .{ .name = "Baby Genius", .age = 1, .description = "PhD in quantum physics and speaks fluent Klingon" },
    .{ .name = "Captain Awesome", .age = 30, .description = "Can juggle chainsaws while solving a Rubik's cube" },
    .{ .name = "Granny Zoom", .age = 99, .description = "Wins marathons and rides a skateboard better than you" },
    .{ .name = "Fluffy the Human", .age = 7, .description = "Convinced they are a golden retriever. Plays fetch, barks occasionally." },
    .{ .name = "Code Lord 3000", .age = 27, .description = "Breathes coffee, writes Zig code for fun, owns 37 keyboards." },
    .{ .name = "Ponderous Pete", .age = 60, .description = "Constantly asks 'What does it mean to be human?' then stares at a potato." },
    .{ .name = "Nameless", .age = 0, .description = "Human description here" },
    .{ .name = "Prankster Paul", .age = 16, .description = "Added hot sauce to the school’s fire extinguisher. No regrets." },
};

const HumanIndex = MultiIndex(Human, .{
    .name = .{
        .unique = true,
        .ordered = false,
    },
    .age = .{},
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var humans = HumanIndex.init(gpa.allocator());

    defer humans.deinit();

    for (samples) |human| {
        try humans.insert(human);
    }

    std.debug.print("find human named \"Code Lord 3000\" (we need them):\n", .{});
    if (humans.find(.name, "Code Lord 3000")) |v| {
        std.debug.print("=> {f}\n", .{v});
    }
    std.debug.print("\n", .{});

    std.debug.print("find all humans aged 16 to 30 (to draft them for war against C++):\n", .{});
    var range = humans.range(.age, 16, 30);
    while (range.next()) |h| {
        std.debug.print("- {f}\n", .{h});
    }
}
