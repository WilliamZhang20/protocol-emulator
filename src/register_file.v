`default_nettype none

// Stores the engine's small set of working values.
// Supplies two read operands and one write port.
// Holds protocol state without dedicated controllers.
module register_file (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  read_address_a,
    input  wire [1:0]  read_address_b,
    output wire [15:0] read_data_a,
    output wire [15:0] read_data_b,
    input  wire        write_enable,
    input  wire [1:0]  write_address,
    input  wire [15:0] write_data
);
endmodule

`default_nettype wire
