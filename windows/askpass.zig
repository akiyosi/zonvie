const std = @import("std");

const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

/// Simple askpass helper for SSH_ASKPASS
/// Reads password from ZONVIE_SSH_PASSWORD environment variable and writes to stdout
pub fn main() void {
    // Get password from environment variable
    const password = std.process.getEnvVarOwned(std.heap.page_allocator, "ZONVIE_SSH_PASSWORD") catch {
        // No password set, just exit
        return;
    };
    defer std.heap.page_allocator.free(password);

    // Write password to stdout using Windows API
    const stdout_handle = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    if (stdout_handle == c.INVALID_HANDLE_VALUE) return;

    // Write password
    var written: c.DWORD = 0;
    _ = c.WriteFile(stdout_handle, password.ptr, @intCast(password.len), &written, null);

    // Write newline
    _ = c.WriteFile(stdout_handle, "\n", 1, &written, null);
}
