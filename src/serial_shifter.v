`default_nettype none

// Shifts serial data into and out of a working word.
// Supports selectable direction and transfer length.
// Exposes completion to the instruction sequencer.
module serial_shifter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load,
    input  wire        shift_enable,
    input  wire        shift_right,
    input  wire        serial_in,
    input  wire [15:0] parallel_in,
    input  wire [4:0]  bit_count,
    output wire        serial_out,
    output wire [15:0] parallel_out,
    output wire        done
);
endmodule

`default_nettype wire
