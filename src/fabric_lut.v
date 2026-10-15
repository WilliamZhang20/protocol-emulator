`default_nettype none

// Spatial fabric glue cell: a 4-input lookup table with an optional
// flip-flop. It supplies the per-bit logic the coarse tiles do not
// (NRZI, Manchester, stuffing gates, inversions, line-state decoding).
//
// Registers (16-bit, written by the controller):
//   0 truth table, indexed by {in3, in2, in1, in0}
//   1 [5:0] in0 line  [11:6] in1 line
//   2 [5:0] in2 line  [11:6] in3 line
//   3 [5:0] enable line  [6] registered
//
// Combinational cells output f directly; registered cells output q, which
// loads f on cycles where the enable line is high. Loop freedom and a
// two-cell depth bound are structural: the core gives rank-1 cells the live
// output of rank-0 cells and every other glue view as its registered value.
module fabric_lut (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [1:0]  cfg_addr,
    input  wire [15:0] cfg_data,
    input  wire [63:0] lines,
    output wire        out,
    output wire        q
);
  reg [15:0] truth;
  reg [11:0] sel_lo;
  reg [11:0] sel_hi;
  reg [6:0]  mode;
  reg        q_r;

  wire [3:0] index = {lines[sel_hi[11:6]], lines[sel_hi[5:0]],
                      lines[sel_lo[11:6]], lines[sel_lo[5:0]]};
  wire f = truth[index];

  assign q   = q_r;
  assign out = mode[6] ? q_r : f;

  always @(posedge clk) begin
    if (!rst_n) begin
      truth  <= 16'd0;
      sel_lo <= 12'd0;
      sel_hi <= 12'd0;
      mode   <= 7'd0;
    end else if (cfg_we) begin
      case (cfg_addr)
        2'd0: truth  <= cfg_data;
        2'd1: sel_lo <= cfg_data[11:0];
        2'd2: sel_hi <= cfg_data[11:0];
        default: mode <= cfg_data[6:0];
      endcase
    end
  end

  always @(posedge clk) begin
    if (!rst_n || !enable)
      q_r <= 1'b0;
    else if (lines[mode[5:0]])
      q_r <= f;
  end
endmodule

`default_nettype wire
