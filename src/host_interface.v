`default_nettype none

// Adapts the external host pins to internal control channels.
// Loads program SRAM and exchanges TX and RX bytes.
// Exposes engine status without affecting protocol timing.
module host_interface (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] host_in,
    output wire [7:0] host_out,
    output wire       engine_enable,
    output wire       program_enable,
    output wire       program_write,
    output wire       program_read,
    output wire [9:0] program_address,
    output wire [7:0] program_write_data,
    output wire [7:0] program_write_mask,
    input  wire [7:0] program_read_data,
    output wire       tx_push,
    output wire [7:0] tx_push_data,
    input  wire       tx_full,
    output wire       rx_pop,
    input  wire [7:0] rx_pop_data,
    input  wire       rx_empty,
    input  wire       engine_halted
);
endmodule

`default_nettype wire
