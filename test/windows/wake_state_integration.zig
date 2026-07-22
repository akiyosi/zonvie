const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
});

const wake_state_offset: c_int = 0;

fn testWndProc(
    hwnd: c.HWND,
    message: c.UINT,
    w_param: c.WPARAM,
    l_param: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    return c.DefWindowProcW(hwnd, message, w_param, l_param);
}

test "top-level HWND extra bytes round-trip wake cookie and durable marker" {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieWakeStateIntegrationTest");
    const instance = c.GetModuleHandleW(null);

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = testWndProc;
    wc.hInstance = instance;
    wc.cbWndExtra = @sizeOf(isize);
    wc.lpszClassName = class_name;
    try std.testing.expect(c.RegisterClassExW(&wc) != 0);
    defer _ = c.UnregisterClassW(class_name, instance);

    const hwnd = c.CreateWindowExW(
        0,
        class_name,
        class_name,
        c.WS_OVERLAPPED,
        0,
        0,
        64,
        64,
        null,
        null,
        instance,
        null,
    );
    try std.testing.expect(hwnd != null);
    defer _ = c.DestroyWindow(hwnd);

    // This must stay a parent-less top-level window: GWLP_ID is only valid
    // for child identifiers, while cbWndExtra offset zero is class-owned.
    try std.testing.expect(c.GetParent(hwnd) == null);
    const cookie: usize = 0x12345;
    c.SetLastError(0);
    const previous = c.SetWindowLongPtrW(hwnd, wake_state_offset, @bitCast(cookie << 1));
    try std.testing.expect(previous != 0 or c.GetLastError() == 0);
    try std.testing.expectEqual(cookie, @as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, wake_state_offset))) >> 1);

    const wake_state: usize = @bitCast(c.GetWindowLongPtrW(hwnd, wake_state_offset));
    _ = c.SetWindowLongPtrW(hwnd, wake_state_offset, @bitCast(wake_state | 1));
    const marked_state: usize = @bitCast(c.GetWindowLongPtrW(hwnd, wake_state_offset));
    try std.testing.expectEqual(cookie, marked_state >> 1);
    try std.testing.expectEqual(@as(usize, 1), marked_state & 1);
}
