`default_nettype none

// Generic CPU-side serial register. Real-time regions use the independent
// TX/RX shifters in action_lane; this block serves scalar VM instructions.
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

  always @(posedge clk) begin
    if (!rst_n || !enable || clear)
      data <= 16'b0;
    else if (load)
      data <= {8'b0, load_data};
    else if (shift)
      data <= {serial_in, data[15:1]};
  end
endmodule

`default_nettype wire
