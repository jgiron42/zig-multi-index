const std = @import("std");
const testing = std.testing;
const MultiIndex = @import("multi_index.zig").MultiIndex;

const User = struct {
    id: u32,
    name: []const u8,
    score: u32,
    age: u8,
};

const UserIndex = MultiIndex(User, .{
    .id = .{ .unique = true, .ordered = false }, // Hash Table
    .name = .{ .unique = true, .ordered = true }, // AVL Tree (Unique)
    .score = .{ .unique = false, .ordered = true }, // AVL Tree (Non-Unique)
    .age = .{ .unique = false, .ordered = false, .hash_context = std.hash_map.AutoContext(u8) }, // Hash Table (Non-Unique? - actually Hash table doesn't support non-unique properly yet per review, will test unique only for now or check config)
});

// Wait, the hash table implementation IS unique only if `unique = true`, otherwise it is a multimap (bucket list).
// Let's verify that.
// src/indexes/hash_table.zig: `find_in_bucket` checks specifically for equality. `insert` just appends to bucket properly chained.
// So yes, non-unique hash table is supported.

test "MultiIndex Operations" {
    var index = UserIndex.init(testing.allocator);
    defer index.deinit();

    // 1. Insert
    try index.insert(.{ .id = 1, .name = "Alice", .score = 100, .age = 30 });
    try index.insert(.{ .id = 2, .name = "Bob", .score = 80, .age = 25 });
    try index.insert(.{ .id = 3, .name = "Charlie", .score = 100, .age = 30 }); // Duplicate score & age allowed

    try testing.expectEqual(@as(usize, 3), index.count());

    // 2. Find (Hash Table - Unique)
    if (index.find(.id, 1)) |u| {
        try testing.expectEqualStrings("Alice", u.name);
    } else return error.NotFound;

    // 3. Find (AVL Unique)
    if (index.find(.name, "Bob")) |u| {
        try testing.expectEqual(@as(u32, 2), u.id);
    } else return error.NotFound;

    // 4. Find (Hash Table - Non-Unique / Multi)
    // Actually `find` returns ONE item. `find_it` returns iterator.
    // Let's test finding by age.
    if (index.find(.age, 30)) |u| {
        // Could be Alice or Charlie
        try testing.expect(u.age == 30);
    } else return error.NotFound;

    // 5. Range Query (AVL Non-Unique)
    var range = index.equal_range(.score, 100);
    var count: usize = 0;
    while (range.next()) |u| {
        try testing.expectEqual(@as(u32, 100), u.score);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);

    // 6. Unique Constraint Violation
    // Attempt duplicate ID
    if (index.insert(.{ .id = 1, .name = "DuplicateId", .score = 0, .age = 0 })) {
        return error.ShouldHaveFailed;
    } else |err| {
        try testing.expectEqual(error.Duplicate, err);
    }

    // Attempt duplicate Name
    if (index.insert(.{ .id = 4, .name = "Alice", .score = 0, .age = 0 })) {
        return error.ShouldHaveFailed;
    } else |err| {
        try testing.expectEqual(error.Duplicate, err);
    }

    try testing.expectEqual(@as(usize, 3), index.count()); // Count should be unchanged

    // 7. Update
    // Let's update Bob's score
    const it = index.find_it(.id, 2);
    _ = try index.update(it, .{ .id = 2, .name = "Bobby", .score = 85, .age = 26 });

    // Verify update
    if (index.find(.name, "Bobby")) |u| {
        try testing.expectEqual(@as(u32, 85), u.score);
        try testing.expectEqual(@as(u8, 26), u.age);
    } else return error.UpdateFailed;

    // Verify old index entry is gone
    if (index.find(.name, "Bob")) |_| {
        return error.OldEntryPersisted;
    }

    // 8. Erase
    const it_erase = index.find_it(.id, 3);
    index.erase_it(it_erase);
    try testing.expectEqual(@as(usize, 2), index.count());

    if (index.find(.id, 3)) |_| {
        return error.EraseFailed;
    }
}

test "Edge Cases: Empty and Single Item" {
    var index = UserIndex.init(testing.allocator);
    defer index.deinit();

    try testing.expectEqual(@as(usize, 0), index.count());

    // Iterate empty range
    var range = index.range(.score, 0, 1000);
    try testing.expect(range.next() == null);

    // Single item lifecycle
    try index.insert(.{ .id = 10, .name = "X", .score = 10, .age = 10 });
    try testing.expectEqual(@as(usize, 1), index.count());

    const it = index.find_it(.id, 10);
    const val = it.peek() orelse return error.NotFound;
    try testing.expectEqual(@as(u32, 10), val.id);

    index.erase_it(it);
    try testing.expectEqual(@as(usize, 0), index.count());
}

