`default_nettype none

// Spatial fabric counter tile: a saturating 8-bit counter stepped by a line.
// Modes give event counting and run-length measurement (bit stuffing for
// USB/CAN, framing counts, preamble skipping).
//
// Registers (written by the controller):
//   0 match  [7:0] threshold
//   1 step   [5:0] step line  [10:6] data level (signal space 32-63)
//            [12:11] mode: 0 count steps, 1 run of ones (data 0 clears),
//                          2 run of zeros (data 1 clears),
//                          3 run of equal bits (a change restarts at 1)
//   2 clear  [4:0] clear pulse line (signal space 0-31; priority over step)
//
// `ge` is the level count >= threshold; `hit` pulses on the step that
// first reaches it.
module fabric_counter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [1:0]  cfg_addr,
    input  wire [12:0] cfg_data,
    input  wire [1:0]  cfg_bank,      // contexts a write goes to
    input  wire        ctx_next,  // context active from the next cycle
    input  wire [63:0] lines,
    output wire        ge,
    output wire        hit,
    output wire [7:0]  count
);
  wire [7:0]  match;
  wire [12:0] step;
  wire [4:0]  clear;
  reg  [7:0]  value;
  reg        last;

  wire step_now  = lines[step[5:0]];
  wire data      = lines[{1'b1, step[10:6]}];
  wire clear_now = lines[{1'b0, clear}];
  wire [7:0] inc = value == 8'hff ? value : value + 8'd1;

  reg [7:0] next;
  always @(*) begin
    case (step[12:11])
      2'd0: next = inc;
      2'd1: next = data ? inc : 8'd0;
      2'd2: next = data ? 8'd0 : inc;
      default: next = data == last ? inc : 8'd1;
    endcase
  end

  assign ge    = value >= match;
  assign hit   = enable && !clear_now && step_now && !ge && next >= match;
  assign count = value;

  config_bank #(.WIDTH(8)) match_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd0), .write_bank(cfg_bank), .data(cfg_data[7:0]),
      .ctx_next(ctx_next), .value(match), .next());
  config_bank #(.WIDTH(13)) step_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd1), .write_bank(cfg_bank), .data(cfg_data),
      .ctx_next(ctx_next), .value(step), .next());
  config_bank #(.WIDTH(5)) clear_r (.clk(clk), .rst_n(rst_n),
      .we(cfg_we && cfg_addr == 2'd2), .write_bank(cfg_bank), .data(cfg_data[4:0]),
      .ctx_next(ctx_next), .value(clear), .next());

  always @(posedge clk) begin
    if (!rst_n || !enable) begin
      value <= 8'd0;
      last  <= 1'b0;
    end else if (clear_now) begin
      value <= 8'd0;
    end else if (step_now) begin
      value <= next;
      last  <= data;
    end
  end
endmodule

`default_nettype wire
