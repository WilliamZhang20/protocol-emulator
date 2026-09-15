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
  reg [15:0] shift_register;
  reg [4:0] bits_remaining;

  assign serial_out = shift_right ? shift_register[0] : shift_register[15];
  assign parallel_out = shift_register;
  assign done = bits_remaining == 5'b0;

  always @(posedge clk) begin
    if (!rst_n) begin
      shift_register <= 16'b0;
      bits_remaining <= 5'b0;
    end else if (load) begin
      shift_register <= parallel_in;
      bits_remaining <= bit_count;
    end else if (shift_enable && bits_remaining != 5'b0) begin
      if (shift_right)
        shift_register <= {serial_in, shift_register[15:1]};
      else
        shift_register <= {shift_register[14:0], serial_in};
      bits_remaining <= bits_remaining - 1'b1;
    end
  end
endmodule

`default_nettype wire
