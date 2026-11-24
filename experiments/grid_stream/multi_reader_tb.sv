`timescale 1ns/1ps
// Four contending clients share one modeled bank and one ordered tagged return
// path with four-cycle latency. Two independent readers each reserve two slots.
module multi_reader_tb;
  reg clk=0,rst_n=0,enable=0,start=0;
  wire [1:0] req,valid,active,done,error;wire [21:0] addr;wire [15:0] data;
  wire [3:0] q0,q1; // {outstanding,queued}
  reg [1:0] consume=0;
  reg hreq=0,hwe=0;reg [9:0] haddr=0;reg [7:0] hwdata=0;
  reg wstart=0,wvalid=0;reg [7:0] wdata=0;
  wire wready,wreq,wactive,wdone,werror;wire [10:0] waddr;wire [7:0] wout;wire [1:0] wq;
  wire [3:0] grant,rvalid;wire [7:0] return_data;
  grid_stream_reader r0(clk,rst_n,enable,start,11'd0,11'd32,req[0],grant[1],addr[10:0],rvalid[1],return_data,
    valid[0],consume[0],data[7:0],active[0],done[0],error[0],q0[1:0],q0[3:2]);
  grid_stream_reader r1(clk,rst_n,enable,start,11'd32,11'd32,req[1],grant[2],addr[21:11],rvalid[2],return_data,
    valid[1],consume[1],data[15:8],active[1],done[1],error[1],q1[1:0],q1[3:2]);
  grid_stream_writer writer(clk,rst_n,enable,wstart,11'd200,11'd32,wvalid,wready,wdata,wreq,grant[3],waddr,wout,wactive,wdone,werror,wq);
  reg [7:0] memory[0:1023];reg [1:0] next_priority=0;reg [3:0] selected;
  reg [3:0] return_valid[0:3];reg [7:0] return_word[0:3];
  integer i,j,candidate;reg found;wire [3:0] requests={wreq,req[1],req[0],hreq};
  wire [3:0] writes={1'b1,1'b0,1'b0,hwe};
  wire [39:0] addresses={waddr[9:0],addr[20:11],addr[9:0],haddr};
  wire [31:0] values={wout,8'b0,8'b0,hwdata};
  reg [1:0] chosen;
  always @* begin
    selected=0;chosen=0;found=0;
    for(i=0;i<4;i=i+1) begin
      candidate=(integer'(next_priority)+i)%4;
      if(!found && requests[candidate] && enable && rst_n) begin selected[candidate]=1;chosen=2'(candidate);found=1;end
    end
  end
  assign grant=selected;assign rvalid=return_valid[3];assign return_data=return_word[3];
  always @(posedge clk) begin
    if(!rst_n) begin next_priority<=0;for(j=0;j<4;j=j+1) return_valid[j]<=0;end
    else begin
      if(|selected) next_priority<=chosen+1'b1;
      return_valid[0]<=selected & ~writes;
      if(|selected) begin
        if(writes[chosen]) memory[addresses[chosen*10+:10]]<=values[chosen*8+:8];
        else return_word[0]<=memory[addresses[chosen*10+:10]];
      end
      for(j=1;j<4;j=j+1) begin return_valid[j]<=return_valid[j-1];return_word[j]<=return_word[j-1];end
    end
  end
  always #5 clk=~clk;
  initial begin #1000000;$fatal(1,"timeout");end
  integer k,cycle,got0=0,got1=0,sent=0,wait0=0,wait1=0,max_wait=0;
  reg d0=0,d1=0,dw=0,accepted;
  always @(posedge clk) if(rst_n && enable) begin
    if(done[0]) d0<=1;if(done[1]) d1<=1;if(wdone) dw<=1;
    if(req[0] && !grant[1]) wait0<=wait0+1;else wait0<=0;
    if(req[1] && !grant[2]) wait1<=wait1+1;else wait1<=0;
    if(wait0>max_wait) max_wait<=wait0;if(wait1>max_wait) max_wait<=wait1;
    if(wait0>3 || wait1>3) $fatal(1,"four-client arbitration starvation");
    if(valid[0] && consume[0]) begin if(data[7:0]!==8'(got0^8'ha5)) $fatal(1,"reader0 mismatch");got0<=got0+1;end
    if(valid[1] && consume[1]) begin if(data[15:8]!==8'((got1+32)^8'ha5)) $fatal(1,"reader1 mismatch");got1<=got1+1;end
    if(wvalid && wready) sent<=sent+1;
  end
  initial begin
    repeat(4) @(negedge clk);rst_n=1;enable=1;
    for(k=0;k<64;k=k+1) begin
      @(negedge clk);hreq=1;hwe=1;haddr=10'(k);hwdata=8'(k^8'ha5);
      do @(posedge clk);while(!grant[0]);@(negedge clk);hreq=0;
    end
    @(negedge clk);start=1;wstart=1;@(negedge clk);start=0;wstart=0;
    hreq=1;hwe=1;haddr=900;hwdata=0;
    for(k=0;k<100 && (q0[1:0]!=2 || q1[1:0]!=2);k=k+1) @(negedge clk);
    if(q0[1:0]!=2 || q1[1:0]!=2) $fatal(1,"readers did not prefill");
    accepted=0;
    for(cycle=0;cycle<1400;cycle=cycle+1) begin
      @(negedge clk);if(accepted) hwdata=hwdata+1'b1;consume=0;wvalid=0;
      if(cycle%16==0 && got0<32) begin if(!valid[0]) $fatal(1,"reader 0 underflow");consume[0]=1;end
      if(cycle%16==4 && got1<32) begin if(!valid[1]) $fatal(1,"reader 1 underflow");consume[1]=1;end
      if(cycle%16==8 && sent<32) begin if(!wready) $fatal(1,"writer overflow");wvalid=1;wdata=8'(sent^8'h3c);end
      @(posedge clk);accepted=grant[0];
      if(d0 && d1 && dw) break;
    end
    @(negedge clk);hreq=0;consume=0;wvalid=0;
    if(!d0 || !d1 || !dw || |error || werror || got0!=32 || got1!=32 || sent!=32) $fatal(1,"multi-reader completion");
    for(k=0;k<32;k=k+1) if(memory[200+k]!==8'(k^8'h3c)) $fatal(1,"writer mismatch %0d",k);
    $display("PASS: two credited readers and writer share a four-cycle tagged return path with a contending host; max wait=%0d",max_wait);
    $finish;
  end
endmodule
