const std = @import("std");
const posix = std.posix;

fn run(machine_code: []const u8) !i64 {
    // Allocate a piece of executable memory of size `machine_code.len`.
    const machine_code_executable = try std.posix.mmap(
        null,
        machine_code.len,
        posix.PROT.READ | posix.PROT.WRITE | posix.PROT.EXEC,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(machine_code_executable);

    // Copy the bytes of `machine_code` into `machine_code_executable`
    @memcpy(machine_code_executable, machine_code);

    // The `machine_code_executable` pointer is actually
    // a function that returns an integer (`fn() -> i64`)
    const f: *const fn () callconv(.C) i64 = @ptrCast(machine_code_executable);
    const result = f();

    return result;
}

fn jit(allocator: std.mem.Allocator, program: []const u8) !std.ArrayList(u8) {
    // Set the `rax` register to 0 before doing anything else.
    var machine_code = std.ArrayList(u8).init(allocator);
    try machine_code.appendSlice(&[_]u8{
        0x48, 0xC7, 0xC0, 0x00, 0x00, 0x00, 0x00, // mov rax, 0
    });

    for (program) |token| {
        switch (token) {
            '+' => try machine_code.appendSlice(&[_]u8{
                0x48, 0x83, 0xC0, 0x01, // add rax, 1
            }),
            '-' => try machine_code.appendSlice(&[_]u8{
                0x48, 0x83, 0xE8, 0x01, // sub rax, 1
            }),
            '*' => try machine_code.appendSlice(&[_]u8{
                0x48, 0xC1, 0xE0, 0x01, // shl rax, 1 (multiply by 2)
            }),
            '/' => try machine_code.appendSlice(&[_]u8{
                0x48, 0xC7, 0xC1, 0x02, 0x00, 0x00, 0x00, // mov rcx, 2
                0x48, 0x99, // cqo (sign-extends rax into rdx:rax)
                0x48, 0xF7, 0xF9, // idiv rcx
            }),
            else => {}, // ignore everything else
        }
    }

    try machine_code.append(0xc3); // ret

    return machine_code;
}

test "run_works" {
    const machine_code = &[_]u8{ 0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3 };
    try std.testing.expectEqual(@as(i64, 42), try run(machine_code));
}

test "jit_plus" {
    const code = try jit(std.testing.allocator, "+");
    defer code.deinit();
    try std.testing.expectEqual(@as(i64, 1), try run(code.items));
}

test "jit_sub" {
    const code = try jit(std.testing.allocator, "-");
    defer code.deinit();
    try std.testing.expectEqual(@as(i64, -1), try run(code.items));
}

test "jit_mul" {
    const code = try jit(std.testing.allocator, "+*");
    defer code.deinit();
    try std.testing.expectEqual(@as(i64, 2), try run(code.items));
}

test "jit_div" {
    const code = try jit(std.testing.allocator, "++/");
    defer code.deinit();
    try std.testing.expectEqual(@as(i64, 1), try run(code.items));
}

test "jit_multiple_instructions" {
    const code = try jit(std.testing.allocator, "+++***+++***+++--/**////*****---*+*");
    defer code.deinit();
    try std.testing.expectEqual(@as(i64, 3446), try run(code.items));
}

// repl
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    try stdout.print("JIT Calculator REPL\n", .{});
    try stdout.print("Commands: + (add 1), - (sub 1), * (mul by 2), / (div by 2)\n", .{});
    try stdout.print("Type 'Ctrl-D' to exit\n\n", .{});

    while (true) {
        try stdout.print("> ", .{});

        var buffer: [256]u8 = undefined;
        const input = stdin.readUntilDelimiterOrEof(buffer[0..], '\n') catch |err| {
            try stdout.print("Error reading input: {}\n", .{err});
            continue;
        };

        if (input) |src| {
            // JIT compile and run the program
            var code = jit(allocator, src) catch |err| {
                try stdout.print("Error compiling: {}\n", .{err});
                continue;
            };
            defer code.deinit();

            const result = run(code.items) catch |err| {
                try stdout.print("Error executing: {}\n", .{err});
                continue;
            };

            try stdout.print("{}\n", .{result});
        } else {
            // EOF reached
            try stdout.print("\nGoodbye!\n", .{});
            break;
        }
    }
}
