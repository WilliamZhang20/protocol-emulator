`timescale 1ns/1ps
module stream_tb;
  reg clk=0,rst_n=0,enable=0,cfg_we=0;reg [2:0] routes=0;
  reg rs=0,ws=0,rbank=0,wbank=0;reg [9:0] rbase=100,wbase=200;reg [10:0] length=32;
  wire rr,rv,rd_valid,rd_active,rd_done,rd_error;
  wire [10:0] ra;wire [7:0] rd_data;wire [1:0] rq,ri;
  wire wr_req,wr_ready,wr_active,wr_done,wr_error;wire [10:0] wa;wire [7:0] wd;wire [1:0] wq;
  reg consume=0,writer_valid=0;
  reg host_req=0,host_we=0;reg [9:0] host_addr=0;reg [7:0] host_data=0;
  wire [2:0] ready,rvalid;wire [23:0] rdata;
  grid_stream_reader reader(clk,rst_n,enable,rs,{rbank,rbase},length,rr,ready[1],ra,rvalid[1],rdata[15:8],rd_valid,consume,rd_data,rd_active,rd_done,rd_error,rq,ri);
  grid_stream_writer writer(clk,rst_n,enable,ws,{wbank,wbase},length,writer_valid,wr_ready,rd_data,wr_req,ready[2],wa,wd,wr_active,wr_done,wr_error,wq);
  grid_stream_memory #(.USE_MACRO(1)) memory(clk,rst_n,enable,cfg_we,routes,{wa[10],ra[10]},{wr_req,rr,host_req},{1'b1,1'b0,host_we},
    {wa[9:0],ra[9:0],host_addr},{wd,8'b0,host_data},ready,rvalid,rdata);
  always #5 clk=~clk;
  initial begin #1000000;$fatal(1,"timeout");end
  assert property (@(posedge clk) disable iff(!rst_n || !enable) rr && ready[1] |=> rvalid[1]);
  assert property (@(posedge clk) disable iff(!rst_n || !enable) (rq+ri)<=2);
  integer denial=0,max_denial=0,host_stalls=0,writer_stalls=0,reads=0,writes=0,transferred=0;
  integer cycles=0,request_start=0,return_index=0,max_latency=0;
  integer issued_at[0:31];reg waiting=0;
  reg seen_rd_done=0,seen_wr_done=0;
  always @(posedge clk) if(rst_n && enable) begin
    cycles=cycles+1;
    if(rd_done) seen_rd_done<=1;
    if(wr_done) seen_wr_done<=1;
    if(rr && !ready[1]) begin denial<=denial+1;if(denial+1>max_denial) max_denial<=denial+1;end
    else denial<=0;
    if(host_req && !ready[0]) host_stalls<=host_stalls+1;
    if(wr_req && !ready[2]) writer_stalls<=writer_stalls+1;
    if(rr && !waiting) begin request_start=cycles;waiting=1;end
    if(rr && ready[1]) begin issued_at[reads]=request_start;waiting=0;reads<=reads+1;end
    if(rvalid[1]) begin
      if(cycles-issued_at[return_index]>max_latency) max_latency=cycles-issued_at[return_index];
      if(cycles-issued_at[return_index]>4) $fatal(1,"reader request-to-FIFO latency exceeded four cycles");
      return_index=return_index+1;
    end
    if(wr_req && ready[2]) writes<=writes+1;
    if(consume && rd_valid) transferred<=transferred+1;
    if(denial>2) $fatal(1,"reader exceeded 3-client round-robin bound");
  end
  task automatic host_write(input [9:0] a,input [7:0] d);
    begin @(negedge clk);host_req=1;host_we=1;host_addr=a;host_data=d;
      do @(posedge clk);while(!ready[0]);@(negedge clk);host_req=0;end
  endtask
  task automatic host_check(input [9:0] a,input [7:0] expected);
    begin @(negedge clk);host_req=1;host_we=0;host_addr=a;
      do @(posedge clk);while(!ready[0]);#1;
      if(!rvalid[0] || rdata[7:0]!==expected) $fatal(1,"read %0d got %h expected %h",a,rdata[7:0],expected);
      @(negedge clk);host_req=0;end
  endtask
  integer i,cycle;reg accepted;
  initial begin
    repeat(4) @(negedge clk);rst_n=1;cfg_we=1;routes=0;@(negedge clk);cfg_we=0;enable=1;
    for(i=0;i<32;i=i+1) host_write(10'(100+i),8'(i^8'hb6));
    @(negedge clk);rs=1;ws=1;@(negedge clk);rs=0;ws=0;
    host_req=1;host_we=1;host_addr=900;host_data=8'h5a;
    // The external wire cannot wait for a late byte. Prefill both credits,
    // then require every scheduled byte to be available without backpressure.
    for(i=0;i<100 && rq!=2;i=i+1) @(negedge clk);
    if(rq!=2) $fatal(1,"reader failed to prefill under host contention");
    accepted=0;
    for(cycle=0;cycle<1200;cycle=cycle+1) begin
      @(negedge clk);
      if(accepted) host_data=host_data+1'b1;
      if(cycle%16==0 && transferred<32) begin
        if(!rd_valid || !wr_ready) $fatal(1,"periodic stream would underflow or overrun at byte %0d",transferred);
        writer_valid=1;consume=1;
      end else begin writer_valid=0;consume=0;end
      @(posedge clk);accepted=ready[0];
      if(seen_rd_done && seen_wr_done) break;
    end
    @(negedge clk);host_req=0;writer_valid=0;consume=0;
    if(!seen_rd_done || !seen_wr_done || rd_error || wr_error || reads!=32 || writes!=32 || transferred!=32)
      $fatal(1,"stream status rdone=%b wdone=%b err=%b%b reads=%0d writes=%0d moved=%0d",seen_rd_done,seen_wr_done,rd_error,wr_error,reads,writes,transferred);
    if(host_stalls==0 || writer_stalls==0 || max_denial==0) $fatal(1,"contention not exercised");
    for(i=0;i<32;i=i+1) host_check(10'(200+i),8'(i^8'hb6));
    @(negedge clk);enable=0;@(negedge clk);enable=1;rbank=1;rbase=1023;length=2;rs=1;
    @(negedge clk);rs=0;#1;if(!rd_done || !rd_error || rd_active) $fatal(1,"reader range not rejected");
    $display("PASS: depth-two streams preserve 32 bytes at 16-cycle periods with three-client same-bank contention; max denial=%0d, request-to-FIFO latency=%0d",max_denial,max_latency);
    $finish;
  end
endmodule
