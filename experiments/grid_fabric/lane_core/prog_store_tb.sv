`timescale 1ns/1ps
// The lane controller's program store: the behavioural model the proof
// uses (USE_MACRO 0) against the IHP vendor model of the on-chip macro
// (USE_MACRO 1, test/models, FUNCTIONAL). Every address is written first
// (contents and DOUT are not reset); then random reads, writes, idle clocks
// and disabled clocks. DOUT must agree every clock, including that a write
// and an idle clock hold it.
module prog_store_tb;
  reg clk = 0;
  always #5 clk = ~clk;
  reg men = 0, wen = 0, ren = 0;
  reg [5:0] addr = 0;
  reg [15:0] din = 0;
  wire [15:0] model_dout, macro_dout;
  lane_prog_store #(.ABITS(6), .USE_MACRO(0)) model(clk, men, wen, ren, addr, din, model_dout);
  lane_prog_store #(.ABITS(6), .USE_MACRO(1)) macro(clk, men, wen, ren, addr, din, macro_dout);
  integer i, reads = 0, holds = 0, writes = 0, seed = 7;
  reg read_seen = 0;
  initial begin
    for (i = 0; i < 64; i = i + 1) begin
      @(negedge clk); men = 1; wen = 1; ren = 0; addr = i[5:0]; din = $random(seed);
    end
    for (i = 0; i < 20000; i = i + 1) begin
      @(negedge clk);
      if (read_seen && model_dout !== macro_dout) begin
        $display("FAIL cycle %0d: model %h macro %h", i, model_dout, macro_dout); $fatal(1);
      end
      case ($unsigned($random(seed)) % 4)
        0: begin men = 1; wen = 1; ren = 0; writes = writes + 1; end
        1, 2: begin men = 1; wen = 0; ren = 1; reads = reads + 1; read_seen = 1; end
        default: begin men = $random(seed); wen = 0; ren = 0; holds = holds + 1; end  // disabled, or enabled without a read: DOUT holds
      endcase
      addr = $random(seed); din = $random(seed);
    end
    $display("PASS: program store model matches the IHP 64x16 macro model over %0d reads, %0d writes, %0d held clocks",
             reads, writes, holds);
    $finish;
  end
endmodule
