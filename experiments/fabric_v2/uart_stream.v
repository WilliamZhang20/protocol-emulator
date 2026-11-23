`default_nettype none
// Experimental independent UART TX/RX streams over the existing two-bank
// SRAM fabric. Four-byte TX and RX queues, one outstanding actor read, and
// registered actor requests. RX storage is a finite, non-wrapping region.
module fabric_v2_uart_stream #(parameter USE_MACRO=0)(
    input wire clk,rst_n,arm,cfg_we,input wire [4:0] cfg_addr,input wire [15:0] cfg_data,
    input wire bank_cfg_we,input wire [1:0] bank_routes,
    input wire host_req,host_we,input wire [9:0] host_addr,input wire [7:0] host_wdata,
    output wire host_ready,host_rvalid,output wire [7:0] host_rdata,
    input wire tx_start,input wire [9:0] tx_base,input wire [10:0] tx_length,
    input wire [9:0] rx_base,input wire [10:0] rx_capacity,
    input wire [1:0] pin_in,output wire [2:0] pin_out,pin_oe,
    output wire configured,output reg tx_done,tx_error,rx_overflow,
    output wire tx_active,output reg [10:0] rx_received,rx_written,
    output wire [2:0] tx_queued,rx_queued);
  reg [15:0] format,ormask;
  reg [1:0] fmt_written;
  wire adapter_valid=fmt_written==2'b11 && format[15:13]==0 && format[1:0]==1 && format[3:2]==1 && format[4];
  wire tile_configured;
  assign configured=adapter_valid && tile_configured;
  always @(posedge clk) begin
    if(!rst_n) begin format<=0;ormask<=0;fmt_written<=0;end
    else if(!arm && cfg_we) begin
      if(cfg_addr==22) begin format<=cfg_data;fmt_written[0]<=1;end
      if(cfg_addr==23) begin ormask<=cfg_data;fmt_written[1]<=1;end
    end
  end
  reg [7:0] tx_fifo[0:3],rx_fifo[0:3];
  reg [1:0] tx_rd,tx_wr,rx_rd,rx_wr;
  reg [2:0] tx_count,rx_count;
  assign tx_queued=tx_count;assign rx_queued=rx_count;
  reg tx_live,rx_enabled,armed_seen,tx_inflight,cooldown;
  reg [10:0] tx_to_fetch,tx_to_send,rx_limit;
  reg [9:0] next_tx,rx_origin;
  reg req,req_we;
  reg [9:0] req_addr;
  reg [7:0] req_data;
  reg prefer_rx;
  wire [1:0] ready,rvalid;
  wire [15:0] mem_data;
  wire [1:0] busy,finished;
  wire [15:0] rx0,rx1;
  wire live=rst_n && arm && configured && armed_seen;
  wire tx_fire=live && tx_live && tx_count!=0 && !busy[0] && !finished[0] && !cooldown;
  wire [15:0] txword=({8'd0,tx_fifo[tx_rd]} << format[8:5]) | ormask;
  assign tx_active=tx_live;
  fabric_v2 fabric(clk,rst_n,arm && adapter_valid,cfg_we,cfg_addr,cfg_data,{1'b0,tx_fire},pin_in,txword,16'd0,
      pin_out,pin_oe,rx0,rx1,busy,finished,tile_configured);
  experiment_memory_fabric #(.USE_MACRO(USE_MACRO)) memory(clk,rst_n,arm,bank_cfg_we,bank_routes,
      {req,host_req},{req_we,host_we},{req_addr,host_addr},{req_data,host_wdata},ready,rvalid,mem_data);
  assign host_ready=ready[0];assign host_rvalid=rvalid[0];assign host_rdata=mem_data[7:0];
  wire actor_accept=req && ready[1];
  wire rx_pop=actor_accept && req_we;
  wire tx_push=rvalid[1] && tx_inflight;
  wire rx_event=live && finished[1];
  wire rx_room=(rx_count<4 || rx_pop);
  wire rx_push=rx_event && rx_enabled && rx_received<rx_limit && rx_room;
  wire tx_fetch_possible=tx_live && tx_to_fetch!=0 && !tx_inflight && tx_count<4;
  // Length has 11 bits; 12-bit sums prevent overflow before the bounds check.
  wire [11:0] tx_end={2'b0,tx_base}+{1'b0,tx_length};
  wire [11:0] rx_end={2'b0,rx_base}+{1'b0,rx_capacity};
  wire [15:0] decoded_rx=rx1 >> format[12:9];
  always @(posedge clk) begin
    if(!rst_n || !arm || !configured) begin
      tx_rd<=0;tx_wr<=0;rx_rd<=0;rx_wr<=0;tx_count<=0;rx_count<=0;
      tx_live<=0;rx_enabled<=0;armed_seen<=0;tx_inflight<=0;cooldown<=0;
      tx_to_fetch<=0;tx_to_send<=0;rx_limit<=0;next_tx<=0;rx_origin<=0;
      req<=0;req_we<=0;req_addr<=0;req_data<=0;prefer_rx<=1;
      tx_done<=0;tx_error<=0;rx_overflow<=0;rx_received<=0;rx_written<=0;
    end else begin
      tx_done<=0;
      if(!armed_seen) begin
        armed_seen<=1;rx_origin<=rx_base;rx_limit<=rx_capacity;
        rx_enabled<=rx_capacity!=0 && rx_end<=1024;
        if(rx_capacity==0 || rx_end>1024) rx_overflow<=1;
      end
      if(finished[0]) cooldown<=1;
      else if(cooldown) cooldown<=0;
      if(tx_start && !tx_live) begin
        tx_error<=0;
        if(tx_length==0 || tx_end>1024) begin tx_error<=1;tx_done<=1;end
        else begin tx_live<=1;next_tx<=tx_base;tx_to_fetch<=tx_length;tx_to_send<=tx_length;end
      end
      if(tx_fire) begin tx_rd<=tx_rd+1'b1;tx_to_send<=tx_to_send-1'b1;end
      if(tx_push) begin tx_fifo[tx_wr]<=mem_data[15:8];tx_wr<=tx_wr+1'b1;tx_inflight<=0;end
      case ({tx_push,tx_fire})
        2'b10:tx_count<=tx_count+1'b1;
        2'b01:tx_count<=tx_count-1'b1;
        default:begin end
      endcase
      if(finished[0] && tx_live && tx_to_send==0) begin tx_live<=0;tx_done<=1;end
      if(rx_event && !rx_push) rx_overflow<=1;
      if(rx_push) begin rx_fifo[rx_wr]<=decoded_rx[7:0];rx_wr<=rx_wr+1'b1;rx_received<=rx_received+1'b1;end
      if(rx_pop) begin rx_rd<=rx_rd+1'b1;rx_written<=rx_written+1'b1;end
      case ({rx_push,rx_pop})
        2'b10:rx_count<=rx_count+1'b1;
        2'b01:rx_count<=rx_count-1'b1;
        default:begin end
      endcase
      // The registered request remains unchanged until its bank accepts it.
      if(actor_accept) begin
        req<=0;
        if(req_we) prefer_rx<=0;
        else begin tx_inflight<=1;next_tx<=next_tx+1'b1;tx_to_fetch<=tx_to_fetch-1'b1;prefer_rx<=1;end
      end else if(!req) begin
        if(rx_count!=0 && (prefer_rx || !tx_fetch_possible)) begin
          req<=1;req_we<=1;req_addr<=rx_origin+rx_written[9:0];req_data<=rx_fifo[rx_rd];
        end else if(tx_fetch_possible) begin
          req<=1;req_we<=0;req_addr<=next_tx;req_data<=0;
        end
      end
    end
  end
`ifdef FABRIC_V2_ASSERT
  // RTL-only contract checks; disabled in synthesis and shared GL tests.
  assert property (@(posedge clk) disable iff (!rst_n || !arm || !configured)
    req && !ready[1] |=> req && $stable({req_we,req_addr,req_data}));
  assert property (@(posedge clk) disable iff (!rst_n || !arm || !configured)
    tx_count<=4 && rx_count<=4 && rx_written<=rx_received);
  assert property (@(posedge clk) disable iff (!rst_n || !arm || !configured)
    tx_push |-> (tx_count<4 || tx_fire));
`endif
endmodule
`default_nettype wire
