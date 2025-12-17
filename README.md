# zig-multi-index

A **zero-copy, compile-time multi-index data structure** for Zig that enables querying a single collection through multiple independent indexes simultaneously, with automatic index selection and synchronization.

## Quick Demo

```zig
const MultiIndex = @import("multi-index").MultiIndex;

const Person = struct {
    name: []const u8,
    age: u8,
    email: []const u8,  // Not indexed; can still be stored
};

var people = MultiIndex(Person, .{
    .name = .{ 
        .unique = true,
        .ordered = false,  // Unordered index (hash table)
    },
    .age = .{},  // Ordered index (AVL tree, multiset allowed)
}).init(allocator);
defer people.deinit();

// Insert
try people.insert(.{ .name = "Alice", .age = 30, .email = "alice@example.com" });
try people.insert(.{ .name = "Bob", .age = 25, .email = "bob@example.com" });

// O(1) amortized lookup by name
if (people.find(.name, "Alice")) |person| {
    std.debug.print("{s} is {}\n", .{ person.name, person.age });
}

// O(log n) range queries by age
var range = people.range(.age, 25, 30);
while (range.next()) |person| {
    std.debug.print("- {s} ({})\n", .{ person.name, person.age });
}

// Cannot lookup by email (not indexed)
// people.find(.email, "alice@example.com")  // Compile error!

// Automatic re-indexing on update
try people.update(iterator, .{ .name = "Alicia", .age = 31, .email = "alicia@example.com" });
```

## Overview

**zig-multi-index** is a generic data structure that maintains a single collection of values indexed through multiple independent **index backends** (e.g. AVL trees, hash tables...). Each index is a separate data structure that references the same underlying collection, enabling O(log n) or O(1) lookups across any indexed field without duplicating the actual data.

Key characteristics:

- **Type-safe, field-based indexing**: Indexes are selected using tagged field names (`.name`, `.age`)
- **Automatic index selection**: The library chooses the best data structure based on your config (currently AVL or hash-table)
- **Zero-copy**: All indexes reference the same underlying node; no data duplication
- **Flexible**: Index only the fields you need; store any data you want
- **Atomic updates**: Changes to one index are atomic across all indexes via two-phase insert/update protocol

## How It Works

### Architecture

zig-multi-index maintains three layers:

1. **Node Structure** (Runtime): A wrapper containing the actual value and **headers** for each index
2. **Indexes** (Runtime): Multiple independent data structures (AVL or hash table), each maintaining a view into the nodes
3. **MultiIndex Wrapper** (Compile-time generated): A type-safe API that coordinates all indexes

```
MultiIndex<Person> (type-safe API)
    ├─ Index[.name] (Hash Table) → Person.name nodes (O(1) lookup)
    └─ Index[.age] (AVL Tree)    → Person.age nodes (O(log n) + range queries)

All indexes contain pointers to the SAME underlying Node<Person> instances
```

### Intrusive Data Structures

The key insight is using **intrusive node headers**: instead of storing separate copies of data, each index holds a header (node pointer) that is **embedded inside** the actual node. This allows:

- **Zero duplication**: One copy of each value lives in memory
- **Structural synchronization**: Removing a node automatically removes it from all indexes
- **Cache efficiency**: All indexes traverse the same node pointers

```zig
const Node = struct {
    headers: struct {
        name: hash_table.Node,  // embedded header for name index (hash table)
        age: avl.Node,          // embedded header for age index (AVL tree)
    },
    value: Person,              // the actual data (single copy)
};
```

Note: The header field names match the indexed field names for clarity. Each header type depends on the configuration.

### Dual-Phase Insert/Update

To maintain consistency across indexes, operations use a **prepare-finish pattern**:

**Insert**:
1. **Prepare Phase**: Each index validates constraints (uniqueness) and reserves a position (hint)
2. **Finish Phase**: Each index commits the node using the reserved hint

If any index fails validation, the entire operation fails before any index is modified, preserving atomicity.

```zig
// Step 1: Prepare all indexes
var hints: Hints = undefined;
inline for (indexes) |index| {
    hints[i] = try index.prepare_insert(node);  // May fail on duplicate
}

// Step 2: All or nothing commit
inline for (indexes) |index| {
    index.finish_insert(hints[i], node);  // Guaranteed to succeed
}
```

**Update**:
1. **Prepare**: Check if reordering/rehashing is needed in each index and validate constraints
2. **Commit**: Remove from old position, insert at new position (if needed)

If an index doesn't need reordering, it's skipped.

### Compile-Time Configuration

The `Config` type describes which fields get indexed and how:

```zig
MultiIndex(T, .{
    .field_name = .{
        .unique = true,           // Enforce uniqueness (default: false)
        .ordered = true,          // Choose an ordered data structure (default: true)
        // for AVL
        .compare_fn = custom_cmp,  // Custom comparator (default: std.math.order)

        // for HashTable
        .hash_context = context,   // Custom hash context for unordered indexes

        .custom = CustomIndexType, // Use custom index backend
    },
    // ... only indexed fields go here
})
```

At compile-time, Zig's comptime evaluation:
1. Analyzes the config struct
2. Generates unique index types for each field
3. Creates a unified `Indexes` struct containing all backends
4. Generates `Node.Headers` struct with embedded headers
5. Produces an API that references fields by **comptime field enums**

