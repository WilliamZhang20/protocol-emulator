`default_nettype none

// Buffers bytes between the host and protocol engine.
// Decouples host service latency from exact-cycle execution.
// Reports occupancy and flow-control status at both ends.
module byte_fifo #(
    parameter DEPTH = 4,
    parameter ADDRESS_WIDTH = 2
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   push,
    input  wire [7:0]             push_data,
    input  wire                   pop,
    output wire [7:0]             pop_data,
    output wire                   empty,
    output wire                   full,
    output wire [ADDRESS_WIDTH:0] level
);
endmodule

`default_nettype wire
