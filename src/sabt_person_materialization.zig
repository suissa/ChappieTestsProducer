const std = @import("std");

pub const Field = enum { name, age, email, phone, cpf, address };
pub const Kind = enum { string, integer, float, boolean };

pub const Value = union(Kind) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

/// SABT is the transport envelope. Its field metadata is checked only after
/// the envelope is received; the public preparation API remains generic.
pub const SABT = struct {
    field: Field,
    value: Value,
};

pub const Prepared = struct {
    field: Field,
    received_kind: Kind,
    value: Value,
    stage: Stage,
};

pub const Stage = enum { materialized, adapted, normalized, validated };
pub const Validation = enum { valid, invalid };

pub const PrepareError = error{
    UnsupportedPayloadType,
    WrongSABTField,
    IncompatibleValue,
    InvalidValue,
};

fn toValue(payload: anytype) PrepareError!Value {
    const T = @TypeOf(payload);
    if (T == Value) return payload;
    if (@typeInfo(T) == .bool) return .{ .boolean = payload };
    if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
        return .{ .integer = @intCast(payload) };
    }
    if (@typeInfo(T) == .float or @typeInfo(T) == .comptime_float) {
        return .{ .float = @floatCast(payload) };
    }
    if (@typeInfo(T) == .pointer) {
        const child = @typeInfo(T).pointer.child;
        if (child == u8) return .{ .string = payload };
        if (@typeInfo(child) == .array and @typeInfo(child).array.child == u8) {
            return .{ .string = payload[0..] };
        }
    }
    return PrepareError.UnsupportedPayloadType;
}

fn unwrap(payload: anytype, expected: Field) PrepareError!Value {
    const T = @TypeOf(payload);
    if (T == SABT) {
        if (payload.field != expected) return PrepareError.WrongSABTField;
        return payload.value;
    }
    return toValue(payload);
}

fn normalize(value: Value) Value {
    return switch (value) {
        .string => |text| .{ .string = std.mem.trim(u8, text, " \t\r\n") },
        .integer => value,
        .float => value,
        .boolean => value,
    };
}

fn adapt(value: Value, expected: Field) PrepareError!Value {
    if (expected == .age) {
        return switch (value) {
            .integer => value,
            .float => |number| if (@floor(number) == number)
                .{ .integer = @intFromFloat(number) }
            else
                PrepareError.IncompatibleValue,
            .string => |text| .{ .integer = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch return PrepareError.IncompatibleValue },
            else => PrepareError.IncompatibleValue,
        };
    }

    return switch (value) {
        .string => value,
        // Do not silently stringify integers for identifiers: leading zeros
        // and semantic identity cannot be recovered after numeric coercion.
        else => PrepareError.IncompatibleValue,
    };
}

/// Receive as anytype, unwrap SABT, materialize a concrete value, resolve its
/// received kind, adapt only along explicitly supported edges, normalize,
/// then validate the domain invariant.
pub fn prepare(payload: anytype, expected: Field) PrepareError!Prepared {
    const unwrapped = try unwrap(payload, expected);
    const received_kind = std.meta.activeTag(unwrapped);
    const materialized = unwrapped;
    const adapted = try adapt(materialized, expected);
    const canonical = normalize(adapted);
    return .{
        .field = expected,
        .received_kind = received_kind,
        .value = canonical,
        .stage = .normalized,
    };
}

pub fn validate(prepared: Prepared) Validation {
    return switch (prepared.field) {
        .name => switch (prepared.value) {
            .string => |s| if (s.len > 0) .valid else .invalid,
            else => .invalid,
        },
        .age => switch (prepared.value) {
            .integer => |n| if (n >= 0 and n <= 150) .valid else .invalid,
            else => .invalid,
        },
        .email => switch (prepared.value) {
            .string => |s| if (std.mem.indexOfScalar(u8, s, '@') != null and
                std.mem.indexOfScalar(u8, s, '.') != null) .valid else .invalid,
            else => .invalid,
        },
        .phone => switch (prepared.value) {
            .string => |s| if (s.len >= 8 and s.len <= 16) .valid else .invalid,
            else => .invalid,
        },
        .cpf => switch (prepared.value) {
            .string => |s| if (s.len == 11 and allDigits(s)) .valid else .invalid,
            else => .invalid,
        },
        .address => switch (prepared.value) {
            .string => |s| if (s.len > 0) .valid else .invalid,
            else => .invalid,
        },
    };
}

fn allDigits(text: []const u8) bool {
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

test "SABT Person.name unwraps and trims before validation" {
    const result = try prepare(SABT{ .field = .name, .value = .{ .string = " Ada " } }, .name);
    try std.testing.expectEqualStrings("Ada", result.value.string);
    try std.testing.expectEqual(Validation.valid, validate(result));
}

test "Person.age adapts numeric strings after unwrap" {
    const result = try prepare(SABT{ .field = .age, .value = .{ .string = " 42 " } }, .age);
    try std.testing.expectEqual(@as(i64, 42), result.value.integer);
    try std.testing.expectEqual(Validation.valid, validate(result));
}

test "Person.email accepts string representation then validates" {
    const result = try prepare(SABT{ .field = .email, .value = .{ .string = "ada@example.org" } }, .email);
    try std.testing.expectEqual(Validation.valid, validate(result));
}

test "Person.phone accepts string representation then validates" {
    const result = try prepare(SABT{ .field = .phone, .value = .{ .string = "+551199999999" } }, .phone);
    try std.testing.expectEqual(Validation.valid, validate(result));
}

test "Person.cpf preserves zero-padded identifiers as strings" {
    const result = try prepare(SABT{ .field = .cpf, .value = .{ .string = "04864713901" } }, .cpf);
    try std.testing.expectEqualStrings("04864713901", result.value.string);
    try std.testing.expectEqual(Validation.valid, validate(result));
}

test "Person.address materializes string representation then validates" {
    const result = try prepare(SABT{ .field = .address, .value = .{ .string = "Rua A, 10" } }, .address);
    try std.testing.expectEqual(Validation.valid, validate(result));
}

test "SABT field mismatch is detected after receiving envelope" {
    try std.testing.expectError(PrepareError.WrongSABTField, prepare(SABT{ .field = .name, .value = .{ .string = "Ada" } }, .age));
}

test "unsupported direct payload is rejected by materializer" {
    try std.testing.expectError(PrepareError.UnsupportedPayloadType, prepare(.{ .unsupported = @as(u8, 7) }, .name));
}
