`default_nettype none
// One ordered read stream. Credits reserve FIFO slots for both queued bytes
// and accepted reads whose responses have not arrived. Memory must return one
// ordered response per accepted request; there is no response backpressure.
module grid_stream_reader #(parameter DEPTH=2, parameter PTR_W=DEPTH>1 ? $clog2(DEPTH) : 1, parameter COUNT_W=$clog2(DEPTH+1))(
  input wire clk,rst_n,enable,start,input wire [10:0] base,input wire [10:0] length,
  output wire req, input wire ready,output wire [10:0] addr,
  input wire rvalid,input wire [7:0] rdata,
  output wire valid,input wire consume,output wire [7:0] data,
  output reg active,done,error,output wire [COUNT_W-1:0] queued,outstanding);
  reg [7:0] fifo[0:DEPTH-1];
  reg [PTR_W-1:0] rd,wr;
  reg [COUNT_W-1:0] count,inflight;
  reg inflight_bank;
  reg [10:0] next_addr;reg [10:0] remaining;
  wire [11:0] end_addr={1'b0,base}+{1'b0,length};
  wire [COUNT_W:0] used={1'b0,count}+{1'b0,inflight};
  wire issue=req && ready;
  wire push=active && rvalid;
  wire pop=valid && consume;
  // Different banks may have different return latencies. Drain outstanding
  // reads at a boundary before issuing to the next bank, preserving order.
  assign req=enable && active && remaining!=0 && used<DEPTH && (inflight==0 || next_addr[10]==inflight_bank);
  assign addr=next_addr;
  assign valid=enable && active && count!=0;
  assign data=fifo[rd];
  assign queued=count;assign outstanding=inflight;
  localparam [31:0] DEPTH_MINUS_ONE = DEPTH-1;
  localparam [PTR_W-1:0] LAST = DEPTH_MINUS_ONE[PTR_W-1:0];
  function [PTR_W-1:0] advance(input [PTR_W-1:0] ptr);
    advance=(ptr==LAST) ? 0 : ptr+1'b1;
  endfunction
  always @(posedge clk) begin
    if(!rst_n) begin
      rd<=0;wr<=0;count<=0;inflight<=0;inflight_bank<=0;next_addr<=0;remaining<=0;
      active<=0;done<=0;error<=0;
    end else if(!enable) begin
      // A registered return network may outlive disarm. Drop queued data,
      // but retain and drain accepted reads before another stream can start.
      rd<=0;wr<=0;count<=0;next_addr<=0;remaining<=0;
      active<=0;done<=0;error<=0;
      if(rvalid && inflight!=0) inflight<=inflight-1'b1;
    end else begin
      done<=0;
      if(start && !active) begin
        rd<=0;wr<=0;count<=0;error<=0;
        if(inflight!=0 || length==0 || end_addr>2048) begin error<=1;done<=1;end
        else begin active<=1;next_addr<=base;remaining<=length;end
      end
      if(issue) begin
        if(inflight==0) inflight_bank<=next_addr[10];
        next_addr<=next_addr+1'b1;remaining<=remaining-1'b1;
      end
      if(push) begin fifo[wr]<=rdata;wr<=advance(wr);end
      if(pop) rd<=advance(rd);
      case({push,pop})
        2'b10:count<=count+1'b1;
        2'b01:count<=count-1'b1;
        default:begin end
      endcase
      if(!active && inflight!=0 && rvalid) inflight<=inflight-1'b1;
      else case({issue,push})
          2'b10:inflight<=inflight+1'b1;
          2'b01:inflight<=inflight-1'b1;
          default:begin end
        endcase
      if(active && remaining==0 && inflight==0 && count==0) begin active<=0;done<=1;end
    end
  end
`ifdef GRID_STREAM_ASSERT
  assert property (@(posedge clk) disable iff(!rst_n || !enable) used<=DEPTH);
  assert property (@(posedge clk) disable iff(!rst_n || !enable) rvalid && active |-> inflight!=0);
  assert property (@(posedge clk) disable iff(!rst_n || !enable) req && !ready |=> req && $stable(addr));
  assert property (@(posedge clk) disable iff(!rst_n || !enable) valid && !consume |=> valid && $stable(data));
`endif
endmodule

// A bounded write stream. Input ready reserves an actual FIFO slot; writes
// are retired only when the selected bank accepts them.
module grid_stream_writer #(parameter DEPTH=2, parameter PTR_W=DEPTH>1 ? $clog2(DEPTH) : 1, parameter COUNT_W=$clog2(DEPTH+1))(
  input wire clk,rst_n,enable,start,input wire [10:0] base,input wire [10:0] length,
  input wire valid,output wire accept_ready,input wire [7:0] data,
  output wire req,input wire ready,output wire [10:0] addr,output wire [7:0] wdata,
  output reg active,done,error,output wire [COUNT_W-1:0] queued);
  reg [7:0] fifo[0:DEPTH-1];reg [PTR_W-1:0] rd,wr;
  reg [COUNT_W-1:0] count;reg [10:0] next_addr;reg [10:0] remaining;
  wire [11:0] end_addr={1'b0,base}+{1'b0,length};
  wire pop=req && ready;
  wire push=valid && accept_ready;
  assign accept_ready=enable && active && remaining!=0 && (count<DEPTH || pop);
  assign req=enable && active && count!=0;
  assign addr=next_addr;assign wdata=fifo[rd];assign queued=count;
  localparam [31:0] DEPTH_MINUS_ONE = DEPTH-1;
  localparam [PTR_W-1:0] LAST = DEPTH_MINUS_ONE[PTR_W-1:0];
  function [PTR_W-1:0] advance(input [PTR_W-1:0] ptr);
    advance=(ptr==LAST) ? 0 : ptr+1'b1;
  endfunction
  always @(posedge clk) begin
    if(!rst_n || !enable) begin
      rd<=0;wr<=0;count<=0;next_addr<=0;remaining<=0;active<=0;done<=0;error<=0;
    end else begin
      done<=0;
      if(start && !active) begin
        rd<=0;wr<=0;count<=0;error<=0;
        if(length==0 || end_addr>2048) begin error<=1;done<=1;end
        else begin active<=1;next_addr<=base;remaining<=length;end
      end
      if(push) begin fifo[wr]<=data;wr<=advance(wr);remaining<=remaining-1'b1;end
      if(pop) begin rd<=advance(rd);next_addr<=next_addr+1'b1;end
      case({push,pop})
        2'b10:count<=count+1'b1;
        2'b01:count<=count-1'b1;
        default:begin end
      endcase
      if(active && remaining==0 && count==0) begin active<=0;done<=1;end
    end
  end
`ifdef GRID_STREAM_ASSERT
  assert property (@(posedge clk) disable iff(!rst_n || !enable) count<=DEPTH);
  assert property (@(posedge clk) disable iff(!rst_n || !enable) req && !ready |=> req && $stable({addr,wdata}));
`endif
endmodule
`default_nettype wire
