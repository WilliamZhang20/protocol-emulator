`default_nettype none

// One configuration register with two contexts. A controller write goes to
// the contexts selected by `write_bank` ([0] context 0, [1] context 1).
// `ctx_next` names the context active from the next cycle.
//
// The two contexts are held as `active` (the one in use, read by the tile
// straight from a register, so the context select stays off its timing
// paths) and `shadow` (the other one). A switch swaps them. `cur` records
// which context `active` holds, so writes reach the right copy. Tiles that
// precompute from their configuration also get `next`, the value of the
// next cycle.
module config_bank #(
    parameter WIDTH = 16
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             we,
    input  wire [1:0]       write_bank,
    input  wire [WIDTH-1:0] data,
    input  wire             ctx_next,
    output wire [WIDTH-1:0] value,
    output wire [WIDTH-1:0] next
);
  reg [WIDTH-1:0] active, shadow;
  reg             cur;
  wire swap = ctx_next != cur;
  wire we_active = we && write_bank[cur];
  wire we_shadow = we && write_bank[!cur];
  wire [WIDTH-1:0] active_w = we_active ? data : active;
  wire [WIDTH-1:0] shadow_w = we_shadow ? data : shadow;
  assign next = swap ? shadow_w : active_w;

  always @(posedge clk) begin
    if (!rst_n) begin
      active <= {WIDTH{1'b0}};
      shadow <= {WIDTH{1'b0}};
      cur    <= 1'b0;
    end else begin
      active <= next;
      shadow <= swap ? active_w : shadow_w;
      cur    <= ctx_next;
    end
  end

  assign value = active;
endmodule

`default_nettype wire
