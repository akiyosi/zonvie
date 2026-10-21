const std = @import("std");
const clock = @import("zonvie_core").clock;

pub fn main(init: std.process.Init.Minimal) u8 {
    _ = init;
    clock.init();
    return 0;
}