### Why It's Efficient

**Comptime**:
- No runtime polymorphism or virtual dispatch
- All type relationships known at compile-time
- Inlining opportunities throughout

**Structural Guarantees**:
- Intrusive headers mean no extra allocations
- Update hints allow skipping unnecessary rebalancing

**Index Backends**:
- **AVL Trees** (ordered, O(log n) insert/lookup, self-balancing)
- **Hash Tables** (unordered, O(1) amortized insert/lookup)
- Selection is compile-time based on the config struct

## API Overview

### Basic Operations

```zig
pub fn insert(self: *Self, value: T) !void
pub fn update(self: *Self, it: Iterator, value: T) !T
pub fn erase_it(self: *Self, it: Iterator) void
pub fn count(self: Self) usize
pub fn reset(self: *Self) void
pub fn deinit(self: *Self) void
```

### Lookups

```zig
// Exact match on any indexed field
pub fn find(self: Self, comptime field: Field, v: KeyType) ?T
pub fn find_it(self: Self, comptime field: Field, v: KeyType) Iterator

// Range queries (ordered indexes only)
pub fn lower_bound(self: Self, comptime field: Field, v: KeyType) Iterator
pub fn upper_bound(self: Self, comptime field: Field, v: KeyType) Iterator
pub fn range(self: Self, field: Field, v1: KeyType, v2: KeyType) Range
pub fn equal_range(self: Self, field: Field, v: KeyType) Range
```

### Iteration

```zig
var range = people.range(.age, 25, 30);
while (range.next()) |person| {
    // person is of type T
}
```

### Advanced

```zig
// Change axe of iteration
iterator.switch_field(.new_field)

// Bulk erase by range
map.erase_range(map.range(.field, low, high))
```

## Strengths & Design Philosophy

### Zero Runtime Overhead
No runtime decision-making about which index to use. The compiler generates **monomorphic code** with no indirection. An `insert` call directly inlines into the specific AVL and hash table implementations being used.

### Type-Safe at Compile-Time
Field names are **not strings**—they're comptime field enums generated from your struct. Attempting to index a non-indexed field is a compile-error:

```zig
people.find(.email, "...")  // Error: email is not indexed
```

### True Zero-Copy Design
Stores **one copy** of each value with embedded headers. The indexes are just different tree structures pointing at the same nodes. This is similar to C++ Boost.MultiIndex's intrusive approach, but enforced by Zig's type system.

### Flexible Index Selection
Specify `ordered: true/false` and the library picks the optimal backend at compile-time. Mix different index types for different fields:

```zig
MultiIndex(Person, .{
    .id = .{ .unique = true, .ordered = false },     // Hash table (O(1) lookup)
    .age = .{ .unique = false, .ordered = true },    // AVL (O(log n) + ranges)
})
```

### Atomic Multi-Index Updates
Updates that span multiple indexes use a prepare-finish protocol, ensuring **all-or-nothing semantics**. If reindexing fails on any index, the entire operation is rolled back.

## Current Index Backends

zig-multi-index currently provides two backends:

| Backend        | Ordered | Lookup   | Insert   | Remove   | Use Case                        |
| -------------- | ------- | -------- | -------- | -------- | ------------------------------- |
| **AVL Tree**   | ✅ Yes   | O(log n) | O(log n) | O(log n) | Range queries, sorted iteration |
| **Hash Table** | ❌ No    | O(1) avg | O(1) avg | O(1) avg | Fast exact-match lookups        |

## Future Index Backends

The architecture is designed to support additional backends. Planned additions:

- **Red-Black trees, scape goat trees...** Similar to an AVL but with slightly different performance.
- **Skip Lists**: Ordered access but simpler to implement and better cache locality for sequential scans
- **B-Trees**: Better I/O performance for disk-backed or large-scale indexes

Example (future):
```zig
MultiIndex(Person, .{
    .timestamp = .{ .custom = SkipList },  // Custom backend
    .score = .{ .ordered = true },         // AVL
    .uid = .{ .ordered = false },          // Hash table
})
```

## When to Use

**zig-multi-index is ideal for:**
- Databases/indexes with multiple query paths (uid, name, timestamp, etc.)
- Cache managers needing LRU + lookup-by-key
- Routing tables with prefix + length ordering
- Event queues indexed by priority and deadline
- Any scenario where one collection needs 2+ independent access patterns

**Consider alternatives if:**
- You only have a single query pattern (use a single index)
- Your indexes don't need to stay in sync (use separate data structures)
- You need complex queries beyond exact match and range (full database)

## Advanced Index Concepts (Future)

Beyond simple key-value indexes, the architecture is extensible to other data structures:

- **Priority Queue Index**: Use a field as a priority key in a priority queue, enabling efficient `pop_min()` or `pop_max()` across the entire dataset
- **Full-Text Search Index**: Index string fields for keyword matching

These would be accessed similarly:
```zig
// Future: priority queue index on deadline field
var urgent = events.pop_min(.deadline);

// Future: full-text search index
var results = docs.search(.content, "keyword");
```

## Building & Running

```bash
zig build
zig build run-example  # Run the example.zig demo
```

---

**Author**: Joachim Giron