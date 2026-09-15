`default_nettype none

// Implements exact-cycle waits and general counting.
// Loads a duration supplied by the execution core.
// Reports expiration for deterministic instruction flow.
module timer_counter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load,
    input  wire        count_enable,
    input  wire [15:0] load_value,
    output wire [15:0] count_value,
    output wire        expired
);
  reg [15:0] count;

  assign count_value = count;
  assign expired = count == 16'b0;

  always @(posedge clk) begin
    if (!rst_n)
      count <= 16'b0;
    else if (load)
      count <= load_value;
    else if (count_enable && count != 16'b0)
      count <= count - 1'b1;
  end
endmodule

`default_nettype wire
