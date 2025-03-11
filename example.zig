const std = @import("std");
const MultiIndex = @import("src/multi_index.zig").MultiIndex;

const Human = struct {
    name: []const u8,
    age: u8,
    description: []const u8,

    pub fn format(value: Human, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("{s} ({}): {s}", .{ value.name, value.age, value.description });
    }
};

fn compare_strings(l: []const u8, r: []const u8) bool {
    return std.mem.order(u8, l, r) == .lt;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var humans = MultiIndex(Human, .{
        .name = .{ .unique = true, .compare_fn = compare_strings },
        .age = .{},
    }).init(gpa.allocator());

    defer humans.deinit();

    try humans.insert(.{ .name = "Timmy Timeless", .age = 255, .description = "Might be older than the universe but acts like a 5-year-old" });
    try humans.insert(.{ .name = "Baby Genius", .age = 1, .description = "PhD in quantum physics and speaks fluent Klingon" });
    try humans.insert(.{ .name = "Captain Awesome", .age = 30, .description = "Can juggle chainsaws while solving a Rubik's cube" });
    try humans.insert(.{ .name = "Granny Zoom", .age = 99, .description = "Wins marathons and rides a skateboard better than you" });
    try humans.insert(.{ .name = "Fluffy the Human", .age = 7, .description = "Convinced they are a golden retriever. Plays fetch, barks occasionally." });
    try humans.insert(.{ .name = "Code Lord 3000", .age = 27, .description = "Breathes coffee, writes Zig code for fun, owns 37 keyboards." });
    try humans.insert(.{ .name = "Ponderous Pete", .age = 60, .description = "Constantly asks 'What does it mean to be human?' then stares at a potato." });
    try humans.insert(.{ .name = "Nameless", .age = 0, .description = "Human description here" });
    try humans.insert(.{ .name = "Prankster Paul", .age = 16, .description = "Added hot sauce to the school’s fire extinguisher. No regrets." });

    std.debug.print("find human named \"Code Lord 3000\" (we need him):\n", .{});
    if (humans.find(.name, "Code Lord 3000")) |v| {
        std.debug.print("=> {}\n", .{v});
    }
    std.debug.print("\n", .{});

    std.debug.print("find all humans aged 16 to 30 (to draft them for war against c++):\n", .{});
    var range = humans.range(.age, 16, 30);
    while (range.next()) |h| {
        std.debug.print("- {}\n", .{h});
    }
}
