`timescale 1ns/1ps
// Validate the legacy configurable CRC block against known USB CRC-16 and
// Ethernet CRC-32 vectors before proposing it as a spatial tile.
module crc_reuse_tb;
  reg clk=0,rst_n=0,enable=0,cfg_we=0;reg [2:0] cfg_addr=0;reg [15:0] cfg_data=0;
  reg [63:0] lines=0;wire out,tail_out,ok;wire [31:0] value;
  fabric_crc dut(clk,rst_n,enable,cfg_we,cfg_addr,cfg_data,lines,2'b0,2'b0,2'b0,out,tail_out,ok,value);
  always #5 clk=~clk;
  task automatic cfg(input [2:0] addr,input [15:0] data);
    begin @(negedge clk);cfg_addr=addr;cfg_data=data;cfg_we=1;@(negedge clk);cfg_we=0;end
  endtask
  task automatic run_vector(input [4:0] width_minus_one,input [31:0] poly,input [31:0] expected);
    integer i,j;reg [7:0] b;
    begin
      @(negedge clk);enable=0;lines=0;
      cfg(0,poly[15:0]);cfg(1,poly[31:16]);cfg(4,0);cfg(5,16'h0042);
      cfg(6,{10'b0,1'b1,width_minus_one});cfg(7,0);
      repeat(3) @(negedge clk);enable=1;
      // The canonical ASCII test string "123456789", least-significant bit first.
      for(i=0;i<9;i=i+1) begin
        b=8'h31+8'(i);
        for(j=0;j<8;j=j+1) begin
          @(negedge clk);lines[32]=b[j];lines[0]=1;
          @(negedge clk);lines[0]=0;
        end
      end
      #1;if(value!==expected) $fatal(1,"width %0d CRC register %h expected %h",width_minus_one+1,value,expected);
      @(negedge clk);enable=0;repeat(2) @(negedge clk);
    end
  endtask
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    // Internal register is bit-reversed relative to the uncomplemented
    // reflected CRC. Standard final values are USB b4c8 and Ethernet cbf43926.
    run_vector(15,32'h00008005,32'h0000ecd2);
    run_vector(31,32'h04c11db7,32'h9b63d02c);
    $display("PASS: reusable CRC tile matches USB CRC-16 and Ethernet CRC-32 reference vectors");
    $finish;
  end
endmodule
