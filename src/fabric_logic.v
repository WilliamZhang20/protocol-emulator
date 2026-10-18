`default_nettype none

// Spatial fabric logic cell: a 4-input lookup table and a flip-flop. It
// supplies the per-bit logic the coarse tiles do not (NRZI, Manchester,
// stuffing gates, inversions, line-state decoding).
//
// Registers (16-bit, written by the controller):
//   0 truth table, indexed by {in3, in2, in1, in0}
//   1 [5:0] in0 line   [11:6] in1 line   (any of the 64 lines)
//   2 [4:0] in2 level  [9:5] in3 level   (signal space 32-63)
//   3 [4:0] enable pulse line (signal space 0-31)  [5] start value
//
// The output is the register q, which loads f on cycles where the enable
// line is high (the constant 1 line: every cycle, so q is f one cycle
// late). While the fabric is stopped q holds its start value, so an
// inverted output (a chip select) is already high when the fabric starts. Every signal-space line is a
// register output, so any path is one hop: register, line, selector, tile
// logic, register, whatever the configuration.
module fabric_logic (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [1:0]  cfg_addr,
    input  wire [15:0] cfg_data,
    input  wire [1:0]  cfg_bank,      // contexts a write goes to
    input  wire        ctx_next,  // context active from the next cycle
    input  wire [63:0] lines,
    output wire        q
);
  wire [15:0] truth;
  wire [11:0] sel_lo;
  wire [9:0]  sel_hi;
  wire [5:0]  mode;
  reg        q_r;

  wire [31:0] levels = lines[63:32];
  wire [3:0] index = {levels[sel_hi[9:5]], levels[sel_hi[4:0]],
                      lines[sel_lo[11:6]], lines[sel_lo[5:0]]};
  wire f = truth[index];

  assign q = q_r;

  config_bank #(.WIDTH(16)) truth_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd0), .write_bank(cfg_bank), .data(cfg_data),
      .ctx_next(ctx_next), .value(truth), .next());
  config_bank #(.WIDTH(12)) sel_lo_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd1), .write_bank(cfg_bank), .data(cfg_data[11:0]),
      .ctx_next(ctx_next), .value(sel_lo), .next());
  config_bank #(.WIDTH(10)) sel_hi_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd2), .write_bank(cfg_bank), .data(cfg_data[9:0]),
      .ctx_next(ctx_next), .value(sel_hi), .next());
  config_bank #(.WIDTH(6)) mode_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd3), .write_bank(cfg_bank), .data(cfg_data[5:0]),
      .ctx_next(ctx_next), .value(mode), .next());

  always @(posedge clk) begin
    if (!rst_n)
      q_r <= 1'b0;
    else if (!enable)
      q_r <= mode[5];
    else if (lines[{1'b0, mode[4:0]}])
      q_r <= f;
  end
endmodule

`default_nettype wire
