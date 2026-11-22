`timescale 1ns/1ps
`default_nettype none
module selector_tb;
  reg clk = 0;
  always #5 clk = ~clk;
  reg [63:0] sources = 0;
  reg [5:0] global_select = 0;
  reg [2:0] local_select = 0;
  reg [2:0] remote_select = 0;
  reg [3:0] flat_select = 0;
  wire global_out, local_out, flat_out;
  global_selector global_dut(clk, sources, global_select, global_out);
  flat15_selector flat_dut(clk, sources[6:0], sources[15:8], flat_select, flat_out);
  local_selector local_dut(clk, sources[6:0], sources[15:8],
                           local_select, remote_select, local_out);

  integer i, j;
  initial begin
    // Every directly reachable local source has the same one-edge latency.
    for (i = 0; i < 7; i = i + 1) begin
      @(negedge clk);
      sources = 0;
      global_select = i[5:0];
      flat_select = i[3:0];
      local_select = i[2:0];
      sources[i] = 1;
      @(posedge clk); #1;
      if (global_out !== 1 || flat_out !== 1 || local_out !== 1) $fatal(1, "local rise %0d", i);
      @(negedge clk); sources[i] = 0;
      @(posedge clk); #1;
      if (global_out !== 0 || flat_out !== 0 || local_out !== 0) $fatal(1, "local fall %0d", i);
    end

    // Each remote source costs one extra edge through the relay, in both
    // directions. Start from zero so the relay's unreset value is irrelevant.
    for (j = 0; j < 8; j = j + 1) begin
      @(negedge clk);
      sources = 0;
      global_select = 6'd8 + {3'b000, j[2:0]};
      flat_select = 4'd7 + {1'b0, j[2:0]};
      local_select = 7;
      remote_select = j[2:0];
      repeat (2) @(posedge clk);
      #1;
      if (global_out !== 0 || flat_out !== 0 || local_out !== 0) $fatal(1, "remote clear %0d", j);
      @(negedge clk); sources[8+j] = 1;
      @(posedge clk); #1;
      if (global_out !== 1 || flat_out !== 1 || local_out !== 0) $fatal(1, "remote first edge %0d", j);
      @(posedge clk); #1;
      if (local_out !== 1) $fatal(1, "remote second edge %0d", j);
      @(negedge clk); sources[8+j] = 0;
      @(posedge clk); #1;
      if (global_out !== 0 || flat_out !== 0 || local_out !== 1) $fatal(1, "remote fall first edge %0d", j);
      @(posedge clk); #1;
      if (local_out !== 0) $fatal(1, "remote fall second edge %0d", j);
    end
    $display("PASS: direct paths 1 edge; relayed paths 2 edges");
    $finish;
  end
endmodule
`default_nettype wire
