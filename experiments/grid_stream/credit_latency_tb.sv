`timescale 1ns/1ps
module credit_latency_tb;
  reg clk=0,rst_n=0,enable=0,start=0,consume=0;
  wire req,valid,active,done,error;wire [10:0] addr;wire [7:0] data;
  wire [1:0] queued,outstanding;
  reg [3:0] vpipe=0;reg [7:0] dpipe[0:3];
  grid_stream_reader reader(clk,rst_n,enable,start,11'd20,11'd16,req,1'b1,addr,vpipe[3],dpipe[3],
      valid,consume,data,active,done,error,queued,outstanding);
  always #5 clk=~clk;
  always @(posedge clk) begin
    if(!rst_n) vpipe<=0;
    else begin
      vpipe<={vpipe[2:0],req};
      dpipe[0]<=addr[7:0];dpipe[1]<=dpipe[0];dpipe[2]<=dpipe[1];dpipe[3]<=dpipe[2];
    end
  end
  integer cycle,received=0,max_outstanding=0;
  initial begin
    repeat(4) @(negedge clk);rst_n=1;enable=1;start=1;
    @(negedge clk);start=0;
    for(cycle=0;cycle<400;cycle=cycle+1) begin
      @(negedge clk);consume=(cycle%7)!=0;
      @(posedge clk);
      if(outstanding>max_outstanding) max_outstanding=int'(outstanding);
      if(valid && consume) begin
        if(data!==8'(20+received)) $fatal(1,"out-of-order return %0d got %0d",received,data);
        received=received+1;
      end
      #1;if(done) break;
    end
    if(!done || error || received!=16 || max_outstanding!=2) $fatal(1,"credit test received=%0d max_outstanding=%0d",received,max_outstanding);
    // Disarm with two reads in flight; the return network keeps running.
    // A premature restart must be rejected until stale responses are drained.
    @(negedge clk);start=1;consume=0;@(negedge clk);start=0;
    for(cycle=0;cycle<20 && outstanding!=2;cycle=cycle+1) @(negedge clk);
    if(outstanding!=2) $fatal(1,"failed to create outstanding reads");
    enable=0;@(negedge clk);enable=1;start=1;@(negedge clk);start=0;#1;
    if(!done || !error || active) $fatal(1,"restart accepted before stale reads drained");
    for(cycle=0;cycle<20 && outstanding!=0;cycle=cycle+1) @(negedge clk);
    if(outstanding!=0) $fatal(1,"stale reads did not drain");
    @(negedge clk);start=1;@(negedge clk);start=0;received=0;
    for(cycle=0;cycle<400;cycle=cycle+1) begin
      @(negedge clk);consume=1;
      @(posedge clk);if(valid && consume) begin
        if(data!==8'(20+received)) $fatal(1,"stale response corrupted restarted stream");
        received=received+1;
      end
      #1;if(done) break;
    end
    if(!done || error || received!=16) $fatal(1,"restart after drain failed");
    $display("PASS: two credits safely cover multiple outstanding four-cycle reads with a stalled consumer");
    $finish;
  end
endmodule
