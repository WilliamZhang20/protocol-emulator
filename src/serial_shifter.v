`default_nettype none

// CPU serial register for the 40/5p/6p/70/A0 instructions: load a TX byte,
// shift LSB first through data[0] (out) and data[15] (in), push data[15:8].
// Action lanes have their own shifters.
module serial_shifter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        clear,
    input  wire        load,
    input  wire [7:0]  load_data,
    input  wire        shift,
    input  wire        serial_in,
    output wire        serial_out,
    output wire [15:0] parallel
);
  reg [15:0] data;

  assign serial_out = data[0];
  assign parallel = data;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      data <= 16'b0;
    else if (!enable || clear)
      data <= 16'b0;
    else if (load)
      data <= {8'b0, load_data};
    else if (shift)
      data <= {serial_in, data[15:1]};
  end
endmodule

`default_nettype wire
