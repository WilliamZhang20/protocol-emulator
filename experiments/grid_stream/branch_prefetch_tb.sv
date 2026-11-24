`timescale 1ns/1ps
module branch_prefetch_tb;
  reg clk=0,rst_n=0,enable=0,start=0,resolve=0,choice=0,consume=0;
  wire req,valid,active,done,start_ready;wire [9:0] addr;wire [7:0] data;wire [1:0] issued,received;
  reg [3:0] pipe_valid=0;reg [7:0] pipe_data[0:3];
  grid_branch_prefetch dut(clk,rst_n,enable,start,10'd42,10'd99,req,1'b1,addr,pipe_valid[3],pipe_data[3],
    resolve,choice,valid,consume,data,active,done,start_ready,issued,received);
  always #5 clk=~clk;
  always @(posedge clk) begin
    if(!rst_n) pipe_valid<=0;
    else begin
      pipe_valid<={pipe_valid[2:0],req};
      pipe_data[0]<=addr[7:0]^8'h5a;pipe_data[1]<=pipe_data[0];pipe_data[2]<=pipe_data[1];pipe_data[3]<=pipe_data[2];
    end
  end
  task automatic one(input bit which);
    integer n;
    begin
      @(negedge clk);start=1;choice=which;@(negedge clk);start=0;
      for(n=0;n<20 && received!=2'b11;n=n+1) @(negedge clk);
      if(received!=2'b11 || issued!=2'b11) $fatal(1,"both alternatives not prefetched");
      resolve=1;@(negedge clk);resolve=0;#1;
      if(!valid || data!==(which ? (8'd99^8'h5a) : (8'd42^8'h5a))) $fatal(1,"late choice not immediately available");
      repeat(3) begin @(negedge clk);if(!valid) $fatal(1,"selected value not held");end
      consume=1;@(negedge clk);consume=0;
      for(n=0;n<5 && !done;n=n+1) @(negedge clk);
      if(!done) $fatal(1,"branch operation did not retire");
    end
  endtask
  task automatic early;
    integer n;
    begin
      @(negedge clk);start=1;choice=0;@(negedge clk);start=0;resolve=1;
      @(negedge clk);resolve=0;
      for(n=0;n<20 && !valid;n=n+1) @(negedge clk);
      if(!valid || data!==(8'd42^8'h5a)) $fatal(1,"early choice lost");
      consume=1;@(negedge clk);consume=0;
      for(n=0;n<20 && !done;n=n+1) @(negedge clk);
      if(!done || received!=2'b11) $fatal(1,"unselected response did not drain");
    end
  endtask
  initial begin
    repeat(3) @(negedge clk);rst_n=1;enable=1;
    one(0);one(1);early();
    @(negedge clk);start=1;@(negedge clk);start=0;
    wait(issued==2'b11);@(negedge clk);enable=0;
    @(negedge clk);enable=1;#1;
    if(start_ready) $fatal(1,"branch accepted restart before stale responses drained");
    wait(start_ready);one(1);
    $display("PASS: both alternatives are prefetched; either late decision is available after one control clock");
    $finish;
  end
endmodule
