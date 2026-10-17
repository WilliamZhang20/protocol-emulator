`default_nettype none

// One configuration register with two contexts. A controller write goes to
// the banks selected by `write_bank` ([0] context 0, [1] context 1); the
// tile sees the value of the active context `ctx`. Tiles that
// precompute from their configuration also get `next`, the value that
// will be active in the next cycle.
module config_bank #(
    parameter WIDTH = 16
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             we,
    input  wire [1:0]       write_bank,
    input  wire [WIDTH-1:0] data,
    input  wire             ctx,
    input  wire             ctx_next,
    output wire [WIDTH-1:0] value,
    output wire [WIDTH-1:0] next
);
  reg [WIDTH-1:0] bank0, bank1;
  wire [WIDTH-1:0] bank0_next = (we && write_bank[0]) ? data : bank0;
  wire [WIDTH-1:0] bank1_next = (we && write_bank[1]) ? data : bank1;

  always @(posedge clk) begin
    if (!rst_n) begin
      bank0 <= {WIDTH{1'b0}};
      bank1 <= {WIDTH{1'b0}};
    end else begin
      bank0 <= bank0_next;
      bank1 <= bank1_next;
    end
  end

  assign value = ctx ? bank1 : bank0;
  assign next  = ctx_next ? bank1_next : bank0_next;
endmodule

`default_nettype wire
