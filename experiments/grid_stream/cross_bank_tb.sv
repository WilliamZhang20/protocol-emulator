`timescale 1ns/1ps
// A 1518-byte payload crosses the two real 1 KiB SRAM macro models.
module cross_bank_tb;
  reg clk=0,rst_n=0,enable=0,cfg_we=0;reg [2:0] routes=0;
  reg rs=0,ws=0,consume=0,wvalid=0;reg [7:0] win=0;
  wire rr,rv,rd_active,rd_done,rd_error;wire [10:0] ra;wire [7:0] rd;wire [1:0] rq,ri;
  wire wr,wr_ready,wr_active,wr_done,wr_error;wire [10:0] wa;wire [7:0] wd;wire [1:0] wq;
  reg hreq=0,hwe=0;reg [9:0] ha=0;reg [7:0] hd=0;wire [2:0] ready,rvalid;wire [23:0] rdata;
  grid_stream_reader reader(clk,rst_n,enable,rs,11'd512,11'd1518,rr,ready[1],ra,rvalid[1],rdata[15:8],rv,consume,rd,rd_active,rd_done,rd_error,rq,ri);
  grid_stream_writer writer(clk,rst_n,enable,ws,11'd900,11'd200,wvalid,wr_ready,win,wr,ready[2],wa,wd,wr_active,wr_done,wr_error,wq);
  grid_stream_memory #(.USE_MACRO(1)) mem(clk,rst_n,enable,cfg_we,routes,{wa[10],ra[10]},
    {wr,rr,hreq},{1'b1,1'b0,hwe},{wa[9:0],ra[9:0],ha},{wd,8'b0,hd},ready,rvalid,rdata);
  always #5 clk=~clk;
  initial begin #3000000;$fatal(1,"timeout");end
  function automatic [7:0] pattern(input integer x);pattern=8'(x*37+11);endfunction
  task automatic bank(input bit b);
    begin @(negedge clk);enable=0;cfg_we=1;routes={2'b00,b};@(negedge clk);cfg_we=0;enable=1;end
  endtask
  task automatic hwrite(input [9:0] a,input [7:0] d);
    begin @(negedge clk);hreq=1;hwe=1;ha=a;hd=d;do @(posedge clk);while(!ready[0]);@(negedge clk);hreq=0;end
  endtask
  task automatic hcheck(input [9:0] a,input [7:0] d);
    begin @(negedge clk);hreq=1;hwe=0;ha=a;do @(posedge clk);while(!ready[0]);#1;
      if(!rvalid[0] || rdata[7:0]!==d) $fatal(1,"cross-bank write mismatch addr %0d: %h vs %h",a,rdata[7:0],d);
      @(negedge clk);hreq=0;end
  endtask
  integer i,n,seen=0,sent=0;reg crossed=0;
  always @(posedge clk) if(enable && rr && ready[1] && ra[10]) crossed<=1;
  initial begin
    repeat(4) @(negedge clk);rst_n=1;bank(0);
    for(i=0;i<512;i=i+1) hwrite(10'(512+i),pattern(i));
    bank(1);for(i=0;i<1006;i=i+1) hwrite(10'(i),pattern(512+i));
    bank(0);@(negedge clk);rs=1;@(negedge clk);rs=0;consume=1;
    for(n=0;n<10000;n=n+1) begin
      @(posedge clk);if(rv && consume) begin
        if(rd!==pattern(seen)) $fatal(1,"cross-bank read mismatch at %0d",seen);
        seen=seen+1;
      end
      #1;if(rd_done) break;
    end
    if(!rd_done || rd_error || seen!=1518 || !crossed) $fatal(1,"cross-bank read incomplete %0d",seen);
    @(negedge clk);consume=0;ws=1;@(negedge clk);ws=0;
    for(n=0;n<3000;n=n+1) begin
      @(negedge clk);wvalid=sent<200;win=pattern(sent);
      @(posedge clk);if(wvalid && wr_ready) sent=sent+1;
      #1;if(wr_done) break;
    end
    @(negedge clk);wvalid=0;
    if(!wr_done || wr_error || sent!=200) $fatal(1,"cross-bank write incomplete %0d",sent);
    bank(0);for(i=0;i<124;i=i+1) hcheck(10'(900+i),pattern(i));
    bank(1);for(i=0;i<76;i=i+1) hcheck(10'(i),pattern(124+i));
    $display("PASS: 1518-byte reader and 200-byte writer cross SRAM bank boundary without wrapping");
    $finish;
  end
endmodule
