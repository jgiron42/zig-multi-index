const std = @import("std");

pub fn BoundedIterator(Iterator: type) type {
    return struct {
        lower_bound: ?Iterator = null,
        upper_bound: ?Iterator = null,
        iterator: Iterator,

        pub const ValueType = Iterator.ValueType;
        pub const Base = if (@hasDecl(Iterator, "Base")) Iterator.Base else Iterator;

        const Self = @This();

        pub fn init(v: Base) Self {
            return .{
                .iterator = if (Base == Iterator) v else Iterator.init(v),
            };
        }

        // pub fn advance(self: *Self, n : isize) void {
        //
        // }

        pub fn next(self: *Self) ?ValueType {
            if (self.upper_bound != null and self.iterator.eql(self.upper_bound.?))
                return null;
            return self.iterator.next();
        }

        pub fn prev(self: *Self) ?ValueType {
            if (self.lower_bound != null and self.iterator.eql(self.lower_bound.?))
                return null;
            return self.iterator.prev();
        }

        pub fn eql(self: Self, other: Self) bool {
            return (self.lower_bound != null and other.lower_bound != null and self.lower_bound.eql(other.lower_bound)) and
                (self.upper_bound != null and other.upper_bound != null and self.upper_bound.eql(other.upper_bound)) and
                self.iterator.eql(other.iterator);
        }

        pub fn peek(self: Self) ?ValueType {
            if (self.upper_bound != null and self.iterator.eql(self.upper_bound.?))
                return null;
            return self.iterator.peek();
        }

        pub fn is_valid(self: Self) bool {
            return self.iterator.is_valid() and (self.upper_bound == null or !self.iterator.eql(self.upper_bound.?));
        }

        pub fn base(self: Self) Base {
            return if (@hasDecl(Iterator, "base")) self.iterator.base() else self.iterator;
        }
    };
}
