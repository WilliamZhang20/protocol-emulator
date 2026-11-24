`default_nettype none
// Spatial-grid experiment supporting a finite SPI transaction or
// independent bounded UART streams. The mode is loaded while disarmed.
// UART uses four-byte TX/RX queues, one outstanding actor read, and registered
// actor requests. RX storage is a finite, non-wrapping region.
module grid_unified #(parameter USE_MACRO=0)(
    input wire clk,rst_n,arm,cfg_we,input wire [6:0] cfg_addr,input wire [15:0] cfg_data,
    input wire bank_cfg_we,input wire [1:0] bank_routes,
    input wire host_req,host_we,input wire [9:0] host_addr,input wire [7:0] host_wdata,
    output wire host_ready,host_rvalid,output wire [7:0] host_rdata,
    input wire tx_start,input wire [9:0] tx_base,input wire [10:0] tx_length,
    input wire [9:0] rx_base,input wire [10:0] rx_capacity,
    input wire [1:0] pin_in,output wire [2:0] pin_out,pin_oe,
    output wire configured,output reg tx_done,tx_error,rx_overflow,
    output wire tx_active,output reg [10:0] rx_received,rx_written,
    output wire [2:0] tx_queued,rx_queued,
    input wire spi_start,input wire [9:0] spi_source_addr,spi_dest_addr,
    output reg spi_done,spi_error,output wire spi_active);
  reg [15:0] format,ormask;
  reg [1:0] fmt_written;
  reg mode_uart,mode_written;
  wire adapter_valid=fmt_written==2'b11 && mode_written && !format[15] &&
       (mode_uart ? (format[14:13]==0 && format[1:0]==1 && format[3:2]==1 && format[4]) :
        ((!format[14] || format[13]) && (format[1:0]==1 || format[1:0]==2) && (format[3:2]==1 || format[3:2]==2)));
  wire tile_configured;
  assign configured=adapter_valid && tile_configured;
  always @(posedge clk) begin
    if(!rst_n) begin format<=0;ormask<=0;fmt_written<=0;mode_uart<=0;mode_written<=0;end
    else if(!arm && cfg_we) begin
      if(cfg_addr==63) begin format<=cfg_data;fmt_written[0]<=1;end
      if(cfg_addr==64) begin ormask<=cfg_data;fmt_written[1]<=1;end
      if(cfg_addr==65) begin mode_uart<=cfg_data[0];mode_written<=cfg_data[15:1]==0;end
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
  wire tx_fire=live && mode_uart && tx_live && tx_count!=0 && !busy[0] && !finished[0] && !cooldown;
  wire [15:0] stream_txword=({8'd0,tx_fifo[tx_rd]} << format[8:5]) | ormask;
  reg [15:0] spi_txword,spi_txword1,spi_received;
  reg spi_fire,spi_req,spi_we;
  reg [9:0] spi_addr,spi_src,spi_dst;
  reg [7:0] spi_wdata,spi_first;
  reg spi_tx_finished,spi_tx1_finished,spi_rx_finished;
  reg [3:0] spi_state;
  localparam SPI_IDLE=0,SPI_READ0=1,SPI_WAIT0=2,SPI_READ1=3,SPI_WAIT1=4,
             SPI_FIRE=5,SPI_TRANSFER=6,SPI_WRITE0=7,SPI_WRITE1=8,
             SPI_READ2=9,SPI_WAIT2=10,SPI_READ3=11,SPI_WAIT3=12;
  assign spi_active=spi_state!=SPI_IDLE;
  wire [15:0] txword=mode_uart ? stream_txword : spi_txword;
  wire fabric_fire=mode_uart ? tx_fire : spi_fire;
  wire actor_req=mode_uart ? req : spi_req;
  wire actor_we=mode_uart ? req_we : spi_we;
  wire [9:0] actor_addr=mode_uart ? req_addr : spi_addr;
  wire [7:0] actor_data=mode_uart ? req_data : spi_wdata;
  assign tx_active=tx_live;
  grid_core grid(clk,rst_n,arm && adapter_valid,cfg_we && (cfg_addr<63 || (cfg_addr>=69 && cfg_addr<=80)),cfg_addr,cfg_data,
      fabric_fire,pin_in,txword,spi_txword1,rx0,rx1,busy[0],finished[0],busy[1],finished[1],pin_out,pin_oe,tile_configured);
  grid_memory #(.USE_MACRO(USE_MACRO)) memory(clk,rst_n,arm,bank_cfg_we,bank_routes,
      {actor_req,host_req},{actor_we,host_we},{actor_addr,host_addr},{actor_data,host_wdata},ready,rvalid,mem_data);
  assign host_ready=ready[0];assign host_rvalid=rvalid[0];assign host_rdata=mem_data[7:0];
  wire actor_accept=mode_uart && req && ready[1];
  wire rx_pop=actor_accept && req_we;
  wire tx_push=rvalid[1] && tx_inflight;
  wire rx_event=live && mode_uart && finished[1];
  wire rx_room=(rx_count<4 || rx_pop);
  wire rx_push=rx_event && rx_enabled && rx_received<rx_limit && rx_room;
  wire tx_fetch_possible=tx_live && tx_to_fetch!=0 && !tx_inflight && tx_count<4;
  // Length has 11 bits; 12-bit sums prevent overflow before the bounds check.
  wire [11:0] tx_end={2'b0,tx_base}+{1'b0,tx_length};
  wire [11:0] rx_end={2'b0,rx_base}+{1'b0,rx_capacity};
  wire [15:0] decoded_rx=rx1 >> format[12:9];
  wire [11:0] spi_source_end={2'b0,spi_source_addr}+{10'b0,format[1:0]}+
    (format[13] ? (format[14] ? 12'd2 : 12'd1) : 12'd0);
  wire [11:0] spi_dest_end={2'b0,spi_dest_addr}+{10'b0,format[3:2]};
  always @(posedge clk) begin
    if(!rst_n || !arm || !configured || !mode_uart) begin
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
  // The finite SPI path uses the same tiles and SRAM; mode is static while armed.
  always @* begin
    spi_req=0;spi_we=0;spi_addr=0;spi_wdata=0;spi_fire=0;
    case(spi_state)
      SPI_READ0: begin spi_req=1;spi_addr=spi_src;end
      SPI_READ1: begin spi_req=1;spi_addr=spi_src+10'd1;end
      SPI_READ2: begin spi_req=1;spi_addr=spi_src+{8'b0,format[1:0]};end
      SPI_READ3: begin spi_req=1;spi_addr=spi_src+{8'b0,format[1:0]}+10'd1;end
      SPI_FIRE: spi_fire=1;
      SPI_WRITE0: begin spi_req=1;spi_we=1;spi_addr=spi_dst;
        spi_wdata=format[3:2]==2 ? spi_received[15:8] : spi_received[7:0];end
      SPI_WRITE1: begin spi_req=1;spi_we=1;spi_addr=spi_dst+10'd1;spi_wdata=spi_received[7:0];end
      default: begin end
    endcase
  end
  always @(posedge clk) begin
    if(!rst_n || !arm || !configured || mode_uart) begin
      spi_state<=SPI_IDLE;spi_src<=0;spi_dst<=0;spi_first<=0;spi_txword<=0;spi_txword1<=0;
      spi_received<=0;spi_done<=0;spi_error<=0;spi_tx_finished<=0;spi_tx1_finished<=0;spi_rx_finished<=0;
    end else begin
      spi_done<=0;
      case(spi_state)
        SPI_IDLE: if(spi_start) begin
          spi_error<=0;spi_tx_finished<=0;spi_tx1_finished<=0;spi_rx_finished<=0;
          if(spi_source_end>1024 || spi_dest_end>1024) begin
            spi_error<=1;spi_done<=1;
          end else begin spi_src<=spi_source_addr;spi_dst<=spi_dest_addr;spi_state<=SPI_READ0;end
        end
        SPI_READ0: if(ready[1]) spi_state<=SPI_WAIT0;
        SPI_WAIT0: if(rvalid[1]) begin
          spi_first<=mem_data[15:8];
          if(format[1:0]==1) begin spi_txword<=({8'd0,mem_data[15:8]} << format[8:5]) | ormask;spi_state<=format[13] ? SPI_READ2 : SPI_FIRE;end
          else spi_state<=SPI_READ1;
        end
        SPI_READ1: if(ready[1]) spi_state<=SPI_WAIT1;
        SPI_WAIT1: if(rvalid[1]) begin spi_txword<=({spi_first,mem_data[15:8]} << format[8:5]) | ormask;spi_state<=format[13] ? SPI_READ2 : SPI_FIRE;end
        SPI_READ2: if(ready[1]) spi_state<=SPI_WAIT2;
        SPI_WAIT2: if(rvalid[1]) begin
          spi_first<=mem_data[15:8];
          if(format[14]) spi_state<=SPI_READ3;
          else begin spi_txword1<={8'b0,mem_data[15:8]};spi_state<=SPI_FIRE;end
        end
        SPI_READ3: if(ready[1]) spi_state<=SPI_WAIT3;
        SPI_WAIT3: if(rvalid[1]) begin spi_txword1<={spi_first,mem_data[15:8]};spi_state<=SPI_FIRE;end
        SPI_FIRE: spi_state<=SPI_TRANSFER;
        SPI_TRANSFER: begin
          if(finished[0]) spi_tx_finished<=1;
          if(finished[1]) spi_tx1_finished<=1;
          if(finished[format[4]]) begin spi_received<=(format[4] ? rx1 : rx0) >> format[12:9];spi_rx_finished<=1;end
          if((spi_tx_finished || finished[0]) && (!format[13] || spi_tx1_finished || finished[1]) &&
             (spi_rx_finished || finished[format[4]])) spi_state<=SPI_WRITE0;
        end
        SPI_WRITE0: if(ready[1]) begin if(format[3:2]==1) begin spi_state<=SPI_IDLE;spi_done<=1;end else spi_state<=SPI_WRITE1;end
        SPI_WRITE1: if(ready[1]) begin spi_state<=SPI_IDLE;spi_done<=1;end
        default:spi_state<=SPI_IDLE;
      endcase
    end
  end
`ifdef FABRIC_V2_ASSERT
  // RTL-only contract checks; disabled in synthesis and shared GL tests.
  assert property (@(posedge clk) disable iff (!rst_n || !arm || !configured || !mode_uart)
    req && !ready[1] |=> req && $stable({req_we,req_addr,req_data}));
  assert property (@(posedge clk) disable iff (!rst_n || !arm || !configured)
    tx_count<=4 && rx_count<=4 && rx_written<=rx_received);
  assert property (@(posedge clk) disable iff (!rst_n || !arm || !configured)
    tx_push |-> (tx_count<4 || tx_fire));
`endif
endmodule
`default_nettype wire
