`timescale 1ns/1ps
`default_nettype none
module control_fabric_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, cfg_we=0;
  reg [4:0] cfg_addr=0;
  reg [15:0] cfg_data=0;
  reg [1:0] pad_in=0;
  wire [2:0] pad_out,pad_oe;
  reg [15:0] image[0:16];
  reg [1023:0] image_path;
  integer i, high_count=0, low_count=0;
  control_fabric dut(clk,rst_n,arm,cfg_we,cfg_addr,cfg_data,pad_in,pad_out,pad_oe);

  // Observe top-level pins only. A one-cycle pulse is counted once.
  always @(negedge clk) begin
    if (arm && pad_oe==3'b011) begin
      if (pad_out[0]) high_count=high_count+1;
      if (pad_out[1]) low_count=low_count+1;
      if (pad_out[2] && pad_oe[2]) $fatal(1,"unassigned pad driven");
    end
  end
  task write_word(input [4:0] address, input [15:0] data);
    begin
      @(negedge clk); cfg_we=1; cfg_addr=address; cfg_data=data;
      @(negedge clk); cfg_we=0;
    end
  endtask
  initial begin
    if (!$value$plusargs("IMAGE=%s",image_path)) $fatal(1,"IMAGE required");
    $readmemh(image_path,image);
    repeat (3) @(negedge clk); rst_n=1;
    for (i=0; i<16; i=i+1) write_word(i[4:0],image[i]);
    @(negedge clk); arm=1; repeat (3) @(negedge clk);
    if (pad_oe!==0) $fatal(1,"incomplete image drove pads");
    arm=0; write_word(16,image[16]);
    @(negedge clk); arm=1; repeat (7) @(negedge clk);
    if (pad_oe!==3'b011 || pad_out!==0) $fatal(1,"bad armed idle");
    pad_in=2'b01; repeat (9) @(negedge clk);
    if (high_count!=1 || low_count!=0) $fatal(1,"high event: %0d %0d",high_count,low_count);
    pad_in=2'b11; repeat (7) @(negedge clk);
    if (high_count!=1 || low_count!=0) $fatal(1,"unused input changed behavior");
    pad_in=2'b10; repeat (9) @(negedge clk);
    if (high_count!=1 || low_count!=1) $fatal(1,"low event: %0d %0d",high_count,low_count);
    arm=0; repeat (3) @(negedge clk);
    if (pad_oe!==0) $fatal(1,"disarm did not release pads");
    $display("PASS: complete restricted .spt image drives expected pins");
    $finish;
  end
endmodule
`default_nettype wire
