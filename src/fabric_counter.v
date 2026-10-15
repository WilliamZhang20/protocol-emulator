`default_nettype none

// Spatial fabric counter tile: a saturating 8-bit counter stepped by a line.
// Modes give event counting and run-length measurement (bit stuffing for
// USB/CAN, framing counts, preamble skipping).
//
// Registers (written by the controller):
//   0 match  [7:0] threshold
//   1 step   [5:0] step line  [11:6] data line
//            [13:12] mode: 0 count steps, 1 run of ones (data 0 clears),
//                          2 run of zeros (data 1 clears),
//                          3 run of equal bits (a change restarts at 1)
//   2 clear  [5:0] clear line (priority over step)
//
// `ge` is the level count >= threshold; `hit` pulses on the step that
// first reaches it.
module fabric_counter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        cfg_we,
    input  wire [1:0]  cfg_addr,
    input  wire [13:0] cfg_data,
    input  wire [63:0] lines,
    output wire        ge,
    output wire        hit,
    output wire [7:0]  count
);
  reg [7:0]  match;
  reg [13:0] step;
  reg [5:0]  clear;
  reg [7:0]  value;
  reg        last;

  wire step_now  = lines[step[5:0]];
  wire data      = lines[step[11:6]];
  wire clear_now = lines[clear];
  wire [7:0] inc = value == 8'hff ? value : value + 8'd1;

  reg [7:0] next;
  always @(*) begin
    case (step[13:12])
      2'd0: next = inc;
      2'd1: next = data ? inc : 8'd0;
      2'd2: next = data ? 8'd0 : inc;
      default: next = data == last ? inc : 8'd1;
    endcase
  end

  assign ge    = value >= match;
  assign hit   = enable && !clear_now && step_now && !ge && next >= match;
  assign count = value;

  always @(posedge clk) begin
    if (!rst_n) begin
      match <= 8'd0;
      step  <= 14'd0;
      clear <= 6'd0;
    end else if (cfg_we) begin
      case (cfg_addr)
        2'd0: match <= cfg_data[7:0];
        2'd1: step  <= cfg_data;
        2'd2: clear <= cfg_data[5:0];
        default: begin end
      endcase
    end
  end

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
