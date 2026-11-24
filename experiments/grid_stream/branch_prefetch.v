`default_nettype none
// Two independent one-byte alternatives are fetched before a late decision.
// The memory returns ordered, unbackpressured read responses. Each branch has
// its own reserved response slot; a selected byte never waits on a new read.
module grid_branch_prefetch(
  input wire clk,rst_n,enable,start,input wire [9:0] addr0,addr1,
  output wire req,input wire ready,output wire [9:0] addr,
  input wire rvalid,input wire [7:0] rdata,
  input wire resolve,input wire choice,
  output wire valid,input wire consume,output wire [7:0] data,
  output reg active,done,output wire start_ready,output wire [1:0] issued,received);
  reg [1:0] sent,have;reg [7:0] value0,value1;
  reg [9:0] saved0,saved1;
  reg decided,selected,taken;
  wire issue=req && ready;
  assign issued=sent;assign received=have;
  assign start_ready=enable && !active && sent==have;
  assign req=enable && active && !sent[1];
  assign addr=sent[0] ? saved1 : saved0;
  assign valid=enable && active && decided && !taken && have[selected];
  assign data=selected ? value1 : value0;
  always @(posedge clk) begin
    if(!rst_n) begin
      sent<=0;have<=0;decided<=0;selected<=0;taken<=0;active<=0;done<=0;value0<=0;value1<=0;saved0<=0;saved1<=0;
    end else if(!enable) begin
      active<=0;done<=0;decided<=0;taken<=0;
      if(rvalid && sent!=have) begin if(!have[0]) have[0]<=1;else have[1]<=1;end
    end else begin
      done<=0;
      if(start && start_ready) begin sent<=0;have<=0;decided<=0;taken<=0;active<=1;saved0<=addr0;saved1<=addr1;end
      if(issue) begin if(!sent[0]) sent[0]<=1;else sent[1]<=1;end
      if(rvalid && active) begin
        if(!have[0]) begin value0<=rdata;have[0]<=1;end
        else begin value1<=rdata;have[1]<=1;end
      end
      if(rvalid && !active && sent!=have) begin if(!have[0]) have[0]<=1;else have[1]<=1;end
      if(resolve && active && !decided) begin decided<=1;selected<=choice;end
      if(valid && consume) taken<=1;
      if(active && taken && (&have)) begin active<=0;done<=1;end
    end
  end
`ifdef GRID_STREAM_ASSERT
  assert property (@(posedge clk) disable iff(!rst_n || !enable) req && !ready |=> req && $stable(addr));
  assert property (@(posedge clk) disable iff(!rst_n || !enable) valid && !consume |=> valid && $stable(data));
  assert property (@(posedge clk) disable iff(!rst_n || !enable) rvalid && active |-> (sent!=have));
`endif
endmodule
`default_nettype wire
