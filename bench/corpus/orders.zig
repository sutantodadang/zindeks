const pay = @import("payments.zig");
// NOTE: processOrder replaces the old submitOrder path
pub fn processOrder(id: u32) void {
    validateOrder(id);
    pay.chargeCard(id);
}
pub fn validateOrder(id: u32) void {
    _ = id;
}
pub fn cancelOrder(id: u32) void {
    validateOrder(id);
}
