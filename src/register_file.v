`default_nettype none

// Stores the engine's working values (8x16, additive growth from 4x16).
// Supplies two read operands and one write port.
// Holds protocol state without dedicated controllers.
module register_file (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  read_address_a,
    input  wire [2:0]  read_address_b,
    output wire [15:0] read_data_a,
    output wire [15:0] read_data_b,
    input  wire        write_enable,
    input  wire [2:0]  write_address,
    input  wire [15:0] write_data
);
  reg [15:0] registers [0:7];
  integer index;

  assign read_data_a = registers[read_address_a];
  assign read_data_b = registers[read_address_b];

  always @(posedge clk) begin
    if (!rst_n) begin
      for (index = 0; index < 8; index = index + 1)
        registers[index] <= 16'b0;
    end else if (write_enable) begin
      registers[write_address] <= write_data;
    end
  end
endmodule

`default_nettype wire
