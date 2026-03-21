// dialogs.zig — Native GTK dialogs for Linux frontend.
//
// TODO: Implement dialog types:
// - SSH password prompt (GtkPasswordEntry in GtkDialog)
// - Quit confirmation with unsaved buffers
// - File open/save dialogs (if needed)

const std = @import("std");
const app_mod = @import("../app.zig");

/// Show a password input dialog for SSH authentication.
/// Returns the entered password as a borrowed slice, or null if cancelled.
pub fn showPasswordDialog(prompt: []const u8) ?[]const u8 {
    _ = prompt;
    // TODO: create GtkDialog with GtkPasswordEntry
    // For now, return null (no password)
    return null;
}

/// Show a quit confirmation dialog when there are unsaved buffers.
/// Returns true if the user confirms quit.
pub fn showQuitConfirmation() bool {
    // TODO: create GtkMessageDialog
    return true;
}