test "AVL Ordering: lower_bound and upper_bound" {
    var index = UserIndex.init(testing.allocator);
    defer index.deinit();

    // Insert in random order
    try index.insert(.{ .id = 5, .name = "E", .score = 50, .age = 5 });
    try index.insert(.{ .id = 1, .name = "A", .score = 10, .age = 1 });
    try index.insert(.{ .id = 3, .name = "C", .score = 30, .age = 3 });
    try index.insert(.{ .id = 2, .name = "B", .score = 20, .age = 2 });
    try index.insert(.{ .id = 4, .name = "D", .score = 40, .age = 4 });

    // Verify ordering via lower_bound iteration on 'score'
    var it = index.lower_bound(.score, 0);
    var prev_score: u32 = 0;
    var count: usize = 0;
    while (it.next()) |u| {
        try testing.expect(u.score >= prev_score);
        prev_score = u.score;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);

    // Test upper_bound
    var ub = index.upper_bound(.score, 30);
    if (ub.peek()) |u| {
        try testing.expect(u.score > 30);
    }
}

test "Range Query with Bounds" {
    var index = UserIndex.init(testing.allocator);
    defer index.deinit();

    const names = [_][]const u8{
        "Alice",
        "Bob",
        "Charlie",
        "David",
        "Eve",
        "Frank",
        "Grace",
        "Heidi",
        "Ivan",
        "Judy",
    };

    for (0..10) |i| {
        const id: u32 = @intCast(i);
        try index.insert(.{
            .id = id,
            .name = names[i],
            .score = id * 10,
            .age = @intCast(i),
        });
    }

    // Range [20, 70]
    var range = index.range(.score, 20, 70);
    var count: usize = 0;
    while (range.next()) |u| {
        try testing.expect(u.score >= 20 and u.score <= 70);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 6), count); // 20, 30, 40, 50, 60, 70
}

test "Update Unique Constraint Conflict" {
    var index = UserIndex.init(testing.allocator);
    defer index.deinit();

    try index.insert(.{ .id = 1, .name = "Alice", .score = 100, .age = 30 });
    try index.insert(.{ .id = 2, .name = "Bob", .score = 80, .age = 25 });

    // Try to update Bob's id to 1 (conflict)
    const it = index.find_it(.id, 2);
    if (index.update(it, .{ .id = 1, .name = "Bob", .score = 80, .age = 25 })) |_| {
        return error.ShouldHaveFailed;
    } else |err| {
        try testing.expectEqual(error.Duplicate, err);
    }

    // Verify Bob is unchanged
    if (index.find(.id, 2)) |u| {
        try testing.expectEqualStrings("Bob", u.name);
    } else return error.BobDisappeared;
}

test "Stress Test: Many Insertions and Deletions" {
    var index = UserIndex.init(testing.allocator);
    defer index.deinit();

    const N = 1000;

    const name = try testing.allocator.alloc(u8, N);
    defer testing.allocator.free(name);

    // Insert N items
    for (0..N) |i| {
        const id: u32 = @intCast(i);
        try index.insert(.{
            .id = id,
            .name = name[i..],
            .score = id % 100,
            .age = @intCast(id % 256),
        });
    }
    try testing.expectEqual(@as(usize, N), index.count());

    // Delete every other item
    for (0..N / 2) |i| {
        const id: u32 = @intCast(i * 2);
        const it = index.find_it(.id, id);
        if (it.peek() != null) {
            index.erase_it(it);
        }
    }
    try testing.expectEqual(@as(usize, N / 2), index.count());

    // Verify remaining items are odd IDs
    for (0..N / 2) |i| {
        const id: u32 = @intCast(i * 2 + 1);
        try testing.expect(index.find(.id, id) != null);
    }
}

test "Hash Table Non-Unique: Multiple Items Same Key" {
    // Test non-unique hash table (age field)
    var index = UserIndex.init(testing.allocator);
    defer index.deinit();

    // Insert multiple users with same age
    try index.insert(.{ .id = 1, .name = "A", .score = 10, .age = 25 });
    try index.insert(.{ .id = 2, .name = "B", .score = 20, .age = 25 });
    try index.insert(.{ .id = 3, .name = "C", .score = 30, .age = 25 });

    try testing.expectEqual(@as(usize, 3), index.count());

    // Find should return one of them
    if (index.find(.age, 25)) |u| {
        try testing.expectEqual(@as(u8, 25), u.age);
    } else return error.NotFound;
}
