`timescale 1ns/1ps
module arbiter_bound_tb;
  reg clk=0,rst_n=0,enable=0;reg [2:0] req=0;wire [2:0] ready,rvalid;wire [7:0] rdata;
  // Host and writer write; reader requests reads every cycle.
  grid_stream_bank #(.USE_MACRO(1)) dut(clk,rst_n,enable,req,3'b101,
    {10'd900,10'd100,10'd901},{8'h77,8'h00,8'h55},ready,rvalid,rdata);
  always #5 clk=~clk;
  integer cycle,denied=0,max_denied=0,grants=0;
  initial begin
    repeat(3) @(negedge clk);rst_n=1;enable=1;req=3'b111;
    for(cycle=0;cycle<30;cycle=cycle+1) begin
      @(posedge clk);
      if(ready!== (cycle%3==0 ? 3'b001 : cycle%3==1 ? 3'b010 : 3'b100))
        $fatal(1,"round robin grant %0d was %b",cycle,ready);
      if(ready[1]) begin grants=grants+1;denied=0;end
      else begin denied=denied+1;if(denied>max_denied) max_denied=denied;end
      @(negedge clk);
    end
    if(max_denied!=2 || grants!=10) $fatal(1,"arbitration bound mismatch");
    $display("PASS: persistent three-client bank arbitration reaches the exact two-cycle reader denial bound");
    $finish;
  end
endmodule
