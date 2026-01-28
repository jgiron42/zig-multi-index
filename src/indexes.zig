// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joachim Giron
const std = @import("std");
const TypeConfig = @import("config.zig").TypeConfig;

pub const IndexEnum = enum {
    AVL,
    HashTable,
    pub fn get(self: @This()) type {
        return switch (self) {
            .AVL => @import("indexes/avl.zig"),
            .HashTable => @import("indexes/hash_table.zig"),
        };
    }
    pub fn from_type_config(T: type, config: TypeConfig(T)) IndexEnum {
        return if (config.ordered) .AVL else .HashTable;
    }
};
