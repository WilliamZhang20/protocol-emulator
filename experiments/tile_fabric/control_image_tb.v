`timescale 1ns/1ps
`default_nettype none
// Exercises a compiler-produced table through the control tile's input/output
// ports. The source program's pin-to-tile binding is intentionally external.
module control_image_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, arm=0, cfg_we=0, trigger=0, second=0;
  reg [3:0] cfg_row=0;
  reg [4:0] cfg_data=0;
  wire action1, action2, action3;
  reg [15:0] image [0:15];
  reg [1023:0] image_path;
  integer i;
  proto_control dut(clk,rst_n,arm,cfg_we,cfg_row,cfg_data,trigger,second,
                    action1,action2,action3);
  task check_step(input reg a, input reg b, input [2:0] expected);
    begin
      @(negedge clk); trigger=a; second=b;
      @(posedge clk); #1;
      if ({action3,action2,action1} !== expected)
        $fatal(1,"trigger=%b second=%b actions=%b expected=%b",a,b,{action3,action2,action1},expected);
    end
  endtask
  initial begin
    if (!$value$plusargs("IMAGE=%s",image_path)) $fatal(1,"IMAGE required");
    $readmemh(image_path,image);
    repeat (3) @(negedge clk); rst_n=1;
    for (i=0; i<16; i=i+1) begin
      @(negedge clk); cfg_we=1; cfg_row=i[3:0]; cfg_data=image[i][4:0];
      @(negedge clk); cfg_we=0;
    end
    @(negedge clk); arm=1;
    check_step(0,0,3'b000);
    check_step(1,0,3'b001);
    check_step(1,1,3'b000); // missing row: hold; second input ignored
    check_step(0,1,3'b010);
    check_step(0,0,3'b000);
    check_step(1,1,3'b001);
    check_step(0,0,3'b010);
    @(negedge clk); arm=0;
    @(posedge clk); #1;
    if ({action3,action2,action1} !== 0) $fatal(1,"disarm did not clear actions");
    $display("PASS: frontend-generated control table matches pin stimulus");
    $finish;
  end
endmodule
`default_nettype wire
